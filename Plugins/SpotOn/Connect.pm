package Plugins::SpotOn::Connect;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use File::Path qw(mkpath);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed weaken refaddr);
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

# 84-02 (cluster 4, D-21): how far a player-reported stream elapsed may exceed
# the wall time since the current Soloist per-track stream was dispatched
# before it is judged to belong to the PREVIOUS stream (squeezelite reports the
# old stream's elapsed until the new one plays; timer granularity and the
# dispatch-to-first-byte latency stay well inside one second).
use constant STREAM_ELAPSED_SLACK => 1.0;

# 84-26 F-24-2: the floor below which a resume position never becomes LMS's resume position. Mirrors
# Soloist::Control ENTRY_MIN_TARGET_MS (Control.pm:73, 1000 ms): `_anchorPosSec` passes sub-second reset
# figures (the daemon's new-item reset reads 0.000..0.9) and the reactivation resume is always emitted, so
# a jumpToTime(0.112) would restart the title -- the 82-24/84-14 defect class.
use constant RESUME_JUMP_MIN_MS => 1000;

# 84.3-01 (D-04): the ONE context-end discriminator -- the LMS clock at the stop instant is
# within this many seconds of the title duration. 2.0 s is >60x the observed 0.000-0.03 s
# deviation of the clock from the duration at a real context end (RESEARCH A1).
use constant CTX_END_MARGIN_S => 2.0;

# 84.3-01 (D-02): seconds the grace timer waits before it re-validates a playing-but-not-stuck
# context end from the stored snapshot (D-02 says ~1-2 s; RESEARCH A2).
use constant SETTLE_GRACE_S => 1.5;

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

# 83.1-02 Task 2 (D-D2): timestamp of the last bindConnectClaim write -- a
# log DETAIL only (the near-simultaneous-bind case gets "within <ms> ms"
# appended to the warn line), never a time-window DECISION -- last message
# always wins regardless of how close together the two binds arrived.
my $_lastBindAt;

# 84.1-08 (WR-02, D-02): the LMS Song object playing when the Connect
# claim was bound, held weakly (Pitfall 4 -- identity, never a time
# window; a freed entry song can never match). Keyed on client id.
my %_connectEntrySong;

# 84-17 (L1 repair): the open hold per client id, see the block above
# _onPause for the shape and the lifecycle.
my %_hold;

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
    # 84.1 D-01(b): a bare `stop` on an already-stopped player is `_NoOp`
    # in StreamingController (no `playlist stop` notified), but
    # Request::execute notifies every completed command regardless -- this
    # is the notification-independent-of-state trigger D-01(b) needs
    # (live-confirmed, 84.1-01: A_NOOP_SEEN=yes, A_NOTIFY_STOP_SEEN=no for
    # the ['playlist']-scoped subscription above). `playlist clear` is a
    # notified command too (Commands.pm playlistClearCommand ->
    # Slim::Player::Playlist::stopAndClear).
    # 84.1-08 CR-01: LMS keys its %listeners by the coderef itself
    # (Request.pm:797), so each subscription needs its OWN coderef -- a
    # second subscribe of the same coderef silently REPLACES the first
    # (84.1-REVIEW.md CR-01, introduced in 833f85bd: both lines used to
    # pass \&_onLmsStop, so only the ['playlist'],['clear'] entry
    # survived and the bare ['stop'] trigger was never registered).
    Slim::Control::Request::subscribe(\&_onLmsStop, [['stop']]);
    Slim::Control::Request::subscribe(\&_onLmsClear, [['playlist'], ['clear']]);
    # 84.2-02 (CAUSE-2, D-08): an LMS playlist change in browse re-evaluates
    # the prefetch (the B6 runner adds the successor AFTER the title started).
    # Own coderef per the CR-01 rule above.
    Slim::Control::Request::subscribe(\&_onLmsPlaylistChanged, [['playlist'], ['add', 'insert', 'addtracks', 'inserttracks', 'move', 'delete', 'repeat', 'shuffle']]);

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

