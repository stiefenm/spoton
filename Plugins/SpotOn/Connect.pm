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

# Seconds; Phase 76 (ROADMAP: auto-play after LMS restart) — a freshly
# (re)spawned daemon re-announces an existing dormant Spirc session as
# track_changed/start with NO user action (live-captured sequence, 76-05
# SUMMARY: daemon spawn +0.43s -> 'start' -> unconditional playlist play ->
# the real paused state arrives as 'stop' +45ms later and is swallowed by
# CONNECT_START_GRACE). A genuine app-initiated transfer cannot arrive this
# close to the daemon's own spawn: the device only becomes transferable
# after the daemon has connected to Spotify, and a human still has to tap
# it. All captured re-announcements arrived at daemon uptime < 1s.
use constant RESTART_START_GRACE => 5;

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
# Used by ProtocolHandler to suppress the LMS-side stream restart on seek
# (getSeekData returns undef; the seek is forwarded to the binary instead).
sub isSpotifyConnect {
    my ($class, $client) = @_;

    return unless $client;
    $client = $client->master if $client->can('master');

    return $_activeConnectPlayer && $_activeConnectPlayer eq $client->id ? 1 : 0;
}

sub _releaseConnectClaim {
    my ($class, $client) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');
    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        $_activeConnectPlayer = undef;
        $client->pluginData(pendingConnect => 0);
    }
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

