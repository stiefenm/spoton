package Plugins::SpotOn::API::Credentials;

# D-01: Shared credential-derivation module. Converts a PKCE access_token
# into long-lived librespot stored credentials (credentials.json, auth_type
# 1 = STORED_SPOTIFY_CREDENTIALS) by spawning `spoton --token-login`
# non-blockingly (Proc::Background + Slim::Utils::Timers poll, mirroring
# Plugins::SpotOn::Unified::Daemon's _pollPortFile shape -- Pitfall 2: never
# use blocking backticks/system() here, LMS is single-threaded).
#
# Consumed by both the Settings-eager call site (immediately after PKCE auth)
# and the DaemonManager-lazy call site (safety-net before daemon start) --
# wired in plans 02/03.

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

# ============================================================
# Public class methods
# ============================================================

# deriveCredentials($class, $accountId, $cb)
# cb signature: ($ok, $reason). $reason is undef on success, else one of:
#   no_token | no_binary | binary_too_old | spawn_failed | derivation_failed
#   | rate_limited
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

        # 5. Spawn: ensure the account dir exists (mirrors PKCE::storeTokens).
        my $accountDir = _accountDir($accountId);
        unless (-d $accountDir) {
            require File::Path;
            # IN-02: restrict directory permissions to owner-only (0700) for
            # defense-in-depth. mode param is advisory on Windows (silently
            # ignored), which is fine. Mirrors the chmod(0700) in
            # Settings.pm _pkceStoreAccount (T-04.3-07 pattern).
            File::Path::make_path($accountDir, { mode => 0700 });
        }

        # WR-04: unlink any pre-existing credentials.json before spawning
        # so verifyCredentials after exit can only succeed against a file
        # the subprocess actually wrote. Without this, the eager Settings
        # path (re-auth of an existing account) could detect the OLD file
        # as a successful derivation even when the subprocess wrote nothing.
        my $credFile = $class->credentialsPathFor($accountId);
        unlink $credFile if -f $credFile;

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
                '--cache', $accountDir,
            );
        };
        delete $ENV{SPOTON_TOKEN} if $useTokenEnv;  # immediately after spawn
        if ($@ || !$proc) {
            # CRITICAL (T-29-07/T-51-05): never log the spawn command line or
            # the token value -- log only the masked accountId and cache dir.
            $log->error("Credentials: spawn failed for account " . _mask($accountId)
                . " (cache=$accountDir)");
            _recordFailure($accountId);
            $resolve->(0, 'spawn_failed');
            return;
        }

        main::INFOLOG && $log->info(
            "Credentials: derivation started for account " . _mask($accountId)
            . " (cache=$accountDir)");

        # 6. Async poll for completion (mirrors Daemon::_pollPortFile).
        my $state = {
            proc      => $proc,
            accountId => $accountId,
            resolve   => $resolve,
            attempts  => 0,
        };
        # IN-03: removed no-op killTimers($state, \&_pollDerivation) — $state
        # was just created above and no timer exists on it. The in-flight
        # coalescing guard already prevents concurrent polls per account.
        Slim::Utils::Timers::setTimer($state, Time::HiRes::time() + DERIVE_POLL_INTERVAL, \&_pollDerivation);
    });
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
    return undef;
}

# ============================================================
# Private helpers
# ============================================================

# _pollDerivation($state)
# Timer callback -- completion continuation for the --token-login subprocess.
# Copies Daemon::_pollPortFile's poll-again-vs-complete branch structure.
sub _pollDerivation {
    my ($state) = @_;

    my $proc      = $state->{proc};
    my $accountId = $state->{accountId};
    my $resolve   = $state->{resolve};

    my $attempts = ($state->{attempts} || 0) + 1;
    $state->{attempts} = $attempts;

    my $procAlive = $proc && $proc->alive;

    if ($procAlive && $attempts < DERIVE_POLL_MAX_ATTEMPTS) {
        Slim::Utils::Timers::setTimer($state, Time::HiRes::time() + DERIVE_POLL_INTERVAL, \&_pollDerivation);
        return;
    }

    # Timeout with the subprocess still alive -- kill it.
    if ($procAlive) {
        eval { $proc->die };
    }

    # Success detection is FILE-BASED ONLY -- never rely on subprocess stdout
    # (Windows stdout-piping precedent, commit 9874835).
    my $credsClass = __PACKAGE__;
    my $creds = $credsClass->verifyCredentials($accountId);

    if ($creds) {
        # The Rust binary controls the file's creation mode -- enforce
        # restrictive perms Perl-side as defense-in-depth (T-51-03).
        my $credFile = $credsClass->credentialsPathFor($accountId);
        chmod(0600, $credFile) if -f $credFile;

        _clearFailures($accountId);
        $resolve->(1, undef);
    } else {
        _recordFailure($accountId);
        $resolve->(0, 'derivation_failed');
    }
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

1;
