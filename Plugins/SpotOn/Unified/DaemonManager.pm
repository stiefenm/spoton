package Plugins::SpotOn::Unified::DaemonManager;

use strict;
use warnings;

use File::Basename qw(basename);
use File::Glob qw(bsd_glob);
use File::Spec::Functions qw(catdir catfile);
use Scalar::Util qw(blessed);

use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;

use Plugins::SpotOn::Plugin;
use Plugins::SpotOn::Unified::Daemon;

# Buffer the helper initialization to prevent a flurry of activity when
# players connect/disconnect.
use constant DAEMON_INIT_DELAY        => 2;
use constant DAEMON_WATCHDOG_INTERVAL => 60;

# Fast poll interval for unified daemons — keeps crash-silence window <=5s
use constant STREAM_WATCHDOG_INTERVAL => 5;

# Delay before cleaning up orphaned log files (seconds after init)
# Gives players time to reconnect after LMS restart before their logs are deleted.
use constant ORPHAN_LOG_CLEANUP_DELAY => 30;

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

my %helperInstances;

# H8: crash-loop flags are reset ONCE per LMS process start (fresh chance after
# an LMS restart) — initHelpers is re-invoked by the 60s watchdog, and resetting
# on every invocation would wipe the crash-loop protection 60s after it engages.
my $crashLoopFlagsWereReset = 0;

# H9: health-restart rate-limit timestamps keyed by daemon MAC. Stored at
# package level because stopHelper DELETES the Daemon object — an object-level
# timestamp would be erased by the very restart it is rate-limiting.
my %lastHealthRestart;

# M10: subscription coderefs, kept so shutdown() can unsubscribe them —
# anonymous subs passed inline can never be unregistered and accumulate
# across plugin re-inits.
my ($clientSubRef, $syncSubRef);

# _isConnectEnabled($client)
# Returns true if the per-player (or global fallback) Spotify Connect toggle is on.
# Used by Unified::Daemon::start() to determine whether to pass --enable-connect to the
# Rust binary. Does NOT gate whether the daemon starts at all — that is credential-gated.
sub _isConnectEnabled {
    my $client = shift;
    return $prefs->client($client)->get('enableSpotifyConnect')
        // $prefs->get('enableSpotifyConnect');
}

# resolvePassthroughForClient($class, $client)
# Single source of truth for OGG passthrough decisions (D-04/D-05/D-08).
# Called by Daemon.pm (--passthrough flag) and Plugin.pm (_typeString display).
# Returns 1 if the player should receive raw Ogg/Vorbis, 0 for PCM.
sub resolvePassthroughForClient {
    my ($class, $client) = @_;
    return 0 unless $client;

    # Per-client resolution (used for individual check and sync-group iteration)
    my $resolveOne = sub {
        my ($c) = @_;
        my $fmt = $prefs->client($c)->get('streamFormat')
                  || $prefs->client($c)->get('connectOggOverride')
                  || 'auto';

        # D-05: explicit format override — trust the user's choice directly
        return 1 if $fmt eq 'ogg';
        return 0 if $fmt =~ /^(?:pcm|flac|mp3)$/;

        # auto (D-04): both conditions must be true
        # 1. Binary has passthrough capability (passthrough-decoder feature compiled in)
        require Plugins::SpotOn::Helper;
        return 0 unless Plugins::SpotOn::Helper->getCapability('passthrough');
        # 2. Player announces ogg in its supported formats
        return 0 unless grep { $_ eq 'ogg' } $c->formats;

        return 1;
    };

    my $result = $resolveOne->($client);

    # D-08: sync-group aggregation — PCM fallback if ANY member can't do OGG
    if ($result && $client->isSynced() && $client->master) {
        my $master = $client->master;
        $result = $resolveOne->($master) if "$master" ne "$client";
        if ($result) {
            for my $slave (Slim::Player::Sync::slaves($master)) {
                next if "$slave" eq "$client";  # skip self (already resolved above)
                unless ($resolveOne->($slave)) {
                    $result = 0;
                    last;
                }
            }
        }
    }

    return $result ? 1 : 0;
}

