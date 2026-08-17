package Plugins::SpotOn::API::Credentials;

# D-01: Shared credential-derivation module. Converts a PKCE access_token
# into long-lived librespot stored credentials (credentials.json, auth_type
# 1 = STORED_SPOTIFY_CREDENTIALS) by spawning `spoton --token-login`
# non-blockingly (Proc::Background + Slim::Utils::Timers poll, mirroring
# Plugins::SpotOn::Unified::Daemon's _pollPortFile shape -- Pitfall 2: never
# use blocking backticks/system() here, LMS is single-threaded).
#
# GH #147 / CONTEXT D-04: since the Aug 10, 2026 Login5 provenance blockade,
# PKCE-derived stored credentials are rejected by Spotify. ALL automatic
# call sites of the derivation path have been removed (Settings eager,
# DaemonManager crash-repair and lazy safety-net). The sub itself is
# retained for plan 65-03's Keymaster browser-fallback token path.

use strict;
use warnings;

use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

use constant CREDENTIALS_FILE => 'credentials.json';

# GH #147: persistent per-account "needs playback authorization" flag.
# Deliberately a SEPARATE flag from TokenManager's REAUTH_FLAG_PREFIX --
# needsReauth short-circuits TokenManager->getToken and would break the
# still-working Web API (Browse/Search/Library). Playback is broken; the
# Web API is not.
use constant PLAYBACK_AUTH_FLAG_PREFIX => 'spoton_needs_playback_auth_';

# M12-style async poll: 0.1s interval, 100 attempts (10s cap) -- mirrors
# Daemon.pm's PORT_POLL_INTERVAL/PORT_POLL_MAX_ATTEMPTS.
use constant DERIVE_POLL_INTERVAL     => 0.1;
use constant DERIVE_POLL_MAX_ATTEMPTS => 100;

# D-05: re-derive rate limiting -- 3 failures within 5 minutes triggers a
# 30-minute cooldown. Mirrors Daemon.pm's crash-loop constants
# (MAX_FAILURES_BEFORE_DISABLE_DISCOVERY / MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY /
# DISCOVERY_COOLDOWN_SECONDS), scoped here to derivation attempts per accountId
# rather than daemon crashes per player.
use constant MAX_DERIVE_FAILURES    => 3;
use constant DERIVE_FAILURE_WINDOW  => 300;   # 5 minutes
use constant DERIVE_COOLDOWN_SECONDS => 1800; # 30 minutes

# GH #147 plan 65-02: ZeroConf pairing (D-02 primary path). The user picks
# the announced "SpotOn Authorization (<library>)" device in their Spotify
# app while playing a track; the official app hands over Keymaster-provenance
# credentials that Login5 accepts. Poll every 2s; the Rust binary exits on
# its own after 900s (--discover-once self-timeout), 930s is our backstop
# margin before we force-kill a hung helper.
use constant PAIRING_POLL_INTERVAL   => 2;
use constant PAIRING_TIMEOUT_SECONDS => 930;
use constant PAIRING_STAGING_SUBDIR  => 'pairing-tmp';

# GH #147 plan 65-03: staging subdir for the Keymaster browser-fallback
# token derivation (deriveCredentialsFromToken). Separate from the pairing
# staging dir -- both flows isolate output from the live credentials.json
# until D-01 username validation passes (_installPairedCredentials).
use constant DERIVE_STAGING_SUBDIR => 'derive-tmp';

my $log         = logger('plugin.spoton');
my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');

# Cache instance for the playback-auth flag (GH #147). M5: cache version
# lives in Plugin.pm (single source of truth). Plugin.pm is always compiled
# first in production (this module is runtime-require'd) -- same pattern as
# PKCE.pm's own cache instantiation.
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# H3-style in-flight coalescing (Pitfall 3) -- keyed by accountId. Each value
# is an arrayref of pending callbacks. Concurrent Eager/Lazy derivation
# requests for the same account share a single --token-login subprocess.
my %_deriveInflight;

# D-05 rate-limit state -- keyed by accountId.
my %_deriveFailures;      # accountId => arrayref of failure epochs
my %_deriveCooldownUntil; # accountId => epoch until which derivation is blocked

# GH #147 plan 65-02: single global pairing slot -- only ONE ZeroConf mDNS
# announcement at a time (one pairing name on the LAN). Keys:
#   proc, accountId, stagingDir, state, startedAt
# state: idle | waiting | success | failed | mismatch | timeout
my %_pairing;

# ============================================================
# Public class methods
# ============================================================

