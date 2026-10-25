package Plugins::SpotOn::API::Credentials;

# Stored playback credentials of an account (credentials.json, librespot
# auth_type 1 = STORED_SPOTIFY_CREDENTIALS): where they live, whether they are
# valid, how a ZeroConf pairing or a dropped-in file becomes an account
# (installAccountCredentials), and the persistent per-account "needs playback
# authorization" flag.
#
# 85-14 (D-01): nothing mints credentials from an access token any more. The
# helper's token-login derivation and its spawn/poll/cooldown machinery went
# with the token path; since the Aug 10, 2026 Login5 provenance blockade only
# credentials the Spotify app hands over (ZeroConf pairing, discover folder)
# are accepted anyway. Spawning is async: Proc::Background plus
# Slim::Utils::Timers, never blocking calls -- LMS is single-threaded.

use strict;
use warnings;

use File::Spec::Functions qw(catdir catfile);
use Digest::MD5 qw(md5_hex);
use Encode ();
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

use constant CREDENTIALS_FILE => 'credentials.json';

# GH #147: persistent per-account "needs playback authorization" flag.
# Playback is broken for this account; the Web API (Login5/SpClient bearer) is
# not, so Browse/Search/Library stay usable while the flag is set.
use constant PLAYBACK_AUTH_FLAG_PREFIX => 'spoton_needs_playback_auth_';

# GH #147 plan 65-02: ZeroConf pairing (D-02 primary path). The user picks
# the announced "SpotOn Authorization (<library>)" device in their Spotify
# app while playing a track; the official app hands over Keymaster-provenance
# credentials that Login5 accepts. Poll every 2s; the Rust binary exits on
# its own after 900s (--discover-once self-timeout), 930s is our backstop
# margin before we force-kill a hung helper.
use constant PAIRING_POLL_INTERVAL   => 2;
use constant PAIRING_TIMEOUT_SECONDS => 930;
use constant PAIRING_STAGING_SUBDIR  => 'pairing-tmp';

# 85-10 (D-21): the pairing window the user actually gets. ~5 min, well below
# the helper's own 900 s --discover-once self-timeout; PAIRING_TIMEOUT_SECONDS
# stays as the absolute backstop for a hung helper. The window is the LAN
# exposure of the account-less pairing (T-85-13): anyone on the LAN can answer
# the announcement while it runs.
use constant PAIRING_WINDOW_SECONDS       => 300;
# 85-10 (3fd1632 replay guard): a start request arriving within this many
# seconds after a success is answered 'just_paired' -- a double-clicked or
# replayed POST must not announce a second pairing device right after the first.
use constant PAIRING_SUCCESS_HOLD_SECONDS => 10;
# 85-10 (T-85-14): a staged credentials.json is a few hundred bytes; anything at
# or above this is not one and is never parsed.
use constant MAX_STAGED_CREDENTIALS_BYTES => 65536;
# 85-11 (D-23): the drop folder for setups where the phone cannot reach the
# mDNS announcement (Docker, VLANs, pCP). A credentials.json produced elsewhere
# (`spoton --discover-once`) is copied to <cachedir>/spoton/__DISCOVER__/ and
# becomes an account at the next settings page load or plugin start.
use constant DISCOVER_SUBDIR => '__DISCOVER__';

my $log         = logger('plugin.spoton');
my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');

# Cache instance for the playback-auth flag (GH #147). M5: cache version
# lives in Plugin.pm (single source of truth). Plugin.pm is always compiled
# first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# GH #147 plan 65-02: single global pairing slot -- only ONE ZeroConf mDNS
# announcement at a time (one pairing name on the LAN). Keys:
#   proc, accountId (set on success only: the id comes from the credentials), stagingDir,
#   state, startedAt, finishedAt (success)
# state: idle | waiting | success | failed | timeout
my %_pairing;

