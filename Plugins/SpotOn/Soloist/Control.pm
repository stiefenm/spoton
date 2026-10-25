package Plugins::SpotOn::Soloist::Control;

# Phase 82 Plan 01 (Neuausrichtung §3.1-3.3, D-01/D-02): the single place
# that sends WS commands to the Soloist daemon and interprets its events for
# a given player -- deliberately NOT a second dispatcher next to Connect.pm
# (Prinzip 3.1(4): exactly one entry point). `wanted` (what LMS wants),
# `observed` (what the daemon last reported) and `pending` (the last sent
# command, for window-less echo classification) replace the seven flags
# (sessionActive, sessionStarted, sessionPaused, deactivating, skipInitiated,
# pendingPlayConfirm, soloistBrowseActive) that used to live spread across
# SoloistWS.pm/ProtocolHandler.pm/Connect.pm. `mode` (idle|browse|connect)
# is policy (Prinzip 3.1(3)), not implementation -- this plan implements
# only the `browse` column of the mode table; `connect` is Phase 83.

use strict;
use warnings;

use base qw(Slim::Utils::Accessor);

use Scalar::Util qw(blessed refaddr);
use Time::HiRes;
use IO::Socket::INET;
use Digest::MD5 qw(md5_hex);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

# IN-03 (82-REVIEW.md): these three were used throughout this module
# (Slim::Player::Client::getClient, Slim::Player::Source::playmode,
# Slim::Player::Playlist::song/count) without ever being `use`d --
# implicitly relying on the LMS core having already loaded them.  Always
# true in the running server, NOT guaranteed in isolated contexts
# (Scanner, tests) -- t/44's/t/45's harnesses already stub and load them
# explicitly before requiring this module; any OTHER test file that loads
# this module for real must do the same.
use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Player::Playlist;

# S-03 mismatch: track_changed 112/161/119 ms after trigger (n=3);
# client-attach p95 121 ms (n=30); Arm-TTL 3000 ms. >= 3x the slowest
# observed track_changed, well under the arm TTL -- MEDIUM confidence
# (track_changed latency itself is only n=3).
use constant T1_TRACK_CHANGED_MS => 500;

# RESEARCH reconcile table "Drift": on a mismatch that keeps recurring,
# re-_dispatch up to this many times per target before surfacing via
# errors[] instead of retrying silently forever.
use constant DRIFT_MAX_REDISPATCH => 2;

# 73-05 (D-06): 3 s Toleranz fuer App-Seek-Erkennung; nur mode=connect.
# Herkunft SoloistWS.pm:42 -- 1:1 uebernommen (82-03).
use constant SEEK_THRESHOLD => 3;

# 84-02 (cluster 4, D-21): a position report within this many ms of the prior
# anchor's own raw position, arriving after the rebased expectation moved on
# by more than SEEK_THRESHOLD, is the daemon's frozen report, not a seek.
use constant FROZEN_POSITION_TOLERANCE_MS => 500;

# 84-02 C4-c: how old (seconds) the last real position before a zero reset
# frame may be and still stand in for the transfer-in position.
use constant ENTRY_ANCHOR_MAX_AGE_S => 10;

# 84-14 (D-06 workaround for a daemon-side entry figure): a transfer-in whose
# daemon entry position differs from the position the app had at the transfer
# by more than this many ms is corrected with exactly ONE seek. Both figures
# are the daemon's own millisecond reports (the app position as the last real
# frame before the new-item reset), so the tolerance matches the 2 s `entry`
# machine gate, not the coarser app-bar read. ENTRY_MIN_TARGET_MS: never seek
# to (or near) 0 -- a target under 1 s is treated as unknown (82-24 lesson).
use constant ENTRY_TOLERANCE_MS  => 2000;
use constant ENTRY_MIN_TARGET_MS => 1000;

# Befund 3: LMS' Restart ist synchron und liegt im Sub-100-ms-Bereich; 2 s
# deckt _JumpPaused->Unpause NICHT ab -- dort ruft _JumpOrResume
# canDoAction/getSeekData ohnehin erneut (SC.pm:1605-1620).
use constant SEEK_INTENT_TTL => 2;

# 84-26 F-24-2 (defensive): an LMS re-open (requestTrack seek=1, same uri) within this many seconds of
# Control's own reactivation transfer-in resume is judged against the position THAT resume emitted
# (`observed.entryResume`). The primary repair is Connect.pm's jumpToTime (the re-open then already carries
# the daemon's figure); this marker keeps the daemon's position even if LMS still re-opens at a stale one.
use constant ENTRY_RESUME_WINDOW_S => 2;

# [ASSUMED -- A3] D-13: 8/8 Laengen < 200ms, Reserve >= 7x; zu kurz ->
# seekable=0 faelschlich, Gegenmassnahme: noteDuration darf seekable
# nachtraeglich auf 1 setzen (siehe noteDuration).
use constant T_META_MS => 1500;

# 85-07 D-09 (T-85-23): Up Next comes from the helper. A menu open reads the
# cache (observed.upNext) and asks the daemon for a fresh queue at most once
# per QUEUE_REQUEST_MIN_INTERVAL_S; UP_NEXT_MAX bounds the cache (T-85-24)
# and is also the `limit` of the get_queue command.
use constant QUEUE_REQUEST_MIN_INTERVAL_S => 5;
use constant UP_NEXT_MAX                  => 20;

# CON-11, aus Connect.pm:28 -- gilt jetzt in beiden Modi (82-05, Task 6):
# der Daemon startet mit `-i <client->volume>`, sein erstes volume_changed
# ist damit ohnehin ein Echo, egal ob Browse oder Connect.
use constant VOLUME_GRACE_PERIOD => 3;

# D-02/D-03; S-01 B: der Wachhund feuerte nach ~28s in 6/6 Laeufen und
# ueberschrieb das Daemon-Ergebnis, bevor es bei LMS ankam.
use constant WATCHDOG_ROUND_S => 10;

# 83.1-03 (D-A1/D-A3): connect's OWN watchdog budget -- NOT shared with
# WATCHDOG_ROUND_S. D-A1: rung 1 (watchdogRing) rescued 0/6 connect hangs
# (Messung D+E) -- Plugin.pm:4121 returns early for a connect session once
# isSpotifyConnect is true (plan 02), so watchdogRing is never even invoked
# there; rung 2 (this constant) rescued 6/6 after exactly 10.0s. D-A3
# (CONTEXT Nachtrag 2026-09-23, Plan-Check Runde 2, P2-B2, user decision):
# own constant, fires ONCE per incident, hands over to the plan-02 ladder
# (_connectResync) instead of re-arming itself -- "Musik zuerst retten
# statt stoppen, Wachhund feuert einmal". D-A4: the clock counts only while
# a re-open by LMS is actually possible (see _pauseConnectWatchdog).
use constant CONNECT_WATCHDOG_S => 10;

# 84-17 (L1 repair): the shim answers POST /boundary with its own
# classification of the title change (`via=live|departed|none`, see
# fake-libpulse.c _serve_boundary). In connect mode Control reads that reply
# (asynchronously, never blocking LMS' event loop) before it emits `change`;
# BOUNDARY_REPLY_CAP_S bounds the wait. The shim's HTTP thread answers within
# its poll tick, so the deferral is milliseconds; the cap is the worst case.
# BOUNDARY_PATH_DRAIN asks the shim to plant a LIVE boundary at the drained
# end of the old title (`?anchor=drain`, fake-libpulse.c) instead of 1.5-1.75 s
# inside the next one. 79-31 (D-26, STUTTER-SOLO): the browse natural-boundary
# posts ask for it too (_onFrameTrackChanged outside a Connect session,
# _maybeContextEnd, _onQueueHeadReplay -- the last two done in 79-38), because
# with `anchor=pushed` the old stream carried the first 1.75 s of the next title
# and the new stream restarted it at 0:00 (79-30 control run, `via=live
# anchor=pushed`). The Connect `change` keeps it (84-17). BOUNDARY_PATH_PLAIN
# stays for the Connect session start (V-j) and the skip/stop posts of
# _postBoundary (a skip is not a natural end). The shim keeps the old placement
# by itself when no live client exists or the ring did not drain within 2 s
# (fake-libpulse.c _serve_boundary), so the drain request cannot move a
# boundary later.
#
# 79 D-31 (79-37 shim, 79-38 Control): the shim holds the first bytes of a
# refill that follows a gap of >= 500 ms (the next title at a natural end) for
# up to 450 ms. The drain POST above consumes that hold (planted at the old
# title's end, `hold=consumed`), so nothing of the next title enters the old
# stream. Every transition into `playing` from paused or buffering on the
# SAME title posts /hold-release (_postHoldRelease via _noteHoldRelease), so a
# resume after a pause or a stall the daemon reports as `buffering` costs no
# hold time. A stall the daemon never reports as a state frame still waits up
# to the hold time (450 ms). Every natural end and every LMS-driven title
# start may also produce one harmless `hold_suppressed: window_ms=450` line, at
# a natural end a few ms after the drain POST (the release of the new title's
# buffering -> playing finds no hold left); at an LMS-driven start from a long
# pause it can instead be a `hold_released: reason=release` with a few ms held.
use constant BOUNDARY_REPLY_CAP_S  => 0.3;
use constant BOUNDARY_PATH_PLAIN   => '/boundary';
use constant BOUNDARY_PATH_DRAIN   => '/boundary?anchor=drain';

# 84.2-01 (CAUSE-3, D-07/IN-04): `observed.queuedByUs` is a SET
# { <spotify:track:uri> => <epoch> } of the titles SpotOn itself queued.
# OWN_QUEUE_MAX is only a leak guard -- the set is emptied on every loss of
# control (_forgetOwnQueue); past the cap the oldest entry is dropped.
use constant OWN_QUEUE_MAX => 16;

# 84.2-02 (D-15): the context-end carrier. A position frame at or below
# CONTEXT_END_RESET_MS with no speed is a reset to the title start; the
# title counts as ended when the anchor in force BEFORE that reset, carried
# forward along the daemon's own timestamp_ms, lies within
# CONTEXT_END_NEAR_MS of the known duration (off-1: 194143 + 11604 = 205747
# vs 205933; a user pause 5 s in stays far below the threshold).
use constant CONTEXT_END_RESET_MS => 1000;
use constant CONTEXT_END_NEAR_MS  => 10_000;

# 84-17 (L1 repair) -- the hold on a natural end. Defined ONCE here and
# referenced from Connect.pm (Plugins::SpotOn::Soloist::Control::HOLD_*), so
# both sides compute the same instants. Justification in
# 84-L1-ATTRIBUTION.md `## 84-17 hold design`:
#   HOLD_CAP_S      first moment Connect's safety timer looks at LMS's state:
#                   TAIL_MAX_S 37 + the STMd-to-STMs handoff (~10 s) + margin.
#                   Nothing WAITS for it (LMS advances by itself at the
#                   audible end); it only bounds a hold that never closes.
#   HOLD_RECHECK_S  cadence of the re-checks after the cap.
#   HOLD_MAX_S      3 x HOLD_CAP_S of accumulated PLAYING time on the old
#                   url: the hard ceiling after which `playlist play` fires
#                   (never out of a pause) and the record in observed->{hold}
#                   expires (_checkSplitBrain escalates again as today).
use constant HOLD_CAP_S     => 60;
use constant HOLD_RECHECK_S => 5;
use constant HOLD_MAX_S     => 180;

# 83.1-02 Task 2 (D-04/D-05): the split-brain ladder's shared attempt cap --
# the watchdog's single attempt (_connectResync('watchdog')) and
# _checkSplitBrain's own ticker-sighting attempts count against ONE shared
# counter (observed->{splitBrain}{attempts}, CONTEXT D-A3 Nachtrag P2-B2).
# After this many failed nachziehen attempts, D-05's Notausgang (daemon
# pause) fires instead of another re-open try. "zweimal nicht" (D-05).
use constant SPLIT_BRAIN_MAX_ATTEMPTS => 2;

# 82-08 CR-01: Toleranz fuer den Positionsvergleich im Treffer-Zweig
# (_reconcile Schritt 4). Deckt Anker-Alter (der letzte position_sync/
# playback_state-Schnappschuss ist nie exakt "jetzt") und Netzlaufzeit
# zwischen Control und Daemon ab -- darunter ist ein zusaetzliches `seek`
# teurer als der Fehler, den es korrigiert. Live dreimal reproduziert ohne
# diesen Vergleich: 19431/81235/200708 ms Restposition statt der
# angeforderten 0 (82-REVIEW.md CR-01).
use constant HIT_POSITION_TOLERANCE_MS => 1500;

# 82-16 F1 (H-v bestaetigt, 82-G1-MESSUNG.md): deckt das Fenster zwischen
# zwei requestTrack-Aufrufen DESSELBEN synchronen LMS-Kommandos (gemessen
# 2,4 ms, server.log 18:50:17.3977 -> .4022) und die Zeit bis zum naechsten
# position_sync nach dem Flush (S-03: unter 5 ms nach dem Flush, Flush
# 23-71 ms nach dem Trigger) -- eine Sekunde ist Reserve, keine Toleranz.
use constant SEEK_ISSUED_WINDOW_S => 1;

# 82-11 CR-03: a daemon that reports 'requires authentication' is
# re-probed with `get_auth_state` on this cadence instead of waiting on a
# spontaneous push after login -- no fixture proves the daemon sends one
# unprompted.
use constant AUTH_REPROBE_S => 5;

# 82-11 CR-03: bounded re-probe -- a daemon that stays unpaired forever
# must not generate an endless command stream; after this many attempts
# the state becomes visible via errors[] instead (Task 2) and the
# re-probe stops.
use constant AUTH_REPROBE_MAX => 3;

# 82-11 (Todo errors-startup-falschmeldung-nicht-paired): a daemon younger
# than this many seconds gets its first 'unpaired' report suppressed in
# errors[] -- the daemon is still restoring its session in this window
# (measured live: 7-10 s after LMS start), and a transient startup state
# reported as a durable error is indistinguishable from a real (g)-finding.
use constant UNPAIRED_GRACE_S => 15;

# 82-12 WR-01 (82-REVIEW.md): T1_TRACK_CHANGED_MS is derived from a
# 3-sample distribution (S-03: 112/119/161ms) -- a track_changed echo that
# misses that window under load or after a reconnect is not implausible.
# This window covers the gap between T1's timeout and a plausible late
# echo without staying open indefinitely (Fall C: the window DOES expire).
use constant LATE_ECHO_WINDOW_S => 3;

# Debug session inaktiver-player-steuert-fern (user decision A, 2026-09-25):
# how long a KNOWN-inactive Control waits for the daemon to confirm its own
# take-over (`activate` -> device_changed is_active:true) before the
# requested title fails visibly. Measured 2026-09-25 on the rig: +884 ms
# (M1) and +621 ms (M2) with another device active and playing, +1 ms with
# no device active (M5) -- n=3, reserve >= 5x the slowest.
use constant TAKEOVER_TIMEOUT_S => 5;

# 82-42 Task C (get-state-statt-play.md, T-3 AND-gate Richtung (i)): TTL for
# a deferred requestTrack (_reconcile Schritt 1, trigger='requestTrack',
# wsConnected still false). Bauform per 82-42-PLAN.md Task B checkpoint
# answer "q4-trigger-paired:25" -- the retry hook fires on the auth_state
# branch's `paired=1`/logged_in:true (Control.pm ~2086ff, actual login
# completion), NOT on the bare wsConnected handshake alone (Task A's third
# finding: the daemon's `_transport open` pseudoframe sets wsConnected=1
# for EVERY event, strictly BEFORE any login answer -- Runde 2 Warning 1,
# a hook tied to the handshake burns its one retry shot against a
# not-yet-logged-in daemon). Retry latency is therefore login duration
# PLUS up to one _authProbe tick (AUTH_REPROBE_S=5, +5/+10/+15s after the
# daemon's own unprompted logged_in:false push, Control.pm ~2122-2129) --
# and the TTL clock itself starts at requestTrack, i.e. BEFORE the
# handshake, so the requestTrack->handshake span (unmeasured in this
# project -- get-state-statt-play.md "Handschlag-vor-Login": SoloistWS.pm's
# successful handshake writes no server.log line) is additional reserve
# on top. Plan-derived reasoned lower bound: 15s (worst-case probe tick,
# +5/+10/+15 grid) + <=6.7s (82-18-SUMMARY.md:199 "zweiter Respawn loggte
# sich binnen 6,7s ein" -- an UPPER bound for the requestTrack->handshake
# reserve, n=1, not a direct measurement of that span alone) = 21.7s
# upper-bound need. The checkpoint answer chose 25s over the plan's own
# floor of 20s to clear that 21.7s bound with margin -- 25 is a REASONED
# value, not a measured one.
#
# Phase 82 Plan 44 (D-12, Runde 44): superseded by ONE 20s budget shared
# across ProtocolHandler -> DaemonManager -> SoloistDaemon -> Control
# (Plugins::SpotOn::Unified::DeferBudget::TOTAL_DEFER_BUDGET_S) instead of
# staggering independent per-level TTLs (this one plus
# SoloistDaemon::PENDING_TRACK_TTL_S could add up to 50s/75s). Kept as a
# delegating sub (not a plain re-export) so every existing bareword call
# site (e.g. Control.pm:1552's "... . WS_RETRY_TTL_S . ...") keeps working
# unchanged -- the empty prototype `()` is required for that.
sub WS_RETRY_TTL_S () {
    require Plugins::SpotOn::Unified::DeferBudget;
    return Plugins::SpotOn::Unified::DeferBudget::TOTAL_DEFER_BUDGET_S();
}

# 83.1-01 (D-01/D-02): _timerRegistry backs _execute's snapshot/rollback --
# a shadow of the deadline/args of every timer THIS module currently has
# armed, keyed by refaddr(cb) (Slim::Utils::Timers itself offers no "peek
# the deadline for this timer" query). Maintained only by _execute's
# 'timer'/'killtimer' intent handling; not touched anywhere else.
__PACKAGE__->mk_accessor( rw => qw( mac mode wanted observed pending _generation _driftCount _awaitMeta _authProbeCount _lastAuthProbeAt _deferredTrackRequest _shutDown _timerRegistry _restartAllowance _takeover _lastQueueRequestAt ) );
__PACKAGE__->mk_accessor( weak => qw( daemon ) );

my $prefs = preferences('plugin.spoton');
my $log   = logger('plugin.spoton');

# Per-player registry, keyed by master MAC (Analog C: DaemonManager's
# %helperInstances / for_client($clientOrMac) form).
my %_byMac;

# _normalizeUri($url) -- shared by requestTrack/noteSeekIntent/
# consumeSeekIntent/seekable/noteDuration/noteMetadataMissing. Accepts
# either the spoton:// form LMS uses or an already-normalized spotify: uri;
# returns undef on anything else (T-22-01: only [A-Za-z0-9]+ ids pass).
sub _normalizeUri {
    my ($url) = @_;
    my ($type, $id) = ($url // '') =~ m{^(?:spoton://|spotify:)(track|episode):([A-Za-z0-9]+)$};
    return undef unless defined $id;
    return "spotify:$type:$id";
}

# _lmsCurrentUrl($self) -- the url of the song LMS would unpause right now
# (playingSong, else streamingSong), or undef when it cannot be known (no
# client, no song, no such accessor). 84-01: lets the transfer-in tell a
# session that can be reactivated (LMS still holds its track) from a marker
# that outlived its session.
sub _lmsCurrentUrl {
    my $self = shift;

    my $client = eval { Slim::Player::Client::getClient($self->mac) } or return undef;
    my $song = eval {
        ($client->can('playingSong') ? $client->playingSong : undef)
            || ($client->can('streamingSong') ? $client->streamingSong : undef)
    } or return undef;
    my $track = eval { $song->track } or return undef;
    return eval { $track->url } // '';
}

# _lmsSongIsOurs($self) -- CR-04 (82-REVIEW.md): does LMS' CURRENT song
# belong to us AT ALL? This is deliberately NOT the (83.1-07: removed)
# Connect claim-gating check, which additionally required the LMS url to
# match the SPECIFIC track the daemon currently reports (used to gate the
# Connect claim, now asked directly via `mode eq 'connect'`); this only
# asks whether LMS is on ANY spoton:// track/episode url. Used as the
# ownership guard in requestPause/requestResume/requestVolume -- without
# it, a local file or Radio playing on LMS still forwarded pause/resume/
# volume to the Spotify account session running at the daemon (the
# retired `_soloistBrowseWs` enforced this; the mode-based rewrite dropped
# it).
sub _lmsSongIsOurs {
    my $self = shift;

    my $client = Slim::Player::Client::getClient($self->mac) or return 0;
    my $song = $client->streamingSong || $client->playingSong or return 0;
    my $url = $song->track ? ($song->track->url // '') : '';
    return $url =~ m{^spoton://(?:track|episode):[A-Za-z0-9]+$} ? 1 : 0;
}

# _resumeTargetsOurTitle($self, $wanted, $observed) -- 84-26 R1 (F-24-1).
# 1 when a bare daemon `play` resumes OUR title, 0 when it would resume a
# title we did not ask for. Browse mode only (R1_CONNECT_ROW=marker_only):
#   - the daemon sits on a title other than wanted.uri (our title is over at
#     the daemon, e.g. the ended title's autoplay successor), or
#   - the daemon sits on the title the autoplay guard (or its replay sibling)
#     paused (`observed.autoplayPaused` -- written in Task 2 (R2); a seeded
#     marker is honoured here already), or
#   - 84.2-05 (B7, D-15): the daemon sits on the title whose context end
#     SpotOn planted (`observed.contextEndPlanted eq observed.track`) -- a
#     bare play would resume the wrapped title from 0:00.
# An undefined observed.track ("no track_changed seen on this WS yet") keeps
# the bare play: "no title observed" is not "a different title".
# In connect mode the predicate is always 1: wanted.uri does NOT follow
# observed.track there (wanted({...}) is written only by requestTrack, the
# idle adoption and the transfer-in; Connect.pm's 84-17 hold issues no
# `playlist play` for a phone-side title change, so wanted.uri lags for the
# whole deferred tail) -- a uri clause would refuse a genuine unpause; and an
# adopted Connect session on the autoplay-paused title is legitimate (D-02),
# so a stale marker must never refuse there.
sub _resumeTargetsOurTitle {
    my ($self, $wanted, $observed) = @_;

    return 1 unless $self->mode eq 'browse';
    my $track = $observed->{track};
    return 1 unless defined $track;

    return 0 if defined $wanted->{uri} && $track ne $wanted->{uri};
    return 0 if defined $observed->{autoplayPaused} && $observed->{autoplayPaused} eq $track;
    # 84.2-05 (B7, D-15): the daemon sits on the title whose context end SpotOn
    # planted in this play generation. The marker is written only by
    # _maybeContextEnd in the paused-at-<=CONTEXT_END_RESET_MS state and cleared
    # by every requestTrack and leaveBrowse, so it IS the "paused near 0 after
    # its own end" fact -- no second position read (a position_sync could race
    # it). LMS's _Rebuffer/_Resume unpause at the planted boundary
    # (StreamingController.pm:1652, forwarded by Connect.pm _onPause) is
    # indistinguishable from a user unpause and must be refused here -- same
    # shape as 84-26 R1.
    return 0 if defined $observed->{contextEndPlanted} && $observed->{contextEndPlanted} eq $track;
    return 1;
}

# _clearAutoplayPausedUnless($self, $uri) -- 84-26 R2 (F-24-1). The autoplay
# marker `observed.autoplayPaused` (written by the guard and its replay sibling
# when they pause) names ONE uri; every write of `observed.track` calls this with
# the uri it writes, and a marker naming a DIFFERENT uri dies (the daemon moved
# on: the paused title is no longer the one it sits on). A marker naming the
# SAME uri survives -- the guard sets it just before its own track write.
sub _clearAutoplayPausedUnless {
    my ($self, $uri) = @_;
    my $ap = $self->observed->{autoplayPaused};
    delete $self->observed->{autoplayPaused} if defined $ap && (!defined $uri || $ap ne $uri);
    return;
}

# _isKnownInactive($observed) / _knownInactive($self) -- debug session
# inaktiver-player-steuert-fern (user decision A, 2026-09-25). All players
# share ONE Spotify account, and every daemon executes a state-changing
# command of a device that is NOT the account's active device as Connect
# REMOTE control against the active one, acking it with the same plain
# command_result as a local command (measured 2026-09-24 23:35:58 seek +
# resume, 23:37:09 play -> track change, 23:36:54 pause -- all executed on
# lavender-UAT2 for an inactive lavender-UAT). The daemon's own is_active
# flag (auth_state/playback_state/device_changed) is the only discriminator
# Control has. "Known" inactive = the daemon SAID so (defined and 0); an
# undefined flag (fresh Control, no frame yet) is unknown and keeps today's
# behaviour -- the first auth_state after every WS connect defines it.
sub _isKnownInactive {
    my ($observed) = @_;
    my $a = $observed ? $observed->{is_active} : undef;
    return (defined $a && !$a) ? 1 : 0;
}

sub _knownInactive {
    my $self = shift;
    return _isKnownInactive($self->observed);
}

# _sendableWhileInactive($cmd) -- the commands a known-inactive Control may
# still put on the wire: the read-only queries and the take-over itself
# (`activate`/`deactivate` act on THIS device only, docs table "Become /
# Release active device"). Everything else would steer the active device.
my %SENDABLE_WHILE_INACTIVE = map { $_ => 1 } qw(get_state get_auth_state get_queue activate deactivate);
sub _sendableWhileInactive {
    my ($cmd) = @_;
    return (defined $cmd && $SENDABLE_WHILE_INACTIVE{$cmd}) ? 1 : 0;
}

# leaveBrowse($self) -- CR-04: the missing `browse` -> `idle` path. Resets
# `mode` and `wanted` to a fresh state and sends NO command -- the
# re-entry point is ALWAYS requestTrack (Prinzip 3.1(4)); a command sent
# from here would be a second entry point. Clearing `wanted` to an empty
# hash is deliberate beyond `mode`: it makes wanted->{playing} undefined
# again, so the H6-Ersatz volume push (D-06) re-arms cleanly the next time
# `browse` is entered, exactly as if this were a fresh Control.
sub leaveBrowse {
    my $self = shift;

    $self->_dropPendingChange('leaveBrowse');
    delete $self->observed->{hold};
    $self->_forgetOwnQueue('leaveBrowse');
    delete $self->observed->{prefetchWish};    # 84.2-02: a wish never survives a loss of control
    # 84.2-05 (B7): LMS left a title whose context end SpotOn planted -- if the
    # daemon is found playing it after this leave while LMS is on foreign
    # content, that is NOT a phone-side Connect start (_holdAfterForeignLeave).
    $self->observed->{leftBrowsePlanted} = $self->observed->{contextEndPlanted} if defined $self->observed->{contextEndPlanted};
    delete $self->observed->{contextEndPlanted};
    delete $self->observed->{preResetAnchor};
    $self->mode('idle');
    $self->wanted({});
}

# _forgetOwnQueue($self, $why) -- 84.2-01 (CAUSE-3, D-04): SpotOn forgets
# that any queued title is its own on EVERY loss of control. Called from
# leaveBrowse (covers the LMS stop-leave, the non-spoton pause/stop, the
# Connect.pm CR-04 source switch and the session loss to another device)
# and from both entries into connect (the browse->connect transfer-in in
# _onFrameDeviceChanged, the idle->connect reconnect in
# _onFramePlaybackState). NEVER on a mere pause (a pause is not a loss of
# control) and never from queue_changed (it can race the track_changed that
# consumes the entry, 84-19 ordering note). Only forgets -- the entry stays
# in the account queue (D-05: no queue-removal code); if the daemon reaches
# it later, the autoplay guard pauses it as foreign (B7 07:48: 6d0c).
sub _forgetOwnQueue {
    my ($self, $why) = @_;
    my $q = $self->observed->{queuedByUs};
    return unless ref($q) eq 'HASH' && %$q;
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Control: forgetting own queue entries (" . join(',', sort keys %$q) . ") -- "
        . ($why // '?') . " (" . ($self->mac // '?') . ")"
    );
    $self->observed->{queuedByUs} = {};
    return;
}

sub new {
    my ($class, %args) = @_;

    my $self = $class->SUPER::new();

    $self->daemon($args{daemon});    # 'weak' accessor -- daemon owns Control, not vice versa
    $self->mac($args{mac});
    $self->mode('idle');
    $self->wanted({});
    $self->observed({ wsConnected => 0, meta => {} });
    $self->pending(undef);
    $self->_generation(0);
    $self->_driftCount({});
    $self->_awaitMeta(undef);
    $self->_timerRegistry({});

    $_byMac{ $self->mac } = $self if defined $self->mac;

    return $self;
}

# for_client($class, $clientOrMac) -- accepts either a client object or a
# bare MAC string, normalizes to the sync master (Connect.pm:100-101
# convention), returns the registered Control instance or undef (no daemon
# for this player / player is on the librespot backend).
sub for_client {
    my ($class, $clientOrMac) = @_;
    return undef unless defined $clientOrMac;

    my $mac = $clientOrMac;
    if (blessed($clientOrMac)) {
        my $client = $clientOrMac;
        $client = $client->master if $client->can('master');
        $mac = $client->id;
    }

    return $_byMac{$mac};
}

# shutdown($self) -- teardown counterpart to new(); called from
# SoloistDaemon::stop() before the WS itself disconnects. Any command still
# in flight is released with an error rather than left to hang forever.
sub shutdown {
    my $self = shift;

    # CR-01 (82-REVIEW.md Zeile 50-88, 82-VERIFICATION.md gaps[0]): the
    # registry deregistration AND the shutdown marker run FIRST, before any
    # timer kill and before all three callback-firing releases below
    # (pending, _releaseDeferredTrackRequest, _releaseAwaitMeta). LMS' own
    # _nextTrackError can reenter synchronously via Control->for_client from
    # inside one of those errorCb calls -- once $_byMac no longer resolves
    # to this instance and _shutDown is set, requestTrack's own guard (see
    # below) rejects that reentrant call immediately instead of arming a
    # new deferral/timer on an instance that is already mid-teardown.
    # wr04 (83.1-02 Task 3): mark this instance as a PLANNED stop before the
    # `_transport closed` pseudo-frame arrives -- `_transportClosed`'s ring
    # write is gated on this flag so an orderly teardown (sync-group stop,
    # backend switch, LMS shutdown) never reports a transport LOSS.
    $self->observed->{shutdown} = 1;

    delete $_byMac{ $self->mac } if defined $self->mac;
    $self->_shutDown(1);

    # 84-17: an unresolved boundary-reply wait does not outlive the instance
    # (no emission -- the session this change belonged to is gone).
    $self->_dropPendingChange('shutdown');
    delete $self->observed->{hold};

    Slim::Utils::Timers::killTimers($self, \&_t1Fire);
    Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
    # 82-11 CR-03: same discipline as WR-02/WR-03 -- no timer outlives a
    # torn-down Control.
    Slim::Utils::Timers::killTimers($self, \&_authProbe);
    $self->_authProbeCount(undef);

    if (my $pending = $self->pending) {
        $self->_fireCbs($pending->{cb}, 'errorCb', 'PROBLEM_OPENING', 'Soloist control shut down');
    }
    $self->pending(undef);

    # WR-03 (82-REVIEW.md): same discipline as the pending release just
    # above -- a deferred requestTrack must not outlive a torn-down
    # Control instance either. Shares _releaseDeferredTrackRequest with
    # _transportClosed (promote instead of add-alongside, 82-45
    # convention) instead of a fifth inline copy of the same release.
    $self->_releaseDeferredTrackRequest('Soloist control shut down');
    # inaktiver-player-steuert-fern: a take-over in flight does not outlive
    # the instance either (no errors[] entry -- a planned stop, not a loss).
    $self->_releaseTakeover('Soloist control shut down', 0);

    # WR-01 (82-REVIEW.md): same discipline as the T1/watchdog/authProbe
    # timers just above -- a late-echo expectation must not outlive the
    # instance that recorded it.
    delete $self->observed->{expectEcho};
    # 82-16 F1: same discipline -- a torn-down instance must not suppress a
    # future seek on behalf of a send it never actually completed.
    delete $self->observed->{seekIssued};

    $self->_releaseAwaitMeta('Soloist control shut down');
}

# _releaseDeferredTrackRequest($self, $reason) -- WR-03 (82-REVIEW.md):
# the single named release path for _deferredTrackRequest/_wsRetryTimeout
# (promote instead of add-alongside, same convention as 82-45's
# _handOffPendingTrackRequest/_releasePendingTrackRequest in
# DaemonManager.pm). Kills the TTL timer, clears the field, and fires
# errorCb with a caller-supplied, level-distinguishing $reason -- shutdown
# and _transportClosed are both bare callers of this one sub, so a future
# third terminal-release caller inherits symmetry by construction instead
# of writing its own inline copy.
sub _releaseDeferredTrackRequest {
    my ($self, $reason) = @_;

    if (my $deferred = $self->_deferredTrackRequest) {
        Slim::Utils::Timers::killTimers($self, \&_wsRetryTimeout);
        $self->_deferredTrackRequest(undef);
        $self->_fireCbs($deferred->{opts}, 'errorCb', 'PROBLEM_OPENING', $reason);
    }
}

# requestTrack($self, $url, $position_ms, $opts) -- the ONLY entry point for
# a track/position change from LMS (Prinzip 3.1(4); getNextTrack, and from
# 82-04 onStream, both funnel here). $url accepts either the spoton:// form
# LMS uses or an already-normalized spotify: uri. $opts = { successCb,
# errorCb, source => 'getNextTrack'|'onStream', seek => 0|1 }.
sub requestTrack {
    my ($self, $url, $position_ms, $opts) = @_;
    $opts ||= {};
    my $errorCb = $opts->{errorCb};

    # CR-01 (82-REVIEW.md Zeile 50-88, 82-VERIFICATION.md gaps[0]): a call
    # that arrives during/after shutdown() -- most concretely a synchronous
    # reentrant call from an errorCb that shutdown() itself just fired (all
    # three of pending/_releaseDeferredTrackRequest/_releaseAwaitMeta can
    # trigger this) -- must be rejected immediately, before any of wanted/
    # observed/seekIntent is mutated, instead of arming a NEW deferral/
    # timer on an instance that is already mid-teardown.
    if ($self->_shutDown) {
        $errorCb->('PROBLEM_OPENING', 'Soloist control shut down') if $errorCb;
        return 0;
    }

    # Captured BEFORE any mode mutation below -- the H6-Ersatz (D-06, Task
    # 6) fires on the idle/connect -> browse TRANSITION, not on every call.
    my $prevMode = $self->mode;

    my $uri = _normalizeUri($url);
    unless (defined $uri) {
        $errorCb->('PROBLEM_OPENING', 'invalid uri') if $errorCb;
        return 0;
    }

    # 84.1 D-01(b): any requestTrack call is a re-entry into browse/connect
    # -- the stop-triggered leave's autoplay-guard marker no longer applies
    # once we are being asked to play something (own owner, this task end
    # to end).
    delete $self->observed->{leftBrowseUri}; delete $self->observed->{leftConnectForeign};
    delete $self->observed->{leftBrowsePlanted};    # 84.2-05: same clear point as its siblings
    # 84-26 R2 clear (a): a new own play intent re-targets the daemon -- the autoplay
    # guard's marker (any uri) no longer applies.
    delete $self->observed->{autoplayPaused};
    # 84.2-02 (D-15): every requestTrack is a new play generation -- also the
    # SAME uri (LMS repeat-one re-requests the title at its wrap), whose next
    # context end must plant again. The plant-once guard only holds within
    # one generation. Deliberately outside the prevWantedUri block below.
    # 84.2-REVIEW WR-01: the same new-generation rule holds for the round-2
    # timer. watchdogRing (c)-planted arms round 2 for the planted uri; a
    # same-uri re-request (repeat-one wrap) does not pass the prevWantedUri
    # kill below, so without this round 2 fired `playlist jump +1` ~10 s
    # into the replay. Only when a plant for THIS uri was in force -- every
    # other same-uri re-request keeps its round 2 (existing semantics).
    if (defined $self->observed->{contextEndPlanted} && $self->observed->{contextEndPlanted} eq $uri) {
        Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
        delete $self->observed->{watchdogReason};
    }
    delete $self->observed->{contextEndPlanted};
    delete $self->observed->{preResetAnchor};

    # Befund 3 (d): a seek-intent marker left over for a DIFFERENT uri
    # (Open-Fehler -> _NextIfMore -> getNextTrack for the NEXT title; or any
    # other non-restart caller, Befund 3 (a)/(b)) must not survive onto the
    # uri this call is now requesting -- explicit clear, on top of
    # consumeSeekIntent's own uri check.
    if (my $marker = $self->wanted->{seekIntent}) {
        delete $self->wanted->{seekIntent} if !defined $marker->{uri} || $marker->{uri} ne $uri;
    }
    my $keptSeekIntent = $self->wanted->{seekIntent};

    # T-9 Kante 2: a NEW uri (LMS moved on -- naturally, or via the
    # watchdog's own round-2 skip) invalidates any still-armed round-2
    # timer for the OLD target; watchdogRing's own uri guard would already
    # no-op it, but killing it here is the explicit contract (D-02/D-03).
    my $prevWantedUri = $self->wanted->{uri};
    if (!defined $prevWantedUri || $prevWantedUri ne $uri) {
        Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
        delete $self->observed->{watchdogReason};

        # WR-01 (82-REVIEW.md): a new target uri invalidates any still-open
        # late-echo expectation for the OLD one -- the same "state is
        # already invalid" discipline as the watchdogRound2 kill just
        # above (a marker that outlives what it was waiting for is the
        # same class of bug as WR-03).
        delete $self->observed->{expectEcho};
        # 82-28 (WR-02, Review Runde 3): the uri now being requested is by
        # definition no longer "unrequested" -- clear any autoplay:<uri>
        # ring entry the foreign-track branch may have written for it
        # earlier. This is the normal-case clear path; the late-echo
        # branch's own clear (below in onEvent) only fires after a T1
        # timeout, which the realistic resolutions (Schritt 4 hit,
        # pending-echo) never reach. Covers both the hit and mismatch
        # paths alike -- this block runs for any new uri, not just a
        # confirmed match.
        $self->_clearErrorOnce('autoplay:' . $uri);
        # 82-16 F1: same discipline -- a seek issued for the OLD uri must
        # not suppress a correction the NEW uri legitimately needs.
        delete $self->observed->{seekIssued};
        # 84.2-02: a prefetch wish raised for the OLD title does not carry
        # over (the Treffer below raises a fresh one when it applies).
        delete $self->observed->{prefetchWish};
    }

    $self->mode('browse') if $self->mode eq 'idle';

    # The heutige `wasConnect`-Fall (ProtocolHandler.pm:833-836, pre-82-01):
    # getNextTrack asking for a DIFFERENT track than the daemon currently
    # reports while still nominally in connect mode means LMS has taken
    # over the session -- the connect POLICY itself (mode=connect column)
    # is Phase 83; this plan only recognizes the handoff.
    if ($self->mode eq 'connect' && ($opts->{source} // '') eq 'getNextTrack'
        && (!defined $self->observed->{track} || $self->observed->{track} ne $uri))
    {
        $self->mode('browse');
    }
    elsif ($self->mode eq 'connect' && ($opts->{source} // '') eq 'getNextTrack'
        && defined $self->observed->{track} && $self->observed->{track} eq $uri)
    {
        # 84.2-05 (debug b6-prefetch-b7-africa-replay; producer table P1-P14 and
        # stay-signal lifetime table in 84.2-05-PLAN.md): the uri test alone
        # could not tell Connect's own re-open from a user's play of the
        # daemon's current title (B6, 2026-10-09 21:50: H3's transfer-in left a
        # DORMANT session -- claim bound, daemon paused on its title at 0:00,
        # LMS stopped -- and title 1 was exactly that title, so every 84.2-02
        # mechanism stayed gated off). Two positive signals can, each live:
        #   (a) `origin => 'connect'`: Connect.pm's one-shot dispatch marker
        #       (stamped at its own `playlist play` sites and in _holdOpen;
        #       consumed by the next getNextTrack of that client, cleared by
        #       _holdClose while unconsumed and by releaseConnectClaim);
        #   (d) observed.status playing/buffering: the daemon is actively on
        #       this title (written by every daemon frame, deleted with the
        #       transport in _transportClosed).
        # Either keeps the 83.1-03 D-A1/D-A3 re-open: LMS confirmed it, cancel
        # the connect watchdog clock, mode stays connect. That is the safe
        # default for an ACTIVE session (P6 the hold's advance via the
        # _holdOpen stamp, P8 a re-open of a playing title). An LMS-UI seek
        # never reaches this branch (P7: it re-streams through onStream), and
        # a seekdata Play event on a dormant title hands over like P12 (P14).
        # Neither signal -- an unmarked LMS play while the daemon is dormant
        # (paused/stopped/idle) on the title (P12) -- hands over to browse:
        # LMS owns the playlist, D-A1/D-A3 describe Connect's OWN re-open only.
        # Status vocabulary: playing/buffering active; paused/stopped/idle
        # dormant; an undefined status reads as not dormant (safe default).
        # Neither the 84-17 hold record (it can outlive the LMS-side hold) nor
        # seekdata is read. Never here for the branch above (a DIFFERENT uri
        # means LMS took over, not a re-open).
        my $marked  = (($opts->{origin} // 'lms') eq 'connect') ? 1 : 0;
        my $st      = $self->observed->{status} // '';
        my $dormant = ($st eq 'paused' || $st eq 'stopped' || $st eq 'idle') ? 1 : 0;
        if ($marked || !$dormant) {
            $self->_cancelConnectWatchdog;
        }
        else {
            main::INFOLOG && $log->is_info && $log->info(
                "Control: LMS opened the daemon's current title $uri in a dormant Connect session (status=$st, no Connect dispatch marker) -- handing over to browse ("
                . ($self->mac // '?') . ")"
            );
            # a no-op when none is armed; a watchdog a dormant session's
            # _emitStart armed must not survive into browse
            $self->_cancelConnectWatchdog;
            $self->mode('browse');
        }
    }

    my $posMs = $position_ms // 0;

    # 84-26 F-24-2 (defensive): the one-shot marker the reactivation transfer-in resume left. Consumed on
    # first read (whatever this call is); acts only for the SAME uri, a seek re-open (seek=1) in connect,
    # within ENTRY_RESUME_WINDOW_S. The comparison and the substitute are the marker's OWN position_ms --
    # what Control EMITTED in that resume, the 84-14 entryFixMs included -- NEVER `_observedPositionMs` /
    # `observed.anchor`: the 84-14 entry fix rewrites only a LOCAL anchor copy and `observed.anchor` keeps
    # the daemon's reset (~0), so substituting it would seek the daemon back to ~0, the 84-14 defect itself.
    # The seek flag is KEPT and the TARGET substituted: the connect seek row then dispatches `seek <own>`
    # and the daemon's seek echo (Connect.pm seek branch) rewrites the new song's startOffset -- this path
    # depends on that echo for LMS's clock. Never a `play`.
    if (my $er = delete $self->observed->{entryResume}) {
        if ($opts->{seek} && $self->mode eq 'connect' && defined $er->{uri} && $er->{uri} eq $uri
            && (Time::HiRes::time() - ($er->{hr} // 0)) <= ENTRY_RESUME_WINDOW_S)
        {
            my $own = $er->{position_ms};
            if (defined $own && $own >= ENTRY_MIN_TARGET_MS && abs($posMs - $own) > HIT_POSITION_TOLERANCE_MS) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: LMS re-open after transfer-in at $posMs ms differs from the position Control emitted $own ms -- following the emitted position ("
                    . ($self->mac // '?') . ")"
                );
                $posMs = int($own);
            }
        }
    }

    # 82-24 CR-04: mode=connect -- LMS follows the daemon, it does not
    # correct it. The uri equality is mandatory (Plan-Check B1) -- without
    # it an onStream for a DIFFERENT track would carry the OLD track's
    # position into _reconcile Schritt 5's mismatch dispatch. int() is a
    # rounding decision (Plan-Check B2): _observedPositionMs returns a float,
    # the wire and Schritt 3 compare integer milliseconds (== on
    # position_ms). It does not make two calls equal when they are more
    # than one millisecond apart (live about 3 ms); such a second call
    # stays off the wire through the hit path (the daemon already plays the
    # target and the observed position lies within
    # HIT_POSITION_TOLERANCE_MS), see t/soloist/44 "R2-CR04 Fall H gap"
    # (TD-36).
    if ($self->mode eq 'connect' && !$opts->{seek}
        && defined $self->observed->{track} && $self->observed->{track} eq $uri)
    {
        my $obsMs = $self->_observedPositionMs;
        $posMs = int($obsMs) if defined $obsMs;
    }

    $self->wanted({
        uri         => $uri,
        position_ms => $posMs,
        playing     => 1,
        volume      => $self->wanted->{volume},
        (defined $keptSeekIntent ? (seekIntent => $keptSeekIntent) : ()),
    });

    # Befund 2 / D-04: the caller (getNextTrack, or onStream via
    # _applyRuntimeMetadata) may already know the track's length -- note it
    # BEFORE _reconcile decides whether to await metadata, so a known
    # length never triggers a T_meta wait.
    if (defined $opts->{duration} && $opts->{duration} > 0) {
        $self->noteDuration($uri, $opts->{duration});
    }

    # F-20-LATCH (84-21, D-24; todo browse-drift-sperre-titel-bis-lms-neustart):
    # _driftCount is per uri and was only cleared by a track_changed echo of
    # that uri -- after one failed Browse start every later `playlist play` of
    # the title failed within ~1 ms until LMS restarted. A NEW LMS play intent
    # (source => 'getNextTrack') is a fresh start of the title: clear the
    # count and its errors[] entry (the pair of the echo branch below). NOT on
    # source => 'onStream' (the second half of the SAME intent,
    # ProtocolHandler.pm), NOT on calls without a source, NOT in the deferred
    # `_reconcile` re-runs -- the limit must still bite inside one intent. The
    # loop stays bounded by LMS (StreamingController consecutiveErrors).
    if (($opts->{source} // '') eq 'getNextTrack') {
        delete $self->_driftCount->{$uri};
        $self->_clearErrorOnce('drift:' . $uri);
    }

    my $result = $self->_reconcile('requestTrack', $opts);

    # D-06 H6-Ersatz (Task 6): entering `browse` from `idle`/`connect` pushes
    # LMS' CURRENT volume to the daemon right away -- in `mode=browse`,
    # `wanted` has the final word (Prinzip 3.1(3)). This replaces the old H6
    # guard, which only DROPPED a foreign volume_changed for a non-Connect
    # player and left the daemon on its stale Connect-side volume until the
    # next unrelated LMS volume change (`connect-metadata-bleed`).
    if (($prevMode eq 'idle' || $prevMode eq 'connect') && $self->mode eq 'browse') {
        my $client = Slim::Player::Client::getClient($self->mac);
        if ($client && defined $client->volume) {
            my $vol = $client->volume;
            if ($self->pending) {
                # The `play` just dispatched above is still awaiting its
                # track_changed echo (or T1's release) -- `pending` is a
                # single slot (CR-01), so calling requestVolume here would
                # overwrite it and strand the play's own callback/T1
                # bookkeeping (the exact clobber postSeek already avoids
                # for a mismatched seek, 82-04). Fold it in the same way:
                # apply once the play settles, in onEvent's echo branch or
                # _t1Fire.
                $self->pending->{postVolume} = $vol;
            }
            elsif (my $tk = $self->_takeover) {
                # inaktiver-player-steuert-fern: the take-over is still in
                # flight -- a set_volume now would be dropped by the send
                # gate (inactive). Applied once the take-over completes.
                $tk->{postVolume} = $vol;
            }
            else {
                # reconcile already settled synchronously (Treffer: the
                # daemon already reported this uri) -- safe to send now.
                # CR-04: force bypasses the new ownership guard -- Control
                # is just now ESTABLISHING ownership on this mode
                # transition, so LMS' song object need not point at the
                # new title yet (D-06's whole point).
                $self->requestVolume($vol, { force => 1 });
            }
        }
    }

    # 84.2-02 (CAUSE-2 after-hit): a Treffer raised the prefetch wish in
    # _reconcilePlan. Without a seek (or with a seek, whose slot clears on
    # the send) nothing is pending and the next successor goes out now; an
    # open slot (e.g. the H6 set_volume above) defers it to the settle point
    # at the onEvent tail.
    $self->_consumePrefetchWish;

    return $result;
}

# requestPause($self, $isStop) -- Befund 3 (Task 4): the LMS
# ['playlist','pause'|'stop'] notification, classified against LMS'
# CURRENT playmode at delivery time -- never a time window. Notifications
# are always delivered AFTER the synchronous command that caused them
# (RESEARCH "Befund 3, die Ordnung, exakt"): if LMS already shows 'play'
# again by the time this arrives, the notification is historical -- it was
# the internal stop LMS itself issues before a `playlist play` that had
# already run synchronously -- so nothing is sent and `wanted.playing` is
# left untouched. $isStop is accepted for call-site symmetry with the LMS
# command that triggered this (`playlist stop` vs `playlist pause`) but
# does not change the outcome here: a real stop and a real pause both mean
# the daemon must stop decoding (the stream itself is dropped by LMS on a
# pause once the player buffer is full -- `Stopping remote stream upon full
# buffer when paused`, StreamingController _CheckPaused, the 84-04 B3 row;
# since 84-22 the shim's writer no longer closes a stalled client, so no
# 2 s writer close is part of the pause) -- Pause/Stop
# are never deadened, dead WS included (see _reconcile trigger
# 'requestPause'/'transport'). CR-04 EXCEPTION: this guarantee only holds
# while `mode` is `browse` AND LMS is actually on our material
# (_lmsSongIsOurs) -- outside a Stop, a foreign title's pause is simply
# dropped (there is no command coming that would ever ask us to resume a
# session we never touched); a Stop still forces exactly one `pause`
# through regardless, because a Stop means the daemon must not keep
# running unattended (T-82-64).
sub requestPause {
    my ($self, $isStop) = @_;

    # G3-MESS (82-20): the entry line for the whole guard chain below --
    # DEBUG only, no behavior change. See 82-G3-MESSUNG.md Hypothesenregister
    # H-E.
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "SpotOn G3-INSTR: requestPause mac=" . ($self->mac // '?')
        . " mode=" . ($self->mode // '?')
        . " isStop=" . ($isStop ? 1 : 0)
    );

    # 83.1-03 (D-08, :500 site): connect gets the same treatment as browse
    # from here on -- LMS pause/stop must never be deadened in mode=connect
    # either (prerequisite for plan 07's removal of Connect.pm's
    # `_sendControlCommand` WS branch).
    return 0 unless $self->mode eq 'browse' || $self->mode eq 'connect';

    unless ($self->_lmsSongIsOurs) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "SpotOn G3-INSTR: requestPause not-ours isStop=" . ($isStop ? 1 : 0)
            . " dispatchPause=" . ($isStop ? 1 : 0)
        );
        # R3-WR01 (82-27, Review Runde 3): `isStop` was previously dropped
        # here -- the fold in `_dispatch` (postPauseIsStop} = 1 if $p{isStop})
        # only remembers a Stop if the caller threads it through, and this
        # was the one `_dispatch('pause')` call site the 82-22 CR-02 fix did
        # not name. Passed through as an opt, not a second command path
        # (Prinzip 3.1(4)) -- the `if $isStop` guard at this call site is
        # unchanged (R3-WR01 Fall D).
        $self->_dispatch('pause', isStop => $isStop) if $isStop;
        # 83.1-03: leaveBrowse only makes sense coming FROM a browse session
        # (it resets mode to 'idle' and clears wanted) -- there is no browse
        # session to leave in connect.
        $self->leaveBrowse if $self->mode eq 'browse';
        return 0;
    }

    my $client = Slim::Player::Client::getClient($self->mac);
    unless ($client) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "SpotOn G3-INSTR: requestPause noclient mac=" . ($self->mac // '?')
            . " isStop=" . ($isStop ? 1 : 0)
        );
        return 0;
    }
    my $pm = Slim::Player::Source::playmode($client) // '';

    if ($pm eq 'play') {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: historic pause/stop notification, LMS already playing again -- ignored (Befund 3, "
            . ($self->mac // '?') . ")"
        );
        return 1;
    }

    $self->wanted->{playing} = 0;

    # 83.1-04 (D-B2): remember WHY LMS stopped/paused -- requestSkip's
    # resume rule (D-B2 -- a `jump +1` on a one-entry connect playlist
    # forces LMS's own internal stop BEFORE the jump notification) needs to
    # tell that internal stop apart from a genuine user pause. Cleared by
    # requestResume and by a confirmed track change (_onFrameTrackChanged).
    $self->wanted->{stopBy} = ($isStop ? 'lms-stop' : 'lms-pause') if $self->mode eq 'connect';

    # inaktiver-player-steuert-fern: LMS paused/stopped while our take-over
    # is still in flight. Nothing may go out now (a `pause` from a
    # not-yet-active device would pause the OTHER device), but the
    # `activate` is already on its way -- once it is confirmed the
    # transferred session may be playing here, unattended. Folded exactly
    # like a pause into an open play-pending (postPause/postPauseIsStop):
    # replayed through _reconcile('requestPause') after the take-over.
    if (my $tk = $self->_takeover) {
        $tk->{postPause} = 1;
        $tk->{postPauseIsStop} = 1 if $isStop;
        main::INFOLOG && $log->is_info && $log->info(
            "Control: " . ($isStop ? 'stop' : 'pause') . " during take-over -- folded, applied once the take-over is confirmed ("
            . ($self->mac // '?') . ")"
        );
        return 1;
    }

    # 82-20 (G-3, H-F bestaetigt, 82-G3-MESSUNG.md Verdikt): a real isStop
    # transition must force the pause dispatch regardless of
    # observed.status -- three live-measured runs (L1-L3) showed the
    # daemon still actively streaming while observed.status already read a
    # stale 'paused' from an earlier poll/session, and _reconcile's
    # statusIsPlaying guard silently swallowed the dispatch (Split-Brain:
    # daemon ticks, LMS stands still -- exactly what T-4 excludes). Passed
    # through as an opt, not a second trigger/command path (Prinzip 3.1(4)).
    my $rc = $self->_reconcile('requestPause', { isStop => $isStop });

    # G3-MESS (82-20): the only clock for H-F -- stands exactly when both
    # guards and the historic branch above have been passed. DEBUG only, no
    # behavior change.
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "SpotOn G3-INSTR: requestPause exit rc=" . $rc
        . " observed.status=" . ($self->observed->{status} // 'undef')
        . " wsConnected=" . ($self->observed->{wsConnected} ? 1 : 0)
        . " paired=" . (defined $self->observed->{paired} ? $self->observed->{paired} : 'undef')
        . " pending=" . (($self->pending && $self->pending->{cmd}) ? $self->pending->{cmd} : '-')
    );

    # 84.1 D-01(b): an LMS stop of our own browse title ends SpotOn's
    # browse mode -- re-entry is ALWAYS requestTrack (Prinzip 3.1(4));
    # leaveBrowse itself sends no command. leftBrowseUri is set FIRST so
    # the autoplay guard (_onFrameTrackChanged) stays armed for this title
    # after the leave -- see that guard's own comment for why. Browse
    # only, per the D-01 clarification (user, 2026-09-27, CONTEXT.md,
    # locked): in connect an LMS stop stays a session pause so the app's
    # resume keeps working (t/44 A5 pins it). `!$self->pending` excludes
    # the fold-into-open-pending case (R2-CR02/R2-WR02): a Stop folded into
    # a still-open play/set_volume pending is LMS's own internal
    # stop-before-play plumbing during a title transition, not a genuine
    # "LMS stopped our browse session" -- the fold's own replay handles it,
    # and leaving now (before the echo settles the fold) would strand it.
    if ($isStop && $self->mode eq 'browse' && !$self->pending) {
        $self->observed->{leftBrowseUri} = $self->wanted->{uri};
        main::INFOLOG && $log->is_info && $log->info(
            "Control: LMS stopped our browse title -- leaveBrowse (" . ($self->mac // '?') . ")"
        );
        $self->leaveBrowse;
    }

    return $rc;
}

# requestResume($self) -- the ['playlist','pause',0] (unpause)
# notification. CR-04: guarded the same way as requestPause -- outside
# `mode=browse` with LMS on our own material, this is a no-op. Without
# this guard, a local file/Radio unpause on LMS resumed the Spotify
# account session at the daemon (82-REVIEW.md CR-04).
sub requestResume {
    my $self = shift;

    # 83.1-03 (D-08, :571 site): connect gets the same treatment as browse.
    return 0 unless ($self->mode eq 'browse' || $self->mode eq 'connect') && $self->_lmsSongIsOurs;

    # 83.1-04 (D-B2): a genuine unpause resolves whatever requestPause
    # marked -- the session is playing again, by LMS's own explicit resume,
    # not by requestSkip's jump-resume rule.
    delete $self->wanted->{stopBy};

    $self->wanted->{playing} = 1;
    return $self->_reconcile('requestResume');
}

# requestVolume($self, $v, $opts) -- LMS -> daemon direction of D-06
# (Task 6). Sets wanted.volume and lets _reconcile decide whether the
# daemon already matches (idempotent: no send when observed.volume already
# equals $v).
#
# CR-04: guarded the same way as requestPause/requestResume -- a foreign
# LMS title's volume must not be pushed to the daemon. $opts->{force}
# skips the guard for the three INTERNAL callers that establish or
# re-confirm ownership themselves rather than reading it off LMS: the
# H6-Ersatz in requestTrack (LMS' song object need not point at the new
# title yet -- the mode transition itself IS the ownership signal), and
# the folded-volume replays in _t1Fire/the echo branch (the guard already
# ran, implicitly, when the ORIGINAL play was accepted; replaying a value
# that already passed once is not a second, independent forward).
#
# Gueltigkeitsgrenze (D-06/D-D Gegenargument, mitzufuehren, nicht zu
# glaetten): forwarding this is an ANZEIGEFUNKTION, not an audio function.
# SoloistDaemon.pm always sets LD_PRELOAD to the fake-libpulse stub for
# this backend, whose pa_context_set_sink_input_volume is a confirmed
# no-op (fake-libpulse.c:1974-1982), and S-06 measured a constant RMS
# across every volume step with that stub in place -- measured against the
# stub (Attrappe), not against real PulseAudio.
sub requestVolume {
    my ($self, $v, $opts) = @_;
    $opts ||= {};

    # 83.1-03 (D-08, :603 site): connect gets the same treatment as browse.
    # Gueltigkeitsgrenze above still holds regardless of mode -- an
    # Anzeigefunktion against the fake-libpulse no-op backend, connect
    # included.
    return 0 unless $opts->{force} || (($self->mode eq 'browse' || $self->mode eq 'connect') && $self->_lmsSongIsOurs);

    $self->wanted->{volume} = int($v);
    return $self->_reconcile('requestVolume');
}

# requestSkip($self, $dir, $reason) -- 83.1-04 Task 1 STUB. Task 2 (same
# plan) replaces this body with the real D-B2/D-B4 routing before any live
# use; this stub exists only so Connect.pm's `_onSeek` time-0 branch (Task
# 1) has a call site to compile against, and so t/37's Task 1 gate can
# already assert that call site exists.
# requestSkip($self, $dir, $reason) -- 83.1-04 Task 2 (D-B2/D-B4): the ONE
# entry point for both title keys in connect. `$dir` is 'next' or 'prev';
# `$reason` is a caller-supplied breadcrumb for the log line only (e.g.
# 'jump+1', 'time0') -- never branched on. Since debug session
# connect-skip-prev-ton-bleibt (decision 1B, 2026-09-24) `jump +0` reaches
# this sub only as the fallback when requestRestart (below) cannot run --
# see there for the D-B2 deviation. D-A2: browse moves its own
# playlist through getNextTrack, never through a skip_* wire command --
# `requestSkip` is a no-op there (matches the existing `_onPlaylistJump`
# mode gate this replaces).
#
# D-B4 precondition: `observed->{availableActions}` is the daemon's own
# capability statement (captured in Task 1's `_onFramePlaybackState`). A
# verb missing from it is refused -- an UNDEFINED set (no playback_state
# frame has EVER carried the field) is refused too, with its own reason
# (`vorbedingung_actions_unbekannt`): a missing field is not permission.
# Refusal sends nothing, warns once, and records one `refused-action:<verb>`
# errors[] entry (cleared on a later accepted skip of the SAME verb).
#
# D-B2 resume rule: a `jump +1` on LMS's one-entry connect playlist fires
# `controller->skip()` synchronously, which sends its own internal
# `playlist stop` notification (forwarded per D-08 -- `requestPause`'s
# connect row -- as a real `pause`) BEFORE the `playlist jump` notification
# this sub handles reaches Connect.pm. `wanted->{stopBy} eq 'lms-stop'`
# marks exactly that LMS-internal stop (set by `requestPause`, cleared
# here/`requestResume`/a confirmed track change): once the skip itself is
# accepted, replay `wanted.playing=1` and a bare `play` (no uri -- the
# EIGENTUMSFRAGE ownership-invariant guard only ever fires on a URI-bearing
# `play`, so this bare resume never trips it) to restore the session intent
# LMS's own internal stop had nothing to do with.
sub requestSkip {
    my ($self, $dir, $reason) = @_;

    # 83.1-REVIEW.md CR-01: ownership guard -- mirrors the _lmsSongIsOurs
    # guard already used by requestPause/requestResume/requestVolume. Without
    # it, an LMS transport key (playlist jump) on a FOREIGN (non-spoton)
    # song still forwarded skip_next/skip_prev to the daemon, driving the
    # Spotify account session off a local playlist.
    return 0 unless $self->mode eq 'connect' && $self->_lmsSongIsOurs;

    my $verb = $dir eq 'next' ? 'skip_next' : 'skip_prev';
    my $mac  = $self->mac // '?';

    my $aa = $self->observed->{availableActions};
    unless (defined $aa) {
        $self->_recordErrorOnce('refused-action:' . $verb, 'warn',
            "Control: $verb refused -- vorbedingung_actions_unbekannt ($mac)");
        return 0;
    }
    unless ($aa->{$verb}) {
        $self->_recordErrorOnce('refused-action:' . $verb, 'warn',
            "Control: $verb refused -- available_actions lacks it ($mac)");
        return 0;
    }

    $self->_clearErrorOnce('refused-action:' . $verb);
    $self->_dispatch($verb);

    if (($self->wanted->{stopBy} // '') eq 'lms-stop') {
        # LMS's own playlist ran out on this jump (D-B2) -- the session's
        # actual intent was playing, not stopped; replay it now that the
        # skip itself is on its way.
        $self->wanted->{playing} = 1;
        delete $self->wanted->{stopBy};
        $self->_dispatch('play');
    }

    return 1;
}

# requestRestart($self, $reason) -- debug session connect-skip-prev-ton-
# bleibt, user decision 1B ("LMS entscheidet", 2026-09-24), a DEVIATION
# from plan decision D-B2 for `jump +0`: like LMS' own "previous" button,
# a `jump +0` (more than 5 s into the title, Slim::Buttons::Common 'jump'
# rew) means "this title from the start", not Spotify's skip_prev. Sending
# skip_prev there was the reported defect: Spotify restarted the SAME
# title, its unarmed flush closed LMS' stream (flush-disconnect), nothing
# re-opened it (CON-13 only moved the clock), the player played out its
# buffered OLD audio and LMS stopped 15-22 s later.
#
# The restart runs through the seek path instead -- the LMS restart chain
# that carries every connect seek (D-B1): jumpToTime(0) -> _JumpToTime ->
# canDoAction('rew') -> _Stop + _Stream (the player drops its buffered
# old audio) -> onStream (rewind marker 0) -> requestTrack(seek => 1) ->
# the connect seek row -> arm + `seek 0`.
#
# Why an allowance: LMS consults canDoAction('rew') for `time 0`,
# `jump -1` on the one-entry playlist AND `jump +0` alike -- as the same
# jumpToTime(0, 1) -- and BEFORE the `playlist jump` notification reaches
# Connect.pm::_onPlaylistJump, so canDoAction itself cannot tell them
# apart; it keeps blocking all of them in connect (their D-B2 routes stay:
# `time 0` and `jump -1` -> skip_prev). This sub runs from _onPlaylistJump
# once `+0` is known, grants a ONE-SHOT allowance for exactly the playing
# uri and asks the controller again, synchronously; canDoAction consumes
# the allowance (consumeRestartAllowance) and lets the restart through.
# The allowance is cleared right after the call in every case -- it can
# never leak into a later `time 0` (which would then restart AND
# skip_prev: two command paths for one event, Prinzip 3.1(4)).
#
# Returns 1 iff LMS took the restart (the allowance was consumed), 0 when
# the route cannot run -- mode not connect, LMS paused or stopped (LMS'
# unpause would re-ask canDoAction('rew') for resumeTime 0 with no
# allowance left, so a paused restart is not attempted), no LMS song, the
# title not seekable (no known length, Befund 2), or the daemon on a
# different title than LMS' song. The caller then keeps the old D-B2
# skip_prev route. Sends nothing to the daemon itself.
sub requestRestart {
    my ($self, $reason) = @_;

    return 0 unless $self->mode eq 'connect';

    my $mac    = $self->mac // '?';
    my $client = Slim::Player::Client::getClient($self->mac) or return 0;
    my $controller = $client->controller or return 0;
    return 0 if $controller->isPaused || $controller->isStopped;

    my $song = $client->playingSong or return 0;
    my $url  = $song->track ? $song->track->url : undef;
    my $uri  = _normalizeUri($url);
    return 0 unless defined $uri;
    return 0 unless ($self->observed->{track} // '') eq $uri;
    return 0 unless $self->seekable($url);

    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Control: requestRestart(" . ($reason // '-') . ") -- LMS restart from 0 via the seek path ($mac)"
    );

    my $allowance = { uri => $uri, used => 0, granted => 0 };
    $self->_restartAllowance($allowance);
    my $ok = eval { $controller->jumpToTime(0, 1); 1 };
    my $err = $@;
    $self->_restartAllowance(undef);
    die $err unless $ok;

    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Control: requestRestart(" . ($reason // '-') . ") -- "
        . ($allowance->{granted} ? 'LMS took the restart'
            : $allowance->{used} ? 'canDoAction asked for a different uri, restart denied'
            : 'LMS did not consult canDoAction, no restart')
        . " ($mac)"
    );
    return $allowance->{granted} ? 1 : 0;
}

# consumeRestartAllowance($self, $url) -- the read side of requestRestart's
# one-shot allowance, called by ProtocolHandler::canDoAction('rew') in
# connect. One-shot: the first call uses the allowance up whatever it
# asks for (a mismatched uri fails closed, like consumeSeekIntent); returns
# 1 only for the uri the allowance was granted for, and only once.
sub consumeRestartAllowance {
    my ($self, $url) = @_;

    my $allowance = $self->_restartAllowance;
    $self->_restartAllowance(undef);
    return 0 unless defined $allowance && !$allowance->{used};
    $allowance->{used} = 1;

    my $uri = _normalizeUri($url);
    return 0 unless defined $uri && $uri eq $allowance->{uri};
    $allowance->{granted} = 1;
    return 1;
}

# watchdogRing($self, $triggerUrl) -- D-02: Plugin.pm's _prefetchHangCheck
# (the timer, unchanged) calls this instead of deciding for itself. Round 1
# compares wanted against observed and lets the SAME reconcile primitives
# (`_postBoundary`, `_dispatch('play')`) do the right thing instead of an
# immediate blind `playlist jump +1` -- S-01 Setup B measured the blind
# jump overwriting the daemon's own result in 6/6 runs before it ever
# reached LMS. T-9 Kante 1: if LMS has already moved on
# (wanted.uri ne triggerUrl -- e.g. a `getNextTrack(k+1)` already ran
# between the timer arming and this ring), there is nothing to reconcile;
# the caller's own librespot-style jump would be wrong here, so this
# returns silently rather than falling through to Runde 2.
sub watchdogRing {
    my ($self, $triggerUrl) = @_;

    my $uri = _normalizeUri($triggerUrl);
    return unless defined $uri;
    return unless $self->mode eq 'browse';

    my $wanted = $self->wanted;
    return unless defined $wanted->{uri} && $wanted->{uri} eq $uri;

    my $observed = $self->observed;

    # (d) WS tot -- sofort Runde 2, kein zweites 10s-Warten auf einen
    # Daemon, der nicht antwortet.
    unless ($observed->{wsConnected}) {
        $observed->{watchdogReason} = 'ws down';
        return $self->_watchdogRound2($uri);
    }

    my $track  = $observed->{track};
    my $status = $observed->{status};

    if (defined $track && $track ne $uri) {
        # (a) Daemon ist weiter (Autoplay/Prefetch-Treffer, S-01 B Lauf
        # play/2, queue/1) -- der Boundary-Zyklus hat nicht geliefert;
        # erneut pflanzen, damit der haengende Client sein EOF bekommt.
        $observed->{watchdogReason} = 'daemon advanced to ' . $track;
        $self->_postBoundary;
    }
    elsif (defined $status && ($status eq 'playing' || $status eq 'buffering')) {
        # (b) Daemon spielt wanted.uri noch (track eq uri, sonst waere (a)
        # oben schon gegriffen) -- LMS-Uhr voraus oder Ring-Stau, keine
        # Aktion.
        $observed->{watchdogReason} = 'daemon still playing (LMS clock ahead or ring stall)';
    }
    else {
        # (c) paused/stopped/idle (S-07-Signatur "Daemon intern gewechselt,
        # dann pausiert"), oder observed.track undef bei verbundenem WS.
        # 84.2-02 (D-15): a context end SpotOn already planted the boundary
        # for -- the title ended, there is no Spotify successor (Autoplay
        # OFF). A `play` here would replay it from 0:00 for ~10 s; LMS moves
        # on or stops through the boundary. Round 2 below stays armed as the
        # non-audible safety net.
        if (defined $observed->{contextEndPlanted} && $observed->{contextEndPlanted} eq $uri) {
            $observed->{watchdogReason} = 'context end (no successor)';
        }
        else {
            $observed->{watchdogReason} = 'daemon idle/paused';
            $self->_dispatch('play');
        }
    }

    Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
    Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + WATCHDOG_ROUND_S, \&_watchdogRound2, $uri);

    return 1;
}

# _watchdogRound2($self, $uri) -- D-03 (browse)/D-A1+D-A3 (connect, 83.1-03):
# the last escalation stage, promoted-in-place to a mode branch instead of
# add-alongside (D-A1). Browse keeps its Runde 2 body byte-identical (D-A2).
# Connect (D-A1: rung 1/watchdogRing never rescued a connect hang, 0/6
# Messung D+E -- Plugin.pm:4121 returns early for a connect session anyway
# once plan 02 made isSpotifyConnect true) has NO rung 1; THIS timer is the
# only rung, armed by _armConnectWatchdog for CONNECT_WATCHDOG_S s of
# counted silence after an emitted (re-)open request. Fires ONCE per
# incident (D-A3 Nachtrag P2-B2) and hands over to _connectResync('watchdog')
# -- which OWNS the escalation record/errors[] entry; if that one attempt
# fails, the ladder continues at _checkSplitBrain's own ticker cadence
# (D-05/D-04), never by re-arming this timer.
sub _watchdogRound2 {
    my ($self, $uri) = @_;

    my $mode = $self->mode;

    if ($mode eq 'connect') {
        # A resolving requestTrack (LMS confirmed the re-open) already
        # cancelled this timer via _cancelConnectWatchdog; the uri guard is
        # a second, defensive line against a stray fire (e.g. a
        # concurrently-armed duplicate timer, or a fire that raced a fresh
        # arm for a NEW uri).
        my $cw = $self->observed->{connectWatchdog};
        return unless $cw && $cw->{uri} eq $uri;

        my $mac = $self->mac // '?';
        $log->warn("Control: connect watchdog -- LMS did not re-open $uri within "
            . CONNECT_WATCHDOG_S . "s ($mac)");
        delete $self->observed->{connectWatchdog};

        # No errors[] entry written HERE -- _connectResync owns the shared
        # escalation record (observed->{splitBrain}) and the ONE attempts
        # counter for both this rung and _checkSplitBrain's ticker path; it
        # writes the reason-specific errors[] entry itself (D-D3: a
        # watchdog rung never claims "LMS steht, Daemon spielt", which it
        # did not itself observe).
        $self->_connectResync('watchdog');
        return;
    }

    return unless $mode eq 'browse';

    # A resolving requestTrack (new uri) already killed this timer; the
    # uri guard is a second, defensive line in case a stray fire slips
    # through (e.g. a concurrently-armed duplicate timer).
    return unless defined $self->wanted->{uri} && $self->wanted->{uri} eq $uri;

    my $mac    = $self->mac // '?';
    my $reason = $self->observed->{watchdogReason} // 'unknown';

    $log->warn("Control: watchdog forced skip on $mac (round 2: $reason)");
    $self->_recordErrorOnce('watchdog:' . $uri, 'warn',
        "$mac: watchdog forced skip (round 2: $reason)");

    my $client = Slim::Player::Client::getClient($self->mac) or return;
    $client->execute(['playlist', 'jump', '+1']);
}

# _armConnectWatchdog($self, $uri) -- 83.1-03 (D-A1/D-A3): the ONLY connect
# rung. Armed at the moment Control asks LMS to (re-)open a track (a
# daemon-driven start/change emission -- never the split-brain ladder's own
# 'nachziehen' re-emit, and never a same-uri daemon change while an
# incident for that uri is already open; see the callers in
# _emitStart/_emit). Kills any stale timer for THIS object first -- a fresh
# emission always restarts the clock from CONNECT_WATCHDOG_S.
sub _armConnectWatchdog {
    my ($self, $uri, $windowS) = @_;

    return unless $self->mode eq 'connect';
    return unless defined $uri;

    # 84-17: $windowS (optional) overrides the budget -- a `live` change
    # arms HOLD_MAX_S + CONNECT_WATCHDOG_S (the hold's own cap/ceiling plays
    # first; this stays the last resort).
    my $window = defined $windowS ? $windowS : CONNECT_WATCHDOG_S;

    Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
    $self->observed->{connectWatchdog} = {
        uri          => $uri,
        deadline     => Time::HiRes::time() + $window,
        remaining_ms => undef,
    };
    Slim::Utils::Timers::setTimer(
        $self, Time::HiRes::time() + $window, \&_watchdogRound2, $uri
    );
}

# _cancelConnectWatchdog($self) -- LMS confirmed the re-open (requestTrack's
# getNextTrack handoff for the SAME uri the daemon already reports, while
# still in connect): kill the timer and delete the record. A no-op if it
# was never armed (e.g. cancelled twice, or the clock is currently paused
# mid-handshake with no live timer to kill).
sub _cancelConnectWatchdog {
    my $self = shift;

    return unless $self->observed->{connectWatchdog};
    Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
    delete $self->observed->{connectWatchdog};
}

# _pauseConnectWatchdog($self) -- D-A4: the clock counts only while a
# re-open is actually possible. `_transport closed` means no re-open CAN
# arrive until the WS reconnects and the daemon logs back in -- freeze the
# remaining budget (integer milliseconds, never rounded to whole seconds)
# instead of letting the clock run out during a legitimate handshake
# (Gueltigkeitsgrenze 5.1s measured, D-06). A no-op if already paused or
# never armed.
sub _pauseConnectWatchdog {
    my $self = shift;

    my $cw = $self->observed->{connectWatchdog} or return;
    return if defined $cw->{remaining_ms};

    Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
    my $remaining = $cw->{deadline} - Time::HiRes::time();
    $remaining = 0 if $remaining < 0;
    $cw->{remaining_ms} = int($remaining * 1000);
    $cw->{pausedAt}     = Time::HiRes::time();
}

# _resumeConnectWatchdog($self) -- D-A4: re-arm with the PRESERVED remaining
# budget once the handshake concludes (`auth_state logged_in` after
# `_transport open`) -- never reset to the full CONNECT_WATCHDOG_S and
# never rounded to whole seconds (T2/precision). A no-op if not currently
# paused.
sub _resumeConnectWatchdog {
    my $self = shift;

    my $cw = $self->observed->{connectWatchdog} or return;
    return unless defined $cw->{remaining_ms};

    my $remainingS = $cw->{remaining_ms} / 1000;
    $cw->{deadline} = Time::HiRes::time() + $remainingS;
    delete $cw->{remaining_ms};
    delete $cw->{pausedAt};

    Slim::Utils::Timers::killTimers($self, \&_watchdogRound2);
    Slim::Utils::Timers::setTimer($self, $cw->{deadline}, \&_watchdogRound2, $cw->{uri});
}

# noteSeekIntent($self, $url, $target_ms) -- the two absicht-erfassende
# LMS hooks (ProtocolHandler::canDoAction('rew') for a restart-to-0,
# ::getSeekData($newtime) for a restart-to-N) call this; onStream is the
# ONLY consumer (Befund 1/3, D-04) -- never a second command path
# (Prinzip 3.1(4)). Marker lives on `wanted` (not `pending`) because it is
# set BEFORE any LMS restart happens, independent of anything currently in
# flight.
sub noteSeekIntent {
    my ($self, $url, $target_ms) = @_;

    my $uri = _normalizeUri($url);
    return unless defined $uri;

    $self->wanted->{seekIntent} = { uri => $uri, target_ms => int($target_ms), ts => Time::HiRes::time() };

    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Control: noteSeekIntent($uri, $target_ms) (" . ($self->mac // '?') . ")"
    );
}

# consumeSeekIntent($self, $url) -- reads AND CLEARS the marker, always
# (Befund 3: a stale marker must never survive to be misread by a LATER,
# unrelated onStream call). Returns undef when there was no marker, it had
# expired (SEEK_INTENT_TTL), or it belonged to a different uri (Befund 3
# (a)/(b)/(d): UPnP probe, _JumpPaused, Open-Fehler -> next title).
sub consumeSeekIntent {
    my ($self, $url) = @_;

    my $marker = delete $self->wanted->{seekIntent};
    return undef unless defined $marker;

    my $uri = _normalizeUri($url);
    return undef unless defined $uri;

    if ((Time::HiRes::time() - $marker->{ts}) > SEEK_INTENT_TTL) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: seek-intent marker expired (" . ($self->mac // '?') . ")"
        );
        return undef;
    }

    if ($marker->{uri} ne $uri) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: seek-intent marker uri mismatch (" . ($self->mac // '?') . ")"
        );
        return undef;
    }

    return $marker->{target_ms};
}

# seekable($self, $url) -- Befund 2: without a known track length, a
# restart-to-0 (or the marker's target) can never be trusted (LMS's
# !duration abbreviation zweig would misread a real seek target as 0).
# Explicit `seekable` (set by noteDuration/noteMetadataMissing) always
# wins; otherwise fall back to "known length implies seekable".
sub seekable {
    my ($self, $url) = @_;

    my $uri = _normalizeUri($url);
    return 0 unless defined $uri;

    my $m = $self->observed->{meta}{$uri};
    return 0 unless defined $m;
    return $m->{seekable} if defined $m->{seekable};
    return defined $m->{duration} ? 1 : 0;
}

# noteDuration($self, $url, $secs) -- Befund 2: the ONLY writers of
# $song->duration for spoton:// urls are in ProtocolHandler.pm
# (getNextTrack cache hit, _applyRuntimeMetadata after an API fetch) --
# both call this so Control learns the length as soon as LMS does.
# Promotes seekable to 1 even if noteMetadataMissing already set it to 0
# (T_meta fired before a slow-but-successful fetch landed) -- the length
# IS known now, A3's Gegenmassnahme.
sub noteDuration {
    my ($self, $url, $secs) = @_;

    my $uri = _normalizeUri($url);
    return unless defined $uri;

    $self->observed->{meta}{$uri}{duration} = $secs;
    $self->observed->{meta}{$uri}{seekable} = 1;
    $self->observed->{meta}{$uri}{seen_at}  = time();

    # wr05 (83.1-02 Task 3): a late-but-successful duration fetch closes the
    # nometa: ring entry noteMetadataMissing may have written earlier for
    # this SAME uri -- the promotion above already makes seek work again;
    # the errors[] entry must not keep claiming otherwise.
    $self->_clearErrorOnce('nometa:' . $uri);

    my $await = $self->_awaitMeta;
    if ($await && $await->{uri} eq $uri) {
        Slim::Utils::Timers::killTimers($self, \&_tMetaFire);
        $self->_awaitMeta(undef);
        $self->_fireCbs($await->{cb}, 'successCb');
    }
}

# noteMetadataMissing($self, $url) -- Befund 2: spclient (the only metadata
# source, 85-07 D-11) answered a real HTTP 404 -- the length will NEVER catch
# up (measured, not a timing corner). Sent by ProtocolHandler's refetch for
# a 404 only; a network error, a timeout or the T_meta timer never reach it.
# Fail-closed for seek ONLY: canDoAction/getSeekData consult `seekable` and
# refuse the LMS-side restart; playback itself is untouched ([ASSUMED -- A2]:
# whether the daemon can even play a 404 title is unmeasured -- M-2 in
# RESEARCH).
sub noteMetadataMissing {
    my ($self, $url) = @_;

    my $uri = _normalizeUri($url);
    return unless defined $uri;

    $self->observed->{meta}{$uri}{seekable} = 0;
    $self->_recordErrorOnce('nometa:' . $uri, 'warn',
        ($self->mac // '?') . ": no metadata for $uri, seek disabled");

    my $await = $self->_awaitMeta;
    if ($await && $await->{uri} eq $uri) {
        Slim::Utils::Timers::killTimers($self, \&_tMetaFire);
        $self->_awaitMeta(undef);
        $self->_fireCbs($await->{cb}, 'successCb');
    }
}

# nextStreamGeneration($self) / streamGeneration($self) -- D-01 Folge D: a
# reine Perl-Dekoration for LMS URL-uniqueness per stream start
# ([ASSUMED -- A1]: RemoteTrack/Direktstream-Header caches keyed by URL);
# fake-libpulse itself never reads the URL (fake-libpulse.c:1033-1080).
sub nextStreamGeneration {
    my $self = shift;
    my $gen  = ($self->_generation // 0) + 1;
    $self->_generation($gen);
    return $gen;
}

sub streamGeneration {
    my $self = shift;
    return $self->_generation // 0;
}

# _seekAlreadyIssued($self, $uri, $wantMs) -- 82-16 F1 (H-v bestaetigt):
# true when observed.seekIssued already covers this exact correction --
# same uri, position within HIT_POSITION_TOLERANCE_MS, and recorded less
# than SEEK_ISSUED_WINDOW_S ago. Read side of the seekIssued bookkeeping
# (_dispatch is the write side, on every successful `seek` send); used by
# BOTH corrective-seek call sites that key off "the daemon already reports
# this uri" -- _reconcile Schritt 4 (Treffer, opts->{seek} falsy) and the
# Seek-Pfad (2) branch (opts->{seek} true) -- because getNextTrack and
# onStream can each land in either one for the SAME synchronous LMS
# command and must not both dispatch the same seek (H-v).
sub _seekAlreadyIssued {
    my ($self, $uri, $wantMs) = @_;

    my $seekIssued = $self->observed->{seekIssued} or return 0;
    return 0 unless defined $seekIssued->{uri} && defined $uri && $seekIssued->{uri} eq $uri;
    return 0 unless abs(($seekIssued->{position_ms} // 0) - $wantMs) <= HIT_POSITION_TOLERANCE_MS;
    return 0 unless (Time::HiRes::time() - ($seekIssued->{at} // 0)) < SEEK_ISSUED_WINDOW_S;
    return 1;
}

# _reconcile($self, $trigger, $opts) / _reconcilePlan($self, $trigger,
# $opts, $now) -- compares wanted against observed and decides what (if
# anything) to send. Only the `browse` column of the mode table (RESEARCH
# "Mode-Tabelle") is implemented here; `connect` is 82-03+.
#
# _reconcilePlan is D-01/D-02: the pure
# decision body of `_reconcile`, extracted verbatim except for I/O -- see
# `_planCommand`'s header for the intent vocabulary. `$now` is an INPUT:
# `_reconcile` reads `Time::HiRes::time()` ONCE and passes it down (D-01
# "Wanduhr aus dem Entscheidungspfad") -- every clock read this body used
# to make (the AUTH_REPROBE_S check and the `_lastAuthProbeAt` stamp in
# Schritt 2, the idempotency window check in Schritt 3) uses `$now`
# instead. Plain field reads/writes on `wanted`/`observed`/`pending`/
# `_driftCount`/`_deferredTrackRequest`/`_authProbeCount`/
# `_lastAuthProbeAt` stay inline (not I/O in the D-01 sense: no WS send,
# no timer, no loopback POST, no callback fire, no errors[] write) --
# only the operations named in that list become intents, performed by
# `_execute`.
# Connect ownership invariant (83.1 EIGENTUMSFRAGE TEILENTSCHEID):
#
#   EIGENTUMSFRAGE: TEILENTSCHEID connect=Daemon-Eigentuemer (Ist-Zustand,
#   §3.4, LMS folgt per change->playlist play); browse=VERTAGT, Neigung A;
#   kein play <context-uri> in 83.1
#
# In mode=connect Control never emits `play` with a uri, never `add_to_queue`,
# and never calls `_prefetchNext` on its own initiative -- the daemon owns
# queue and position; LMS follows via `change -> playlist play
# spoton://track:<id>` (Connect.pm's change handler). Two gates from
# earlier plans already implement this by construction and are named here,
# not modified: the `_prefetchNext if $self->mode eq 'browse'` call site
# (D-C, 82-06 Task 1, formerly Control.pm:1829) and the `_transport open`
# branch's "never sends `play`/`play uri` on its own" comment + dispatch
# (82-23 WR-04, formerly :2545-2551). `_enforceConnectOwnershipInvariant`
# (Task 3, below) is the THIRD line -- an executable safety net for a
# defect in a path this plan cannot enumerate today, not a feature; it
# must never fire in the existing test suite (t/44 asserts
# Status::RECORDED carries no 'invariant:' key across the whole file).
sub _reconcilePlan {
    my ($self, $trigger, $opts, $now) = @_;
    $opts ||= {};
    my $successCb = $opts->{successCb};
    my $errorCb   = $opts->{errorCb};

    my $wanted   = $self->wanted;
    my $observed = $self->observed;
    my $pending  = $self->pending;

    my @intents;

    # 1. Transport not ready -- no WS frame has ever set wsConnected yet.
    unless ($observed->{wsConnected}) {
        # 82-42 Task C (get-state-statt-play.md T-3): a requestTrack that
        # arrives before the daemon's first frame used to be dropped here
        # SILENTLY (no _recordErrorOnce call on this path) -- LMS's own
        # internal _NextIfMore auto-advance gets exactly one, EARLY shot at
        # the persisted track after a restart and loses it here 100% of the
        # time this plan's diagnosis measured (## Resolution). Defer instead
        # of dropping: requestPause/requestResume/transport stay terminal
        # (T-77-10 does not apply to them -- they carry no LMS-side caller
        # waiting on a getNextTrack-style callback), only 'requestTrack'
        # gets the retry/TTL machinery below.
        if ($trigger eq 'requestTrack') {
            # Fall-5 (Verdraengung): a still-pending EARLIER deferral loses
            # its one shot the moment a newer request supersedes it -- exact
            # convention as the existing play-pending supersession
            # (Control.pm, `_planCommand`'s slot path), not a new mechanism.
            if (my $prevDeferred = $self->_deferredTrackRequest) {
                push @intents, { op => 'killtimer', cb => \&_wsRetryTimeout };
                push @intents, { op => 'fire', cb => $prevDeferred->{opts}, which => 'errorCb', args => [ 'PROBLEM_OPENING', 'superseded' ] };
            }
            $self->_deferredTrackRequest({ uri => $wanted->{uri}, opts => $opts });
            require Plugins::SpotOn::Unified::DeferBudget;
            my $deadline = Plugins::SpotOn::Unified::DeferBudget::deadlineFor($opts);
            push @intents, { op => 'timer', cb => \&_wsRetryTimeout, at => $deadline, args => [] };
            return \@intents;
        }
        push @intents, { op => 'fire', cb => { errorCb => $errorCb }, which => 'errorCb', args => [ 'PROBLEM_OPENING', 'Soloist daemon not ready' ] } if $errorCb;
        push @intents, { op => 'fail' };
        return \@intents;
    }

    # 2. Known-unpaired daemon (T-7): every command would just bounce off
    # an 'error' frame -- fail fast instead of round-tripping one.
    if (defined $observed->{paired} && !$observed->{paired}) {
        # 82-23 CR-03 (Runde 2): a first auth error that fell inside
        # UNPAIRED_GRACE_S is correctly suppressed by _recordErrorOnce's own
        # grace check (below), but this fail-fast path never wrote a ring
        # entry of its own -- a daemon that stays unpaired past the grace
        # window was invisible to errors[] until the NEXT probe exhaustion
        # (or forever, if requestTrack never ran again). _recordErrorOnce's
        # dedupe (errorsReported{unpaired}) makes this call a no-op once the
        # original error-frame handler (`_onFrameError`) already wrote the
        # same key.
        push @intents, { op => 'error', key => 'unpaired', level => 'error', message => ($self->mac // '?') . ": daemon not paired (request refused)" };

        # 82-23 WR-05: a bounded probe cycle that already exhausted
        # (_authProbeCount undef because AUTH_REPROBE_MAX was reached) has
        # no other way out except a spontaneous daemon push. A later user
        # action landing here is exactly the signal that the situation may
        # have changed -- ask again, rate-limited to once per
        # AUTH_REPROBE_S so a burst of requests doesn't burst probes too.
        # `unless (defined $self->_authProbeCount)` also covers the W2
        # restore-window case (WR-01's logged_in:false sets paired=0
        # without ever arming a probe cycle at all) -- see 82-23-PLAN.md
        # <objective> "W2-Wechselwirkung" and R2-WR05 Fall D: this trigger
        # cannot distinguish "exhausted" from "never armed", and does not
        # need to -- both mean "no probe is currently in flight". T1/probe
        # (checker round 2): the probe intent carries the stamp INSIDE the
        # same conditional unit `_execute` performs it in -- no ws, no
        # send AND no stamp (Vorab Fall-A pins it).
        unless (defined $self->_authProbeCount) {
            my $last = $self->_lastAuthProbeAt // 0;
            if (($now - $last) >= AUTH_REPROBE_S) {
                push @intents, { op => 'probe', cmd => 'get_auth_state', stamp => { attr => '_lastAuthProbeAt', value => $now } };
            }
        }

        # 82-42A (Defekt A, get-state-statt-play.md Befund A): a
        # requestTrack landing here used to be TERMINAL -- exactly the
        # T-3 core path measured 4/6 times (Handschlag-vor-Login:
        # wsConnected already 1, paired still 0 because the daemon's own
        # auth_state push had not yet landed). The WR-05 probe just above
        # is the ONLY mechanism that can ever flip paired back to 1 in
        # this state (82-26 CR-01: the daemon does not push a later login
        # on its own) -- it MUST run before this defers, never after/
        # instead, or the deferral would wait its full TTL for an event
        # nobody asked for. This is why the probe intent stays ABOVE this
        # block, unchanged. Same field/timer/TTL as Schritt 1
        # (_deferredTrackRequest, _wsRetryTimeout, WS_RETRY_TTL_S) -- no
        # second mechanism -- and the SAME Fall-5 supersession convention:
        # a still-pending EARLIER deferral (from either Schritt 1 or here)
        # loses its one shot to a newer request. requestPause/
        # requestResume/requestVolume/transport stay terminal below (they
        # carry no LMS-side caller waiting on a getNextTrack-style
        # callback, same reasoning as Schritt 1's own T-77-10 note).
        #
        # T1/ws-undef (checker round 2, 82-42A T-3 path): this deferral
        # list carries NO `require_ws` intent -- it must run to completion
        # even with `_ws` undef, exactly as `_reconcile` does today (Vorab
        # Fall-A pins this).
        if ($trigger eq 'requestTrack') {
            if (my $prevDeferred = $self->_deferredTrackRequest) {
                push @intents, { op => 'killtimer', cb => \&_wsRetryTimeout };
                push @intents, { op => 'fire', cb => $prevDeferred->{opts}, which => 'errorCb', args => [ 'PROBLEM_OPENING', 'superseded' ] };
            }
            $self->_deferredTrackRequest({ uri => $wanted->{uri}, opts => $opts });
            require Plugins::SpotOn::Unified::DeferBudget;
            my $deadline = Plugins::SpotOn::Unified::DeferBudget::deadlineFor($opts);
            push @intents, { op => 'timer', cb => \&_wsRetryTimeout, at => $deadline, args => [] };
            return \@intents;
        }

        push @intents, { op => 'fire', cb => { errorCb => $errorCb }, which => 'errorCb', args => [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ] } if $errorCb;
        push @intents, { op => 'fail' };
        return \@intents;
    }

    # 2b. inaktiver-player-steuert-fern (user decision A "Erst uebernehmen,
    # dann spielen", 2026-09-25): the daemon said it is NOT the account's
    # active device. Every play/seek decided below (Seek-Pfad, Treffer,
    # Mismatch) would be executed as REMOTE control of the active device --
    # and the Treffer branch would even compare against a MIRRORED
    # observed.track (live 23:35:58: remote seek 0 + resume of UAT2, UAT
    # hung at play 0.0). Take the session over first; the actual decision
    # is made once the daemon confirms (_completeTakeover), against its
    # then-own state.
    if ($trigger eq 'requestTrack' && _isKnownInactive($observed)) {
        push @intents, @{ $self->_planTakeover($opts, $now) };
        return \@intents;
    }

    # Task 4/6 (82-05): requestPause/requestResume/requestVolume/transport
    # each reconcile the ONE field they own (wanted.playing or
    # wanted.volume) and return immediately -- they never fall into the
    # uri-centric mismatch path below, which would wrongly re-send `play`
    # for a trigger that never touched wanted.uri.
    if ($trigger eq 'requestPause' || $trigger eq 'requestResume' || $trigger eq 'transport') {
        my $status          = $observed->{status};
        my $statusIsPlaying = !defined($status) || $status eq 'playing' || $status eq 'buffering';

        # 82-11 CR-03: `defined` first -- on a FRESH Control `wanted` is
        # `{}`, so `wanted->{playing}` is undef and means "no wish yet",
        # not "wants not-playing". Without this guard a `_transport open`
        # on a fresh Control sent `pause` to a daemon that was still 7-10 s
        # into restoring its session after an LMS restart, which the
        # daemon answered with "requires authentication" -- latching
        # `paired=0` for the rest of the daemon's lifetime (82-REVIEW.md
        # CR-03).
        # R3-WR01 (82-27, Review Runde 3): a real Stop's replay must not be
        # swallowed by `leaveBrowse` wiping `wanted` to `{}` -- a Stop is a
        # transport event, not a wish, and stays true even after the wish is
        # gone. `$realStop` bypasses the `defined` guard ONLY for a real
        # requestPause Stop (R3-WR01 Fall B); every other trigger through
        # this branch (`requestResume`, `transport`, and a Pause without
        # isStop) keeps the full 82-11 CR-03 `defined` discipline (R3-WR01
        # Fall C) -- coupled to `$trigger eq 'requestPause'`, not merely to
        # `$opts->{isStop}` alone, so a future caller cannot silently widen
        # this by passing isStop through a different trigger. The
        # `!$wanted->{playing}` clause is untouched for BOTH branches --
        # a title re-requested within T1 (wanted.playing=1 again) still
        # suppresses the pause (R3-WR01 Fall E, Plan-Check W2).
        my $realStop = ($trigger eq 'requestPause' && $opts->{isStop}) ? 1 : 0;
        if ((($realStop || defined $wanted->{playing}) && !$wanted->{playing})
            && ($statusIsPlaying || $opts->{isStop})) {
            # Never deadened (T-82-28): fires for requestPause AND for a
            # 'transport' reconcile after a reconnect -- a pause requested
            # while the WS was down (wanted.playing left at 0) is caught up
            # here the moment `_transport open` fires again.
            #
            # 82-20 (G-3, H-F bestaetigt): `$opts->{isStop}` forces this
            # SAME dispatch even when `observed.status` is stale (e.g.
            # 'paused' from an earlier poll while the daemon is still
            # actually streaming) -- a real Stop transition must never be
            # silently swallowed by the statusIsPlaying guard (Split-Brain,
            # T-4). No second command path: same `pause` dispatch, gate
            # condition only extended (Prinzip 3.1(4)). Only requestPause
            # ever passes `isStop`, so this cannot fire for
            # `requestResume`/`transport` reconciles.
            push @intents, @{ $self->_planCommand('pause', isStop => $opts->{isStop}) };
            return \@intents;
        }

        # `transport` never resumes on its own -- LMS is the queue owner; a
        # cold start after a reconnect runs through getNextTrack, not here.
        #
        # 84-26 R1 (F-24-1, B7): a bare `play` resumes WHATEVER the daemon
        # sits on. After the autoplay guard paused a foreign successor, an
        # LMS-internal unpause (a rebuffer at the A->L boundary, forwarded by
        # Connect.pm _onPause) restarted that foreign title through this row.
        # `_resumeTargetsOurTitle` refuses while the daemon sits on a title
        # other than wanted.uri or on the autoplay-paused title: one INFO
        # line, no errors[] entry, `wanted` untouched (wanted.playing stays 1,
        # `transport` never resumes on its own, the pause row needs
        # !wanted.playing). A refusal in the prefetch-hit shape (the daemon's
        # track_changed for the prefetched successor arrives while wanted.uri
        # is still the previous title) is harmless: LMS's own advance calls
        # requestTrack(successor), which takes the step-4 resume row.
        if ($trigger eq 'requestResume' && $wanted->{playing}
            && defined $status && ($status eq 'paused' || $status eq 'stopped'))
        {
            if ($self->_resumeTargetsOurTitle($wanted, $observed)) {
                push @intents, @{ $self->_planCommand('play') };
            }
            else {
                push @intents, { op => 'log', level => 'info', text =>
                    "Control: requestResume refused -- daemon on " . ($observed->{track} // 'none')
                    . " not on " . ($wanted->{uri} // 'none')
                    . " (marker=" . ($observed->{autoplayPaused} // 'none')
                    . " planted=" . ($observed->{contextEndPlanted} // 'none') . ") (" . ($self->mac // '?') . ")" };
            }
            return \@intents;
        }

        return \@intents;
    }

    if ($trigger eq 'requestVolume') {
        my $v = $wanted->{volume};
        if (!defined $observed->{volume} || $observed->{volume} != $v) {
            push @intents, @{ $self->_planCommand('set_volume', volume => $v) };
            return \@intents;
        }
        return \@intents;
    }

    # Seek-Pfad (opts->{seek} wahr, RESEARCH Kante 3): Idempotenz (3) und
    # Treffer (4) sind bereits `&& !$opts->{seek}`-gated unten -- die
    # Reihenfolge der folgenden zwei Pruefungen ist Vertrag. Der dritte Fall
    # (anderer Titel, kein pending) faellt bewusst durch auf den normalen
    # Mismatch-Pfad (5) -- wanted->{position_ms} traegt das Sprungziel
    # bereits, Schritt 5 setzt postSeek daraus.
    if ($opts->{seek}) {
        my $uri = $wanted->{uri};
        my $pos = $wanted->{position_ms} // 0;

        # G4-INSTR (82-21): eine reine Lesezeile am Eintritt des Seek-Pfads
        # -- traegt alle Eingaben, aus denen Zweig (1)/(2)/(3) und die
        # Armierung folgen (H-S2/H-S3, 82-G4-MESSUNG.md). DEBUG-only,
        # keine Wirkung auf $uri/$pos/$pending.
        push @intents, { op => 'log', level => 'debug', text =>
            "SpotOn G4-INSTR: seek-path pos=$pos observed.track="
            . ($observed->{track} // 'undef') . " observed.status="
            . ($observed->{status} // 'undef') . " pending="
            . ($pending ? $pending->{cmd} . (defined $pending->{uri} ? ':' . $pending->{uri} : '') : '-')
            . " seekIssued=" . ($self->_seekAlreadyIssued($uri, $pos) ? 1 : 0)
            . " (" . ($self->mac // '?') . ")"
        };

        # (1) Offenes pending play derselben uri: der Daemon ist noch auf
        # dem alten Titel (Regelfall getNextTrack(X,N)+onStream(X,seekdata
        # N) im selben synchronen LMS-Kommando; ebenso Rewind < 500ms nach
        # Play) -- kein zweites play, kein sofortiges seek (traefe den
        # alten Titel). Der Arm-Zustand des ersten Dispatch gilt weiter.
        if ($pending && $pending->{cmd} eq 'play'
            && defined $pending->{uri} && defined $uri && $pending->{uri} eq $uri)
        {
            push @intents, { op => 'set', target => 'pending', key => 'postSeek', value => $pos };
            push @intents, { op => 'log', level => 'debug', text =>
                "Control: seek folded into pending play (postSeek=$pos, " . ($self->mac // '?') . ")"
            };
            return \@intents;
        }

        # (2) Gleicher Titel spielt, kein pending play: seek (armiert, wenn
        # ein Flush plausibel bevorsteht -- seit 82-19 F2 IMMER ueber den
        # synchronen Loopback-Arm, siehe _armSync), danach ein nackter play
        # (Resume-Semantik, No-op auf spielendem Daemon). command_result ist
        # kein Zustandswechsel (D-B Gegenargument) -- successCb feuert
        # sofort, kein Echo-Warten.
        # 82-16 F1 (H-v bestaetigt): getNextTrack (Schritt 4, unten) and
        # onStream (hier) can both reach a "daemon already on this uri"
        # branch for the SAME synchronous LMS command and see the same
        # stale anchor -- _seekAlreadyIssued suppresses the SECOND send
        # (whichever call actually completes first, per _dispatch's own
        # seekIssued bookkeeping); the bare `play` below still runs either
        # way (Resume-Semantik is independent of the seek).
        if (defined $observed->{track} && defined $uri && $observed->{track} eq $uri) {
            # 82-21 (G-4, H-S3 bestaetigt n=3): die Armierung folgt jetzt
            # derselben H-vi-Regel wie Schritt 4 und Schritt 5 -- "arm
            # whenever a track is observed at all, independent of status"
            # (82-16 H-vi) -- statt der alten status-gebundenen Bedingung.
            my $armed = defined $observed->{track} ? 1 : 0;
            unless ($self->_seekAlreadyIssued($uri, $pos)) {
                push @intents, @{ $self->_planCommand('seek', position_ms => $pos, armed => $armed) };
            }

            # 83.1-04 (D-B1), revised 84.1-06 (REPAIR_PAUSEHANG): the
            # connect seek row is arm + seek only when the daemon is
            # already PLAYING -- Browse's Resume-Semantik (a bare play
            # follows every seek, even a no-op resume on an already-playing
            # daemon) does not apply there: the daemon owns playback state
            # (EIGENTUMSFRAGE TEILENTSCHEID, _reconcilePlan's own comment
            # block above), LMS only follows it, and a bare `play` would
            # have nothing to accomplish (onStream calls this with no
            # successCb at all, D-B1 acceptance, plan 05).
            #
            # EXCEPTION (84.1-05/06, connect-weiter-nach-pause-haengt-im-
            # puffern, release-blocker candidate): when LMS drops a long-
            # paused remote stream (_CheckPaused) and later re-opens it via
            # this same seekdata path, the daemon can still be `paused` at
            # that reopen -- there is nobody else left to resume it, so
            # without a follow-up `play` LMS waits in BUFFERING-STREAMING
            # forever. Measured live 2026-09-24 13:24 (armed seek, `Resume
            # -> BUFFERING-STREAMING`, 50s+ of `StatusHeartbeat ... _NoOp`)
            # and CONFIRMED by the 84.1-05 series on BOTH players
            # (B4_OBSERVED_STATUS=paused, no PLAYING-STREAMING within 15s
            # of the armed seek -- see 84.1-CLUSTER2-VERDICTS.md
            # DECIDING_connect-weiter-nach-pause-haengt-im-puffern=confirmed).
            # IN-09 (84-08, D-22, user decision 2026-10-11: KEEP). The
            # `&& $wanted->{playing}` clause below is INERT on the direct
            # path: requestTrack rewrites `wanted` with playing => 1 before
            # its own _reconcile, so an LMS pause -> seek while paused ->
            # play always reaches this row with 1. It takes effect ONLY on
            # the two replays of stored requestTrack opts (incl. `seek`):
            # the take-over confirmation (_reconcile('requestTrack',
            # \%merged)) and the WS catch-up after login
            # (_reconcile('requestTrack', $deferred->{opts})), when an LMS
            # pause (requestPause -> wanted.playing 0) falls between the
            # deferral and the replay -- there it keeps the LMS-side pause
            # intent (D-08) from being overridden by a `play` of our own.
            # Pinned by t/44 "IN-09 R1" (replay: seek, no play; removing
            # the clause turns it red) and "IN-09 R2" (direct: seek + play).
            if ($self->mode eq 'connect') {
                push @intents, @{ $self->_planCommand('play') }
                    if (($observed->{status} // '') eq 'paused') && $wanted->{playing};
                push @intents, { op => 'fire', cb => { successCb => [ $successCb ] }, which => 'successCb', args => [] } if $successCb;
                return \@intents;
            }

            push @intents, @{ $self->_planCommand('play') };
            push @intents, { op => 'fire', cb => { successCb => [ $successCb ] }, which => 'successCb', args => [] } if $successCb;
            return \@intents;
        }

        # (3) Anderer Titel, kein pending play -- faellt durch auf Schritt 5
        # unten (Mismatch), das dort ergaenzte postSeek uebernimmt pos.
    }

    # 3. Idempotency: an identical play is already in flight -- attach this
    # caller's successCb to the list that fires on the shared echo instead
    # of sending a second command. Resolves the getNextTrack+onStream
    # double-entry for the same target (RESEARCH "Idempotenz").
    if ($pending && $pending->{cmd} eq 'play'
        && defined $pending->{uri} && defined $wanted->{uri}
        && $pending->{uri} eq $wanted->{uri}
        && ($pending->{position_ms} // 0) == ($wanted->{position_ms} // 0)
        && ($now - $pending->{sentAt}) < (T1_TRACK_CHANGED_MS / 1000)
        && !$opts->{seek})
    {
        push @{ $pending->{cb}{successCb} }, $successCb if $successCb;
        return \@intents;
    }

    # 79-33 (D-28 F2, LABELS-SKIP): the onStream twin of a play that T1 already
    # released. LMS runs the released successCb synchronously (_Stream ->
    # Song::open -> onStream -> requestTrack), so the twin arrives with no
    # pending play but with the late-echo window of that very play still open
    # (_t1Fire arms observed.expectEcho). The play is on the wire already:
    # absorb the twin instead of sending a second one. A seek, another uri or
    # another position is a genuine new request and is not absorbed.
    if (!($pending && $pending->{cmd} eq q{play})
        && ($opts->{source} // q{}) eq q{onStream} && !$opts->{seek}
        && defined $wanted->{uri} && $observed->{expectEcho}
        && ($observed->{expectEcho}{uri} // q{}) eq $wanted->{uri}
        && ($observed->{expectEcho}{until} // 0) > $now
        && ($observed->{expectEcho}{position_ms} // 0) == ($wanted->{position_ms} // 0))
    {
        push @intents, { op => q{fire}, cb => { successCb => [ $successCb ] }, which => q{successCb}, args => [] } if $successCb;
        return \@intents;
    }

    # 4. Treffer: the daemon already reports the wanted track. 82-08 CR-01:
    # a BARE `play` here used to be sent unconditionally on paused/stopped,
    # which the daemon executes as a resume at whatever position it last
    # reported -- live reproduced three times at the account session's
    # stale position (19431/81235/200708 ms) instead of the requested 0.
    # Fix: compare the wanted position against the anchor rebased to now
    # (_observedPositionMs) and correct with a `seek` BEFORE resuming/
    # playing whenever the drift exceeds HIT_POSITION_TOLERANCE_MS -- a
    # bare `play`/no-op now only goes out on its own when the position
    # already matches.
    #
    # W-NEU-1 (Review Runde 2): the fourth clause below excludes a Treffer
    # when a `play`-Pending is open for a DIFFERENT uri than wanted.uri --
    # observed.track can be a stale intermediate value from BEFORE the
    # daemon's in-flight switch to that other target, not a stable
    # already-there. Falls through to Schritt 5 (Mismatch) instead, which
    # reaches the SAME Superseded mechanism (B2 above) a genuine new `play
    # uri` already uses -- `_planCommand` itself stays unchanged.
    if (defined $observed->{track} && defined $wanted->{uri}
        && $observed->{track} eq $wanted->{uri} && !$opts->{seek}
        && !($pending && $pending->{cmd} eq 'play' && defined $pending->{uri}
             && $pending->{uri} ne $wanted->{uri}))
    {
        # WR-01 (82-REVIEW.md), Treffer-Zweig: the daemon already reports
        # the wanted uri -- the drift counter's question (does the daemon
        # follow this play?) is answered, clear it here too, not only on
        # the onEvent echo path above. Without this, three late echoes
        # that each individually landed here via the Treffer-Zweig (rather
        # than the echo branch) would still accumulate toward
        # DRIFT_MAX_REDISPATCH and eventually make the title unplayable
        # even though the daemon was correct every single time.
        delete $self->_driftCount->{ $wanted->{uri} };
        push @intents, { op => 'clearerror', key => 'drift:' . $wanted->{uri} };

        # 84.2-02 (CAUSE-2 after-hit): LMS adopted the title the daemon
        # already plays (typically a prefetch hit through getNextTrack) --
        # no `play uri`, so no echo, so the echo's _prefetchNext never runs
        # for the NEXT successor. Raise the prefetch wish; requestTrack (or
        # the onEvent tail, once a slot settles) consumes it. LMS has already
        # moved streamingSongIndex to this title, so idx+1 is the next one.
        push @intents, { op => 'set', target => 'observed', key => 'prefetchWish', value => 1 }
            if $self->mode eq 'browse';

        my $status  = $observed->{status} // '';
        my $playing = ($status eq 'playing' || $status eq 'buffering') ? 1 : 0;
        my $wantMs  = $wanted->{position_ms} // 0;
        my $haveMs  = $self->_observedPositionMs($now);

        # 82-30 T-3: a known-and-drifting position was always corrected
        # (below), but an UNKNOWN position (no observed.anchor yet -- the
        # normal state right after an LMS restart, before the daemon has
        # sent its first position frame for this track) fell through the
        # old `defined $haveMs && ...` condition entirely and left the
        # daemon to continue its own stale account-session position on the
        # bare `play` below. $needsSeek widens the correction to that case
        # too, with two explicit exceptions: mode=connect (82-24 CR-04
        # deliberately removed the seek 0 there -- LMS follows the daemon,
        # it does not correct it), and an already-open play-Pending for
        # this same uri (R2-CR01 Fall F -- `_planCommand`'s own
        # fold-through already resolves that case, a second seek would
        # break it).
        #
        # WR-01 (82-REVIEW.md Runde 6, 82-31): a third exception used to
        # sit here -- an already-$playing daemon, reasoned as the
        # "prefetch-/resume-hit case". That reasoning does not hold:
        # track_changed NEVER writes observed.anchor (only position_sync/
        # playback_state write it, only _transportClosed clears it), so a
        # genuine prefetch hit always carries the PREVIOUS track's anchor
        # and is decided by the defined-arm above, never by this branch.
        # What the removed exception actually protected was the
        # playing-twin of the 82-30 fix itself -- a fresh/reconnected
        # Control where the daemon already reports playing but no position
        # frame for the CURRENT track has arrived yet -- and that state
        # stayed uncorrected. CR-01 Fall F (t/44) is now its permanent
        # guard (user decision 2026-09-12, STATE.md :352).
        my $needsSeek = defined $haveMs
            ? abs($haveMs - $wantMs) > HIT_POSITION_TOLERANCE_MS
            : ($self->mode ne 'connect' && !($pending && $pending->{cmd} eq 'play'));

        if ($needsSeek) {
            # 82-16 F1 (H-v bestaetigt, 82-G1-MESSUNG.md): getNextTrack and
            # onStream can both land in this branch for the SAME
            # synchronous LMS command and see the same stale anchor --
            # without this check both used to send the identical seek
            # (two dispatch seek lines, 7ms apart, live-measured A2/A3/B1/
            # B2). _seekAlreadyIssued reads observed.seekIssued, which
            # `_execute`'s `send` handler writes on every successful `seek`
            # send (Slot-Pfad AND Fold-Through) -- whichever of the two
            # calls completes first wins, the other is a no-op here.
            if ($self->_seekAlreadyIssued($wanted->{uri}, $wantMs)) {
                push @intents, { op => 'log', level => 'debug', text =>
                    "Control: Treffer seek suppressed (already issued wantMs=$wantMs, "
                    . ($self->mac // '?') . ")"
                };
            }
            else {
                # G1-MESS (82-15 Task 1): H-v's trennsignal -- counts how many
                # times THIS branch fires per LMS command (getNextTrack and
                # onStream can both land here for the same stale anchor). DEBUG
                # only, no behavior change. The channel marker (sync=) that
                # used to distinguish the two dispatch call sites is gone as
                # of 82-19 F2 -- both now arm identically, see _armSync.
                push @intents, { op => 'log', level => 'debug', text =>
                    "Control: Treffer seek wantMs=$wantMs haveMs=" . ($haveMs // 'undef') . " armed="
                    . (defined $observed->{track} ? 1 : 0)
                    . " source=" . ($opts->{source} // '-') . " (" . ($self->mac // '?') . ")"
                };
                # 82-16 H-vi (82-G1-MESSUNG.md Verdikt: bestaetigt, Laeufe
                # B1/B2 -- A2/A3 reproduced the same pattern) -- armed =>
                # $playing left a seek on a paused/unknown daemon unarmed,
                # but a flush follows it there too (four of five runs
                # showed the pattern). Arm whenever a track is observed at
                # all, independent of status; an over-armed flush is cheap
                # (WR-03: TTL 3000ms, reset on POST /boundary), a missing
                # one costs the client.
                push @intents, @{ $self->_planCommand('seek', position_ms => $wantMs,
                    armed => (defined $observed->{track} ? 1 : 0)) };
            }
        }

        if ($playing) {
            # Prefetch/resume hit, position already corrected above (if it
            # needed correcting) -- nothing else to send.
            push @intents, { op => 'fire', cb => { successCb => [ $successCb ] }, which => 'successCb', args => [] } if $successCb;
            return \@intents;
        }
        # paused/stopped/unknown -- bare resume (play without uri). Safe if
        # the daemon turns out to already be playing (no-op); resumes if
        # actually paused; never blocks getNextTrack on an ambiguous status.
        push @intents, @{ $self->_planCommand('play', position_ms => $wantMs,
            armed => 0, cb => { successCb => [ $successCb ? ($successCb) : () ], errorCb => $errorCb }) };
        return \@intents;
    }

    # 5. Mismatch -- the daemon is elsewhere (or unknown). Re-dispatch up to
    # DRIFT_MAX_REDISPATCH times per target, then surface via errors[]
    # instead of retrying silently forever (RESEARCH reconcile table
    # "Drift").
    my $uri   = $wanted->{uri};
    my $count = ($self->_driftCount->{$uri} // 0) + 1;
    $self->_driftCount->{$uri} = $count;

    if ($count > DRIFT_MAX_REDISPATCH) {
        push @intents, { op => 'error', key => 'drift:' . $uri, level => 'warn',
            message => ($self->mac // '?') . ": daemon does not follow play $uri after " . DRIFT_MAX_REDISPATCH . " attempts" };
        push @intents, { op => 'fire', cb => { errorCb => $errorCb }, which => 'errorCb', args => [ 'PROBLEM_OPENING', 'Soloist daemon does not follow' ] } if $errorCb;
        push @intents, { op => 'fail' };
        return \@intents;
    }

    # D-B (81-DECISIONS): Arm bleibt in C -- 30/30 korrekt geordnet, d1 p95
    # = 70 ms. Gueltigkeitsgrenze: nur auf dem Mismatch-Pfad gemessen; beim
    # Positionswechsel im selben Titel feuerte der Arm in 0/30 Laeufen
    # (Takeover-Pfad).
    # 82-16 H-vi (82-G1-MESSUNG.md Verdikt: bestaetigt, Laeufe B1/B2 -- und
    # A2/A3 reproduzierten dasselbe Muster) -- armed => $playing liess einen
    # Flush auf einem pausierten/unbekannten Daemon unarmiert: der Arm wird
    # jetzt gesetzt, sobald ein Titel beobachtet ist (defined
    # observed.track), unabhaengig vom Status. Ein zu viel gesetzter Arm ist
    # billig (WR-03: TTL 3000 ms, Reset bei POST /boundary); ein fehlender
    # kostet den Client (77-REVIEWS HIGH). Gegenargument: `command_result`
    # erreicht Dritte nie -- Control ist Sender und sieht es, wertet es aber
    # nicht als Zustandswechsel (Note Section 2.2).
    my $armed = defined $observed->{track} ? 1 : 0;
    my $posMs = $wanted->{position_ms} // 0;

    # Befund 2: play uri geht SOFORT raus (Pitfall 5) -- awaitMeta merkt
    # nur, ob successCb auf noteDuration/T_meta warten muss, ohne den
    # Kommandoversand zu verzoegern.
    my $metaKnown = $observed->{meta}{$uri} && defined $observed->{meta}{$uri}{duration};

    # Mismatch-Pfad-Ergaenzung (82-04, erweitert 82-08 CR-01): ein play mit
    # einer vom Aufrufer uebergebenen Position setzt postSeek selbst -- die
    # Position ist damit auch ohne folgendes onStream (Sync-Mitglied,
    # fehlender Hook) nicht verloren. Frueher wurde position_ms == 0 hier
    # unterdrueckt (posMs > 0); das war der zweite Teil von CR-01 -- ein
    # `play uri` auf den Titel der laufenden Account-Session verhaelt sich
    # beim Daemon wie ein Resume an dessen alter Position, 0 ist also der
    # wichtigste Fall, nicht der Sonderfall.
    # 84-19 F-18-N4 change 2: the target IS the head of the daemon's user
    # queue (our own prefetch from an earlier visit, or a stale entry) --
    # `play X` never consumes a head equal to X (same-1 10:29:57.381: head
    # 6d0c stayed, the next prefetch made [6d0c, 5EZh, 5EZh], and at the end
    # of the title the daemon consumed the head and replayed 6d0c). Consume
    # it instead: `skip_next` pops exactly one entry and starts it with a
    # track_changed (drain3). The slot stays {cmd => 'play', uri} (wireCmd
    # only changes what goes on the wire) so the echo is classified as OWN
    # by target match and every post-echo step stays the same. The title
    # starts at 0: a postSeek of 0 is dropped, a resume position stays.
    # Browse only, and only for a head we KNOW (queueHead is cleared by
    # every track_changed until the next queue_changed re-states it).
    my $head = $observed->{queueHead};
    if ($self->mode eq 'browse' && ref($head) eq 'HASH' && defined $head->{uri} && $head->{uri} eq $uri) {
        push @intents, @{ $self->_planCommand('play', uri => $uri, position_ms => $posMs,
            armed => $armed, awaitMeta => ($metaKnown ? 0 : 1),
            postSeek => ($posMs > 0 ? $posMs : undef),
            wireCmd => 'skip_next',
            cb => { successCb => [ $successCb ? ($successCb) : () ], errorCb => $errorCb }) };
        return \@intents;
    }

    push @intents, @{ $self->_planCommand('play', uri => $uri, position_ms => $posMs,
        armed => $armed, awaitMeta => ($metaKnown ? 0 : 1),
        postSeek => (defined $wanted->{position_ms} ? $posMs : undef),
        cb => { successCb => [ $successCb ? ($successCb) : () ], errorCb => $errorCb }) };
    return \@intents;
}

# _reconcile($self, $trigger, $opts) -- D-01: thin wrapper, kept for all
# existing call sites/return-value contract. Reads the clock exactly ONCE
# and passes it into the pure planner.
sub _reconcile {
    my ($self, $trigger, $opts) = @_;

    my $intents = $self->_reconcilePlan($trigger, $opts, Time::HiRes::time());
    $intents = $self->_enforceConnectOwnershipInvariant($intents, $opts // {})
        if $self->mode eq 'connect';

    return $self->_execute($intents);
}

# _planTakeover($self, $opts, $now) -- debug session inaktiver-player-
# steuert-fern (user decision A, 2026-09-25): the planner half of the
# take-over step _reconcilePlan Schritt 2b enters for a requestTrack on a
# KNOWN-inactive daemon. Measured on the rig (2026-09-25, runs M1/M2/M5/M6):
#   - `activate` on an inactive daemon while another device plays is a
#     Connect TRANSFER -- the session moves here (same title, cluster
#     position, play state), the other device stops with `RemoteTransfer`;
#   - it is confirmed by device_changed is_active:true: +884/+621 ms with
#     another device active (AFTER command_result and after a track_changed
#     of the transferred title), +1 ms with no device active (M5, where the
#     account's last title stays paused);
#   - an already-active daemon answers `activate` with command_result only,
#     no device_changed (M6) -- hence the read-only `get_auth_state` probe
#     right behind it: its auth_state answer carries is_active, and onEvent
#     completes the take-over from ANY frame that leaves is_active=1;
#   - there is no error frame for a take-over that does not happen -- only
#     the missing confirmation, hence TAKEOVER_TIMEOUT_S.
# A second requestTrack while the take-over is in flight sends no second
# `activate`: the same title joins the waiting callers (getNextTrack +
# onStream double entry), a DIFFERENT title supersedes them (Fall-5
# convention of the deferral path above).
sub _planTakeover {
    my ($self, $opts, $now) = @_;
    $opts ||= {};

    my @intents;
    my $uri = $self->wanted->{uri};

    if (my $tk = $self->_takeover) {
        if (!defined $tk->{uri} || !defined $uri || $tk->{uri} ne $uri) {
            for my $old (@{ $tk->{opts} || [] }) {
                push @intents, { op => 'fire', cb => $old, which => 'errorCb', args => [ 'PROBLEM_OPENING', 'superseded' ] };
            }
            $tk->{opts} = [];
            $tk->{uri}  = $uri;
        }
        push @{ $tk->{opts} }, $opts;
        return \@intents;
    }

    push @intents, { op => 'require_ws', cb => { errorCb => $opts->{errorCb} } };
    push @intents, { op => 'set', target => 'attr', key => '_takeover',
        value => { uri => $uri, opts => [ $opts ], startedAt => $now } };
    push @intents, { op => 'log', level => 'info', text =>
        "Control: not the active Spotify device -- taking the session over (activate) before playing "
        . ($uri // '?') . " (" . ($self->mac // '?') . ")" };
    # Timer BEFORE the sends: a send that silently goes nowhere is still
    # bounded by the timeout.
    push @intents, { op => 'timer', cb => \&_takeoverTimeout, at => $now + TAKEOVER_TIMEOUT_S, args => [] };
    push @intents, { op => 'probe', cmd => 'activate' };
    push @intents, { op => 'probe', cmd => 'get_auth_state' };
    return \@intents;
}

# _completeTakeover($self) -- the daemon confirmed our take-over (onEvent,
# after any frame that left observed.is_active=1 while `_takeover` is set).
# From here on its state is OUR state: the requested title is decided by the
# ordinary requestTrack reconcile -- EXCEPT the anchor: the transferred
# session reports a stale position (M1: playback_state pos=0 while the
# daemon started at 48751 ms), so it is dropped and the Treffer branch
# corrects with an explicit seek (82-30 T-3 "unknown anchor" rule).
sub _completeTakeover {
    my $self = shift;

    my $tk = $self->_takeover or return;
    $self->_takeover(undef);
    Slim::Utils::Timers::killTimers($self, \&_takeoverTimeout);
    delete $self->_timerRegistry->{ refaddr(\&_takeoverTimeout) } if $self->_timerRegistry;

    my $mac = $self->mac // '?';
    $self->_clearErrorOnce('takeover');
    main::INFOLOG && $log->is_info && $log->info(sprintf(
        "Control: take-over confirmed after %d ms -- now the active device, playing %s (%s)",
        (Time::HiRes::time() - ($tk->{startedAt} // Time::HiRes::time())) * 1000, $tk->{uri} // '?', $mac));

    my @callers = @{ $tk->{opts} || [] };

    # LMS moved on while we waited (leaveBrowse after a foreign-title stop,
    # or another title than the one taken over for): nothing to play. The
    # transferred session may be PLAYING here now (M1) -- stop it locally,
    # it has no LMS listener.
    my $wantUri = $self->wanted->{uri};
    if (!defined $wantUri || !defined $tk->{uri} || $wantUri ne $tk->{uri}) {
        main::INFOLOG && $log->is_info && $log->info(
            "Control: take-over confirmed but LMS no longer wants " . ($tk->{uri} // '?') . " -- pausing locally ($mac)");
        $self->_fireCbs($_, 'errorCb', 'PROBLEM_OPENING', 'superseded') for @callers;
        $self->_dispatch('pause');
        return 0;
    }

    delete $self->observed->{anchor};

    my @success = grep { $_ } map { $_->{successCb} } @callers;
    my @error   = grep { $_ } map { $_->{errorCb} } @callers;
    my %merged  = %{ $callers[-1] || {} };
    $merged{successCb} = @success ? sub { $_->(@_) for @success } : undef;
    $merged{errorCb}   = @error   ? sub { $_->(@_) for @error }   : undef;

    my $rc = $self->_reconcile('requestTrack', \%merged);

    # H6-Ersatz volume push folded by requestTrack while the take-over was
    # in flight -- same fold rules as the play-pending path there.
    if (defined $tk->{postVolume}) {
        if ($self->pending) { $self->pending->{postVolume} = $tk->{postVolume}; }
        else                { $self->requestVolume($tk->{postVolume}, { force => 1 }); }
    }

    # LMS pause/stop that arrived during the take-over (requestPause fold).
    $self->_reconcile('requestPause', { isStop => $tk->{postPauseIsStop} }) if $tk->{postPause};

    return $rc;
}

# _releaseTakeover($self, $reason, $record) -- the take-over did not happen
# (timeout, daemon error, transport loss, shutdown): every waiting caller
# gets its errorCb exactly once (getNextTrack must never wedge, T-77-10);
# $record writes the visible errors[] entry (key `takeover`, cleared by the
# next confirmed take-over). Safe to call with nothing in flight.
sub _releaseTakeover {
    my ($self, $reason, $record) = @_;

    my $tk = $self->_takeover or return;
    $self->_takeover(undef);
    Slim::Utils::Timers::killTimers($self, \&_takeoverTimeout);
    delete $self->_timerRegistry->{ refaddr(\&_takeoverTimeout) } if $self->_timerRegistry;

    my $mac = $self->mac // '?';
    my $msg = "$mac: Spotify take-over failed ($reason) -- " . ($tk->{uri} // '?') . " not played";
    $log->warn("Control: $msg");
    $self->_recordErrorOnce('takeover', 'warn', $msg) if $record;

    $self->_fireCbs($_, 'errorCb', 'PROBLEM_OPENING', "Spotify take-over failed ($reason)")
        for @{ $tk->{opts} || [] };
}

# _takeoverTimeout($self) -- TAKEOVER_TIMEOUT_S passed without a
# confirmation (see _planTakeover: a failed take-over has no error frame).
sub _takeoverTimeout {
    my $self = shift;
    return unless $self->_takeover;
    $self->_releaseTakeover('not confirmed within ' . TAKEOVER_TIMEOUT_S . ' s', 1);
}

# _enforceConnectOwnershipInvariant($self, $intents, $opts) -- 83.1-03 Task
# 3 (EIGENTUMSFRAGE point 1, safety net not a feature): scans the intents
# `_reconcilePlan` just produced and, in mode=connect ONLY, converts any
# `send` intent that would emit `play` WITH a uri or `add_to_queue` -- and
# did NOT originate from an actual LMS request ($opts->{source} is
# 'getNextTrack' or 'onStream') -- into a `log` + `error` intent pair
# instead. Every real connect getNextTrack/onStream call already tags
# $opts->{source} accordingly (module contract, see _reconcile's own doc
# comment above _reconcilePlan) and is therefore exempt by construction;
# this only catches a FUTURE trigger that reaches `_reconcile` in connect
# mode without that provenance. Never touches `_dispatch`'s direct
# callers (watchdogRing, _connectResync, playback-state resume) -- those
# are already structurally gated (mode eq 'browse' for the two `play`/
# `add_to_queue`-adjacent ones) and never route through `_reconcile` at
# all, so they are out of this guard's reach by design, not by omission.
sub _enforceConnectOwnershipInvariant {
    my ($self, $intents, $opts) = @_;
    return $intents unless ref($intents) eq 'ARRAY';

    my $src = $opts->{source} // '';
    return $intents if $src eq 'getNextTrack' || $src eq 'onStream';

    my @out;
    for my $intent (@$intents) {
        if (ref($intent) eq 'HASH' && ($intent->{op} // '') eq 'send') {
            my $cmd = $intent->{cmd} // '';
            my %wire = @{ $intent->{wireArgs} // [] };
            if (($cmd eq 'play' && exists $wire{uri}) || $cmd eq 'add_to_queue') {
                my $mac  = $self->mac // '?';
                my $uri  = $wire{uri} // ($intent->{slot} && $intent->{slot}{uri}) // '?';
                my $text = "Control: connect invariant -- suppressed $cmd $uri (daemon owns the queue) ($mac)";
                push @out, { op => 'log', level => 'warn', text => $text };
                push @out, { op => 'error', key => 'invariant:' . $cmd, level => 'warn',
                    message => "$mac: connect invariant -- suppressed $cmd $uri (daemon owns the queue)" };
                next;
            }
        }
        push @out, $intent;
    }
    return \@out;
}

# _wireArgsFor($cmd, %p) -- the ONE place in this module that decides
# which of %p's keys reach the wire (82-09, CR-02 Schritt 3): both the
# slotted play/set_volume/seek path below AND the fold-through path for
# side commands (add_to_queue/get_state/seek/... sent while a `play` is
# pending) build their wire arguments here -- a second, independent
# builder would let the two paths silently drift apart.
sub _wireArgsFor {
    my ($cmd, %p) = @_;
    my @wireArgs;
    return @wireArgs if defined $p{wireCmd} && $p{wireCmd} eq 'skip_next';    # 84-19: no arguments on the wire
    push @wireArgs, (uri => $p{uri}) if defined $p{uri};
    push @wireArgs, (position_ms => $p{position_ms}) if $cmd eq 'seek';
    push @wireArgs, (volume => $p{volume}) if $cmd eq 'set_volume';
    return @wireArgs;
}

# 83.1-01 (D-01/D-02): `_dispatch`'s old, single monolithic body is split
# into a pure PLANNER (`_planCommand`, below) and an EXECUTOR
# (`_execute`, further below) with snapshot/rollback -- the I/O-free
# decision core the whole 83.1 mode-policy build stands on (83-CONTEXT.md
# D-01 Begruendung: in `mode=connect`, `wanted` gets a second writer, and
# every arbitration rule needs a decision path whose exits can be
# enumerated, which is only possible once timers/socket/wall-clock are out
# of it). `_dispatch($self, $cmd, %p)` keeps its exact name, signature and
# return contract for all ~40 existing call sites -- it is now a thin
# wrapper: `_execute(_planCommand(...))`.
#
# _planCommand($self, $cmd, %p) -- decides WHAT to do for a dispatch call
# and returns an ARRAY ref of intents; it performs NO I/O itself (no
# `$ws->sendCommand`, no `Slim::Utils::Timers::*`, no `$log->*`, no
# `_armSync`/`_postBoundary`/`_fireCbs`/`_recordErrorOnce` calls) -- every
# one of those becomes an intent for `_execute` to perform. Reads
# `pending`/`observed` exactly as `_dispatch` used to. %p: uri, position_ms
# (stored for idempotency comparisons; sent on the wire ONLY for 'seek' --
# 'play' never carries it in this plan), armed (82-19 F2: armed ->
# `_armSync`, ALWAYS, before the wire send; the `sync` channel marker and
# the async HTTP-client arm it selected between are gone -- an armed
# dispatch now sends synchronously on BOTH call sites, so
# observed.seekIssued is already written when onStream's requestTrack asks
# in the same LMS command; see 82-G1-MESSUNG.md ## Berichtigung 82-19 --
# Zuschreibung des Doppel-Seeks), awaitMeta (82-04: !defined duration at
# dispatch time -- successCb waits for noteDuration/T_meta instead of the
# echo alone), postSeek (82-04: a seek target to send once the echo
# confirms this uri -- RESEARCH Kante 3), volume (82-05: the target for
# 'set_volume', compared against pending.volume by onEvent's echo
# classification -- never a last-sent-value equality check), cb => {
# successCb => [...], errorCb => coderef|undef }.
#
# 82-09 (CR-02): an open `play`-pending with waiting callbacks (a
# getNextTrack in flight) is cleared by NOTHING except the track_changed
# echo, T1's timeout, a correlated error, or a transport loss -- never by
# a side command sent while it is open. `set_volume` and `pause` fold
# their target into the SAME slot (postVolume/postPause, consumed on the
# echo and in _t1Fire, same discipline as postSeek); every other command
# (add_to_queue/get_state/seek/...) is sent straight through via
# `_wireArgsFor`, updates `pending.lastSentCmd` (the WR-04 error-
# correlation fallback) and returns, without touching `pending` or the T1
# timer. `killTimers` on `_t1Fire` therefore only runs on the path that
# actually replaces the slot below -- moving it earlier would kill T1 out
# from under a folded side command (82-REVIEW.md CR-02).
#
# Intent vocabulary (hash refs, `op` key), performed only by `_execute`:
# `require_ws` (the WR-06 ws gate, emitted FIRST by every call below --
# 83.1-01 checker round 2: this is a per-CALL check, never a per-intent-
# list-item pre-check that could abort a deferral list that never asked
# for a dispatch at all -- see `_reconcilePlan`, 83.1-01 Task 2), `send`
# (cmd, wireArgs, cb, slot => the pending fields to establish, or undef
# for a fold-through side command that must not open a new slot; see
# `_execute`'s own header for its exact contract), `set` (a state mutation
# on `pending`/`observed`/an accessor `attr`: `target`, `key`, `value`, or
# `delete => 1`), `fire` (cb-hash + `which` + `args`, replacing inline
# `_fireCbs`), `timer` (`cb`, `at`, `args`), `killtimer` (`cb`), `log`
# (`level`, `text`).
sub _planCommand {
    my ($self, $cmd, %p) = @_;

    my @intents;
    # WR-06 (a gone/dead transport -- weak `daemon` collected, or `_ws`
    # momentarily undef on a respawn, see WR-02): this used to return 0
    # silently -- the caller got neither success nor error and
    # getNextTrack wedged forever. `_execute` fires the caller's own
    # errorCb so it sees the same failure shape as a send that fails
    # further down, BEFORE anything else in this list runs (checker round
    # 2: this sits exactly where `_dispatch`'s old ws-gone check sat --
    # before fold-through and before supersession).
    push @intents, { op => 'require_ws', cb => $p{cb} };

    my $prev = $self->pending;
    if ($prev && $prev->{cmd} eq 'play' && !($cmd eq 'play' && defined $p{uri})) {
        # FOLD-THROUGH: an open play-pending with waiting callbacks (a
        # getNextTrack in flight) absorbs a side command instead of a
        # second slot being opened (82-09 CR-02 above).
        if ($cmd eq 'set_volume') {
            push @intents, { op => 'set', target => 'pending', key => 'postVolume', value => $p{volume} };
            return \@intents;
        }
        if ($cmd eq 'pause') {
            # CR-02: a real Stop folded into an open play-pending must
            # survive to the replay -- without this, the replay's
            # `_reconcile('requestPause')` call has no way to know the
            # fold was a Stop, not a Pause, and its own statusIsPlaying
            # guard can silently swallow the pause on a stale
            # observed.status (Split-Brain, T-4).
            push @intents, { op => 'set', target => 'pending', key => 'postPause', value => 1 };
            push @intents, { op => 'set', target => 'pending', key => 'postPauseIsStop', value => 1 } if $p{isStop};
            # G3-MESS (82-20): H-F variant -- a pause folds silently into an
            # open play-pending with no "Control: dispatch" line otherwise.
            # DEBUG only, no behavior change.
            push @intents, { op => 'log', level => 'debug', text =>
                "SpotOn G3-INSTR: dispatch pause folded into pending play uri=" . ($prev->{uri} // '-')
                . " age=" . sprintf('%.3f', Time::HiRes::time() - ($prev->{sentAt} // Time::HiRes::time()))
            };
            return \@intents;
        }
        if ($cmd eq 'play') {
            # CR-01: das offene play uri IST der Resume -- nichts geht neu auf
            # die Leitung. Deckt das blanke `play` aus requestResume/
            # watchdogRing/Seek-Pfad(2) (kein `cb`, `_fireCbs` no-opt) UND den
            # Treffer-Zweig-Fall (`_reconcile` Zeile 979, `cb` gesetzt) ab --
            # dessen successCb feuert SOFORT, statt in `$prev->{cb}` gemergt
            # oder stillschweigend verloren zu werden.
            push @intents, { op => 'log', level => 'debug', text =>
                "SpotOn G3-INSTR: dispatch play folded into pending play uri=" . ($prev->{uri} // '-')
            };
            push @intents, { op => 'set', target => 'pending', key => 'postPause', delete => 1 };
            push @intents, { op => 'set', target => 'pending', key => 'postPauseIsStop', delete => 1 };
            push @intents, { op => 'fire', cb => $p{cb}, which => 'successCb', args => [] } if $p{cb};
            return \@intents;
        }
        # G1-MESS (82-15 Task 1): fold-through path -- a command folded
        # into an already-pending play (e.g. a second seek while
        # getNextTrack's play is still open) still reaches the wire here,
        # so it needs the same LMS-side clock as the slotted path below.
        # DEBUG only, no behavior change.
        push @intents, { op => 'set', target => 'pending', key => 'lastSentCmd', value => $cmd };
        push @intents, { op => 'log', level => 'debug', text =>
            "Control: dispatch $cmd armed=" . ($p{armed} ? 1 : 0)
            . " uri=" . ($p{uri} // '-') . " (" . ($self->mac // '?') . ")"
        };
        # 82-16 F1 (H-v bestaetigt): write side of the seekIssued bookkeeping
        # -- Fold-Through Sendeweg. See the Slot-Pfad write below for the
        # counterpart and _seekAlreadyIssued for the read side.
        push @intents, {
            op        => 'send',
            cmd       => $cmd,
            wireArgs  => [ _wireArgsFor($cmd, %p) ],
            slot      => undef,
            seekTarget=> ($cmd eq 'seek'
                ? { uri => $self->wanted->{uri}, position_ms => $p{position_ms} }
                : undef),
        };
        return \@intents;
    }

    # SLOT: establish a new pending. `_execute`'s `send` handler performs
    # the superseded-fire + `_t1Fire` killTimers + `pending({...})` set
    # itself, atomically with the wire attempt, whenever a `send` intent
    # carries `slot` data (T1/adjacency, T1/ordering -- 83.1-01 Task 3
    # Fall-14 exercises this directly against `_execute`).
    my $cb = $p{cb} || {};
    $cb->{successCb} ||= [];

    # G1-MESS (82-15 Task 1): the ONE LMS-side clock every actually-sent
    # command runs through, exactly one line per command (before the arm,
    # not after -- H-iii asks whether an arm this line names ever landed
    # at the daemon). DEBUG only, no behavior change.
    push @intents, { op => 'log', level => 'debug', text =>
        "Control: dispatch $cmd armed=" . ($p{armed} ? 1 : 0)
        . " uri=" . ($p{uri} // '-')
        . (defined $p{wireCmd} ? " via=$p{wireCmd}" : '')    # 84-19: the wire command differs from the slot's
        . " (" . ($self->mac // '?') . ")"
    };

    push @intents, {
        op         => 'send',
        cmd        => $cmd,
        # 84-19 F-18-N4 change 2: what actually goes on the wire when it
        # differs from the slot's `cmd` (a `play` slot consumed by
        # `skip_next`); the send gate, the slot and every echo test keep
        # reading `cmd`.
        wireCmd    => $p{wireCmd},
        wireArgs   => [ _wireArgsFor($cmd, %p) ],
        cb         => $cb,
        # The exact fields `_dispatch` used to write at its
        # `$self->pending({...})` site -- `cmd`, `sentAt`, `lastSentCmd`
        # and `cb` are filled in by `_execute` itself (`sentAt` is an
        # EXECUTOR-side fact: the moment of the actual send, not a
        # planner decision).
        slot       => {
            uri         => $p{uri},
            position_ms => $p{position_ms},
            volume      => $p{volume},
            armed       => $p{armed} ? 1 : 0,
            awaitMeta   => $p{awaitMeta} ? 1 : 0,
            postSeek    => $p{postSeek},
        },
        # Pitfall 2 (82-19 F2): onStream has no callback and $player->play
        # follows in the SAME loop (StreamingController.pm:1311-1327) -- an
        # async arm would run behind the GET (78-UAT-10 signature). This is
        # the ONLY arm path, on BOTH call sites (Schritt 4 AND Seek-Pfad
        # (2)) -- see `_armSync`'s own comment block for the tradeoff this
        # collapse brings and why it is accepted. Degrade-open either way
        # (T-77-10).
        armed      => $p{armed} ? 1 : 0,
        # 82-16 F1 (H-v bestaetigt): write side of the seekIssued
        # bookkeeping -- Slot-Pfad Sendeweg (see the Fold-Through write
        # above for the counterpart). Recorded on the WIRE uri
        # (self->wanted->{uri}: %p never carries uri for a 'seek'
        # dispatch), so _seekAlreadyIssued's read side compares against
        # the same target the two call sites (Schritt 4, Seek-Pfad (2))
        # themselves compare against.
        seekTarget => ($cmd eq 'seek'
            ? { uri => $self->wanted->{uri}, position_ms => $p{position_ms} }
            : undef),
        # Wait for the track_changed echo (or T1's timeout release) --
        # getNextTrack must never wedge (T-77-10).
        armT1      => ($cmd eq 'play' && defined $p{uri}) ? 1 : 0,
        # Bare resume / seek: command_result is not a state change (D-B
        # Gegenargument, Note §2.2 -- it reaches only the sender and is
        # not a track transition worth waiting on). `set_volume` waits for
        # the volume_changed echo instead (D-06) -- pending stays set so
        # onEvent can classify it by target match, same discipline as
        # play/track_changed; no LMS-side caller waits on this
        # (requestVolume takes no cb) so no T1-style timeout is needed: a
        # lost echo just means the NEXT volume_changed, if any, is read as
        # a fresh value instead of an echo -- never a wedge.
        onSuccessBare => (($cmd eq 'play' && defined $p{uri}) || $cmd eq 'set_volume') ? 0 : 1,
    };

    return \@intents;
}

# _deepCopy($val) -- recursive HASH/ARRAY duplication for `_execute`'s
# snapshot (D-02). Coderefs and blessed objects are returned BY IDENTITY
# (shallow) -- only the hash/array structure `pending`/`observed` are ever
# built from needs duplicating; a `cb`'s coderefs must stay the exact
# instance the caller passed in.
sub _deepCopy {
    my ($val) = @_;
    return $val unless ref $val;
    if (ref($val) eq 'HASH') {
        return { map { $_ => _deepCopy($val->{$_}) } keys %$val };
    }
    if (ref($val) eq 'ARRAY') {
        return [ map { _deepCopy($_) } @$val ];
    }
    return $val;
}

# _execute($self, $intents) -- the ONE place in this module that ever
# calls `$ws->sendCommand` (via the `$wireSend` closure below, so the
# literal call site stays singular even once 83.1-01 Task 2 adds the
# `probe` op alongside `send`). D-02: takes a snapshot of `pending` and
# `observed` LAZILY, before the first intent that actually touches state
# (a list of only `require_ws`/`log` intents -- and `_execute([])` itself,
# T1/boundary -- takes no snapshot at all), and restores it if a `send`
# intent that carries `slot` data (i.e. one that establishes a NEW pending
# -- 83-CONTEXT.md D-02's own measurement is scoped to exactly this path:
# "der Ausfuehrer verwirft den Vorgaenger-Callback ... alles bevor
# feststeht, ob sendCommand gelingt") fails to send: `pending`/`observed`
# return to their pre-execution values, every timer THIS execution armed
# is killed, every timer THIS execution killed is re-armed with its
# original deadline/args, and the caller's own errorCb fires -- never
# leaves `pending` empty-but-different-from-before (D-02). A fold-through
# send (no `slot`) keeps `_dispatch`'s original, narrower failure contract
# unchanged: it just returns 0, no rollback, no callback (HEAD never fired
# one there either).
#
# Intents execute STRICTLY in list order -- never reordered, deduped or
# merged (T1/ordering).
sub _execute {
    my ($self, $intents) = @_;
    $intents ||= [];
    return 1 unless @$intents;

    my $snapshot;
    my $takeSnapshot = sub {
        return if $snapshot;
        $snapshot = {
            pending  => _deepCopy($self->pending),
            observed => _deepCopy($self->observed),
        };
    };

    # Timer bookkeeping for THIS execution only, diffed against the
    # object-level `_timerRegistry` (D-02's "die armierten Timer" --
    # persists across calls so a killed timer's pre-kill deadline/args are
    # still known here even though `Slim::Utils::Timers` itself keeps no
    # such index).
    my %armedHere;    # refaddr(cb) => cb -- timers armed during this execution
    my %killedHere;   # refaddr(cb) => [cb, at, args] -- pre-existing timers killed during this execution

    my $doSetTimer = sub {
        my ($cb, $at, $args) = @_;
        $args ||= [];
        Slim::Utils::Timers::setTimer($self, $at, $cb, @$args);
        my $key = refaddr($cb);
        $self->_timerRegistry->{$key} = [ $cb, $at, $args ];
        $armedHere{$key} = $cb;
        delete $killedHere{$key};
    };
    my $doKillTimer = sub {
        my ($cb) = @_;
        my $key     = refaddr($cb);
        my $existed = delete $self->_timerRegistry->{$key};
        Slim::Utils::Timers::killTimers($self, $cb);
        if ($existed && !$armedHere{$key}) {
            $killedHere{$key} = $existed;
        }
        delete $armedHere{$key};
    };

    my $rollback = sub {
        return unless $snapshot;
        $self->pending(_deepCopy($snapshot->{pending}));
        $self->observed(_deepCopy($snapshot->{observed}));
        for my $key (keys %armedHere) {
            Slim::Utils::Timers::killTimers($self, $armedHere{$key});
            delete $self->_timerRegistry->{$key};
        }
        %armedHere = ();
        for my $key (keys %killedHere) {
            my (undef, $at, $args) = @{ $killedHere{$key} };
            my $cb = $killedHere{$key}[0];
            Slim::Utils::Timers::setTimer($self, $at, $cb, @$args);
            $self->_timerRegistry->{$key} = [ $cb, $at, $args ];
        }
        %killedHere = ();
    };

    # The ONE textual wire-send call site (D-02's must_have) -- both
    # `send` and (83.1-01 Task 2) `probe` call through this closure rather
    # than writing `$ws->sendCommand(` a second time.
    my $wireSend = sub {
        my ($ws, $cmd, @wireArgs) = @_;
        return $ws->sendCommand($cmd, @wireArgs);
    };

    for my $intent (@$intents) {
        my $op = $intent->{op} // '';

        if ($op eq 'require_ws') {
            # WR-06: fire the caller's own errorCb so it sees the same
            # failure shape as a send that fails further down -- no
            # snapshot needed, nothing has mutated yet.
            unless ($self->daemon && $self->daemon->_ws) {
                $self->_fireCbs($intent->{cb}, 'errorCb', 'PROBLEM_OPENING', 'Soloist daemon gone');
                return 0;
            }
        }
        elsif ($op eq 'send') {
            # inaktiver-player-steuert-fern (user decision A, 2026-09-25):
            # THE send gate, at the one place every state-changing command
            # passes. A daemon that is not the account's active device
            # executes these as Connect REMOTE control of the active device
            # (measured: pause, seek + resume, play -> track change) and
            # acks them like local ones -- so while the daemon says it is
            # inactive, nothing but the read-only queries and the take-over
            # itself goes out (requestTrack takes the session over first,
            # _planTakeover). Checked BEFORE the slot/arm bookkeeping: a
            # gated command opens no pending, arms nothing, starts no T1.
            # A slotted caller's errorCb fires so nothing LMS-side wedges.
            if ($self->_knownInactive && !_sendableWhileInactive($intent->{cmd})) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: not the active Spotify device -- " . ($intent->{cmd} // '?')
                    . " not sent (it would steer the active device) (" . ($self->mac // '?') . ")"
                );
                $self->_fireCbs($intent->{cb}, 'errorCb', 'PROBLEM_OPENING', 'not the active Spotify device')
                    if $intent->{slot};
                next;
            }

            $takeSnapshot->();

            my $cmd      = $intent->{cmd};
            my $wireArgs = $intent->{wireArgs} || [];
            my $cb       = $intent->{cb};
            my $slot     = $intent->{slot};
            my $ws       = $self->daemon && $self->daemon->_ws;

            # 83.1-REVIEW.md WR-02: capture (but do not yet FIRE) the
            # predecessor's supersession -- deferred until the wire attempt
            # below is known to have succeeded. Firing errorCb('superseded')
            # here unconditionally told the predecessor it lost its slot
            # even when the send then failed and rollback put it right back
            # as pending -- a later T1 fire or track_changed echo then fired
            # its successCb too, breaking the single-fire contract.
            my $superseded;
            if ($slot) {
                # Slot-establishing send: supersede any still-open
                # play-pending (its callbacks are released with
                # PROBLEM_OPENING/superseded rather than silently dropped),
                # kill its T1 timer, then take this slot -- T1/adjacency:
                # two slot sends in one list supersede in list order.
                my $prev = $self->pending;
                $superseded = ($prev && $prev->{cmd} eq 'play') ? $prev->{cb} : undef;
                $doKillTimer->(\&_t1Fire);
                $self->pending({
                    %$slot,
                    cmd         => $cmd,
                    sentAt      => Time::HiRes::time(),
                    lastSentCmd => $cmd,
                    cb          => $cb,
                });
                if ($intent->{armed}) {
                    $self->_armSync;
                }
            }

            my $ok = $ws ? $wireSend->($ws, ($intent->{wireCmd} // $cmd), @$wireArgs) : 0;

            unless ($ok) {
                if ($slot) {
                    $log->warn("Control: arm-leak -- $cmd send failed after arm (" . ($self->mac // '?') . ")")
                        if $intent->{armed};
                    # 82-23 WR-04: a wire-level send failure is its own
                    # errors[] candidate, distinct from
                    # t1/daemon-error/transport -- the command never even
                    # reached the daemon. A2 (named, not implemented): no
                    # _clearErrorOnce counterpart in this plan -- see
                    # SUMMARY.
                    # 83.1-REVIEW.md WR-01: rollback FIRST, then record --
                    # rollback() replaces self->observed wholesale with the
                    # pre-execution snapshot; recording before it erased the
                    # observed->{errorsReported}{"send:$cmd"} dedupe lock
                    # this call just wrote, so every failed slot send on a
                    # half-open socket appended a fresh Status ring entry
                    # instead of deduping like every other _recordErrorOnce
                    # call site.
                    $rollback->();
                    $self->_recordErrorOnce('send:' . $cmd, 'warn',
                        "Soloist send failed: $cmd (" . ($self->mac // '?') . ")");
                    $self->_fireCbs($cb, 'errorCb', 'PROBLEM_OPENING', 'Soloist daemon send failed');
                }
                return 0;
            }

            # WR-02: the send succeeded -- only NOW is it safe to tell the
            # predecessor it lost its slot. Its errorCb has not fired yet,
            # rollback never ran, and this new slot is the one now on the
            # wire (single-fire contract preserved either way).
            $self->_fireCbs($superseded, 'errorCb', 'PROBLEM_OPENING', 'superseded') if $superseded;

            if ($intent->{seekTarget}) {
                $self->observed->{seekIssued} = {
                    %{ $intent->{seekTarget} },
                    at => Time::HiRes::time(),
                };
            }

            if ($slot) {
                if ($intent->{armT1}) {
                    $doSetTimer->(\&_t1Fire, Time::HiRes::time() + (T1_TRACK_CHANGED_MS / 1000), []);
                }
                elsif ($intent->{onSuccessBare}) {
                    $self->_fireCbs($cb, 'successCb');
                    $self->pending(undef);
                }
            }
        }
        elsif ($op eq 'set') {
            my $target = $intent->{target} // 'pending';
            if ($target eq 'attr') {
                my $key = $intent->{key};
                $self->$key($intent->{delete} ? undef : $intent->{value});
                next;
            }
            $takeSnapshot->();
            if (!defined $intent->{key}) {
                $self->pending($intent->{value})  if $target eq 'pending';
                $self->observed($intent->{value}) if $target eq 'observed';
                next;
            }
            my $h = $target eq 'observed' ? $self->observed : $self->pending;
            if ($h) {
                if ($intent->{delete}) { delete $h->{ $intent->{key} }; }
                else                    { $h->{ $intent->{key} } = $intent->{value}; }
            }
        }
        elsif ($op eq 'fire') {
            $self->_fireCbs($intent->{cb}, $intent->{which}, @{ $intent->{args} || [] });
        }
        elsif ($op eq 'timer') {
            $doSetTimer->($intent->{cb}, $intent->{at}, $intent->{args} || []);
        }
        elsif ($op eq 'killtimer') {
            $doKillTimer->($intent->{cb});
        }
        elsif ($op eq 'log') {
            my $level = $intent->{level} // 'debug';
            if ($level eq 'debug') {
                $log->debug($intent->{text}) if main::DEBUGLOG && $log->is_debug;
            }
            elsif ($level eq 'warn') { $log->warn($intent->{text}); }
            elsif ($level eq 'info') { $log->info($intent->{text}); }
        }
        elsif ($op eq 'error') {
            $self->_recordErrorOnce($intent->{key}, $intent->{level}, $intent->{message});
        }
        elsif ($op eq 'clearerror') {
            $self->_clearErrorOnce($intent->{key});
        }
        elsif ($op eq 'probe') {
            # T1/probe (checker round 2): the SAME `sendCommand(` line as
            # `send` (via `$wireSend`), result ignored, no snapshot, no
            # rollback, no callback -- the list continues either way. The
            # send and the optional stamp sit inside ONE `if (my $ws = ...)`
            # conditional, mirroring HEAD's `_reconcile` Schritt 2 line for
            # line: no ws -> no send AND no stamp (Vorab Fall-A pins this;
            # an unconditional stamp would consume the AUTH_REPROBE_S rate
            # limit on the ws-undef path where HEAD does not -- Vorab
            # Fall-A's negative assertion, Fall-C's positive one).
            # inaktiver-player-steuert-fern: same gate as `send` above --
            # a probe only ever carries get_auth_state/activate today, so
            # this is a defensive line against a future state-changing probe.
            next if $self->_knownInactive && !_sendableWhileInactive($intent->{cmd});
            if (my $ws = $self->daemon && $self->daemon->_ws) {
                $wireSend->($ws, $intent->{cmd}, @{ $intent->{wireArgs} || [] });
                if (my $stamp = $intent->{stamp}) {
                    my $attr = $stamp->{attr};
                    $self->$attr($stamp->{value});
                }
            }
        }
        elsif ($op eq 'arm') {
            $self->_armSync;
        }
        elsif ($op eq 'boundary') {
            $self->_postBoundary;
        }
        elsif ($op eq 'fail') {
            # `_reconcilePlan`'s early-return-0 branches (Schritt 1/2's
            # non-requestTrack terminal path, Schritt 5's drift-exhausted
            # path) signal "return 0 without a send" this way -- whatever
            # `fire`/`error` intents precede this one in the list have
            # already run.
            return 0;
        }
        else {
            $log->warn("Control: _execute unknown intent op '$op' (" . ($self->mac // '?') . ")");
        }
    }

    return 1;
}

# _dispatch($self, $cmd, %p) -- D-01: thin wrapper, kept for all ~40
# existing call sites. See `_planCommand`'s header above for the intent
# vocabulary and `_execute`'s header for the executor/rollback contract.
sub _dispatch {
    my ($self, $cmd, %p) = @_;
    return $self->_execute($self->_planCommand($cmd, %p));
}

# _fireCbs($self, $cb, $which, @args) -- internal helper, fires either every
# queued successCb (idempotency can queue more than one caller) or the
# single errorCb.
sub _fireCbs {
    my ($self, $cb, $which, @args) = @_;
    return unless $cb;

    if ($which eq 'successCb') {
        for my $cbRef (@{ $cb->{successCb} || [] }) {
            $cbRef->() if $cbRef;
        }
    }
    elsif ($which eq 'errorCb') {
        $cb->{errorCb}->(@args) if $cb->{errorCb};
    }
}

# _t1Fire($self) -- T1_TRACK_CHANGED_MS timeout: if track_changed never
# arrives after a play, release successCb anyway so getNextTrack never
# wedges (T-77-10). The daemon-side arm (if any) stays valid for its own
# 3000ms TTL regardless -- this only stops LMS from waiting on it.
sub _t1Fire {
    my $self = shift;

    my $pending = $self->pending or return;
    return unless $pending->{cmd} eq 'play';

    # WR-01 (82-REVIEW.md): save the expectation BEFORE pending is cleared
    # below -- a track_changed echo that arrives after this timeout is
    # still OUR echo, just late (S-03: 3 measurements between 112-161ms;
    # T1 is set from a 3-sample distribution, so a slower echo under load
    # or after a reconnect is not exotic). Without this, onEvent's echo
    # branch below no longer recognizes the target once `pending` is gone
    # and runs the FOREIGN-track path instead: it plants a boundary on the
    # own freshly-started stream and increments _driftCount, which after
    # three such late-but-correct echoes made the title permanently
    # unplayable via DRIFT_MAX_REDISPATCH (82-REVIEW.md WR-01). Only for a
    # `play` with a defined uri -- nothing else has an echo to expect.
    if (defined $pending->{uri}) {
        $self->observed->{expectEcho} = {
            uri         => $pending->{uri},
            until       => Time::HiRes::time() + LATE_ECHO_WINDOW_S,
            # 79-33 (D-28 F2): the released play's position, so _reconcilePlan
            # absorbs only an onStream twin for the SAME position.
            position_ms => $pending->{position_ms} // 0,
        };
    }

    my $msg = "Control: no track_changed within " . T1_TRACK_CHANGED_MS
        . "ms after play " . ($pending->{uri} // '?') . " (" . ($self->mac // '?') . ") -- releasing successCb";
    # T1 is a documented validity boundary, not an error path: a seek on an
    # unconfirmed title would hit the OLD track, so a pending postSeek is
    # dropped (never sent) rather than fired blind -- name it in the log.
    $msg .= " (dropping postSeek " . $pending->{postSeek} . ")" if defined $pending->{postSeek};
    $log->warn($msg);
    # 82-23 WR-04: T1 timeout is a genuine errors[] candidate -- the
    # daemon never confirmed a play we asked for. Only for a `play` with
    # a defined uri (same guard as the expectEcho block above -- nothing
    # else has an echo to expect, hence no timeout to report per-uri).
    $self->_recordErrorOnce('t1:' . $pending->{uri}, 'warn', $msg) if defined $pending->{uri};

    my $postVolume     = $pending->{postVolume};
    my $postPause      = $pending->{postPause};
    my $postPauseIsStop = $pending->{postPauseIsStop};
    # 79-33 (D-28 F1, LABELS-SKIP): clear pending BEFORE the released successCb
    # runs (the echo branch's order). The successCb starts LMS's synchronous
    # chain (_Stream -> Song::open -> onStream -> requestTrack); with the old
    # order that chain saw this play still pending, treated it as superseded
    # and fired its errorCb('PROBLEM_OPENING', 'superseded'), so LMS marked
    # the title failed and skipped it (79-R3-FORENSICS.md Part B).
    my $releasedCb = $pending->{cb};
    $self->pending(undef);
    $self->_fireCbs($releasedCb, 'successCb');

    # Unlike postSeek, a folded volume push (Task 6) does not target a
    # specific track -- it is safe to still apply after T1's timeout,
    # where dropping postSeek would risk hitting the wrong title. CR-04:
    # force -- the guard already ran when the ORIGINAL play was accepted.
    $self->requestVolume($postVolume, { force => 1 }) if defined $postVolume;

    # 82-09 (CR-02): a folded pause is never replayed as a stored raw
    # command -- it is re-decided via _reconcile against whatever observed
    # says NOW (same idempotency discipline as postVolume/requestVolume).
    # wanted.playing is already 0 (set by the original requestPause call
    # that folded it), so this only needs to catch the daemon up if it
    # still reports playing. 82-22 CR-02: a folded Stop must dispatch its
    # `pause` unconditionally, regardless of a stale observed.status --
    # isStop rides along the same replay call the Pause case already used.
    $self->_reconcile('requestPause', { isStop => $postPauseIsStop }) if $postPause;
}

# _wsRetryTimeout($self) -- 82-42 Task C: TTL fallback for a requestTrack
# deferred by _reconcile Schritt 1 (wsConnected still false at the time).
# Mirrors _t1Fire's shape (above): if the deferral is STILL pending when
# the timer fires, resolve it with the SAME immediate-failure error text
# _reconcile used to fire synchronously before this plan -- getNextTrack/
# onStream must never wedge indefinitely (T-77-10), the TTL is the bound.
sub _wsRetryTimeout {
    my $self = shift;

    my $deferred = $self->_deferredTrackRequest or return;
    $self->_deferredTrackRequest(undef);

    # 82-42-PLAN.md Task B, Frage 2 ("ttl-visible"): a silent Step-1 return
    # is exactly the defect get-state-statt-play.md documents as the root
    # cause of nine failed measurement rounds -- _reconcile Schritt 1 never
    # called _recordErrorOnce, so a wedged/never-ready daemon was invisible
    # in Soloist's own errors[] ring even though LMS' own, separate
    # StreamingController log carried a NextTrackError line for it. Make
    # the TTL expiry itself visible here, on the same ring the rest of this
    # module already reports through (82-23 convention).
    $self->_recordErrorOnce('ws-retry:' . ($deferred->{uri} // '?'), 'warn',
        ($self->mac // '?') . ": deferred requestTrack for " . ($deferred->{uri} // '?')
        . " timed out after " . WS_RETRY_TTL_S . "s (Soloist daemon never became ready)");

    $self->_fireCbs($deferred->{opts}, 'errorCb', 'PROBLEM_OPENING', 'Soloist daemon not ready');
}

# _tMetaFire($self) -- T_META_MS timeout: the echo confirmed the title but
# its length still had not arrived (Befund 2 cache-miss path, D-04 "Laenge
# nachziehen"). Releases successCb (unless noteDuration already fired first
# and cleared _awaitMeta) -- getNextTrack must never wedge on a slow/failed
# metadata fetch (T-77-10).
#
# 85-07 D-11: this timer deliberately does NOT touch seek state. A local
# timer cannot tell "slow" from "never" (it fires 28.5 s before the fetch's
# own timeout can), and writing an explicit seekable=0 here cost a title its
# seek until some later fetch happened to land. Until the length is known
# `seekable` already answers 0 (no duration -> no trusted restart target),
# and noteDuration turns it on the moment the length arrives. The only thing
# that fails seek closed on purpose is a real HTTP 404 from spclient
# (noteMetadataMissing, sent by ProtocolHandler).
sub _tMetaFire {
    my $self = shift;

    my $await = $self->_awaitMeta or return;
    $self->_awaitMeta(undef);

    $self->_fireCbs($await->{cb}, 'successCb');
}

# _releaseAwaitMeta($self, $reason) -- 82-09 (WR-03): `shutdown` and
# `_transportClosed` used to leave `_awaitMeta` and its `_tMetaFire` timer
# standing after tearing everything else down -- a successCb waiting on
# noteDuration/T_meta then fired as a SUCCESS up to T_META_MS after the
# daemon was gone, and getNextTrack opened a stream against an abandoned
# daemon. That is worse than an error: it LOOKS like success. Safe to call
# unconditionally, even with nothing waiting (a no-op then).
sub _releaseAwaitMeta {
    my ($self, $reason) = @_;

    Slim::Utils::Timers::killTimers($self, \&_tMetaFire);

    if (my $await = $self->_awaitMeta) {
        $self->_fireCbs($await->{cb}, 'errorCb', 'PROBLEM_OPENING', $reason);
        $self->_awaitMeta(undef);
    }
}

# _ownActivation($self) -- G2-G3 (82-17): is an incoming
# device_changed(is_active:true) an echo of OUR OWN just-issued `play`, not
# a real transfer from the Spotify app? Classified by target match against
# three independent sources -- pending/expectEcho/observed.track -- the
# same discipline as the track_changed echo branches above (Pitfall 4:
# never a time window alone). Only ever consulted while mode is 'browse'
# (a device_changed while already 'connect' or still 'idle' is untouched --
# the Connect POLICY itself and the idle->connect transfer are Phase 83 /
# 82-03 and stay exactly as they were).
#
# Live evidence (see <objective> for the full trace): Lauf 1 18:05:26.493 --
# an empty-item playback_state frame lands in the SAME millisecond as
# device_changed, a full 81ms BEFORE the track_changed echo for the
# requested title arrives at .574; Lauf 3 18:24:25.191/.2325 -- same
# mechanism, the title happened to already match so only the mode (not the
# displayed title) was wrong; the two Connect-column volume-forwarding
# lines at 18:25:06/18:50:15 that followed once mode was wrongly latched to
# 'connect'.
#
# Documented boundary: an auto-advance Z of a PREVIOUS session that arrives
# between T1's timeout and our own echo, followed by a device_changed
# BEFORE our echo lands, is read as a real transfer (Fall D' in
# t/44_soloist_control.t) -- expectEcho.displacedBy (set by the foreign
# track_changed path below) is what tells criterion (2) apart from that
# case. Measured order in Laeufe 1 and 3 was device_changed arriving in the
# SAME millisecond as the first frame of our own title; the reverse order
# is the theoretical one this boundary describes, not a measured one.
# _ownActivationAt($wanted, $observed, $pending, $mode, $now, $lmsPlaysOurs)
# -- D-03: the pure decision body of `_ownActivation`, extracted so
# `_classify` (no `$self`) can decide the `device_changed(is_active:true)`
# row through the SAME logic, never by reading the wall clock itself.
sub _ownActivationAt {
    my ($wanted, $observed, $pending, $mode, $now, $lmsPlaysOurs) = @_;

    return 0 unless $mode eq 'browse';

    # (1) An own `play` is still open (the daemon has not echoed it yet).
    return 1 if $pending && $pending->{cmd} eq 'play' && defined $pending->{uri};

    # (2) A late-echo expectation for the CURRENTLY wanted uri is still
    # open (T1 already released `pending`, WR-01/82-12) -- but only while
    # nothing has displaced it (a foreign track_changed in the meantime,
    # Fall D').
    my $expectEcho = $observed->{expectEcho};
    if ($expectEcho && defined $expectEcho->{uri} && defined $wanted->{uri}
        && $expectEcho->{uri} eq $wanted->{uri}
        && defined $expectEcho->{until} && $expectEcho->{until} > $now
        && !defined $expectEcho->{displacedBy})
    {
        return 1;
    }

    # (3) The daemon already reports the wanted uri (the echo settled
    # through some other path -- e.g. a Treffer-Zweig, or the pending-echo
    # branch already ran for this same uri) -- but only while LMS is
    # ACTUALLY playing our material (84.1 D-03, todo
    # control-bleibt-in-browse-nach-browse-lauf). After an LMS stop the
    # same observed.track == wanted.uri is just the daemon still parked on
    # the title -- a device_changed(is_active:1) then is the app's
    # transfer, not our own echo.
    my $track = $observed->{track};
    return 1 if $lmsPlaysOurs && defined $track && defined $wanted->{uri} && $track eq $wanted->{uri};

    return 0;
}

sub _ownActivation {
    my $self = shift;
    return _ownActivationAt($self->wanted, $self->observed, $self->pending, $self->mode,
        Time::HiRes::time(), $self->_lmsPlaysOurs);
}

# _lmsPlaysOurs($self) -- 84.1 D-03: is LMS actually playing our own
# material right now? Shared by _ownActivation and onEvent's _classify
# call site so both consult the SAME expression. Never a time window
# (Pitfall 4) -- LMS playmode plus song ownership, read fresh each call.
sub _lmsPlaysOurs {
    my $self = shift;
    my $client = Slim::Player::Client::getClient($self->mac);
    return ($client && (Slim::Player::Source::playmode($client) // '') eq 'play'
        && $self->_lmsSongIsOurs) ? 1 : 0;
}

# onEvent($self, $msg) -- the transport hands this the already-decoded HASH
# for every WS frame (SoloistWS::_onMessage's onEvent seam). Every branch is
# hardened against non-HASH payloads and missing fields -- this must never
# die on a frame from t/fixtures/soloist/ (T-82-01/T-82-03).
#
# Phase 82-03: the Connect column of the mode table is added here 1:1 from
# SoloistWS.pm's `_onAuthState`...`_emitAllowed` (sessionActive/
# sessionStarted/deactivating -> observed.is_active/startEmittedFor/mode) --
# it is **verlagert, nicht struktuell abgeloest**: the Connect POLICY itself
# (D-A(2) pertrack song model, the `_sendControlCommand` WS branch) is
# Phase 83 and is not pulled forward here. Gegenbefund mitgefuehrt: § S-07
# found 3/10 measured track boundaries faulty (2/10 permanently stalled) --
# Control must never treat a `track_changed` frame as a progress guarantee.
# Loglevel-Grenze (RESEARCH "Was die Phase-81-Messungen fuer den Plan
# festlegen"): `server.log` carries zero `getNextTrack` lines at Standard-
# Loglevel (0 hits in the whole log since 2026-09-02) -- log absence is
# NEVER evidence of anything at Standard-Loglevel; only `observed`, the
# recorder trace and the status endpoint count as proof.
#
# 83.1-01 (D-01/D-03): the ten frame-type branches this function used to
# hold inline (941 lines, RESEARCH 1.2) are now their own `_onFrame*`
# methods, reached via `%FRAME_HANDLERS`. This function keeps the shared
# preamble (wsConnected/lastEventAt bookkeeping, the non-HASH/undef-type
# guards -- T-82-01/T-82-03, T1/empty) and now ALSO classifies every valid
# frame once via `_classify` (D-03: a TOTAL function, `unknown` for
# anything outside the ten known types) before dispatching -- the class is
# stored in `observed->{lastClass}` (read by nobody yet; plans 02-06 use
# it) but does not yet change which branch decides (null measurement: the
# ten handlers below keep deciding by their own pre-existing conditions).
# An `unknown` type writes exactly one warn line naming type/mode/wanted/
# observed/pending so no frame falls through silently, and returns without
# dispatching (there is no handler to dispatch to).
# _trackIdOf($uri) -- D-01 duplicate fold: the bare track/episode ID
# extraction repeated across track_changed/playback_state/device_changed
# (prevId/newId/tid/trackId locals) -- returns undef on no match, same as
# each former inline `my ($id) = $uri =~ /.../ ;` idiom.
sub _trackIdOf {
    my ($uri) = @_;
    return undef unless defined $uri;
    my ($id) = $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/;
    return $id;
}

# _anchorPosSec($anchor) -- D-01 duplicate fold: the anchor-to-seconds
# formatting repeated in playback_changed's resume block and
# device_changed's reactivation block (`$posSec`).
sub _anchorPosSec {
    my ($anchor) = @_;
    return ($anchor && defined $anchor->{position_ms})
        ? sprintf('%.3f', $anchor->{position_ms} / 1000) : '0.000';
}

# ---------------------------------------------------------------------------
# 84-14 (D-06 workaround): transfer-in entry position.
#
# The Soloist daemon (a Spotify binary) can enter a transferred title at a
# figure that is not the app's position (84-14 M1: 3.62 s while the app was at
# 47.17 s; M3: 6.97 s vs 45.87 s; 84-01 120305: 15.53 s vs 46.7 s). The wrong
# figure is the daemon's own, reported as position_sync after the new-item
# reset and BEFORE device_changed, i.e. before SpotOn sends any command; its
# origin (stale transfer state vs daemon memory of the title) is an open item
# (84-ENTRY-ATTRIBUTION.md). SpotOn cannot change that, but it knows the
# position the app had -- the last real frame before the reset -- and corrects
# the daemon with exactly ONE seek when the entry is off by more than
# ENTRY_TOLERANCE_MS. Never a seek to 0 or to an unknown position (82-24).
# ---------------------------------------------------------------------------

# _captureEntryAnchor($self, $posMs) -- remember the last real position before
# a new-item reset frame (position < 1 s after a real position >= 5 s).
sub _captureEntryAnchor {
    my ($self, $posMs) = @_;
    my $priorAnchor = $self->observed->{anchor};
    if (defined $posMs && $posMs < 1000
        && $priorAnchor && defined $priorAnchor->{position_ms} && $priorAnchor->{position_ms} >= 5000
        && (time() - ($priorAnchor->{seen_at} // 0)) <= ENTRY_ANCHOR_MAX_AGE_S)
    {
        $self->observed->{entryAnchor} = {
            position_ms => $priorAnchor->{position_ms},
            seen_at     => $priorAnchor->{seen_at},
            seen_hr     => $priorAnchor->{seen_hr},
            speed       => $priorAnchor->{speed},
            reset_hr    => Time::HiRes::time(),
        };
    }
}

# _capturePreResetAnchor($self, $posMs, $speed, $ts) -- 84.2-02 (D-15): called
# by both observed.anchor writers right before the overwrite (the
# _captureEntryAnchor idiom, without its age/5000 ms gates -- the daemon's
# position ticker is not reliable: off-1 sent no frame for the last 11.6 s,
# run7 none for 113 s). When the incoming frame is a reset (position <=
# CONTEXT_END_RESET_MS, no speed) and the current anchor still holds a real
# position, that anchor is copied with the reset frame's timestamp_ms. A
# second reset frame finds an anchor at 0 and leaves the first copy
# standing. The copy keeps the anchor's uri tag: at a late pick (B7 07:48,
# Africa paused at 292333, then 6d0c starts at 0) the copy is Africa's and
# never reads 6d0c as near its end.
sub _capturePreResetAnchor {
    my ($self, $posMs, $speed, $ts) = @_;
    return unless defined $posMs && $posMs <= CONTEXT_END_RESET_MS && !$speed;
    my $a = $self->observed->{anchor};
    return unless ref($a) eq 'HASH' && defined $a->{position_ms} && $a->{position_ms} > CONTEXT_END_RESET_MS;
    $self->observed->{preResetAnchor} = {
        position_ms  => $a->{position_ms},
        speed        => $a->{speed},
        timestamp_ms => $a->{timestamp_ms},
        seen_hr      => $a->{seen_hr},
        uri          => $a->{uri},
        reset_ts     => $ts,
        reset_hr     => Time::HiRes::time(),
    };
    return;
}

# _nearTitleEnd($self, $uri) -- 84.2-02 (D-15), pure: 1 when the pre-reset
# anchor of $uri, carried forward along the daemon's clock (timestamp_ms;
# wall clock as a fallback) when it was moving, lies within
# CONTEXT_END_NEAR_MS of the known duration; else 0. An anchor of another
# uri, an unknown duration or no capture -> 0. No upper bound by design: a
# stale speed-1 anchor means the daemon kept playing.
sub _nearTitleEnd {
    my ($self, $uri) = @_;
    my $pre = $self->observed->{preResetAnchor};
    return 0 unless ref($pre) eq 'HASH' && defined $uri && defined $pre->{uri} && $pre->{uri} eq $uri;
    my $meta = $self->observed->{meta};
    my $dur  = (ref($meta) eq 'HASH' && ref($meta->{$uri}) eq 'HASH') ? $meta->{$uri}{duration} : undef;
    return 0 unless defined $dur && $dur > 0;
    my $pos = $pre->{position_ms};
    return 0 unless defined $pos;
    if (($pre->{speed} // 0) > 0) {
        my $carry = (defined $pre->{reset_ts} && defined $pre->{timestamp_ms})
            ? $pre->{reset_ts} - $pre->{timestamp_ms}
            : (defined $pre->{reset_hr} && defined $pre->{seen_hr})
                ? ($pre->{reset_hr} - $pre->{seen_hr}) * 1000
                : 0;
        $pos += $carry if $carry > 0;
    }
    return ($pos >= $dur * 1000 - CONTEXT_END_NEAR_MS) ? 1 : 0;
}

# _maybeContextEnd($self) -- 84.2-02 (D-15, D-16, D-01): the context-end
# carrier, at the onEvent tail. Under Autoplay OFF a Spotify title that ends
# without a Spotify successor leaves the daemon paused on the SAME uri at 0
# (playback_changed paused, queue_changed upcoming [], playback_state paused
# 0/0). Nothing would end LMS's stream, and watchdog round 1 (c) used to
# resume the wrapped title. Plant the boundary once per title instead
# (_onQueueHeadReplay's idiom), so LMS moves on to its successor or stops.
# No pause (already paused), no errors[] entry (correct Spotify behaviour),
# the daemon's queue untouched (D-05). Browse only: Connect rows stay paused
# (D-16). The near-end test keeps a user pause (a reset 5 s in) silent.
sub _maybeContextEnd {
    my $self = shift;
    return unless $self->mode eq 'browse';
    my $wanted   = $self->wanted;
    my $observed = $self->observed;
    my $uri      = $wanted->{uri};
    return unless $wanted->{playing} && defined $uri;
    return if $self->pending;
    return if $observed->{expectEcho} && ($observed->{expectEcho}{until} // 0) > Time::HiRes::time();
    return unless $observed->{is_active};
    return unless ($observed->{status} // '') eq 'paused';
    return unless defined $observed->{track} && $observed->{track} eq $uri;
    my $a = $observed->{anchor};
    return unless ref($a) eq 'HASH' && defined $a->{position_ms}
        && $a->{position_ms} <= CONTEXT_END_RESET_MS && !$a->{speed};
    return if @{ $observed->{queueUris} // [] };
    return if $wanted->{seekIntent};
    return if defined $observed->{contextEndPlanted} && $observed->{contextEndPlanted} eq $uri;
    return unless $self->_nearTitleEnd($uri);

    $observed->{contextEndPlanted} = $uri;
    main::INFOLOG && $log->is_info && $log->info(
        "Control: context end without successor on $uri -- planting boundary, no resume ("
        . ($self->mac // '?') . ")"
    );
    $self->_postBoundaryRead(BOUNDARY_PATH_DRAIN, sub {
        my $reply = shift;
        main::DEBUGLOG && $log->is_debug && $log->debug($self->_boundaryReplyLine($reply));
    });
    return;
}

# _entryTargetMs($anchorLike, $atHr) -- the anchor's position carried forward
# to $atHr when its frame said the app was playing (speed > 0).
sub _entryTargetMs {
    my ($a, $atHr) = @_;
    my $ms = $a->{position_ms};
    if (defined $a->{speed} && $a->{speed} > 0 && defined $a->{seen_hr} && defined $atHr && $atHr > $a->{seen_hr}) {
        my $dt = $atHr - $a->{seen_hr};
        $dt = ENTRY_ANCHOR_MAX_AGE_S if $dt > ENTRY_ANCHOR_MAX_AGE_S;
        $ms += $dt * 1000;
    }
    return $ms;
}

sub _entryDiverges {
    my ($target, $entryMs) = @_;
    return 0 unless defined $target && defined $entryMs;
    return ($target >= ENTRY_MIN_TARGET_MS && abs($target - $entryMs) > ENTRY_TOLERANCE_MS) ? 1 : 0;
}

# _armEntryCheck($self, $targetMs, $zeroSeen) -- one-shot: the first real
# position frame after the new-item reset (within ENTRY_ANCHOR_MAX_AGE_S) is
# compared with $targetMs by _entryCheckFrame.
sub _armEntryCheck {
    my ($self, $targetMs, $zeroSeen) = @_;
    $self->observed->{entryCheck} = {
        target_ms => $targetMs,
        armed_hr  => Time::HiRes::time(),
        zeroSeen  => $zeroSeen ? 1 : 0,
    };
}

# _entryFixOnTransferIn($self) -- called once per transfer-in (fresh session,
# not a reactivation). Returns the app position in ms when the entry frame is
# already known and off (a corrective seek follows); otherwise arms the entry
# check for frames that follow device_changed, and returns undef.
sub _entryFixOnTransferIn {
    my ($self) = @_;
    my $o = $self->observed;
    delete $o->{entryCheck};
    my $an = $o->{anchor};
    my $ea = $o->{entryAnchor};
    my $eaFresh = $ea && defined $ea->{position_ms}
        && (time() - ($ea->{seen_at} // 0)) <= ENTRY_ANCHOR_MAX_AGE_S;
    if ($eaFresh) {
        my $target = _entryTargetMs($ea, $ea->{reset_hr});
        if ($an && defined $an->{position_ms} && ($an->{seen_hr} // 0) >= ($ea->{reset_hr} // 0)) {
            # The latest report is the daemon's entry after the new-item reset. It may be
            # the reset frame itself (0): live 2026-09-30 14:25 (84-14 proof run, `Start
            # Reason: "remote"`, start_position 0 ms) the daemon entered at 0:00 and sent
            # no frame after the zero -- the pa failure of 12:32 (user heard 0:00). Every
            # entry frame seen live (84-14 M1/M3, 84-01 120305) arrived BEFORE
            # device_changed, so at transfer-in the latest report IS the entry.
            return _entryDiverges($target, $an->{position_ms}) ? $target : undef;
        }
        $self->_armEntryCheck($target, 1);   # unreachable in practice: a reset without a later report
        return undef;
    }
    if ($an && defined $an->{position_ms} && $an->{position_ms} >= ENTRY_MIN_TARGET_MS) {
        $self->_armEntryCheck(_entryTargetMs($an, Time::HiRes::time()), 0);
    }
    return undef;
}

# _entryCheckFrame($self, $posMs) -- position_sync hook. Returns 1 when this
# frame was the wrong entry frame and the corrective seek went out.
sub _entryCheckFrame {
    my ($self, $posMs) = @_;
    my $ec = $self->observed->{entryCheck} or return 0;
    return 0 unless defined $posMs;
    if ($self->mode ne 'connect' || Time::HiRes::time() - $ec->{armed_hr} > ENTRY_ANCHOR_MAX_AGE_S) {
        delete $self->observed->{entryCheck};
        return 0;
    }
    if ($posMs < ENTRY_MIN_TARGET_MS) { $ec->{zeroSeen} = 1; return 0; }
    return 0 unless $ec->{zeroSeen};
    delete $self->observed->{entryCheck};   # one-shot, whatever the verdict
    return 0 unless _entryDiverges($ec->{target_ms}, $posMs);
    $self->wanted->{position_ms} = int($ec->{target_ms}) if ref($self->wanted) eq 'HASH';
    $self->_entryCorrect($ec->{target_ms}, 'entry frame ' . sprintf('%.3f', $posMs / 1000) . ' s after device_changed');
    return 1;
}

# _entryCorrect($self, $targetMs, $why) -- the ONE corrective seek, through the
# armed seek path (_dispatch -> _planCommand/_execute, /seek-arm first).
sub _entryCorrect {
    my ($self, $targetMs, $why) = @_;
    my $ms = int($targetMs // 0);
    return 0 if $ms < ENTRY_MIN_TARGET_MS;
    main::INFOLOG && $log->is_info && $log->info(sprintf(
        "Control: transfer-in entry off the app position (%s) -- one corrective seek to %.3fs (84-14 workaround for a daemon-side entry figure, D-06) (%s)",
        $why, $ms / 1000, ($self->mac // '?')
    ));
    $self->_dispatch('seek', position_ms => $ms, armed => (defined $self->observed->{track} ? 1 : 0));
    return 1;
}

# _debugStatusTransition($self, $newStatus, $via) -- D-01 duplicate fold:
# the "capture prevStatus, write the new one, log the G4-INSTR transition"
# triple repeated across track_changed's four status writes and
# playback_state's one. `$newStatus` may be undef (playback_state's own
# `$msg->{status} if defined` conditional) -- the write is then skipped,
# matching the original `if defined` guard exactly, but the (unchanged)
# before/after is still logged.
sub _debugStatusTransition {
    my ($self, $newStatus, $via) = @_;
    my $prevStatus = $self->observed->{status};
    $self->observed->{status} = $newStatus if defined $newStatus;
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "SpotOn G4-INSTR: status " . ($prevStatus // 'undef') . " -> "
        . ($self->observed->{status} // 'undef') . " via $via (" . ($self->mac // '?') . ")"
    );
}

# %FRAME_HANDLERS -- file-scoped dispatch table, one entry per known frame
# type (RESEARCH 1.2's ten-row table). `onEvent` looks up `$type` here
# instead of an if/elsif chain (D-01: "onEvent zerfaellt entlang der zehn
# Frame-Typen").
my %FRAME_HANDLERS = (
    track_changed    => \&_onFrameTrackChanged,
    playback_changed => \&_onFramePlaybackChanged,
    position_sync    => \&_onFramePositionSync,
    playback_state   => \&_onFramePlaybackState,
    auth_state       => \&_onFrameAuthState,
    volume_changed   => \&_onFrameVolumeChanged,
    device_changed   => \&_onFrameDeviceChanged,
    _transport       => \&_onFrameTransport,
    error            => \&_onFrameError,
    queue_changed    => \&_onFrameQueueChanged,
);

sub onEvent {
    my ($self, $msg) = @_;
    return unless ref($msg) eq 'HASH';

    $self->observed->{wsConnected} = 1;
    $self->observed->{lastEventAt} = time();

    my $type = $msg->{type};
    return unless defined $type;

    my $now = Time::HiRes::time();
    my ($class, $detail) = _classify($msg, $self->wanted, $self->observed, $self->pending, $self->mode, $now,
        $self->_lmsPlaysOurs);
    $self->observed->{lastClass} = $class;

    my $handler = $FRAME_HANDLERS{$type};
    unless ($handler) {
        # D-03: `unknown` is a warn line, not a silent debug -- this is the
        # SAME "command_result/context_changed/options_changed" catch-all
        # that used to log at debug only; the type is now legitimately
        # visible per-frame instead of only in aggregate (Repudiation,
        # T-83.1-03). No behavior beyond logging: the frame is otherwise a
        # no-op either way (nothing ever consumed this catch-all's effects).
        $log->warn("Control: classify unknown -- type=$type mode=" . ($self->mode // '?')
            . " wanted.uri=" . ($self->wanted->{uri} // '-')
            . " observed.track=" . ($self->observed->{track} // '-')
            . " pending.cmd=" . ($self->pending ? $self->pending->{cmd} : '-')
            . " (" . ($self->mac // '?') . ")"
        );
        return;
    }

    $self->$handler($msg, $class, $detail);

    # inaktiver-player-steuert-fern: a take-over in flight completes on the
    # FIRST frame that leaves the daemon active -- device_changed(true) is
    # the measured confirmation (M1/M5), the auth_state answer to the probe
    # sent with `activate` covers an already-active daemon (M6), and a
    # playback_state reporting is_active covers either order.
    $self->_completeTakeover if $self->_takeover && $self->observed->{is_active};

    # 84.2-02 (CAUSE-2): the settle point -- a prefetch wish raised while a
    # command was pending goes out once that command's echo cleared it.
    $self->_consumePrefetchWish;
    # 84.2-02 (D-15): a context end without a Spotify successor plants the
    # boundary once, so LMS moves on or stops by itself.
    $self->_maybeContextEnd;
    return;
}

sub _onFrameTrackChanged {
    my ($self, $msg, $class, $detail) = @_;
        # WR-08: `item` payload shape is unconfirmed -- guard against a
        # non-HASH item dying with "Not a HASH reference", which would
        # abort every remaining frame in this read burst.
        my $uri = (ref($msg->{item}) eq 'HASH') ? $msg->{item}{uri} : undef;
        return unless defined $uri;
        # T-22-01 discipline: validate before any id reaches an LMS command.
        return unless $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/;
        my $id = $1;

        $self->_noteCurrentItem($msg->{item});    # 85-07 D-09

        # 79 D-31: a title change ends the hold-release candidate (see _noteHoldRelease).
        {
            my $hrPrev = $self->observed->{track};
            delete $self->observed->{holdReleaseFor} if !defined $hrPrev || $hrPrev ne $uri;
        }

        # 84-19 F-18-N4: a track change may have consumed the queue head --
        # its identity is unknown until the queue_changed that follows in
        # the same burst (same-1 10:29:57.380/.381, bound-1 09:44:03.654).
        # Cleared FIRST, before any branch below returns: this is what
        # separates a natural advance (bound-1, track_changed carries the
        # consumption) from a silent replay (same-1, none does) for the
        # consumed-head detector in _onFrameQueueChanged, independent of
        # frame order, and an unknown head never licenses a skip_next.
        delete $self->observed->{queueHead};

        # 84-17: a second track_changed for a DIFFERENT uri while a change is
        # still waiting for the shim's reply cancels the classification --
        # the pending one is emitted `unknown` (with its queue) NOW, then
        # this frame is processed as before. The same uri (a re-announcement
        # of the changed item) never gets here past the same-track check
        # below, so it never cancels.
        if (my $pcx = $self->observed->{pendingChange}) {
            $self->_cancelPendingChange('track_changed for another uri')
                if $pcx->{uri} ne $uri;
        }

        # inaktiver-player-steuert-fern: a daemon that is not the active
        # device only MIRRORS the account's track_changed -- the active
        # device playing the same uri is not the echo of OUR play (live
        # 2026-09-24: a mirrored frame settled the pending, successCb fired
        # and LMS hung at play 0.0 while our own daemon produced nothing).
        # Neither echo branch below matches while the daemon says it is
        # inactive; the frame falls through to the foreign path.
        my $mirrored = $self->_knownInactive;

        my $pending = $self->pending;
        if ($pending && $pending->{cmd} eq 'play' && !$mirrored
            && defined $pending->{uri} && $pending->{uri} eq $uri)
        {
            # Echo of our own play -- classified by target match, never by
            # a time window (Pitfall 4).
            #
            # D-C, eingefuehrt (82-06 Task 1): der Queue-Prefetch
            # (`_prefetchNext`, called below once the echo settles) macht
            # `add_to_queue(k+1)` erst wirksam, weil D-02 dem Wachhund das
            # Ueberschreiben genommen hat -- ohne D-02 waere Prefetch totes
            # Gewicht gewesen (81-DECISIONS Section D-C).
            $self->observed->{track}  = $uri;
            $self->_clearAutoplayPausedUnless($uri);    # 84-26 R2 clear (b)
            # 83.1-04 (D-B2): the daemon confirming a (re-)played uri
            # settles whatever requestPause marked -- a fresh title
            # means any pending jump-resume question is moot.
            delete $self->wanted->{stopBy};
            # WR-07 (82-REVIEW.md): unconditional, not `unless defined` --
            # the echo IS the daemon confirming it is playing THIS uri now;
            # a stale 'paused' left over from an earlier poll/position_sync
            # must not survive a real echo (asymmetric bookkeeping was the
            # WR-07 root cause).
            $self->_debugStatusTransition('playing', 'track_changed echo');
            Slim::Utils::Timers::killTimers($self, \&_t1Fire);
            delete $self->_driftCount->{$uri};
            # 82-11 WR-05 Fall E: _clearErrorOnce removes the ring entry
            # itself, not only the dedupe lock -- one clearing mechanism
            # shared with the auth_state branch below.
            $self->_clearErrorOnce('drift:' . $uri);
            $self->_clearErrorOnce('replay:' . $uri);

            my $postSeek        = $pending->{postSeek};
            my $postVolume      = $pending->{postVolume};
            my $postPause       = $pending->{postPause};
            my $postPauseIsStop = $pending->{postPauseIsStop};
            my $awaitMeta       = $pending->{awaitMeta};
            my $cb              = $pending->{cb};
            $self->pending(undef);

            if ($awaitMeta) {
                # Befund 2 / Pitfall 5: play already went out; only
                # successCb waits, bounded by T_META_MS (A3) so a 404 title
                # (Befund 2: NEVER catches up) cannot wedge getNextTrack.
                # wr05 (83.1-02 Task 3): release any PRIOR wait before
                # arming this one -- without this, a second echo within
                # T_META_MS of the first (a fast skip) left the old
                # _tMetaFire timer armed, which then fired against the NEW
                # uri at the OLD deadline (killTimers alone is not enough;
                # _releaseAwaitMeta also errors the old cb so it stops
                # waiting instead of silently never resolving).
                $self->_releaseAwaitMeta('superseded');
                $self->_awaitMeta({ uri => $uri, cb => $cb });
                Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + (T_META_MS / 1000), \&_tMetaFire);
            }
            else {
                $self->_fireCbs($cb, 'successCb');
            }

            if (defined $postSeek) {
                # RESEARCH Kante 3: the echo IS the confirmation that the
                # daemon is now on this uri -- exactly one seek follows,
                # async (we are already inside the event callback).
                # 82-16 H-vi (82-G1-MESSUNG.md Verdikt: bestaetigt) -- arm
                # whenever a track is observed, not only while status looks
                # like playing (see Schritt 4's comment, same rationale).
                my $armed = (defined $self->observed->{track} ? 1 : 0);
                $self->_dispatch('seek', position_ms => $postSeek, armed => $armed);
            }

            # WR-02 (82-REVIEW.md): prefetch BEFORE the volume replay --
            # `_prefetchNext`'s `add_to_queue` used to run AFTER
            # requestVolume(postVolume) below and clobber ITS freshly
            # opened `set_volume` pending slot; the following
            # `volume_changed` echo then found no pending, misclassified
            # as a foreign value, and mirrored the OLD volume back to LMS.
            # `add_to_queue` itself is not slot-forming once `pending` is
            # already undef (cleared above), so running it first is safe
            # and leaves requestVolume's slot untouched.
            #
            # D-C (82-06 Task 1): prefetch the NEXT LMS playlist entry now
            # that the daemon confirmed it is on THIS one -- browse only
            # (Pitfall 8, same mode gate as every other emission decision
            # in this function).
            $self->_prefetchNext if $self->mode eq 'browse';

            # D-06 H6-Ersatz (Task 6): the volume push folded above (this
            # `play` was still pending when requestTrack tried to send it)
            # applies now that the echo confirmed the track -- `pending` is
            # settled again (cleared above, or by the postSeek dispatch's
            # own bare-command completion just above). CR-04: force -- the
            # guard already ran when the ORIGINAL play was accepted.
            $self->requestVolume($postVolume, { force => 1 }) if defined $postVolume;

            # 82-09 (CR-02): a folded pause (requestPause arrived while
            # this play was still pending) is never replayed as a stored
            # raw command -- _reconcile decides the idempotency itself
            # against observed's now-current state, same discipline as
            # postVolume/requestVolume just above. wanted.playing is
            # already 0 (set by the original requestPause call). 82-22
            # CR-02: isStop rides along so a folded Stop dispatches
            # regardless of a stale observed.status.
            $self->_reconcile('requestPause', { isStop => $postPauseIsStop }) if $postPause;

            return;
        }

        # WR-01 (82-REVIEW.md): no matching `pending` (already released by
        # T1's timeout, above) -- but this may still be a LATE echo of our
        # own play, not a foreign track. Classified by target match
        # against the expectation _t1Fire saved, same discipline as the
        # pending-echo branch above (never a time window alone, Pitfall
        # 4 -- the window only bounds how long the expectation stays
        # open, not what counts as a match; Fall C: past `until`, this is
        # a no-match and falls through to the foreign-track path below).
        # A late echo corrects the bookkeeping (observed.track, drift
        # counter) -- it does NOT start a new title from Control's
        # perspective (the daemon never left this uri), so unlike the
        # pending-echo branch above, no boundary is planted and no
        # prefetch is triggered here.
        my $expectEcho = $self->observed->{expectEcho};
        if ($expectEcho && defined $expectEcho->{uri} && $expectEcho->{uri} eq $uri && !$mirrored
            && $expectEcho->{until} > Time::HiRes::time())
        {
            delete $self->observed->{expectEcho};
            $self->observed->{track}  = $uri;
            $self->_clearAutoplayPausedUnless($uri);    # 84-26 R2 clear (b)
            # 83.1-04 (D-B2): the daemon confirming a (re-)played uri
            # settles whatever requestPause marked -- a fresh title
            # means any pending jump-resume question is moot.
            delete $self->wanted->{stopBy};
            # WR-07 (82-REVIEW.md): unconditional -- same discipline as the
            # pending-echo branch above, the late echo is still the daemon
            # confirming it is playing THIS uri now.
            $self->_debugStatusTransition('playing', 'track_changed late-echo');
            delete $self->_driftCount->{$uri};
            $self->_clearErrorOnce('drift:' . $uri);
            # 82-23 WR-04: the late echo IS the T1 timeout's resolution --
            # the daemon confirmed this uri after all, just later than
            # T1_TRACK_CHANGED_MS. Clear the t1:<uri> ring entry T1Fire
            # may have written.
            $self->_clearErrorOnce('t1:' . $uri);
            # 82-23 WR-03 (W6): a confirmed echo for this uri -- late or
            # not -- means it is no longer "unrequested"; clear any
            # autoplay:<uri> ring entry the foreign-track branch may have
            # written for it earlier. Without this, autoplay:<uri> has no
            # clear path at all and accumulates one unbounded key per
            # foreign uri for the daemon's whole lifetime.
            $self->_clearErrorOnce('autoplay:' . $uri);
            return;
        }

        # G2-G3 (82-17): a foreign track_changed while a late-echo
        # expectation is still open (the match above already returned --
        # this uri differs from what we expect) means the App took over
        # DURING the late-echo window (Fall D', see <objective> "Warum
        # Kriterium 2 die Verdraengung kennen muss"). Mark the
        # displacement instead of deleting the expectation -- deleting it
        # would also disable the late-echo branch above for a LATER
        # track_changed that matches the ORIGINAL uri (WR-01, 82-12: an
        # auto-advance of the previous session racing our own `play`,
        # whose echo then arrives after this foreign frame). The
        # alternative of additionally requiring observed.track to be
        # undefined-or-equal-to wanted.uri in criterion (2) was rejected
        # (see <objective>): observed.track is never cleared when `play
        # uri` is sent, so in the late-echo case it still holds the
        # PREVIOUS session's title, which would disable criterion (2) in
        # exactly the case it exists for.
        if ($expectEcho && defined $expectEcho->{uri} && $expectEcho->{uri} ne $uri) {
            $expectEcho->{displacedBy} = $uri;
        }

        # D-C prefetch-hit log (unchanged position, 82-42B: kept BEFORE the
        # same-track check below so it still observes every foreign frame,
        # same-track or not -- exactly as it did before this reorder; only
        # _postBoundary moved, not this block).
        #
        # 84.2-01: keyed on the own-queue SET, not on `queuedNext` (any
        # queue_changed upcoming[0]) -- a leftover from an earlier session
        # is no hit and must not be logged as one (misleading 84-27 evidence).
        if ($self->mode eq 'browse' && ref($self->observed->{queuedByUs}) eq 'HASH'
            && exists $self->observed->{queuedByUs}{$uri})
        {
            # D-C confirmation (S-01 A): the prefetch we sent on the
            # PREVIOUS track's echo just paid off -- _reconcile's Treffer
            # branch (below, via the next requestTrack(k+1)) will find
            # observed.track already equal to wanted.uri and send nothing.
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Control: prefetch hit on " . ($self->mac // '?') . " ($uri)"
            );
        }

        # 82-42B (Defekt B, get-state-statt-play.md Signatur B, 2026-09-14
        # investigation): checked BEFORE _postBoundary below -- deliberately
        # diverging from SoloistWS's own sequence (boundary first, then this
        # return). At this point pending/expectEcho's own echo branches
        # (above) have already ruled themselves out, so a track_changed
        # reaching here for the uri we are ALREADY observed on is not a real
        # title transition -- it is a same-track re-announcement (e.g.
        # device re-activation, or a second late track_changed frame racing
        # a `seek` dispatch, as measured live in Signatur B: ~230-300ms
        # after `seek armed=1`, same uri). Nothing changed, so there is
        # nothing to bound; planting a boundary here corked the daemon's
        # just-opened stream (`client-close: bounded EOF`, `song pos: 0` or
        # a truncated `total_pushed`) instead of bounding a genuine
        # transition, which is exactly the mechanism Signatur B measured.
        my $prev = $self->observed->{track};
        if (defined $prev && $prev eq $uri) {
            $self->_debugStatusTransition('playing', 'track_changed foreign');
            return;
        }

        # Foreign track / auto-advance: plant a boundary (today's rule --
        # only the confirmation of our OWN play skips it) 1:1 from
        # SoloistWS::_onTrackChanged:637-678 (82-03 Connect column). 82-42B:
        # moved to AFTER the same-track check above so a same-track
        # re-announcement (ruled out above, which already returned) never
        # reaches this call -- see that check's comment for why.
        #
        # 84-17: in mode=connect with a running session this frame becomes a
        # `change` -- the boundary POST then READS the shim's reply (the same
        # send, at the same instant, plus `?anchor=drain`), the `change` is
        # held as THE pending change and emitted from the reply callback with
        # `via` as the wire's 4th positional; follow-up verbs queue behind it
        # (_emit). Everywhere else (browse/idle, or the first track of a
        # session = `start`) the reply is read and logged only -- nothing
        # waits on it, today's placement and semantics.
        my $pc;
        my $armed;
        if ($self->mode eq 'connect' && defined $self->observed->{startEmittedFor}) {
            $pc = {
                id     => $id,
                prevId => (_trackIdOf($prev) // ''),
                uri    => $uri,
                queued => [],
            };
            $self->observed->{pendingChange} = $pc;
            $armed = $self->_postBoundaryRead(BOUNDARY_PATH_DRAIN, sub {
                $self->_resolvePendingChange($pc, $_[0]);
            });
            $pc->{abort} = $armed if ref($armed) eq 'CODE';
        }
        else {
            # 79-31 D-26: browse/idle natural end -> drain anchor; the first
            # frame of a Connect session (`start`) keeps the plain path.
            my $path = $self->mode eq 'connect' ? BOUNDARY_PATH_PLAIN : BOUNDARY_PATH_DRAIN;
            $self->_postBoundaryRead($path, sub {
                my $reply = shift;
                main::DEBUGLOG && $log->is_debug && $log->debug($self->_boundaryReplyLine($reply));
            });
        }

        # 82-23 WR-03 (Plan-Check-Korrektur B1): a foreign, non-Prefetch
        # track_changed in mode=browse means the daemon advanced on its
        # own (Spotify autoplay) -- pause it and surface it, instead of
        # letting it stream unrequested until LMS' buffer runs dry
        # (~30s). The abgrenzung must prove SPOTON queued this uri, not
        # merely that the daemon announced it: `queuedNext` is written
        # unconditionally from ANY queue_changed frame's upcoming[0],
        # including the daemon's OWN autoplay announcement -- exactly the
        # case this guard exists to catch. `queuedByUs` (set only in
        # _prefetchNext, where SpotOn itself dispatches add_to_queue) is
        # the correct origin proof.
        #
        # Ordering note (found during Task 3, not in the original plan
        # text): the marker must be read and consumed HERE, not in the
        # queuedNext-confirmed-hit branch above -- at the moment the
        # daemon's OWN track_changed for a just-prefetched uri arrives,
        # `wanted.uri` is still the PREVIOUS track (LMS has not called
        # requestTrack for the new one yet; that is the entire point of
        # D-C prefetch: the daemon is already there when LMS's own
        # playlist naturally advances). Clearing queuedByUs any earlier
        # in this function would delete it before this guard ever reads
        # it, making every legitimate D-C prefetch hit look exactly like
        # an unrequested foreign track and pausing it -- the opposite of
        # what Fall F (Gegenprobe) requires.
        #
        # 84.2-01 (D-07 / IN-04): `queuedByUs` is a SET of own queue
        # entries -- a prefetched title LMS skipped past is still own when
        # the daemon reaches it; a match consumes only that one key.
        my $queuedByUsMatch = (ref($self->observed->{queuedByUs}) eq 'HASH'
            && exists $self->observed->{queuedByUs}{$uri}) ? 1 : 0;
        if ($queuedByUsMatch) {
            delete $self->observed->{queuedByUs}{$uri};
        }

        # wr03 (83.1-07 Group D, .planning/todos/pending/wr03-...): a
        # foreign frame landing INSIDE the still-open late-echo window
        # (82-12's expectEcho, kept alive on purpose so our own late echo
        # is still recognized -- see the criterion-2 comment above) is
        # exactly the race 82-12 documented: T1 has already cleared
        # `pending`, so without this exclusion the guard below would
        # `pause` a daemon that already accepted `play X` and is about to
        # echo it -- ending the session paused on our OWN title. Excluding
        # the window here does not weaken the guard outside it (Fall-2 /
        # Gegenprobe): once expectEcho has expired, a foreign frame is
        # unambiguously an unrequested advance and still gets paused.
        my $echoOpen = $self->observed->{expectEcho}
            && ($self->observed->{expectEcho}{until} // 0) > Time::HiRes::time();

        # fremder-autoplay-waechter (.planning/debug/resolved/fremder-
        # autoplay-waechter.md): every daemon on the account MIRRORS the
        # account-wide track_changed, including a daemon that is not the
        # active device. Only the ACTIVE device can have advanced on its
        # own; on an inactive daemon a foreign frame is another player's
        # track change, and `pause` here would pause THAT player's music
        # (live 2026-09-24 11:32:29: an uninvolved player left in
        # mode=browse paused lavender-pa). Own browse playback sets
        # is_active=1 via the own-activation echo before its first
        # track_changed (P1, live-confirmed), so the active player's own
        # autoplay is still caught. Risk asymmetry: a false negative is a
        # stray track for <= 30 s, a false positive pauses someone else.
        #
        # 84.1 D-01(b): after a stop-triggered leaveBrowse the daemon is
        # STILL the active device (is_active never dropped) and may
        # autoplay right past the title we just left -- the second half of
        # this OR keeps the guard armed in idle, keyed on leftBrowseUri
        # (the same target-match discipline as the browse half, never a
        # time window).
        if ((($self->mode eq 'browse' && defined $self->wanted->{uri} && $uri ne $self->wanted->{uri})
                || ($self->mode eq 'idle' && defined $self->observed->{leftBrowseUri}
                    && $uri ne $self->observed->{leftBrowseUri}))
            && !$queuedByUsMatch && !$self->pending && !$echoOpen && $self->observed->{is_active})
        {
            $self->_recordErrorOnce('autoplay:' . $uri, 'warn',
                ($self->mac // '?') . ": daemon advanced to $uri unrequested -- pausing");
            $self->_dispatch('pause');
            # 84-26 R2 (F-24-1): remember WHICH title the guard paused. The marker lives in
            # `observed` (not `wanted`), so it survives leaveBrowse (which wipes `wanted` only):
            # R1 refuses a bare resume of it in browse, R3 refuses to re-adopt it as a Connect
            # session while LMS plays foreign content. Set INSIDE the guard's if-block -- the
            # track write below runs for EVERY foreign frame.
            $self->observed->{autoplayPaused} = $uri;
        }

        $self->observed->{track}  = $uri;
        $self->_clearAutoplayPausedUnless($uri);    # 84-26 R2 clear (b): another uri's marker dies here
        # 83.1-04 (D-B2): same discipline as the echo/late-echo
        # branches above -- a confirmed track change settles stopBy.
        delete $self->wanted->{stopBy};
        $self->_debugStatusTransition('playing', 'track_changed foreign');

        # Emission (start/change) is a mode=connect concern -- never in
        # browse/idle (Pitfall 8: a foreign track_changed must never touch
        # the Browse playlist Connect.pm would otherwise replace).
        if ($self->mode eq 'connect') {
            if (!defined $self->observed->{startEmittedFor}) {
                $self->_emitStart($id);
            }
            else {
                my $prevId = _trackIdOf($prev) // '';
                if ($pc) {
                    if (ref($armed) eq 'CODE') {
                        # Waiting for the reply: the callback (Select read or
                        # the cap timer) emits the `change` with its via.
                    }
                    elsif (defined $armed && $armed eq 'failed') {
                        # The send itself failed: degrade open, emit now.
                        $self->_resolvePendingChange($pc, { via => 'unknown', reason => 'send_failed' });
                    }
                    else {
                        # Nothing could be asked (no daemon/port/Select):
                        # exactly today's emission, no via on the wire.
                        delete $self->observed->{pendingChange};
                        $self->_emit('change', $id, $prevId);
                    }
                }
                else {
                    $self->_emit('change', $id, $prevId);
                }
            }
        }
        return;
}

sub _onFramePlaybackChanged {
    my ($self, $msg, $class, $detail) = @_;
        my $status = $msg->{status};
        return unless defined $status;

        # 84-17: a stop/idle ends the title change we are classifying --
        # resolve the pending `change` as `unknown` (today's immediate path)
        # before this frame is processed.
        if ($status eq 'stopped' || $status eq 'idle') {
            $self->_cancelPendingChange("playback_changed $status");
            delete $self->observed->{hold};    # 84-17: the title the hold deferred is gone
        }

        my $mode       = $self->mode;
        my $prevStatus = $self->observed->{status};

        my $g4Pending = $self->pending;
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "SpotOn G4-INSTR: status " . ($prevStatus // 'undef') . " -> " . $status
            . " via playback_changed mode=$mode pending="
            . ($g4Pending ? $g4Pending->{cmd} : '-') . " (" . ($self->mac // '?') . ")"
        );

        # Blip-Regel (82-03, ersetzt `deactivating`): while idle with no
        # active session, a stray playback_changed is a straggler from a
        # session that already ended via device_changed -- record the
        # status, emit nothing (SoloistWS.pm:724-737 1:1).
        if ($mode eq 'idle' && !$self->observed->{is_active}) {
            $self->observed->{status} = $status;
            $self->_postBoundary if $status eq 'stopped';
            return;
        }

        $self->observed->{status} = $status;
        $self->_noteHoldRelease($status, undef, $prevStatus, $self->observed->{track});    # 79 D-31
        # D-02 (unchanged from SoloistWS:731): a natural end plants a
        # boundary so the bounded serve gets a clean EOF. A transient
        # 'paused' arriving while a play is pending (fixture: +21ms) is
        # historical by the time it is delivered (LMS's OWN internal stop
        # before the synchronous play that already superseded it) and must
        # not be read as a widerspruch to wanted.playing (Research Lücke 3)
        # -- 'stopped' below is unconditional either way.
        $self->_postBoundary if $status eq 'stopped';

        return unless $mode eq 'connect';

        if ($status eq 'playing') {
            # 73-05 (D-06 gap 1): resume only for a REAL Paused->Playing
            # transition -- SoloistWS.pm:747-770 1:1.
            if (defined $prevStatus && ($prevStatus eq 'paused' || $prevStatus eq 'stopped')) {
                my $trackId = _trackIdOf($self->observed->{track});
                my $anchor  = $self->observed->{anchor};
                my $posSec  = _anchorPosSec($anchor);
                $self->_emit('resume', $trackId, $posSec);
                # Post-resume reconciliation: the get_state reply (a
                # playback_state snapshot) catches any residual drift.
                $self->_dispatch('get_state');
            }
        }
        elsif ($status eq 'paused' || $status eq 'stopped') {
            # librespot collapses Paused+Stopped identically -- Connect.pm
            # has no 'pause' verb (RESEARCH Pattern 3).
            $self->_emit('stop');
        }
        elsif ($status eq 'buffering') {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Control: playback_changed 'buffering' (recognized no-op, " . ($self->mac // '?') . ")"
            );
        }
        return;
}

sub _onFramePositionSync {
    my ($self, $msg, $class, $detail) = @_;
        my $p = $msg->{position};
        return unless ref($p) eq 'HASH';

        # 84-14: the entry check of a transfer-in whose entry frames follow
        # `device_changed` (see _armEntryCheck). True when this frame was the
        # daemon's wrong entry frame and a corrective seek went out: that
        # frame is not an app seek, so the drift detection below skips it.
        my $entryCorrected = $self->_entryCheckFrame($p->{position_ms});

        # Drift detection against the PRIOR anchor, before it is overwritten
        # below (mirrors SoloistWS::_onPositionSync:812-820) -- connect only.
        if (!$entryCorrected && $self->mode eq 'connect' && defined $self->observed->{anchor}) {
            $self->_detectSeek($p->{position_ms}, time());
        }

        # 84-02 C4-c: the daemon resets the position to 0 (speed 0) when a
        # new item opens -- live 2026-09-30 12:10:03.699-04.003: 44499 (speed
        # 1), track_changed, then 0 (speed 0), device_changed 0.6 s later. The
        # zero frame overwrites the anchor below, so a transfer-in would see
        # no position. Remember the last real position before such a reset.
        $self->_captureEntryAnchor($p->{position_ms});
        # 84.2-02 (D-15): keep the anchor in force before a reset to 0.
        $self->_capturePreResetAnchor($p->{position_ms}, $p->{speed}, $p->{timestamp_ms});

        $self->observed->{anchor} = {
            position_ms  => $p->{position_ms},
            timestamp_ms => $p->{timestamp_ms},
            speed        => $p->{speed},
            seen_at      => time(),
            seen_hr      => Time::HiRes::time(),
            uri          => $self->observed->{track},    # 84.2-02: the title this anchor belongs to
        };

        # S-02 caveat: speed is a paused/not-paused SIGNAL, never a position
        # correction against LMS. Skip while a play is pending -- the
        # daemon's pre-echo idle state must not overwrite the just-issued
        # 'playing' wish.
        if (defined $p->{speed} && !$p->{speed}) {
            my $pending = $self->pending;
            my $g4Applied = ($pending && $pending->{cmd} eq 'play') ? 0 : 1;
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "SpotOn G4-INSTR: status " . ($self->observed->{status} // 'undef')
                . " -> paused via position_sync speed=0 applied=$g4Applied pending="
                . ($pending ? $pending->{cmd} : '-') . " (" . ($self->mac // '?') . ")"
            );
            $self->observed->{status} = 'paused'
                unless $pending && $pending->{cmd} eq 'play';
        }
        # WR-07 (82-REVIEW.md, teilweise): the symmetric case -- a
        # position_sync with speed>0 stands for "the daemon is moving",
        # which must reset a stuck `observed.status='paused'` back to
        # 'playing'. Without this, `speed:0` above was the only writer of
        # 'paused' and nothing ever wrote it back once a real Pause landed
        # in the SAME narrow window a stale speed:0 frame had just set it
        # (the remaining, unfixed part of WR-07 -- see <objective>).
        elsif (defined $p->{speed} && $p->{speed} > 0 && ($self->observed->{status} // '') eq 'paused') {
            $self->observed->{status} = 'playing';
        }

        # D-D3/D-04 (83.1-02 Task 2): position_sync is the daemon's own
        # ~10s ticker -- the detection point for "LMS steht, Daemon spielt".
        $self->_checkSplitBrain;

        return;
}

sub _onFramePlaybackState {
    my ($self, $msg, $class, $detail) = @_;
        my $item = $msg->{item};
        my $uri  = (ref($item) eq 'HASH') ? $item->{uri} : undef;
        my $mode = $self->mode;
        # 79 D-31: status and track as they were BEFORE this frame (both are overwritten below).
        my $hrPrevStatus = $self->observed->{status};
        my $hrPrevTrack  = $self->observed->{track};

        if (defined $uri && $uri =~ /^spotify:(?:track|episode):([A-Za-z0-9]+)$/) {
            my $newId = $1;
            my $prev  = $self->observed->{track};

            $self->_noteCurrentItem($item);    # 85-07 D-09

            # Phase 82-03 flagged assumption (T-1, "Reconnect mitten in
            # einer Connect-Session"): mirrors track_changed's start-vs-
            # change branch exactly, so a WS reconnect mid-session (a prior
            # `_transport closed` cleared observed.track but NOT mode/
            # startEmittedFor) reports 'change', never a duplicate 'start'.
            if ($mode eq 'connect' && (!defined $prev || $prev ne $uri)) {
                if (!defined $self->observed->{startEmittedFor}) {
                    $self->_emitStart($newId);
                }
                else {
                    # observed.track may be undef here (a `_transport
                    # closed` cleared it) even though a session is
                    # demonstrably still running (startEmittedFor
                    # survived) -- fall back to it as the last-known
                    # track for prevId so a reconnect never reports an
                    # empty previous track.
                    my $prevSrc = defined $prev ? $prev : $self->observed->{startEmittedFor};
                    my $prevId  = _trackIdOf($prevSrc) // '';
                    $self->_emit('change', $newId, $prevId);
                }
            }

            $self->observed->{track} = $uri;
            $self->_clearAutoplayPausedUnless($uri);    # 84-26 R2 clear (b)

            # 83.1-04 (D-B1, Fall-3): learn the track's length the moment a
            # playback_state frame carries it -- never overwrite a value LMS
            # (getNextTrack cache hit) or an earlier fetch already supplied
            # (noteDuration itself is unconditional; the guard here decides
            # WHETHER to call it, not what it does once called). The real
            # frame shape (playback_state.json, track_changed.json) nests it
            # at item.decorations.playback.duration_ms, not item.playback --
            # verified against both fixtures during Task 1 (deviation from
            # the plan text's "item.playback.duration_ms" shorthand).
            # Scoped to playback_state only (not track_changed):
            # track_changed.json's existing T_meta/awaitMeta tests
            # (82-09/82-REVIEW) deliberately exercise the "duration still
            # unknown after the echo" path on that exact fixture, which also
            # happens to carry this same field -- capturing it there too
            # would silently satisfy the awaited duration (noteDuration
            # releases the held successCb before the T_meta timer runs) and
            # break those pre-existing assertions. playback_state is
            # Fall-3's own fixture and carries no such conflicting test.
            my $playback = (ref($item->{decorations}) eq 'HASH') ? $item->{decorations}{playback} : undef;
            if (ref($playback) eq 'HASH' && defined $playback->{duration_ms}
                && !defined $self->observed->{meta}{$uri}{duration})
            {
                $self->noteDuration($uri, $playback->{duration_ms} / 1000);
            }
        }

        # 83.1-04 (D-B4): capture the daemon's own capability statement --
        # a missing verb here is read by requestSkip as "refused", never as
        # "unknown, assume permitted" (Task 2). Keep the LAST known set: a
        # frame that lacks the key at all (not this frame's concern -- every
        # playback_state frame observed so far always carries it) must not
        # erase a previously-learned set; `availableActionsAt` timestamps it
        # for a future staleness rule (not decided in this plan -- D-B4 only
        # requires "never seen" is refused, not "stale").
        if (ref($msg->{available_actions}) eq 'HASH') {
            $self->observed->{availableActions} = { map { $_ => 1 } keys %{ $msg->{available_actions} } };
            $self->observed->{availableActionsAt} = time();
        }

        $self->_debugStatusTransition($msg->{status}, 'playback_state item.uri=' . ($uri // '-'));
        $self->_noteHoldRelease($msg->{status},
            (defined $uri && $uri =~ /^spotify:(?:track|episode):[A-Za-z0-9]+$/) ? $uri : undef,
            $hrPrevStatus, $hrPrevTrack);    # 79 D-31

        if (defined $msg->{position}) {
            my $posMs = ref($msg->{position}) eq 'HASH'
                ? $msg->{position}{position_ms}
                : $msg->{position};
            if (defined $posMs) {
                if ($mode eq 'connect' && defined $self->observed->{anchor}) {
                    $self->_detectSeek($posMs, time());
                }
                # 84-14: the daemon sends the new-item reset as a playback_state
                # (0, buffering) BEFORE the position_sync (0, speed 0) (recorder,
                # 84-14 M1/M3) -- this write was overwriting the last real
                # position first, so entryAnchor (84-02) was never set live.
                $self->_captureEntryAnchor($posMs);
                my $posHash = ref($msg->{position}) eq 'HASH' ? $msg->{position} : {};
                # 84.2-02 (D-15): keep the anchor in force before a reset to 0.
                $self->_capturePreResetAnchor($posMs, $posHash->{speed}, $posHash->{timestamp_ms});
                $self->observed->{anchor} = {
                    position_ms  => $posMs,
                    timestamp_ms => $posHash->{timestamp_ms},
                    speed        => $posHash->{speed},
                    seen_at      => time(),
                    seen_hr      => Time::HiRes::time(),
                    uri          => $self->observed->{track},    # 84.2-02: the title this anchor belongs to
                };
            }
        }

        if (defined $msg->{volume}) {
            # 82-05 (D-06, Task 6): the same echo/grace rule as the
            # volume_changed branch below -- a snapshot value is not
            # automatically a live external change; only differs from that
            # branch in comparing against the PRIOR observed value (a
            # snapshot can repeat one unchanged), not unconditionally.
            my $v       = $msg->{volume};
            my $pending = $self->pending;
            if ($pending && $pending->{cmd} eq 'set_volume' && defined $pending->{volume} && $pending->{volume} == $v) {
                $self->pending(undef);
            }
            elsif ($self->daemon && $self->daemon->can('uptime') && $self->daemon->uptime < VOLUME_GRACE_PERIOD) {
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: ignoring playback_state volume within CON-11 grace period (" . ($self->mac // '?') . ")"
                );
            }
            elsif (!defined $self->observed->{volume} || $v != $self->observed->{volume}) {
                $self->wanted->{volume} = $v;
                $self->_emit('volume', $v);
            }
            $self->observed->{volume} = $v;
        }

        $self->observed->{is_active} = $msg->{is_active} ? 1 : 0 if defined $msg->{is_active};

        # Reconnect in laufende App-Session (SoloistWS.pm:906-909, 1:1): the
        # LMS side never saw device_changed(is_active:true) for this
        # session -- the WS itself just (re)connected to a daemon that was
        # already active. Only from idle -- Prinzip "Transfer": ONLY
        # device_changed switches Browse out (RESEARCH Fluesse "Transfer").
        if ($msg->{is_active} && (($msg->{status} // '') eq 'playing') && $mode eq 'idle' && !$self->_holdAfterForeignLeave) {
            # 83.1-REVIEW.md CR-02: bind the Connect claim from THIS transfer
            # class too, mirroring _onFrameDeviceChanged's D-D1 bind
            # (Control.pm:3371-3379) -- BEFORE any mode/_emitStart dispatch
            # below. Without it, the claim stays unbound after an LMS
            # restart into a live app session and the daemon's next
            # track_changed 'change' is dropped by Connect.pm's
            # `unless (isSpotifyConnect || pendingConnect)` guard.
            # Eval-guarded like the device_changed bind -- a Connect.pm load
            # failure must not abort event processing.
            #
            # 84-21 (D-31 (1)): the per-player Connect switch is enforced HERE,
            # server side, before the claim is bound and before the mode flips:
            # "visible but refusing" (a Soloist daemon cannot be hidden from
            # the app). Shared helper with the device_changed entry so the two
            # cannot drift.
            if (!$self->_emitAllowed) {
                $self->_refuseTransferConnectOff('playback_state');
                return;
            }
            $self->_clearErrorOnce('connect-off:' . ($self->mac // '?'));
            eval {
                require Plugins::SpotOn::Connect;
                my $bindClient = Slim::Player::Client::getClient($self->mac);
                Plugins::SpotOn::Connect->bindConnectClaim($bindClient, 'reconnect') if $bindClient;
                1;
            };
            # 84.2-01 (D-04, defensive): idle -> connect is a loss of Browse
            # control too -- whatever path left an own-queue set behind in
            # idle, none of it survives into connect.
            $self->_forgetOwnQueue('reconnect-to-connect');
            $self->mode('connect'); delete $self->observed->{leftBrowseUri};
            delete $self->observed->{leftBrowsePlanted};    # 84.2-05: the adoption happened -- the episode is over
            # IN-02 (82-REVIEW.md): explicit field assignment, same
            # pattern as the device_changed branch below -- a pauschale
            # `{ %{ $self->observed } }` copy shared HASH REFERENCES
            # between `wanted` and `observed` (meta/errorsReported/anchor
            # are refs, not scalars); a later write through `wanted` would
            # silently mutate `observed` too. `meta`, `errorsReported` and
            # `anchor` are OBSERVATIONS, not wishes, and deliberately do
            # NOT belong in `wanted` at all. `uri` comes from
            # observed->{track} -- there is no observed->{uri}.
            my $anchor = $self->observed->{anchor};
            $self->wanted({
                uri         => $self->observed->{track},
                position_ms => ($anchor && defined $anchor->{position_ms}) ? $anchor->{position_ms} : 0,
                playing     => 1,
                volume      => $self->observed->{volume},
            });
            if (defined $self->observed->{track}) {
                my $tid = _trackIdOf($self->observed->{track});
                $self->_emitStart($tid) if defined $tid;
            }
        }

        # D-D3/D-04 (83.1-02 Task 2): playback_state is the daemon's other
        # regular frame -- same detection point as position_sync.
        $self->_checkSplitBrain;

        return;
}

sub _onFrameAuthState {
    my ($self, $msg, $class, $detail) = @_;
        $self->observed->{loggedOutAt} = Time::HiRes::time() if !$msg->{logged_in} && $self->observed->{logged_in}; $self->observed->{logged_in} = $msg->{logged_in} ? 1 : 0;
        # 84.1 plan 03 (D-04): answers "did the daemon answer a
        # get_auth_state after time T" for DaemonManager's health tick --
        # onEvent's own observed->{lastEventAt} stamp cannot serve that
        # purpose because EVERY frame (ticker frames included) refreshes it.
        $self->observed->{authStateAt} = Time::HiRes::time();
        $self->observed->{is_active} = $msg->{is_active} ? 1 : 0 if defined $msg->{is_active};
        # 82-23 WR-01: paired bookkeeping must be SYMMETRIC -- a
        # logged_in:false has to clear a stale paired=1 the same way a
        # logged_in:true sets it, or Status.pm keeps trusting a defined-
        # but-wrong value from before a session expiry/reconnect
        # (ispaired-heuristik-falschpositiv.md "Update 82-14").
        if ($msg->{logged_in}) {
            $self->observed->{paired} = 1;

            # 83.1-03 (D-A4): the handshake concludes here -- resume the
            # connect watchdog clock with its PRESERVED remaining budget
            # (never reset to the full CONNECT_WATCHDOG_S). Guarded on
            # wsConnected too: `_transport open` (which sets it) always
            # arrives before this login answer (Handschlag-vor-Login,
            # 82-42 Task A), so requiring it here is a defensive line, not
            # the actual ordering dependency.
            $self->_resumeConnectWatchdog
                if $self->mode eq 'connect' && $self->observed->{wsConnected};

            # 82-11 CR-03: login ends any in-flight bounded re-probe --
            # the question has been answered, stop asking it again.
            Slim::Utils::Timers::killTimers($self, \&_authProbe);
            $self->_authProbeCount(undef);
            # 82-11 WR-05 Fall C: _clearErrorOnce removes the ring entry
            # itself, not only the dedupe lock -- a permanently-standing
            # 'daemon not paired' is indistinguishable from a real
            # (g)-finding (Todo errors-startup-falschmeldung-nicht-paired).
            $self->_clearErrorOnce('unpaired');

            # 82-42 Task C (82-42-PLAN.md Task B checkpoint answer
            # "q4-trigger-paired"): resolve a deferred requestTrack HERE --
            # the actual login completion, not the bare wsConnected
            # handshake (onEvent's own wsConnected=1 assignment at the top
            # of this sub fires for EVERY frame, including the
            # `_transport open` pseudoframe that arrives strictly BEFORE
            # any login answer -- Task A's third finding, "Handschlag-vor-
            # Login: bestaetigt"). A hook tied to the bare handshake would
            # burn the one retry shot against a still-unpaired daemon
            # (Runde 2, Warning 1) -- this hook fires only once `paired`
            # is genuinely true.
            if (my $deferred = $self->_deferredTrackRequest) {
                Slim::Utils::Timers::killTimers($self, \&_wsRetryTimeout);
                $self->_deferredTrackRequest(undef);
                # get-state-statt-play.md "## Direction (ii) Investigation
                # (82-42 Task A)", Frage 2, Fall (b): LMS discards the
                # ORIGINAL successCb/errorCb by generation
                # (nextTrackCallbackId, StreamingController.pm:640/
                # 2435-2445) the instant the earlier _NextIfMore attempt
                # reached STOPPED-IDLE -- a Control-only replay of the
                # stored callbacks alone would be silently dropped by LMS
                # (STATUS_FINISHED set, no error, no log). Force a FRESH,
                # LMS-seitig wirksames Kommando BEFORE replaying: this
                # opens a NEW nextTrackCallbackId generation
                # (Source.pm:66-96 -> StreamingController.pm's
                # _eventAction('Play',...) -> _StopGetNext -> _getNextTrack
                # with a fresh $id) -- the same LMS-core entry point the
                # external `playlist play` reannounce also reaches, but by
                # an INDEPENDENT route, not the one Task A assumed.
                #
                # KORREKTUR 2026-09-14 (get-state-statt-play.md
                # "## Bedingung 2 des UND-Tors"): Task A's premise that the
                # reannounce arrives "via the bug 14760 same-URL shortcut"
                # is REFUTED. That shortcut (Commands.pm:1444-1476) is
                # structurally unreachable for spoton:// URLs -- this
                # plugin's own explodePlaylist is picked up earlier, at
                # Commands.pm:1386-1400, which calls it and RETURNS. The
                # real path is explodePlaylist -> playlistXtracksCommand
                # (Commands.pm:1663) -> playlistJumpCommand (:922) ->
                # $controller->play($newIndex=0) (:1020), unconditional,
                # with no same-URL check anywhere on it.
                #
                # The call below stays CORRECT and effective -- only this
                # justification was wrong. For playingState=STOPPED the
                # Play dispatch table (StreamingController.pm:120-125)
                # routes from BOTH IDLE and TRACKWAIT to _StopGetNext ->
                # _getNextTrack without $ifMoreTracks (:969-972), forcing
                # $index=0 instead of the silent give-up that starved
                # _NextIfMore's own internal attempt. Both callers converge
                # on _eventAction('Play',...) independently of each other.
                if (my $client = Slim::Player::Client::getClient($self->mac)) {
                    Slim::Player::Source::playmode($client, 'play');
                }
                $self->_reconcile('requestTrack', $deferred->{opts});
            }
        }
        else {
            # 82-26 CR-01 (Review Runde 3): WR-01 made this latch paired=0, but
            # the daemon pushes auth_state unprompted right after the WS
            # handshake -- at an LMS start that push says `false` while the
            # session restore is still running (measured 2026-09-11: 3.8 s
            # between `restoring session` and `logged in as`; 82-11 measured
            # 7-10 s). Nothing un-latched it, so the user's FIRST play failed
            # and wrote a false `unpaired` entry. Re-ask on the same bounded
            # cadence the `error` branch has used since 82-11, so a login is
            # discovered without a user action. `_authProbe` aborts by itself
            # the moment `paired` turns true or the transport is gone.
            $self->observed->{paired} = 0;
            # PLAN-CHECK-KORREKTUR B1 (2026-09-11, am gepatchten Code gemessen --
            # BLOCKER): die zweite Bedingung ist NICHT optional. Die Antwort auf
            # JEDE `get_auth_state`-Sondierung ist selbst ein `auth_state`-Frame
            # und laeuft durch genau diesen Ast. `_authProbe` setzt bei
            # Erschoepfung `_authProbeCount(undef)`; die Millisekunden spaeter
            # eintreffende dritte Antwort faende `_authProbeCount` also
            # undefiniert und armierte einen frischen Dreierzyklus -- endlos,
            # eine Sondierung je AUTH_REPROBE_S, fuer jeden ungepairten Daemon.
            # Dasselbe traefe den bisher korrekten `error`-Zweig-Zyklus und die
            # WR-05-Re-Sondierung aus Schritt 2. Die Zeitschranke unterscheidet
            # den Handshake-Push (keine eigene Sondierung davor, `_lastAuthProbeAt`
            # alt oder unbelegt -> armiert) von der Antwort auf eine eigene
            # Sondierung (Stempel Millisekunden alt -> armiert NICHT).
            unless (defined $self->_authProbeCount
                    || (Time::HiRes::time() - ($self->_lastAuthProbeAt // 0)) < AUTH_REPROBE_S)
            {
                $self->_authProbeCount(0);
                Slim::Utils::Timers::setTimer(
                    $self, Time::HiRes::time() + AUTH_REPROBE_S, \&_authProbe
                );
            }
        }

        # Per-mac status snapshot for Settings (73-04, 1:1 from
        # SoloistWS::_onAuthState:524-548). Best-effort -- never lets a
        # cache hiccup break event processing.
        eval {
            require Slim::Utils::Cache;
            require Plugins::SpotOn::Plugin;
            my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
            (my $macClean = $self->mac || '') =~ s/://g;
            $cache->set("spoton_soloist_ws_$macClean", {
                logged_in   => $msg->{logged_in} ? 1 : 0,
                is_active   => $msg->{is_active} ? 1 : 0,
                device_name => $msg->{device_name},
                seen_at     => time(),
            }, 3600);
            1;
        };

        # 73-02 (D-05 reconnect resync): once logged in, request a fresh
        # get_state snapshot -- the playback_state branch above reconciles
        # against whatever Control still believes, closing the drift window
        # opened while the connection was down.
        $self->_dispatch('get_state') if $msg->{logged_in};

        return;
}

sub _onFrameVolumeChanged {
    my ($self, $msg, $class, $detail) = @_;
        my $v = $msg->{volume};
        return unless defined $v;

        # 82-05 (D-06, Task 6): Browse opened -- Echo/Schonfrist/Fremdwert
        # replace the daemon-side equality-against-the-previous-value
        # comparison (SoloistWS.pm:899-903) in BOTH modes, not just connect.
        my $pending = $self->pending;
        if ($pending && $pending->{cmd} eq 'set_volume' && defined $pending->{volume} && $pending->{volume} == $v) {
            # Echo of our own set_volume -- target match against pending,
            # never a bare equality-with-the-last-value check (D-06).
            $self->pending(undef);
        }
        elsif ($self->daemon && $self->daemon->can('uptime') && $self->daemon->uptime < VOLUME_GRACE_PERIOD) {
            # CON-11: the daemon starts with `-i <client->volume>`
            # (SoloistDaemon.pm) -- its first volume_changed carries LMS'
            # own value and is an echo by construction, indistinguishable
            # from a real external change by target-match alone. Now
            # applies in Browse too (previously connect-only, gated
            # downstream in Connect.pm's _connectEvent).
            main::INFOLOG && $log->is_info && $log->info(
                "Control: ignoring volume_changed within CON-11 grace period (" . ($self->mac // '?') . ")"
            );
        }
        else {
            # Fremdwert: the App/binary changed it, not us. In Browse,
            # `wanted` normally wins at reconcile time, but a live
            # device-originated change IS the point of D-06 -- one device,
            # one control -- so it wins here too (Mode-Policy in _emit
            # restricts what actually reaches Connect.pm per mode: browse
            # only ever surfaces 'volume').
            $self->wanted->{volume} = $v;
            $self->_emit('volume', $v);
        }

        $self->observed->{volume} = $v;
        return;
}

sub _onFrameDeviceChanged {
    my ($self, $msg, $class, $detail) = @_;
        if ($msg->{is_active}) {
            # inaktiver-player-steuert-fern: the confirmation of OUR OWN
            # take-over (`activate`, _planTakeover) -- not a transfer from
            # the app. Mode stays as requestTrack set it (browse); onEvent
            # completes the take-over right after this handler returns.
            if ($self->_takeover) {
                $self->observed->{is_active} = 1;
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: own take-over confirmed by device_changed -- staying " . ($self->mode // '?')
                    . " (" . ($self->mac // '?') . ")"
                );
                return;
            }

            # G2-G3 (82-17): before anything else -- is this the daemon
            # echoing our OWN just-issued `play` (the "became active
            # device" line the daemon logs when IT starts streaming, not
            # the App claiming the session)? Classified by target match
            # (_ownActivation), never by a time window alone (Pitfall 4,
            # same discipline as the track_changed echo above). Root cause
            # (see <objective>): G-2 (LMS displays the previous session's
            # title/length after a Browse cold start) and G-3 (LMS' `stop`
            # stops reaching the daemon) are ONE mechanism -- this
            # misclassification used to switch `mode` to 'connect' on our
            # own activation, after which Connect.pm's `start` handler
            # rewrote the LMS playlist with observed.track (still the
            # PREVIOUS session's title at that point) and requestPause's
            # `mode eq 'browse'` guard started rejecting the Stop
            # notification. A real transfer-in (idle, no open `play`,
            # foreign title -- Fall C/D below) is untouched.
            if ($self->_ownActivation) {
                $self->observed->{is_active} = 1;
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: own activation echo -- staying browse (" . ($self->mac // '?') . ")"
                );
                return;
            }

            $self->observed->{is_active} = 1;

            # 84-21 (D-31 (1)): the per-player Connect switch. Placed AFTER the
            # _takeover and _ownActivation returns above on purpose -- a check
            # above them would refuse our OWN Browse take-over / activation
            # confirmation (the mirror defect of this policy). Only a frame
            # that would enter connect is a transfer-in to refuse; a session
            # already in connect is left to its own paths.
            if ($self->mode ne 'connect') {
                if (!$self->_emitAllowed) {
                    $self->_refuseTransferConnectOff('device_changed');
                    return;
                }
                $self->_clearErrorOnce('connect-off:' . ($self->mac // '?'));
            }

            # D-D1 (83.1-02 Task 1): bind the Connect claim from the
            # transfer class BEFORE any _emitStart/_emit dispatch below --
            # the single write path for a Soloist player. Eval-guarded like
            # _recordErrorOnce guards Status -- a Connect.pm load failure
            # must not abort event processing.
            eval {
                require Plugins::SpotOn::Connect;
                my $bindClient = Slim::Player::Client::getClient($self->mac);
                Plugins::SpotOn::Connect->bindConnectClaim($bindClient, 'transfer') if $bindClient;
                1;
            };

            # Captured BEFORE any mode/startEmittedFor mutation below --
            # this is the sessionStarted-at-entry read SoloistWS.pm:577
            # took before _emitStart's side effect (260827-jqa Fix B).
            #
            #
            # 84-01 (L2, D-18 release blocker): a surviving startEmittedFor is
            # only a reactivation while LMS still holds THAT session's track
            # (transfer-away and back: stop('inactive') paused the player on
            # the session's own item -- seek + resume is right). The marker
            # survives every session end except leaveConnect and a fresh
            # Control (is_active:false sets mode idle without clearing it,
            # the requestTrack connect->browse flip leaves it too), so it can
            # outlive its session. Frozen window 2026-09-29 10:55:04.32: mode
            # idle, marker of an ended session, LMS's current item a STALE
            # title -- the transfer-in took the reactivation branch, sent
            # seek + resume, Connect.pm's resume handler unpaused the stale
            # item and LMS asked getNextTrack for it 38 ms later. A POSITIVELY
            # known mismatch (LMS's current url is another track or foreign
            # content) means there is no session to come back to: drop the
            # dead marker so the transfer-in is the fresh session it is
            # (_emitStart -> start -> playlist play of the transferred
            # track). Unknown (no client/song, no observed track) keeps the
            # old reactivation behaviour.
            my $reactivation = defined $self->observed->{startEmittedFor};
            if ($reactivation) {
                my $lmsUrl     = $self->_lmsCurrentUrl;
                my $sessionUri = $self->observed->{track};
                if (defined $lmsUrl && defined $sessionUri
                    && (_normalizeUri($lmsUrl) // '') ne $sessionUri)
                {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Control: transfer-in -- LMS holds '" . $lmsUrl . "', not the session track "
                        . $sessionUri . " -- dropping the marker of an ended session, fresh start ("
                        . ($self->mac // '?') . ")"
                    );
                    delete $self->observed->{startEmittedFor};
                    $reactivation = 0;
                }
            }

            if ($self->mode ne 'connect') {
                my $anchor = $self->observed->{anchor};
                # 84.2-01 (D-04): the transfer-in (browse/idle -> connect)
                # flips the mode without leaveBrowse -- forget here as well.
                $self->_forgetOwnQueue('transfer-in');
                $self->mode('connect');
                $self->wanted({
                    uri         => $self->observed->{track},
                    position_ms => ($anchor && defined $anchor->{position_ms}) ? $anchor->{position_ms} : 0,
                    playing     => 1,
                    volume      => $self->observed->{volume},
                });
                # 84.1 D-01(b): a transfer-in is a fresh session -- the
                # stop-triggered leave's autoplay-guard marker no longer
                # applies once the daemon is the active device again.
                delete $self->observed->{leftBrowseUri}; delete $self->observed->{leftConnectForeign};
                delete $self->observed->{leftBrowsePlanted};    # 84.2-05: a fresh session
                # 84-26 R2 clear (d): same fresh-session clear point -- an adopted Connect session
                # on the autoplay-paused title is legitimate (D-02); a stale marker must not outlive it.
                delete $self->observed->{autoplayPaused};
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: transfer-in -> mode=connect (" . ($self->mac // '?') . ")"
                );
            }

            if (!$reactivation && defined $self->observed->{track}) {
                my $tid = _trackIdOf($self->observed->{track});
                # 84-02 C4-c: the transfer-in enters the title mid-way and no
                # seek echo follows -- pass the app position along so
                # Connect.pm's start handler can set LMS' clock to it
                # (otherwise the bar runs from 0 while the audio is at P).
                my $startAnchor = $self->observed->{anchor};
                my $startPos    = ($startAnchor && defined $startAnchor->{position_ms} && $startAnchor->{position_ms} > 0)
                    ? _anchorPosSec($startAnchor) : '';
                if ($startPos eq '') {
                    # the anchor reads 0 (the daemon's new-item reset): fall back to the
                    # last real position seen shortly before it
                    my $entry = $self->observed->{entryAnchor};
                    if ($entry && defined $entry->{position_ms} && $entry->{position_ms} > 0
                        && (time() - ($entry->{seen_at} // 0)) <= ENTRY_ANCHOR_MAX_AGE_S)
                    {
                        $startPos = _anchorPosSec($entry);
                    }
                }
                # 84-14 (D-06 workaround): the daemon's entry frame can sit far from the
                # position the app had (84-14 M1 3.6 s vs 47.2 s, M3 7.0 s vs 45.9 s: the
                # wrong figure is the daemon's own, reported BEFORE device_changed and
                # before any SpotOn command). The app's position is the last real frame
                # before the new-item reset (entryAnchor); a real entry frame after the
                # reset that differs from it by more than ENTRY_TOLERANCE_MS gets exactly
                # one corrective seek. Entry frames that follow device_changed are
                # handled by the entry check armed below.
                my $entryFixMs = $self->_entryFixOnTransferIn;
                if (defined $entryFixMs) {
                    $startPos = sprintf('%.3f', $entryFixMs / 1000);
                    $self->wanted->{position_ms} = int($entryFixMs) if ref($self->wanted) eq 'HASH';
                }
                $self->_emitStart($tid, $startPos) if defined $tid;
                $self->_entryCorrect($entryFixMs, 'transfer-in') if defined $entryFixMs;
            }

            if ($reactivation) {
                # Re-activation: sync position and resume playback
                # (SoloistWS.pm:584-599, 1:1).
                my $anchor = $self->observed->{anchor};
                # 84-14 (round 3, D-06 workaround): a surviving marker with an empty
                # playlist (LMS url undef, so the 84-01 marker-drop cannot fire) takes
                # this branch for a fresh transfer-in too (live 14:25/14:36, `empty
                # --prior same`). Its anchor is then the daemon's new-item reset (0) or
                # an entry figure far off the app position, and `seek <anchor>` sent
                # 0:00 itself. Same entry-position source and tolerance as the fresh
                # branch (_entryFixOnTransferIn, one-shot): a divergent entry gets the
                # app position -- on the LMS seek/resume AND as ONE daemon seek. A
                # genuine transfer-away-and-back (real anchor, no new-item reset seen)
                # never reaches the fix.
                my $ea = $self->observed->{entryAnchor};
                my $resetSeen = $ea && defined $ea->{position_ms}
                    && (time() - ($ea->{seen_at} // 0)) <= ENTRY_ANCHOR_MAX_AGE_S
                    && $anchor && ($anchor->{seen_hr} // 0) >= ($ea->{reset_hr} // 0);
                my $anchorIsReset = !$anchor || !defined $anchor->{position_ms}
                    || $anchor->{position_ms} < ENTRY_MIN_TARGET_MS;
                my $entryFixMs;
                if ($resetSeen || ($anchorIsReset && $anchor && defined $anchor->{position_ms})) {
                    $entryFixMs = $self->_entryFixOnTransferIn;
                }
                if (defined $entryFixMs) {
                    $anchor = { %$anchor, position_ms => int($entryFixMs) };
                    $self->wanted->{position_ms} = int($entryFixMs) if ref($self->wanted) eq 'HASH';
                }
                # never a LMS `seek 0.000`: an anchor that still reads a reset is unknown
                if ($anchor && defined $anchor->{position_ms} && $anchor->{position_ms} >= ENTRY_MIN_TARGET_MS) {
                    $self->_emit('seek', sprintf('%.3f', $anchor->{position_ms} / 1000));
                }
                $self->_entryCorrect($entryFixMs, 'reactivation transfer-in') if defined $entryFixMs;
                $self->observed->{status} = 'playing';
                my $posSec = _anchorPosSec($anchor);
                # Bugfix (getnexttrack-url-seek-position, 2026-09-22):
                # _emit's contract is ($cmd, $p2, $p3) and Connect.pm's
                # 'resume' handler reads _p2 as the track ID and _p3 as the
                # position (see the identical playback_changed sibling call
                # above, ~line 2080). This call was missing the track-ID
                # argument entirely, which shifted $posSec into the
                # track-ID slot -- Connect.pm's reentry path then built
                # "spoton://track:$trackId" directly from the position
                # value (e.g. spoton://track:0.000), a URL getNextTrack
                # cannot resolve to a real track (17/17 correlation in the
                # debug session).
                my $trackId = _trackIdOf($self->observed->{track});
                # 84-26 F-24-2 (defensive): remember what THIS resume emits (after the 84-14 fix rewrote
                # the local anchor, when it did) -- written ONLY at or above ENTRY_MIN_TARGET_MS:
                # `_anchorPosSec` yields 0.000 for an anchor that still reads the new-item reset, :4286
                # already refuses to emit such a seek, and a marker carrying it would substitute ~0.
                my $emittedMs = int($posSec * 1000 + 0.5);
                if ($emittedMs >= ENTRY_MIN_TARGET_MS && defined $self->observed->{track}) {
                    $self->observed->{entryResume} = {
                        uri         => $self->observed->{track},
                        position_ms => $emittedMs,
                        hr          => Time::HiRes::time(),
                    };
                }
                $self->_emit('resume', $trackId, $posSec);
            }
        }
        else {
            # GH #151: mark this stop as the SESSION-END signal (device
            # deselected in the Spotify app / transfer-away / disconnect)
            # -- distinct from the plain pause 'stop' above. Emitted BEFORE
            # the mode switch (Connect.pm's stop handler reads the
            # 'inactive' marker while the session is still nominally
            # connect). In browse, a stray is_active:false changes nothing
            # (no active Connect session to end).
            #
            # inaktiver-player-steuert-fern: inactive FIRST, in both modes
            # -- the LMS pause/stop each branch below causes can re-enter
            # requestPause, and that `pause` must meet the send gate
            # instead of pausing the device that just took the session.
            $self->observed->{is_active} = 0; delete $self->observed->{leftBrowseUri}; # 84.1-08 WR-01: a lost session ends the stop-leave episode in any mode
            delete $self->observed->{leftBrowsePlanted};    # 84.2-05: a lost session ends the episode in any mode
            if ($self->mode eq 'connect') {
                # D-D1: emit BEFORE release -- Connect.pm's stop('inactive')
                # handler pauses only while isSpotifyConnect is still true
                # (Connect.pm ~1516); releasing the claim first would make
                # that check see 'not connect' and skip the pause.
                $self->_emit('stop', 'inactive');
                eval {
                    require Plugins::SpotOn::Connect;
                    my $releaseClient = Slim::Player::Client::getClient($self->mac);
                    Plugins::SpotOn::Connect->releaseConnectClaim($releaseClient, 'inactive') if $releaseClient;
                    1;
                };
                $self->mode('idle');
            }
            elsif ($self->mode eq 'browse') {
                # fremder-autoplay-waechter: make P2 readable in server.log
                # -- from here on this daemon is no longer the active
                # device, so the autoplay guard in _onFrameTrackChanged
                # stands down for mirrored foreign track changes.
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: no longer active device in browse -- autoplay guard off ("
                    . ($self->mac // '?') . ")"
                );
                # inaktiver-player-steuert-fern (user decision A): another
                # device took the session (app, or another player's own
                # take-over). If LMS keeps playing here, its next
                # getNextTrack would take the session straight back --
                # ping-pong between two players. A player that loses the
                # session stops in LMS, like a device switch in the app.
                # Only while LMS actually plays OUR material: a paused LMS
                # or a local file/radio is left alone.
                my $client = Slim::Player::Client::getClient($self->mac);
                if ($client && $self->_lmsSongIsOurs
                    && (Slim::Player::Source::playmode($client) // '') eq 'play')
                {
                    main::INFOLOG && $log->is_info && $log->info(
                        "Control: lost the Spotify session to another device in browse -- stopping LMS ("
                        . ($self->mac // '?') . ")"
                    );
                    $client->execute(['stop']);
                }
                # 84.1 D-01(b): clear the stop-triggered leave marker here
                # -- Task 2 (D-01(a)) adds the leaveBrowse call for the
                # session-loss trigger at this exact spot, after the
                # playmode-gated stop above; this task owns the marker end
                # to end (check iteration 2: this gate must stay true after
                # every later task of this plan commits).
                delete $self->observed->{leftBrowseUri};
                # 84.1 D-01(a): the daemon is no longer our device, so
                # browse mode has nothing left to steer -- leave
                # unconditionally, in BOTH LMS states (playing: LMS was
                # just stopped above; paused: left alone, decision A of
                # inaktiver-player-steuert-fern stands unchanged). Re-entry
                # is requestTrack (LMS's next play of our material).
                # leaveBrowse is idempotent (plain setters), so a `stop`
                # notification re-entering requestPause first (Task 1's
                # stop-leave, via the execute() re-entrancy IA-7r/IA-7c
                # pin) does no harm if it already ran. Pending requests are
                # left untouched (their T1 timer resolves them), exactly
                # as the two existing leaveBrowse callers do.
                $self->leaveBrowse;
                main::INFOLOG && $log->is_info && $log->info(
                    "Control: lost the Spotify session in browse -- leaveBrowse (" . ($self->mac // '?') . ")"
                );
            }
            $self->observed->{is_active} = 0;
        }
        return;
}

sub _onFrameTransport {
    my ($self, $msg, $class, $detail) = @_;
        my $state = $msg->{state} // '';
        if ($state eq 'closed') {
            $self->_transportClosed;
        }
        elsif ($state eq 'open') {
            $self->observed->{wsConnected} = 1;
            # 82-23 WR-04: a reopened transport resolves whatever
            # 'transport' ring entry _transportClosed may have written --
            # before _reconcile('transport'), same discipline as every
            # other paired/state clear in this function.
            $self->_clearErrorOnce('transport');
            # T-82-28: catch up a `pause` that could not be sent while the
            # WS was down (wanted.playing left at 0 by requestPause) --
            # never sends `play`/`play uri` on its own (LMS is the queue
            # owner; a cold start runs through getNextTrack, not here).
            $self->_reconcile('transport');
        }
        return;
}

sub _onFrameError {
    my ($self, $msg, $class, $detail) = @_;
        my $message = $msg->{message} // '';

        # inaktiver-player-steuert-fern: an error while our take-over is in
        # flight belongs to it (nothing else state-changing was sent while
        # inactive) -- fail it visibly instead of waiting out the timeout.
        # The branches below still run (e.g. the requires-authentication
        # bookkeeping).
        # A requires-authentication error gets its own `unpaired` entry
        # below -- no second errors[] entry for the same cause.
        if ($self->_takeover) {
            my $unpaired = ($message =~ /requires authentication/i) ? 1 : 0;
            $self->_releaseTakeover($unpaired ? 'daemon not paired' : "daemon error: $message", $unpaired ? 0 : 1);
        }

        if ($message =~ /requires authentication/i) {
            $self->observed->{paired} = 0;
            # 82-11 CR-03: capture the command that actually failed BEFORE
            # `pending` is released below -- SoloistWS::lastCommand is a
            # 1-deep shared slot that a subsequent get_auth_state overwrites
            # before this handler ever runs, naming the WRONG command in
            # the log (82-REVIEW.md CR-03 side note). Naming none is better
            # than naming a wrong one.
            my $failedCmd;
            if (my $pending = $self->pending) {
                $failedCmd = $pending->{cmd};
                Slim::Utils::Timers::killTimers($self, \&_t1Fire);
                $self->_fireCbs($pending->{cb}, 'errorCb', 'PROBLEM_OPENING', 'Soloist daemon not paired');
                $self->pending(undef);
            }
            $self->_recordErrorOnce('unpaired', 'error',
                ($self->mac // '?') . ": daemon not paired (command requires authentication"
                . (defined $failedCmd ? ", cmd=$failedCmd" : '') . ')');

            # 82-11 CR-03: begin a bounded re-probe instead of hoping the
            # daemon pushes an unprompted auth_state after login -- no
            # fixture proves it does. `defined` guards against re-arming a
            # cycle that is already running (a second auth error while the
            # first re-probe is still pending).
            unless (defined $self->_authProbeCount) {
                $self->_authProbeCount(0);
                Slim::Utils::Timers::setTimer(
                    $self, Time::HiRes::time() + AUTH_REPROBE_S, \&_authProbe
                );
            }
            return;
        }

        # 82-09 (WR-04): the daemon carries no reliable command-correlation
        # field in every case -- SoloistWS::lastCommand is one-deep and
        # gets overwritten by any side command already dispatched through
        # _dispatch's fold-through path above -- so the correlation has to
        # live here, in Control, against `pending.lastSentCmd`. An
        # uncorrelated error (e.g. to a get_state/add_to_queue sent while
        # a play is still open) must not abort a play that is itself still
        # legitimately in flight.
        if (my $pending = $self->pending) {
            my $frameCmd = $msg->{command};
            my $belongsToPending = defined $frameCmd
                ? ($frameCmd eq $pending->{cmd})
                : (($pending->{lastSentCmd} // $pending->{cmd}) eq $pending->{cmd});

            unless ($belongsToPending) {
                main::DEBUGLOG && $log->is_debug && $log->debug(
                    "Control: daemon error for a different command, not aborting the open pending ("
                    . ($self->mac // '?') . "): cmd=" . ($frameCmd // $pending->{lastSentCmd} // '?')
                    . " message=$message"
                );
                return;
            }

            Slim::Utils::Timers::killTimers($self, \&_t1Fire);
            # 82-23 WR-04: a correlated daemon error (belongs to the open
            # pending command) is its own errors[] candidate. A2 (named,
            # not implemented): no _clearErrorOnce counterpart in this
            # plan -- see SUMMARY.
            # 82-28 (WR-02, Review Runde 3): keyed by message content, not
            # a single fixed key -- otherwise the first correlated daemon
            # error silently blocks every later, DIFFERENT error message
            # for the daemon's lifetime (write-once class, same shape as
            # the autoplay: fix above). The same message text still
            # dedupes via _recordErrorOnce's existing lock -- this only
            # widens what counts as "the same" error.
            # 82-29 (WR-01, Review Runde 4): Digest::MD5::md5_hex stirbt mit
            # "Wide character in subroutine entry", sobald die Zeichenkette einen
            # Codepoint oberhalb U+00FF traegt -- SoloistWS' from_json liefert
            # fuer jede nicht-lateinische Daemon-Nachricht genau eine solche
            # Zeichenkette. onEvent darf laut eigenem Vertrag (siehe Kopfkommentar)
            # auf keinem Frame sterben. Fuer eine reine ASCII-Nachricht ist
            # utf8::encode ein No-op auf der Byte-Ebene -- jeder bestehende
            # daemon-error:-Ringschluessel bleibt byte-identisch.
            my $msgBytes = $message;
            utf8::encode($msgBytes);
            $self->_recordErrorOnce('daemon-error:' . md5_hex($msgBytes), 'warn', ($self->mac // '?') . ": daemon error: $message");
            $self->_fireCbs($pending->{cb}, 'errorCb', 'PROBLEM_OPENING', "Soloist daemon error: $message");
            $self->pending(undef);
            return;
        }

        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: daemon error with no pending command (" . ($self->mac // '?') . "): $message"
        );
        return;
}

sub _onFrameQueueChanged {
    my ($self, $msg, $class, $detail) = @_;
        # D-C confirmation (82-06 Task 1, S-01 A): the ONLY field Control
        # reads from this frame is upcoming[0].item.uri -- context_changed/
        # options_changed remain verworfen (RESEARCH Open Question 6,
        # COVERAGE.md OPT-OUT, Phase 83).
        my $up = $msg->{upcoming};
        if (ref($up) eq 'ARRAY' && ref($up->[0]) eq 'HASH' && ref($up->[0]{item}) eq 'HASH') {
            my $u = $up->[0]{item}{uri};
            $self->observed->{queuedNext} = $u
                if defined $u && $u =~ /^spotify:track:[A-Za-z0-9]+$/;
        }

        # 84-19 F-18-N4 (stale daemon user queue): the daemon's user queue
        # outlives every Browse session (entries from our own prefetch
        # survive title jumps, LMS and daemon restarts) and its API has no
        # remove/clear. Three changes read this frame:
        #   - queueUris: every `source: queue` track uri, so _prefetchNext
        #     never queues a uri twice (same-1 10:29:57.394: [6d0c, 5EZh,
        #     5EZh]);
        #   - queueHead {uri, uid}: upcoming[0] when it is a queue entry --
        #     what `skip_next` would consume (_reconcilePlan mismatch path:
        #     `play X` never consumes a head equal to X, same-1
        #     10:29:57.381); cleared by every track_changed (below) because
        #     a track change may have consumed it, so an unknown head never
        #     licenses a skip_next;
        #   - the consumed-head detector: the daemon consumed the head that
        #     IS the title playing and restarted it (same-1 10:30:26.152:
        #     queue_changed previous=[ctx 6d0c], no track_changed -- the
        #     guard of _onFrameTrackChanged keys on a track_changed and
        #     never sees it; LMS stalled 17 s on the replayed title).
        # Uids are per entry and compared, never the uri alone (duplicates
        # like [5EZh, 5EZh] are real).
        #
        # A placeholder frame (every entry uid `node_rules_placeholder`) is
        # the daemon's transitional state at the START of every `play`,
        # ~40 ms before track_changed and the real queue_changed (same-1
        # 10:29:57.343; UAT 2026-10-04 11:50:22.516) -- not a queue state.
        # Taken at face value it emptied queueUris before the echo's
        # prefetch looked at it, so the dedupe never fired in the real
        # frame order and a third entry was queued; and it would read as
        # "the head is gone" to the detector.
        my $isPlaceholder = ref($up) eq 'ARRAY' && @$up
            && !grep { !(ref($_) eq 'HASH' && ($_->{uid} // '') eq 'node_rules_placeholder') } @$up;
        if (ref($up) eq 'ARRAY' && !$isPlaceholder) {
            my (@qUris, %uids, $head);
            for my $i (0 .. $#$up) {
                my $e = $up->[$i];
                next unless ref($e) eq 'HASH';
                $uids{ $e->{uid} } = 1 if defined $e->{uid};
                next unless ref($e->{item}) eq 'HASH' && ($e->{source} // '') eq 'queue';
                my $eu = $e->{item}{uri};
                next unless defined $eu && $eu =~ /^spotify:track:[A-Za-z0-9]+$/;
                push @qUris, $eu;
                $head = { uri => $eu, uid => $e->{uid} } if $i == 0;
            }
            my $old = $self->observed->{queueHead};
            $self->observed->{queueUris} = \@qUris;
            if ($head) { $self->observed->{queueHead} = $head }
            else       { delete $self->observed->{queueHead} }

            if ($old && defined $old->{uid} && !$uids{ $old->{uid} }
                && defined $self->observed->{track} && $old->{uri} eq $self->observed->{track})
            {
                $self->_onQueueHeadReplay($old);
            }
        }

        # 85-07 D-09: the renderable copy of the same frame, for the Up Next
        # menu. Independent of the bookkeeping above (it only READS $up).
        $self->_cacheUpNext($up);
        return;
}

# ------------------------------------------------------------------
# 85-07 D-09: Up Next from the playback helper.
#
# The daemon announces its queue in `queue_changed` frames -- unsolicited,
# and as the reply to the `get_queue` command (85-03 D09-QUEUE: the reply is
# the same frame type, t/fixtures/soloist/s85-get-queue-reply.jsonl; no new
# dispatch entry is needed). Each upcoming entry carries the display data
# (decorations) inline, so the menu needs no Web API call. Everything below
# is untrusted wire data (T-85-24): type-checked at every level, bounded,
# only spotify:track / spotify:episode uris, strings length-capped.
# ------------------------------------------------------------------

my %COVER_WIDTH = (small => 64, default => 300, large => 640, xlarge => 640);

sub _boundedString {
    my ($v) = @_;
    return undef if !defined $v || ref $v || !length $v;
    return length($v) > 300 ? substr($v, 0, 300) : $v;
}

# _normalizeQueueItem($item) -> { uri, name, artists, album, duration_ms } | undef
# Shape = what Plugin.pm::_trackItem reads off a Web API track object, so the
# menu renders it through the established pipeline.
sub _normalizeQueueItem {
    my ($item) = @_;
    return undef unless ref($item) eq 'HASH';

    my $uri = $item->{uri};
    return undef unless defined $uri && !ref $uri && $uri =~ /^spotify:(?:track|episode):[A-Za-z0-9]+$/;

    my $dec = $item->{decorations};
    return undef unless ref($dec) eq 'HASH';
    my $name = _boundedString(ref($dec->{identity}) eq 'HASH' ? $dec->{identity}{name} : undef);
    return undef unless defined $name;

    my @artists;
    if (ref($dec->{creators}) eq 'ARRAY') {
        for my $c (@{ $dec->{creators} }) {
            last if @artists >= 10;
            next unless ref($c) eq 'HASH' && ref($c->{entity}) eq 'HASH';
            my $ent   = $c->{entity};
            my $aname = _boundedString(ref($ent->{decorations}) eq 'HASH' && ref($ent->{decorations}{identity}) eq 'HASH'
                ? $ent->{decorations}{identity}{name} : undef);
            next unless defined $aname;
            my %a = (name => $aname);
            $a{id} = $1 if defined $ent->{uri} && !ref $ent->{uri} && $ent->{uri} =~ /^spotify:artist:([A-Za-z0-9]+)$/;
            push @artists, \%a;
        }
    }

    my %album;
    if (ref($dec->{parent}) eq 'HASH' && ref($dec->{parent}{entity}) eq 'HASH') {
        my $pe = $dec->{parent}{entity};
        my $an = _boundedString(ref($pe->{decorations}) eq 'HASH' && ref($pe->{decorations}{identity}) eq 'HASH'
            ? $pe->{decorations}{identity}{name} : undef);
        $album{name} = $an if defined $an;
        $album{id}   = $1 if defined $pe->{uri} && !ref $pe->{uri} && $pe->{uri} =~ /^spotify:album:([A-Za-z0-9]+)$/;
    }
    my @images;
    my $vi = $dec->{visual_identity};
    if (ref($vi) eq 'HASH' && ref($vi->{cover}) eq 'ARRAY') {
        for my $c (@{ $vi->{cover} }) {
            last if @images >= 8;
            next unless ref($c) eq 'HASH' && defined $c->{url} && !ref $c->{url} && $c->{url} =~ m{^https://[^\s]{1,500}$};
            push @images, { url => $c->{url}, width => ($COVER_WIDTH{ $c->{size} // '' } // 0) };
        }
    }
    $album{images} = \@images;

    my $dur;
    if (ref($dec->{playback}) eq 'HASH') {
        my $d = $dec->{playback}{duration_ms};
        $dur = int($d) if defined $d && !ref $d && $d =~ /^\d{1,9}$/;
    }

    return {
        uri     => $uri,
        name    => $name,
        artists => \@artists,
        album   => \%album,
        (defined $dur ? (duration_ms => $dur) : ()),
    };
}

# _cacheUpNext($self, $upcoming) -- refresh observed.upNext from a
# queue_changed `upcoming` list. A non-array leaves the cache as it was; a
# placeholder frame (every uid node_rules_placeholder -- the daemon's
# transitional state at the start of a `play`, see _onFrameQueueChanged) is
# not a queue state and is ignored too.
sub _cacheUpNext {
    my ($self, $up) = @_;
    return unless ref($up) eq 'ARRAY';

    return if @$up
        && !grep { !(ref($_) eq 'HASH' && ($_->{uid} // '') eq 'node_rules_placeholder') } @$up;

    my @out;
    for my $e (@$up) {
        last if @out >= UP_NEXT_MAX;
        next unless ref($e) eq 'HASH';
        my $n = _normalizeQueueItem($e->{item}) or next;
        push @out, $n;
    }
    $self->observed->{upNext} = \@out;
    return;
}

# _noteCurrentItem($self, $item) -- remember the display data of the title
# the daemon announced as playing (playback_state / track_changed), so the
# Up Next menu can head its list with it. Unrenderable -> forget the old one.
sub _noteCurrentItem {
    my ($self, $item) = @_;
    my $n = _normalizeQueueItem($item);
    if ($n) { $self->observed->{currentItem} = $n }
    else    { delete $self->observed->{currentItem} }
    return;
}

# requestQueue($self) -- ask the daemon for a fresh queue (the reply is a
# queue_changed frame, handled above). T-85-23: at most one get_queue per
# QUEUE_REQUEST_MIN_INTERVAL_S; menu opens in between only read the cache.
# Goes through _execute's probe op (the one sendCommand site) and never
# touches `pending`. Returns 1 when a command went out, 0 otherwise.
sub requestQueue {
    my ($self) = @_;

    my $now  = Time::HiRes::time();
    my $last = $self->_lastQueueRequestAt;
    return 0 if defined $last && ($now - $last) < QUEUE_REQUEST_MIN_INTERVAL_S;
    return 0 unless $self->daemon && $self->daemon->_ws;

    $self->_execute([ {
        op       => 'probe',
        cmd      => 'get_queue',
        wireArgs => [ limit => UP_NEXT_MAX ],
        stamp    => { attr => '_lastQueueRequestAt', value => $now },
    } ]);
    return 1;
}

# queueSnapshot($self) -> { current => entry|undef, upcoming => [entry...] }
# A deep copy: the caller (Plugin.pm menu) may do what it likes with it.
sub queueSnapshot {
    my ($self) = @_;
    my $obs = $self->observed || {};
    return {
        current  => (ref($obs->{currentItem}) eq 'HASH' ? _deepCopy($obs->{currentItem}) : undef),
        upcoming => (ref($obs->{upNext}) eq 'ARRAY' ? _deepCopy($obs->{upNext}) : []),
    };
}

# _onQueueHeadReplay($self, $old) -- 84-19 F-18-N4 change 3 (safety net): the
# daemon consumed the queue head $old, which IS the title playing, without
# a track_changed -- it restarted the title (same-1). LMS has no way to tell
# (the stream carries the replayed PCM or stalls, 17 s measured), so the
# same reaction as the foreign branch of _onFrameTrackChanged: plant the
# boundary (the replayed PCM never reaches LMS's stream) and pause.
# Guards copied from that branch (mode browse, no open own play, no open
# late-echo window, active device) plus no seek intent (a seek to 0 is not a
# replay). An own play that is pending DEFERS the detector -- LMS repeat-one
# re-requests the title through `play`, and the daemon's replay may land
# before it; that play's echo settles the state itself. Also covers the
# autoplay-OFF twin F-18-N1(b) as a side effect (user decision 2026-10-04:
# the twin itself stays deferred until after 84-20).
sub _onQueueHeadReplay {
    my ($self, $old) = @_;

    return unless $self->mode eq 'browse';
    return unless $self->observed->{is_active};
    return if $self->wanted->{seekIntent};

    my $echoOpen = $self->observed->{expectEcho}
        && ($self->observed->{expectEcho}{until} // 0) > Time::HiRes::time();
    if ($self->pending || $echoOpen) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: queue head replay of " . $old->{uri} . " deferred (own play pending or late-echo window open) ("
            . ($self->mac // '?') . ")"
        );
        return;
    }

    my $uri = $old->{uri};
    $self->_postBoundaryRead(BOUNDARY_PATH_DRAIN, sub {
        my $reply = shift;
        main::DEBUGLOG && $log->is_debug && $log->debug($self->_boundaryReplyLine($reply));
    });
    $self->_recordErrorOnce('replay:' . $uri, 'warn',
        ($self->mac // '?') . ": daemon consumed its queue head and restarted $uri unrequested -- pausing");
    $self->_dispatch('pause');
    # 84-26 R2 (F-24-1): the second marker writer -- same marker, same readers (R1, R3) as the guard's.
    $self->observed->{autoplayPaused} = $uri;
    return;
}

# _classify($event, $wanted, $observed, $pending, $mode, $now) -- D-03: a
# TOTAL, pure function (no `$self`, no clock of its own -- `$now` is
# always an input) returning exactly one of Echo|Drift|Fremdeingriff|
# Transfer|unknown for every frame type in the ten-row table times every
# mode. `mode` is an INPUT to the function, not a side-channel guard: the
# SAME foreign `track_changed` is Fremdeingriff in browse and the NORMAL
# CASE (Transfer) in connect (Prinzip 3.1(3) in executable form, per
# 83-CONTEXT.md D-03). Nothing in this plan CONSUMES the returned class
# yet (null measurement) -- `onEvent` only records it.
sub _classify {
    my ($event, $wanted, $observed, $pending, $mode, $now, $lmsPlaysOurs) = @_;

    my $type = (ref($event) eq 'HASH') ? $event->{type} : undef;
    return ('unknown', 'no-type') unless defined $type;

    if ($type eq 'track_changed') {
        my $uri = (ref($event->{item}) eq 'HASH') ? $event->{item}{uri} : undef;
        return ('unknown', 'no-uri') unless defined $uri;

        if ($pending && $pending->{cmd} eq 'play' && defined $pending->{uri} && $pending->{uri} eq $uri) {
            return ('Echo', 'own-play');
        }
        my $expectEcho = $observed->{expectEcho};
        if ($expectEcho && defined $expectEcho->{uri} && $expectEcho->{uri} eq $uri
            && defined $expectEcho->{until} && $expectEcho->{until} > $now)
        {
            return ('Echo', 'late');
        }
        if (defined $observed->{track} && $observed->{track} eq $uri) {
            return ('Drift', 'reannounce');
        }
        return $mode eq 'connect' ? ('Transfer', 'foreign') : ('Fremdeingriff', 'foreign');
    }

    if ($type eq 'device_changed') {
        if ($event->{is_active}) {
            return _ownActivationAt($wanted, $observed, $pending, $mode, $now, $lmsPlaysOurs)
                ? ('Echo', 'own activation')
                : ('Transfer', 'activation');
        }
        return ('Transfer', 'inactive');
    }

    if ($type eq 'position_sync' || $type eq 'playback_state') {
        if ($mode eq 'connect') {
            my $posMs = ($type eq 'position_sync')
                ? (ref($event->{position}) eq 'HASH' ? $event->{position}{position_ms} : undef)
                : (ref($event->{position}) eq 'HASH' ? $event->{position}{position_ms} : $event->{position});
            if (defined $posMs) {
                my $expectedMs = _positionMsOf($observed, $now) // 0;
                if (abs($posMs - $expectedMs) / 1000 > SEEK_THRESHOLD) {
                    return ('Drift', 'seek');
                }
            }
        }
        return ('Drift', $type);
    }

    if ($type eq 'playback_changed' || $type eq 'volume_changed' || $type eq 'auth_state'
        || $type eq 'queue_changed' || $type eq '_transport' || $type eq 'error')
    {
        return ('Drift', $type);
    }

    return ('unknown', $type);
}


# _emitStart($self, $id) -- 1:1 from SoloistWS::_emitStart:925-933. Fires at
# most once per Connect session -- observed.startEmittedFor persists across
# a transport loss (_transportClosed does NOT clear it) so a WS reconnect
# mid-session never re-announces 'start' (T-1 flagged assumption).
sub _emitStart {
    my ($self, $id, $posSec) = @_;

    return if defined $self->observed->{startEmittedFor};
    $self->observed->{startEmittedFor} = $self->observed->{track};

    # 83.1-03 (D-A1/D-A3): a `start` is a daemon-driven (re-)open request --
    # arm the connect watchdog clock on it, same as a `change` (see _emit's
    # own arming hook below for the full guard rationale). A no-op outside
    # mode=connect (_armConnectWatchdog's own gate).
    $self->_armConnectWatchdog($self->observed->{track})
        if $self->mode eq 'connect' && defined $self->observed->{track};

    $self->_emit('start', $id, $posSec // '');
}

# _checkSplitBrain($self) -- D-D3/D-04 (83.1-02 Task 2): detects "LMS und
# Daemon uneinig" at the daemon's OWN ticker cadence (called from the end of
# _onFramePositionSync/_onFramePlaybackState, ~10s apart) -- there is no
# notification-based detection point (a StreamingFailed stop does not reach
# _onPause/requestPause; measured 2026-09-11: the daemon played four
# minutes on with errors[] empty). Gated on mode=connect (D-A2: Browse
# untouched), wanted.playing (D-08: an LMS-side pause/stop intent is NEVER
# split-brain) and observed.is_active. Requires TWO consecutive sightings
# before escalating -- one ticker frame is not evidence (a user pause
# forwarded to the daemon takes ~100ms to echo back).
sub _checkSplitBrain {
    my $self = shift;

    return unless $self->mode eq 'connect';

    # 84-17: while a hold is open LMS lags the daemon by the buffered tail on
    # purpose (and may read `stop` around the bounded EOF/advance) -- that is
    # the expected state, not a split brain. Reset the sightings and stand
    # down; an expired record (HOLD_MAX_S) counts as absent, so a genuinely
    # stopped LMS is escalated after the ceiling exactly as before.
    if ($self->_hold) {
        if (my $sbh = $self->observed->{splitBrain}) { $sbh->{sightings} = 0; }
        return;
    }

    return unless $self->wanted->{playing};
    return unless $self->observed->{is_active};
    return unless ($self->observed->{status} // '') eq 'playing';

    my $client = Slim::Player::Client::getClient($self->mac);
    return unless $client;

    my $playmode = Slim::Player::Source::playmode($client) // '';

    if ($playmode ne 'stop') {
        # Reset rule: a real Play resolves the ladder -- clear both the
        # record and every errors[] entry either entry point may have
        # written through it (plan 03's watchdog writes 'watchdog:<uri>'
        # through this SAME record).
        if (my $sb = $self->observed->{splitBrain}) {
            delete $self->observed->{splitBrain};
            $self->_clearErrorOnce('split-brain:' . $sb->{uri}) if defined $sb->{uri};
            $self->_clearErrorOnce('watchdog:' . $sb->{uri})    if defined $sb->{uri};
        }
        return;
    }

    my $uri = $self->observed->{track};
    return unless defined $uri;

    my $sb = $self->observed->{splitBrain};
    if (!$sb || $sb->{uri} ne $uri) {
        # A new title is a new ladder -- a stale record for the OLD uri
        # (or none at all) does not carry forward.
        $sb = $self->observed->{splitBrain} = { uri => $uri, attempts => 0, sightings => 0 };
    }

    $sb->{sightings}++;
    return if $sb->{sightings} < 2;

    $sb->{sightings} = 0;
    $self->_connectResync('split-brain');
}

# _connectResync($self, $reason) -- 83.1-02 Task 2 (D-04/D-05): the OWNER of
# the split-brain escalation record for BOTH entry points -- this module's
# own _checkSplitBrain (reason 'split-brain') and plan 03's
# _watchdogRound2 connect branch (reason 'watchdog', which calls this sub
# with NO prior two-sighting confirmation of its own). Creates the record
# when absent, resets it on a title change, and increments the ONE shared
# `attempts` counter regardless of which entry point called (CONTEXT D-A3
# Nachtrag 2026-09-23 P2-B2: the watchdog fires once per incident; its one
# attempt and the ticker's own attempts share this counter, so
# SPLIT_BRAIN_MAX_ATTEMPTS nachziehen attempts happen in total before D-05).
#
# D-04 (attempts within budget): re-emit `change` for observed.track (LMS
# nachziehen) with a reason-specific errors[] entry (D-D3: the status page
# must show WHAT happened -- a watchdog rung never claims "LMS steht,
# Daemon spielt", which it did not itself observe). The re-emit carries
# origin 'nachziehen' as _emit's 5th argument and does NOT re-arm plan 03's
# connect watchdog clock (a ladder re-emit is not a daemon-driven emission).
#
# D-05 (attempts exhausted): Notausgang -- an explicit, named exception to
# Prinzip 3.1(3) (in connect, `observed` is normally right; here LMS wins
# instead), never a general rule. Pauses the daemon so the daemon/LMS/App
# converge on 'paused' instead of the daemon playing into the void.
sub _connectResync {
    my ($self, $reason) = @_;

    my $uri = $self->observed->{track};
    return unless defined $uri;

    my $sb = $self->observed->{splitBrain} ||= { uri => $uri, attempts => 0, sightings => 0 };
    if ($sb->{uri} ne $uri) {
        $sb = $self->observed->{splitBrain} = { uri => $uri, attempts => 0, sightings => 0 };
    }

    $sb->{attempts}++;
    $sb->{sightings} = 0;
    $sb->{reason}    = $reason;

    my $mac = $self->mac // '?';
    my $n   = $sb->{attempts};

    if ($n <= SPLIT_BRAIN_MAX_ATTEMPTS) {
        if ($reason eq 'split-brain') {
            $self->_recordErrorOnce('split-brain:' . $uri, 'warn',
                "$mac: LMS und Daemon uneinig -- LMS steht, Daemon spielt $uri; "
                . "LMS wird nachgezogen (Versuch $n von " . SPLIT_BRAIN_MAX_ATTEMPTS . ", D-04)");
        }
        elsif ($reason eq 'watchdog') {
            # 83.1-03: CONNECT_WATCHDOG_S replaces plan 02's placeholder
            # literal 10 (same numeric value, now the real constant).
            $self->_recordErrorOnce('watchdog:' . $uri, 'warn',
                "$mac: LMS hat $uri nicht binnen " . CONNECT_WATCHDOG_S . " s wieder geoeffnet; "
                . "LMS wird nachgezogen (Versuch $n von " . SPLIT_BRAIN_MAX_ATTEMPTS . ", D-06/D-04)");
        }

        my $client = Slim::Player::Client::getClient($self->mac);
        $log->warn("Control: nachziehen -- reason=$reason attempt=$n/" . SPLIT_BRAIN_MAX_ATTEMPTS
            . " playmode=" . ($client ? (Slim::Player::Source::playmode($client) // '?') : '?')
            . " observed.status=" . ($self->observed->{status} // '?')
            . " uri=$uri ($mac)");

        my $prevId = _trackIdOf($self->observed->{startEmittedFor});
        my $id     = _trackIdOf($uri);
        $self->_emit('change', $id, $prevId, 'nachziehen');
    }
    else {
        $self->_recordErrorOnce('split-brain-halt:' . $uri, 'warn',
            "$mac: LMS liess sich " . SPLIT_BRAIN_MAX_ATTEMPTS
            . "-mal nicht nachziehen (Grund: $reason) -- Daemon angehalten (Notausgang D-05, Ausnahme von Prinzip 3.1(3))");
        $log->warn("Control: Notausgang -- reason=$reason attempts=$n uri=$uri ($mac)");

        $self->wanted->{playing} = 0;
        $self->_dispatch('pause');
        delete $self->observed->{splitBrain};
    }
}

# _observedPositionMs($self, $now) -- observed.anchor (position_ms/seen_at)
# rebased onto $now (defaults to Time::HiRes::time() if omitted). Frozen
# (no elapsed-time added) while observed.status is paused/stopped -- the
# same baseline _detectSeek has always used, now extracted here so the
# rebasing math lives in exactly one place instead of being reimplemented
# in the Treffer-Zweig (82-08 CR-01). undef when there is no anchor yet, or
# its position_ms is missing -- nothing to compare against, and guessing a
# position would be worse than sending nothing. Since 82-30, "no anchor, no
# seek" is no longer the blanket rule for the Treffer-Zweig in _reconcile
# Schritt 4 -- it holds ONLY when mode=connect (82-24 CR-04, LMS follows
# the daemon there), OR an open play-Pending for the same uri already owns
# the resolution (R2-CR01 Fall F). For EVERY OTHER case in mode!=connect
# with no open Pending -- including an already-$playing daemon (WR-01,
# 82-REVIEW.md Runde 6, 82-31: track_changed never writes observed.anchor,
# so a genuine prefetch hit always carries the PREVIOUS track's anchor and
# is decided above, never by the no-anchor case; CR-01 Fall F in t/44
# guards the case this used to wrongly exempt) -- $needsSeek now (82-30,
# widened 82-31) DOES fire a seek precisely BECAUSE the position is
# unknown -- an unknown position must not be treated as "already correct".
# _positionMsOf($observed, $now) -- D-03: the pure anchor-rebasing
# arithmetic of `_observedPositionMs`, extracted so `_classify` (no
# `$self`) can decide the seek-drift row (position_sync/playback_state in
# mode=connect) through the SAME arithmetic, `$now` always an input.
sub _positionMsOf {
    my ($observed, $now) = @_;

    my $anchor = $observed->{anchor};
    return undef unless $anchor && defined $anchor->{position_ms};

    my $frozen    = (($observed->{status} // '') =~ /^(?:paused|stopped)$/) ? 1 : 0;
    my $elapsedMs = $frozen ? 0 : (($now - ($anchor->{seen_at} // $now)) * 1000);

    return $anchor->{position_ms} + $elapsedMs;
}

sub _observedPositionMs {
    my ($self, $now) = @_;
    $now = Time::HiRes::time() unless defined $now;
    return _positionMsOf($self->observed, $now);
}

# _detectSeek($self, $posMs, $now) -- 1:1 from SoloistWS::_detectSeek:839-848,
# rebased onto observed.anchor (position_ms/seen_at) and observed.status
# (paused/stopped = frozen baseline) instead of the old lastPositionMs/
# lastPositionTs/sessionPaused accessors. Only ever called from mode=connect
# call sites (position_sync, playback_state) -- the guard stays at the call
# site, not in here (CR-S1 divergence, preserved). The rebasing itself now
# goes through _observedPositionMs (82-08 CR-01) -- unchanged behavior, one
# fewer place carrying the anchor math.
sub _detectSeek {
    my ($self, $posMs, $now) = @_;

    my $expectedMs = $self->_observedPositionMs($now) // 0;
    my $deltaSec   = abs($posMs - $expectedMs) / 1000;
    if ($deltaSec > SEEK_THRESHOLD) {
        # 84-02 (cluster 4, D-21): the Soloist daemon's reported position can
        # stay frozen for minutes while the stream plays on (uncork delay,
        # fakepulse-timing-buffer.md; live 2026-09-30 11:40:49.0975: 0.13 s
        # reported 8.9 s into the title; l2-proof 11:04:41/11:05:41: the entry
        # position 45.1 s repeated every 60 s). The prior anchor holds the
        # daemon's last report; a new report that equals it while the
        # rebased expectation advanced is that same frozen value again -- echoing
        # it as `seek` set LMS' clock back to it (startOffset -7.33,
        # -8.86, -68.87). A genuine app-side seek lands elsewhere.
        my $anchor = $self->observed->{anchor};
        if ($anchor && defined $anchor->{position_ms}
            && abs($posMs - $anchor->{position_ms}) < FROZEN_POSITION_TOLERANCE_MS)
        {
            main::INFOLOG && $log->is_info && $log->info(sprintf(
                "Control: position report %.3fs repeats the prior anchor (%.3fs) while %.1fs passed -- frozen daemon position, no seek echo (%s)",
                $posMs / 1000, $anchor->{position_ms} / 1000, $deltaSec, ($self->mac // '?')
            ));
            return;
        }
        $self->_emit('seek', sprintf('%.3f', $posMs / 1000));
    }
}

# _transportClosed($self) -- handles the `_transport closed` pseudo-frame
# SoloistWS.pm's _onClosed forwards (82-03 transport cut). Clears the
# session-observation fields that are no longer trustworthy across a
# reconnect (track/status/anchor) and releases any in-flight command with
# an error so getNextTrack never wedges on a dead transport (T-77-10).
# `mode` and `startEmittedFor` deliberately survive -- clearing either would
# make the next playback_state snapshot re-announce a duplicate 'start'
# (T-1 flagged assumption, "Reconnect mitten in einer Connect-Session").
# `_awaitMeta` explicitly does NOT belong to that survivor set (82-09,
# WR-03) -- it is released below, same as `pending`.
# _authProbe($self) -- 82-11 CR-03: timer callback for the bounded
# get_auth_state re-probe armed in onEvent's 'error' branch. Deliberately
# calls $ws->sendCommand directly rather than going through _dispatch --
# the pending-slot pass-through _dispatch offers only applies while a
# 'play' is already in flight (82-09); an auth probe must NEVER touch
# `pending` regardless of what else is in flight, or it would wedge
# whatever real command is waiting on the single pending slot.
sub _authProbe {
    my $self = shift;

    # Abandon the cycle the moment either the question is answered or the
    # transport it would ride on is gone -- an unpaired-forever daemon
    # still stops asking after AUTH_REPROBE_MAX (below), but a daemon that
    # became paired or disconnected mid-cycle stops immediately.
    if ($self->observed->{paired} || !$self->observed->{wsConnected}) {
        $self->_authProbeCount(undef);
        return;
    }

    my $ws = $self->daemon && $self->daemon->_ws;
    unless ($ws) {
        $self->_authProbeCount(undef);
        return;
    }

    my $count = ($self->_authProbeCount // 0) + 1;
    $self->_authProbeCount($count);
    # 83.1-01 Task 2: routed through `_execute`'s `probe` op -- the SAME
    # `sendCommand(` call site `_planCommand`'s `send` uses (D-02 must_have:
    # `_execute` is the ONLY site that ever calls it). The ws-gone branch
    # just above already guarantees `$ws` here, so the op's own internal
    # `if (my $ws = ...)` re-check is redundant but harmless.
    $self->_execute([ { op => 'probe', cmd => 'get_auth_state' } ]);
    # 82-23 WR-05: stamp every probe (bounded-cycle AND, below, the
    # single reconcile-triggered re-probe) so the Schritt-2 trigger can
    # rate-limit itself to one extra probe per AUTH_REPROBE_S.
    $self->_lastAuthProbeAt(Time::HiRes::time());

    if ($count < AUTH_REPROBE_MAX) {
        Slim::Utils::Timers::setTimer(
            $self, Time::HiRes::time() + AUTH_REPROBE_S, \&_authProbe
        );
    }
    else {
        # AUTH_REPROBE_MAX reached -- the state becomes visible via
        # errors[] (Task 2's grace/ring logic already ran on the initial
        # error) instead of asking forever.
        # 82-23 CR-03 (Runde 2): that comment was aspirational, not true --
        # the initial error-frame handler's ring write only fires while the
        # error frame arrives; a daemon whose FIRST failure fell inside
        # UNPAIRED_GRACE_S never got a ring entry from it, and no request
        # necessarily runs in between to trip the fail-fast write above.
        # Write here too so probe exhaustion itself is a guaranteed ring
        # entry -- _recordErrorOnce's own dedupe/grace logic makes this a
        # no-op if the key is already recorded.
        $self->_recordErrorOnce('unpaired', 'error',
            ($self->mac // '?') . ": daemon not paired after " . AUTH_REPROBE_MAX . " probes");
        $self->_authProbeCount(undef);
    }
}

sub _transportClosed {
    my $self = shift;

    # 83.1-03 (D-A4): a torn-down transport means no re-open CAN arrive
    # until the WS reconnects AND the daemon logs back in -- freeze the
    # connect watchdog clock's remaining budget rather than let it run out
    # during a legitimate handshake. Before wsConnected flips (this sub's
    # own contract does not depend on the order), a no-op outside connect.
    $self->_pauseConnectWatchdog if $self->mode eq 'connect';

    $self->observed->{wsConnected} = 0;
    delete $self->observed->{track};
    delete $self->observed->{status};
    delete $self->observed->{anchor};
    # 85-07 D-09: the Up Next cache describes the queue of a connection that
    # is gone; the next queue_changed / get_queue reply rebuilds it.
    delete $self->observed->{upNext};
    delete $self->observed->{currentItem};
    $self->_lastQueueRequestAt(undef);
    # WR-01 (82-REVIEW.md): a torn-down transport invalidates any still-
    # open late-echo expectation -- no echo from THIS connection is coming.
    delete $self->observed->{expectEcho};
    # 82-16 F1: same discipline -- a seek issued over the closed transport
    # must not suppress a correction on whatever reconnects next.
    delete $self->observed->{seekIssued};
    # 82-23 WR-01: a dead transport has no pairing state to report --
    # `defined` vs `0` matters downstream. Deleting (not setting 0) falls
    # `_reconcile` Schritt 2's fail-fast through (nothing to fail fast on
    # from a transport that is already gone) and lets Status.pm:219 fall
    # back to its filesystem heuristic (named consequence, W7 -- see
    # SUMMARY) instead of asserting a stale "unpaired".
    delete $self->observed->{paired};
    # 82-23 WR-04: transport loss is its own errors[] candidate -- a
    # cleared path exists (the `_transport open` branch above clears it
    # via _clearErrorOnce('transport') before _reconcile('transport')).
    # wr04 (83.1-02 Task 3): a PLANNED stop (shutdown() ran first) is not a
    # transport LOSS -- skip the ring write entirely so a sync-group stop/
    # backend switch/LMS shutdown never reports "WS transport lost" for an
    # action the user (or LMS) itself triggered.
    $self->_recordErrorOnce('transport', 'warn', ($self->mac // '?') . ": WS transport lost")
        unless $self->observed->{shutdown};

    Slim::Utils::Timers::killTimers($self, \&_t1Fire);
    # 82-11 CR-03: a re-probe timer that outlives a torn-down transport is
    # the same class of bug as WR-02/WR-03 -- stop asking a daemon that is
    # no longer reachable.
    Slim::Utils::Timers::killTimers($self, \&_authProbe);
    $self->_authProbeCount(undef);
    # 82-29 (WR-02, Review Runde 4): eine Sondierung, die ueber einen jetzt
    # toten Transport ging, hat keine Antwort mehr zu erwarten -- die
    # Zeitschranke im auth_state-False-Zweig (82-26 PLAN-CHECK-KORREKTUR
    # B1) darf sich also nicht mehr an ihr orientieren. Ohne diese Zeile
    # kann ein Handshake-Push auf dem NAECHSTEN Transport innerhalb von
    # AUTH_REPROBE_S nach der letzten Sondierung des VORHERIGEN Transports
    # landen und die Schranke faelschlich als "frisch" lesen -- nichts wird
    # armiert, und die CR-01-Verklemmung ist fuer genau diesen Reconnect
    # wieder offen.
    $self->_lastAuthProbeAt(undef);
    if (my $pending = $self->pending) {
        $self->_fireCbs($pending->{cb}, 'errorCb', 'PROBLEM_OPENING', 'Soloist daemon not ready');
        $self->pending(undef);
    }

    # 82-42 Task C, Fall-6 (82-42-PLAN.md Task B checkpoint answer
    # "clear-on-teardown"): a deferred requestTrack does not survive a
    # torn-down transport -- clear it and resolve its errorCb rather than
    # leaving it to a respawn that may never happen (T-82-42A). NOTE this
    # fires not only on a genuine teardown but also on the 5s WS-handshake
    # timeout (SoloistWS.pm HANDSHAKE_TIMEOUT/_handshakeTimeoutTimer) once
    # the TCP connection was accepted -- a merely STALLED (not aborted)
    # handshake already clears the deferral within its own TTL window.
    # 82-46 WR-03: promoted onto the shared _releaseDeferredTrackRequest
    # sub -- shutdown now calls the same path with its own reason text.
    $self->_releaseDeferredTrackRequest('transport closed');

    # inaktiver-player-steuert-fern: no confirmation can arrive over a dead
    # transport. errors[] already carries `transport` (above) -- no second
    # entry for the same loss.
    $self->_releaseTakeover('transport closed', 0);

    $self->_releaseAwaitMeta('Soloist daemon not ready');
}

# _loopbackPost($self, $port, $path) -- CR-05 (82-REVIEW.md): the ONE place
# that sends a fire-and-forget POST to fake-libpulse's own loopback control
# endpoints (/seek-arm, /boundary), shared by _armSync and _postBoundary.
# Non-blocking socket setup (`Blocking => 0`, NO `Timeout`) and exactly one
# `syswrite` -- CLAUDE.md's non-blocking rule applies in the LMS command
# path regardless of how short a bounded stall would realistically be
# (81-DECISIONS D-B: 30/30 correctly ordered, p95 70ms -- a loopback
# connect on a listening port returns near-instantly even against a frozen
# daemon, but "bounded" is not "allowed"; CR-05). No response is EVER
# read -- callers' own comments carry the resulting ordering-guarantee
# boundary (send order, not processing order). The whole block is
# eval-guarded and degrade-open (T-77-10): a failed connect is the
# caller's problem to log, not this sub's. A short write (partial
# `syswrite`) is this sub's own problem to log, since neither caller can
# tell a partial write from a connect failure otherwise. (84-17:
# _postBoundaryRead is the one sibling that DOES read the reply -- through
# Slim::Networking::Select, never blocking; this fire-and-forget helper and
# its callers stay write-only.)
sub _loopbackPost {
    my ($self, $port, $path) = @_;

    my $sock = $self->_loopbackSend($port, $path) or return 0;
    close($sock);
    return 1;
}

# _loopbackSend($self, $port, $path) -- 84-17: the connect + the ONE
# syswrite of _loopbackPost, factored out so a caller that wants the reply
# (_postBoundaryRead) shares the byte-identical send. Returns the still-open
# socket after a COMPLETE write, undef otherwise (the socket is closed on
# every failure path; a partial write is logged here). The send itself is
# unchanged: non-blocking, one syswrite, eval-guarded, degrade-open.
sub _loopbackSend {
    my ($self, $port, $path) = @_;

    my $request = "POST $path HTTP/1.0\r\nConnection: close\r\n\r\n";

    my $sock;
    my $ok = eval {
        $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "connect: $!";

        my $written = $sock->syswrite($request);

        if (!defined $written || $written != length($request)) {
            $log->warn("Control: loopback POST $path partial write ("
                . (defined $written ? $written : 'undef') . "/" . length($request)
                . " bytes, port $port, " . ($self->mac // '?') . ")");
            0;
        }
        else {
            # G1-MESS (82-15 Task 1): the LMS-side clock for H-iii -- without
            # this line a sync arm that was actually SENT is invisible in
            # server.log, indistinguishable from one that was never
            # attempted. DEBUG only, no behavior change.
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Control: loopback POST $path sent (port $port, " . ($self->mac // '?') . ")"
            );
            1;
        }
    };
    unless ($ok) {
        eval { close($sock) } if $sock;
        return undef;
    }
    return $sock;
}

# _postBoundary($self) -- 1:1 from SoloistWS::_signalBoundary. Fire-and-
# forget loopback POST to fake-libpulse's /boundary control endpoint on the
# daemon's own HTTP stream port via _loopbackPost -- degrade-open (a missed
# boundary just means one track won't get a bounded EOF).
#
# S-01 B: im LMS-getriebenen Setup wurde je Titelgrenze KEIN Boundary
# gepflanzt (`boundary_planted` nur im Konstruktor beobachtet); die
# Echo-gebundene Boundary-Regel dieser Datei (skip nur auf dem eigenen-
# play-Echo, plant sonst) ist damit gegen ein echtes LMS ungetestet -- siehe
# M-3(c) in 82-07 (das UAT-Szenario "Auto-Advance ohne Watchdog-Sprung").
sub _postBoundary {
    my $self = shift;

    my $daemon   = $self->daemon or return;
    my $httpPort = $daemon->_streamPort or return;

    unless ($self->_loopbackPost($httpPort, '/boundary')) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: boundary signal failed (" . ($self->mac // '?') . ")"
        );
    }
}

# _postHoldRelease($self) -- 79 D-31 (79-38): fire-and-forget loopback POST to
# fake-libpulse's /hold-release endpoint (79-37), the same shape as
# _postBoundary: daemon -> _streamPort -> _loopbackPost, write only, degrade
# open. The shim answers `hold=released ...` (a hold was armed) or
# `hold=suppressed ...` (none armed: the next arming inside the window is
# suppressed); neither reply is read.
sub _postHoldRelease {
    my $self = shift;

    my $daemon   = $self->daemon or return;
    my $httpPort = $daemon->_streamPort or return;

    unless ($self->_loopbackPost($httpPort, '/hold-release')) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: hold release signal failed (" . ($self->mac // '?') . ")"
        );
    }
}

# _noteHoldRelease($self, $status, $uri, $prevStatus, $prevTrack) -- 79 D-31
# (79-38): the release rule, called by BOTH state frames with the status and
# track as they were before the frame (whichever frame reports the transition
# first posts; the second sees playing -> playing).
#   - A frame that enters paused or buffering and names no other uri than the
#     title we were on (no uri counts as the same) sets the candidate
#     (observed.holdReleaseFor) to that title.
#   - A frame naming another uri (including a buffering frame that announces
#     the new title), stopped and idle clear it; track_changed clears it on a
#     title change.
#   - A frame that enters playing from paused or buffering while the candidate
#     equals the title posts ONE release and clears the candidate.
# The daemon's statuses are buffering, paused, playing, stopped and idle (no
# "stalled"). At a natural end track_changed and its drain POST come first, so
# the release can only reach the shim after the drain consumed the hold.
# Never in idle without an active session.
sub _noteHoldRelease {
    my ($self, $status, $uri, $prevStatus, $prevTrack) = @_;
    return unless defined $status;
    my $o = $self->observed;

    if ($status eq 'stopped' || $status eq 'idle') {
        delete $o->{holdReleaseFor};
        return;
    }
    if (defined $uri && defined $prevTrack && $uri ne $prevTrack) {
        delete $o->{holdReleaseFor};    # another title: a change, not a resume
        return;
    }
    return if $self->mode eq 'idle' && !$o->{is_active};

    my $track = defined $uri ? $uri : $prevTrack;
    if ($status eq 'paused' || $status eq 'buffering') {
        $o->{holdReleaseFor} = $track if defined $track;
        return;
    }
    if ($status eq 'playing') {
        return unless defined $prevStatus && ($prevStatus eq 'paused' || $prevStatus eq 'buffering');
        my $cand = delete $o->{holdReleaseFor};
        return unless defined $cand && defined $track && $cand eq $track;
        $self->_postHoldRelease;
    }
    return;
}

# _postBoundaryRead($self, $path, $cb) -- 84-17 (L1 repair, channel decision
# in 84-L1-ATTRIBUTION.md `## 84-17 signal channel`): the same send as
# _postBoundary (the SAME _loopbackSend: non-blocking connect, ONE syswrite,
# at the SAME instant -- the boundary must still land before LMS' next
# `GET /stream`, so nothing about the send moves) but the socket is kept
# open and the shim's reply body (`via=live|departed|none boundary=.. anchor=..
# ring_fill=.. total_pushed=.. total_popped=.. drops=.. gen=..`) is read
# through Slim::Networking::Select::addRead -- ONE non-blocking sysread per
# callback, never a blocking read in LMS' single-threaded event loop (T-84-75)
# -- bounded by a BOUNDARY_REPLY_CAP_S timer. $cb is invoked EXACTLY ONCE
# with a hash ({ via => live|departed|none|timeout|unknown, ... }) and always
# from a LATER event-loop turn (a Select read or the cap timer), never from
# inside this call.
#
# Return value (the caller decides what a non-armed outcome means):
#   'unavailable'  nothing could be asked (no daemon, no stream port, or
#                  Slim::Networking::Select not loadable): the caller
#                  continues exactly as before this plan;
#   'failed'       the send failed (connect refused, partial write): $cb is
#                  NOT invoked; the caller resolves as 'unknown';
#   a CODE ref     armed; calling it aborts the wait without invoking $cb
#                  (shutdown / mode leave).
sub _postBoundaryRead {
    my ($self, $path, $cb) = @_;

    my $daemon   = $self->daemon or return 'unavailable';
    my $httpPort = $daemon->_streamPort or return 'unavailable';

    unless (eval { require Slim::Networking::Select; 1 }) {
        # No Select (a bare harness): keep today's fire-and-forget behaviour.
        $self->_loopbackPost($httpPort, $path);
        return 'unavailable';
    }

    my $sock = $self->_loopbackSend($httpPort, $path);
    unless ($sock) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: boundary signal failed (" . ($self->mac // '?') . ")"
        );
        return 'failed';
    }

    my $state = { buf => '', done => 0 };
    my ($capCb, $readCb);

    my $release = sub {
        eval { Slim::Networking::Select::removeRead($sock) };
        eval { close($sock) };
        Slim::Utils::Timers::killTimers($self, $capCb);
    };
    my $finish = sub {
        my ($reply) = @_;
        return if $state->{done};
        $state->{done} = 1;
        $release->();
        $cb->($reply);
    };

    $readCb = sub {
        return if $state->{done};
        my $chunk;
        my $n = $sock->sysread($chunk, 2048);
        if (!defined $n) {
            # EAGAIN/EINTR: the reply is not there yet -- stay registered.
            return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
            $finish->(_parseBoundaryReply($state->{buf}, 'read_error'));
            return;
        }
        if ($n == 0) {
            $finish->(_parseBoundaryReply($state->{buf}, 'eof_without_via'));
            return;
        }
        $state->{buf} .= $chunk;
        # Complete as soon as the body line is in (Content-Length framed text,
        # one line); otherwise the shim's close (EOF) or the cap ends it.
        if ($state->{buf} =~ /\r\n\r\n.*\bvia=\w+.*\n/s) {
            $finish->(_parseBoundaryReply($state->{buf}));
        }
    };
    $capCb = sub {
        $finish->({ via => 'timeout', reason => 'cap' });
    };

    Slim::Networking::Select::addRead($sock, $readCb);
    Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + BOUNDARY_REPLY_CAP_S, $capCb);

    return sub {
        return if $state->{done};
        $state->{done} = 1;
        $release->();
    };
}

# _parseBoundaryReply($raw, $reason) -- the shim's reply (status line, headers,
# blank line, `key=value ...` body) as a hash. A reply without a recognisable
# `via=` (an older shim answering an empty 200, a truncated read) is
# `via => 'unknown'` with a reason, never a guess.
sub _parseBoundaryReply {
    my ($raw, $reason) = @_;

    my (undef, $body) = split /\r\n\r\n/, ($raw // ''), 2;
    my %f;
    if (defined $body) {
        $f{$1} = $2 while $body =~ /\b(\w+)=(\S+)/g;
    }
    my $via = $f{via};
    if (!defined $via || $via !~ /^(?:live|departed|none)$/) {
        return { via => 'unknown', reason => ($reason // 'no_via') };
    }
    return \%f;
}

# _boundaryReplyLine($self, $reply) -- the ONE format of the evidence line
# (extract-run.pl category `Control: boundary reply via=`).
sub _boundaryReplyLine {
    my ($self, $reply) = @_;
    my $mac = $self->mac // '?';
    if (defined $reply->{reason}) {
        return "Control: boundary reply via=$reply->{via} reason=$reply->{reason} ($mac)";
    }
    return "Control: boundary reply via=$reply->{via}"
        . " anchor=" . ($reply->{anchor} // '?')
        . " boundary=" . ($reply->{boundary} // '?')
        . " ring_fill=" . ($reply->{ring_fill} // '?')
        . " drops=" . ($reply->{drops} // '?')
        . " ($mac)";
}

# _resolvePendingChange($self, $pc, $reply) -- 84-17: the single exit of a
# pending connect `change`. Emits it NOW with the shim's `via` as the wire's
# 4th positional, immediately followed by every verb queued behind it, in
# arrival order (so the wire order is always `change ... <via>` first).
# Idempotent: a change that is no longer THE pending one (already resolved
# by the reply, the cap, or a cancelling frame) is a no-op.
sub _resolvePendingChange {
    my ($self, $pc, $reply) = @_;

    my $cur = $self->observed->{pendingChange};
    return unless $cur && $cur == $pc;
    delete $self->observed->{pendingChange};

    $reply = { via => 'unknown', reason => 'no_reply' } unless ref($reply) eq 'HASH';
    my $via = $reply->{via} // 'unknown';

    if (defined $reply->{reason}) {
        $log->warn($self->_boundaryReplyLine($reply));
    }
    else {
        main::INFOLOG && $log->is_info && $log->info($self->_boundaryReplyLine($reply));
    }

    $self->_emit('change', $pc->{id}, $pc->{prevId}, undef, $via);
    for my $q (@{ $pc->{queued} }) {
        $self->_emit(@$q);
    }
    return;
}

# _cancelPendingChange($self, $why) -- a CANCELLING frame (a second
# track_changed for a different uri, playback_changed idle/stopped, a device/
# session end): resolve the pending change IMMEDIATELY as `unknown` (today's
# immediate path -- emit it now with its queue), then let the caller process
# the new frame as before. Never holds anything.
sub _cancelPendingChange {
    my ($self, $why) = @_;

    my $pc = $self->observed->{pendingChange} or return;
    $pc->{abort}->() if ref($pc->{abort}) eq 'CODE';
    $self->_resolvePendingChange($pc, { via => 'unknown', reason => "cancelled:$why" });
    return;
}

# _dropPendingChange($self, $why) -- shutdown / mode leave: the connect
# session the change belonged to is gone, so nothing is emitted (a late
# `change` would make Connect play a title the user left). The wait is
# aborted (read watcher removed, socket closed, cap timer killed).
sub _dropPendingChange {
    my ($self, $why) = @_;

    my $obs = $self->observed or return;
    my $pc = delete $obs->{pendingChange} or return;
    $pc->{abort}->() if ref($pc->{abort}) eq 'CODE';
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Control: pending change for $pc->{id} dropped ($why, " . ($self->mac // '?') . ")"
    );
    return;
}

# _hold($self) -- 84-17: the OPEN hold record of this Control, or undef. A
# record whose max_at has passed counts as absent and is deleted on read
# (expired: HOLD_MAX_S after it opened -- a genuinely stuck LMS is escalated
# by _checkSplitBrain/the watchdog exactly as before this plan).
sub _hold {
    my $self = shift;

    my $obs = $self->observed or return;
    my $h = $obs->{hold} or return;
    if (Time::HiRes::time() >= $h->{max_at}) {
        delete $obs->{hold};
        return;
    }
    return $h;
}

# clearHold($self, $uri) -- 84-17: Connect calls this when a hold closes (the
# deferred item's newsong, the cap/ceiling fallback BEFORE its `playlist
# play`, an H-c cancel). With a uri (spotify:track:<id>, spoton://track:<id>
# or a bare id) only the record of THAT title is cleared, so a stale close
# for an older hold never kills a newer one; without one it clears
# unconditionally. Cheap and idempotent.
sub clearHold {
    my ($self, $uri) = @_;

    my $obs = $self->observed or return;
    my $h = $obs->{hold} or return;
    if (defined $uri && length $uri) {
        my ($want) = $uri =~ /([A-Za-z0-9]{10,})\z/;
        return if defined $want && defined $h->{id} && $want ne $h->{id};
    }
    delete $obs->{hold};
    return;
}

# notePlaylistChanged($self) -- 84.2-02 (CAUSE-2, D-08): called by
# Connect.pm's _onLmsPlaylistChanged for an LMS playlist change (add,
# insert, move, delete, repeat, shuffle). Browse only -- in connect the
# daemon owns the queue (Pitfall 4). Raises the prefetch wish and tries to
# consume it at once; with a command pending it waits for the settle point.
sub notePlaylistChanged {
    my $self = shift;
    return unless $self->mode eq 'browse';
    $self->observed->{prefetchWish} = 1;
    $self->_consumePrefetchWish;
    return;
}

# _consumePrefetchWish($self) -- 84.2-02: the ONE consumer of
# observed.prefetchWish. Only at a settle point: browse, nothing pending (an
# add_to_queue with no play pending opens a slot and would supersede an
# open seek/set_volume slot -- the WR-02 class), the daemon on the wanted
# title, no open late-echo window. The wish is deleted BEFORE _prefetchNext
# so a successor-less attempt does not re-fire on every frame; the next LMS
# playlist change (or the next Treffer) raises it again. Idempotent through
# plan 01's own-queue set and the queueUris dedupe.
sub _consumePrefetchWish {
    my $self = shift;
    my $obs  = $self->observed;
    return unless $obs->{prefetchWish};
    unless ($self->mode eq 'browse') {
        delete $obs->{prefetchWish};
        return;
    }
    return if $self->pending;
    return unless defined $obs->{track} && $obs->{track} eq ($self->wanted->{uri} // '');
    return if $obs->{expectEcho} && ($obs->{expectEcho}{until} // 0) > Time::HiRes::time();
    delete $obs->{prefetchWish};
    $self->_prefetchNext;
    return;
}

# _prefetchNext($self) -- D-C, eingefuehrt (82-06 Task 1): `add_to_queue`
# had no caller anywhere in Plugins/SpotOn/** before this plan (RESEARCH) --
# "beibehalten" from 81-DECISIONS was moot; D-02 is what makes introducing
# it worthwhile (the watchdog no longer overwrites the result before it
# reaches LMS). S-01 A measured add_to_queue(Y) winning deterministically
# in 3/3 runs when sent BEFORE the boundary. Gegenargument mitgefuehrt:
# one more WS message per track, one more echo case (queue_changed); in
# the LMS-driven setup no boundary was ever planted per track boundary
# (S-01 B) -- whether the EOF cycle reliably reaches LMS within
# WATCHDOG_ROUND_S against a real LMS is unmeasured until M-3(c) (82-07).
# Reversibility: reversible (one _dispatch call site, one observed field).
sub _prefetchNext {
    my $self = shift;

    my $client = Slim::Player::Client::getClient($self->mac) or return;

    my $idx = Slim::Player::Source::streamingSongIndex($client);
    $idx = Slim::Player::Source::playingSongIndex($client) unless defined $idx;
    return unless defined $idx;

    # 84.2-02 (CAUSE-2 repeat wrap): the next index LMS will play, computed
    # side-effect free after StreamingController::nextsong (:848-897; never
    # call it -- it reshuffles at a wrap). repeat: 0 none, 1 song, 2 all.
    # repeat-one re-plays the same uri (a queued copy would be a replay);
    # at the end of the list only repeat-all wraps to 0, and not when
    # shuffle + reshuffleOnRepeat makes the next title unknown until LMS
    # reshuffles. Playlist::track, not the deprecated song (Pitfall 10:
    # song logs a WARN per call).
    my $count  = Slim::Player::Playlist::count($client) // 0;
    my $repeat = Slim::Player::Playlist::repeat($client) // 0;
    return if $repeat == 1;
    my $n = $idx + 1;
    if ($n >= $count) {
        return unless $repeat == 2;
        return if Slim::Player::Playlist::shuffle($client) && preferences('server')->get('reshuffleOnRepeat');
        $n = 0;
    }

    my $next = Slim::Player::Playlist::track($client, $n) or return;
    my $url  = $next->url // '';

    # Only a track qualifies -- add_to_queue accepts spotify:track: only
    # per the Web API (Note §2.2); a differently-typed next entry is left
    # alone, no command sent.
    return unless $url =~ m{^spoton://track:([A-Za-z0-9]+)$};

    # 82-23 WR-03 (Plan-Check-Korrektur B1): the origin marker for the
    # foreign-track_changed guard above -- proves SPOTON queued this uri,
    # as opposed to `queuedNext`, which the daemon's own queue_changed
    # frame sets unconditionally regardless of who queued it.
    #
    # 84.2-01 (D-07 / IN-04): the marker is a SET entry, written only once
    # SpotOn's claim is real -- after a successful add_to_queue send, or in
    # the dedupe branch below. A failed send leaves no marker.
    my $nextUri = "spotify:track:$1";

    # 84.2-02 same-uri guard: a repeat-all wrap on a one-entry playlist lands
    # on the playing title itself. Queued, the daemon would consume its own
    # queue head without a track_changed and _onQueueHeadReplay would pause
    # it as `restarted unrequested` -- a self-inflicted pause.
    if ((defined $self->observed->{track} && $nextUri eq $self->observed->{track})
        || (defined $self->wanted->{uri} && $nextUri eq $self->wanted->{uri}))
    {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: prefetch skipped, $nextUri is the playing title (" . ($self->mac // '?') . ")"
        );
        return;
    }

    # 84-19 F-18-N4 change 1: never queue a uri the daemon's user queue
    # already holds (it keeps entries across title jumps and restarts and
    # has no remove -- each re-prefetch after a jump added a duplicate,
    # same-1 10:29:57.394: [6d0c, 5EZh, 5EZh]). The origin marker is still
    # set: the entry is in the queue and LMS chose it as the successor, so
    # the natural advance to it must stay a recognised prefetch hit, not a
    # foreign title.
    if (grep { $_ eq $nextUri } @{ $self->observed->{queueUris} || [] }) {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            "Control: prefetch skipped, $nextUri is already a queue entry (" . ($self->mac // '?') . ")"
        );
        $self->_markOwnQueue($nextUri);
        return;
    }

    # Idempotent per uri: already queued by us in this session -> no second send.
    return if ref($self->observed->{queuedByUs}) eq 'HASH' && exists $self->observed->{queuedByUs}{$nextUri};

    if ($self->_dispatch('add_to_queue', uri => $nextUri)) {
        $self->_markOwnQueue($nextUri);
    }
}

# _markOwnQueue($self, $uri) -- 84.2-01: add one own queue entry to the set
# (`observed.queuedByUs`), dropping the oldest past OWN_QUEUE_MAX.
sub _markOwnQueue {
    my ($self, $uri) = @_;
    $self->observed->{queuedByUs} = {} unless ref($self->observed->{queuedByUs}) eq 'HASH';
    my $q = $self->observed->{queuedByUs};
    $q->{$uri} = Time::HiRes::time();
    while (keys(%$q) > OWN_QUEUE_MAX) {
        my ($oldest) = sort { $q->{$a} <=> $q->{$b} || $a cmp $b } keys %$q;
        delete $q->{$oldest};
    }
    return;
}

# _armSync($self) -- RESEARCH "Synchroner Loopback-Arm" Code Example,
# updated (82-12, CR-05; 82-19 F2). Pitfall 2 / 78-UAT-10: onStream has NO
# callback and $player->play follows in the SAME loop
# (StreamingController.pm:1311-1327) -- an armed-but-async POST would
# still be in flight when the new GET attaches, reproducing the 78-UAT-10
# unarmed-flush signature. Sending the arm POST from THIS call site (via
# _loopbackPost), before the caller's own WS command goes out, keeps arm
# before flush a SEND-ORDER guarantee, not a processing-order one: no
# response is ever read here, so this only proves the bytes left in the
# right order, not that fake-libpulse acted on them before the flush
# arrived. 81-DECISIONS D-B measured this ordering 30/30 correct with a
# 70ms p95 gap between arm and flush -- that supports the assumption, it
# does not prove it, and D-B's own validity boundary still applies: the
# arm is only ever reached on the mismatch path (Control.pm:_reconcile
# Schritt 5), never on a same-track position change. The name `_armSync`
# describes the CALL SITE (synchronous, inside the LMS command path) --
# not blocking, since CR-05 replaced the blocking socket with a
# non-blocking one via _loopbackPost.
#
# 82-19 F2: this is now the ONLY arm path -- the former async HTTP-client
# arm (`_armAsync`/`SimpleAsyncHTTP`, keyed off a `sync` channel marker)
# is gone. That channel used to wait for the daemon's own 200 before
# running its send closure, which was the only PROCESSING-order guarantee
# on the getNextTrack path; `_loopbackPost` only ever gave a SEND-order
# guarantee, never processing-order. Trading the former away is a real
# tradeoff, and it is accepted for two reasons:
# (a) H-ii widerlegt auf dem Direktpfad (A1, 2/2); Proxy-Pfad: 82-G1-MESSUNG.md ## Proxy-Gegenlauf 82-19
#     -- H-ii (arm lands AFTER the flush it should cover) is refuted on
#     the direct-streaming path with the one run that had arms arrive at
#     all (A1: both `seek_arm: armed=1` lines preceded their flush), but
#     the proxy path has its own verdict line there, not assumed from
#     A1 -- see 82-G1-MESSUNG.md ## Berichtigung 82-19 for the corrected
#     record this tradeoff rests on.
# (b) the async arm this replaces never actually arrived in six of six
#     recorded post-fix opportunities (server.log 09:31:26.8688 ..
#     09:53:04.7944, Control.pm:2241) -- a guarantee that never lands is
#     not a guarantee.
# Degrade-open (T-77-10): the caller's command is sent regardless of arm
# success.
sub _armSync {
    my ($self) = @_;

    my $daemon = $self->daemon;
    my $port   = $daemon && $daemon->_streamPort;
    unless ($port) {
        $log->warn("Control: no stream port yet -- skipping sync arm (" . ($self->mac // '?') . ")");
        return 0;
    }

    my $ok = $self->_loopbackPost($port, '/seek-arm');
    if ($ok) {
        # 82-23 WR-04: a following successful arm resolves whatever
        # 'arm' ring entry a prior failure wrote.
        $self->_clearErrorOnce('arm');
    }
    else {
        $log->warn("Control: sync seek-arm failed (" . ($self->mac // '?') . ")");
        $self->_recordErrorOnce('arm', 'warn', ($self->mac // '?') . ": sync seek-arm failed");
    }
    return $ok ? 1 : 0;
}

# _recordErrorOnce($self, $key, $level, $message) -- errors[] is a Ring 30
# with NO dedupe (Status.pm:57-69) -- the caller must only report on a
# state TRANSITION, or an unpaired daemon answering every 'play' with
# 'error' floods the ring within seconds. $key tracks which state has
# already been reported; auth_state.logged_in clears 'unpaired', an echo
# clears 'drift:<uri>' -- both via _clearErrorOnce (82-11), the one
# removal path matching this one write path. The key reaching Status.pm is
# mac-qualified so two daemons never clear each other's entries (82-11,
# WR-05 Fall D).
#
# 82-11 (Todo errors-startup-falschmeldung-nicht-paired): 'unpaired'
# additionally gets a startup grace window -- a daemon younger than
# UNPAIRED_GRACE_S is still restoring its session (measured live: 7-10 s
# after LMS start), and a transient state that reports as a durable ring
# entry is indistinguishable from a real (g)-finding without checking the
# timestamp by hand. This suppresses ONLY the ring write and the dedupe
# lock -- observed.paired is already 0 (set by the caller before this
# runs) and every request keeps failing fast regardless.
sub _recordErrorOnce {
    my ($self, $key, $level, $message) = @_;

    if ($self->observed->{errorsReported}{$key}) {
        # 82-28 (WR-02, Review Runde 3): the dedupe lock above does not
        # know when Status.pm's ring has evicted this entry via
        # MAX_ERROR_HISTORY's shift -- the two states can diverge, and the
        # lock outliving the ring entry it mirrors is exactly the defect
        # this plan closes. Ask the ring directly before trusting the
        # local lock.
        my $stillThere = 0;
        eval {
            require Plugins::SpotOn::Status;
            $stillThere = Plugins::SpotOn::Status->hasError('Soloist', ($self->mac // '?') . ':' . $key) ? 1 : 0;
            1;
        };
        return if $stillThere;
        # The entry fell out through the ring boundary; the lock is now a
        # mirror without a subject. Write again instead of staying silent.
        # A failed hasError() query above leaves $stillThere at 0, so this
        # also runs -- a doubled entry is visible and harmless, a
        # swallowed error is exactly the defect being fixed.
    }

    if ($key eq 'unpaired' && $self->daemon && $self->daemon->can('uptime')
        && $self->daemon->uptime < UNPAIRED_GRACE_S)
    {
        return;
    }

    $self->observed->{errorsReported}{$key} = 1;

    eval {
        require Plugins::SpotOn::Status;
        Plugins::SpotOn::Status->recordError($level, 'Soloist', $message, ($self->mac // '?') . ':' . $key);
        1;
    };
    $log->warn($message);
}

# _clearErrorOnce($self, $key) -- the one removal path matching
# _recordErrorOnce's one write path (82-11, Todo
# errors-startup-falschmeldung-nicht-paired): resets the dedupe lock AND
# removes the ring entry itself, mac-qualified the same way it was
# written. eval-guarded like _recordErrorOnce -- a Status.pm load failure
# must not abort event processing.
sub _clearErrorOnce {
    my ($self, $key) = @_;

    $self->observed->{errorsReported}{$key} = 0;

    eval {
        require Plugins::SpotOn::Status;
        Plugins::SpotOn::Status->clearError('Soloist', ($self->mac // '?') . ':' . $key);
        1;
    };
}

# _emitAllowed($self) -- 1:1 from SoloistWS::_emitAllowed (Analog H): the
# per-player Connect toggle gate. Callers: `_emit` (the emission gate) and the
# two transfer-in entries (_onFramePlaybackState reconnect adoption,
# _onFrameDeviceChanged), which ask it before binding the claim / entering
# mode=connect (84-21, D-31 (1)).
sub _emitAllowed {
    my $self = shift;

    my $client = Slim::Player::Client::getClient($self->mac);
    return 0 unless $client;

    my $enabled = $prefs->client($client)->get('enableSpotifyConnect')
        // $prefs->get('enableSpotifyConnect');
    return $enabled ? 1 : 0;
}

# _refuseTransferConnectOff($self, $entry) -- 84-21 (D-31 (1)): the Connect
# switch is off for this player and a transfer-in arrived. "Visible but
# refusing": the daemon stays visible in the app (no discovery flag to hide it,
# SoloistDaemon.pm), so Control refuses the transfer instead -- no claim bind,
# no mode('connect'), no write to `wanted->{uri}`; the caller returns.
#   idle   -> probe `deactivate` (the op leaveConnect uses; sendable while
#             inactive) + one errors[] entry. The probe op itself logs no
#             dispatch line, so the INFO line below (deactivate=sent|no_ws,
#             computed with the probe's own ws test BEFORE _execute) is the
#             only server.log channel of the deactivate.
#   browse -> NO deactivate (it would end the daemon's session and starve the
#             single-slot Browse stream); the errors[] entry plus a re-assert of
#             the wanted title through _reconcile (the deferred re-run form).
#             Never an LMS command either way (@EXECUTED stays empty).
# The error key is cleared again on the next ALLOWED transfer-in.
sub _refuseTransferConnectOff {
    my ($self, $entry) = @_;

    my $mac    = $self->mac // '?';
    my $mode   = $self->mode // 'idle';
    my $browse = ($mode eq 'browse') ? 1 : 0;

    my $deactivate = 'not_sent';
    if (!$browse) {
        $deactivate = ($self->daemon && $self->daemon->_ws) ? 'sent' : 'no_ws';
    }

    main::INFOLOG && $log->is_info && $log->info(
        "Control: transfer-in refused -- Spotify Connect is off for this player (entry=" . ($entry // '?')
        . ", mode=" . $mode . ", deactivate=" . $deactivate . ", " . $mac . ")"
    );

    my @intents;
    push @intents, { op => 'probe', cmd => 'deactivate' } unless $browse;
    push @intents, {
        op      => 'error',
        key     => 'connect-off:' . $mac,
        level   => 'warn',
        message => $mac . ": Spotify Connect is switched off for this player -- transfer refused",
    };
    $self->_execute(\@intents);

    if ($browse) {
        # Re-assert the wanted title: the clock is LMS' (songTime), kept as is
        # when there is no client or no readable time.
        my $client = Slim::Player::Client::getClient($mac);
        my $t = $client ? eval { Slim::Player::Source::songTime($client) } : undef;
        if (defined $t && $t =~ /^\d+(?:\.\d+)?$/ && ref $self->wanted eq 'HASH') {
            $self->wanted->{position_ms} = int($t * 1000 + 0.5);
        }
        $self->_reconcile('requestTrack', { source => 'connect-off' });
    }

    return;
}

# _emit($self, $cmd, $p2, $p3) -- 1:1 from SoloistWS::_emit (Analog H), but
# the mode-policy replaces the old soloistBrowseActive flag (Prinzip
# 3.1(3)): browse only ever surfaces a volume echo (D-06, 82-05); idle only
# surfaces the inactive stop; connect (Phase 83) allows everything. Unused
# until 82-03/82-05 wire a caller.
# _emit($self, $cmd, $p2, $p3, $origin, $p4) -- 83.1-02 Task 2: `$origin` is a
# 5th, OPTIONAL argument naming the emission's origin (e.g. 'nachziehen'
# from _connectResync). It is NOT part of the `spottyconnect` command
# itself (the wire command stays [$cmd, $p2, $p3] exactly as before) -- it
# exists purely so a caller (plan 03's arming hook) can tell a split-brain
# ladder re-emit apart from a normal daemon-driven emission.
#
# 84-17: `$p4` is a 6th, OPTIONAL argument -- the wire's 4th positional
# (`_p4` in Connect.pm). It is appended to the wire ONLY when defined, so the
# librespot path and every `nachziehen` re-emit keep the 4-element command
# byte for byte. Carriers: `change` -> the shim's `via` (live|departed|none|
# timeout|unknown), `seek` -> `deferred` (the echo of the changed item).
#
# 84-17 queue: while a connect `change` awaits the shim's reply
# (observed->{pendingChange}), every OTHER verb that would reach the wire is
# queued behind it in arrival order -- the wire order is always
# `change ... <via>` first. A new `change`/`start` or the session-end `stop
# inactive` cancels the classification instead (the pending one is emitted
# `unknown` with its queue, then this verb goes out immediately).
sub _emit {
    my ($self, $cmd, $p2, $p3, $origin, $p4) = @_;

    return unless $self->_emitAllowed;

    my $mode = $self->mode;
    if ($mode eq 'browse') {
        return unless $cmd eq 'volume';
    }
    elsif ($mode eq 'idle') {
        return unless $cmd eq 'stop' && defined $p2 && $p2 eq 'inactive';
    }

    if (my $pc = $self->observed->{pendingChange}) {
        if ($cmd eq 'change' || $cmd eq 'start'
            || ($cmd eq 'stop' && defined $p2 && $p2 eq 'inactive'))
        {
            $self->_cancelPendingChange("superseded by $cmd");
        }
        else {
            # The echo of the changed item (a position_sync-derived seek)
            # carries the `deferred` marker so Connect can tell it from an
            # app seek (84-17 Task 2 drops it during a hold).
            $p4 = 'deferred' if $cmd eq 'seek' && !defined $p4;
            push @{ $pc->{queued} }, [ $cmd, $p2, $p3, $origin, $p4 ];
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Control: $cmd queued behind the pending change for $pc->{id} (" . ($self->mac // '?') . ")"
            );
            return;
        }
    }

    # 84-17 hold record and the deferred marker. A `live` change opens the
    # hold (Control knows the via; Connect owns only the LMS-side deferral);
    # any other change, a `start` or the session-end `stop inactive` closes
    # it. While it is open EVERY seek/resume Control emits carries `deferred`
    # as the 4th positional -- the daemon's own end-of-write position_sync
    # pair and the post-change storm must reach neither the playing song nor
    # the new one (Connect drops them; H-h).
    if ($mode eq 'connect') {
        if ($cmd eq 'change') {
            if (defined $p4 && $p4 eq 'live') {
                my $now = Time::HiRes::time();
                $self->observed->{hold} = {
                    uri    => $self->observed->{track},
                    id     => $p2,
                    since  => $now,
                    max_at => $now + HOLD_MAX_S,
                };
            }
            else {
                delete $self->observed->{hold};
            }
        }
        elsif ($cmd eq 'start' || ($cmd eq 'stop' && defined $p2 && $p2 eq 'inactive')) {
            delete $self->observed->{hold};
        }
        elsif (($cmd eq 'seek' || $cmd eq 'resume') && !defined $p4 && $self->_hold) {
            $p4 = 'deferred';
        }
    }

    # 83.1-03 (D-A1/D-A3 Nachtrag P2-B2, checker r3 W1): connect -- the only
    # thing to watch is whether LMS re-opens. A `change` is a daemon-driven
    # (re-)open request UNLESS its origin is the split-brain ladder's own
    # 'nachziehen' re-emit (that re-emit is not a NEW ask, so it must never
    # re-arm this clock -- the watchdog fires ONCE per incident), or the
    # emitted uri already has an open incident on the shared record
    # (observed->{splitBrain}{uri} eq this uri, attempts>=1 -- a same-uri
    # daemon track_changed during that incident is not a new one either). A
    # NEW uri always arms a fresh clock even with a stale record for a
    # DIFFERENT (old) uri still present -- the plan-02 record resets on the
    # uri change.
    if ($mode eq 'connect' && $cmd eq 'change') {
        my $emitUri = $self->observed->{track};
        if (defined $emitUri && (($origin // '') ne 'nachziehen')) {
            my $sb = $self->observed->{splitBrain};
            my $openIncident = $sb && defined $sb->{uri} && $sb->{uri} eq $emitUri
                && (($sb->{attempts} // 0) >= 1);
            # 84-17: a `live` change is deliberately NOT re-opened by LMS for
            # up to HOLD_MAX_S (the buffered tail plays first) -- its watchdog
            # gets the EXTENDED deadline HOLD_MAX_S + CONNECT_WATCHDOG_S; LMS's
            # re-open (requestTrack at STMd) cancels it as always.
            my $window = (defined $p4 && $p4 eq 'live') ? (HOLD_MAX_S + CONNECT_WATCHDOG_S) : undef;
            $self->_armConnectWatchdog($emitUri, $window) unless $openIncident;
        }
    }

    my $client = Slim::Player::Client::getClient($self->mac);
    return unless $client;

    my @wire = ('spottyconnect', $cmd, $p2 // '', $p3 // '');
    push @wire, $p4 if defined $p4;
    $client->execute(\@wire);
}

# leaveConnect($self, $reason) -- D-02 (84.1-02-PLAN.md:30/:35/:39-70,
# reused unchanged): the counterpart to leaveBrowse for the connect
# session. Foreign LMS content arriving while Control is in `connect`
# means the user switched away from Spotify -- SpotOn must give the
# Connect session up cleanly: release the claim, stop watching for the
# stale re-open, forget the old session marker, and go idle. Called
# from Connect.pm _onNewSong's url-class guard (mode connect, a
# non-empty url that is not spoton://).
#
# Nothing else goes in this sub:
# - no emission towards LMS and no command to the daemon beyond the
#   self-scoped deactivate probe below (the documented exception
#   84.1-02-PLAN.md:70 already made: only a device-level release makes
#   the app drop the device);
# - pending requests and observed.splitBrain stay untouched, in parity
#   with the is_active:0 connect half (Control.pm:3834-3846).
#   _connectResync is only reached through mode-guarded callers;
# - no leftBrowseUri, which is a browse-only marker.
#
# Order: state goes first, so the daemon's is_active:0 echo meets mode
# idle -- in idle, _onFrameDeviceChanged only clears is_active, because
# the session-end emission is gated on mode connect
# (Control.pm:3834-3839). So LMS never pauses the foreign content.
sub leaveConnect {
    my ($self, $reason) = @_;

    return unless $self->mode eq 'connect';

    eval {
        require Plugins::SpotOn::Connect;
        my $client = Slim::Player::Client::getClient($self->mac);
        Plugins::SpotOn::Connect->releaseConnectClaim($client, $reason // 'foreign-lms-content') if $client;
        1;
    };

    $self->_cancelConnectWatchdog;

    # 84-17: the session a pending change belonged to is gone -- nothing is
    # emitted for it (a late `change` would play a title the user left).
    $self->_dropPendingChange('leaveConnect');
    delete $self->observed->{hold};

    # A tap-back is a fresh session -- it gets 'start', not 'resume'.
    delete $self->observed->{startEmittedFor};

    # T-84.1-29/T-84.1-30: the pending-state marker the re-adoption
    # guard (_holdAfterForeignLeave) reads, cleared wherever this
    # post-leave episode provably ends (see the table in the plan's
    # Step 2b).
    $self->observed->{leftConnectForeign} = 1;
    # 84-26 R2 clear (c) (hygiene): the session the marker could have belonged to is gone.
    delete $self->observed->{autoplayPaused};
    delete $self->observed->{entryResume};    # 84-26 F-24-2: same hygiene for the transfer-in resume marker

    $self->mode('idle');
    $self->wanted({});

    main::INFOLOG && $log->is_info && $log->info(
        "Control: LMS plays foreign content in connect -- leaveConnect (" . ($self->mac // '?') . ")"
    );

    # IN-04 (84.1-REVIEW.md, D-02): a WS that is already known to be down
    # (Control's own observed.wsConnected, cleared by _transportClosed
    # in the same call SoloistWS.pm:205-232 tears down the transport)
    # means the deactivate probe below has no live daemon to reach --
    # _execute's own probe branch (Control.pm ~2515-2520) silently drops
    # the send AND the stamp when daemon->_ws is undef, and sendCommand
    # itself only DEBUG-logs a drop on a connected-but-unreachable object
    # (SoloistWS.pm:285-310). Neither is visible without this line. The
    # release above and the state reset below are unconditional either
    # way; only this notice and the probe attempt itself are affected.
    if (!$self->observed->{wsConnected}) {
        main::INFOLOG && $log->is_info && $log->info(
            "Control: leaveConnect without a WS connection -- deactivate not sent, the daemon may stay the active device ("
            . ($self->mac // '?') . ")"
        );
    }

    $self->_execute([ { op => 'probe', cmd => 'deactivate' } ]);
}

# _holdAfterForeignLeave($self) -- T-84.1-29: guards the reconnect
# adoption in _onFramePlaybackState (Control.pm:3474) against a
# playback_state(is_active,playing) frame landing after leaveConnect
# but before the daemon's deactivate echo, which would otherwise
# restart Spotify in LMS and replace whatever the user just started --
# the opposite of D-02. A pending-state marker plus a url class, never
# a time window (Pitfall 4): held only while leftConnectForeign is set
# AND the daemon reports playing AND LMS is not on our own material.
# Returns 1 (hold) or 0 (clear to adopt), and self-clears the marker
# once LMS no longer plays foreign content -- one of several clear
# points (see leaveConnect's comment and the plan's Step 2b table), not
# the only one; it only runs when consulted.
sub _holdAfterForeignLeave {
    my $self = shift;

    # 84-26 R3 (F-24-1): second clause of the SAME predicate, placed BEFORE the leftConnectForeign
    # early return (after it that return would skip this clause). The autoplay guard (or its replay
    # sibling) paused the title the daemon sits on (`observed.autoplayPaused`), and an LMS-internal
    # unpause may have resumed it: a playing, is_active frame on exactly that title while LMS plays
    # foreign content (a local file) is NOT a phone-side Connect start -- adopting it would flip
    # mode connect under a local file (84-24 B7). Same clause shape as T-84.1-29 below (a pending-state
    # marker plus a url class, never a time window). Accepted asymmetry (the guard documents the same
    # one at its own site): a phone press on exactly the autoplay-paused title WHILE LMS plays a local
    # file is not adopted until LMS leaves the foreign content or the daemon moves to another title
    # (the next track_changed to another uri clears the marker).
    my $ap = $self->observed->{autoplayPaused};
    if (defined $ap) {
        my $track  = $self->observed->{track};
        my $client = Slim::Player::Client::getClient($self->mac);
        if (defined $track && $ap eq $track && $client
            && ((Slim::Player::Source::playmode($client) // '') eq 'play')
            && !$self->_lmsSongIsOurs)
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Control: daemon plays the autoplay-paused title $track while LMS plays foreign content -- not re-adopting ("
                . ($self->mac // '?') . ")"
            );
            return 1;
        }
        # the predicate falls through (LMS is not on foreign content): the adoption that follows is a
        # legitimate Connect start (D-02) -- the marker has served its purpose.
        delete $self->observed->{autoplayPaused};
    }

    # 84.2-05 (B7): third clause, same shape as the R3 clause above. leaveBrowse left a title
    # whose context end SpotOn planted (`observed.leftBrowsePlanted`); LMS's own rebuffer unpause
    # may have resumed it at the daemon. A playing, is_active frame on exactly that title while
    # LMS plays foreign content is NOT a phone-side Connect start (the 2026-10-09 22:05:45 chain
    # pulled LMS off a local file). Marker + url class, never a time window. The same accepted
    # asymmetry as R3: a phone press on exactly that title WHILE LMS plays a local file is not
    # adopted until LMS leaves the foreign content or the daemon moves to another title.
    my $lbp = $self->observed->{leftBrowsePlanted};
    if (defined $lbp) {
        my $track  = $self->observed->{track};
        my $client = Slim::Player::Client::getClient($self->mac);
        if (defined $track && $lbp eq $track && $client
            && ((Slim::Player::Source::playmode($client) // '') eq 'play')
            && !$self->_lmsSongIsOurs)
        {
            main::INFOLOG && $log->is_info && $log->info(
                "Control: daemon plays the context-end title $track LMS left while LMS plays foreign content -- not re-adopting ("
                . ($self->mac // '?') . ")"
            );
            return 1;
        }
        # falls through (LMS stopped or on our own material, or another title): the adoption is
        # legitimate (D-02) -- the marker has served its purpose.
        delete $self->observed->{leftBrowsePlanted};
    }

    return 0 unless $self->observed->{leftConnectForeign};

    my $client = Slim::Player::Client::getClient($self->mac);
    if ($client
        && ((Slim::Player::Source::playmode($client) // '') eq 'play')
        && !$self->_lmsSongIsOurs)
    {
        main::INFOLOG && $log->is_info && $log->info(
            "Control: daemon reports playing after leaveConnect while LMS plays foreign content -- not re-adopting ("
            . ($self->mac // '?') . ")"
        );
        return 1;
    }

    delete $self->observed->{leftConnectForeign};
    return 0;
}

# endForeignLeave($self, $why) -- T-84.1-30: an explicit clear point for
# the leftConnectForeign marker, for callers outside the mode-entry
# paths above (Connect.pm _onLmsStop: an LMS stop or playlist clear
# ends the foreign content, and with it the post-leave episode).
sub endForeignLeave {
    my ($self, $why) = @_;
    delete $self->observed->{leftConnectForeign};
    return;
}

1;