# bindConnectClaim($class, $client, $source) -- D-D1 (83.1-02 Task 1): the
# ONE write path for the Soloist Connect claim ($_activeConnectPlayer).
# Called from Control's transfer-class handler (_onFrameDeviceChanged,
# is_active:true, source 'transfer') and from the resume re-entry path
# below (source 'resume'). The generic `spottyconnect start` dispatch no
# longer writes here for a Soloist helper (see the cmd eq 'start' branch) --
# D-D2's conflict-vs-clean distinction lives in this sub so both callers
# share it.
sub bindConnectClaim {
    my ($class, $client, $source) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');

    my $now = Time::HiRes::time();

    if ($_activeConnectPlayer && $_activeConnectPlayer ne $client->id) {
        # D-D2: last message wins -- protokolliert statt still ueberschrieben.
        # Distinguish a CLEAN handover (the old player's own Control is no
        # longer mid-session) from an UNCLEAN one (the old Control still
        # thinks it is live) -- Messung B's validity boundary covers only
        # "ein sauberer Einzeltransfer"; this branch is what happens outside
        # that boundary (two fast switches, a dropped connection with a
        # fresh sign-in, or two simultaneous reports).
        my $oldId    = $_activeConnectPlayer;
        my $unclean  = 0;

        # 84-08 (SEAM-6.2): the OLD player's backend role answers "still
        # live?" (state mode connect + active); a backend without a player
        # engine (librespot: mode undef) always takes the clean path.
        eval {
            require Plugins::SpotOn::Unified::DaemonManager;
            my $oldClient = Slim::Player::Client::getClient($oldId);
            my $oldBe     = $oldClient ? Plugins::SpotOn::Unified::DaemonManager->backendFor($oldClient) : undef;
            my $oldSt     = $oldBe ? $oldBe->state : {};
            if (($oldSt->{mode} // '') eq 'connect' && $oldSt->{active}) {
                $unclean = 1;

                my $detail = (defined $_lastBindAt && ($now - $_lastBindAt) < 1)
                    ? sprintf(' (within %dms)', int(($now - $_lastBindAt) * 1000))
                    : '';

                $log->warn(
                    "Connect claim: last message wins -- " . $client->id . " replaces " . $oldId
                    . " while " . $oldId . " still reports an active session (D-D2)" . $detail
                );
                $oldBe->notify('recordErrorOnce', key => 'claim-conflict:' . $oldId, level => 'warn',
                    message => $oldId . ": Connect claim: last message wins -- " . $client->id
                    . " replaces it while " . $oldId . " still reports an active session (D-D2)");
                # The loser merely lost the claim -- its OWN daemon will
                # report is_active:false itself; do not emit stop for it
                # (that would be the player engine's job for a real session end).
                $oldBe->notify('claimLost', reason => 'last-message-wins');
            }
            1;
        };

        unless ($unclean) {
            main::INFOLOG && $log->is_info && $log->info(
                "Connect claim: last message wins -- " . $client->id . " replaces " . $oldId
            );
        }
    }

    $_activeConnectPlayer = $client->id;
    $_lastBindAt = $now;

    # 84.1-08 (WR-02, D-02): record the Song that was playing AT THIS
    # CONNECT ENTRY, held weakly. _onNewSong compares an announced song
    # against this one by object identity -- a title-change re-announce of
    # the SAME song (LMS reuses the Song object, Info.pm:520-534) never
    # ends the session, while a fresh Song (a real content switch, even to
    # the same url -- _getNextTrack always creates a new object) does.
    if ($client->can('playingSong') && (my $entrySong = $client->playingSong())) {
        $_connectEntrySong{ $client->id } = $entrySong;
        weaken($_connectEntrySong{ $client->id });
    }
    else {
        delete $_connectEntrySong{ $client->id };
    }

    main::INFOLOG && $log->is_info && $log->info(
        "Connect claim: bound " . $client->id . " source=" . ($source // '?')
    );
}

# _isConnectEntrySong($client, $song) -- WR-02 (D-02): true only when
# $song is the SAME object (refaddr) as the one recorded at this client's
# most recent bindConnectClaim. Never a url comparison (a re-started
# station is new content, N6b) and never a clock read (Pitfall 4). An
# undef stored entry (freed weak ref, or none recorded) never matches.
sub _isConnectEntrySong {
    my ($client, $song) = @_;
    return 0 unless $client && $song;
    my $entry = $_connectEntrySong{ $client->id };
    return 0 unless defined $entry;
    return (refaddr($entry) == refaddr($song)) ? 1 : 0;
}

# releaseConnectClaim($class, $client, $source) -- public counterpart to
# bindConnectClaim (D-D1). 83.1-07: the legacy underscore-prefixed one-line
# alias that used to wrap this call (0 callers -- git grep proves) is removed.
sub releaseConnectClaim {
    my ($class, $client, $source) = @_;
    return unless $client;
    $client = $client->master if $client->can('master');
    _settleCancel($client, 'claim_release');    # 84.3-01: no grace settle after the claim is gone
    # 84.2-05: hygiene clear of the one-shot dispatch marker -- unconditional (a
    # release without a bound claim, e.g. ProtocolHandler's browse-entry release
    # on every Browse getNextTrack, clears it too). False scalar, never undef
    # (pluginData treats undef as a read).
    $client->pluginData(connectOwnPlayUri => '');
    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        $_activeConnectPlayer = undef;
        $client->pluginData(pendingConnect => 0);
        main::INFOLOG && $log->is_info && $log->info(
            "Connect claim: released " . $client->id . " source=" . ($source // '?')
        );
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
        Slim::Control::Request::unsubscribe(\&_onLmsStop);
        Slim::Control::Request::unsubscribe(\&_onLmsClear);
        Slim::Control::Request::unsubscribe(\&_onLmsPlaylistChanged);

        $_activeConnectPlayer = undef;
        %_connectEntrySong = ();
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
        "newTrack fallback timer fired - clearing flag for " . $client->id . " (H7)");
    $client->pluginData(newTrack => 0);
}

# _finishNewTrack: normal-path clear — kills the fallback timer and clears the flag.
sub _finishNewTrack {
    my ($client) = @_;
    Slim::Utils::Timers::killTimers($client, \&_clearNewTrack);
    $client->pluginData(newTrack => 0);
}

# ---------------------------------------------------------------------------
# 84.3-01: Connect context-end settle (D-01..D-07).
#
# At a Connect context end Spotify sends a pause ('stop' event) and the stop
# branch forwards ['pause',1] to LMS. When LMS is rebuffering at that moment
# (StreamingController Pause row BUFFERING -> _NoOp, SC:133-139) the pause is
# discarded and LMS stays BUFFERING for good: the C5 race. These subs detect
# exactly that state right after the pause and settle it with one source-marked
# ['stop']. Every LMS accessor is read through can() (D-05 "when in doubt,
# wait"): a double or an older LMS without it means no settle, never a die --
# a die here would abort the stop branch after the pause.
# ---------------------------------------------------------------------------

# _lmsController($client) -- the StreamingController, or undef (no accessor).
sub _lmsController {
    my ($client) = @_;
    return undef unless $client->can('controller');
    my $ctl = $client->controller;
    return (blessed($ctl) ? $ctl : undef);
}

# _settleSongUrl($client) -- the playing song's track url, '' when unreadable.
sub _settleSongUrl {
    my ($client) = @_;
    my $song = $client->can('playingSong') ? $client->playingSong : undef;
    return '' unless blessed($song) && $song->can('track');
    my $track = $song->track;
    return '' unless blessed($track) && $track->can('url');
    my $url = $track->url;
    return (defined $url ? $url : '');
}

# _ctxEndSnapshot($client) -- the LMS clock, duration, url and buffer fullness
# at the stop instant, taken BEFORE the pause is sent (KF-3: the seek echo
# zeroes the clock 3 ms after the stop, so it is never read later). undef when
# the duration is unknown (episode, no controller): D-05, never settle.
sub _ctxEndSnapshot {
    my ($client) = @_;
    my $ctl = _lmsController($client);
    return undef unless $ctl && $ctl->can('playingSongDuration') && $ctl->can('playingSongElapsed');
    my $duration = $ctl->playingSongDuration;
    return undef unless defined $duration && $duration > 0;

    return {
        songTime => ($ctl->playingSongElapsed // 0),
        duration => $duration,
        uri      => _settleSongUrl($client),
        fullness => ($client->can('bufferFullness') ? $client->bufferFullness : undef),
    };
}

# _isCtxEnd($snap) -- D-04, the ONE context-end discriminator: the LMS clock at
# the stop instant is within CTX_END_MARGIN_S of the title duration.
sub _isCtxEnd {
    my ($snap) = @_;
    return ($snap && $snap->{songTime} >= $snap->{duration} - CTX_END_MARGIN_S) ? 1 : 0;
}

# _stuckRebuffer($client) -- LMS reports "playing" (non-strict) but the strict
# isPlaying(1) is false and the controller says rebuffering (buffering() == 2,
# SC:1697-1702): the state the discarded pause leaves behind.
sub _stuckRebuffer {
    my ($client) = @_;
    return 0 unless $client->isPlaying && !$client->isPlaying(1);
    my $ctl = _lmsController($client);
    return 0 unless $ctl && $ctl->can('buffering');
    return (($ctl->buffering // 0) == 2) ? 1 : 0;
}

# _neverStarted($client) -- 79-51 runaway D3 (E6): LMS reports "playing" (non-strict), the strict isPlaying(1) is
# false and the controller says INITIAL buffering (buffering() == 1, SC:1697-1702): the playing song has not started
# output yet. The same accessor pair _stuckRebuffer reads, the other value (1 instead of 2).
sub _neverStarted {
    my ($client) = @_;
    return 0 unless $client->isPlaying && !$client->isPlaying(1);
    my $ctl = _lmsController($client);
    return 0 unless $ctl && $ctl->can('buffering');
    return (($ctl->buffering // 0) == 1) ? 1 : 0;
}

# _settleCheck($client, $snap) -- called right after the stop branch's
# ['pause',1]. One info line per evaluation records the outcome and the
# discriminator (PASS-by-pause runs are recorded too).
sub _settleCheck {
    my ($client, $snap) = @_;

    my $paused  = ($client->can('isPaused')  && $client->isPaused)  ? 1 : 0;
    my $stopped = ($client->can('isStopped') && $client->isStopped) ? 1 : 0;
    my $synced  = ($client->can('isSynced')  && $client->isSynced)  ? 1 : 0;
    my $stuck   = _stuckRebuffer($client);
    my $ctl     = _lmsController($client);
    my $state   = $paused ? 'paused' : $stopped ? 'stopped' : $stuck ? 'rebuffering'
                : ($ctl && $ctl->can('buffering') && ($ctl->buffering // 0) == 1) ? 'buffering'
                : $client->isPlaying ? 'playing' : '-';

    my $log_outcome = sub {
        my ($outcome) = @_;
        main::INFOLOG && $log->is_info && $log->info(sprintf(
            'Connect: context-end check -- %s %s songTime=%s duration=%s state=%s stuck=%d',
            $outcome, $client->id,
            ($snap ? sprintf('%.3f', $snap->{songTime}) : '-'),
            ($snap ? sprintf('%.3f', $snap->{duration}) : '-'),
            $state, $stuck,
        ));
    };

    unless ($snap)              { $log_outcome->('no settle (duration_unknown)'); return; }
    if ($synced)                { $log_outcome->('no settle (synced)');           return; }   # D-05: unmeasured, deferred
    if ($paused)                { $log_outcome->('no settle (pause_honoured)');   return; }
    if ($stopped)               { $log_outcome->('no settle (stopped)');          return; }
    unless (_isCtxEnd($snap))   { $log_outcome->('no settle (not_context_end)');  return; }

    if ($stuck) {
        $log_outcome->('settling');
        _settleNow($client, $snap, 'immediate');
        return;
    }

    # D-02: a context end, LMS still playing-but-not-stuck -- the discarded pause may only
    # show up a moment later. ONE grace timer re-validates from this snapshot (never the LMS
    # clock, KF-3: the seek echo zeroes it); one timer per client at most.
    $client->pluginData(connectCtxEnd => { %$snap });   # 84.3-rev IN-03: ONE fullness field, the snapshot's
    Slim::Utils::Timers::killTimers($client, \&_settleFire);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SETTLE_GRACE_S, \&_settleFire);
    $log_outcome->('grace armed');
    return;
}

# _settleFire($client) -- the grace timer callback. Re-validates the LMS state from the
# stored snapshot and settles at most once; any veto settles nothing.
sub _settleFire {
    my ($client) = @_;

    my $ctx = $client->pluginData('connectCtxEnd');
    $client->pluginData(connectCtxEnd => 0);      # false scalar, never undef (a read)
    return unless ref($ctx) eq 'HASH';            # cancelled meanwhile

    my $skip = sub {
        my ($reason) = @_;
        main::INFOLOG && $log->is_info && $log->info(
            "Connect: context-end check -- grace skipped ($reason) " . $client->id
        );
    };

    return $skip->('url_changed')      if _settleSongUrl($client) ne $ctx->{uri};
    return $skip->('claim_released')   unless __PACKAGE__->isSpotifyConnect($client);
    return $skip->('session_resumed')  unless ($client->pluginData('connectSessionPaused') // 0) == 1;
    return $skip->('not_stuck')        unless _stuckRebuffer($client);
    return $skip->('synced')           if $client->can('isSynced') && $client->isSynced;
    my $fullness = $client->can('bufferFullness') ? $client->bufferFullness : undef;
    return $skip->('fullness_unknown') unless defined $fullness && defined $ctx->{fullness};
    if ($fullness > $ctx->{fullness}) {
        # 84.3-rev WR-01: the stop-instant fullness is a start-buffering reading and not comparable
        # with the post-underrun residue, so the FIRST growth is a deferral, not a verdict: re-arm
        # ONCE with the current fullness as the new baseline (still one timer per client, D-02).
        # A second growth is a real "LMS is recovering" and stays terminal.
        return $skip->('data_arriving') if $ctx->{rearmed};
        $client->pluginData(connectCtxEnd => { %$ctx, fullness => $fullness, rearmed => 1 });
        Slim::Utils::Timers::killTimers($client, \&_settleFire);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SETTLE_GRACE_S, \&_settleFire);
        # 84.3-rev IN-05: old -> new, because the re-armed settle's warn line only shows the new
        # baseline and the stop-instant reading would otherwise be lost
        main::INFOLOG && $log->is_info && $log->info(
            "Connect: context-end check -- grace re-armed (data_arriving) fullness="
            . $ctx->{fullness} . '->' . $fullness . ' ' . $client->id
        );
        return;
    }

    _settleNow($client, $ctx, 'grace');
    return;
}

# _settleCancel($client, $why) -- drop an armed grace timer and its snapshot. Safe on every
# client double: a killTimers plus a pluginData read only.
sub _settleCancel {
    my ($client, $why) = @_;
    return unless $client;
    Slim::Utils::Timers::killTimers($client, \&_settleFire);
    if ($client->pluginData('connectCtxEnd')) {
        $client->pluginData(connectCtxEnd => 0);
        main::INFOLOG && $log->is_info && $log->info(
            "Connect: context-end check -- grace cancelled ($why) " . $client->id
        );
    }
    return;
}

# _settleNow($client, $snap, $via) -- the settle itself: a plain, source-marked
# ['stop'] (D-03/D-06). No playlist clear, no power request, no session-end
# power restore; connectSessionPaused and the Connect claim stay untouched.
# Loop prevention is _onLmsStop's existing early return for our own source.
sub _settleNow {
    my ($client, $snap, $via) = @_;

    # 84.3-rev IN-02: an earlier-armed grace timer of this client must not fire after the settle
    _settleCancel($client, 'settled');

    $log->warn(sprintf(
        'Connect: context-end settle -- LMS discarded the pause while rebuffering, stopping %s via=%s songTime=%.3f duration=%.3f fullness=%s',
        $client->id, $via, $snap->{songTime}, $snap->{duration},
        (defined $snap->{fullness} ? $snap->{fullness} : '-'),
    ));

    my $stopReq = Slim::Control::Request->new($client->id, ['stop']);
    $stopReq->source(__PACKAGE__);
    $stopReq->execute();
    return;
}

# _currentSpotonTrackUrl($client)
# Returns the current song URL if it matches ^spoton://(?:track|episode):,
# or '' otherwise.  Uses track->url first (authoritative spoton:// URI),
# then streamUrl fallback — during a track transition only streamingSong
# carries the new URL, so check streamingSong before playingSong (Phase 44
# pattern).  Shared by the echo/confirmation guard in _connectEvent and
# plan 78-04's ownership criterion (82-05: _soloistBrowseWs itself is
# retired -- the bounded-model criterion it implemented now lives in
# Plugins::SpotOn::Soloist::Control's `mode`).
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

# _streamElapsedSeconds($client) -- 84-02 (cluster 4, D-21). The player's
# elapsed seconds OF THE CURRENT STREAM, for the CON-13 startOffset arithmetic
# (LMS clock = song->startOffset + songElapsedSeconds, StreamingController::
# playingSongElapsed; songElapsedSeconds counts from the current stream start).
#
# On a per-track Soloist entry (`start`/`change` dispatch a new
# `playlist play spoton://track:<id>`; connectStreamDispatchTs marks that
# moment) the daemon's seek/resume echo arrives a few ms after the dispatch,
# when LMS already holds the NEW song but squeezelite still reports the OLD
# stream's elapsed (frozen window 2026-09-24 23:45:18.7586-.7672: 87.5 s, so
# `position 0 - elapsed` = startOffset -87.498 and the clock sat at 0.0 for
# ~88 s). A stream dispatched $since seconds ago cannot have played longer than
# that, so a larger elapsed belongs to the previous stream and the new one has
# played 0 s. Without the marker (librespot: one repeating stream that never
# restarts) the raw elapsed is returned unchanged.
sub _streamElapsedSeconds {
    my ($client) = @_;

    my $elapsed = $client->songElapsedSeconds() || 0;
    my $dispatchTs = $client->pluginData('connectStreamDispatchTs');
    return $elapsed unless $dispatchTs;

    my $since = Time::HiRes::time() - $dispatchTs;
    return $elapsed if $elapsed <= $since + STREAM_ELAPSED_SLACK;

    main::INFOLOG && $log->is_info && $log->info(sprintf(
        "Stream elapsed %.3f exceeds the %.3fs since the last dispatch -- belongs to the previous stream, using 0 (84-02)",
        $elapsed, $since
    ));
    return 0;
}

# _queuedNextSong($client) -- 84-26 F-24-2: true when the controller holds a queued NEXT song, i.e. its
# streamingSong is defined and is not the same object as its playingSong (the PAUSED-TRACKWAIT shape; after
# StreamingController::_pauseStreaming the queue holds the playing song only, SC:473-476). Covers the
# `_getNextTrack` entry into TRACKWAIT (SC:683-684) but not necessarily the `updateOnStream` (SC:1179) and
# retry (SC:1469) entries -- a stated limit, not a claim.
sub _queuedNextSong {
    my ($client) = @_;
    my $ctl = $client->controller or return 0;
    my $ss = $ctl->streamingSong;
    return 0 unless defined $ss;
    my $ps = $ctl->playingSong;
    return (defined $ps && refaddr($ss) == refaddr($ps)) ? 0 : 1;
}

# _pausedStreamGone($client) -- 84-26 F-24-2: LMS is PAUSED and the stream is gone (the PAUSED-IDLE state).
# StreamingController state table: the Pause/Resume rows send `Pause`/`Resume` to `_JumpOrResume` in the IDLE
# column only (SC:138 / SC:145 -- Resume x PAUSED-IDLE), and `_JumpOrResume` (SC:1605-1618) turns a plain
# `['pause', 0]` there into a `_JumpToTime(resumeTime)`: LMS re-opens the title at its OWN stale resume time
# (84-24 C6: 31.2 s while the app was at 53.4 s), and the seek chain then forwards that LMS-originated figure to
# the daemon as if it were a user seek. `Client::isPaused` delegates to the controller (Client.pm:1352);
# `isStreaming` / `isStreamout` (SC:1685-1691) are the two public streaming-state accessors, so the predicate
# names the IDLE column. PAUSED-TRACKWAIT also satisfies both accessors but is EXCLUDED by the queued-next-song
# test: there `Pause` dispatches to `_Resume` (SC:138 column 4), and a jump would run `_pauseStreaming` -- stop
# every client, close the stream and shift the queued next song out of the queue (SC:461-476). The live
# unpause (PAUSED-STREAMING / STREAMOUT, `Resume` -> `_Resume`, SC:145 columns 1-2) is untouched.
sub _pausedStreamGone {
    my ($client) = @_;
    return 0 unless $client->isPaused;
    my $ctl = $client->controller or return 0;
    return 0 if $ctl->isStreaming || $ctl->isStreamout;
    return 0 if _queuedNextSong($client);
    return 1;
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

    # 84-17: an open hold ends with the newsong of ITS deferred item (the
    # audible switch: LMS advanced by itself) -- the previous item is pruned
    # by its recorded index, nothing from the hold is applied to the new song
    # (it starts at 0: every position seen during a hold is the daemon's
    # write-side position, 20-35 s ahead of the audible one). A newsong for
    # any other url cancels the hold (H-c).
    if (my $hold = $_hold{ $client->id }) {
        if ($url eq $hold->{uri}) {
            _holdClose($client, 'newsong');
            if (_holdItemUrlAt($client, $hold->{playingIdx}) eq $hold->{oldUrl}) {
                _holdRequest($client, 'playlist', 'delete', $hold->{playingIdx});
            }
            $client->pluginData(progress => 0);
            $client->pluginData(connectSessionPaused => 0);
            $client->pluginData(connectStreamDispatchTs => Time::HiRes::time());
        }
        else {
            _holdCancel($client, 'foreign-newsong');
        }
    }

    # CR-04 (82-REVIEW.md, T-4): the missing `browse` -> `idle` path.
    # A Soloist Control in `browse` mode never saw a `device_changed` (that
    # is the ONLY other way `mode` changes, and only ever towards
    # `connect`) -- so without this, `mode` stays `browse` forever once
    # entered, and requestPause/requestResume/requestVolume's CR-04 guard
    # would need to distinguish "genuinely idle" from "left browse a while
    # ago" using nothing but the LMS song check on every single call.
    # Firing this off the SAME LMS event that already tells us the current
    # song changed avoids a second decision path (Prinzip 3.1(4)): if the
    # new title isn't ours, we are definitely not in a browse session
    # anymore. leaveBrowse only resets state -- no command goes out.
    # 84-08 (SEAM-6.2): through the backend role. $mode re-reads the role's
    # state on every call (the former $ctl->mode did the same after
    # leaveBrowse/leaveConnect changed it); librespot: always undef.
    require Plugins::SpotOn::Unified::DaemonManager;
    my $be   = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    my $mode = sub { $be ? $be->state->{mode} : undef };
    if (($mode->() // '') eq 'browse' && $url !~ m{^spoton://(?:track|episode):}) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "CR-04: new LMS song is not ours -- leaveBrowse (" . $client->id . ")"
        );
        $be->notify('leaveBrowse');
    }

    # 84.1-07 (D-02): foreign LMS content while in a Connect session ends
    # the session cleanly. Placed BEFORE CON-17, which returns early while
    # mode is connect -- exactly why the D-16 release below never fired
    # for this case pre-fix. The guard is a url class only (Pitfall 4):
    # non-empty and not spoton:// (requestTrack owns spoton transitions;
    # this is deliberately broader than a track/episode-only match so a
    # spoton:// playlist or album entry never ends a session).
    if (($mode->() // '') eq 'connect' && $url =~ /\S/ && $url !~ m{^spoton://}) {
        # WR-02 (84.1-08, D-02): a title-change re-announce of the SAME
        # song that was already playing when the Connect claim was bound
        # (LMS reuses the Song object for an in-stream title change,
        # Info.pm:520-534 -- Bug 17174) is not a user starting foreign
        # content; it is our own radio stream continuing. The
        # discriminator is Song object identity (weak, recorded at
        # bindConnectClaim), never a url compare (a re-started station is
        # new content even at the same url, N6b) and never a clock read
        # (Pitfall 4). A real track start always creates a fresh Song in
        # _getNextTrack, so a genuine foreign switch still leaves. `_p2`
        # cannot serve as the discriminator instead: StreamingController
        # .pm:382-390 notifies ['playlist','newsong',$title,$index] for
        # every real track start too, so every real switch would also
        # carry a `_p2` and that filter would disable D-02 entirely.
        if (_isConnectEntrySong($client, $song)) {
            main::INFOLOG && $log->is_info && $log->info(
                "D-02: newsong re-announces the song playing at connect entry -- staying, no leaveConnect (" . $client->id . ")"
            );
        }
        else {
        $be->notify('leaveConnect', reason => 'foreign-lms-content');

        # GH #151: session over because the user started other playback --
        # discard the saved power state WITHOUT powering off (the player
        # is obviously in use). Copied from the D-16 block below:
        # leaveConnect releases the claim first, so that block no longer
        # fires for this case.
        if (defined $client->pluginData('connectPrevPower')) {
            main::INFOLOG && $log->is_info && $log->info(
                "Discarding saved pre-Connect power state for " . $client->id
                . " - user started other playback (GH #151)"
            );
            $client->pluginData(connectPrevPower => undef);
        }
        }
    }
    elsif (($mode->() // '') eq 'connect' && $url !~ /\S/) {
        main::INFOLOG && $log->is_info && $log->info(
            "D-02: newsong without a url in connect -- staying, no leaveConnect (" . $client->id . ")"
        );
    }

    # CON-17: Apply stored progress for Connect sessions.
    # D-16 fix: the old predicate was `isSpotifyConnect($client)` alone, which
    # tested the same condition as the release block below ($_ activeConnectPlayer
    # eq $client->id) — making the release block dead code. Now requires BOTH the
    # ownership claim AND an actual connect-* URL (librespot) or a Soloist
    # session Control itself reports as 'connect' (83.1-07: replaces the
    # former Soloist track-ID URL-matching heuristic -- Control's mode is
    # the single answer source since the claim is bound by the transfer
    # class, plan 02). Progress application only makes sense on a real
    # Connect stream, not on a dormant claim-set-but-Browse-playing state.
    if (__PACKAGE__->isSpotifyConnect($client)
        && ($url =~ m{spoton://connect-} || ($mode->() // '') eq 'connect'))
    {
        if (my $progress = $client->pluginData('progress')) {
            $client->pluginData(progress => 0);

            if (_isStreamMode($client)) {
                # Stream-mode: binary streams from current position. Adjust
                # startOffset so songTime reports the correct position without
                # triggering _JumpToTime → _Stop + _Stream.
                if ($song) {
                    my $elapsed = _streamElapsedSeconds($client);
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
    # that means no connect- URL; for Soloist that means Control's own mode
    # is no longer 'connect' (83.1-07: replaces the former Soloist track-ID
    # URL-matching heuristic).  Under D-04 every Soloist Connect track fires
    # a newsong with a track: URL — this re-key prevents the claim from
    # being released on each track transition (Pitfall 2).
    # Accepted edge (inline per plan): a user manually Browse-playing the
    # exact track the daemon announces will not release the claim until
    # the next differing track.
    if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
        unless ($url =~ m{spoton://connect-} || ($mode->() // '') eq 'connect') {
            main::INFOLOG && $log->is_info && $log->info(
                "D-16: new song without Connect URL - releasing stale Connect claim for " . $client->id
            );
            # 83.1-07 (D-C3 group E): D-D2's "unclean cases visible" intent
            # applies to every retained release path, not just the
            # last-message-wins conflict in bindConnectClaim -- log it here
            # too so a Soloist claim release (now largely redundant since
            # the claim is bound by the transfer class, plan 02) stays
            # traceable if it ever fires.
            $log->warn("Connect claim released by _onNewSong (D-D2)");
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
                    . " - user started other playback (GH #151)"
                );
                $client->pluginData(connectPrevPower => undef);
            }
        }
    }
}

# _onLmsStop($request) -- 84.1 D-01(b): a bare `stop` on an
# already-stopped player is `_NoOp` in StreamingController (no `playlist
# stop` notified), but Request::execute notifies every completed command
# whether or not it caused a state transition -- this is the
# notification-independent-of-state trigger D-01(b) needs. A double
# delivery (`stop` + `playlist stop` on a real transition) is harmless:
# the second call meets mode idle in requestPause and returns 0. Connect
# mode is deliberately excluded -- per the D-01 clarification (CONTEXT.md,
# locked, user 2026-09-27) an LMS stop in connect stays a session pause so
# the app's resume keeps working (t/44 A5 pins it). The leftConnectForeign
# marker clear now shares requestPause's playmode classification (WR-08,
# quick 260928-q2k) -- see the comment at the endForeignLeave call below.
sub _onLmsStop {
    my ($request, $cmd) = @_;
    $cmd //= 'stop';

    # Source-marking loop prevention (mirrors _onPause).
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client() or return;
    $client = $client->master;

    # 84-17 (H-c): an LMS-side stop/clear is a user action -- an open hold is
    # cancelled (the deferred entry removed, no late `playlist play`).
    _holdCancel($client, 'lms_stop');

    # 84-07 (SEAM-6.2): through the backend role. Only a backend with a
    # mode (Soloist with a Control instance) acts; librespot has none.
    require Plugins::SpotOn::Unified::DaemonManager;
    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    my $st = $be->state;
    return unless defined $st->{mode};

    main::INFOLOG && $log->is_info && $log->info(
        "D-01(b): LMS $cmd notification -- mode=" . $st->{mode} . " (" . $client->id . ")"
    );

    # WR-08 (quick 260928-q2k), Befund 3 -- same rule as requestPause
    # (Control.pm:632-640). LMS's own internal `['playlist','stop']`
    # (StreamingController::_notifyStopped, :405-413) also reaches this
    # handler through the unanchored `\bstop\b` match (Request.pm:2021),
    # and on a station change it is delivered with playmode already
    # 'play' -- the foreign content did NOT end, so the D-02 hold
    # `_holdAfterForeignLeave` (Control.pm:4868-4886) must keep its
    # marker. A stop delivered with any other playmode is a genuine end
    # of the foreign content and clears it as before.
    if ((Slim::Player::Source::playmode($client) // '') ne 'play') {
        $be->notify('endForeignLeave', reason => 'lms-stop');
    }
    return unless $st->{mode} eq 'browse';

    $be->control('pause', isStop => 1, source => 'lms_stop');
}

# _onLmsClear($request) -- 84.1-08 CR-01: a distinct coderef for the
# ['playlist'],['clear'] subscription (LMS keys %listeners by coderef,
# Request.pm:797, so this cannot share \&_onLmsStop's coderef without one
# subscription silently replacing the other).
sub _onLmsClear {
    return _onLmsStop($_[0], 'playlist clear');
}

# _onLmsPlaylistChanged($request) -- 84.2-02 (CAUSE-2, D-08): the only
# prefetch trigger used to be the echo of SpotOn's own play, which fires
# before the B6 runner has added the successor (play-then-add), so the
# first Browse title never got its successor queued. Any LMS playlist
# change (add/insert/addtracks/inserttracks/move/delete, and the repeat and
# shuffle switches that change the next index) sets Control's prefetch
# wish; Control consumes it only at a settle point (no pending command), so
# an open seek/set_volume slot is never superseded (WR-02). Browse only --
# in connect the daemon owns the queue (Pitfall 4). A distinct coderef per
# the 84.1-08 CR-01 rule (LMS keys %listeners by coderef, Request.pm:797).
sub _onLmsPlaylistChanged {
    my $request = shift;

    # Source-marking loop prevention (mirrors _onPause/_onLmsStop).
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client() or return;
    $client = $client->master;

    # 84-08 (SEAM-6.2, revision 8): through the backend role -- the wish is
    # noted only in browse (librespot: mode undef -> nothing, no daemon
    # queue to tell). A 'down' outcome is logged once at info, nothing else.
    require Plugins::SpotOn::Unified::DaemonManager;
    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client) or return;
    return unless ($be->state->{mode} // '') eq 'browse';
    my $outcome = $be->notify('notePlaylistChanged');
    main::INFOLOG && $log->is_info && $log->info(
        "_onLmsPlaylistChanged: notify(notePlaylistChanged) -> $outcome for " . $client->id
    ) if $outcome eq 'down';
    return;
}

# ---------------------------------------------------------------------------
# 84-17 (L1 repair) -- the hold on a natural title end.
#
# The audio shim (fake-libpulse) classifies every title change at the moment
# of POST /boundary: `via=live` = the old title was still being streamed to
# LMS = a natural end (the daemon decoded the whole tail ahead of the audible
# position: 12-37 s still sit in the player's buffers and the loopback socket
# buffers, none of it in the shim ring); `departed` = the old client was
# already closed by a skip's flush. Control reads that classification and
# hands it to this handler as the `change`'s 4th positional (`_p4`).
#
# On `live` the immediate `playlist play` is exactly what destroys the tail
# (LMS `_Stop`s and the player flushes its buffers), so it is NOT issued.
# Shape B (84-L1-ATTRIBUTION.md `## 84-17 hold design`): the new title is
# inserted as the NEXT playlist entry (`playlist insert`) and LMS advances by
# itself -- the bounded EOF the shim gives the old stream ends it, the player's
# STMd makes LMS open the deferred item (Control->requestTrack: the daemon is
# already on that title, a hit), STMs at the audible end is the newsong that
# closes the hold. Everything else (departed/none/unknown/timeout/undef, a
# repeat-one or duration-less playlist, a paused LMS) keeps today's immediate
# `playlist play` -- the safe direction.
#
# State per client id (module scope, like %_connectEntrySong):
#   uri, trackId   the deferred item (spoton://track:<id>)
#   oldUrl         the playing url when the hold opened
#   playingIdx     Slim::Player::Source::playingSongIndex at insert time
#   since/capAt/maxAt  Time::HiRes instants (HOLD_CAP_S / HOLD_MAX_S in Control)
#   held_s, lastCheck  accumulated PLAYING time on the old url (the ceiling)
# (declared at the top of the file next to %_connectEntrySong: _onNewSong,
# _onSeek and the other handlers above this block read it)
# ---------------------------------------------------------------------------

# The three constants live ONCE in Control.pm (both sides compute the same
# instants); 84-08: read through the backend role's capabilities
# (holdCapS/holdRecheckS/holdMaxS), not redefined and not named here.
sub _holdCaps    { require Plugins::SpotOn::Unified::DaemonManager; return Plugins::SpotOn::Unified::DaemonManager->backendFor($_[0])->capabilities; }
sub _holdCap     { return _holdCaps($_[0])->{holdCapS}; }
sub _holdRecheck { return _holdCaps($_[0])->{holdRecheckS}; }
sub _holdMax     { return _holdCaps($_[0])->{holdMaxS}; }

# _holdSkipReason($client) -- H-i: the hold is taken ONLY when LMS's own
# advance will open the deferred item. undef = take it.
#   repeat_one   `Slim::Player::Playlist::repeat == 1`: `nextsong` returns the
#                current index (StreamingController.pm:871) -- LMS would
#                re-open the OLD url.
#   no_duration  the playing song has no duration: `_RetryOrNext` (:925,
#                `!$song->duration() && $song->isLive()`) re-streams the OLD
#                url as a radio retry after 10 s of play.
#   not_playing  a paused/stopped LMS has no buffered tail to protect.
#   not_started  79-51 runaway D3 (E6): LMS is in initial buffering (isPlaying, not isPlaying(1), buffering() == 1,
#                `_neverStarted`; WAITING_TO_SYNC reads the same): it has not started output of the playing song, and
#                a never-fed stream can never leave that state (StreamingController.pm:1676-1701), so there is no
#                tail to protect and LMS's own advance would never open the deferred item (094204: `via=live hold=1`
#                on a Redbone stream that never got a byte). Limits: (1) a stream re-opened by an LMS-side seek near
#                the title end is in the same state with bytes already delivered: that remainder is cut instead of
#                held. (2) STOPPED with TRACKWAIT/STREAMING (non-strict isPlaying true, buffering() 0) still takes
#                the hold. A rebuffer (buffering() == 2) keeps the hold: the old title's tail is still in LMS's
#                pipeline.
sub _holdSkipReason {
    my ($client) = @_;

    my $repeat = eval { Slim::Player::Playlist::repeat($client) } // 0;
    return 'repeat_one' if $repeat == 1;

    my $song = $client->playingSong();
    my $dur  = $song ? ($song->duration() // 0) : 0;
    return 'no_duration' unless $dur > 0;

    return 'not_playing' unless $client->isPlaying;
    return 'not_started' if _neverStarted($client);
    return undef;
}

# _holdItemUrlAt($client, $idx) -- the url at playlist index $idx, or ''.
sub _holdItemUrlAt {
    my ($client, $idx) = @_;
    return '' unless defined $idx;
    my $item = eval { Slim::Player::Playlist::song($client, $idx) };
    return '' unless $item;
    return eval { $item->can('url') ? $item->url : ($item->track ? $item->track->url : '') } // '';
}

# _holdRequest($client, @cmd) -- a source-marked request (our own, ignored by
# the Connect subscribers).
sub _holdRequest {
    my ($client, @cmd) = @_;
    my $req = Slim::Control::Request->new($client->id, [ @cmd ]);
    $req->source(__PACKAGE__);
    $req->execute();
}

# _holdRemoveDeferred($client, $hold) -- removes the still-unplayed deferred
# playlist entry (index playing+1) if it is still THAT item; a playlist that
# was replaced by a `playlist play` no longer holds it and nothing is sent.
sub _holdRemoveDeferred {
    my ($client, $hold) = @_;
    my $idx = $hold->{playingIdx};
    return unless defined $idx;
    my $at = $idx + 1;
    if (_holdItemUrlAt($client, $at) eq $hold->{uri}) {
        _holdRequest($client, 'playlist', 'delete', $at);
    }
}

# _holdClose($client, $by) -- the ONE close path: forgets the hold, kills the
# re-check timer, tells Control (its record stops marking seeks/resumes),
# logs `Connect: hold closed by <by>`. Returns the closed hold (or undef when
# none was open).
sub _holdClose {
    my ($client, $by) = @_;

    my $hold = delete $_hold{ $client->id } or return;
    # 84.2-05: a hold that closes without its advance (every _holdCancel -- the
    # deferred entry is removed, LMS never opens it) must not leave the
    # _holdOpen stamp behind, or an unmarked user play of that title into a
    # dormant session would read as Connect's own re-open. On the natural
    # advance the getNextTrack consumed it before the newsong (no-op here); on
    # the cap fallback _dispatchChangePlay re-stamps after this close.
    $client->pluginData(connectOwnPlayUri => '') if ($client->pluginData('connectOwnPlayUri') // '') eq $hold->{uri};
    Slim::Utils::Timers::killTimers($client, \&_holdCheck);

    # 84-08: the player engine drops its own hold mark (no engine -> 'down').
    require Plugins::SpotOn::Unified::DaemonManager;
    Plugins::SpotOn::Unified::DaemonManager->backendFor($client)->notify('clearHold', trackId => $hold->{trackId});
    main::INFOLOG && $log->is_info && $log->info(
        "Connect: hold closed by $by (" . $client->id . ")"
    );
    return $hold;
}

# _holdCancel($client, $reason) -- H-c: a cancelling event (a new session, a
# second change, a session end, an LMS-side user action, a foreign newsong).
# The deferred playlist entry is removed, no late `playlist play` fires, the
# hold is closed `cancel:<reason>`. A no-op when no hold is open.
sub _holdCancel {
    my ($client, $reason) = @_;

    my $hold = $_hold{ $client->id } or return;
    _holdRemoveDeferred($client, $hold);
    _holdClose($client, "cancel:$reason");
    return;
}

# _holdOpen($client, $newTrackId) -- called from the change handler for a
# `live` change that passed the H-i predicates. Inserts the deferred item,
# records the playing index, arms the cap re-check, logs the opening.
sub _holdOpen {
    my ($client, $newTrackId) = @_;

    my $id  = $client->id;
    my $now = Time::HiRes::time();

    # A second `live` change replaces the still-unplayed deferred entry.
    if (my $prev = $_hold{$id}) {
        _holdRemoveDeferred($client, $prev);
        delete $_hold{$id};
        Slim::Utils::Timers::killTimers($client, \&_holdCheck);
    }

    my $song = $client->playingSong();
    my $hold = {
        uri        => "spoton://track:$newTrackId",
        trackId    => $newTrackId,
        oldUrl     => ($song && $song->track ? ($song->track->url // '') : ''),
        playingIdx => Slim::Player::Source::playingSongIndex($client),
        since      => $now,
        capAt      => $now + _holdCap($client),
        maxAt      => $now + _holdMax($client),
        held_s     => 0,
        lastCheck  => $now,
    };
    $_hold{$id} = $hold;

    # The new title becomes the NEXT playlist entry; LMS advances by itself.
    # 84.2-05: the insert IS Connect's own dispatch -- LMS's later advance to the
    # inserted item is its getNextTrack (producer P6), so it carries the one-shot
    # dispatch marker (cleared again in _holdClose if the hold closes without it;
    # a replaced hold's marker is overwritten here before the new insert).
    $client->pluginData(connectOwnPlayUri => $hold->{uri});
    _holdRequest($client, 'playlist', 'insert', $hold->{uri});

    Slim::Utils::Timers::setTimer($client, $hold->{capAt}, \&_holdCheck);

    main::INFOLOG && $log->is_info && $log->info(
        "Connect: hold opened uri=$hold->{uri} cap_at=" . int($hold->{capAt})
        . " max_at=" . int($hold->{maxAt}) . " (" . $id . ")"
    );
}

# _dispatchChangePlay($client, $newTrackId) -- the hold's fallback copy of the
# immediate path's tail (the change handler keeps its own inline copy: t/37
# pins the literal `playlist play` dispatch in that block): the per-track
# `playlist play` (D-05: the daemon's flush-disconnect is the EOF of the old
# track; this playlist play starts the next one).
sub _dispatchChangePlay {
    my ($client, $newTrackId) = @_;

    my $changePlayUrl = "spoton://track:$newTrackId";
    $client->pluginData(connectSessionPaused => 0);
    $client->pluginData(connectStartTime => Time::HiRes::time());
    $client->pluginData(connectStreamDispatchTs => Time::HiRes::time());   # 84-02: _streamElapsedSeconds
    # 84.2-05 (debug b6-prefetch-b7-africa-replay): the one-shot dispatch marker
    # `connectOwnPlayUri` -- uri-tagged, stamped at every own Soloist
    # `playlist play spoton://track:` dispatch (here, the resume re-entry, the
    # start, the change handler, the Spirc ready re-issue) and in _holdOpen
    # before its insert; consumed by ProtocolHandler::getNextTrack whatever the
    # url it asks for and read there as `origin` (connect only when it names the
    # requested url); cleared in _holdClose while unconsumed and in
    # releaseConnectClaim. A user `playlist play` never sets it. Control's
    # same-uri connect rule keeps the session for a marked re-open and hands a
    # dormant one over to browse for an unmarked one.
    $client->pluginData(connectOwnPlayUri => $changePlayUrl);
    my $changePlayReq = Slim::Control::Request->new($client->id, [
        'playlist', 'play', $changePlayUrl
    ]);
    $changePlayReq->source(__PACKAGE__);
    $changePlayReq->execute();
    return $changePlayUrl;
}

# _holdFallback($client, $reason) -- the cap/ceiling fallback: the hold
# closes `cap reason=<r>` (clearHold BEFORE the play, via _holdClose) and the
# deferred item is played the way the immediate path would have: exactly ONE
# `playlist play`.
sub _holdFallback {
    my ($client, $reason) = @_;

    my $hold = $_hold{ $client->id } or return;
    _holdClose($client, "cap reason=$reason");
    _dispatchChangePlay($client, $hold->{trackId});
}

# _holdCheck($client) -- the safety timer, ONE rule with a fixed precedence;
# the LMS clock is never consulted. Fires at HOLD_CAP_S, then every
# HOLD_RECHECK_S while the hold is open:
#   d1  playmode stop              -> the tail drained and LMS did not
#                                     advance: ONE fallback `playlist play`
#   d4  any paused state           -> no play; re-arm; the ceiling clock does
#                                     not run (LMS pause or the app's pause)
#   d3  accumulated PLAYING time on the old url >= HOLD_MAX_S -> `playlist
#                                     play` (reason=ceiling, the safety net)
#   d2  LMS still plays the old url -> no play; re-arm
# A newsong for the deferred item kills the timer in every state (_holdClose).
sub _holdCheck {
    my ($client) = @_;

    my $hold = $_hold{ $client->id } or return;
    my $now   = Time::HiRes::time();
    my $delta = $now - ($hold->{lastCheck} // $now);
    $delta = 0 if $delta < 0;

    my $mode = Slim::Player::Source::playmode($client) // '';
    my $song = $client->playingSong();
    my $url  = ($song && $song->track) ? ($song->track->url // '') : '';

    # Defensive: LMS already plays the deferred item but its newsong did not
    # reach us -- close without playing anything.
    if ($url eq $hold->{uri}) {
        _holdClose($client, 'newsong reason=seen_by_check');
        return;
    }

    if ($mode eq 'stop') {                                              # d1
        _holdFallback($client, 'lms_stopped');
        return;
    }

    my $paused = ($mode eq 'pause') || $client->pluginData('connectSessionPaused');
    if ($paused) {                                                      # d4
        $hold->{lastCheck} = $now;
        Slim::Utils::Timers::setTimer($client, $now + _holdRecheck($client), \&_holdCheck);
        return;
    }

    $hold->{held_s} += $delta if $url eq $hold->{oldUrl};
    $hold->{lastCheck} = $now;

    if ($hold->{held_s} >= _holdMax($client)) {                         # d3
        _holdFallback($client, 'ceiling');
        return;
    }

    Slim::Utils::Timers::setTimer($client, $now + _holdRecheck($client), \&_holdCheck);   # d2
}

# _onPause($request)
# Forwards LMS pause/stop events to the binary's HTTP control endpoint (D-14).
sub _onPause {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    if ($request->source && $request->source eq __PACKAGE__) {
        main::DEBUGLOG && $log->is_debug && $log->debug("SpotOn G3-INSTR: _onPause skip=source");
        return;
    }

    # D-34 (79-48): an app pause/play during LMS-started Browse is forwarded to
    # LMS by Control (its request filter decided the daemon did it, not LMS);
    # the pause notification that request causes must not travel back to the
    # daemon. Control's source marker is BROWSE_FORWARD_SOURCE (Control.pm); the
    # token is repeated here, as a literal inside this sub (t/core/37 evals the
    # sub text on its own), because this module must not load Control or spell
    # a Soloist package (t/soloist/44 pins the two literals together).
    if ($request->source && $request->source eq 'spoton-browse-forward') {
        main::DEBUGLOG && $log->is_debug && $log->debug("SpotOn D-34: _onPause skip=control-forward");
        return;
    }

    my $isUnpause = $request->isCommand([['playlist'], ['pause']]) && !$request->getParam('_newvalue');
    my $isStop    = $request->isCommand([['playlist'], ['stop']]) ? 1 : 0;

    my $client = $request->client();
    unless (defined $client) {
        main::DEBUGLOG && $log->is_debug && $log->debug("SpotOn G3-INSTR: _onPause skip=noclient");
        return;
    }
    $client = $client->master;

    # Phase 82 (Befund 3, T-4): a Soloist Browse session (NOT an active
    # Connect session) forwards pause/unpause to the daemon via Control.
    # Checked BEFORE the Connect-claim gate below, same position as the
    # retired 78-02 finder, so browse forwarding is not shadowed by it.
    # The old play-confirm time-window suppression is GONE:
    # Control->requestPause classifies against LMS' CURRENT playmode at
    # notification-delivery time instead -- notifications are always
    # delivered AFTER the synchronous command that caused them, so a stale
    # internal stop (LMS already back on 'play') is recognized and dropped
    # there, not here. Pause/Stop are never deadened (Note Section 1.2).
    # 84-07 (SEAM-6.2): the command reaches its daemon through the backend
    # role -- Soloist: Control's requestPause/requestResume; librespot: the
    # HTTP /control/* sender (moved to Backend::Librespot).
    require Plugins::SpotOn::Unified::DaemonManager;
    my $be     = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    my $beMode = $be->state->{mode};

    # G3-MESS (82-20): visibility for the LMS-stop -> daemon chain -- DEBUG
    # only, no behavior change. See 82-G3-MESSUNG.md Hypothesenregister H-D.
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "SpotOn G3-INSTR: _onPause mac=" . ($client->id // '?')
        . " isUnpause=" . ($isUnpause ? 1 : 0)
        . " isStop=" . $isStop
        . " ctl=" . (defined $beMode ? 1 : 0)
        . " mode=" . ($beMode // 'noctl')
    );

    # 83.1-03 (D-08): both modes now route through Control's request
    # primitives -- Control's own playmode-at-delivery classification
    # (Befund 3, above) already covers the stop-before-play echo the
    # connectPauseTs/connectStartTime grace windows below exist for, and
    # the source-marked 'stop inactive' request is skipped at the top of
    # this sub regardless of mode. The connect-only suppression chain
    # below (connectPauseTs echo <1s, connectStartTime grace 3s,
    # player-switch guard, dead-history guard) is reached only when NO
    # Control exists for this player (librespot) -- plan 06's code walk
    # must confirm, hop by hop at a title boundary, that Control covers
    # each of those four suppressions BEFORE plan 07 deletes this
    # fallthrough; this bypass lands here, ahead of that proof.
    # 84-07: that chain is now gated by the role's connectClaimGate
    # capability (librespot 1, soloist 0) instead of "no Control instance";
    # its text below is unchanged. A Soloist player -- with or without a
    # Control instance -- goes straight to control(); without Control the
    # role answers 'down' and nothing else happens (84-07 decision, user
    # 2026-10-11: no fallthrough into the librespot HTTP/Web-API path).
    if ($be->capabilities->{connectClaimGate}) {
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
        #
        # 83.1-07 (D-C3 group E): this code is reached only when $ctl is undef
        # (librespot -- the `if ($ctl) { ...; return; }` above already returns
        # for every Soloist player), so the former helper's Soloist-ownership
        # branch could never contribute true here -- it asked the same
        # for_client() registry this function already found empty. Inlined as
        # the librespot-only check it always was in this call site; no
        # Control-mode question needed (there is no Control instance to ask).
        my $onPauseSong = $client->playingSong();
        my $onPauseUrl  = $onPauseSong ? ($onPauseSong->track->url || $onPauseSong->streamUrl || '') : '';
        my $isLiveConnectStream = 0;
        if ($onPauseUrl =~ m{spoton://connect-}) {
            $isLiveConnectStream = (!$onPauseSong->pluginData('info') && _isDeadHistoryUrl($onPauseUrl)) ? 0 : 1;
        }
        if (!$isLiveConnectStream
            && !$client->pluginData('pendingConnect')
            && Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0) >= CONNECT_START_GRACE)
        {
            main::INFOLOG && $log->is_info && $log->info(sprintf(
                "D-16: stale Connect claim on %s - no live connect stream, no pending start, "
                . "grace expired (%.1fs ago). Releasing claim, NOT forwarding pause to daemon.",
                $client->id,
                Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0)
            ));
            # 83.1-07 (D-C3 group E): D-D2 visibility for this retained release
            # path too (see the matching log in _onNewSong's D-16 block).
            $log->warn("Connect claim released by _onPause (D-D2)");
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
                    "Skipping daemon unpause - history replay URL detected: $songUrl"
                );
                return;
            }
        }

        if ($isUnpause) {
            # GH #158: LMS-side unpause resumes the Spotify session — clear the
            # remembered pause state immediately (the daemon's own resume/playing
            # echo would clear it too, but not before the next change could race).
            # (The "forwarding to Connect binary" info lines moved with the
            # sender into Backend::Librespot::control, 84-07.)
            $client->pluginData(connectSessionPaused => 0);
        }
    }

    my $verb    = $isUnpause ? 'play' : 'pause';
    my $outcome = $be->control($verb, isStop => $isStop, source => ($isStop ? 'lms_stop' : 'lms_pause'));
    main::INFOLOG && $log->is_info && $log->info(
        "_onPause: control($verb) -> $outcome for " . ($client->id // '?')
    );
}

# _onVolume($request)
# Forwards LMS volume changes to the daemon (Browse, via Control) or the
# binary's HTTP control endpoint (Connect, D-14), with 0.5s debounce.
sub _onVolume {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    # Phase 82 (D-06, T-6): Browse forwards too now -- gated on Control's
    # own mode (idle has no daemon to forward to) rather than the Connect
    # claim alone. 84-08: the mode comes from the backend role (librespot:
    # undef -> only the Connect claim forwards, as before).
    require Plugins::SpotOn::Unified::DaemonManager;
    my $volMode = Plugins::SpotOn::Unified::DaemonManager->backendFor($client)->state->{mode};
    return unless (defined $volMode && $volMode ne 'idle') || __PACKAGE__->isSpotifyConnect($client);

    my $volume = $client->volume;

    # Debounce: merge rapid volume events into one (0.5s window)
    Slim::Utils::Timers::killTimers($client, \&_bufferedSetVolume);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + VOLUME_DEBOUNCE, \&_bufferedSetVolume, $volume);
}

sub _bufferedSetVolume {
    my ($client, $volume) = @_;

    # Phase 82 (D-06, T-6) / 83.1-03 (D-08) / 84-07 (SEAM-6.2): one call
    # through the backend role -- Soloist: Control's requestVolume (Browse/
    # idle/connect-with-daemon); librespot: HTTP /control/volume with the
    # D-15 Web API fallback (Backend::Librespot, which also carries the
    # "Forwarding volume" info and [DIAG] lines).
    require Plugins::SpotOn::Unified::DaemonManager;
    my $outcome = Plugins::SpotOn::Unified::DaemonManager->backendFor($client)
        ->control('set_volume', volume => int($volume));
    main::INFOLOG && $log->is_info && $outcome ne 'ok' && $log->info(
        "_bufferedSetVolume: control(set_volume) -> $outcome for " . ($client->id // '?')
    );
}

# _onSeek($request)
# Observes LMS seek events. 84-07 (SEAM-6.2): through the backend role.
# 79-28 D-23: a backend whose handlers carry the Connect-claim gate
# (librespot) and the capability connectSeekViaControl forwards the seek to
# the daemon -- debounced 0.3 s, then control('seek', position_ms => N) ->
# POST /control/seek -- and getSeekData returns undef so LMS does not restart
# /stream (the daemon's flush carries the jump). A Soloist player in connect
# sends ONE call, control('seek', position_ms => N), for every position
# (Backend::Soloist maps 0 to requestSkip('prev','time0') and N > 0 to an
# acknowledgement -- the LMS restart chain carries the seek, D-B1); in
# browse this is an observer only.
sub _onSeek {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    # 84-17 (H-c): an LMS-side seek is a user action -- an open hold is cancelled.
    _holdCancel($client, 'lms_seek');

    require Plugins::SpotOn::Unified::DaemonManager;
    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);

    # Librespot (79-28 D-23): the binary has POST /control/seek (unified.rs:1250-1255).
    # The 83.1-04/83.1-07 removal of the v2.x forward left LMS seeks
    # without any effect on the app; the forward is back behind the
    # capability connectSeekViaControl. The target comes from the request
    # (no LMS restart, so songTime still holds the OLD position for a
    # relative seek); the daemon's Seeked event only adjusts startOffset and
    # issues no LMS request (T-79-92).
    if ($be->capabilities->{connectClaimGate}) {
        return unless __PACKAGE__->isSpotifyConnect($client);
        return unless $be->capabilities->{connectSeekViaControl};

        my $position = _seekPositionFromRequest($client, $request);
        Slim::Utils::Timers::killTimers($client, \&_forwardLibrespotSeek);
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SEEK_DEBOUNCE, \&_forwardLibrespotSeek, int($position * 1000));
        return;
    }

    # Plan 77-04/82-04 (D-02/D-04): Browse seeks are armed and dispatched
    # exclusively via canDoAction/getSeekData -> onStream -> Control
    # (Prinzip 3.1(4), one entry point) -- never from this handler. In
    # Browse this is a Beobachter only: a debug-level consistency check
    # against Control's own wanted.position_ms, never a second command
    # path (D-04). A Soloist player WITHOUT a Control instance (mode
    # undef) returns here as well -- 84-07 decision (user 2026-10-11): no
    # fallthrough into the librespot path.
    my $mode = $be->state->{mode};
    if (($mode // '') ne 'connect') {
        return unless defined $mode;
        my $want = $be->query('wantedPositionMs');
        my $req  = int(_seekPositionFromRequest($client, $request) * 1000);
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Soloist browse: ['time'] observer -- request=${req}ms wanted="
            . ($want // 'undef') . "ms (" . $client->id . ")"
        );
        return;
    }

    # 83.1-04 (D-B1): mode=connect -- a seek N > 0 does not command from
    # here: getSeekData (ProtocolHandler.pm) returns {timeOffset} for
    # connect too, so LMS restarts the stream and the restart chain
    # (onStream -> Control's own play-request cascade -> the connect seek
    # row in _reconcilePlan) carries the seek through arm+`send seek`. An
    # exact `time 0` is the one case getSeekData/canDoAction('rew')
    # suppress the LMS-side restart for (ProtocolHandler.pm::canDoAction,
    # D-B2) -- the role routes that one through the skip-backward route,
    # matching Spotify's own "restart-at-0 near the start of a track means
    # previous track" semantics.
    my $position = _seekPositionFromRequest($client, $request);
    my $outcome  = $be->control('seek', position_ms => int($position * 1000));
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Soloist connect: ['time'] observer -- restart chain carries the seek (D-B1) -- control(seek) -> $outcome ("
        . $client->id . ")"
    );
}

# _forwardLibrespotSeek($client, $positionMs) -- the debounce timer target of
# the librespot connect seek (79-28 D-23). The backend is resolved again: the
# daemon may be gone after the 0.3 s window.
sub _forwardLibrespotSeek {
    my ($client, $positionMs) = @_;
    return unless $client;

    require Plugins::SpotOn::Unified::DaemonManager;
    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    return unless $be;
    return unless __PACKAGE__->isSpotifyConnect($client);

    my $outcome = $be->control('seek', position_ms => $positionMs);
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Librespot connect: control(seek, ${positionMs}ms) -> $outcome (" . $client->id . ")"
    );
}

# _onPlaylistJump($request)
# 83.1-04 (D-B2) / 84-07 (SEAM-6.2): both title keys go through the backend
# role -- control('skip_next'|'skip_prev', reason => ...); `jump +0` asks
# control('restart') first (debug session connect-skip-prev-ton-bleibt,
# decision 1B, see below) and falls back to skip_prev on anything but ok
# (librespot: restart is unsupported -> /control/prev, as before).
sub _onPlaylistJump {
    my $request = shift;

    # Source-marking loop prevention (T-05-13): skip our own requests
    return if $request->source && $request->source eq __PACKAGE__;

    my $client = $request->client();
    return if !defined $client;
    $client = $client->master;

    my $index = $request->getParam('_index');
    return if !defined $index;

    # 84-17 (H-c): an LMS-side jump is a user action -- an open hold is cancelled.
    _holdCancel($client, 'lms_jump');

    require Plugins::SpotOn::Unified::DaemonManager;
    my $be   = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    my $gate = $be->capabilities->{connectClaimGate};

    if ($gate) {
        return unless __PACKAGE__->isSpotifyConnect($client);

        # Suppress _onPause echo: LMS fires internal pause/stop events during
        # playlist jump (old track stops). Without this, _onPause forwards them
        # as /control/pause BEFORE the skip command takes effect. Kept for the
        # librespot path only -- Control's own requestPause historic
        # check (playmode-at-delivery, Befund 3) replaces this suppression for
        # Soloist (D-B2), where the write would be a second, needless
        # command path.
        $client->pluginData(connectPauseTs => Time::HiRes::time());
    }
    else {
        # Phase 82: in Browse, LMS' own playlist movement drives the next
        # track via getNextTrack -- no skip_* command to send (Control is the
        # single entry point, Prinzip 3.1(4)). A Soloist player WITHOUT a
        # Control instance (mode undef) returns here too -- 84-07 decision
        # (user 2026-10-11): no fallthrough into the librespot path.
        return if ($be->state->{mode} // '') ne 'connect';
    }

    if ($index eq '+1') {
        main::INFOLOG && !$gate && $log->is_info && $log->info(
            "Connect mode: jump +1 -> Control's skip-forward route (D-B2)"
        );
        $be->control('skip_next', reason => 'jump+1');
    }
    # Debug session connect-skip-prev-ton-bleibt (2026-09-24), user
    # decision 1B -- DEVIATION from D-B2 for `jump +0`: LMS decides, like
    # its own "previous" button (Slim::Buttons::Common 'jump' rew: >= 5 s
    # into the title -> `jump +0`, else `jump -1`). `+0` restarts this
    # title from 0 through the seek path (Control::requestRestart -> LMS
    # stream restart -> armed `seek 0`); a skip_prev here made Spotify
    # restart the title while LMS kept playing buffered old audio and
    # stopped 15-22 s later. Only a real `jump -1` goes to Spotify as
    # skip_prev. The role answers 'declined' where the restart cannot run
    # (LMS paused/stopped, not seekable, daemon on another title) and
    # 'unsupported' on librespot -- `+0` then keeps the skip_prev route.
    elsif ($index eq '+0' && $be->control('restart', reason => 'jump+0') eq 'ok') {
        main::INFOLOG && $log->is_info && $log->info(
            "Connect mode: jump +0 -> restart from the start via the seek path (1B)"
        );
    }
    elsif ($index eq '-1' || $index eq '+0') {
        main::INFOLOG && !$gate && $log->is_info && $log->info(
            "Connect mode: jump $index -> Control's skip-backward route (D-B2)"
        );
        $be->control('skip_prev', reason => 'jump' . $index);
    }
}

# _liveCaps($client) -- the backend role's capabilities for a player whose
# daemon is up (84-08, SEAM-6.2). Replaces the former
# `helperForClient($client->id) && isa(<Soloist daemon class>)` checks of
# _connectEvent one for one: no running daemon -> {} so every per-backend
# branch falls to the generic path exactly as before; a running daemon ->
# the role says what differs (claimOnStart, connectEntry, holdOnChange,
# readyReplaysLastTrack) -- never a class name or a backend name here.
sub _liveCaps {
    my ($client) = @_;
    require Plugins::SpotOn::Unified::DaemonManager;
    return {} unless Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client) or return {};
    return $be->capabilities;
}

# _playUrlFor($client, $trackId) -- the LMS playlist URL a Connect entry
# plays (D-04 backend dispatch, 84-08 on capabilities->{connectEntry}):
#   pertrack  (and a track id) -> spoton://track:<id>  -- one LMS entry per
#             Spotify track (same audio contract as Browse)
#   otherwise                  -> spoton://connect-<ms> -- the repeating
#             stream with a unique timestamp URL (librespot, Windows
#             constraint; also a per-track backend without a track id)
sub _playUrlFor {
    my ($client, $trackId) = @_;
    return "spoton://track:$trackId"
        if $trackId && (_liveCaps($client)->{connectEntry} // '') eq 'pertrack';
    my $ts = int(Time::HiRes::time() * 1000);
    return sprintf("spoton://connect-%u", $ts);
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

    # 83.1-07 (EIGENTUMSFRAGE point 3): resolved once per event for the
    # sharpened change/seek guards below -- asks the player engine's own
    # mode as a second, independent signal alongside the
    # $_activeConnectPlayer claim. 84-08 (SEAM-6.2): through the backend
    # role; $ctlMode re-reads its state on every call (librespot: undef).
    require Plugins::SpotOn::Unified::DaemonManager;
    my $evBe    = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    my $ctlMode = sub { $evBe ? $evBe->state->{mode} : undef };

    # KE: browse-connect-gating -- Phase 82: Browse/Connect discrimination
    # for the Soloist backend now lives in Plugins::SpotOn::Soloist::Control
    # (`mode`), UPSTREAM of this handler. In `mode=browse`, Control's own
    # Mode-Policy (`_emit`) only ever surfaces `volume` -- every other cmd
    # (start/change/stop/resume/seek) simply never dispatches a spottyconnect
    # request while browse holds, so this handler never sees a Soloist
    # Browse echo or auto-advance for those.

    # Claim active Connect ownership on 'start' (must be synchronous, before async ops)
    if ($cmd eq 'start') {
        $client->pluginData(pendingConnect => 1);

        # D-D1: a backend whose claim is bound ONLY by its player engine's
        # transfer class (bindConnectClaim, source 'transfer';
        # capabilities->{claimOnStart} 0) must not let this generic 'start'
        # dispatch -- it fires for ANY spottyconnect start request, including
        # a stray/foreign one -- silently claim ownership. 84-08: asked of
        # the role (_liveCaps: no running daemon -> the generic path, as
        # before).
        my $startCaps = _liveCaps($client);
        if (%$startCaps && !$startCaps->{claimOnStart}) {
            if ($_activeConnectPlayer && $_activeConnectPlayer ne $client->id) {
                $log->warn(
                    "Connect claim: unclean source start (claim=" . $_activeConnectPlayer . ", player=" . $client->id . ")"
                );
            }
        }
        else {
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
    }

    # -----------------------------------------------------------------
    # Volume handler (CON-11): check grace period before forwarding
    # -----------------------------------------------------------------
    if ($cmd eq 'volume') {
        # Phase 82 (D-06): H6-Guard entfernt -- Control emittiert `volume`
        # nur fuer Fremdwerte (Echo ueber pending, Schonfrist in Control);
        # der strukturelle Ersatz ist der Volume-Push beim Browse-Eintritt.
        # Reversibility costly: der Guard war gegen `connect-metadata-bleed`
        # gebaut (RESEARCH/CONTEXT D-06) -- ihn wieder einzuziehen hiesse,
        # den strukturellen Ersatz erneut durch eine Ausnahme zu ersetzen.

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
        # Guard (formerly grouped under "H6", 46-01): ignore Spirc seek
        # events for players not in an active Connect session (metadata/
        # position bleed fix). Unrelated to the Volume-H6 that Phase 82
        # (D-06) removed -- this one stays, Phase 83 territory. CON-17
        # exception: seek can arrive BEFORE playlist play — accept while
        # pendingConnect is set.
        #
        # D-34 (79-48): an app seek during LMS-started Browse on Soloist is
        # marked `browse` by Control (its _p4, the 4th positional). It takes
        # the same startOffset rewrite below -- never ['time', N], which would
        # re-open the stream -- but only while Control's mode really is
        # browse; every other seek keeps both guards exactly as they were.
        my $browseSeek = (($request->getParam('_p4') // '') eq 'browse') ? 1 : 0;
        if ($browseSeek && (($ctlMode->() // '') ne 'browse')) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Dropping browse-marked seek for " . $client->id . " (Control mode is not browse)");
            return;
        }
        unless ($browseSeek || __PACKAGE__->isSpotifyConnect($client) || $client->pluginData('pendingConnect')) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Dropping Connect seek event for non-Connect player " . $client->id . " (connect-guard)");
            return;
        }

        # 83.1-07 (EIGENTUMSFRAGE point 3): sharpen the guard -- claim AND
        # Control mode. The guard's second purpose (D-D2 visibility) fires
        # when the claim and Control disagree; the guard's first purpose
        # (keep a Browse player out of the per-track playlist-play path
        # that would collapse the Browse playlist) is served the same way.
        if (!$browseSeek && defined $ctlMode->() && $ctlMode->() ne 'connect') {
            $log->warn("Connect claim vs Control mode disagree -- dropping change for " . $client->id
                . " (claim=" . (__PACKAGE__->isSpotifyConnect($client) ? 1 : 0)
                . " mode=" . $ctlMode->() . ", D-D2)");
            return;
        }

        my $position = $request->getParam('_p2');
        # 84-17: Control marks the seek that echoes a just-changed item
        # (queued behind the pending `change`) with `deferred`. Logged here;
        # handled as today in this task (Task 2: dropped while a hold is open).
        my $seekDeferred = $request->getParam('_p4');
        main::INFOLOG && $log->is_info && $log->info("Connect seek marked $seekDeferred (84-17)")
            if defined $seekDeferred && $seekDeferred eq 'deferred';
        # 84-17 (H-e): while a hold is open EVERY `seek ... deferred` is the
        # daemon's write-side position (the end-of-write position_sync pair,
        # the echo of the changed item): 20-35 s ahead of the audible one. It
        # is dropped -- never written to the playing song's startOffset, never
        # stored for the new song. Without a hold the marker changes nothing.
        if (defined $seekDeferred && $seekDeferred eq 'deferred'
            && defined $position && $position ne '' && $_hold{ $client->id })
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Connect: deferred position dropped pos=$position (" . $client->id . ")"
            );
            return;
        }
        if (defined $position && $position ne '') {
            main::INFOLOG && $log->is_info && $log->info("Binary reported seek to: $position");
            $log->warn("[DIAG] seek_from_binary: mac=" . $client->id . " position=$position") if $prefs->get('diagnosticMode');

            if (!$browseSeek && $client->pluginData('pendingConnect')) {
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
                    my $elapsed = _streamElapsedSeconds($client);
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
        _settleCancel($client, 'resume');    # 84.3-01
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
        # Phase 78-04: Soloist Connect sessions use spoton://track:ID URLs, so
        # also ask Control's own mode as "on Connect stream" (83.1-07:
        # replaces the former Soloist track-ID URL-matching heuristic --
        # Control reporting mode='connect' with an observed track, on a
        # current spoton://track:/episode: URL, is the same fact the
        # heuristic inferred from the daemon's lastTrackId, now asked
        # directly).
        my $hasLiveMetadata = $song && $song->pluginData('info');
        my $isDeadHistory = $currentUrl =~ m{spoton://connect-} ? _isDeadHistoryUrl($currentUrl) : 0;
        my $actuallyInConnect = (($currentUrl =~ m{spoton://connect-})
                             && ($hasLiveMetadata || !$isDeadHistory))
                             || (($ctlMode->() // '') eq 'connect' && $evBe->state->{observedTrack}
                                 && $currentUrl =~ m{^spoton://(?:track|episode):});

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
                    "Dropping spurious resume for dead history URL - Browse pipeline handles playback"
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
                "Resume while not on Connect stream - re-entering Connect via playlist play"
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
            # D-D2: unclean-source warn for a Soloist helper's resume
            # re-entry, mirroring the 'start' branch's check above -- the
            # resume write itself stays in place (EIGENTUMSFRAGE point 3,
            # D-C1 ordering; only a log line is added here).
            if ((_liveCaps($client)->{connectEntry} // '') eq 'pertrack'
                && $_activeConnectPlayer && $_activeConnectPlayer ne $client->id)
            {
                $log->warn(
                    "Connect claim: unclean source resume (claim=" . $_activeConnectPlayer . ", player=" . $client->id . ")"
                );
            }
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
            # 84-08: _playUrlFor asks the role's connectEntry.
            my $playUrl = _playUrlFor($client, $trackId);
            if ($playUrl =~ m{^spoton://track:}) {
                $client->pluginData(connectStreamDispatchTs => Time::HiRes::time());   # 84-02: _streamElapsedSeconds
                $client->pluginData(connectOwnPlayUri => $playUrl);   # 84.2-05: one-shot dispatch marker (see _dispatchChangePlay)
                # 84-02 C4-c: the reactivation transfer-in (seek + resume while
                # LMS holds no song): the seek echo had no song to adjust, this
                # re-entry is where the app position is still known -- hand it
                # to _onNewSong like the start handler does.
                if (defined $position && $position ne '' && $position > 0) {
                    $client->pluginData(progress => $position);
                }
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

        # 84-26 F-24-2 (C6, 84-24): LMS PAUSED with the stream gone (PAUSED-IDLE) -- the plain
        # `['pause', 0]` below reaches `_JumpOrResume` and re-opens the title at LMS's stale
        # `resumeTime` (see _pausedStreamGone for the state-table columns). Set LMS's resume position
        # to the DAEMON's first, so the re-open and the seek chain carry the daemon's figure:
        # `controller->jumpToTime` while PAUSED -> `_JumpPaused` (SC:166, :1051-1090) sets
        # `resumeTime = $position` and calls `_pauseStreaming` (a no-op on an idle stream). A direct
        # controller call, never `Slim::Control::Request ['time']`: no `['time']` notification exists
        # for `_onSeek` (:1278-1282) to loop on. The floor RESUME_JUMP_MIN_MS keeps a sub-second reset
        # figure from restarting the title.
        my $jumped = 0;
        if (defined $position && $position ne '' && $position * 1000 >= RESUME_JUMP_MIN_MS
            && _pausedStreamGone($client))
        {
            $client->controller->jumpToTime($position);
            $jumped = 1;
            main::INFOLOG && $log->is_info && $log->info(
                "Connect: resume while LMS paused with the stream gone -- resume position set to the daemon's $position s, startOffset adjust skipped ("
                . $client->id . ")"
            );
        }

        my $unPauseReq = Slim::Control::Request->new($client->id, ['pause', 0]);
        $unPauseReq->source(__PACKAGE__);
        $unPauseReq->execute();

        # CON-13: Sync position via startOffset — NEVER use ['time', N] in stream mode.
        # startOffset adjusts songTime without triggering _JumpToTime -> _Stop + _Stream.
        #
        # 84-17 (H-e): not during a hold. A `resume` for the deferred track
        # (or marked `deferred` by Control) carries the daemon's write-side
        # position; written to the PLAYING song's startOffset it would jump
        # the old title's clock by the whole downstream buffer (+31.8 s in
        # run 3). Dropped with one line; the `['pause', 0]` above stays (a
        # no-op on a playing player).
        my $resumeDeferred = $request->getParam('_p4');
        my $holdNow = $_hold{ $client->id };
        if ($holdNow && defined $position && $position ne ''
            && ((defined $resumeDeferred && $resumeDeferred eq 'deferred')
                || (defined $trackId && $trackId eq $holdNow->{trackId})))
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Connect: deferred position dropped pos=$position (" . $client->id . ")"
            );
        }
        elsif (defined $position && $position ne '' && !$jumped) {
            # 84-26 F-24-2: skipped when the jump was taken -- this write is `position - the OLD stream's
            # elapsed` (84-24 C6 extract.txt:162 `Resume: adjusted startOffset to 25.191`), the re-opened
            # song's clock comes from the seekdata instead (onStream sets its startOffset to the seek target).
            my $song = $client->playingSong();
            if ($song) {
                my $elapsed = _streamElapsedSeconds($client);
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
        _holdCancel($client, 'start');    # 84-17 (H-c): a new session
        _settleCancel($client, 'start');  # 84.3-01
        my $trackId = $request->getParam('_p2');
        # 84-02 C4-c: Control's transfer-in passes the app position (seconds,
        # '%.3f') as the third parameter; '' when unknown. It becomes the
        # CON-17 progress that _onNewSong applies to the new Song's clock --
        # the same hand-over the deferred seek echo uses for librespot.
        my $startPosition = $request->getParam('_p3');

        # KE: browse-connect-gating -- the old 78-02 echo guard here (trackId
        # match against _currentSpotonTrackUrl) is gone. A Soloist Browse
        # echo never reaches this handler at all now: Control's own
        # Mode-Policy (mode=browse) suppresses it at the source (82-05). Any
        # 'start' that arrives here for a Soloist backend is by construction
        # a genuine Connect transfer (device_changed(is_active:true) is what
        # switches Control's mode to connect right before it emits).

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
                . "with idle player - restored session, not a user transfer (Phase 76 restart gate)",
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
        # 83.1-07: replaces the former Soloist track-ID URL-matching
        # heuristic with Control's own mode.
        my $song = $client->playingSong();
        my $currentUrl = $song ? ($song->streamUrl || '') : '';
        if ($currentUrl =~ m{^spoton://} && $currentUrl !~ m{spoton://connect-}
            && ($ctlMode->() // '') ne 'connect')
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
        # 84-08: _playUrlFor asks the role's connectEntry.
        my $startPlayUrl = _playUrlFor($client, $trackId);
        {
            if ($startPlayUrl =~ m{^spoton://track:}) {
                $client->pluginData(connectStreamDispatchTs => Time::HiRes::time());   # 84-02: _streamElapsedSeconds
                $client->pluginData(connectOwnPlayUri => $startPlayUrl);   # 84.2-05: one-shot dispatch marker (see _dispatchChangePlay)
                # 84-02 C4-c: a transfer-in enters mid-title and no seek echo
                # follows (live 2026-09-30 11:03:46: verbs = start only) --
                # hand the app position to _onNewSong as the initial clock.
                if (defined $startPosition && $startPosition ne '' && $startPosition > 0) {
                    $client->pluginData(progress => $startPosition);
                }
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
        _settleCancel($client, 'change');    # 84.3-01
        # Guard (formerly grouped under "H6", 46-01): ignore Spirc change
        # events for players not in an active Connect session — a change for
        # a player back in Browse mode would overwrite Browse metadata
        # (known error: connect-metadata-bleed). Unrelated to the Volume-H6
        # that Phase 82 (D-06) removed -- this one stays, Phase 83
        # territory. pendingConnect exception mirrors the seek handler
        # (event may precede playlist play).
        unless (__PACKAGE__->isSpotifyConnect($client) || $client->pluginData('pendingConnect')) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Dropping Connect change event for non-Connect player " . $client->id . " (connect-guard)");
            return;
        }

        # 83.1-07 (EIGENTUMSFRAGE point 3): sharpen the guard -- claim AND
        # Control mode. The guard's second purpose (D-D2 visibility) fires
        # when the claim and Control disagree; the guard's first purpose
        # (keep a Browse player out of the per-track playlist-play path
        # that would collapse the Browse playlist) is served the same way.
        if (defined $ctlMode->() && $ctlMode->() ne 'connect') {
            $log->warn("Connect claim vs Control mode disagree -- dropping change for " . $client->id
                . " (claim=" . (__PACKAGE__->isSpotifyConnect($client) ? 1 : 0)
                . " mode=" . $ctlMode->() . ", D-D2)");
            return;
        }

        my $newTrackId  = $request->getParam('_p2');
        my $prevTrackId = $request->getParam('_p3');
        # 84-17 (L1 repair): the 4th positional is the audio shim's own
        # classification of this title change, read by Soloist::Control from
        # the POST /boundary reply -- live (the old title was still being
        # streamed = a natural end), departed (the old client was already
        # closed by the skip's flush), none, timeout, unknown. Undef on the
        # librespot path and on every `nachziehen` re-emit. `live` takes the
        # hold (below); every other value keeps the immediate `playlist play`.
        my $via = $request->getParam('_p4');

        # Clear echo suppression — track change is authoritative
        $client->pluginData(connectPauseTs => 0);

        main::INFOLOG && $log->is_info && $log->info(
            "Track change: $prevTrackId -> $newTrackId via=" . ((defined $via && $via ne '') ? $via : 'none')
        );

        # 84-17 (L1 repair): decide the hold BEFORE anything touches the
        # playing song. Only a `live` change on the Soloist backend that
        # passes the H-i predicates (LMS's own advance will open the deferred
        # item) is held; a second change while a hold is open either replaces
        # it (live) or cancels it (anything else -- its `playlist play`
        # replaces the playlist, the deferred entry goes with it).
        my $wantHold = 0;
        {
            # 84-08: only a backend with the change hold (capabilities->
            # {holdOnChange}) and a running daemon.
            if (defined $via && $via eq 'live' && $newTrackId
                && _liveCaps($client)->{holdOnChange})
            {
                my $skip = _holdSkipReason($client);
                if (defined $skip) {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Connect: hold skipped reason=$skip (" . $client->id . ")"
                    );
                }
                else {
                    $wantHold = 1;
                }
            }
            _holdCancel($client, 'change') if !$wantHold && $_hold{ $client->id };
        }

        my $song = $client->playingSong();
        if ($wantHold) {
            # The old title keeps playing: its clock must not be reset (that
            # would put it to 0:00 while its tail plays) and its play point
            # stays; only the stored progress is dropped -- nothing the
            # daemon reports during the hold applies to the new song.
            $client->pluginData(progress => 0);
        }
        elsif ($song) {
            # Reset progress bar for the new track: in stream mode,
            # songElapsedSeconds counts from the original stream start,
            # so startOffset must compensate to reset songTime to ~0.
            # The client push for this reset happens later, from
            # _fetchTrackMetadata's exit paths (Phase 58) -- pushing it here
            # would announce position=0 before the real position is known.
            my $elapsed = $client->songElapsedSeconds() || 0;
            $song->startOffset(0 - $elapsed);
            # 84-21 (D-26): this writer was silent -- the attribution of a
            # negative startOffset (L1) could not tell it from the seek
            # writer. NOT the seek writer's wording: the midtitle attribution
            # counts that line as a negative-offset SpotOn write and the
            # change reset is negative on every natural change.
            main::INFOLOG && $log->is_info && $log->info(
                "Stream mode change reset: startOffset=" . $song->startOffset()
                . " elapsed=" . sprintf('%.3f', $elapsed) . " (" . $client->id . ")"
            );
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
        #
        # 84-26 F-24-2 (sibling of the resume branch): on a PAUSED player with the stream gone this
        # unpause reaches the same `_JumpOrResume` at a stale `resumeTime` and re-opens the OLD title,
        # right before the `playlist play` of the new title (below) replaces it. For the Soloist backend
        # WITH a new track id (the condition that gates that `playlist play`; without one no play follows
        # and the unpause stays) it is skipped; the librespot path stays byte-identical (its repeating
        # `connect-<ts>` stream needs the re-open).
        my $skipChangeUnpause = 0;
        if (!$client->isPlaying && $client->isPaused && $newTrackId) {
            # 84-08: the per-track entry backends (connectEntry pertrack).
            if ((_liveCaps($client)->{connectEntry} // '') eq 'pertrack'
                && _pausedStreamGone($client))
            {
                $skipChangeUnpause = 1;
                main::INFOLOG && $log->is_info && $log->info(
                    "Connect: change while LMS paused with the stream gone -- unpause skipped, the playlist play re-opens the new title ("
                    . $client->id . ")"
                );
            }
        }
        if (!$client->isPlaying && __PACKAGE__->isSpotifyConnect($client)
            && !$client->pluginData('connectSessionPaused') && !$skipChangeUnpause) {
            $client->pluginData(connectPauseTs => Time::HiRes::time());
            my $playReq = Slim::Control::Request->new($client->id, ['pause', 0]);
            $playReq->source(__PACKAGE__);
            $playReq->execute();
        }

        # D-04 backend dispatch (change handler): Soloist Connect dispatches
        # a new spoton://track:$newTrackId entry for EVERY track change.
        # D-05 makes the daemon's flush-disconnect itself the EOF, so the
        # forced-reconnect special-path below (librespot only, 82-05: the
        # Soloist-side flag it used to consume is retired) never applies to
        # Soloist. librespot 'change' handling stays byte-identical below
        # this block.
        {
            # 84-08: the per-track entry branch (connectEntry pertrack).
            if ((_liveCaps($client)->{connectEntry} // '') eq 'pertrack' && $newTrackId) {
                $client->pluginData(eventTrackUri => "spotify:track:$newTrackId");
                _fetchTrackMetadata($client, $newTrackId);

                if ($wantHold) {
                    # 84-17: no `playlist play` -- the deferred item is the
                    # NEXT playlist entry and LMS advances by itself.
                    _holdOpen($client, $newTrackId);
                    $log->warn("[DIAG] [$diagTs] change: player=" . $client->id
                        . " prev=" . ($prevTrackId || 'none')
                        . " new=" . ($newTrackId || 'none')
                        . " via=live hold=1 backend=soloist"
                        . " elapsed=" . sprintf('%.3f', Time::HiRes::time() - $diagTs)
                    ) if $diagMode;
                    return;
                }

                # Every Soloist 'change' dispatches a new playlist entry —
                # flush-disconnect (D-05) delivers the EOF for the previous
                # track; this playlist play starts the next one.
                my $changePlayUrl = "spoton://track:$newTrackId";
                $client->pluginData(connectSessionPaused => 0);
                $client->pluginData(connectStartTime => Time::HiRes::time());
                $client->pluginData(connectStreamDispatchTs => Time::HiRes::time());   # 84-02: _streamElapsedSeconds
                $client->pluginData(connectOwnPlayUri => $changePlayUrl);   # 84.2-05: one-shot dispatch marker (see _dispatchChangePlay)
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

        # 82-05: the 260827-of9 forced-reconnect block that used to sit
        # here (keyed off a since-retired per-daemon flag) is deleted --
        # RESEARCH confirmed it unreachable in every configuration (a
        # Soloist-backend player already `return`s above, in the D-04
        # dispatch block; for a librespot player, the flag's lookup always
        # returned undef, since the librespot helper never was the Soloist
        # backend's daemon class).

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
            _holdCancel($client, 'session_end');    # 84-17 (H-c)
            _settleCancel($client, 'session_end');  # 84.3-01
            if ($client->isPlaying && __PACKAGE__->isSpotifyConnect($client)) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Connect session ended (device inactive) - pausing " . $client->id
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
        # This is librespot's grace: its binary fires Stopped between TrackChanged
        # and Playing, which must not pause the LMS player. Time-based check only
        # (isPlaying is already true by the time the stop arrives because playlist
        # play was just issued). D-33 FULL-2 CR-01: Soloist's Control classifies
        # its own frames (stop only on a real paused/stopped), so on that role
        # (connectClaimGate 0) a stop inside the window is a genuine app pause.
        # No role known keeps the grace.
        my $needsStartGrace = $evBe ? ($evBe->capabilities->{connectClaimGate} ? 1 : 0) : 1;
        if ($needsStartGrace && (Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0)) < CONNECT_START_GRACE)
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

            # 84.3-01: the context-end snapshot is taken BEFORE the pause (KF-3).
            my $snap = _ctxEndSnapshot($client);

            $client->pluginData(connectPauseTs => Time::HiRes::time());
            my $pauseReq = Slim::Control::Request->new($client->id, ['pause', 1]);
            $pauseReq->source(__PACKAGE__);
            $pauseReq->execute();

            # 84.3-01 (D-01): did LMS honour the pause? If it discarded it while
            # rebuffering at a context end, settle with one source-marked stop.
            _settleCheck($client, $snap);
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
        _settleCancel($client, 'ready');    # 84.3-01
        main::INFOLOG && $log->is_info && $log->info(
            "Spirc reconnected (ready event) for " . $client->id . " - re-issuing Connect play"
        );

        # Only re-issue if this player was previously the active Connect player.
        # If not (e.g. another player took over), ignore.
        if ($_activeConnectPlayer && $_activeConnectPlayer eq $client->id) {
            # M11: do not force-start playback if the user paused — a Spirc
            # reconnect must not override the paused state.
            if ($client->isPaused()) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Spirc ready but player is paused - not forcing playback (M11)"
                );
                return;
            }
            $client->pluginData(connectStartTime => Time::HiRes::time());

            # D-04 backend dispatch: Soloist Connect uses spoton://track:ID
            # entries; librespot keeps the repeating-stream URL.
            my $readyPlayUrl;
            {
                # 84-08: capabilities->{readyReplaysLastTrack} -- the backend
                # re-enters with the last announced track as its own entry.
                if (_liveCaps($client)->{readyReplaysLastTrack}) {
                    # Derive trackId from eventTrackUri (last announced track)
                    my $readyTrackUri = $client->pluginData('eventTrackUri') || '';
                    if ($readyTrackUri =~ m{^spotify:(?:track|episode):([A-Za-z0-9]+)$}) {
                        $readyPlayUrl = "spoton://track:$1";
                        # 84.2-05 (producer P5): practically unreachable today, stamped anyway --
                        # a reach while the daemon is paused must not drop the session.
                        $client->pluginData(connectOwnPlayUri => $readyPlayUrl);
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
            "Session end: player " . $client->id . " was on before Connect - leaving on (GH #151)"
        );
        return;
    }

    my $song = $client->playingSong();
    my $url  = $song ? ($song->track->url || $song->streamUrl || '') : '';
    # Phase 78-04: also accept a Soloist Connect session (Control's own
    # mode) as "Connect stream" so GH-#151 power restore works at Soloist
    # session end. 83.1-07: replaces the former Soloist track-ID
    # URL-matching heuristic with Control's mode.
    # 84-08: the session mode comes from the backend role.
    require Plugins::SpotOn::Unified::DaemonManager;
    my $restorePowerMode = Plugins::SpotOn::Unified::DaemonManager->backendFor($client)->state->{mode};
    if ($client->isPlaying && $url !~ m{spoton://connect-}
        && ($restorePowerMode // '') ne 'connect') {
        main::INFOLOG && $log->is_info && $log->info(
            "Session end: " . $client->id . " is playing something else - skipping power-off (GH #151)"
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
# Fetches track metadata over spclient and updates NowPlaying display.
# Uses API::SpClient->getTrack() (D-08, 85-07 D-11): spclient is the only
# metadata source -- there is no Web API fallback, a network error is
# retried inside getTrack, and a failure here just resets the NowPlaying
# progress (this is NOT a sender of noteMetadataMissing; only the
# ProtocolHandler refetch classifies a real 404).
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
                "Stale API response: event=$eventUri, API=" . $trackInfo->{uri} . " - using event (T-05-14)"
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
            require Plugins::SpotOn::API::SpClient;   # 79-43 (D-33 FULL-3 CR-01): the format marker of spoton_meta records
            $cache->set(
                'spoton_meta_' . md5_hex($cacheUrl),
                {
                    _spoton_fmt => Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT(),
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
            "Track metadata updated: $title - $artist"
        );
        $log->warn("[DIAG] metadata_success: mac=" . $client->id . " track=$trackId title=$title duration=$duration") if $prefs->get('diagnosticMode');
    }, { refresh => 1 });   # 79-27 D-20: a Connect track start is fetched fresh (overwrites the cached entry)
}

sub _largestImage { Plugins::SpotOn::Plugin::_largestImage(@_) }

1;
