package Plugins::SpotOn::API::TokenManager;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;

use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempfile);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# Constants
use constant TOKEN_EXPIRY_BUFFER   => 300;       # Refresh 5 min before expiry
use constant TOKEN_REFRESH_TIMER   => 45 * 60;   # 45 minute proactive refresh cycle
use constant DISCOVERY_TIMEOUT     => 60 * 15;   # 15 min Proc::Background watchdog
use constant DISCOVER_DIR          => '__DISCOVER__'; # temp dir during ZeroConf
use constant TOKEN_FETCH_TIMEOUT   => 15;        # H2: watchdog for --get-token subprocess
use constant TOKEN_FETCH_POLL      => 0.2;       # H2: async poll interval (seconds)
use constant SPOTIFY_ME_URL        => 'https://api.spotify.com/v1/me';
# Import SPOTON_DEFAULT_CLIENT_ID from Client.pm (single source of truth — D-04).
# Using require + direct call avoids circular compile-time dependency
# (TokenManager is require'd by Client.pm at runtime via _doFlavouredRequest).
use constant SPOTON_DEFAULT_CLIENT_ID => do {
    require Plugins::SpotOn::API::Client;
    Plugins::SpotOn::API::Client::SPOTON_DEFAULT_CLIENT_ID();
};

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new('spoton', 4);

# Package-level discovery process reference
my $discoveryProc;

# H3: In-flight token fetch coalescing — keyed by "accountId|flavor".
# Each value is an arrayref of pending callbacks. Concurrent cache misses for
# the same key share a single --get-token subprocess.
my %tokenFetchInflight;

# ============================================================
# Public class methods
# ============================================================

# getToken($class, $accountId, $flavorOrCb, [$cb])
# Checks cache first; falls back to _fetchKeymasterToken on miss.
# Flavor: 'own' (eigene Client-ID) | 'bundled' (librespot-Default-ID).
# Backward-compatible: getToken($id, $cb) maps to flavor='own'.
sub getToken {
    my ($class, $accountId, $flavorOrCb, $cb) = @_;

    my $flavor;
    if (ref $flavorOrCb eq 'CODE') {
        # Backward-compat: old callers without flavor parameter
        $cb     = $flavorOrCb;
        $flavor = 'own';
    } else {
        $flavor = $flavorOrCb // 'own';
    }

    my $cacheKey = "spoton_token_${accountId}_${flavor}";
    if (my $cached = $cache->get($cacheKey)) {
        main::INFOLOG && $log->info("TokenManager: cache hit for account $accountId ($flavor)");
        $cb->($cached);
        return;
    }

    $class->_fetchKeymasterToken($accountId, $flavor, $cb);
}

# removeAccount($class, $accountId)
# Removes account from prefs and cache. Deletes both flavor keys and legacy key.
sub removeAccount {
    my ($class, $accountId) = @_;

    # Remove from prefs
    my $accounts = $prefs->get('accounts') || {};
    delete $accounts->{$accountId};
    $prefs->set('accounts', $accounts);

    # Clear flavor token cache keys (both new keys + legacy migration key):
    #   spoton_token_${accountId}_own     — own Client-ID flavor
    #   spoton_token_${accountId}_bundled — bundled librespot-Default-ID flavor
    $cache->remove("spoton_token_${accountId}_own");
    $cache->remove("spoton_token_${accountId}_bundled");
    $cache->remove("spoton_token_$accountId");  # legacy key — safe migration net

    # M2: Remove the account's credentials directory from disk — a "removed"
    # account must not leave its Spotify credentials.json behind.
    # Same dir _fetchKeymasterToken uses as --cache for this accountId.
    # Safety: only the per-ACCOUNT dir, never the shared spoton cache root —
    # assert the path ends in the accountId segment before removing.
    if ($accountId) {
        my $serverPrefs = preferences('server');
        my $acctDir = catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);
        if (-d $acctDir && $acctDir =~ m{[/\\]\Q$accountId\E$}) {
            require File::Path;
            if (eval { File::Path::remove_tree($acctDir); 1 }) {
                main::INFOLOG && $log->info("TokenManager: removed credentials dir for account $accountId");
            } else {
                $log->warn("TokenManager: failed to remove credentials dir for $accountId: $@");
            }
        }
    }

    # Clear active account if it was this one
    my $active = $prefs->get('activeAccount') || '';
    if ($active eq $accountId) {
        $prefs->set('activeAccount', '');

        # Stop all daemons — they're running with stale credentials
        if ($INC{'Plugins/SpotOn/Unified/DaemonManager.pm'}) {
            require Plugins::SpotOn::Unified::DaemonManager;
            Plugins::SpotOn::Unified::DaemonManager->shutdown();
            Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
        }
    }

    main::INFOLOG && $log->info("TokenManager: account $accountId removed");
}