# deriveCredentials($class, $accountId, $cb)
# cb signature: ($ok, $reason). $reason is undef on success, else one of:
#   no_token | no_binary | binary_too_old | spawn_failed | derivation_failed
#   | rate_limited
#
# GH #147 / CONTEXT D-04: retained for the plan 65-03 token-path refactor
# (Keymaster browser fallback reuses the shared spawn/poll machinery). This
# sub has ZERO production callers and MUST NOT be re-wired to automatic call
# sites -- PKCE-provenance credentials are rejected by Spotify Login5, so an
# automatic re-derive only re-arms the crash loop.
sub deriveCredentials {
    my ($class, $accountId, $cb) = @_;

    # 1. Coalescing guard FIRST (Pitfall 3): concurrent callers for the same
    # account queue behind the in-flight derivation instead of spawning a
    # second subprocess.
    if ($_deriveInflight{$accountId}) {
        main::INFOLOG && $log->info(
            "Credentials: coalescing derivation for account " . _mask($accountId));
        push @{ $_deriveInflight{$accountId} }, $cb;
        return;
    }
    $_deriveInflight{$accountId} = [$cb];

    my $resolve = sub {
        my ($ok, $reason) = @_;
        _resolveInflight($accountId, $ok, $reason);
    };

    # 2. Rate-limit gate (D-05).
    if (_inCooldown($accountId)) {
        $log->warn("Credentials: derivation rate-limited for account " . _mask($accountId));
        $resolve->(0, 'rate_limited');
        return;
    }

    # 3. Binary gates.
    require Plugins::SpotOn::Helper;
    my $helperPath = Plugins::SpotOn::Helper->get();
    unless ($helperPath) {
        $log->warn("Credentials: no SpotOn helper binary found for account " . _mask($accountId));
        $resolve->(0, 'no_binary');
        return;
    }
    unless (Plugins::SpotOn::Helper->getCapability('token-login')) {
        $log->warn("Credentials: SpotOn binary lacks token-login capability -- "
            . "please update the SpotOn binary (account " . _mask($accountId) . ")");
        $resolve->(0, 'binary_too_old');
        return;
    }

    # 4. Fresh token (Pitfall 5): ALWAYS via TokenManager->getToken (cache-or-
    # refresh), NEVER PKCE::loadTokens directly -- guarantees a non-expired
    # access_token even on the Lazy path (which can fire long after the last
    # proactive refresh cycle, e.g. right after an LMS restart).
    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->getToken($accountId, sub {
        my ($token) = @_;

        unless ($token) {
            # TokenManager has already flagged needsReauth internally when
            # the failure is permanent (M-4/D-08 semantics) -- nothing more
            # to do here than surface the reason to our caller.
            $resolve->(0, 'no_token');
            return;
        }

        # 5+6. Spawn + poll via the shared token-login core (GH #147 plan
        # 65-03 refactor). Derivation goes straight into the live account
        # dir (legacy contract: the token IS the account's own PKCE token,
        # so no staging/username re-validation is needed here); completion
        # handling below is byte-compatible with the pre-refactor behavior.
        my $accountDir = _accountDir($accountId);
        my $spawned = _spawnTokenLogin($accountId, $token, $accountDir, sub {
            # Success detection is FILE-BASED ONLY -- never rely on
            # subprocess stdout (Windows stdout-piping precedent, commit
            # 9874835).
            my $creds = $class->verifyCredentials($accountId);

            if ($creds) {
                # The Rust binary controls the file's creation mode --
                # enforce restrictive perms Perl-side as defense-in-depth
                # (T-51-03).
                my $credFile = $class->credentialsPathFor($accountId);
                chmod(0600, $credFile) if -f $credFile;

                _clearFailures($accountId);
                $resolve->(1, undef);
            } else {
                _recordFailure($accountId);
                $resolve->(0, 'derivation_failed');
            }
        });

        unless ($spawned) {
            _recordFailure($accountId);
            $resolve->(0, 'spawn_failed');
        }
    });
}

