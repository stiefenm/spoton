package Plugins::SpotOn::Connect;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use File::Path qw(mkpath);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);
use Time::HiRes;

use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;

# Seconds; delta threshold to trigger a seek on change events
use constant SEEK_THRESHOLD => 3;

# Fallback artwork for stream-mode metadata updates
use constant IMG_TRACK => '/html/images/cover.png';

# Seconds; CON-11 — ignore volume events within this window after daemon start.
# The binary's suppress_next_volume AtomicBool handles the very first VolumeChanged after
# SessionConnected. This grace period suppresses subsequent echoes during session setup.
use constant VOLUME_GRACE_PERIOD => 3;

# Seconds; suppress spurious stop events during session setup (mid-playback transfer)
use constant CONNECT_START_GRACE => 12;

# Volume debounce: merge rapid volume events into one (0.5s window)
use constant VOLUME_DEBOUNCE => 0.5;

# Seek debounce: coalesce rapid seek events (0.3s window)
use constant SEEK_DEBOUNCE => 0.3;

# H7: newTrack flag fallback — the flag only needs to suppress the transitional
# stop-before-play burst (~1-2s); 10s is generous. Without a fallback, a failed
# metadata fetch leaves the flag set forever and ALL stop events get swallowed.
use constant NEW_TRACK_FALLBACK => 10;

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

my $initialized;
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# Track the MAC of the player currently owning the active Connect session.
# Used by _onPause to suppress stale stop events from old players when switching.
my $_activeConnectPlayer;

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub initConnectHandlers {
    my ($class) = @_;

    return if $initialized;

    Slim::Control::Request::addDispatch(['spottyconnect', '_cmd'],
                                                            [1, 0, 1, \&_connectEvent]
    );

    Slim::Control::Request::subscribe(\&_onNewSong, [['playlist'], ['newsong']]);
    Slim::Control::Request::subscribe(\&_onPause, [['playlist'], ['pause', 'stop']]);
    Slim::Control::Request::subscribe(\&_onVolume, [['mixer'], ['volume']]);
    Slim::Control::Request::subscribe(\&_onSeek, [['time']]);
    Slim::Control::Request::subscribe(\&_onPlaylistJump, [['playlist'], ['jump', 'index']]);

    $initialized = 1;
}

# isSpotifyConnect($class, $client)
# Returns true if the given player is currently in active Spotify Connect mode.
# Used by ProtocolHandler to disable LMS seek in stream mode.
sub isSpotifyConnect {
    my ($class, $client) = @_;

    return unless $client;
    $client = $client->master if $client->can('master');

    return $_activeConnectPlayer && $_activeConnectPlayer eq $client->id ? 1 : 0;
}

# _isDeadHistoryUrl($url)
# Returns true if a spoton://connect-* URL is a dead history record (not a live session).
# Detection: cache entry with spotifyUri field exists — set by _fetchTrackMetadata.
# NOTE: live Connect tracks ALSO get spotifyUri cached during playback. Callers must
# additionally check $song->pluginData('info') to distinguish live from history.
sub _isDeadHistoryUrl {
    my ($url) = @_;
    return 0 unless $url && $url =~ m{spoton://connect-};
    my $meta = $cache->get('spoton_meta_' . md5_hex($url));
    return ($meta && $meta->{spotifyUri}) ? 1 : 0;
}

# shutdown($class)
# Cleanly unsubscribes all event handlers.
# Daemon shutdown is handled by Unified::DaemonManager via Plugin.pm shutdownPlugin().
sub shutdown {
    if ($initialized) {
        Slim::Control::Request::unsubscribe(\&_onNewSong);
        Slim::Control::Request::unsubscribe(\&_onPause);
        Slim::Control::Request::unsubscribe(\&_onVolume);
        Slim::Control::Request::unsubscribe(\&_onSeek);
        Slim::Control::Request::unsubscribe(\&_onPlaylistJump);

        $_activeConnectPlayer = undef;
        $initialized = 0;
    }
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# H7: newTrack lifecycle helpers.
# _armNewTrackFallback: called wherever newTrack => 1 is set — guarantees the
# flag clears within NEW_TRACK_FALLBACK seconds even if the metadata callback
# never completes (API failure, early return).
sub _armNewTrackFallback {
    my ($client) = @_;
    Slim::Utils::Timers::killTimers($client, \&_clearNewTrack);
    Slim::Utils::Timers::setTimer($client,
        Time::HiRes::time() + NEW_TRACK_FALLBACK, \&_clearNewTrack);
}

# Timer callback — clears the flag after the fallback window.
sub _clearNewTrack {
    my ($client) = @_;
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "newTrack fallback timer fired — clearing flag for " . $client->id . " (H7)");
    $client->pluginData(newTrack => 0);
}

# _finishNewTrack: normal-path clear — kills the fallback timer and clears the flag.
sub _finishNewTrack {
    my ($client) = @_;
    Slim::Utils::Timers::killTimers($client, \&_clearNewTrack);
    $client->pluginData(newTrack => 0);
}

# _isStreamMode($client)
# Returns true if the unified daemon for this client has an active stream port.
sub _isStreamMode {
    my ($client) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');
    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
    return $helper && $helper->alive && $helper->_streamPort;
}

# _stopConnectDaemon($class, $client)
# Stops the active daemon for this client (D-08: Browse→Connect mutual exclusion).
# In unified mode the Rust ActiveMode mutex handles this internally (D-09/D-10).
# This method is retained for compatibility but is not called in unified mode
# (ProtocolHandler.pm new() skips it when daemonMode=unified).
sub _stopConnectDaemon {
    my ($class, $client) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');

    main::INFOLOG && $log->is_info && $log->info(
        "D-08 mutual exclusion: stopping daemon for Browse start on " . $client->id
    );

    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Unified::DaemonManager->stopHelper($client->id);

    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        $_activeConnectPlayer = undef;
    }
}