# getAccountIds($class)
# Returns list of known account IDs.
sub getAccountIds {
    my ($class) = @_;
    my $accounts = $prefs->get('accounts') || {};
    return keys %{$accounts};
}

# getActiveAccountName($class, $client)
# Returns displayName of active account, or undef.
sub getActiveAccountName {
    my ($class, $client) = @_;

    my $activeId;
    if ($client) {
        $activeId = $prefs->client($client)->get('activeAccount');
    }
    $activeId ||= $prefs->get('activeAccount');

    return undef unless $activeId;

    my $accounts = $prefs->get('accounts') || {};
    return $accounts->{$activeId} ? $accounts->{$activeId}{displayName} : undef;
}

# refreshAllTokens($class)
# Refreshes own-flavor tokens for all accounts and re-arms the 45-minute timer.
# Bundled tokens are lazy-only (on-demand) — no proactive refresh (D-Discretion).
sub refreshAllTokens {
    my ($class) = @_;

    my $accounts = $prefs->get('accounts') || {};
    my @ids = $class->getAccountIds();
    for my $id (@ids) {
        my $acct = $accounts->{$id} || {};
        my $needsDisplayName = $acct->{displayName}
            && $acct->{spotifyUserId}
            && $acct->{displayName} eq $acct->{spotifyUserId};

        if ($needsDisplayName) {
            $class->_fetchDisplayName($id, $acct->{spotifyUserId}, sub {
                main::INFOLOG && $log->info("TokenManager: updated displayName for $id");
            });
        } else {
            $class->_fetchKeymasterToken($id, 'own', sub {
                my $token = shift;
                main::INFOLOG && $log->info("TokenManager: refreshed token for account $id (own)")
                    if $token;
                unless ($token) {
                    $log->error("TokenManager: failed to refresh token for account $id (own)");
                    if ($INC{'Plugins/SpotOn/Status.pm'}) {
                        Plugins::SpotOn::Status->recordError('error', 'Token', "refresh failed for $id");
                    }
                }
            });
        }
    }

    # Re-arm timer (AUTH-03 timer continuity)
    Slim::Utils::Timers::killTimers($class, \&refreshAllTokens);
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + TOKEN_REFRESH_TIMER,
        \&refreshAllTokens
    );
}