sub scheduleInit {
    my $class = __PACKAGE__;
    Slim::Utils::Timers::killTimers($class, \&initHelpers);
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers);
}

sub init {
    my $class = shift;

    # Debounced init on client connect/disconnect (2s delay to batch events)
    # M10: coderef stored so shutdown() can unsubscribe it.
    $clientSubRef = sub {
        Slim::Utils::Timers::killTimers($class, \&initHelpers);
        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers);
    };
    Slim::Control::Request::subscribe($clientSubRef, [['client'], ['new', 'disconnect']]);

    # Differential restart on sync changes.
    # Stop each daemon via stopForSync (clears stream port, resets backoff) then
    # re-init with a 0.1s micro-delay instead of DAEMON_INIT_DELAY (2s), so
    # Spirc re-registration (when Connect is enabled) happens fast enough for the
    # Spotify app to see the refreshed device within ~10s.
    # M10: coderef stored so shutdown() can unsubscribe it.
    $syncSubRef = sub {
        my $request = shift;

        return if $request->isNotCommand([['sync']]);

        my $client = $request->client();
        my @affected;
        if ($client) {
            push @affected, $client->id;
            if ($client->isSynced() && $client->master) {
                push @affected, $client->master->id;
                push @affected, map { $_->id } Slim::Player::Sync::slaves($client->master);
            }
        }

        main::INFOLOG && $log->is_info && $log->info(
            "Sync group changed - restarting affected Unified daemons: " . join(', ', @affected)
        );

        Slim::Utils::Timers::killTimers($class, \&initHelpers);

        for my $clientId (@affected) {
            $helperInstances{$clientId}->stopForSync() if $helperInstances{$clientId};
        }

        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 0.1, \&initHelpers);
    };
    Slim::Control::Request::subscribe($syncSubRef, [['sync']]);

    # Per-player Connect toggle reaction is handled by Settings.pm calling
    # initHelpers() directly after saving — setChange on global prefs namespace
    # doesn't fire for per-player prefs (WR-01 fix).

    # Immediate initial check — player may already be connected before listeners registered
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 0.5, \&initHelpers);

    # Delayed cleanup of orphaned unified log files from players no longer connected.
    # 30s delay ensures players have had time to reconnect after LMS restart.
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + ORPHAN_LOG_CLEANUP_DELAY, \&_cleanupOrphanedLogs);
}