# ============================================================
# Public class methods
# ============================================================

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
# Returns 1 only when credentials.json parses, has a username, the account
# entry's spotifyUserId is known, and the two differ. All absence/
# parse-failure/unknown-account cases return 0.
#
# This sub only DETECTS a mismatch; the repair is AccountMigration->migrateAccount
# (85-10), which re-keys the account to the credentials' id. Nothing deletes a
# credentials.json here, and directory-tree removal (TokenManager::removeAccount's
# remove_tree pattern) is the WRONG tool for a mismatch: it is for full account
# removal only.
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
# user must re-authorize playback (ZeroConf pairing / discover folder, plans
# 65-02 and 85-11). 'never'-TTL discipline: the flag survives restarts until
# a new pairing clears it.
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
# (LMS is single-threaded; one timer poll per pairing slot).
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

# startPairing($class)
# -> (1) on started, or (0, $reason) with reason in:
#    already_running | just_paired | no_binary | no_capability | spawn_failed
#
# 85-10 (D-05): account-less. There is no account to name before the pairing:
# the account is CREATED from the credentials the Spotify app hands over
# (installAccountCredentials). A legacy account argument is ignored.
sub startPairing {
    my ($class) = @_;

    # Single global slot: one mDNS announcement at a time.
    if (($_pairing{state} // '') eq 'waiting') {
        return (0, 'already_running');
    }

    # Replay guard: a start right after a success is a double click or a
    # replayed request, not a second pairing.
    if (($_pairing{state} // '') eq 'success'
        && defined $_pairing{finishedAt}
        && (time() - $_pairing{finishedAt}) < PAIRING_SUCCESS_HOLD_SECONDS) {
        return (0, 'just_paired');
    }

    require Plugins::SpotOn::Helper;
    my $helperPath = Plugins::SpotOn::Helper->get();
    unless ($helperPath) {
        $log->warn("Credentials: no SpotOn helper binary found for pairing");
        return (0, 'no_binary');
    }
    unless (Plugins::SpotOn::Helper->getCapability('discover-once')) {
        $log->warn("Credentials: SpotOn binary lacks discover-once capability -- "
            . "please update the SpotOn binary");
        return (0, 'no_capability');
    }

    my $name = $class->pairingDeviceName();

    # D-01 isolation: pairing output lands in a staging dir first, never in a
    # live account dir. Account-less: <cachedir>/spoton/pairing-tmp (not an
    # 8-hex name, so it can never collide with an account id).
    my $stagingDir = catdir($serverPrefs->get('cachedir'), 'spoton', PAIRING_STAGING_SUBDIR);
    unless (-d $stagingDir) {
        require File::Path;
        # IN-02: owner-only perms; mode is advisory on Windows (ignored).
        File::Path::make_path($stagingDir, { mode => 0700 });
    }
    chmod(0700, $stagingDir) if -d $stagingDir;
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
        # T-29-07/T-51-05 discipline: never the command line.
        $log->error("Credentials: pairing spawn failed");
        return (0, 'spawn_failed');
    }

    %_pairing = (
        proc       => $proc,
        stagingDir => $stagingDir,
        state      => 'waiting',
        startedAt  => time(),
    );

    main::INFOLOG && $log->info(
        "Credentials: ZeroConf pairing started (device name '$name', window "
        . PAIRING_WINDOW_SECONDS . "s)");

    Slim::Utils::Timers::setTimer(\%_pairing, Time::HiRes::time() + PAIRING_POLL_INTERVAL, \&_pollPairing);
    return (1);
}

# pairingStatus($class)
# -> { state => 'idle'|'waiting'|'success'|'failed'|'timeout',
#      accountId => $id_or_undef }
# accountId is set once the pairing created or refreshed an account (success).
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

# _pollPairing()
# Timer callback -- completion continuation for the --discover-once
# subprocess. Re-arms every PAIRING_POLL_INTERVAL seconds while the helper
# is alive and within the pairing window (D-21).
sub _pollPairing {
    # Guard against a stale timer firing after cancelPairing already reset
    # the slot (killTimers should prevent this, belt-and-braces).
    return unless ($_pairing{state} // '') eq 'waiting';

    my $proc    = $_pairing{proc};
    my $elapsed = time() - ($_pairing{startedAt} || 0);
    my $alive   = $proc && eval { $proc->alive };

    # D-21: the window is PAIRING_WINDOW_SECONDS; PAIRING_TIMEOUT_SECONDS is
    # the absolute backstop should the window constant ever be raised past it.
    my $deadline = PAIRING_WINDOW_SECONDS < PAIRING_TIMEOUT_SECONDS
        ? PAIRING_WINDOW_SECONDS : PAIRING_TIMEOUT_SECONDS;

    if ($alive && $elapsed < $deadline) {
        Slim::Utils::Timers::setTimer(\%_pairing, Time::HiRes::time() + PAIRING_POLL_INTERVAL, \&_pollPairing);
        return;
    }

    if ($alive) {
        # Window over and the helper is still announcing -- stop it.
        eval { $proc->die };
        $log->warn("Credentials: pairing window of " . $deadline . "s elapsed without a pairing -- stopped");
        $_pairing{state} = 'timeout';
        _cleanupPairingStaging();
        return;
    }

    # Helper exited. FILE-BASED success detection only (never stdout).
    my $stagingFile = catfile($_pairing{stagingDir}, CREDENTIALS_FILE);
    if (-f $stagingFile) {
        my ($ok, $result) = __PACKAGE__->installAccountCredentials($stagingFile, 'zeroconf');
        if ($ok) {
            $_pairing{state}      = 'success';
            $_pairing{accountId}  = $result;
            $_pairing{finishedAt} = time();
        } else {
            $_pairing{state} = 'failed';
        }
    } else {
        # Exit without a credentials file: binary failure or its own
        # 15-minute timeout (both exit 1, both leave no file).
        main::INFOLOG && $log->info("Credentials: pairing helper exited without credentials");
        $_pairing{state} = 'failed';
    }

    # Leftover staging must never be mistaken for live credentials.
    _cleanupPairingStaging();
}

# _accountIdForUsername($username)
# D-05: the account id is the first 8 hex of md5(credentials.json username).
# The single definition lives in AccountMigration->accountIdFor (85-10 Task 3);
# this sub delegates there.
sub _accountIdForUsername {
    my ($username) = @_;
    require Plugins::SpotOn::API::AccountMigration;
    return Plugins::SpotOn::API::AccountMigration->accountIdFor($username);
}

# installAccountCredentials($class, $stagingFile, $source)
# -> (1, $accountId) | (0, 'invalid_credentials' | 'install_failed')
#
# 85-10 (D-05/D-22/D-04): the ONE step that turns a staged librespot
# credentials.json into an account. The credentials are authoritative: the id
# and spotifyUserId come from their username (a differing user is a SECOND
# account, the same user refreshes the same id), nothing is compared against a
# pre-existing account. $source: 'zeroconf' | 'discover' | 'keymaster'.
#
# T-85-14: auth_type == 1, non-empty username/auth_data, file < 64 KB; the id is
# an md5 prefix and checked against /\A[0-9a-f]{8}\z/ before any path join --
# the username itself never reaches a path. T-85-15: dirs 0700, file 0600, logs
# only through _mask/_maskUser.
sub installAccountCredentials {
    my ($class, $stagingFile, $source) = @_;
    $source //= 'zeroconf';

    unless (defined $stagingFile && -f $stagingFile) {
        $log->warn("Credentials: no staged credentials to install");
        return (0, 'invalid_credentials');
    }
    my $size = -s $stagingFile;
    if (!defined $size || $size >= MAX_STAGED_CREDENTIALS_BYTES) {
        $log->warn("Credentials: staged credentials file has an implausible size -- not installed");
        return (0, 'invalid_credentials');
    }

    # Validate with the same rules as verifyCredentials: never trust the
    # subprocess exit code alone (Security V5/T-51-02).
    my $data = eval {
        open(my $fh, '<', $stagingFile) or die "open failed: $!";
        local $/;
        my $json = <$fh>;
        close($fh);
        from_json($json);
    };
    if ($@ || ref($data) ne 'HASH'
        || ($data->{auth_type} // -1) != 1
        || ref($data->{username}) || ref($data->{auth_data})
        || !($data->{username}  && length $data->{username})
        || !($data->{auth_data} && length $data->{auth_data})) {
        $log->warn("Credentials: staged pairing credentials invalid -- not installed");
        return (0, 'invalid_credentials');
    }

    my $username  = $data->{username};
    my $accountId = _accountIdForUsername($username);
    unless ($accountId =~ /\A[0-9a-f]{8}\z/) {
        $log->warn("Credentials: derived account id has an unexpected shape -- not installed");
        return (0, 'invalid_credentials');
    }

    # Install into the per-account layout (Pitfall 4: never the legacy flat dir).
    my $accountDir = _accountDir($accountId);
    unless (-d $accountDir) {
        require File::Path;
        File::Path::make_path($accountDir, { mode => 0700 });
    }
    chmod(0700, $accountDir) if -d $accountDir;
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

    # WR-10: the file now holds NEW credentials. Whatever Login5 concluded about
    # the old ones (an invalid_credentials verdict, a cached token) no longer
    # applies -- and must be gone before _storeAccountPrefs below asks
    # hasValidLogin for the D-06 active-account decision.
    eval {
        require Plugins::SpotOn::API::Login5;
        Plugins::SpotOn::API::Login5->forgetAccount($accountId);
        1;
    } or $log->warn("Credentials: could not reset the login5 state for account "
        . _mask($accountId) . ": $@");

    # Account entry: provenance first, then TokenManager's single writer for the
    # account record (display name, spotifyUserId, D-06 active-account rule).
    # An existing display name and sp_dc survive a re-pairing (D-04).
    my $accounts = $prefs->get('accounts') || {};
    my $entry    = $accounts->{$accountId} ||= {};
    my $existingName = (defined $entry->{displayName} && length $entry->{displayName})
        ? $entry->{displayName} : undef;
    $entry->{playbackCredSource} = $source;
    delete $entry->{needsPairing};    # 85-10 (D-02): a pairing answers the migration hint
    $prefs->set('accounts', $accounts);

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->_storeAccountPrefs(
        $accountId, $username, $existingName // $username, sub { }, { noSchedule => 1 });

    __PACKAGE__->clearNeedsPlaybackAuth($accountId);

    # Daemons start within ~2s instead of waiting for the 60s watchdog.
    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Unified::DaemonManager->scheduleInit();

    # W11 (85-16 / 85-17 read this from server.log): logged at WARN so it
    # reaches the default plugin.spoton level without a runtime DEBUG arm.
    $log->warn("Pairing: paired credentials installed for account " . _mask($accountId)
        . " (source $source)");

    # Display name from the profile (85-06). Async and best effort: the account
    # works under its username until (and unless) a name arrives.
    eval {
        require Plugins::SpotOn::API::SpClient;
        Plugins::SpotOn::API::SpClient->getDisplayName($accountId, sub {
            my ($name) = @_;
            return unless defined $name && !ref($name) && length $name;
            my $accts = $prefs->get('accounts') || {};
            return unless $accts->{$accountId};
            $accts->{$accountId}{displayName} = $name;
            $prefs->set('accounts', $accts);
        });
        1;
    } or main::INFOLOG && $log->info(
        "Credentials: display name lookup unavailable for account " . _mask($accountId));

    return (1, $accountId);
}

# intakeDiscoverFolder($class)
# -> (1, $accountId) imported | (0, 'none') nothing dropped
#    | (0, 'invalid_credentials' | 'install_failed') refused, the file is left in place
#
# 85-11 (D-23, T-85-19): turns <cachedir>/spoton/__DISCOVER__/credentials.json
# into an account via installAccountCredentials (source 'discover'): the same
# validation as the ZeroConf pairing (auth_type 1, non-empty fields, < 64 KB), the
# id from the md5 prefix of the username, chmod 0600 after the move. Only that one
# fixed path is ever read -- no caller-supplied path -- and a symlink (file or
# folder) is refused unfollowed. An account directory that already exists is
# refreshed in place; this sub never removes a directory tree (the former
# _autoSetupAccount, 6169a2b^, did). The empty folder is removed after an import.
#
# Idempotent and cheap when nothing is dropped, so the settings handler (BEFORE
# any other handling, 3fd1632 layer 2) and the plugin start can both call it.
sub intakeDiscoverFolder {
    my ($class) = @_;

    my $dir  = catdir($serverPrefs->get('cachedir'), 'spoton', DISCOVER_SUBDIR);
    my $file = catfile($dir, CREDENTIALS_FILE);

    if (-l $dir) {
        $log->warn("Credentials: the discover folder is a symlink -- refused");
        return (0, 'invalid_credentials');
    }
    return (0, 'none') unless -d $dir;

    if (-l $file) {
        $log->warn("Credentials: credentials.json in the discover folder is a symlink -- refused");
        return (0, 'invalid_credentials');
    }
    return (0, 'none') unless -e $file;
    unless (-f $file) {
        $log->warn("Credentials: credentials.json in the discover folder is not a regular file -- refused");
        return (0, 'invalid_credentials');
    }

    my ($ok, $result) = __PACKAGE__->installAccountCredentials($file, 'discover');
    unless ($ok) {
        # installAccountCredentials has logged the cause; the file stays so the
        # user can see and fix it (the settings page shows a notice).
        $log->warn("Credentials: the file in the discover folder was not imported ($result) -- left in place");
        return (0, $result);
    }

    rmdir $dir;    # succeeds only when empty -- exactly what we want
    main::INFOLOG && $log->info("Credentials: account " . _mask($result) . " imported from the discover folder");
    return (1, $result);
}

# _installPairedCredentials($accountId, $stagingDir, $source)
# Thin wrapper around installAccountCredentials for a staging DIRECTORY (its only
# caller is t/core/24; the pairing poll calls installAccountCredentials with the
# file). The legacy $accountId no longer decides the identity: the credentials
# do. -> (1) | (0, $reason)
sub _installPairedCredentials {
    my ($accountId, $stagingDir, $source) = @_;

    my ($ok, $result) = __PACKAGE__->installAccountCredentials(
        catfile($stagingDir, CREDENTIALS_FILE), $source);
    return (0, $result) unless $ok;

    if (defined $accountId && $result ne $accountId) {
        $log->warn("Credentials: installed credentials belong to account " . _mask($result)
            . ", not the requested " . _mask($accountId));
    }
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

# _accountDir($accountId)
# Account-scoped cache dir exclusively -- {cachedir}/spoton/{accountId}.
# Same directory Daemon.pm reads with -c once activeAccountId is set.
sub _accountDir {
    my ($accountId) = @_;
    return catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);
}

# _readCredsRaw($accountId)
# Read + JSON-parse credentials.json. Returns the hashref, or undef on any
# absence/parse failure or when the JSON is not an object (WR-02). No auth_type/field validation here -- that's
# verifyCredentials's job. accountMismatch only needs the raw username field.
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

    # WR-02: valid JSON that is not an object ([], "x", 42) would die in every
    # caller on $data->{...} under strict refs. Only an object is a credentials file.
    return undef if $@ || !$data || ref($data) ne 'HASH';
    return $data;
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