# startDiscovery($class)
# Manages ZeroConf discovery process via librespot --discover-once.
# T-04.3-08: Always cleans __DISCOVER__ dir before starting (stale credential prevention).
# T-04.3-09: DISCOVERY_TIMEOUT watchdog timer kills process after 15 min.
sub startDiscovery {
    my ($class) = @_;

    my $serverPrefs = preferences('server');
    my $discoverDir = catdir($serverPrefs->get('cachedir'), 'spoton', DISCOVER_DIR);
    my $credsFile = catfile($discoverDir, 'credentials.json');
    if (-f $credsFile) {
        # Stale credentials from a failed auto-setup — clean up so discovery can proceed
        $log->warn("TokenManager: removing stale credentials.json from __DISCOVER__");
        require File::Path;
        File::Path::remove_tree($discoverDir);
    }

    # Stop existing discovery if running
    if ($discoveryProc && $discoveryProc->alive()) {
        $discoveryProc->die();
        $discoveryProc = undef;
    }

    require Plugins::SpotOn::Helper;
    my ($helperPath) = Plugins::SpotOn::Helper->get();
    unless ($helperPath) {
        $log->error("TokenManager: cannot start discovery — binary not found");
        if ($INC{'Plugins/SpotOn/Status.pm'}) {
            Plugins::SpotOn::Status->recordError('error', 'Token', "binary not found for discovery");
        }
        return;
    }

    # T-04.3-08: Clean up stale __DISCOVER__ dir (RESEARCH Pitfall 2)
    if (-d $discoverDir) {
        require File::Path;
        File::Path::remove_tree($discoverDir);
    }
    require File::Path;
    File::Path::make_path($discoverDir);

    my $deviceName = _getLmsServerName();

    main::INFOLOG && $log->info(
        "TokenManager: starting ZeroConf discovery as '$deviceName', cache=$discoverDir");

    require Proc::Background;
    $discoveryProc = Proc::Background->new(
        { 'die_upon_destroy' => 0 },
        $helperPath,
        '-n', $deviceName,
        '--cache', $discoverDir,
        '--discover-once',
    );

    unless ($discoveryProc && $discoveryProc->alive()) {
        $log->error("TokenManager: discovery process failed to start");
        if ($INC{'Plugins/SpotOn/Status.pm'}) {
            Plugins::SpotOn::Status->recordError('error', 'Token', "discovery process failed to start");
        }
        $discoveryProc = undef;
        return;
    }

    main::INFOLOG && $log->info(
        "TokenManager: discovery process started (PID " . $discoveryProc->pid() . ")");
    $log->warn("[DIAG] discovery_start: pid=" . $discoveryProc->pid() . " device_name=$deviceName cache=$discoverDir") if $prefs->get('diagnosticMode');

    # T-04.3-09: Watchdog timer — kill discovery after DISCOVERY_TIMEOUT
    Slim::Utils::Timers::killTimers($class, \&stopDiscovery);
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + DISCOVERY_TIMEOUT,
        \&stopDiscovery
    );
}

# stopDiscovery($class)
# Kills discovery process if alive and cleans up watchdog timer.
# T-04.3-08: Cleans __DISCOVER__ if no credentials.json inside.
sub stopDiscovery {
    my ($class) = @_;

    Slim::Utils::Timers::killTimers($class, \&stopDiscovery);

    if ($discoveryProc && $discoveryProc->alive()) {
        main::INFOLOG && $log->info("TokenManager: stopping discovery process");
        $discoveryProc->die();
    }
    $discoveryProc = undef;

    # T-04.3-08: Clean __DISCOVER__ dir if no credentials.json was written
    my $serverPrefs = preferences('server');
    my $discoverDir = catdir($serverPrefs->get('cachedir'), 'spoton', DISCOVER_DIR);
    my $credsFile   = catfile($discoverDir, 'credentials.json');

    if (-d $discoverDir && !-f $credsFile) {
        require File::Path;
        File::Path::remove_tree($discoverDir);
        main::INFOLOG && $log->info("TokenManager: cleaned up empty __DISCOVER__ dir");
    }
}

# isDiscoveryRunning($class)
# Returns boolean: true if discovery process is running.
# Consumed by Settings.pm _isDiscoveryRunning() (Plan 03).
sub isDiscoveryRunning {
    my ($class) = @_;
    return $discoveryProc && $discoveryProc->alive() ? 1 : 0;
}

# autoStartDiscoveryIfNeeded($class)
# D-01: Checks if any account has credentials.json in its cache subdir.
# If no accounts have credentials, calls startDiscovery.
sub autoStartDiscoveryIfNeeded {
    my ($class) = @_;

    my $serverPrefs = preferences('server');
    my $baseDir     = catdir($serverPrefs->get('cachedir'), 'spoton');

    my @accountIds = $class->getAccountIds();

    for my $id (@accountIds) {
        my $credsFile = catfile($baseDir, $id, 'credentials.json');
        if (-f $credsFile) {
            main::INFOLOG && $log->info(
                "TokenManager: credentials found for account $id — skipping auto-discovery");
            return;
        }
    }

    main::INFOLOG && $log->info(
        "TokenManager: no credentials found — auto-starting ZeroConf discovery");
    $class->startDiscovery();
}