sub initHelpers {
    my $class = __PACKAGE__;

    Slim::Utils::Timers::killTimers($class, \&initHelpers);

    # Reset crash-loop flags BEFORE evaluating daemons. Done here (not in
    # init()) because players may not be connected yet when init() runs at startup.
    # H8: runs ONCE per LMS process — initHelpers is re-invoked by the 60s
    # watchdog, and an unconditional reset would wipe the crash-loop cooldown
    # 60s after it engages, letting the daemon crash-loop forever.
    unless ($crashLoopFlagsWereReset) {
        for my $client (Slim::Player::Client::clients()) {
            if ($prefs->client($client)->get('discoveryDisabledByCrashLoop')) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Resetting discoveryDisabledByCrashLoop for " . $client->id
                );
                $prefs->client($client)->set('discoveryDisabledByCrashLoop', 0);
            }
        }
        if ($prefs->get('disableDiscovery')) {
            main::INFOLOG && $log->is_info && $log->info(
                "Resetting global disableDiscovery flag (crash-loop fallback)"
            );
            $prefs->set('disableDiscovery', 0);
        }
        $crashLoopFlagsWereReset = 1;
    }

    main::DEBUGLOG && $log->is_debug && $log->debug("Checking SpotOn Unified helper daemons...");

    # Shut down orphaned instances (players that disconnected)
    $class->shutdown('inactive-only');

    # Deduplicate by MAC: LMS may return multiple client objects for the same
    # MAC address (e.g. UPnP bridge + squeezelite sharing a MAC). Process
    # synced clients first so that sync group membership is detected before
    # standalone duplicates are evaluated.
    my @clients = sort {
        ($b->isSynced() ? 1 : 0) <=> ($a->isSynced() ? 1 : 0)
    } Slim::Player::Client::clients();

    # %handled: MAC => 'started' | 'seen'
    # 'started' = daemon started for this MAC; 'seen' = processed, no daemon needed
    my %handled;

    for my $client (@clients) {
        next if $handled{$client->id};

        # D-07: Unified daemon starts for ALL players with credentials, regardless of
        # _isConnectEnabled. The Connect toggle only affects --enable-connect flag in the
        # Rust binary (handled inside startHelper/Daemon.pm) — not whether daemon starts.
        if (Slim::Player::Sync::isSlave($client) && (my $master = $client->master)) {
            # Slave: daemon runs on the sync master
            my $syncMasterId = $master->id;

            main::INFOLOG && $log->is_info && $log->info(
                "Sync group slave, Unified daemon runs on $syncMasterId: " . $client->id
            );
            $class->stopHelper($client);
            $handled{$client->id} = 'seen';

            if (!$handled{$syncMasterId}) {
                my $delegateClient = Slim::Player::Client::getClient($syncMasterId);
                if ($delegateClient) {
                    main::DEBUGLOG && $log->is_debug && $log->debug(
                        "Evaluating Unified daemon for sync group master: $syncMasterId"
                    );
                    $class->startHelper($delegateClient);
                    $handled{$syncMasterId} = 'started';
                }
            }
        }
        else {
            # Standalone player or sync master — start directly (credential-gated in startHelper)
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Evaluating Unified daemon for player: " . $client->id
            );
            $class->startHelper($client);
            $handled{$client->id} = 'started';
        }
    }

    # Ensure DSTM provider is set for players that never opened SpotOn settings.
    # Only auto-configure when enableAutoplay was never explicitly saved (no timestamp).
    # If the user saved settings (timestamp exists), their choice is authoritative.
    if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
        my $dstmPrefs = preferences('plugin.dontstopthemusic');
        for my $client (Slim::Player::Client::clients()) {
            next if $prefs->client($client)->get('_ts_enableAutoplay');
            my $provider = $dstmPrefs->client($client)->get('provider') // '';
            next if $provider;
            $dstmPrefs->client($client)->set('provider', 'PLUGIN_SPOTON_RECOMMENDATIONS');
            main::INFOLOG && $log->is_info && $log->info(
                "Auto-configured DSTM provider for " . $client->id
            );
        }
    }

    # 60s watchdog: ensure daemons are alive even without player events
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + DAEMON_WATCHDOG_INTERVAL, \&initHelpers);
}

sub _streamAlivePoll {
    my $class = __PACKAGE__;

    Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);

    # Unified daemon is always a streaming daemon when alive — no _streamMode gate
    # (matches Browse::DaemonManager pattern, not Connect::DaemonManager pattern).
    # Self-stop when no daemons are registered — avoids idle timer overhead
    return unless values %helperInstances;

    for my $helper (values %helperInstances) {
        if (!$helper->alive) {
            main::INFOLOG && $log->is_info && $log->info(
                "SpotOn Unified daemon crashed for " . $helper->mac . " - restarting via startHelper"
            );
            $class->startHelper($helper->mac);
        }
        elsif (main::DEBUGLOG && $log->is_debug) {
            $log->debug("SpotOn Unified daemon alive: " . $helper->mac . " pid=" . ($helper->pid || '?'));
        }

        if ($helper->alive && $helper->_streamPort) {
            my $count = ($helper->_healthCheckCount || 0) + 1;
            $helper->_healthCheckCount($count);

            if ($count % 12 == 0) {
                Slim::Networking::SimpleAsyncHTTP->new(
                    sub { $class->_onHealthResponse($helper, @_) },
                    sub { $class->_onHealthError($helper, @_) },
                    { timeout => 5 }
                )->get("http://127.0.0.1:" . $helper->_streamPort . "/health");
            }
        }
    }

    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + STREAM_WATCHDOG_INTERVAL,
        \&_streamAlivePoll
    );
}