# deriveCredentialsFromToken($class, $accountId, $accessToken, $cb)
# GH #147 plan 65-03 (D-02 secondary path): derive stored credentials from a
# CALLER-SUPPLIED access token -- the Keymaster browser fallback's token,
# minted with KEYMASTER_CLIENT_ID and scope=streaming, which carries the
# provenance Login5 accepts. cb->($ok, $reason); reasons:
#   no_binary | binary_too_old | spawn_failed | derivation_failed |
#   rate_limited | account_mismatch | invalid_credentials | install_failed
#
# Unlike deriveCredentials, the subprocess writes into a staging dir first:
# the token's Spotify user might not match the account, so the result only
# reaches the live credentials.json after _installPairedCredentials passes
# D-01 username validation (T-65-12). The access token is used once for the
# spawn and never logged or persisted anywhere (T-29-07/T-51-05, T-65-09).
sub deriveCredentialsFromToken {
    my ($class, $accountId, $accessToken, $cb) = @_;

    # Coalescing guard FIRST (Pitfall 3) -- shares %_deriveInflight with
    # deriveCredentials, so the two entry points can never run concurrent
    # subprocesses for the same account.
    if ($_deriveInflight{$accountId}) {
        main::INFOLOG && $log->info(
            "Credentials: coalescing token derivation for account " . _mask($accountId));
        push @{ $_deriveInflight{$accountId} }, $cb;
        return;
    }
    $_deriveInflight{$accountId} = [$cb];

    my $resolve = sub {
        my ($ok, $reason) = @_;
        _resolveInflight($accountId, $ok, $reason);
    };

    # Rate-limit gate (D-05, T-65-14): a browser-fallback retry loop must
    # not hammer the AP either -- same per-account cooldown state as
    # deriveCredentials.
    if (_inCooldown($accountId)) {
        $log->warn("Credentials: token derivation rate-limited for account " . _mask($accountId));
        $resolve->(0, 'rate_limited');
        return;
    }

    # Binary gates (same as deriveCredentials).
    require Plugins::SpotOn::Helper;
    unless (Plugins::SpotOn::Helper->get()) {
        $log->warn("Credentials: no SpotOn helper binary found for account " . _mask($accountId));
        $resolve->(0, 'no_binary');
        return;
    }
    unless (Plugins::SpotOn::Helper->getCapability('token-login')) {
        $log->warn("Credentials: SpotOn binary lacks token-login capability -- "
            . "please update the SpotOn binary (account " . _mask($accountId) . ")");
        $resolve->(0, 'binary_too_old');
        return;
    }

    unless (defined $accessToken && length $accessToken) {
        # Defensive: callers pass exchangeCode-validated tokens; never spawn
        # without one. No _recordFailure -- the AP was never contacted.
        $resolve->(0, 'derivation_failed');
        return;
    }

    # Staging isolation (D-01): NOT the live account dir -- the token's user
    # might not match the account.
    my $stagingDir = catdir(_accountDir($accountId), DERIVE_STAGING_SUBDIR);

    my $spawned = _spawnTokenLogin($accountId, $accessToken, $stagingDir, sub {
        my $stagingFile = catfile($stagingDir, CREDENTIALS_FILE);
        my ($ok, $reason);

        if (-f $stagingFile) {
            # Shared finalizer (plan 65-02): validates, D-01 username check,
            # atomic install, provenance marker, flag clear, scheduleInit.
            ($ok, $reason) = _installPairedCredentials($accountId, $stagingDir, 'keymaster');
        } else {
            # Subprocess exited without writing credentials: AP rejection or
            # binary failure. Counts toward the D-05 cooldown.
            _recordFailure($accountId);
            ($ok, $reason) = (0, 'derivation_failed');
        }

        # Leftover staging must never be mistaken for live credentials.
        _purgeStagingDir($stagingDir);

        if ($ok) {
            _clearFailures($accountId);
            $resolve->(1, undef);
        } else {
            $resolve->(0, $reason);
        }
    });

    unless ($spawned) {
        _recordFailure($accountId);
        $resolve->(0, 'spawn_failed');
    }
}

# clearRateLimit($class, $accountId)
# WR-02: public reset for the D-05 rate-limit cooldown. Called by
# Settings.pm's _pkceStoreAccount immediately before deriveCredentials on
# a fresh (re-)auth -- a user-initiated PKCE exchange is exactly the event
# the AP-hammering protection should yield to (one attempt with new tokens,
# not zero).
sub clearRateLimit {
    my ($class, $accountId) = @_;
    _clearFailures($accountId);
}

# credentialsPathFor($class, $accountId)
# Single source of truth for the credentials.json path -- always account-
# scoped (Pitfall 4: new code must never touch the legacy flat spoton dir).
sub credentialsPathFor {
    my ($class, $accountId) = @_;
    return catfile(_accountDir($accountId), CREDENTIALS_FILE);
}