# _setupAccountFromCredentials($class, $cb)
# Called after discovery completes (from Settings AJAX flow).
# Reads credentials.json, derives accountId, renames __DISCOVER__ dir,
# sets chmod 0700, fetches display_name, stores in prefs.
# T-04.3-07: chmod 0700 on account dir (credential storage security).
sub _setupAccountFromCredentials {
    my ($class, $cb) = @_;

    my $serverPrefs = preferences('server');
    my $baseDir     = catdir($serverPrefs->get('cachedir'), 'spoton');
    my $discoverDir = catdir($baseDir, DISCOVER_DIR);
    my $credsFile   = catfile($discoverDir, 'credentials.json');

    open(my $fh, '<', $credsFile) or do {
        $log->error("TokenManager: credentials.json not readable: $!");
        $cb->(undef);
        return;
    };
    local $/;
    my $json = <$fh>;
    close $fh;

    my $creds = eval { from_json($json) };
    if ($@ || !$creds->{username}) {
        $log->error("TokenManager: credentials.json parse failed: $@");
        $cb->(undef);
        return;
    }

    my $spotifyUserId = $creds->{username};
    # accountId pattern: MD5 of spotify user_id (stable across username changes)
    my $accountId = substr(md5_hex($spotifyUserId), 0, 8);
    $log->warn("[DIAG] discovery_credential: account=" . substr($accountId, 0, 4) . "**** spotify_user=" . substr($spotifyUserId, 0, 4) . "****") if $prefs->get('diagnosticMode');

    # Dir-rename: __DISCOVER__ -> {accountId}
    my $finalDir = catdir($baseDir, $accountId);
    if (-d $finalDir) {
        require File::Path;
        File::Path::remove_tree($finalDir);
    }
    require File::Copy;
    File::Copy::move($discoverDir, $finalDir) or do {
        $log->error("TokenManager: dir rename failed: $!");
        $cb->(undef);
        return;
    };

    # T-04.3-07: Secure credential dir permissions
    chmod(0700, $finalDir);

    # Fetch display_name via --get-token + /me
    $class->_fetchDisplayName($accountId, $spotifyUserId, $cb);
}

# ============================================================
# Private methods
# ============================================================