sub _cleanupOrphanedLogs {
    my $baseDir = catdir($serverPrefs->get('cachedir'), 'spoton');

    return unless -d $baseDir;

    # W1: bsd_glob — plain glob() splits its argument on whitespace, silently
    # failing for cache dirs with spaces (e.g. C:\Program Files\...).
    my @logFiles = bsd_glob(catfile($baseDir, '*-unified.log'));
    return unless @logFiles;

    for my $f (@logFiles) {
        next unless basename($f) =~ /^([0-9a-f]{12})-unified\.log$/i;
        my $macClean = $1;
        my $mac = join(':', $macClean =~ /../g);

        my $client = Slim::Player::Client::getClient($mac);
        if (!$client || !$client->connected) {
            my $mtime = (stat($f))[9] || 0;
            if (time() - $mtime > 300) {
                unlink $f;
                $log->warn("Cleaned up orphaned Unified log: " . basename($f));
            }
        }
    }
}

sub startHelper {
    my ($class, $clientId) = @_;

    $clientId = $clientId->id if $clientId && blessed $clientId;

    # Credential pre-check: skip daemon start if no cached credentials exist.
    # Mirrors Daemon.pm start() cache dir construction (CON-01 account-level scope).
    # Without this, librespot starts, finds no credentials, and exits immediately —
    # triggering crash-loop detection => 30min disable => retry, filling logs with noise.
    my $activeAccountId = $prefs->get('activeAccount') || '';
    my $cacheDir = $activeAccountId
        ? catdir($serverPrefs->get('cachedir'), 'spoton', $activeAccountId)
        : catdir($serverPrefs->get('cachedir'), 'spoton');
    my $credFile = catfile($cacheDir, 'credentials.json');

    if (! -f $credFile) {
        main::INFOLOG && $log->is_info && $log->info(
            "Skipping Unified daemon for $clientId - no cached credentials (expected: $credFile)"
        );
        return;
    }

    my $helper = $helperInstances{$clientId};

    if ($helper && $helper->alive && ($helper->_accountId || '') ne $activeAccountId) {
        main::INFOLOG && $log->is_info && $log->info(
            "Account changed for $clientId (was " . ($helper->_accountId || 'none') . ", now $activeAccountId) — restarting daemon"
        );
        $class->stopHelper($clientId);
        $helper = undef;
    }

    if ($helper && $helper->alive) {
        my $client = Slim::Player::Client::getClient($clientId);
        if ($client) {
            my $expectedName = substr(
                ($client->isSynced() && $client->model ne 'group')
                    ? Slim::Player::Sync::syncname($client)
                    : $client->name,
                0, 60
            );
            if (($helper->name || '') ne $expectedName) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Name changed for $clientId (was '" . ($helper->name || '') . "', now '$expectedName') — restarting daemon"
                );
                $class->stopHelper($clientId);
                $helper = undef;
            }

            if ($helper && $helper->alive) {
                my $wantConnect = _isConnectEnabled($client) ? 1 : 0;
                if (($helper->_connectEnabled // -1) != $wantConnect) {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Connect toggle changed for $clientId (was " . ($helper->_connectEnabled // '?') . ", now $wantConnect) — restarting daemon"
                    );
                    $class->stopHelper($clientId);
                    $helper = undef;
                }
            }

            if ($helper && $helper->alive) {
                my $wantPassthrough = $class->resolvePassthroughForClient($client) ? 1 : 0;
                if (($helper->_passthrough // -1) != $wantPassthrough) {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Passthrough format changed for $clientId (was " . ($helper->_passthrough // '?') . ", now $wantPassthrough) — restarting daemon"
                    );
                    $class->stopHelper($clientId);
                    $helper = undef;
                }
                # Issue #97: restart daemon when bitrate preference changes
                if ($helper && $helper->alive) {
                    require Plugins::SpotOn::Plugin;
                    my $wantBitrate = Plugins::SpotOn::Plugin->_bitrateConfigForClient($client);
                    if (($helper->_bitrate // 0) != $wantBitrate) {
                        main::INFOLOG && $log->is_info && $log->info(
                            "Bitrate changed for $clientId (was " . ($helper->_bitrate // '?') . ", now $wantBitrate) — restarting daemon"
                        );
                        $class->stopHelper($clientId);
                        $helper = undef;
                    }
                }
            }
        }
    }

    if (!$helper) {
        main::INFOLOG && $log->is_info && $log->info("Need to create Unified daemon for $clientId");
        $helper = $helperInstances{$clientId} = Plugins::SpotOn::Unified::Daemon->new($clientId);
    }
    elsif (!$helper->alive) {
        main::INFOLOG && $log->is_info && $log->info("Need to (re-)start Unified daemon for $clientId");
        $helper->start;
    }

    # Unified daemon is always streaming when alive — activate fast poll unconditionally
    # (matches Browse::DaemonManager pattern)
    if ($helper && $helper->alive) {
        Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);
        Slim::Utils::Timers::setTimer(
            $class,
            Time::HiRes::time() + STREAM_WATCHDOG_INTERVAL,
            \&_streamAlivePoll
        );
    }

    return $helper if $helper && $helper->alive;
}