# verifyCredentials($class, $accountId)
# Reads and validates credentials.json. Returns the parsed hashref only when
# auth_type == 1 AND username/auth_data are both non-empty -- never trust the
# subprocess exit code alone (Security V5/T-51-02). Returns undef on any
# absence/parse/validation failure.
sub verifyCredentials {
    my ($class, $accountId) = @_;

    my $data = _readCredsRaw($accountId);
    return undef unless $data;
    return undef unless ($data->{auth_type} // -1) == 1;
    return undef unless $data->{username}  && length $data->{username};
    return undef unless $data->{auth_data} && length $data->{auth_data};

    return $data;
}

# accountMismatch($class, $accountId) (D-08)
# Returns 1 only when credentials.json parses, has a username, the active
# PKCE account's spotifyUserId is known, and the two differ. All absence/
# parse-failure/unknown-account cases return 0.
#
# This sub only DETECTS a mismatch; deletion + re-derive is wired in plan 02.
# Deletion callers MUST unlink only the single credentials.json file --
# pkce_tokens.json in the same account directory must survive. Directory-tree
# removal (TokenManager::removeAccount's remove_tree pattern) is the WRONG
# tool here; that pattern is for full account removal, not credential-mismatch
# repair (RESEARCH.md Anti-Patterns).
sub accountMismatch {
    my ($class, $accountId) = @_;

    my $data = _readCredsRaw($accountId);
    return 0 unless $data && $data->{username};

    my $accounts = $prefs->get('accounts') || {};
    my $expectedUserId = $accounts->{$accountId} ? $accounts->{$accountId}{spotifyUserId} : undef;
    return 0 unless $expectedUserId;

    return ($data->{username} ne $expectedUserId) ? 1 : 0;
}

# isCredentialError($class, $stderrText) (D-03/D-05)
# Matches the exact librespot-core error strings verified against the
# vendored librespot-core source (connection/mod.rs::login_error_message()).
# Assumption A2: recheck these strings on any librespot-core dependency bump.
#
# INVALID_CREDENTIALS / "Login request was denied" are the Login5 provenance
# blockade signatures observed since Aug 10, 2026 (GH #147): Spotify's Login5
# endpoint rejects stored credentials that were not minted with the Keymaster
# client_id. Same runtime-detection strings Music Assistant matches on
# (commit ec639766).
sub isCredentialError {
    my ($class, $stderrText) = @_;
    return 0 unless defined $stderrText;
    return $stderrText =~ /Bad credentials|Could not validate credentials|No cached credentials in|INVALID_CREDENTIALS|Login request was denied/
        ? 1 : 0;
}

# ============================================================
# Playback-auth flag API (GH #147)
# Persistent per-account flag: the account's stored playback credentials
# were rejected by Spotify Login5 (or are known wrong-provenance) and the
# user must re-authorize playback (ZeroConf pairing / Keymaster browser
# fallback, plans 65-02/65-03). Mirrors TokenManager's _markNeedsReauth
# 'never'-TTL discipline but uses its OWN cache key prefix -- see the
# PLAYBACK_AUTH_FLAG_PREFIX comment above for why needsReauth must NOT be
# reused here.
# ============================================================

# markNeedsPlaybackAuth($class, $accountId, $reason)
# Known reasons: 'credential_error' (Login5 rejection at daemon crash),
# 'legacy_token_derived' (plan 65-03 upgrade migration).
sub markNeedsPlaybackAuth {
    my ($class, $accountId, $reason) = @_;
    return unless defined $accountId && length $accountId;
    $cache->set(PLAYBACK_AUTH_FLAG_PREFIX . $accountId,
        { reason => ($reason // ''), ts => time() }, 'never');
    main::INFOLOG && $log->info(
        "Credentials: account " . _mask($accountId)
        . " flagged as needing playback authorization (" . ($reason // '') . ")");
}

# needsPlaybackAuth($class, $accountId) -> 0|1
sub needsPlaybackAuth {
    my ($class, $accountId) = @_;
    return 0 unless defined $accountId && length $accountId;
    return $cache->get(PLAYBACK_AUTH_FLAG_PREFIX . $accountId) ? 1 : 0;
}

# playbackAuthReason($class, $accountId) -> reason string or ''
sub playbackAuthReason {
    my ($class, $accountId) = @_;
    return '' unless defined $accountId && length $accountId;
    my $flag = $cache->get(PLAYBACK_AUTH_FLAG_PREFIX . $accountId);
    return (ref $flag eq 'HASH' && defined $flag->{reason}) ? $flag->{reason} : '';
}

# clearNeedsPlaybackAuth($class, $accountId)
# Called by the plans 65-02/65-03 provisioning flows once the user has
# completed a playback re-authorization.
sub clearNeedsPlaybackAuth {
    my ($class, $accountId) = @_;
    return unless defined $accountId && length $accountId;
    $cache->remove(PLAYBACK_AUTH_FLAG_PREFIX . $accountId);
    main::INFOLOG && $log->info(
        "Credentials: playback-auth flag cleared for account " . _mask($accountId));
}

# classifyAudioKeyError($class, $stderrText) (D-02)
# Passive stderr classifier for librespot's audio-key exchange, mirroring
# isCredentialError's discipline: pure string-matching over bounded input,
# returns only a symbolic enum value, never the raw stderr text. Called with
# existing stderrTail output only -- never triggers a new process spawn.
#
# Two known signatures (vault/research/Audio Key Service.md):
#   "error audio key 0 1" -- permanent denial (account-cohort key-service wall)
#   "error audio key 0 2" -- transient rapid-skip throttle (~2min, auto-clears)
# Permanent denial takes priority when both are present in the same tail.
sub classifyAudioKeyError {
    my ($class, $stderrText) = @_;
    return undef unless defined $stderrText && length $stderrText;

    return 'denied'   if $stderrText =~ /error audio key 0 1/;
    return 'throttled' if $stderrText =~ /error audio key 0 2/;
    return 'timeout'  if $stderrText =~ /Audio key response timeout/;
    return undef;
}

# ============================================================
# ZeroConf pairing engine (GH #147 plan 65-02, D-02 primary path)
# All async -- Proc::Background + Slim::Utils::Timers, never blocking
# (LMS is single-threaded; mirrors the _pollTokenLogin shape below).
# Success detection is FILE-BASED ONLY: the username is read from the
# staging credentials.json, never from subprocess stdout (Windows
# stdout-piping precedent, commit 9874835).
# ============================================================

# pairingDeviceName($class)
# Gotcha 1: the pairing device name must differ from every Connect player
# name so the user cannot pick a regular player by mistake. Computed here
# (single source of truth) and reused by Settings.pm for the on-page
# instructions so the user sees the exact label to look for.
sub pairingDeviceName {
    my ($class) = @_;

    my $libraryName = eval {
        require Slim::Utils::Misc;
        Slim::Utils::Misc::getLibraryName();
    };
    $libraryName = 'LMS' unless defined $libraryName && length $libraryName;

    my $name = 'SpotOn Authorization (' . $libraryName . ')';
    $name = substr($name, 0, 60) if length($name) > 60;
    return $name;
}

# startPairing($class, $accountId)
# -> (1) on started, or (0, $reason) with reason in:
#    already_running | unknown_account | no_binary | no_capability | spawn_failed
sub startPairing {
    my ($class, $accountId) = @_;

    # Single global slot: one mDNS announcement at a time.
    if (($_pairing{state} // '') eq 'waiting') {
        return (0, 'already_running');
    }

    my $accounts = $prefs->get('accounts') || {};
    unless (defined $accountId && length $accountId && $accounts->{$accountId}) {
        $log->warn("Credentials: pairing requested for unknown account " . _mask($accountId));
        return (0, 'unknown_account');
    }

    require Plugins::SpotOn::Helper;
    my $helperPath = Plugins::SpotOn::Helper->get();
    unless ($helperPath) {
        $log->warn("Credentials: no SpotOn helper binary found for pairing (account " . _mask($accountId) . ")");
        return (0, 'no_binary');
    }
    unless (Plugins::SpotOn::Helper->getCapability('discover-once')) {
        $log->warn("Credentials: SpotOn binary lacks discover-once capability -- "
            . "please update the SpotOn binary (account " . _mask($accountId) . ")");
        return (0, 'no_capability');
    }

    my $name = $class->pairingDeviceName();

    # D-01 isolation: pairing output lands in a staging dir first -- a wrong
    # user's pairing must never touch the live credentials.json.
    my $stagingDir = catdir(_accountDir($accountId), PAIRING_STAGING_SUBDIR);
    unless (-d $stagingDir) {
        require File::Path;
        # IN-02: owner-only perms; mode is advisory on Windows (ignored).
        File::Path::make_path($stagingDir, { mode => 0700 });
    }
    my $staleFile = catfile($stagingDir, CREDENTIALS_FILE);
    unlink $staleFile if -f $staleFile;

    require Proc::Background;
    my $proc = eval {
        Proc::Background->new(
            { 'die_upon_destroy' => 1 },
            $helperPath, '-n', $name,
            '--cache', $stagingDir,
            '--discover-once',
        );
    };
    if ($@ || !$proc) {
        # T-29-07/T-51-05 discipline: masked accountId only, never the
        # command line.
        $log->error("Credentials: pairing spawn failed for account " . _mask($accountId));
        return (0, 'spawn_failed');
    }

    %_pairing = (
        proc       => $proc,
        accountId  => $accountId,
        stagingDir => $stagingDir,
        state      => 'waiting',
        startedAt  => time(),
    );

    main::INFOLOG && $log->info(
        "Credentials: ZeroConf pairing started for account " . _mask($accountId)
        . " (device name '$name')");

    Slim::Utils::Timers::setTimer(\%_pairing, Time::HiRes::time() + PAIRING_POLL_INTERVAL, \&_pollPairing);
    return (1);
}

# pairingStatus($class)
# -> { state => 'idle'|'waiting'|'success'|'failed'|'mismatch'|'timeout',
#      accountId => $id_or_undef }
# Exposes symbolic state only (T-65-07) -- never stderr or usernames.
sub pairingStatus {
    my ($class) = @_;
    return {
        state     => $_pairing{state} || 'idle',
        accountId => $_pairing{accountId},
    };
}

# cancelPairing($class)
# Kill + cleanup, state -> idle. Idempotent when idle, so Plugin shutdown
# paths and the Settings pagehide handler can call it unconditionally
# (gotcha 6; the binary's own 900s self-timeout is the backstop if this is
# never reached).
sub cancelPairing {
    my ($class) = @_;

    Slim::Utils::Timers::killTimers(\%_pairing, \&_pollPairing);

    if ($_pairing{proc} && eval { $_pairing{proc}->alive }) {
        eval { $_pairing{proc}->die };
    }
    _cleanupPairingStaging();

    if (($_pairing{state} // 'idle') ne 'idle') {
        main::INFOLOG && $log->info(
            "Credentials: pairing cancelled (account " . _mask($_pairing{accountId}) . ")");
    }
    %_pairing = ( state => 'idle' );
    return 1;
}

# ============================================================
# Private helpers
# ============================================================

# _spawnTokenLogin($accountId, $token, $targetDir, $onExit)
# Shared spawn-and-poll core for the two --token-login entry points (GH #147
# plan 65-03 refactor): dir prep (0700), stale credentials.json unlink,
# SPOTON_TOKEN env vs --token argv fallback, Proc::Background spawn, async
# poll. $onExit->() fires once the subprocess has exited (or was killed at
# the poll cap) -- completion semantics (live-dir verification vs staging
# install) belong to the caller. Returns 1 when the subprocess was spawned,
# 0 on spawn failure (already logged; caller resolves spawn_failed).
sub _spawnTokenLogin {
    my ($accountId, $token, $targetDir, $onExit) = @_;

    require Plugins::SpotOn::Helper;
    my $helperPath = Plugins::SpotOn::Helper->get();

    unless (-d $targetDir) {
        require File::Path;
        # IN-02: restrict directory permissions to owner-only (0700) for
        # defense-in-depth. mode param is advisory on Windows (silently
        # ignored), which is fine. Mirrors the chmod(0700) in
        # Settings.pm _pkceStoreAccount (T-04.3-07 pattern).
        File::Path::make_path($targetDir, { mode => 0700 });
    }

    # WR-04: unlink any pre-existing credentials.json before spawning so
    # completion detection can only succeed against a file the subprocess
    # actually wrote. Without this, a re-derivation could detect the OLD
    # file as a successful run even when the subprocess wrote nothing.
    my $staleFile = catfile($targetDir, CREDENTIALS_FILE);
    unlink $staleFile if -f $staleFile;

    require Proc::Background;

    # CR-01 / H10: prefer SPOTON_TOKEN env var over --token argv when
    # the binary supports it (capability 'token-env'). argv is world-
    # readable via /proc/<pid>/cmdline and `ps`; the env var is set just
    # for the spawn and deleted immediately after (same pattern as
    # SPOTON_LMS_AUTH in Daemon.pm lines 186-189). --token argv is
    # retained as fallback for older binaries.
    my $useTokenEnv = Plugins::SpotOn::Helper->getCapability('token-env');
    my @tokenArgs = $useTokenEnv ? () : ('--token', $token);
    $ENV{SPOTON_TOKEN} = $token if $useTokenEnv;

    my $proc = eval {
        Proc::Background->new(
            { 'die_upon_destroy' => 1 },
            $helperPath, '-n', 'SpotOn',
            '--token-login', @tokenArgs,
            '--cache', $targetDir,
        );
    };
    delete $ENV{SPOTON_TOKEN} if $useTokenEnv;  # immediately after spawn
    if ($@ || !$proc) {
        # CRITICAL (T-29-07/T-51-05): never log the spawn command line or
        # the token value -- log only the masked accountId and cache dir.
        $log->error("Credentials: spawn failed for account " . _mask($accountId)
            . " (cache=$targetDir)");
        return 0;
    }

    main::INFOLOG && $log->info(
        "Credentials: derivation started for account " . _mask($accountId)
        . " (cache=$targetDir)");

    # Async poll for completion (mirrors Daemon::_pollPortFile).
    my $state = {
        proc      => $proc,
        accountId => $accountId,
        onExit    => $onExit,
        attempts  => 0,
    };
    Slim::Utils::Timers::setTimer($state, Time::HiRes::time() + DERIVE_POLL_INTERVAL, \&_pollTokenLogin);
    return 1;
}

# _pollTokenLogin($state)
# Timer callback -- generic completion continuation for a _spawnTokenLogin
# subprocess. Copies Daemon::_pollPortFile's poll-again-vs-complete branch
# structure; file inspection happens in the caller-supplied onExit closure.
sub _pollTokenLogin {
    my ($state) = @_;

    my $proc = $state->{proc};

    my $attempts = ($state->{attempts} || 0) + 1;
    $state->{attempts} = $attempts;

    my $procAlive = $proc && $proc->alive;

    if ($procAlive && $attempts < DERIVE_POLL_MAX_ATTEMPTS) {
        Slim::Utils::Timers::setTimer($state, Time::HiRes::time() + DERIVE_POLL_INTERVAL, \&_pollTokenLogin);
        return;
    }

    # Timeout with the subprocess still alive -- kill it.
    if ($procAlive) {
        eval { $proc->die };
    }

    $state->{onExit}->();
}

# _purgeStagingDir($dir)
# Removes a staging credentials.json (if still present, e.g. after a
# mismatch) and the staging dir itself. Generic sibling of
# _cleanupPairingStaging (which is bound to the %_pairing slot).
sub _purgeStagingDir {
    my ($dir) = @_;
    return unless defined $dir && length $dir;

    my $file = catfile($dir, CREDENTIALS_FILE);
    unlink $file if -f $file;
    rmdir $dir;  # only succeeds when empty -- exactly what we want
}

# _pollPairing()
# Timer callback -- completion continuation for the --discover-once
# subprocess. Re-arms every PAIRING_POLL_INTERVAL seconds while the helper
# is alive and within the timeout window.
sub _pollPairing {
    # Guard against a stale timer firing after cancelPairing already reset
    # the slot (killTimers should prevent this, belt-and-braces).
    return unless ($_pairing{state} // '') eq 'waiting';

    my $proc    = $_pairing{proc};
    my $elapsed = time() - ($_pairing{startedAt} || 0);
    my $alive   = $proc && eval { $proc->alive };

    if ($alive && $elapsed < PAIRING_TIMEOUT_SECONDS) {
        Slim::Utils::Timers::setTimer(\%_pairing, Time::HiRes::time() + PAIRING_POLL_INTERVAL, \&_pollPairing);
        return;
    }

    if ($alive) {
        # Past the binary's own 900s self-timeout plus margin and it is
        # still alive -- force-kill the hung helper.
        eval { $proc->die };
        $log->warn("Credentials: pairing timed out for account " . _mask($_pairing{accountId}));
        $_pairing{state} = 'timeout';
        _cleanupPairingStaging();
        return;
    }

    # Helper exited. FILE-BASED success detection only (never stdout).
    my $stagingFile = catfile($_pairing{stagingDir}, CREDENTIALS_FILE);
    if (-f $stagingFile) {
        my ($ok, $reason) = _installPairedCredentials(
            $_pairing{accountId}, $_pairing{stagingDir}, 'zeroconf');
        $_pairing{state} = $ok                                       ? 'success'
                         : ($reason && $reason eq 'account_mismatch') ? 'mismatch'
                         :                                              'failed';
    } else {
        # Exit without a credentials file: binary failure or its own
        # 15-minute timeout (both exit 1, both leave no file).
        main::INFOLOG && $log->info(
            "Credentials: pairing helper exited without credentials for account "
            . _mask($_pairing{accountId}));
        $_pairing{state} = 'failed';
    }

    # Leftover staging must never be mistaken for live credentials.
    _cleanupPairingStaging();
}

# _installPairedCredentials($accountId, $stagingDir, $source)
# Shared finalizer -- plan 65-03 reuses it for the Keymaster token path, so
# it carries no ZeroConf-specific assumptions. $source: 'zeroconf' | 'keymaster'.
# -> (1) or (0, 'account_mismatch'|'invalid_credentials'|'install_failed')
sub _installPairedCredentials {
    my ($accountId, $stagingDir, $source) = @_;

    my $stagingFile = catfile($stagingDir, CREDENTIALS_FILE);

    # Validate with the same rules as verifyCredentials: never trust the
    # subprocess exit code alone (Security V5/T-51-02).
    my $data = eval {
        open(my $fh, '<', $stagingFile) or die "open failed: $!";
        local $/;
        my $json = <$fh>;
        close($fh);
        from_json($json);
    };
    if ($@ || !$data
        || ($data->{auth_type} // -1) != 1
        || !($data->{username}  && length $data->{username})
        || !($data->{auth_data} && length $data->{auth_data})) {
        $log->warn("Credentials: staged pairing credentials invalid for account "
            . _mask($accountId) . " -- not installed");
        return (0, 'invalid_credentials');
    }

    # D-01 username validation: a wrong Spotify user's pairing must never
    # persist into this account. Fail-closed when the expected user ID is
    # unknown. Same comparison accountMismatch uses.
    my $accounts = $prefs->get('accounts') || {};
    my $expected = $accounts->{$accountId} ? $accounts->{$accountId}{spotifyUserId} : undef;
    unless (defined $expected && length $expected && $data->{username} eq $expected) {
        $log->warn("Credentials: paired Spotify user " . _maskUser($data->{username})
            . " does not match account " . _mask($accountId)
            . " (expected " . _maskUser($expected) . ") -- credentials NOT installed (D-01)");
        return (0, 'account_mismatch');
    }

    # Install atomically into the per-account layout (Pitfall 4: never the
    # legacy flat dir).
    my $accountDir = _accountDir($accountId);
    unless (-d $accountDir) {
        require File::Path;
        File::Path::make_path($accountDir, { mode => 0700 });
    }
    my $target = __PACKAGE__->credentialsPathFor($accountId);
    # Windows rename does not overwrite -- unlink the target first.
    unlink $target if -f $target;
    unless (rename($stagingFile, $target)) {
        # Cross-volume edge (staging and target on different filesystems).
        require File::Copy;
        unless (File::Copy::move($stagingFile, $target)) {
            $log->error("Credentials: failed to install paired credentials for account "
                . _mask($accountId) . ": $!");
            return (0, 'install_failed');
        }
    }
    # T-51-03 defense-in-depth: the Rust binary controls the creation mode.
    chmod(0600, $target) if -f $target;

    # Record provenance: plan 65-03's migration treats accounts WITHOUT this
    # marker as legacy token-derived.
    $accounts->{$accountId}{playbackCredSource} = $source;
    $prefs->set('accounts', $accounts);

    __PACKAGE__->clearNeedsPlaybackAuth($accountId);

    # Daemons start within ~2s instead of waiting for the 60s watchdog.
    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Unified::DaemonManager->scheduleInit();

    main::INFOLOG && $log->info(
        "Credentials: paired credentials installed for account " . _mask($accountId)
        . " (source=$source)");
    return (1);
}

# _cleanupPairingStaging()
# Removes the staging credentials.json (if still present, e.g. after a
# mismatch) and the staging dir itself. Leftover staging must never be
# mistaken for live credentials.
sub _cleanupPairingStaging {
    my $dir = $_pairing{stagingDir} or return;

    my $file = catfile($dir, CREDENTIALS_FILE);
    unlink $file if -f $file;
    rmdir $dir;  # only succeeds when empty -- exactly what we want

    delete $_pairing{stagingDir};
    delete $_pairing{proc};
}

# _resolveInflight($accountId, $ok, $reason)
# Drains the in-flight callback queue for $accountId. WR-06: eval-guard each
# queued callback so one dying consumer does not starve remaining waiters.
sub _resolveInflight {
    my ($accountId, $ok, $reason) = @_;

    my $queue = delete $_deriveInflight{$accountId} || [];
    for my $cb (@{$queue}) {
        eval { $cb->($ok, $reason); 1 }
            or $log->error("Credentials: derive callback died for account "
                . _mask($accountId) . ": $@");
    }
}

# _accountDir($accountId)
# Account-scoped cache dir exclusively -- {cachedir}/spoton/{accountId}.
# Same directory Daemon.pm reads with -c once activeAccountId is set.
sub _accountDir {
    my ($accountId) = @_;
    return catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);
}

# _readCredsRaw($accountId)
# Read + JSON-parse credentials.json (PKCE::loadTokens shape). Returns the
# hashref, or undef on any absence/parse failure. No auth_type/field
# validation here -- that's verifyCredentials's job. accountMismatch only
# needs the raw username field, even for a not-yet-derivation-complete file.
sub _readCredsRaw {
    my ($accountId) = @_;

    my $credFile = catfile(_accountDir($accountId), CREDENTIALS_FILE);
    return undef unless -f $credFile;

    my $data = eval {
        open(my $fh, '<', $credFile) or die "open failed: $!";
        local $/;
        my $json = <$fh>;
        close($fh);
        from_json($json);
    };

    return undef if $@ || !$data;
    return $data;
}

# _inCooldown($accountId)
# D-05: true while the account is within its post-failure cooldown window.
# Cooldown auto-expires (lazily) once time() passes the recorded deadline.
sub _inCooldown {
    my ($accountId) = @_;

    my $until = $_deriveCooldownUntil{$accountId};
    return 0 unless $until;

    if (time() >= $until) {
        delete $_deriveCooldownUntil{$accountId};
        return 0;
    }
    return 1;
}

# _recordFailure($accountId)
# D-05: records a derivation-attempt failure (spawn_failed / derivation_failed
# only -- pre-flight skips like no_token/no_binary/binary_too_old are not
# counted, since they never actually reach the Spotify AP and D-05's purpose
# is specifically to stop a retry loop from hammering the AP, T-51-06).
# Trims to the last MAX_DERIVE_FAILURES entries; when MAX_DERIVE_FAILURES
# failures fall within DERIVE_FAILURE_WINDOW seconds, engages a
# DERIVE_COOLDOWN_SECONDS cooldown and clears the failure list.
sub _recordFailure {
    my ($accountId) = @_;

    my $list = ($_deriveFailures{$accountId} //= []);
    push @{$list}, time();
    if (@{$list} > MAX_DERIVE_FAILURES) {
        splice @{$list}, 0, @{$list} - MAX_DERIVE_FAILURES;
    }

    if (@{$list} >= MAX_DERIVE_FAILURES && (time() - $list->[0]) < DERIVE_FAILURE_WINDOW) {
        $_deriveCooldownUntil{$accountId} = time() + DERIVE_COOLDOWN_SECONDS;
        $_deriveFailures{$accountId} = [];
        $log->warn("Credentials: " . MAX_DERIVE_FAILURES
            . " derivation failures within " . DERIVE_FAILURE_WINDOW
            . "s -- cooldown engaged for account " . _mask($accountId));
    }
}

# _clearFailures($accountId)
# A successful derivation clears both the failure list and any active
# cooldown for that account.
sub _clearFailures {
    my ($accountId) = @_;
    delete $_deriveFailures{$accountId};
    delete $_deriveCooldownUntil{$accountId};
}

# _mask($accountId)
# T-50-01/T-29-07 discipline: masked accountId for log lines -- never log
# full account IDs or any token value. Identical to TokenManager::_mask.
sub _mask {
    my ($accountId) = @_;
    return 'unknown' unless defined $accountId && length $accountId;
    return substr($accountId, 0, 4) . '****';
}

# _maskUser($username)
# T-65-07: masked Spotify username for the D-01 mismatch warn line --
# first 3 chars + '****', never the full username.
sub _maskUser {
    my ($username) = @_;
    return 'unknown' unless defined $username && length $username;
    return substr($username, 0, 3) . '****';
}

1;