# _fetchKeymasterToken($class, $accountId, $flavorOrCb, [$cb])
# Spawns "spoton --get-token [--client-id X] --cache {cachedir}/spoton/{accountId}".
# Flavor dispatch: 'bundled' = no --client-id; 'own' = own Client-ID from prefs/constant.
# Backward-compatible: _fetchKeymasterToken($id, $cb) maps to flavor='own'.
# H2: Non-blocking — Proc::Background + timer polling with a 15s watchdog.
#     A hung librespot binary can no longer freeze the LMS event loop.
#     Argument LIST spawn (no shell) makes manual quoting unnecessary (Windows-safe).
# H3: Concurrent fetches for the same account/flavor coalesce to one subprocess.
# T-04.3-06: Never logs $result->{accessToken} — logs only accountId, flavor, and TTL.
sub _fetchKeymasterToken {
    my ($class, $accountId, $flavorOrCb, $cb) = @_;

    my $flavor;
    if (ref $flavorOrCb eq 'CODE') {
        # Backward-compat: internal callers without flavor parameter
        $cb     = $flavorOrCb;
        $flavor = 'own';
    } else {
        $flavor = $flavorOrCb // 'own';
    }

    # H3: Coalesce concurrent fetches for the same account/flavor.
    my $inflightKey = "${accountId}|${flavor}";
    if ($tokenFetchInflight{$inflightKey}) {
        main::INFOLOG && $log->info("TokenManager: coalescing token fetch for $accountId ($flavor)");
        push @{ $tokenFetchInflight{$inflightKey} }, $cb;
        return;
    }
    $tokenFetchInflight{$inflightKey} = [$cb];

    # Drains ALL queued callbacks with the same result. The key is deleted
    # BEFORE invoking callbacks so a callback that re-triggers a fetch does
    # not self-coalesce into a dead entry.
    my $resolve = sub {
        my ($token) = @_;
        my $queue = delete $tokenFetchInflight{$inflightKey} || [];
        $_->($token) for @{$queue};
    };

    require Plugins::SpotOn::Helper;
    my ($helper) = Plugins::SpotOn::Helper->get();
    unless ($helper) {
        $log->error("TokenManager: binary not found for account $accountId ($flavor)");
        $resolve->(undef);
        return;
    }

    my $serverPrefs = preferences('server');
    my $cacheDir    = catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);

    my $usedClientId;
    if ($flavor eq 'bundled') {
        $usedClientId = SPOTON_DEFAULT_CLIENT_ID;
    } else {
        my $ownClientId = $prefs->get('clientId');
        $usedClientId = $ownClientId || SPOTON_DEFAULT_CLIENT_ID;
        if (!$ownClientId) {
            main::INFOLOG && $log->info("TokenManager: flavor=own has no custom client ID — using bundled ID (fallback will be identical)");
        }
    }

    # H2: Argument LIST spawn — no shell involved, so no quoting/escaping needed
    # (replaces the old T-04.3-05 manual shell-quoting, which is now obsolete).
    my @args = ($helper, '--get-token', '--cache', $cacheDir, '--client-id', $usedClientId);

    my $maskedId = substr($usedClientId, 0, 8) . '...';
    main::INFOLOG && $log->info("TokenManager: --get-token for account $accountId ($flavor, client_id=$maskedId)");

    # Tempfile for stdout+stderr capture (same pattern as Daemon.pm port capture).
    # stderr is merged into the same file to preserve Keymaster error diagnostics.
    my $tmpDir = catdir($serverPrefs->get('cachedir'), 'spoton');
    unless (-d $tmpDir) {
        require File::Path;
        eval { File::Path::make_path($tmpDir) };
    }
    my ($out_fh, $out_tmpfile);
    eval {
        ($out_fh, $out_tmpfile) = tempfile('spoton-token-XXXX',
            DIR    => $tmpDir,
            UNLINK => 0,
        );
    };
    if ($@ || !$out_tmpfile) {
        $log->error("TokenManager: tempfile() failed for token capture: $@");
        $resolve->(undef);
        return;
    }
    close($out_fh);

    require Proc::Background;

    # Pitfall 7 (see Daemon.pm): LMS ties STDERR to Slim::Utils::Log::Trapper —
    # untie around the fork so Proc::Background can dup2 it in the child.
    my $had_stderr_tie = defined tied(*STDERR);
    untie *STDERR if $had_stderr_tie;

    my $proc;
    eval {
        $proc = Proc::Background->new(
            { 'die_upon_destroy' => 1,
              stdout => $out_tmpfile,
              stderr => $out_tmpfile },
            @args,
        );
    };

    tie *STDERR, 'Slim::Utils::Log::Trapper' if $had_stderr_tie;

    if ($@ || !$proc) {
        $log->error("TokenManager: failed to spawn --get-token for $accountId ($flavor): $@");
        unlink $out_tmpfile;
        $resolve->(undef);
        return;
    }

    my $deadline = Time::HiRes::time() + TOKEN_FETCH_TIMEOUT;

    # Completion continuation — runs the pre-existing output-parsing logic on
    # the captured tempfile content, then resolves the coalescing queue.
    my $finish = sub {
        my ($timedOut) = @_;

        if ($timedOut) {
            # H2 watchdog: bounds the worst case at TOKEN_FETCH_TIMEOUT seconds
            # of ASYNC waiting instead of an infinite SYNCHRONOUS freeze.
            $proc->die if $proc->alive;
            $log->error("TokenManager: --get-token timed out after " . TOKEN_FETCH_TIMEOUT . "s for $accountId ($flavor, client_id=$maskedId)");
            if ($INC{'Plugins/SpotOn/Status.pm'}) {
                Plugins::SpotOn::Status->recordError('error', 'Token', "get-token timed out for $accountId ($flavor)");
            }
            $log->warn("[DIAG] token_refresh_timeout: account=" . substr($accountId, 0, 4) . "**** flavor=$flavor") if $prefs->get('diagnosticMode');
            unlink $out_tmpfile;
            $resolve->(undef);
            return;
        }

        my $exit = $proc->wait >> 8;
        my $output = '';
        if (open(my $ofh, '<', $out_tmpfile)) {
            local $/;
            $output = <$ofh> // '';
            close($ofh);
        }
        unlink $out_tmpfile;

        if ($exit != 0 || !$output) {
            $log->error("TokenManager: --get-token failed for $accountId ($flavor, client_id=$maskedId) (exit $exit)");

            if ($output) {
                # Extract Keymaster HTTP status from librespot's MercuryResponse debug format
                if ($output =~ /status_code:\s*(\d+)/) {
                    $log->error("TokenManager: keymaster_status: HTTP $1 for client_id=$maskedId");
                }
                # Decode Keymaster error payload from byte array (e.g. payload: [[123, 34, ...]])
                if ($output =~ /payload:\s*\[\[([0-9,\s]+)\]\]/) {
                    my $payloadJson = join('', map { chr($_) } split(/,\s*/, $1));
                    my $payload = eval { from_json($payloadJson) };
                    if ($payload && $payload->{errorDescription}) {
                        $log->error("TokenManager: keymaster_error: code=" . ($payload->{code} // '?')
                            . " message=\"$payload->{errorDescription}\" (client_id=$maskedId)");
                    }
                }
            }

            if ($INC{'Plugins/SpotOn/Status.pm'}) {
                Plugins::SpotOn::Status->recordError('error', 'Token', "get-token failed for $accountId ($flavor)");
            }
            $log->warn("[DIAG] token_refresh_fail: account=" . substr($accountId, 0, 4) . "**** flavor=$flavor exit=$exit") if $prefs->get('diagnosticMode');
            $resolve->(undef);
            return;
        }

        # The token JSON is the last stdout line; stderr noise may precede it.
        # from_json on the full merged output works when librespot is quiet;
        # fall back to the last JSON-looking line if the full parse fails.
        my $result = eval { from_json($output) };
        if ($@ || !$result || !$result->{accessToken}) {
            for my $line (reverse split /\r?\n/, $output) {
                next unless $line =~ /^\s*\{/;
                $result = eval { from_json($line) };
                last if $result && $result->{accessToken};
            }
        }
        if (!$result || !$result->{accessToken}) {
            $log->error("TokenManager: JSON parse error on --get-token for $accountId ($flavor): $@");
            $log->warn("[DIAG] token_parse_fail: account=" . substr($accountId, 0, 4) . "**** flavor=$flavor") if $prefs->get('diagnosticMode');
            $resolve->(undef);
            return;
        }

        # T-04.3-06: Log only accountId, flavor, and TTL — never the token value
        $class->_cacheToken($accountId, $flavor, $result->{accessToken}, $result->{expiresIn});
        $log->warn("[DIAG] token_refresh_ok: account=" . substr($accountId, 0, 4) . "**** flavor=$flavor ttl=" . ($result->{expiresIn} || 'unknown') . "s") if $prefs->get('diagnosticMode');
        $resolve->($result->{accessToken});
    };

    # H2: Async polling — check every TOKEN_FETCH_POLL seconds whether the
    # subprocess has exited; watchdog fires at $deadline.
    my $pollCb;
    $pollCb = sub {
        unless ($proc->alive) {
            undef $pollCb;   # break closure self-reference cycle
            $finish->(0);
            return;
        }
        if (Time::HiRes::time() >= $deadline) {
            undef $pollCb;
            $finish->(1);
            return;
        }
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + TOKEN_FETCH_POLL, $pollCb);
    };
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + TOKEN_FETCH_POLL, $pollCb);
}