# _sendControlCommand($client, $endpoint, $body_hashref)
# Sends an HTTP control command to the binary's /control/* endpoint (D-14).
# Falls back to Spotify Web API via API::Client if binary unreachable (D-15).
sub _sendControlCommand {
    my ($client, $endpoint, $body) = @_;
    return unless $client;

    require Plugins::SpotOn::Unified::DaemonManager;
    my $port = Plugins::SpotOn::Unified::DaemonManager->streamPortForClient($client->id);
    unless ($port) {
        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: no stream port for " . $client->id . ", skipping $endpoint"
        );
        return;
    }

    my $url      = "http://127.0.0.1:$port$endpoint";
    my $jsonBody = $body ? eval { to_json($body) } : '{}';

    main::INFOLOG && $log->is_info && $log->info(
        "_sendControlCommand: POST $url ($jsonBody)"
    );
    $log->warn("[DIAG] control_cmd_sent: mac=" . $client->id . " endpoint=$endpoint body=$jsonBody") if $prefs->get('diagnosticMode');

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("_sendControlCommand: $endpoint OK");
            $log->warn("[DIAG] control_cmd_ok: mac=" . $client->id . " endpoint=$endpoint") if $prefs->get('diagnosticMode');
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("[DIAG] control_cmd_fail: mac=" . $client->id . " endpoint=$endpoint error=$error fallback=web_api") if $prefs->get('diagnosticMode');
            main::INFOLOG && $log->is_info && $log->info(
                "_sendControlCommand: $endpoint failed ($error) — trying Web API fallback (D-15)"
            );
            _sendControlFallback($client, $endpoint, $body);
        },
        { timeout => 5 }
    );

    $http->post($url, 'Content-Type' => 'application/json', $jsonBody);
}

# _sendControlFallback($client, $endpoint, $body)
# D-15: Spotify Web API fallback when binary control endpoint is unreachable.
sub _sendControlFallback {
    my ($client, $endpoint, $body) = @_;
    require Plugins::SpotOn::API::Client;

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';
    $log->warn("[DIAG] web_api_fallback: mac=" . $client->id . " endpoint=$endpoint account=" . substr($accountId, 0, 4) . "****") if $prefs->get('diagnosticMode');

    if ($endpoint eq '/control/pause') {
        Plugins::SpotOn::API::Client->playerPause($accountId, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API pause fallback done");
        });
    }
    elsif ($endpoint eq '/control/play') {
        Plugins::SpotOn::API::Client->playerPlay($accountId, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API play fallback done");
        });
    }
    elsif ($endpoint eq '/control/volume' && $body && defined $body->{volume}) {
        Plugins::SpotOn::API::Client->playerVolume($accountId, $body->{volume}, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API volume fallback done");
        });
    }
    elsif ($endpoint eq '/control/seek' && $body && defined $body->{position_ms}) {
        my $positionMs = $body->{position_ms};
        Plugins::SpotOn::API::Client->playerSeek($accountId, $positionMs, sub {
            main::DEBUGLOG && $log->is_debug && $log->debug("Web API seek fallback done");
        });
    }
}

# ---------------------------------------------------------------------------
# Event subscribers (LMS → Binary direction, D-14)
# ---------------------------------------------------------------------------

# _onNewSong($request)
# Handles CON-17: when a Connect session triggers a new LMS track, apply
# previously-stored progress offset so playback resumes at the correct position.
sub _onNewSong {
    my $request = shift;

    # Source-marking loop prevention: skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    # CON-17: Apply stored progress for Connect sessions
    if (__PACKAGE__->isSpotifyConnect($client)) {
        if (my $progress = $client->pluginData('progress')) {
            $client->pluginData(progress => 0);

            if (_isStreamMode($client)) {
                # Stream-mode: binary streams from current position. Adjust
                # startOffset so songTime reports the correct position without
                # triggering _JumpToTime → _Stop + _Stream.
                my $song = $client->playingSong();
                if ($song) {
                    my $elapsed = $client->songElapsedSeconds() || 0;
                    $song->startOffset(int($progress) - $elapsed);
                    $log->warn(sprintf("[DIAG] startOffset_adjust: mac=%s old=0 new=%d progress=%s elapsed=%.1f", $client->id, $song->startOffset(), $progress, $elapsed)) if $prefs->get('diagnosticMode');
                    main::INFOLOG && $log->is_info && $log->info(
                        "Stream mode mid-song connect: startOffset=" . $song->startOffset()
                    );
                }
            } else {
                my $seekReq = Slim::Control::Request->new($client->id, ['time', int($progress)]);
                $seekReq->source(__PACKAGE__);
                $seekReq->execute();
            }
        }
        return;
    }

    # If Connect flag was set but we're no longer in a Connect URL, clear state
    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        my $song = $client->playingSong();
        my $url  = $song ? ($song->streamUrl || '') : '';
        unless ($url =~ m{spoton://connect-}) {
            main::INFOLOG && $log->is_info && $log->info(
                "New song without Connect URL — clearing active Connect state for " . $client->id
            );
            $_activeConnectPlayer = undef;
        }
    }
}