# _isSoloistOwnedSong($client)
# Phase 78-04: Soloist ownership criterion.  Returns true iff the client's
# registered helper is a SoloistDaemon with a connected WS and a defined
# lastTrackId, AND the current song URL (via _currentSpotonTrackUrl) matches
# spoton://track:<lastTrackId> or spoton://episode:<lastTrackId>.  This
# replaces the m{spoton://connect-} live-URL semantic for Soloist Connect
# sessions — under D-04 Connect tracks use spoton://track:ID URLs, so the
# old URL-scheme test no longer discriminates Browse from Connect.
#
# Accepted edge case (documented inline per plan): a user manually
# Browse-playing the EXACT track the daemon is announcing while a Connect
# claim is set will not release the claim until the next differing track.
sub _isSoloistOwnedSong {
    my ($client) = @_;
    return 0 unless $client;
    $client = $client->master if $client->can('master');

    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
    return 0 unless $helper && $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon');

    my $ws = $helper->_ws;
    return 0 unless $ws && $ws->connected;

    my $lastId = $ws->lastTrackId;
    return 0 unless defined $lastId && $lastId ne '';

    my $currentUrl = _currentSpotonTrackUrl($client);
    return 0 unless $currentUrl;

    # Match spoton://track:<id> or spoton://episode:<id>
    return ($currentUrl =~ m{^spoton://(?:track|episode):\Q$lastId\E$}) ? 1 : 0;
}

# _isLiveConnectStream($client)
# D-16: returns true iff the player has a playing song whose URL is a
# spoton://connect-* stream (librespot Connect) OR a Soloist-owned
# spoton://track: song (Soloist Connect under D-04).  Uses track->url
# first, then streamUrl fallback (Phase 44 pattern: on a direct-streamed
# session streamUrl becomes the http://…/stream proxy URL, so
# streamUrl-only would false-negative).
sub _isLiveConnectStream {
    my ($client) = @_;
    return 0 unless $client;
    $client = $client->master if $client->can('master');
    my $song = $client->playingSong();
    return 0 unless $song;
    my $url = $song->track->url || $song->streamUrl || '';

    # librespot path: spoton://connect-* URL (unchanged)
    if ($url =~ m{spoton://connect-}) {
        # WR-01: dead-history connect URLs survive in restored playlists —
        # same distinction the unpause guard (§697-706) and resume handler
        # (§1011-1018) already apply.
        return 0 if !$song->pluginData('info') && _isDeadHistoryUrl($url);
        return 1;
    }

    # Soloist path (D-04): spoton://track:ID entries — a Soloist Connect
    # session has no connect- URL anymore, so check ownership via the
    # daemon's lastTrackId.
    if (__PACKAGE__->isSpotifyConnect($client) && _isSoloistOwnedSong($client)) {
        return 1;
    }

    return 0;
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

# _currentSpotonTrackUrl($client)
# Returns the current song URL if it matches ^spoton://(?:track|episode):,
# or '' otherwise.  Uses track->url first (authoritative spoton:// URI),
# then streamUrl fallback — during a track transition only streamingSong
# carries the new URL, so check streamingSong before playingSong (Phase 44
# pattern).  Shared by _soloistBrowseWs, the echo/confirmation guard in
# _connectEvent, and plan 78-04's ownership criterion.
sub _currentSpotonTrackUrl {
    my ($client) = @_;
    return '' unless $client;
    $client = $client->master if $client->can('master');

    # Check streamingSong first (carries the new URL during a transition),
    # then fall back to playingSong (stable after the transition completes).
    for my $accessor (qw(streamingSong playingSong)) {
        my $song = $client->controller->$accessor();
        next unless $song;
        my $url = $song->track->url || '';
        return $url if $url =~ m{^spoton://(?:track|episode):};
    }
    return '';
}

# _soloistBrowseWs($client)
# Phase 78-02: bounded-model criterion.  Returns the SoloistWS instance
# when the player is in a Soloist Browse session (NOT Connect): the
# registered helper is a SoloistDaemon, WS is connected, the player does
# not hold an active Connect claim, and the current song is a
# spoton://track: or spoton://episode: URL.  Used by _onPause/_onSeek to
# forward LMS-originated transport commands to the daemon during bounded
# Browse playback — a browse session is not a Connect session
# (isSpotifyConnect is false), so it needs its own forwarding branch.
sub _soloistBrowseWs {
    my ($client) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');

    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
    return unless $helper && $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon');

    my $ws = $helper->_ws;
    return unless $ws && $ws->connected;

    # A Connect session uses the Connect forwarding path below, not this one.
    return if __PACKAGE__->isSpotifyConnect($client);

    # The current song must be a spoton://track: or spoton://episode: URL —
    # the player is streaming bounded Soloist audio.
    my $url = _currentSpotonTrackUrl($client);
    return unless $url =~ m{^spoton://(?:track|episode):};

    return $ws;
}

# _soloistConnectWs($client)
# 260827-of9 (~30s Connect-skip audio delay): returns the SoloistWS instance
# for this client when its registered helper is a SoloistDaemon, else undef.
# Unlike _soloistBrowseWs above, this does NOT require the bounded-model
# criterion — the 'change' handler needs to read/consume skipInitiated
# during a Connect session.
sub _soloistConnectWs {
    my ($client) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');

    require Plugins::SpotOn::Unified::DaemonManager;
    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
    return unless $helper && $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon');

    return $helper->_ws;
}

# _seekPositionFromRequest($client, $request)
# Shared by the Connect and soloist-browse seek forwarders (GH #129
# pattern): extracts the absolute target position (seconds) from a
# ['time', N] request, resolving relative (+N/-N) deltas against the
# current songTime. Never negative.
sub _seekPositionFromRequest {
    my ($client, $request) = @_;

    my $newvalue = $request->getParam('_newvalue');
    my $position;
    if (defined $newvalue && $newvalue =~ /^[+-]/) {
        $position = (Slim::Player::Source::songTime($client) || 0) + $newvalue;
    } elsif (defined $newvalue) {
        $position = $newvalue;
    } else {
        $position = Slim::Player::Source::songTime($client) || 0;
    }
    $position = 0 if $position < 0;
    return $position;
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
#
# Phase 73-02 (D-06): single dispatch point for backend routing. When the
# registered helper for this player is a SoloistDaemon, the endpoint is
# translated into the Soloist WS command vocabulary (RESEARCH Pattern 3) and
# sent over the daemon's WS connection instead of POSTing to librespot's
# HTTP /control/* port (which soloist doesn't serve -- that port instead
# serves fake-libpulse's PCM /stream). When the WS is absent/disconnected or
# sendCommand() fails, falls through to the same Web API fallback used by
# the librespot path (D-15 parity -- same Spotify account, same player
# endpoints). The librespot HTTP path below this block is unmodified.
sub _sendControlCommand {
    my ($client, $endpoint, $body) = @_;
    return unless $client;

    require Plugins::SpotOn::Unified::DaemonManager;

    my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
    if ($helper && $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon')) {
        my %endpointToCommand = (
            '/control/pause'  => 'pause',
            '/control/play'   => 'play',      # no uri: resume semantics
            '/control/next'   => 'skip_next',
            '/control/prev'   => 'skip_prev',
            '/control/seek'   => 'seek',
            '/control/volume' => 'set_volume',
        );
        my $command = $endpointToCommand{$endpoint};

        unless ($command) {
            main::INFOLOG && $log->is_info && $log->info(
                "_sendControlCommand: no soloist WS mapping for $endpoint, skipping"
            );
            return;
        }

        my %params;
        if ($command eq 'seek' && $body && defined $body->{position_ms}) {
            $params{position_ms} = $body->{position_ms};
        }
        elsif ($command eq 'set_volume' && $body && defined $body->{volume}) {
            $params{volume} = int($body->{volume});
        }

        $log->warn("[DIAG] control_cmd_sent: mac=" . $client->id . " endpoint=$endpoint backend=soloist command=$command") if $prefs->get('diagnosticMode');

        my $ws   = $helper->_ws;
        my $sent = ($ws && $ws->connected) ? $ws->sendCommand($command, %params) : 0;

        if ($sent) {
            main::INFOLOG && $log->is_info && $log->info(
                "_sendControlCommand: $endpoint -> soloist WS command '$command' sent"
            );
            $log->warn("[DIAG] control_cmd_ok: mac=" . $client->id . " endpoint=$endpoint backend=soloist command=$command") if $prefs->get('diagnosticMode');
            return;
        }

        main::INFOLOG && $log->is_info && $log->info(
            "_sendControlCommand: $endpoint via soloist WS unavailable (ws down or send failed) -- Web API fallback (D-15)"
        );
        $log->warn("[DIAG] control_cmd_fail: mac=" . $client->id . " endpoint=$endpoint backend=soloist fallback=web_api") if $prefs->get('diagnosticMode');
        _sendControlFallback($client, $endpoint, $body);
        return;
    }

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
            my ($http, $error, $response) = @_;

            # GH #159: the daemon answers 409 Conflict when Spirc dropped the
            # command because this device is no longer the active Connect
            # target (deselected in the Spotify app). SimpleAsyncHTTP routes
            # every non-2xx/3xx response through this error callback; the
            # response object (third arg, newer LMS) carries the code, and
            # $error holds the status line ("409 Conflict") as a fallback for
            # LMS versions whose onError only passes two args.
            my $code = ($response && blessed($response) && $response->can('code'))
                ? ($response->code || 0) : 0;
            $code ||= ($error && $error =~ /^(\d{3})\b/) ? $1 : 0;

            if ($code == 409) {
                $log->warn(
                    "_sendControlCommand: $endpoint rejected for " . $client->id
                    . " — device is not the active Connect target (GH #159); ejecting stale stream"
                );
                $log->warn("[DIAG] control_cmd_rejected: mac=" . $client->id . " endpoint=$endpoint code=409") if $prefs->get('diagnosticMode');

                # Eject the stale stream so LMS leaves BUFFERING-STREAMING
                # instead of hanging until the device is re-selected.
                # source(__PACKAGE__) prevents _onPause from echoing the stop
                # back to the daemon (T-05-13 / T-76-05).
                my $stopReq = Slim::Control::Request->new($client->id, ['stop']);
                $stopReq->source(__PACKAGE__);
                $stopReq->execute();

                # Deliberately NO _sendControlFallback here: the Web API PUT
                # would act on the user's actually-active device — exactly
                # wrong for a command meant for this (deselected) player.
                return;
            }

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

    # D-16: extract the new song's URL once, using the Phase-44-safe pattern
    # (track->url first, then streamUrl fallback). Phase 44 lesson (§935-940):
    # track->url is the original spoton://connect-* URL; streamUrl becomes the
    # http://…/stream proxy URL after canDirectStream resolves it — a
    # streamUrl-only check false-negatives on live direct-streamed sessions.
    # Shared by WR-06, CON-17, and the D-16 stale-claim release below.
    my $song = $client->playingSong();
    my $url  = $song ? ($song->track->url || $song->streamUrl || '') : '';

    # CON-17: Apply stored progress for Connect sessions.
    # D-16 fix: the old predicate was `isSpotifyConnect($client)` alone, which
    # tested the same condition as the release block below ($_ activeConnectPlayer
    # eq $client->id) — making the release block dead code. Now requires BOTH the
    # ownership claim AND an actual connect-* URL (librespot) or Soloist-owned
    # song (D-04).  Progress application only makes sense on a real Connect
    # stream, not on a dormant claim-set-but-Browse-playing state.
    if (__PACKAGE__->isSpotifyConnect($client)
        && ($url =~ m{spoton://connect-} || _isSoloistOwnedSong($client)))
    {
        if (my $progress = $client->pluginData('progress')) {
            $client->pluginData(progress => 0);

            if (_isStreamMode($client)) {
                # Stream-mode: binary streams from current position. Adjust
                # startOffset so songTime reports the correct position without
                # triggering _JumpToTime → _Stop + _Stream.
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

    # D-16: Stale-claim release — re-keyed for D-04.  Release the Connect
    # claim when the new song is NOT a live Connect stream: for librespot
    # that means no connect- URL; for Soloist that means not owned by the
    # daemon (_isSoloistOwnedSong).  Under D-04 every Soloist Connect track
    # fires a newsong with a track: URL — this re-key prevents the claim
    # from being released on each track transition (Pitfall 2).
    # Accepted edge (inline per plan): a user manually Browse-playing the
    # exact track the daemon announces will not release the claim until
    # the next differing track.
    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        unless ($url =~ m{spoton://connect-} || _isSoloistOwnedSong($client)) {
            main::INFOLOG && $log->is_info && $log->info(
                "D-16: new song without Connect URL — releasing stale Connect claim for " . $client->id
            );
            $_activeConnectPlayer = undef;
            # D-16: belt-and-braces with Task 1 — a stale claim implies a
            # stale pending flag.
            $client->pluginData(pendingConnect => 0);

            # GH #151: session over because the user started other playback —
            # discard the saved power state WITHOUT powering off (the player
            # is obviously in use).
            if (defined $client->pluginData('connectPrevPower')) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Discarding saved pre-Connect power state for " . $client->id
                    . " — user started other playback (GH #151)"
                );
                $client->pluginData(connectPrevPower => undef);
            }
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

    # Phase 78-02: bounded-model Browse forwarding.  A Soloist Browse
    # session is NOT a Connect session (isSpotifyConnect is false), so LMS
    # pause/unpause must be forwarded to the daemon via WS here — otherwise
    # the daemon keeps decoding, the ring fills, and fake-libpulse's 2s
    # POLLOUT timeout closes the bounded HTTP connection (Pitfall 4).
    # Checked BEFORE the isSpotifyConnect guard so browse forwarding is not
    # shadowed by it.
    #
    # Phase 78 fix: LMS's internal stop of the previous playlist entry
    # during a track transition arrives here as an un-sourced pause.  If a
    # WS 'play' was just sent (pendingPlayConfirm), forwarding this pause
    # would kill the new playback — the daemon processes play then pause,
    # and pause wins.  Suppress the forward during the play-confirm window.
    if (my $browseWs = _soloistBrowseWs($client)) {
        if ($browseWs->can('pendingPlayConfirm') && $browseWs->pendingPlayConfirm && !$isUnpause) {
            main::INFOLOG && $log->is_info && $log->info(
                "Soloist browse: suppressing pause/stop forward — play command pending"
            );
            return;
        }
        if ($isUnpause) {
            main::INFOLOG && $log->is_info && $log->info(
                "Soloist browse: forwarding unpause to daemon via WS play (resume)"
            );
            $browseWs->sendCommand('play');
        }
        elsif ($request->isCommand([['playlist'], ['stop']])) {
            # LMS stop — the daemon must stop decoding so the ring does not
            # run drop-oldest against a closed/blocked socket.  No session
            # teardown in the bounded model (no browseSession state machine).
            main::INFOLOG && $log->is_info && $log->info(
                "Soloist browse: forwarding LMS stop to daemon via WS pause"
            );
            $browseWs->sendCommand('pause');
        }
        else {
            main::INFOLOG && $log->is_info && $log->info(
                "Soloist browse: forwarding pause to daemon via WS pause"
            );
            $browseWs->sendCommand('pause');
        }
        return;
    }

    return unless __PACKAGE__->isSpotifyConnect($client);

    # D-16 stale-claim guard (RC-2): the ownership claim is set but this
    # pause/stop does NOT belong to a live Connect session.  Without this
    # guard a Browse 'playlist play' (which internally stops the previous
    # item) would fall through to the isSpotifyConnect gate — true via the
    # dormant claim — and forward /control/pause to the daemon, pausing
    # the very session the Browse play is trying to start.
    # Guards: (a) no live connect-* song URL on the player — protects live
    # sessions including direct-streamed ones (track->url stays
    # spoton://connect-*); (b) pendingConnect is not set — protects the
    # legitimate start window where the claim exists before the connect-*
    # song does; (c) connectStartTime grace has expired — also protects
    # the start window.
    if (!_isLiveConnectStream($client)
        && !$client->pluginData('pendingConnect')
        && Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0) >= CONNECT_START_GRACE)
    {
        main::INFOLOG && $log->is_info && $log->info(sprintf(
            "D-16: stale Connect claim on %s — no live connect stream, no pending start, "
            . "grace expired (%.1fs ago). Releasing claim, NOT forwarding pause to daemon.",
            $client->id,
            Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0)
        ));
        $_activeConnectPlayer = undef;
        $client->pluginData(pendingConnect => 0);
        return;
    }

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
        # GH #158: LMS-side unpause resumes the Spotify session — clear the
        # remembered pause state immediately (the daemon's own resume/playing
        # echo would clear it too, but not before the next change could race).
        $client->pluginData(connectSessionPaused => 0);
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

    # Phase 78-02: bounded-model Browse seek forwarding.  LMS now DOES
    # restart the stream for Soloist Browse (getSeekData returns
    # timeOffset); the WS seek runs in parallel so the daemon flushes and
    # repositions while LMS is rebuilding the connection.  Documented race
    # (RESEARCH Pitfall 5): if the new GET arrives before the daemon flush,
    # a brief burst of pre-seek audio may be heard before the
    # flush-disconnect closes the stale connection and LMS retries.
    # Separate timer key (_bufferedBrowseSeek is a distinct coderef from
    # _bufferedSeek) so the Connect and browse debounces cannot collide.
    if (my $browseWs = _soloistBrowseWs($client)) {
        my $position   = _seekPositionFromRequest($client, $request);
        my $positionMs = int($position * 1000);

        Slim::Utils::Timers::killTimers($client, \&_bufferedBrowseSeek);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SEEK_DEBOUNCE, \&_bufferedBrowseSeek, $positionMs);
        return;
    }

    return unless __PACKAGE__->isSpotifyConnect($client);

    # GH #129: read the seek target from the request instead of songTime —
    # with getSeekData returning undef in Connect mode, LMS does not restart
    # the stream, so songTime still holds the OLD position at this point.
    my $position   = _seekPositionFromRequest($client, $request);
    my $positionMs = int($position * 1000);

    # Debounce: coalesce rapid seek events (0.3s window)
    Slim::Utils::Timers::killTimers($client, \&_bufferedSeek);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SEEK_DEBOUNCE, \&_bufferedSeek, $positionMs);
}

# _bufferedBrowseSeek($client, $positionMs)
# Phase 78-02: debounced soloist-browse seek forward — re-checks the
# bounded criterion (the player may have stopped during the debounce
# window) before sending.
sub _bufferedBrowseSeek {
    my ($client, $positionMs) = @_;

    my $browseWs = _soloistBrowseWs($client);
    return unless $browseWs;

    main::INFOLOG && $log->is_info && $log->info(
        "Soloist browse: forwarding seek to daemon via WS seek: ${positionMs}ms"
    );
    $log->warn("[DIAG] browse_seek_to_daemon: mac=" . $client->id . " position_ms=$positionMs debounced=" . SEEK_DEBOUNCE . "s") if $prefs->get('diagnosticMode');

    $browseWs->sendCommand('seek', position_ms => $positionMs);
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

    # KE: browse-connect-gating -- Browse/Connect discrimination for the
    # Soloist backend now happens UPSTREAM in SoloistWS.pm, via the explicit
    # soloistBrowseActive flag (set by ProtocolHandler::getNextTrack's WS
    # 'play' dispatch, cleared only by a genuine
    # SoloistWS::_onDeviceChanged(is_active:true)). While that flag is set,
    # SoloistWS::_emit() never dispatches a spottyconnect request at all --
    # this handler simply never sees a Soloist Browse echo or auto-advance.
    # The previous per-event guards here (78-02/78-04, trackId/URL matching
    # against _currentSpotonTrackUrl) were removed: they raced against LMS
    # song state that had not necessarily settled by the time the event
    # arrived (debug session
    # .planning/debug/resolved/browse-connect-gating.md).

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
                    Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
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
        # Phase 78-04: Soloist Connect sessions use spoton://track:ID URLs,
        # so also check _isSoloistOwnedSong as "on Connect stream".
        my $hasLiveMetadata = $song && $song->pluginData('info');
        my $isDeadHistory = $currentUrl =~ m{spoton://connect-} ? _isDeadHistoryUrl($currentUrl) : 0;
        my $actuallyInConnect = (($currentUrl =~ m{spoton://connect-})
                             && ($hasLiveMetadata || !$isDeadHistory))
                             || _isSoloistOwnedSong($client);

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

            # GH #151: this re-entry powers the player on (playlist play
            # below) — save the pre-Connect power state if no session save
            # exists yet (e.g. a restart-suppressed session resuming here;
            # first save wins, same rule as the start handler).
            if (!defined $client->pluginData('connectPrevPower')) {
                $client->pluginData(connectPrevPower => ($client->power ? 1 : 0));
                main::INFOLOG && $log->is_info && $log->info(
                    "Saved pre-Connect power state for " . $client->id . ": "
                    . ($client->pluginData('connectPrevPower') ? 'on' : 'off') . " (GH #151)"
                );
            }

            # CR-01: re-establish ownership — 'resume' is the only entry path
            # after a D-16 stale-claim release; 'start' will not fire for a
            # restored session that already has a current track.
            if ($_activeConnectPlayer && $_activeConnectPlayer ne $client->id) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Player switch on resume re-entry: " . $_activeConnectPlayer . " -> " . $client->id);
            }
            $_activeConnectPlayer = $client->id;

            # Suppress transitional pause/stop events (same as 'start' handler):
            # newTrack prevents _onPause from forwarding the LMS stop-before-play
            # sequence to the binary, which would immediately re-pause Spotify.
            $client->pluginData(connectPauseTs => 0);
            $client->pluginData(connectSessionPaused => 0);   # GH #158: resuming
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

            # D-04 backend dispatch: Soloist Connect uses spoton://track:ID
            # entries (same audio contract as Browse); librespot keeps the
            # repeating-stream spoton://connect-<ts> URL (Windows constraint).
            my $playUrl;
            require Plugins::SpotOn::Unified::DaemonManager;
            my $resumeHelper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
            if ($resumeHelper && $resumeHelper->isa('Plugins::SpotOn::Unified::SoloistDaemon') && $trackId) {
                $playUrl = "spoton://track:$trackId";
            } else {
                # librespot path: repeating-stream with unique timestamp URL
                my $ts = int(Time::HiRes::time() * 1000);
                $playUrl = sprintf("spoton://connect-%u", $ts);
            }
            my $playReq = Slim::Control::Request->new($client->id, [
                'playlist', 'play', $playUrl
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
                . " url=$playUrl"
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
        $client->pluginData(connectSessionPaused => 0);   # GH #158: session resumed
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

        # KE: browse-connect-gating -- the old 78-02 echo guard here (trackId
        # match against _currentSpotonTrackUrl) is gone. A Soloist Browse
        # echo never reaches this handler at all now: SoloistWS::_emit()
        # suppresses it at the source while soloistBrowseActive is set. Any
        # 'start' that arrives here for a Soloist backend is by construction
        # a genuine Connect transfer (device_changed(is_active:true) is what
        # clears soloistBrowseActive right before SoloistWS emits it).

        # ROADMAP Phase 76 (auto-play after LMS restart): provenance gate.
        # A 'start' arriving within RESTART_START_GRACE of the daemon's own
        # (re)spawn while the LMS player is idle is a re-announcement of a
        # restored/dormant session — NOT a fresh user transfer (see constant
        # comment for the captured event sequence). Suppress the playlist
        # play (no self-starting audio), but keep the session visible and
        # manually resumable: metadata is still fetched, and a later play
        # tap in the Spotify app arrives as 'resume' whose not-on-Connect-
        # stream branch re-enters via playlist play normally.
        #
        # D-16 (RC-2 stale-claim hygiene): the ownership claim
        # $_activeConnectPlayer deliberately STAYS (the dormant session
        # remains identifiable and manually resumable), but pendingConnect
        # must NOT — it is strictly the start-event-precedes-playlist-play
        # window flag (used by the change/seek handlers' || pendingConnect
        # exceptions), and leaking it lets those handlers manipulate
        # whatever the player is actually doing (metadata bleed, KE
        # connect-metadata-bleed) for the lifetime of the dormant session.
        # The non-suppressed path clears it at the playlist-play site
        # (line after $playReq->execute); the resume re-entry path clears
        # it likewise. This suppressed branch must clear it too.
        #
        # The isPlaying exception preserves daemon-crash recovery: if the
        # player was already audibly playing when the daemon respawned,
        # resuming the stream is not a "self-start".
        # (Unrelated to pref_enableAutoplay — that is DSTM autoplay.)
        require Plugins::SpotOn::Unified::DaemonManager;
        my $daemonUptime = Plugins::SpotOn::Unified::DaemonManager->uptime($client->id) || 0;
        if (!$client->isPlaying && $daemonUptime > 0 && $daemonUptime < RESTART_START_GRACE) {
            main::INFOLOG && $log->is_info && $log->info(sprintf(
                "Suppressing Connect autoplay for %s: start event %.2fs after daemon spawn "
                . "with idle player — restored session, not a user transfer (Phase 76 restart gate)",
                $client->id, $daemonUptime
            ));

            if ($trackId) {
                $client->pluginData(eventTrackUri => "spotify:track:$trackId");
                _fetchTrackMetadata($client, $trackId);
            }

            $log->warn("[DIAG] [$diagTs] start_suppressed: player=" . $client->id
                . " track=" . ($trackId || 'none')
                . " daemonUptime=" . sprintf('%.2f', $daemonUptime)
            ) if $diagMode;

            # D-16: clear the start-window flag — the playlist play was
            # suppressed, so there is no pending start to protect.
            $client->pluginData(pendingConnect => 0);

            return;
        }

        # GH #151: save the pre-Connect power state ONCE per session, BEFORE
        # the playlist play below powers the player on. First save wins:
        # repeated start events within one session (transfer away/back,
        # Spirc reconnect) must not overwrite the saved value with the
        # now-on state. Cleared at a real session end (stop 'inactive'
        # marker) or when the user starts other playback (_onNewSong).
        if (!defined $client->pluginData('connectPrevPower')) {
            $client->pluginData(connectPrevPower => ($client->power ? 1 : 0));
            main::INFOLOG && $log->is_info && $log->info(
                "Saved pre-Connect power state for " . $client->id . ": "
                . ($client->pluginData('connectPrevPower') ? 'on' : 'off') . " (GH #151)"
            );
        }

        # Clear echo suppression — new track start is authoritative
        $client->pluginData(connectPauseTs => 0);
        # GH #158: a fresh session start supersedes any remembered pause state
        $client->pluginData(connectSessionPaused => 0);

        # D-08 mutual exclusion: stop any Browse playback on this player.
        # Phase 78-04: do not stop a Soloist-owned Connect session (the
        # Connect re-start is re-announcing the same daemon session).
        my $song = $client->playingSong();
        my $currentUrl = $song ? ($song->streamUrl || '') : '';
        if ($currentUrl =~ m{^spoton://} && $currentUrl !~ m{spoton://connect-}
            && !_isSoloistOwnedSong($client))
        {
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

        # D-04 backend dispatch: Soloist Connect uses spoton://track:ID
        # entries (same audio contract as Browse); librespot keeps the
        # repeating-stream spoton://connect-<ts> URL (Windows constraint).
        # $trackId is already in scope from _p2 above.
        my $startPlayUrl;
        {
            require Plugins::SpotOn::Unified::DaemonManager;
            my $startHelper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
            if ($startHelper && $startHelper->isa('Plugins::SpotOn::Unified::SoloistDaemon') && $trackId) {
                $startPlayUrl = "spoton://track:$trackId";
            } else {
                # librespot path: repeating-stream with unique timestamp URL
                my $ts = int(Time::HiRes::time() * 1000);
                $startPlayUrl = sprintf("spoton://connect-%u", $ts);
            }
        }
        my $playReq = Slim::Control::Request->new($client->id, [
            'playlist', 'play', $startPlayUrl
        ]);
        $playReq->source(__PACKAGE__);
        $playReq->execute();

        $client->pluginData(pendingConnect => 0);

        # Fetch metadata for NowPlaying display via API::SpClient (D-08/D-13)
        if ($trackId) {
            _fetchTrackMetadata($client, $trackId);
        }

        $log->warn("[DIAG] [$diagTs] start: player=" . $client->id
            . " track=" . ($trackId || 'none')
            . " url=$startPlayUrl"
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
            # The client push for this reset happens later, from
            # _fetchTrackMetadata's exit paths (Phase 58) -- pushing it here
            # would announce position=0 before the real position is known.
            my $elapsed = $client->songElapsedSeconds() || 0;
            $song->startOffset(0 - $elapsed);
            $client->playPoint(undef);
            $client->pluginData(progress => 0);
        }

        # Ensure player is playing — stop→change from skip leaves squeezelite paused.
        # (isSpotifyConnect re-check kept although the H6 top guard makes it
        # near-redundant: pendingConnect-only entry must not force playback.)
        # GH #158: NEVER force-unpause while the Spotify session itself is
        # paused (connectSessionPaused, tracked from stop/resume events). A
        # skip while user-paused delivers a 'change' with Spotify STILL
        # paused — the old unconditional unpause here made LMS stream
        # against a paused (data-less) source, which on sync groups spirals
        # into a rebuffer/restart loop ("song starts over and over"). The
        # later user play arrives as 'resume' and unpauses normally.
        if (!$client->isPlaying && __PACKAGE__->isSpotifyConnect($client)
            && !$client->pluginData('connectSessionPaused')) {
            $client->pluginData(connectPauseTs => Time::HiRes::time());
            my $playReq = Slim::Control::Request->new($client->id, ['pause', 0]);
            $playReq->source(__PACKAGE__);
            $playReq->execute();
        }

        # D-04 backend dispatch (change handler): Soloist Connect dispatches
        # a new spoton://track:$newTrackId entry for EVERY track change.
        # D-05 makes the daemon's flush-disconnect itself the EOF, so the
        # skipInitiated reconnect special-path is bypassed for Soloist.
        # librespot 'change' handling stays byte-identical below this block.
        {
            require Plugins::SpotOn::Unified::DaemonManager;
            my $changeHelper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
            if ($changeHelper && $changeHelper->isa('Plugins::SpotOn::Unified::SoloistDaemon') && $newTrackId) {
                $client->pluginData(eventTrackUri => "spotify:track:$newTrackId");
                _fetchTrackMetadata($client, $newTrackId);

                # Every Soloist 'change' dispatches a new playlist entry —
                # flush-disconnect (D-05) delivers the EOF for the previous
                # track; this playlist play starts the next one.
                my $changePlayUrl = "spoton://track:$newTrackId";
                $client->pluginData(connectSessionPaused => 0);
                $client->pluginData(connectStartTime => Time::HiRes::time());
                my $changePlayReq = Slim::Control::Request->new($client->id, [
                    'playlist', 'play', $changePlayUrl
                ]);
                $changePlayReq->source(__PACKAGE__);
                $changePlayReq->execute();

                $log->warn("[DIAG] [$diagTs] change: player=" . $client->id
                    . " prev=" . ($prevTrackId || 'none')
                    . " new=" . ($newTrackId || 'none')
                    . " url=$changePlayUrl backend=soloist"
                    . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
                ) if $diagMode;

                return;
            }
        }

        # Fetch metadata for the new track (D-13) — librespot path
        if ($newTrackId) {
            $client->pluginData(eventTrackUri => "spotify:track:$newTrackId");
            _fetchTrackMetadata($client, $newTrackId);
        }

        # 260827-of9: Soloist skip -- this handler otherwise never issues
        # `playlist play` for a mid-session track change, so squeezelite
        # keeps the persistent /stream connection open and must drain
        # 10-20s of stale buffered audio before the new track is heard.
        # Only fires for a REAL app-initiated skip (SoloistWS::skipInitiated,
        # set when sessionPaused was already true before this track_changed
        # arrived) -- a gapless transition leaves skipInitiated=0 and stays
        # on the persistent stream untouched (T-quick-02).
        my $soloistWs = _soloistConnectWs($client);
        if ($soloistWs && $soloistWs->skipInitiated) {
            $soloistWs->skipInitiated(0);    # consume the flag
            # GH #158: the forced reconnect below starts playback — any
            # remembered session-pause state is superseded.
            $client->pluginData(connectSessionPaused => 0);

            my $ts      = int(Time::HiRes::time() * 1000);
            my $playReq = Slim::Control::Request->new($client->id, [
                'playlist', 'play',
                sprintf("spoton://connect-%u", $ts)
            ]);
            $playReq->source(__PACKAGE__);

            # 76-07 (WINDOWS #5, D-12): t2 of the skip reconnect timeline --
            # millisecond-stamped bracket around the playlist-play dispatch so
            # server.log correlates against the daemon log's [fakepulse <ts>]
            # flush-disconnect (t1) and client-attach (t3) lines.
            my $skipDispatchT = Time::HiRes::time();
            $log->warn(sprintf("[DIAG] [%.3f] skip_dispatch: mac=%s playlist play spoton://connect-%u",
                $skipDispatchT, $client->id, $ts)) if $diagMode;

            $playReq->execute();

            $log->warn(sprintf("[DIAG] [%.3f] skip_dispatch_done: mac=%s execute_elapsed=%.3fs",
                Time::HiRes::time(), $client->id, Time::HiRes::time() - $skipDispatchT)) if $diagMode;

            $client->pluginData(connectStartTime => Time::HiRes::time());

            main::INFOLOG && $log->is_info && $log->info(
                "Soloist skip: forcing stream reconnect via playlist play for " . $client->id
            );
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
        # GH #151: SESSION-END path — the daemon marks the stop 'inactive'
        # when this device stopped being the active Connect target (device
        # deselected / transfer-away / disconnect). This is an authoritative
        # daemon-side state change, not a transitional stop, so it is
        # handled BEFORE the newTrack/grace suppressions below. Pause the
        # stream (mirrors the plain-stop behavior), then restore the saved
        # pre-Connect power state. The generic un-marked stop (app pause)
        # never restores power.
        if (($request->getParam('_p2') || '') eq 'inactive') {
            if ($client->isPlaying && __PACKAGE__->isSpotifyConnect($client)) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Connect session ended (device inactive) — pausing " . $client->id
                );
                $client->pluginData(connectPauseTs => Time::HiRes::time());
                my $pauseReq = Slim::Control::Request->new($client->id, ['pause', 1]);
                $pauseReq->source(__PACKAGE__);
                $pauseReq->execute();
            }

            # GH #158: session over — drop the remembered pause state
            $client->pluginData(connectSessionPaused => 0);

            _restorePowerAfterConnect($client);

            $log->warn("[DIAG] [$diagTs] stop: player=" . $client->id
                . " sessionEnd=1"
                . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
            ) if $diagMode;

            return;
        }
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

        # GH #158: a genuine (post-grace) stop means the Spotify session is
        # paused — remember it so the 'change' handler does not force-unpause
        # a skip-while-paused sequence. Cleared on start/resume/unpause.
        if (__PACKAGE__->isSpotifyConnect($client)) {
            $client->pluginData(connectSessionPaused => 1);
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

            # D-04 backend dispatch: Soloist Connect uses spoton://track:ID
            # entries; librespot keeps the repeating-stream URL.
            my $readyPlayUrl;
            {
                require Plugins::SpotOn::Unified::DaemonManager;
                my $readyHelper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
                if ($readyHelper && $readyHelper->isa('Plugins::SpotOn::Unified::SoloistDaemon')) {
                    # Derive trackId from eventTrackUri (last announced track)
                    my $readyTrackUri = $client->pluginData('eventTrackUri') || '';
                    if ($readyTrackUri =~ m{^spotify:(?:track|episode):([A-Za-z0-9]+)$}) {
                        $readyPlayUrl = "spoton://track:$1";
                    }
                }
                unless ($readyPlayUrl) {
                    # librespot path (or Soloist fallback if no trackId available):
                    # repeating-stream with unique timestamp URL
                    my $ts = int(Time::HiRes::time() * 1000);
                    $readyPlayUrl = sprintf("spoton://connect-%u", $ts);
                }
            }
            my $playReq = Slim::Control::Request->new($client->id, [
                'playlist', 'play', $readyPlayUrl
            ]);
            $playReq->source(__PACKAGE__);
            $playReq->execute();
        }
        return;
    }

    main::INFOLOG && $log->is_info && $log->info("Unhandled spottyconnect command: $cmd");
}

# _restorePowerAfterConnect($client)
# GH #151: restore the pre-Connect power state at Connect session end
# (ShairTunes prior art). Only powers OFF (never on): a player that was
# already on before the session simply stays on. Guards:
#   - no-op unless a power state was saved for this session
#   - the saved flag is ALWAYS cleared, even on the skip paths, so a stale
#     value can never leak into a later session (first-save-wins contract)
#   - skip the power-off if the player is meanwhile playing something that
#     is not the Connect stream (user started local playback during/after
#     the session — powering off would kill their music)
# Sync groups: _connectEvent normalizes to the master client (the daemon
# lives on the master), so save/restore applies to the player that received
# the event — each member with its own session is handled individually.
sub _restorePowerAfterConnect {
    my ($client) = @_;

    my $prev = $client->pluginData('connectPrevPower');
    return unless defined $prev;

    # Always clear first — no path below may leave a stale saved state.
    $client->pluginData(connectPrevPower => undef);

    if ($prev) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Session end: player " . $client->id . " was on before Connect — leaving on (GH #151)"
        );
        return;
    }

    my $song = $client->playingSong();
    my $url  = $song ? ($song->track->url || $song->streamUrl || '') : '';
    # Phase 78-04: also accept a Soloist-owned song as "Connect stream"
    # so GH-#151 power restore works at Soloist session end.
    if ($client->isPlaying && $url !~ m{spoton://connect-} && !_isSoloistOwnedSong($client)) {
        main::INFOLOG && $log->is_info && $log->info(
            "Session end: " . $client->id . " is playing something else — skipping power-off (GH #151)"
        );
        return;
    }

    main::INFOLOG && $log->is_info && $log->info(
        "Session end: restoring pre-Connect power state (off) for " . $client->id . " (GH #151)"
    );

    my $powerReq = Slim::Control::Request->new($client->id, ['power', 0]);
    $powerReq->source(__PACKAGE__);
    $powerReq->execute();
}

# _fetchTrackMetadata($client, $trackId)
# Fetches track metadata from Spotify Web API and updates NowPlaying display.
# Uses API::SpClient->getTrack() (D-08) which routes via spclient for
# login5-capable accounts, falling back to Client.pm's own-token path
# transparently (track endpoint is accessible with own or bundled token).
sub _fetchTrackMetadata {
    my ($client, $trackId) = @_;

    return unless $trackId;

    require Plugins::SpotOn::API::SpClient;

    my $accountId = $prefs->client($client)->get('activeAccount')
                 || $prefs->get('activeAccount')
                 || '';
    $log->warn("[DIAG] metadata_fetch: mac=" . $client->id . " track=$trackId account=$accountId") if $prefs->get('diagnosticMode');

    Plugins::SpotOn::API::SpClient->getTrack($accountId, $trackId, sub {
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
            # Push the change handler's progress reset now -- the API response
            # is discarded, but clients still need to see the reset (Phase 58).
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
            _finishNewTrack($client);   # H7
            return;
        }

        # H7: EVERY exit path of this callback must clear newTrack — a leaked
        # flag swallows all subsequent stop events.
        unless ($trackInfo && $trackInfo->{name}) {
            # Push the change handler's progress reset now -- metadata fetch
            # failed (429 backoff / parse error / no data), so this is the
            # only remaining chance to notify clients (Phase 58, preserves #126).
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
            _finishNewTrack($client);
            return;
        }

        my $song = $client->playingSong();
        unless ($song) {
            _finishNewTrack($client);
            return;
        }

        # browse-stale-metadata-elapsed: this callback resolves after an
        # async Spotify API round-trip -- by then playback may already have
        # moved on from Connect entirely (most commonly a Browse `playlist
        # play` racing a session-restore fetch right after an LMS restart).
        # The stale-API-protection check above only catches a wrong TRACK
        # within Connect (event vs API mismatch); it does not catch playback
        # having left Connect mode altogether. Same guard idiom as
        # _restorePowerAfterConnect (GH #151): only a spoton://connect-*
        # song is a valid target for Connect metadata. Without this, a late
        # callback overwrites the CURRENT (Browse) song's title/duration
        # with the stale Connect track's data.
        my $songUrl = ($song->track && $song->track->url) || $song->streamUrl || '';
        unless ($songUrl =~ m{spoton://connect-}) {
            main::INFOLOG && $log->is_info && $log->info(
                "_fetchTrackMetadata: playingSong is no longer a Connect stream ($songUrl)"
                . " -- discarding stale metadata for track=$trackId"
            );
            # Let clients re-query the (correct) current metadata instead.
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
            _finishNewTrack($client);
            return;
        }

        my $title    = $trackInfo->{name};
        my $artist   = join(', ', map { $_->{name} } @{ $trackInfo->{artists} || [] });
        my $album    = ($trackInfo->{album} || {})->{name} || '';
        my $duration = ($trackInfo->{duration_ms} || 0) / 1000;
        my $cover    = _largestImage(($trackInfo->{album} || {})->{images}) || IMG_TRACK;
        my $year     = Plugins::SpotOn::Plugin::_releaseYear(($trackInfo->{album} || {})->{release_date});

        # Instant display update — set on both logical and stream URL so renderers
        # that key their display off the stream URL (e.g. UPnPBridge) also get the title
        my $logicalUrl = ($song->track && $song->track->url)
            ? $song->track->url
            : $song->streamUrl;
        my $streamUrl = $song->streamUrl;
        my $displayTitle = "$artist - $title";

        Slim::Music::Info::setCurrentTitle(
            $logicalUrl,
            $displayTitle,
            $client
        );
        if ($streamUrl && $streamUrl ne $logicalUrl) {
            Slim::Music::Info::setCurrentTitle(
                $streamUrl,
                $displayTitle,
            );
        }

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
            icon         => $cover,
            year         => $year,
            url          => $logicalUrl,
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
                    year       => $year,
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
        $client->currentPlaylistUpdateTime(Time::HiRes::time())
            if $client->can('currentPlaylistUpdateTime');

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