# _fetchDisplayName($class, $accountId, $spotifyUserId, $cb)
# Gets token via _fetchKeymasterToken (own flavor), then GET /me for display_name.
# Fallback: uses spotifyUserId directly if /me fails.
sub _fetchDisplayName {
    my ($class, $accountId, $spotifyUserId, $cb) = @_;

    $class->_fetchKeymasterToken($accountId, 'own', sub {
        my $accessToken = shift;

        unless ($accessToken) {
            # Fallback: use spotifyUserId as display name
            $log->warn("TokenManager: could not get token for /me — using userId as displayName");
            $class->_storeAccountPrefs($accountId, $spotifyUserId, $spotifyUserId, $cb);
            return;
        }

        # Need SimpleAsyncHTTP for this single /me call
        require Slim::Networking::SimpleAsyncHTTP;

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http    = shift;
                my $profile = eval { from_json($http->content) };
                if ($@ || !$profile) {
                    $log->warn("TokenManager: /me JSON parse failed for $accountId — using userId");
                    $class->_storeAccountPrefs($accountId, $spotifyUserId, $spotifyUserId, $cb);
                    return;
                }
                my $displayName = $profile->{display_name} || $spotifyUserId || 'Unknown';
                $class->_storeAccountPrefs($accountId, $spotifyUserId, $displayName, $cb);
            },
            sub {
                my ($http, $error) = @_;
                $log->warn("TokenManager: /me HTTP error for $accountId: $error — using userId");
                $class->_storeAccountPrefs($accountId, $spotifyUserId, $spotifyUserId, $cb);
            },
            { timeout => 30 }
        )->get(
            SPOTIFY_ME_URL,
            'Authorization' => "Bearer $accessToken",
            'Accept'        => 'application/json',
        );
    });
}