# _onPause($request)
# Forwards LMS pause/stop events to the binary's HTTP control endpoint (D-14).
sub _onPause {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $isUnpause = $request->isCommand([['playlist'], ['pause']]) && !$request->getParam('_newvalue');

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    # Echo suppression: _connectEvent's ['pause', 0/1] triggers a playlist
    # notification without source-marking. Suppress within 1s of our last
    # _connectEvent-initiated pause to prevent spirc.pause()/play() echo.
    my $lastConnectPause = $client->pluginData('connectPauseTs') || 0;
    if (Time::HiRes::time() - $lastConnectPause < 1) {
        $log->warn("[DIAG] echo_suppressed: mac=" . $client->id . " event=onPause reason=connectPauseTs_within_1s age=" . sprintf('%.3f', Time::HiRes::time() - $lastConnectPause) . "s") if $prefs->get('diagnosticMode');
        main::INFOLOG && $log->is_info && $log->info(
            "Suppressing _onPause echo from _connectEvent (within 1s)"
        );
        return;
    }

    # Grace period: suppress stop/pause events within 3s of our own playlist play.
    # When Connect issues playlist play, LMS internally stops the previous item
    # which generates a stop event that would leak back to the binary as /control/pause.
    my $startTime = $client->pluginData('connectStartTime') || 0;
    if (Time::HiRes::time() - $startTime < 3) {
        $log->warn("[DIAG] echo_suppressed: mac=" . $client->id . " event=onPause reason=connect_start_grace age=" . sprintf('%.3f', Time::HiRes::time() - $startTime) . "s") if $prefs->get('diagnosticMode');
        main::INFOLOG && $log->is_info && $log->info(
            "Suppressing pause/stop during Connect start grace period"
        );
        return;
    }

    # Player-switch guard: if another player has taken over the active Connect
    # session, suppress this player's stop event.
    if ($_activeConnectPlayer && $_activeConnectPlayer ne $client->id) {
        main::INFOLOG && $log->is_info && $log->info(
            "Ignoring stop/pause from " . $client->id . " - active Connect player is $_activeConnectPlayer"
        );
        return;
    }

    # History-replay guard: skip daemon forward for dead history URLs.
    # IMPORTANT: also check !pluginData('info') — live Connect tracks get spotifyUri
    # cached during playback by _fetchTrackMetadata, so _isDeadHistoryUrl alone
    # would false-positive on live tracks and break unpause.
    if ($isUnpause) {
        my $song = $client->playingSong();
        my $songUrl = $song ? ($song->track->url || $song->streamUrl || '') : '';
        if ($song && !$song->pluginData('info') && _isDeadHistoryUrl($songUrl)) {
            main::INFOLOG && $log->is_info && $log->info(
                "Skipping daemon unpause — history replay URL detected: $songUrl"
            );
            return;
        }
    }

    if ($isUnpause) {
        main::INFOLOG && $log->is_info && $log->info(
            "Got unpause event - forwarding to Connect binary via HTTP /control/play (D-14)"
        );
        _sendControlCommand($client, '/control/play', undef);
    } else {
        main::INFOLOG && $log->is_info && $log->info(
            "Got a pause event - forwarding to Connect binary via HTTP /control/pause (D-14)"
        );
        _sendControlCommand($client, '/control/pause', undef);
    }
}

# _onVolume($request)
# Forwards LMS volume changes to binary /control/volume with 0.5s debounce (D-14).
sub _onVolume {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    my $volume = $client->volume;

    # Debounce: merge rapid volume events into one (0.5s window)
    Slim::Utils::Timers::killTimers($client, \&_bufferedSetVolume);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + VOLUME_DEBOUNCE, \&_bufferedSetVolume, $volume);
}

sub _bufferedSetVolume {
    my ($client, $volume) = @_;

    main::INFOLOG && $log->is_info && $log->info(
        "Forwarding volume to Connect binary: $volume (D-14)"
    );
    $log->warn("[DIAG] volume_to_binary: mac=" . $client->id . " volume=$volume debounced=" . VOLUME_DEBOUNCE . "s") if $prefs->get('diagnosticMode');

    _sendControlCommand($client, '/control/volume', { volume => int($volume) });
}

# _onSeek($request)
# Forwards LMS seek events to binary /control/seek with 0.3s debounce (D-14).
sub _onSeek {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    my $position = Slim::Player::Source::songTime($client) || 0;
    my $positionMs = int($position * 1000);

    # Debounce: coalesce rapid seek events (0.3s window)
    Slim::Utils::Timers::killTimers($client, \&_bufferedSeek);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SEEK_DEBOUNCE, \&_bufferedSeek, $positionMs);
}