sub _onHealthResponse {
    my ($class, $helper, $http) = @_;

    return unless $helper && $helper->alive;

    my $raw  = $http->content // '';
    my $json = eval { from_json($raw) };
    if ($@) {
        $log->warn("Health check JSON parse error for " . $helper->mac
                   . ": $@ (body: " . substr($raw, 0, 200) . ")");
    }

    # Always store health data on daemon (even before restart checks)
    $helper->_lastHealthSession({
        session_valid    => $json ? ($json->{session_valid} ? 1 : 0) : undef,
        session_age_secs => $json ? ($json->{session_age_secs} // 0) : undef,
        idle_secs        => $json ? ($json->{idle_secs} // 0) : undef,
        checked_at       => time(),
    });

    # Malformed response: daemon is confused, restart
    unless ($json && defined $json->{status} && $json->{status} eq 'ok') {
        $class->_restartForHealth($helper, 'malformed health response');
        return;
    }

    # Signal 1: librespot explicitly reports dead session
    if (!$json->{session_valid}) {
        $class->_restartForHealth($helper, 'session_valid=false');
        return;
    }

    # Signal 2: stale session (old + idle) — proactive restart
    # session_age > 4h AND idle > 5 min
    # Idle guard prevents restarting during active playback/Connect use
    if ($json->{session_age_secs} > 14400 && $json->{idle_secs} > 300) {
        $class->_restartForHealth($helper,
            sprintf('stale session (age=%ds, idle=%ds)', $json->{session_age_secs}, $json->{idle_secs}));
        return;
    }
}

sub _onHealthError {
    my ($class, $helper, $http) = @_;

    # HTTP error to localhost health endpoint while daemon process is alive
    # = daemon HTTP server not responding. Unusual but not critical — process-level
    # alive check in _streamAlivePoll already handles process death.
    # Log but don't restart (avoid double-restart race with alive poll).
    $log->warn("Health check failed for " . $helper->mac . ": " . ($http->error || 'unknown'));

    # Mark last health data as unavailable so Status UI shows stale-data indicator
    # rather than displaying the previous (potentially outdated) snapshot (WR-05).
    $helper->_lastHealthSession({
        session_valid    => undef,
        session_age_secs => undef,
        idle_secs        => undef,
        checked_at       => time(),
        error            => $http->error || 'connection failed',
    });
}

sub _restartForHealth {
    my ($class, $helper, $reason) = @_;

    return unless $helper && $helper->alive;

    # Rate-limit health restarts: no more than 1 per 5 minutes (WR-02).
    # H9: timestamps live in the package-level %lastHealthRestart hash keyed by
    # MAC — stopHelper DELETES the Daemon object, so an object-level timestamp
    # would be erased by the very restart being rate-limited and a permanently
    # dead session would restart indefinitely at the health-check cadence (~60s).
    my $now  = time();
    my $last = $lastHealthRestart{ $helper->mac } // 0;
    if ($now - $last < 300) {
        main::INFOLOG && $log->is_info && $log->info(
            sprintf("Health restart suppressed for %s (last was %ds ago): %s",
                    $helper->mac, $now - $last, $reason)
        );
        return;
    }
    $lastHealthRestart{ $helper->mac } = $now;

    main::INFOLOG && $log->is_info && $log->info(
        sprintf("Health check restart for %s: %s", $helper->mac, $reason)
    );

    $helper->_healthCheckCount(0);
    $class->stopHelper($helper->mac);
    $class->startHelper($helper->mac);
}

sub stopHelper {
    my ($class, $clientId) = @_;

    $clientId = $clientId->id if $clientId && blessed $clientId;

    my $helper = delete $helperInstances{$clientId};

    if ($helper && $helper->alive) {
        main::INFOLOG && $log->is_info && $log->info(
            sprintf("Shutting down Unified daemon for $clientId (pid: %s)", $helper->pid)
        );
        $helper->stop;
    }

    # Stop the fast poll when the last Unified daemon is removed
    unless (grep { $_->alive } values %helperInstances) {
        Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);
    }
}

sub shutdown {
    my ($class, $mode) = @_;

    # 'inactive-only': only stop helpers for players no longer connected
    my %activeClientIds;
    if ($mode && $mode eq 'inactive-only') {
        %activeClientIds = map { $_->id => 1 } Slim::Player::Client::clients();
    }

    foreach my $clientId (keys %helperInstances) {
        # In inactive-only mode, skip helpers for still-connected players
        next if %activeClientIds && $activeClientIds{$clientId};
        $class->stopHelper($clientId);
    }

    unless ($mode && $mode eq 'inactive-only') {
        Slim::Utils::Timers::killTimers($class, \&initHelpers);
        Slim::Utils::Timers::killTimers($class, \&_streamAlivePoll);

        # M10: unregister the event subscriptions added in init() — otherwise
        # they accumulate across plugin shutdown/re-init cycles.
        for my $subRef ($clientSubRef, $syncSubRef) {
            Slim::Control::Request::unsubscribe($subRef) if $subRef;
        }
        ($clientSubRef, $syncSubRef) = (undef, undef);
    }
}

# helperForClient($class, $clientId)
# Returns the Daemon instance for a given player (by id or client object).
# For synced players, also checks the sync group master and slaves if no
# daemon is found directly — handles the case where the daemon is registered
# under the sync master's MAC but the lookup uses a slave's MAC.
sub helperForClient {
    my ($class, $clientId) = @_;

    my $client;
    if ($clientId && blessed $clientId) {
        $client   = $clientId;
        $clientId = $clientId->id;
    }

    return unless $clientId;

    # Direct lookup — fastest path
    my $helper = $helperInstances{$clientId};
    return $helper if $helper && $helper->alive;

    # Sync group fallback: if the direct MAC has no daemon, check the sync
    # master and all sync members. This covers the case where the daemon
    # runs under the master's MAC but the lookup comes via a slave MAC.
    if (!$client) {
        $client = Slim::Player::Client::getClient($clientId);
    }
    if ($client && $client->isSynced()) {
        my $master = $client->master;
        if ($master) {
            $helper = $helperInstances{$master->id};
            return $helper if $helper && $helper->alive;

            for my $slave (Slim::Player::Sync::slaves($master)) {
                $helper = $helperInstances{$slave->id};
                return $helper if $helper && $helper->alive;
            }
        }
    }

    return undef;
}

# streamPortForClient($class, $clientId)
# Returns the HTTP stream port for the Unified daemon serving this player.
sub streamPortForClient {
    my ($class, $clientId) = @_;
    $clientId = $clientId->id if $clientId && blessed $clientId;
    my $helper = $class->helperForClient($clientId) || return;
    return $helper->_streamPort;
}

# helperPids($class)
# Returns list of PIDs for all currently-alive Unified daemons.
# Called by Plugin.pm::_killOrphanedProcesses to exclude Unified daemon PIDs
# from orphan cleanup (CON-09 / Pitfall 6).
sub helperPids {
    my $class = shift;
    return map { $_->pid } grep { $_->alive } values %helperInstances;
}

# uptime($class, $clientId)
# Returns seconds since last daemon start for the given player, or 0 if not found.
sub uptime {
    my ($class, $clientId) = @_;
    return 0 unless $clientId;
    my $helper = $class->helperForClient($clientId) || return 0;
    return $helper->uptime();
}

# helperInstances($class)
# Returns all Daemon instances (for inspection/iteration).
sub helperInstances {
    my $class = shift;
    return values %helperInstances;
}

1;