# _storeAccountPrefs($class, $accountId, $spotifyUserId, $displayName, $cb)
# Stores account in prefs, sets activeAccount if none, calls $cb->($accountId).
sub _storeAccountPrefs {
    my ($class, $accountId, $spotifyUserId, $displayName, $cb) = @_;

    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$accountId} = {
        displayName   => $displayName,
        spotifyUserId => $spotifyUserId,
    };
    $prefs->set('accounts', $accounts);

    # Set as active account if none currently set
    my $needsDaemonStart = !$prefs->get('activeAccount');
    unless ($prefs->get('activeAccount')) {
        $prefs->set('activeAccount', $accountId);
    }

    main::INFOLOG && $log->info(
        "TokenManager: account $accountId stored (displayName=$displayName)");

    # Trigger daemon start when a fresh account was activated
    if ($needsDaemonStart) {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
    }
    $log->warn("[DIAG] account_stored: account=" . substr($accountId, 0, 4) . "**** display_name=$displayName is_active=" . (($prefs->get('activeAccount') || '') eq $accountId ? 1 : 0)) if $prefs->get('diagnosticMode');
    $cb->($accountId);
}

# _cacheToken($class, $accountId, $flavor, $accessToken, $expiresIn)
# Caches the access token under flavor-specific key with TTL = expiresIn - TOKEN_EXPIRY_BUFFER.
# T-04.3-06: Never logs the token value itself — only accountId, flavor, and TTL.
sub _cacheToken {
    my ($class, $accountId, $flavor, $accessToken, $expiresIn) = @_;

    $expiresIn //= 3600;
    my $ttl = $expiresIn > TOKEN_EXPIRY_BUFFER
        ? $expiresIn - TOKEN_EXPIRY_BUFFER
        : ($expiresIn > 60 ? $expiresIn : 60);

    $cache->set("spoton_token_${accountId}_${flavor}", $accessToken, $ttl);
    main::INFOLOG && $log->info(
        "TokenManager: token cached for account $accountId ($flavor), TTL ${ttl}s");
}

# _getLmsServerName()
# Returns LMS server name from preferences('server')->get('libraryname'),
# with Sys::Hostname fallback, truncated to 60 chars.
# Per RESEARCH Pattern 5: Spotify device name limit.
sub _getLmsServerName {
    my $serverPrefs = preferences('server');
    my $name = $serverPrefs->get('libraryname') || '';
    unless ($name) {
        require Sys::Hostname;
        $name = eval { Sys::Hostname::hostname() } || 'Lyrion Music Server';
    }
    return substr($name, 0, 60);
}

1;