sub _bufferedSeek {
    my ($client, $positionMs) = @_;

    main::INFOLOG && $log->is_info && $log->info(
        "Forwarding seek to Connect binary: ${positionMs}ms (D-14)"
    );
    $log->warn("[DIAG] seek_to_binary: mac=" . $client->id . " position_ms=$positionMs debounced=" . SEEK_DEBOUNCE . "s") if $prefs->get('diagnosticMode');

    _sendControlCommand($client, '/control/seek', { position_ms => $positionMs });
}

# _onPlaylistJump($request)
# Forwards LMS skip next/prev events to binary /control/next or /control/prev (D-14).
sub _onPlaylistJump {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    return unless __PACKAGE__->isSpotifyConnect($client);

    my $index = $request->getParam('_index');
    return if !defined $index;

    # Suppress _onPause echo: LMS fires internal pause/stop events during
    # playlist jump (old track stops). Without this, _onPause forwards them
    # as /control/pause BEFORE the skip command takes effect.
    $client->pluginData(connectPauseTs => Time::HiRes::time());

    if ($index eq '+1') {
        main::INFOLOG && $log->is_info && $log->info(
            "Connect mode: forwarding skip-next to binary /control/next (D-14)"
        );
        _sendControlCommand($client, '/control/next', undef);
    }
    elsif ($index eq '-1' || $index eq '+0') {
        main::INFOLOG && $log->is_info && $log->info(
            "Connect mode: forwarding skip-previous to binary /control/prev (D-14)"
        );
        _sendControlCommand($client, '/control/prev', undef);
    }
}

# ---------------------------------------------------------------------------
# spottyconnect JSON-RPC dispatch handler (Binary → LMS direction, CON-03)
#
# Wire vocabulary (librespot-spoton connect.rs):
#   start  — new track begins (None -> Some);  p1=track_id(base62), p2=""
#   change — track changes mid-playback;        p1=new_track_id, p2=previous_track_id
#   stop   — PlayerEvent::Paused OR Stopped;    p1="", p2=""  (NOTE: no 'pause' event)
#   volume — VolumeChanged (after suppress);    p1=volume 0-100, p2=""
#   seek   — Seeked mid-playback;               p1=position in seconds (3 decimals), p2=""
#   resume — Playing after Pause (same track); p1=track_id(base62), p2=position (seconds, 3 decimals)
#   ready  — Spirc reconnected internally;      p1="", p2=""
# ---------------------------------------------------------------------------
sub _connectEvent {
    my $request = shift;
    my $client  = $request->client();
    return unless defined $client;
    $client = $client->master;

    my $cmd = $request->getParam('_cmd');

    main::INFOLOG && $log->is_info && $log->info(sprintf(
        'Got spottyconnect event for %s: %s', $client->id, $cmd
    ));

    # Diagnostic timing (#3): capture entry timestamp when diagnosticMode is active
    my $diagMode = $prefs->get('diagnosticMode');
    my $diagTs = $diagMode ? sprintf('%.3f', Time::HiRes::time()) : '';

    # Claim active Connect ownership on 'start' (must be synchronous, before async ops)
    if ($cmd eq 'start') {
        $client->pluginData(pendingConnect => 1);

        # If another player had Connect, clear its state
        if ($_activeConnectPlayer && $_activeConnectPlayer ne $client->id) {
            my $oldClient = Slim::Player::Client::getClient($_activeConnectPlayer);
            if ($oldClient) {
                $oldClient = $oldClient->master;
                main::INFOLOG && $log->is_info && $log->info(
                    "Player switch: clearing Connect on " . $_activeConnectPlayer . " for " . $client->id
                );
            }
        }

        $_activeConnectPlayer = $client->id;
    }

    # -----------------------------------------------------------------
    # Volume handler (CON-11): check grace period before forwarding
    # -----------------------------------------------------------------
    if ($cmd eq 'volume') {
        # H6: ignore Spirc volume events for players not in an active Connect
        # session — a player that switched back to Browse must not have its
        # volume overwritten (known error: connect-metadata-bleed).
        unless (__PACKAGE__->isSpotifyConnect($client)) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Dropping Connect volume event for non-Connect player " . $client->id . " (H6)");
            return;
        }

        # Skip source-marked requests (would be from our own _onVolume, not from binary)
        return if $request->source && $request->source eq __PACKAGE__;

        my $volume = $request->getParam('_p2');
        return unless defined $volume && $volume ne '';

        # CON-11: VOLUME_GRACE_PERIOD — ignore volume events within the first N seconds
        # after daemon start. The binary's suppress_next_volume AtomicBool handles the very
        # first VolumeChanged; this grace period covers subsequent echoes during session setup.
        require Plugins::SpotOn::Unified::DaemonManager;
        if (Plugins::SpotOn::Unified::DaemonManager->uptime($client->id) < VOLUME_GRACE_PERIOD) {
            main::INFOLOG && $log->is_info && $log->info(
                "Ignoring initial volume reset right after daemon start (CON-11 grace period)"
            );
            return;
        }

        main::INFOLOG && $log->is_info && $log->info("Binary reported volume change: $volume");
        $log->warn("[DIAG] volume_from_binary: mac=" . $client->id . " volume=$volume uptime=" . sprintf('%.1f', Plugins::SpotOn::Unified::DaemonManager->uptime($client->id)) . "s") if $prefs->get('diagnosticMode');

        # Source-mark to prevent _onVolume from echoing back to binary (T-05-13)
        my $volReq = Slim::Control::Request->new($client->id, ['mixer', 'volume', $volume]);
        $volReq->source(__PACKAGE__);
        $volReq->execute();
        return;
    }

    # -----------------------------------------------------------------
    # Seek handler (CON-13): always use startOffset, NEVER ['time', N] in stream mode
    # -----------------------------------------------------------------
    if ($cmd eq 'seek') {
        # H6: ignore Spirc seek events for players not in an active Connect
        # session (metadata/position bleed fix). CON-17 exception: seek can
        # arrive BEFORE playlist play — accept while pendingConnect is set.
        unless (__PACKAGE__->isSpotifyConnect($client) || $client->pluginData('pendingConnect')) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Dropping Connect seek event for non-Connect player " . $client->id . " (H6)");
            return;
        }

        my $position = $request->getParam('_p2');
        if (defined $position && $position ne '') {
            main::INFOLOG && $log->is_info && $log->info("Binary reported seek to: $position");
            $log->warn("[DIAG] seek_from_binary: mac=" . $client->id . " position=$position") if $prefs->get('diagnosticMode');

            if ($client->pluginData('pendingConnect')) {
                # Seek arrived before playlist play — store for _onNewSong to apply
                # AFTER the new song object is created (CON-17 race prevention)
                $client->pluginData(progress => $position);
                $client->pluginData(pendingConnect => 0);
                main::INFOLOG && $log->is_info && $log->info(
                    "Stream mode seek deferred: progress=$position (pending connect)"
                );
            } else {
                # CON-13: Use startOffset to adjust position without triggering
                # _JumpToTime → _Stop + _Stream (which would restart the HTTP stream)
                my $song = $client->playingSong();
                if ($song) {
                    my $elapsed = $client->songElapsedSeconds() || 0;
                    $song->startOffset($position - $elapsed);
                    main::INFOLOG && $log->is_info && $log->info(
                        "Stream mode seek: adjusted startOffset to " . $song->startOffset()
                    );
                }
            }
        }
        return;
    }

    # -----------------------------------------------------------------
    # Resume handler (CON-05, D-02): binary sends resume notify after Pause->Playing
    # transition on same track. Unpauses squeezelite via ['pause', 0] (source-marked
    # to prevent _onPause echo, T-05-13). Adjusts startOffset per CON-13.
    # -----------------------------------------------------------------
    if ($cmd eq 'resume') {
        my $trackId  = $request->getParam('_p2');
        my $position = $request->getParam('_p3');

        # Check actual playing URL, not just the $_activeConnectPlayer flag.
        # The flag stays set after source switch because 'stop' from Spotify
        # (pause forwarding) doesn't clear it — only _onNewSong clears it.
        # Phase 44 fix: use track->url (the original spoton://connect-* URL),
        # not streamUrl (which becomes the direct-streamed http://…/stream
        # proxy URL after canDirectStream resolves it).
        my $song = $client->playingSong();
        my $currentUrl = $song ? ($song->track->url || $song->streamUrl || '') : '';

        # Determine if the player is on a live Connect stream.
        # pluginData('info') is set by _fetchTrackMetadata for live sessions.
        # _isDeadHistoryUrl alone is insufficient: live tracks also get spotifyUri
        # cached during playback, so we must check pluginData to avoid false positives.
        my $hasLiveMetadata = $song && $song->pluginData('info');
        my $isDeadHistory = $currentUrl =~ m{spoton://connect-} ? _isDeadHistoryUrl($currentUrl) : 0;
        my $actuallyInConnect = ($currentUrl =~ m{spoton://connect-})
                             && ($hasLiveMetadata || !$isDeadHistory);

        $log->warn("[DIAG] resume_check: streamUrl=" . ($currentUrl || 'undef')
            . " trackUrl=" . ($song ? ($song->track->url || 'undef') : 'no_song')
            . " hasLiveMetadata=" . ($hasLiveMetadata ? 1 : 0)
            . " isDeadHistory=" . ($isDeadHistory ? 1 : 0)
            . " actuallyInConnect=" . ($actuallyInConnect ? 1 : 0)
            . " isPlaying=" . ($client->isPlaying ? 1 : 0)
            . " isPaused=" . ($client->isPaused ? 1 : 0)
        ) if $diagMode;

        if (!$actuallyInConnect) {
            # History replay: _onPause already skipped the daemon forward, so this
            # resume event is spurious — drop it and let getNextTrack do the translation.
            if ($currentUrl =~ m{spoton://connect-}
                && !$hasLiveMetadata && _isDeadHistoryUrl($currentUrl)) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Dropping spurious resume for dead history URL — Browse pipeline handles playback"
                );

                $log->warn("[DIAG] [$diagTs] resume: player=" . $client->id
                    . " track=" . ($trackId || 'none')
                    . " position=" . ($position || 'none')
                    . " actuallyInConnect=0 deadHistory=1"
                    . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
                ) if $diagMode;

                return;
            }

            main::INFOLOG && $log->is_info && $log->info(
                "Resume while not on Connect stream — re-entering Connect via playlist play"
            );

            # Suppress transitional pause/stop events (same as 'start' handler):
            # newTrack prevents _onPause from forwarding the LMS stop-before-play
            # sequence to the binary, which would immediately re-pause Spotify.
            $client->pluginData(connectPauseTs => 0);
            $client->pluginData(newTrack => 1);
            _armNewTrackFallback($client);   # H7
            $client->pluginData(connectStartTime => Time::HiRes::time());

            if ($currentUrl =~ m{^spoton://} && $currentUrl !~ m{spoton://connect-}) {
                my $stopReq = Slim::Control::Request->new($client->id, ['stop']);
                $stopReq->source(__PACKAGE__);
                $stopReq->execute();
            }

            if ($trackId) {
                $client->pluginData(eventTrackUri => "spotify:track:$trackId");
            }

            my $ts      = int(Time::HiRes::time() * 1000);
            my $playReq = Slim::Control::Request->new($client->id, [
                'playlist', 'play',
                sprintf("spoton://connect-%u", $ts)
            ]);
            $playReq->source(__PACKAGE__);
            $playReq->execute();

            $client->pluginData(pendingConnect => 0);

            if ($trackId) {
                _fetchTrackMetadata($client, $trackId);
            }

            $log->warn("[DIAG] [$diagTs] resume: player=" . $client->id
                . " track=" . ($trackId || 'none')
                . " position=" . ($position || 'none')
                . " actuallyInConnect=0 reEntering=1"
                . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
            ) if $diagMode;

            return;
        }

        main::INFOLOG && $log->is_info && $log->info(
            "Resume event: trackId=$trackId position=$position"
        );

        # Unpause squeezelite — CRITICAL: use ['pause', 0] NOT ['play'].
        # ['play'] would open a new HTTP stream connection and break the
        # continuous PCM stream (Pitfall 1). Source-mark for T-05-13 loop prevention.
        $client->pluginData(connectPauseTs => Time::HiRes::time());
        my $unPauseReq = Slim::Control::Request->new($client->id, ['pause', 0]);
        $unPauseReq->source(__PACKAGE__);
        $unPauseReq->execute();

        # CON-13: Sync position via startOffset — NEVER use ['time', N] in stream mode.
        # startOffset adjusts songTime without triggering _JumpToTime -> _Stop + _Stream.
        if (defined $position && $position ne '') {
            my $song = $client->playingSong();
            if ($song) {
                my $elapsed = $client->songElapsedSeconds() || 0;
                $song->startOffset($position - $elapsed);
                main::INFOLOG && $log->is_info && $log->info(
                    "Resume: adjusted startOffset to " . $song->startOffset()
                );
            }
        }

        $log->warn("[DIAG] [$diagTs] resume: player=" . $client->id
            . " track=" . ($trackId || 'none')
            . " position=" . ($position || 'none')
            . " actuallyInConnect=1"
            . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
        ) if $diagMode;

        return;
    }

    # -----------------------------------------------------------------
    # Ignore stop events during initial new-track window (newTrack flag prevents
    # race between start event processing and LMS stop-before-play sequence)
    # -----------------------------------------------------------------
    if ($cmd eq 'stop' && $client->pluginData('newTrack')) {
        main::INFOLOG && $log->is_info && $log->info(
            "Ignoring stop event while starting new track"
        );
        return;
    }

    # -----------------------------------------------------------------
    # Start: issue playlist play with spoton://connect-<ts> URL
    # (CON-17: progress stored BEFORE playlist play command)
    # -----------------------------------------------------------------
    if ($cmd eq 'start') {
        my $trackId = $request->getParam('_p2');

        # Clear echo suppression — new track start is authoritative
        $client->pluginData(connectPauseTs => 0);

        # D-08 mutual exclusion: stop any Browse playback on this player
        my $song = $client->playingSong();
        my $currentUrl = $song ? ($song->streamUrl || '') : '';
        if ($currentUrl =~ m{^spoton://} && $currentUrl !~ m{spoton://connect-}) {
            main::INFOLOG && $log->is_info && $log->info(
                "D-08: Connect start stopping Browse playback on " . $client->id
            );
            my $stopReq = Slim::Control::Request->new($client->id, ['stop']);
            $stopReq->source(__PACKAGE__);
            $stopReq->execute();
        }

        # Mark new track in progress (prevents premature newsong handling)
        $client->pluginData(newTrack => 1);
        _armNewTrackFallback($client);   # H7
        $client->pluginData(connectStartTime => Time::HiRes::time());

        # CON-17: store progress from initial seek event (already set in 'seek' handler above)
        # The progress is stored in pluginData BEFORE we issue playlist play.
        # _onNewSong will read and apply it after the new Song object is created.

        # Stale-API-fallback: if API returns no track, use the binary's track_id
        if ($trackId) {
            $client->pluginData(eventTrackUri => "spotify:track:$trackId");
        }

        # The spoton://connect-<ts> URL signals Connect mode to ProtocolHandler.pm
        # which returns 'soc' from formatOverride() and provides canDirectStream URL.
        my $ts      = int(Time::HiRes::time() * 1000);
        my $playReq = Slim::Control::Request->new($client->id, [
            'playlist', 'play',
            sprintf("spoton://connect-%u", $ts)
        ]);
        $playReq->source(__PACKAGE__);
        $playReq->execute();

        $client->pluginData(pendingConnect => 0);

        # Fetch metadata for NowPlaying display via API::Client (D-13)
        if ($trackId) {
            _fetchTrackMetadata($client, $trackId);
        }

        $log->warn("[DIAG] [$diagTs] start: player=" . $client->id
            . " track=" . ($trackId || 'none')
            . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
        ) if $diagMode;

        return;
    }

    # -----------------------------------------------------------------
    # Change: track changed mid-playback (stream continues, metadata updates)
    # -----------------------------------------------------------------
    if ($cmd eq 'change') {
        # H6: ignore Spirc change events for players not in an active Connect
        # session — a change for a player back in Browse mode would overwrite
        # Browse metadata (known error: connect-metadata-bleed). pendingConnect
        # exception mirrors the seek handler (event may precede playlist play).
        unless (__PACKAGE__->isSpotifyConnect($client) || $client->pluginData('pendingConnect')) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Dropping Connect change event for non-Connect player " . $client->id . " (H6)");
            return;
        }

        my $newTrackId  = $request->getParam('_p2');
        my $prevTrackId = $request->getParam('_p3');

        # Clear echo suppression — track change is authoritative
        $client->pluginData(connectPauseTs => 0);

        main::INFOLOG && $log->is_info && $log->info(
            "Track change: $prevTrackId -> $newTrackId"
        );

        my $song = $client->playingSong();
        if ($song) {
            # Reset progress bar for the new track: in stream mode,
            # songElapsedSeconds counts from the original stream start,
            # so startOffset must compensate to reset songTime to ~0.
            my $elapsed = $client->songElapsedSeconds() || 0;
            $song->startOffset(0 - $elapsed);
            $client->playPoint(undef);
            $client->pluginData(progress => 0);
        }

        # Ensure player is playing — stop→change from skip leaves squeezelite paused.
        # (isSpotifyConnect re-check kept although the H6 top guard makes it
        # near-redundant: pendingConnect-only entry must not force playback.)
        if (!$client->isPlaying && __PACKAGE__->isSpotifyConnect($client)) {
            $client->pluginData(connectPauseTs => Time::HiRes::time());
            my $playReq = Slim::Control::Request->new($client->id, ['pause', 0]);
            $playReq->source(__PACKAGE__);
            $playReq->execute();
        }

        # Fetch metadata for the new track (D-13)
        if ($newTrackId) {
            $client->pluginData(eventTrackUri => "spotify:track:$newTrackId");
            _fetchTrackMetadata($client, $newTrackId);
        }

        $log->warn("[DIAG] [$diagTs] change: player=" . $client->id
            . " prev=" . ($prevTrackId || 'none')
            . " new=" . ($newTrackId || 'none')
            . " streamRestart=0"
            . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
        ) if $diagMode;

        return;
    }

    # -----------------------------------------------------------------
    # Stop: forward pause to LMS player (source-marked to prevent echo)
    # -----------------------------------------------------------------
    if ($cmd eq 'stop') {
        # Grace period: ignore spurious stop events during Connect session setup.
        # The binary fires Stopped between TrackChanged and Playing — this must not
        # pause the LMS player. Time-based check only (isPlaying is already true by
        # the time the stop arrives because playlist play was just issued).
        if ((Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0)) < CONNECT_START_GRACE)
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Ignoring spurious stop during Connect session setup grace period"
            );

            $log->warn("[DIAG] [$diagTs] stop: player=" . $client->id
                . " isPlaying=" . ($client->isPlaying ? 1 : 0)
                . " gracePeriod=1"
                . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
            ) if $diagMode;

            return;
        }

        if ($client->isPlaying && __PACKAGE__->isSpotifyConnect($client)) {
            main::INFOLOG && $log->is_info && $log->info(
                "Spotify told us to pause: " . $client->id
            );

            $client->pluginData(connectPauseTs => Time::HiRes::time());
            my $pauseReq = Slim::Control::Request->new($client->id, ['pause', 1]);
            $pauseReq->source(__PACKAGE__);
            $pauseReq->execute();
        }

        $log->warn("[DIAG] [$diagTs] stop: player=" . $client->id
            . " isPlaying=" . ($client->isPlaying ? 1 : 0)
            . " gracePeriod=0"
            . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
        ) if $diagMode;

        return;
    }

    # -----------------------------------------------------------------
    # Ready: Spirc reconnected internally (after session expiry or source switch).
    # Binary sends this after successfully completing a Spirc::new() reconnect.
    # Re-issue playlist play so LMS resumes streaming without user intervention.
    # T-05.3-06: guard checks $_activeConnectPlayer eq $client->id before acting.
    # T-05.3-07: source(__PACKAGE__) prevents the resulting playlist events from
    # echoing back to the binary (T-05-13 loop prevention).
    # -----------------------------------------------------------------
    if ($cmd eq 'ready') {
        main::INFOLOG && $log->is_info && $log->info(
            "Spirc reconnected (ready event) for " . $client->id . " — re-issuing Connect play"
        );

        # Only re-issue if this player was previously the active Connect player.
        # If not (e.g. another player took over), ignore.
        if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
            # M11: do not force-start playback if the user paused — a Spirc
            # reconnect must not override the paused state.
            if ($client->isPaused()) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Spirc ready but player is paused — not forcing playback (M11)"
                );
                return;
            }
            $client->pluginData(connectStartTime => Time::HiRes::time());
            my $ts      = int(Time::HiRes::time() * 1000);
            my $playReq = Slim::Control::Request->new($client->id, [
                'playlist', 'play',
                sprintf("spoton://connect-%u", $ts)
            ]);
            $playReq->source(__PACKAGE__);
            $playReq->execute();
        }
        return;
    }

    main::INFOLOG && $log->is_info && $log->info("Unhandled spottyconnect command: $cmd");
}

# _fetchTrackMetadata($client, $trackId)
# Fetches track metadata from Spotify Web API and updates NowPlaying display.
# Uses API::Client->getTrack() which routes via own-token (me/* path not needed here,
# track endpoint is accessible with own or bundled token).
sub _fetchTrackMetadata {
    my ($client, $trackId) = @_;

    return unless $trackId;

    require Plugins::SpotOn::API::Client;

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';
    $log->warn("[DIAG] metadata_fetch: mac=" . $client->id . " track=$trackId account=$accountId") if $prefs->get('diagnosticMode');

    Plugins::SpotOn::API::Client->getTrack($accountId, $trackId, sub {
        my ($trackInfo) = @_;

        # Stale-API protection (T-05-14 / Pitfall 5): the binary's event track_id
        # has priority over the API response. If event says different track, trust event.
        my $eventUri = $client->pluginData('eventTrackUri') || '';
        if ($trackInfo && $trackInfo->{uri} && $eventUri
            && $eventUri ne $trackInfo->{uri})
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Stale API response: event=$eventUri, API=" . $trackInfo->{uri} . " — using event (T-05-14)"
            );
            $log->warn("[DIAG] metadata_stale: mac=" . $client->id . " event_uri=$eventUri api_uri=" . ($trackInfo->{uri} || 'none')) if $prefs->get('diagnosticMode');
            _finishNewTrack($client);   # H7
            return;
        }

        # H7: EVERY exit path of this callback must clear newTrack — a leaked
        # flag swallows all subsequent stop events.
        unless ($trackInfo && $trackInfo->{name}) {
            _finishNewTrack($client);
            return;
        }

        my $song = $client->playingSong();
        unless ($song) {
            _finishNewTrack($client);
            return;
        }

        my $title    = $trackInfo->{name};
        my $artist   = join(', ', map { $_->{name} } @{ $trackInfo->{artists} || [] });
        my $album    = ($trackInfo->{album} || {})->{name} || '';
        my $duration = ($trackInfo->{duration_ms} || 0) / 1000;
        my $cover    = _largestImage(($trackInfo->{album} || {})->{images}) || IMG_TRACK;

        # Instant display update
        Slim::Music::Info::setCurrentTitle(
            $song->streamUrl,
            "$artist - $title",
            $client
        );

        # Full metadata for Now Playing display
        require Plugins::SpotOn::Plugin;
        my $type_str = Plugins::SpotOn::Plugin->_typeString($client, 'Connect');
        my $bitrate = Plugins::SpotOn::Plugin->_bitrateForClient($client);
        $song->pluginData(info => {
            title        => $title,
            artist       => $artist,
            album        => $album,
            duration     => $duration,
            cover        => $cover,
            url          => $song->streamUrl,
            bitrate      => $bitrate . 'k',
            originalType => $type_str,
            type         => $type_str,
        });

        # D-01/D-02: Persist Connect metadata to cache for history replay
        # Cache key uses connect-timestamp URL; spotifyUri enables future Browse translation.
        my $cacheUrl = $song->track->url || $song->streamUrl;
        if ($cacheUrl) {
            my %trackIds = Plugins::SpotOn::Plugin::_extractTrackIds($trackInfo);
            $cache->set(
                'spoton_meta_' . md5_hex($cacheUrl),
                {
                    title      => $title,
                    artist     => $artist,
                    album      => $album,
                    duration   => $duration,
                    cover      => $cover,
                    icon       => $cover,
                    bitrate    => $bitrate . 'k',
                    type       => $type_str,
                    spotifyUri => $trackInfo->{uri},
                    %trackIds,
                },
                604800,
            );
        }

        # Update song duration for progress bar
        if ($duration) {
            $song->duration($duration);
            $client->streamingProgressBar({
                url      => $song->streamUrl,
                duration => $duration,
            });
        }

        # Update playlist timestamp so polling clients (WiiM, web UI) detect the change
        $client->currentPlaylistUpdateTime(Time::HiRes::time());

        # Fire newmetadata notification so LMS refreshes Now Playing
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

        # Clear newTrack flag — initial metadata fetch complete (H7: also
        # kills the fallback timer)
        _finishNewTrack($client);

        main::INFOLOG && $log->is_info && $log->info(
            "Track metadata updated: $title — $artist"
        );
        $log->warn("[DIAG] metadata_success: mac=" . $client->id . " track=$trackId title=$title duration=$duration") if $prefs->get('diagnosticMode');
    });
}

sub _largestImage { Plugins::SpotOn::Plugin::_largestImage(@_) }

1;
