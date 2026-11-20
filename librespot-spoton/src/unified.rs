// SpotOn librespot-spoton/src/unified.rs
//
// Phase 29-01 implementation: --unified mode
//
// Provides:
//   run_unified(): single entry point combining Browse (GET /track/{id}) and
//   Connect (GET /stream, POST /control/*, Spirc) in one librespot process per player.
//
// Architecture decisions (from 29-RESEARCH.md):
//   D-01: Spirc only starts when --enable-connect is passed
//   D-02: Shared Session for Browse and Connect (audio-key cache reused)
//   D-03: Session connects immediately at daemon start
//   D-04: Dynamic port binding (:0 + stdout announcement)
//   D-05: ONE combined HTTP server on ONE port
//   D-09: Connect takes over Browse — browse_cancel.notify_waiters() -> EOF to LMS
//   D-10: Browse preempts Connect — Spirc pause, Browse loads its own Player
//   D-11: Stream-based EOF for transition notification
//   Pitfall 4: Announce "stream_port=N" (not "unified_port=N") — Perl regex matches this key
//
// PITFALL NOTES (from 29-RESEARCH.md — read before modifying):
//   Pitfall 1: Never let Browse Player and Connect Player call load() simultaneously.
//              ActiveMode mutex enforces sequential Player::load() calls.
//   Pitfall 2: After Browse preemption, drain Connect pcm_rx and close relay's conn_tx.
//              RelayGuard drop clears relay_active. browse_preempting AtomicBool signals relay.
//   Pitfall 3: Race between Spirc TrackChanged and Browse request.
//              Both sides check ActiveMode mutex before proceeding.
//   Pitfall 4: Use "stream_port=N" for stdout announcement (not "unified_port=N").
//   Pitfall 5: Rate-limiting is FORBIDDEN in BrowseHttpSink. Only UnifiedHttpStreamSink (Connect) is rate-limited.

use std::io::Write as IoWrite;
use std::sync::{Arc, atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, Ordering}};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full, StreamBody, combinators::BoxBody};
use hyper::{Method, Response, StatusCode};
use hyper::body::Frame;
use hyper::server::conn::http1 as HyperHttp1;
use hyper_util::rt::TokioIo;
use hyper_util::server::graceful::GracefulShutdown;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt as TokioStreamExt;

use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::Session;
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use librespot_playback::{NUM_CHANNELS, SAMPLE_RATE};

use librespot_discovery::DeviceType;

use crate::connect::LMS;
use crate::browse::{serve_track_request, empty_response};

// -------------------------------------------------------------------------
// ActiveMode — shared Browse/Connect mode state
// -------------------------------------------------------------------------

/// Tracks which mode currently owns the audio output path.
///
/// Protected by Arc<tokio::sync::Mutex<ActiveMode>> so that the HTTP request
/// handlers and the Spirc event loop can coordinate transitions atomically.
///
/// Transitions (all hold the mutex lock before acting):
///   Idle -> Connect:        Spirc fires TrackChanged/Playing while in Idle
///   Connect -> Browse(id):  GET /track/{id} arrives while Connect is active (D-10)
///   Browse(id) -> Connect:  Spirc fires TrackChanged while Browse is active (D-09)
///   Browse(id) -> Idle:     Browse track completes (EndOfTrack/Stopped)
///   Connect -> Idle:        Spirc session ends (not typical; left for completeness)
///   Idle -> Browse(id):     GET /track/{id} arrives while Idle
#[derive(Debug, Clone, PartialEq)]
enum ActiveMode {
    Idle,
    Connect,
    Browse(String), // String = track_id currently streaming
}

fn advance_connect_track_generation(
    event: &PlayerEvent,
    current_track: &mut Option<String>,
    track_gen: &AtomicU64,
) {
    if let PlayerEvent::TrackChanged { audio_item } = event {
        let new_id = audio_item.track_id.to_id();
        if current_track.as_deref() != Some(new_id.as_str()) {
            let prev = current_track.replace(new_id.clone());
            let gen = track_gen.fetch_add(1, Ordering::AcqRel) + 1;
            log::info!(
                "[spoton/unified] Connect TrackChanged {:?} -> {} — track_gen={}",
                prev.as_deref().unwrap_or("none"),
                new_id,
                gen
            );
        }
    }
}

/// How long a Browse `/track/` or `/episode/` request waits for the Player's first real
/// signal (the first audio chunk, or the verdict of `serve_track_request`) before it gives
/// up. 89-09 (ACC-02): the status line is decided by that signal, never by a timer. Before,
/// the handler answered `200 OK` after a fixed 500 ms and a verdict that came later could
/// only end the body with 0 bytes, which LMS starts as a short track.
///
/// The value sits between three other clocks:
/// - above the fork's key timeout chain (`KEY_RESPONSE_TIMEOUT` 1.5 s, three attempts,
///   4.5 s), so a dead key channel still reaches the 404 arm as a verdict and counts
///   toward the reconnect;
/// - below the 15 s LMS waits for a status line when it opens the stream itself (proxy
///   mode, sync groups, transcoding: `Slim::Formats::RemoteStream::request` reads it with
///   a blocking `sysreadline`, server pref `remotestreamtimeout`, default 15). LMS is
///   blocked for that read, so the bound is also the longest such block;
/// - below the about 58 s after which the fork hands back a code-2 refusal (`request`
///   asks again at 3, 8, 18 ... 58 s). Phase 88 Pitfall 4: such a refusal must not reach
///   the 404 arm (it would count toward the reconnect); the request has given up long
///   before, and the give-up arm does not count.
/// squeezelite itself puts no limit on the wait for headers (10 s on the TCP connect only).
const BROWSE_FIRST_SIGNAL_BOUND: Duration = Duration::from_secs(10);

/// The first thing a Browse title request learns from its serve task.
#[derive(Debug, PartialEq)]
enum BrowseFirstSignal {
    /// The first audio chunk: the title plays.
    Audio(Bytes),
    /// `serve_track_request` ended before any audio (404 unavailable, 409 superseded, ...).
    Verdict(StatusCode),
    /// The serve task was dropped before any audio and without a verdict (aborted by the
    /// Connect takeover listener).
    Aborted,
    /// Neither audio nor a verdict within the bound.
    NoAnswer,
}

/// Waits for the first real signal of a Browse title request. Audio wins over a verdict
/// that is ready at the same time (a title that fits the channel whole still plays).
async fn browse_first_signal(
    pcm_rx: &mut mpsc::Receiver<Bytes>,
    status_rx: &mut tokio::sync::oneshot::Receiver<StatusCode>,
    bound: Duration,
) -> BrowseFirstSignal {
    let deadline = tokio::time::sleep(bound);
    tokio::pin!(deadline);
    let mut pcm_open = true;
    loop {
        tokio::select! {
            biased;
            chunk = pcm_rx.recv(), if pcm_open => match chunk {
                Some(chunk) => return BrowseFirstSignal::Audio(chunk),
                // Closed without a byte: the serve task is ending, its verdict follows.
                None => pcm_open = false,
            },
            status = &mut *status_rx => return match status {
                Ok(status) => BrowseFirstSignal::Verdict(status),
                Err(_) => BrowseFirstSignal::Aborted,
            },
            _ = &mut deadline => return BrowseFirstSignal::NoAnswer,
        }
    }
}

/// What a title is answered that ended without a single audio byte and without a 404 or a
/// 409: never a 2xx (an empty 200 is a stream LMS starts as a short track).
fn status_for_an_end_without_audio(status: StatusCode) -> StatusCode {
    if status.is_success() { StatusCode::BAD_GATEWAY } else { status }
}

/// The body of a Browse answer: the chunk that was the first signal, then the rest.
fn browse_audio_body(first: Option<Bytes>, rest: mpsc::Receiver<Bytes>) -> BoxBody<Bytes, hyper::Error> {
    let stream = TokioStreamExt::map(
        TokioStreamExt::chain(tokio_stream::iter(first), ReceiverStream::new(rest)),
        |chunk| Ok::<Frame<Bytes>, hyper::Error>(Frame::data(chunk)),
    );
    BodyExt::boxed(StreamBody::new(stream))
}

// -------------------------------------------------------------------------
// /control status mapping — GH #159
// -------------------------------------------------------------------------

/// Maps a /control/{cmd} dispatch outcome to an HTTP status.
///
/// GH #159: Spirc drops transport commands (play/pause/next/prev) while the
/// device is not the active Connect target ("SpircCommand::X will be ignored
/// while Not Active"), but the channel send itself still succeeds — so
/// `result_present` alone cannot detect the drop. The caller passes the
/// `spirc_active` flag (maintained from SessionConnected/SessionDisconnected
/// player events) as the authoritative activity signal.
///
/// 409 CONFLICT means: the command was (or would have been) dropped because
/// this device is not the active Connect target — a distinct status so the
/// Perl side (Connect.pm) can eject the stale LMS stream instead of buffering
/// forever. Two paths produce it for the four transport commands:
///   1. `spirc_active == false` — SessionDisconnected observed (device
///      deselected in the Spotify app, explicit Disconnect, Spirc shutdown).
///   2. `result_present == false` — the Spirc handle is gone (Browse
///      preemption / ZeroConf reconnect window / never activated) or the
///      command channel is closed (Spirc task ended). Both also mean "not an
///      active Connect target", so 409 is the correct signal here too.
///      (Body-parse failures cannot reach this arm — those exist only for
///      volume/seek, which keep their 422 mapping.)
fn control_status(recovering: bool, spirc_active: bool, result_present: bool, cmd: &str) -> StatusCode {
    match (recovering, spirc_active, result_present, cmd) {
        // GH #207 / D-08 (Fable decision 1 item 7): while the helper rebuilds a dropped
        // AP session the answer is 503 (+ Retry-After 2 from the caller), never 409, so
        // Backend/Librespot.pm does not eject the stream and the D-03 pull-back is not
        // triggered by the helper's own outage.
        (true, _, _, "pause" | "play" | "next" | "prev" | "volume" | "seek") => {
            StatusCode::SERVICE_UNAVAILABLE
        }
        (_, false, _, "pause" | "play" | "next" | "prev") => StatusCode::CONFLICT,
        (_, _, false, "pause" | "play" | "next" | "prev") => StatusCode::CONFLICT,
        (_, _, true, _) => StatusCode::NO_CONTENT,
        (_, _, false, "volume" | "seek") => {
            log::debug!("[spoton/unified] /control/{cmd}: body parse failed, returning 422");
            StatusCode::UNPROCESSABLE_ENTITY
        }
        _ => StatusCode::NOT_FOUND,
    }
}

// -------------------------------------------------------------------------
// /control/transfer status mapping and play-after-takeover - phase 88 D-03
// -------------------------------------------------------------------------

/// Minimum spacing between two accepted /control/transfer dispatches
/// (T-88-12, proactive burst prevention).
const TRANSFER_MIN_INTERVAL: Duration = Duration::from_secs(3);

/// Maps a /control/transfer dispatch outcome to an HTTP status.
///
/// Deliberately takes NO activity flag: a transfer-back is requested precisely
/// while this device is not the active Connect target, so the 409-when-inactive
/// rule of `control_status` must never apply to it (D-03, Pitfall 5, GH #223).
///
/// - an AP-drop recovery runs (GH #207, `recovering`): 503
/// - no Spirc handle (Browse preemption / reconnect window): 503
/// - last accepted dispatch younger than TRANSFER_MIN_INTERVAL: 503
///   (T-88-12, the caller adds `Retry-After: 2`)
/// - otherwise 204
fn transfer_status(recovering: bool, spirc_present: bool, since_last_dispatch: Option<Duration>) -> StatusCode {
    // GH #207: the old Spirc is being woken and the new one is not up yet.
    if recovering || !spirc_present {
        return StatusCode::SERVICE_UNAVAILABLE;
    }
    match since_last_dispatch {
        Some(d) if d < TRANSFER_MIN_INTERVAL => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::NO_CONTENT,
    }
}

/// Window in which a takeover still counts as the one a /control/transfer
/// asked for. Derivation: 88-06's TRANSFER_WAIT_S (8 s) plus the 5.33 s
/// connect_transfer latency accepted in phase 84, rounded up. A takeover
/// later than that was not requested by any waiting LMS gesture and must not
/// play by itself (D-09).
const TRANSFER_PLAY_WINDOW: Duration = Duration::from_secs(15);

/// One-shot play-after-takeover decision (D-03, GH #223).
///
/// Spotify's takeover loads PAUSED when the restored remote state was paused
/// (`handle_transfer` loads with `is_playing = !is_paused`), and LMS's start
/// handler then streams a silent /stream. When the takeover is the one this
/// helper itself requested (`armed_at` = instant of the accepted
/// /control/transfer) and it arrives inside TRANSFER_PLAY_WINDOW, the helper
/// sends `play()` once. No arm (app selection, 88-04's recovery takeover) or
/// an expired arm never plays (D-09, T-88-30).
fn play_after_takeover(armed_at: Option<Instant>, now: Instant) -> bool {
    match armed_at {
        Some(t) => now.saturating_duration_since(t) <= TRANSFER_PLAY_WINDOW,
        None => false,
    }
}

/// Shared transfer bookkeeping: the last accepted dispatch (rate limit) and
/// the one-shot play arm consumed by the first SessionConnected.
#[derive(Default)]
struct TransferState {
    last_dispatch: std::sync::Mutex<Option<Instant>>,
    play_armed: std::sync::Mutex<Option<Instant>>,
}

impl TransferState {
    /// Takes (and thereby consumes) the play arm.
    fn take_play_arm(&self) -> Option<Instant> {
        self.play_armed.lock().unwrap_or_else(|e| e.into_inner()).take()
    }
}

/// POST /control/transfer: ask Spirc to pull a moved session back to this
/// device (`Spirc::transfer(None)`). Success is NOT awaited; it shows later as
/// `start`/`change` to LMS. Returns the HTTP status; the log lines are the
/// extract-run category of 88-03.
fn dispatch_transfer(
    spirc_handle: &std::sync::Mutex<Option<Spirc>>,
    state: &TransferState,
    recovering: bool,
) -> StatusCode {
    let guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
    let present = guard.is_some();
    let since = state
        .last_dispatch
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .map(|t| t.elapsed());
    let status = transfer_status(recovering, present, since);
    if status != StatusCode::NO_CONTENT {
        let reason = if recovering {
            "recovering"
        } else if present {
            "min_interval"
        } else {
            "no_spirc"
        };
        log::info!("[spoton/unified] /control/transfer: refused ({reason})");
        return status;
    }
    let sent = guard.as_ref().map(|s| s.transfer(None).is_ok()).unwrap_or(false);
    if !sent {
        // Command channel closed: the Spirc task is gone, same as no handle.
        log::info!("[spoton/unified] /control/transfer: refused (no_spirc)");
        return StatusCode::SERVICE_UNAVAILABLE;
    }
    let now = Instant::now();
    *state.last_dispatch.lock().unwrap_or_else(|e| e.into_inner()) = Some(now);
    *state.play_armed.lock().unwrap_or_else(|e| e.into_inner()) = Some(now);
    log::info!("[spoton/unified] /control/transfer: dispatched");
    StatusCode::NO_CONTENT
}

// -------------------------------------------------------------------------
// AP-drop recovery decisions - phase 88 D-07/D-08/D-09, GH #207
// -------------------------------------------------------------------------
//
// Pure decision functions of the helper-internal recovery (Fable decision 1,
// option d). The wiring (poll, intent, wake, rebuild, re-acquire) lives in the
// main loop of `run`; everything that can be decided without I/O is decided here
// so the table tests pin it.

/// How long after a Recovered outcome a Paused/Stopped is still the takeover's
/// own paused load. Derivation: the gh207 rule's recovery budget ("recovered in"
/// within 15 s): a takeover load slower than that already fails the rig row, and
/// a Paused after it is the user's.
const RECOVERY_SETTLE: Duration = Duration::from_secs(15);

/// Age limit of the not-active transfer path (Fable decision 1 item 4): the
/// fallback transfer could otherwise pull a session back from a device the user
/// switched to in the meantime.
const RECOVERY_TRANSFER_MAX_AGE: Duration = Duration::from_secs(30);

/// The player-event kinds the recovery gates look at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EventKind {
    SessionDisconnected,
    Paused,
    Stopped,
    Playing,
    TrackChanged,
    Other,
}

fn event_kind(event: &PlayerEvent) -> EventKind {
    match event {
        PlayerEvent::SessionDisconnected { .. } => EventKind::SessionDisconnected,
        PlayerEvent::Paused { .. } => EventKind::Paused,
        PlayerEvent::Stopped { .. } => EventKind::Stopped,
        PlayerEvent::Playing { .. } => EventKind::Playing,
        PlayerEvent::TrackChanged { .. } => EventKind::TrackChanged,
        _ => EventKind::Other,
    }
}

/// What the helper knew when the session was lost (Fable decision 1 item 1).
#[derive(Debug, Clone)]
struct RecoveryIntent {
    was_active: bool,
    was_playing: bool,
    track_id: Option<String>,
    session_id: String,
    at: Instant,
}

/// Next step after the rebuilt Spirc is up (Fable decision 1 item 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecoveryStep {
    Play,
    TransferThenPlay,
    TransferOnly,
    Quiet,
    GiveUp,
}

/// How the recovery ended, as the dispatcher needs to know it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecoveryOutcome {
    Recovered,
    Failed,
    GaveUp,
}

/// Fable decision 1 item 2: the session end (and the pause/stop the wake-up and
/// the old Spirc cause) is NOT passed to LMS while a recovery runs OR while the
/// session is already invalid at event time (the Spirc task noticed the loss
/// before the poll did). Outside a loss the same events are the honest end /
/// the user's pause and are forwarded.
fn suppress_for_recovery(kind: EventKind, recovering: bool, session_invalid: bool) -> bool {
    match kind {
        EventKind::SessionDisconnected | EventKind::Paused | EventKind::Stopped => {
            recovering || session_invalid
        }
        _ => false,
    }
}

/// What to do once the rebuilt Spirc is up (Fable decision 1 item 4), evaluated
/// in this order. The 30 s age limit belongs ONLY to the not-active transfer
/// path: a takeover that already succeeded is never a failure because of elapsed
/// time. A session that was paused at the loss never plays (D-09), a device that
/// was not active never takes over anything (D-09, T-88-09).
///
/// 88-03 spike (N=1, rig): the session-id carry-over fired the automatic
/// takeover 410 ms after `Spirc::new` (`NORMAL_TAKEOVER_STEP=session-id`), so
/// `active_after_rebuild` is normally already true and the transfer branches are
/// the unexercised fallback (assumption A1 stays open for 88-08).
fn recovery_plan(intent: &RecoveryIntent, active_after_rebuild: bool, age: Duration) -> RecoveryStep {
    if !intent.was_active {
        RecoveryStep::Quiet
    } else if active_after_rebuild {
        if intent.was_playing { RecoveryStep::Play } else { RecoveryStep::Quiet }
    } else if age >= RECOVERY_TRANSFER_MAX_AGE {
        RecoveryStep::GiveUp
    } else if intent.was_playing {
        RecoveryStep::TransferThenPlay
    } else {
        RecoveryStep::TransferOnly
    }
}

/// The event the dispatcher passes to the ordinary `handle_player_event` call
/// once the outcome is known. Recovered: the session continues, nothing is
/// replayed. Failed / GaveUp: the held SessionDisconnected, or one built from
/// the old session's connection id when none was held, so the ordinary arm
/// sends `stop inactive <counter>` and resets the cursor. A held Paused/Stopped
/// is never replayed (the replayed disconnect pauses LMS anyway).
fn held_event_after_recovery(
    outcome: RecoveryOutcome,
    held: Option<PlayerEvent>,
    old_connection: &(String, String),
) -> Option<PlayerEvent> {
    match outcome {
        RecoveryOutcome::Recovered => None,
        RecoveryOutcome::Failed | RecoveryOutcome::GaveUp => match held {
            Some(e @ PlayerEvent::SessionDisconnected { .. }) => Some(e),
            _ => Some(PlayerEvent::SessionDisconnected {
                connection_id: old_connection.0.clone(),
                user_name: old_connection.1.clone(),
            }),
        },
    }
}

/// The 1 s loss poll fires ONCE per loss: not while the reconnect arm runs
/// (`connecting`) and not while a recovery runs (`recovering`). Round-3 finding:
/// `connecting` alone is set only in the Spirc-task-died arm, so the poll kept
/// re-firing every second until the old task ended and each re-fire reset the
/// intent's `at`.
fn loss_poll_fires(connecting: bool, recovering: bool, session_invalid: bool) -> bool {
    !connecting && !recovering && session_invalid
}

/// After a Recovered outcome the takeover's own paused load (Spirc loads paused
/// because the intent paused it at the loss; the Play step plays afterwards)
/// must not reach LMS as `stop` + `resume`. Paused/Stopped inside the settle
/// window are suppressed; Playing never is (the caller ends the window on it);
/// a later pause is the user's; a new SessionDisconnected is an honest end or a
/// new recovery and is never hidden by the window.
fn suppress_after_recovery(kind: EventKind, settle_until: Option<Instant>, now: Instant) -> bool {
    matches!(kind, EventKind::Paused | EventKind::Stopped)
        && settle_until.map(|u| now < u).unwrap_or(false)
}

/// GH #207 (88-08 finding 1, V4): the rebuilt Spirc announces the title it takes
/// over a second time - `TrackChanged` first, then `Playing` with the restored
/// position. For a RELINKED title the two carry different ids (88-03 observation
/// 3: `TrackChanged` names the relinked id `0yNtt...`, `Playing` the Spirc-side id
/// `4uLU...`), and the dispatcher cursor holds the `Playing` form from before the
/// loss. `connect.rs` therefore read the takeover's `TrackChanged` as `4uLU ->
/// 0yNtt` and the `Playing` as `0yNtt -> 4uLU`: two `change` notifications, each
/// of which Connect.pm answers with `startOffset = -elapsed`, i.e. the LMS clock
/// restarted at 0 while the helper's position (51261 ms at the loss, 51424 ms at
/// the takeover) was right all along.
///
/// The takeover of the session this helper just lost is the SAME session, not a
/// new title, so its `TrackChanged` is held back from LMS while the recovery runs
/// (`recovering`) and inside the settle window after a Recovered outcome (the
/// event can land on either side of `RecoveryShared::finish`). The cursor then
/// still equals the `Playing` id, which stays a no-op; a takeover that really
/// restored a DIFFERENT title still reaches LMS as `change` through `Playing`
/// (its id differs from the cursor). Needs a cursor: without one the event is a
/// session start (`start`), never held. Only `TrackChanged` is concerned: the
/// caller keeps ending the window on `Playing`, and the pause gates above are
/// separate.
fn suppress_takeover_announce(
    kind: EventKind,
    recovering: bool,
    settle_until: Option<Instant>,
    now: Instant,
    has_cursor: bool,
) -> bool {
    kind == EventKind::TrackChanged
        && has_cursor
        && (recovering || settle_until.map(|u| now < u).unwrap_or(false))
}

/// Round-4 safety net: the wake-up command is sent once; if the old Spirc task
/// never leaves (stuck in a network call on the dead session), the recovery
/// would hold `recovering` (503 for /control, no Perl health restart) forever.
/// After RECOVERY_WAKE_TIMEOUT the rebuild is forced.
fn recovery_wake_stuck(recovering: bool, connecting: bool, age: Duration) -> bool {
    recovering && !connecting && age >= RECOVERY_WAKE_TIMEOUT
}

/// 88 review WR-02: the re-acquire step reads `spirc_active == true` as "the
/// rebuilt Spirc took over". The ordinary path into the rebuild (the
/// Spirc-task-ended arm) clears the flag first; the two shortcuts (no Spirc to
/// wake, the forced rebuild of a Spirc that never left) bypass that arm. A Spirc
/// stuck in `handle_disconnect` emits its SessionDisconnected only after the
/// await it hangs in, so the dispatcher never cleared the flag either: the
/// re-acquire then saw a takeover at its first poll and sent `play()` to a
/// rebuilt Spirc that was not active yet, which the fork drops ("will be ignored
/// while Not Active") while the log read `recovered in N ms (playing=1)`.
/// Both shortcuts call this before they set `connecting`.
fn mark_inactive_for_rebuild(spirc_active: &AtomicBool) {
    spirc_active.store(false, Ordering::SeqCst);
}

/// Retry schedule of a failed `Spirc::new` on the recovery path (Fable decision
/// 1 item 6): after 1, 2, 4 s, each with a NEW Session; then give up and let the
/// Perl backoff (GH #147) take over.
fn recovery_retry_delay(attempt: usize) -> Option<Duration> {
    match attempt {
        0 => Some(Duration::from_secs(1)),
        1 => Some(Duration::from_secs(2)),
        2 => Some(Duration::from_secs(4)),
        _ => None,
    }
}

/// 88 review WR-03: upper bound of ONE `Spirc::new` on the recovery path.
///
/// The rebuild is awaited inline in the reconnect arm of the main loop. The fork
/// bounds the TCP connect and the handshake (5 s, `connection::connect`), but
/// `connection::authenticate` awaits the access point's answer with no timeout:
/// an access point that completes the handshake and then goes quiet blocked the
/// arm for good. `recovering` stayed set (503 for /control, no Perl health
/// restart) and neither the loss poll nor Ctrl+C was served.
///
/// 30 s = the fork's own access-point rotation (`Session::connect`: 6 access
/// points, 5 s each): the longest a rebuild can legitimately take before it
/// fails by itself. The limit must not be shorter, because a retry starts with a
/// NEW Session and that rotation starts over. An elapsed limit is an ordinary
/// failed attempt of the 1/2/4 s schedule (`recovery_retry_delay`).
const RECOVERY_SPIRC_NEW_TIMEOUT: Duration = Duration::from_secs(30);

/// Only the recovery path is bounded: outside it `recovering` is not set, so the
/// Perl health restart (GH #149) is still armed and today's await is unchanged.
fn rebuild_limit(on_recovery_path: bool) -> Option<Duration> {
    on_recovery_path.then_some(RECOVERY_SPIRC_NEW_TIMEOUT)
}

/// Await one rebuild attempt, at most `limit` long. An elapsed limit drops the
/// attempt and returns a DeadlineExceeded error, so the caller's retry schedule
/// treats it like any other failed `Spirc::new`.
async fn bounded_rebuild<T, F>(attempt: F, limit: Option<Duration>) -> Result<T, librespot_core::Error>
where
    F: std::future::Future<Output = Result<T, librespot_core::Error>>,
{
    match limit {
        None => attempt.await,
        Some(limit) => match tokio::time::timeout(limit, attempt).await {
            Ok(result) => result,
            Err(_) => Err(librespot_core::Error::deadline_exceeded(format!(
                "Spirc::new timed out after {} ms",
                limit.as_millis()
            ))),
        },
    }
}

/// Upper bound of the shutdown-side wait for the dispatcher's ack of a replayed
/// recovery outcome: notify's TCP bound (5 s, connect.rs) + 1 s.
const OUTCOME_ACK_TIMEOUT: Duration = Duration::from_secs(6);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AckResult {
    Acked,
    TimedOut,
    Dropped,
}

/// Wait (bounded) for the dispatcher to finish the replay of a recovery outcome.
/// A dropped sender (the dispatcher is gone) returns at once; nothing can still
/// deliver the replay then.
async fn await_outcome_ack(rx: tokio::sync::oneshot::Receiver<()>, timeout: Duration) -> AckResult {
    match tokio::time::timeout(timeout, rx).await {
        Ok(Ok(())) => AckResult::Acked,
        Ok(Err(_)) => AckResult::Dropped,
        Err(_) => AckResult::TimedOut,
    }
}

/// Wait for the old Spirc task to leave after the wake-up before the rebuild is
/// forced. Its exit normally takes about 1.3 s (88-03: two spclient PUTs and the
/// dealer close); 10 s leaves a wide margin without holding `recovering` long.
const RECOVERY_WAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// Fable decision 1 item 4: wait up to 3 s for the automatic takeover
/// (`spirc_active`), then up to 5 s after the fallback `transfer(None)`.
const RECOVERY_ACTIVE_WAIT: Duration = Duration::from_secs(3);
const RECOVERY_TRANSFER_WAIT: Duration = Duration::from_secs(5);

/// Poll `flag` every 50 ms until it is set or `timeout` elapsed.
async fn wait_active(flag: &AtomicBool, timeout: Duration) -> bool {
    let t0 = Instant::now();
    loop {
        if flag.load(Ordering::Acquire) {
            return true;
        }
        if t0.elapsed() >= timeout {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Fires the recovery outcome acknowledgement when dropped, so every exit of a
/// dispatcher loop iteration (including `continue`) acknowledges the replay.
struct AckOnDrop(Option<tokio::sync::oneshot::Sender<()>>);

impl Drop for AckOnDrop {
    fn drop(&mut self) {
        if let Some(tx) = self.0.take() {
            let _ = tx.send(());
        }
    }
}

type OutcomeMsg = (RecoveryOutcome, tokio::sync::oneshot::Sender<()>);

/// State shared by the main loop and the player-event dispatchers.
struct RecoveryShared {
    /// A recovery runs: /control answers 503, /health reports it, the session
    /// end is held back.
    recovering: AtomicBool,
    /// Last known "this device was the active Connect target". NOT cleared by a
    /// SessionDisconnected that was suppressed because the session was invalid
    /// (the Spirc task noticed the loss before the poll), so the intent still
    /// knows the device was active.
    active_snapshot: AtomicBool,
    /// The main loop shut the session down ON PURPOSE (ZeroConf credential
    /// rotation, Browse-triggered reconnect). Such an end keeps today's path: its
    /// SessionDisconnected is forwarded, not held back as an AP drop.
    deliberate: AtomicBool,
    settle_until: std::sync::Mutex<Option<Instant>>,
    held: std::sync::Mutex<Option<PlayerEvent>>,
    /// (connection id, user name) of the session that was lost.
    old_connection: std::sync::Mutex<(String, String)>,
    /// Mirror of the dispatcher's LMS cursor (the id form the dispatcher itself
    /// compares, 88-03 observation 3).
    cursor: std::sync::Mutex<Option<String>>,
    lms_configured: bool,
    /// Outcome channel, main loop -> dispatcher. INVARIANT (88 review WR-09):
    /// this struct owns BOTH halves and nothing closes the receiver, so for as
    /// long as a `RecoveryShared` exists a send cannot fail and a receive cannot
    /// report a closed channel. `finish` and `next_outcome` rely on it; do not
    /// hand either half out or call `close()` without revisiting both.
    outcome_tx: mpsc::UnboundedSender<OutcomeMsg>,
    outcome_rx: tokio::sync::Mutex<mpsc::UnboundedReceiver<OutcomeMsg>>,
}

impl RecoveryShared {
    fn new(lms_configured: bool) -> Self {
        let (outcome_tx, outcome_rx) = mpsc::unbounded_channel();
        RecoveryShared {
            recovering: AtomicBool::new(false),
            active_snapshot: AtomicBool::new(false),
            deliberate: AtomicBool::new(false),
            settle_until: std::sync::Mutex::new(None),
            held: std::sync::Mutex::new(None),
            old_connection: std::sync::Mutex::new((String::new(), String::new())),
            cursor: std::sync::Mutex::new(None),
            lms_configured,
            outcome_tx,
            outcome_rx: tokio::sync::Mutex::new(outcome_rx),
        }
    }

    fn is_recovering(&self) -> bool {
        self.recovering.load(Ordering::Acquire)
    }

    /// 88 review WR-06: the main loop or the HTTP handler takes the device off
    /// the session ON PURPOSE (Browse preemption, ZeroConf rotation,
    /// Browse-triggered reconnect, the Spirc task ended). Clears the activity
    /// flag AND the snapshot: the disconnect event that would clear the snapshot
    /// may be suppressed or never emitted (an aborted Spirc task), and a stale
    /// snapshot makes the next loss read `was_active` for a device that was not.
    fn clear_active(&self, spirc_active: &AtomicBool) {
        spirc_active.store(false, Ordering::SeqCst);
        self.active_snapshot.store(false, Ordering::SeqCst);
    }

    /// Hold a suppressed SessionDisconnected until the outcome is known. A
    /// suppressed Paused/Stopped is dropped.
    fn hold(&self, event: &PlayerEvent) {
        if matches!(event, PlayerEvent::SessionDisconnected { .. }) {
            *self.held.lock().unwrap_or_else(|e| e.into_inner()) = Some(event.clone());
        }
    }

    fn take_held(&self) -> Option<PlayerEvent> {
        self.held.lock().unwrap_or_else(|e| e.into_inner()).take()
    }

    fn old_connection(&self) -> (String, String) {
        self.old_connection.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn settle_until(&self) -> Option<Instant> {
        *self.settle_until.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn end_settle(&self) {
        *self.settle_until.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    fn set_cursor(&self, cursor: &Option<String>) {
        *self.cursor.lock().unwrap_or_else(|e| e.into_inner()) = cursor.clone();
    }

    fn cursor(&self) -> Option<String> {
        self.cursor.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Next recovery outcome for a dispatcher to act on. Waits while none is
    /// queued; the channel cannot close (see the invariant on `outcome_tx`).
    async fn next_outcome(&self) -> OutcomeMsg {
        self.outcome_rx
            .lock()
            .await
            .recv()
            .await
            .expect("RecoveryShared owns the outcome sender: the channel cannot close")
    }

    /// End the recovery: open the settle window (Recovered), hand the outcome to
    /// the dispatcher and clear `recovering`. The returned receiver fires when the
    /// dispatcher finished the replay; without LMS (`!lms_configured`) no
    /// dispatcher consumes outcomes and it is fired here. Clearing happens last,
    /// so no event slips between the outcome and the window.
    fn finish(&self, outcome: RecoveryOutcome) -> tokio::sync::oneshot::Receiver<()> {
        if outcome == RecoveryOutcome::Recovered {
            *self.settle_until.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(Instant::now() + RECOVERY_SETTLE);
        }
        let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
        if self.lms_configured {
            // Cannot fail (invariant on `outcome_tx`): the receiver lives in `self`.
            let _ = self.outcome_tx.send((outcome, ack_tx));
        } else {
            let _ = ack_tx.send(());
        }
        self.recovering.store(false, Ordering::Release);
        ack_rx
    }
}

/// "This device was the active Connect target when the session was lost": the
/// live flag, or the snapshot a suppressed SessionDisconnected left behind.
fn was_active_at_loss(spirc_active: &AtomicBool, rs: &RecoveryShared) -> bool {
    spirc_active.load(Ordering::Acquire) || rs.active_snapshot.load(Ordering::Acquire)
}

/// 88 review WR-06: the Spirc task ended while the session is still VALID (after
/// a Browse preemption or an internal error) and the main loop shuts the session
/// down to rebuild it. Marked `deliberate` like the ZeroConf rotation and the
/// Browse-triggered reconnect, so an event of the old Spirc that the dispatcher
/// reads after the shutdown is forwarded as the honest end (`stop inactive`)
/// instead of being held as an AP drop and discarded. An already invalid session
/// is the AP drop itself: nothing is shut down, nothing is marked. Returns
/// whether the session was shut down here.
fn end_valid_session_on_purpose(rs: &RecoveryShared, session: &Session) -> bool {
    if session.is_invalid() {
        return false;
    }
    rs.deliberate.store(true, Ordering::Release);
    session.shutdown();
    true
}

/// Extrapolated playback position of the LMS anchor, for the log line only.
fn anchor_position_ms(anchor: &Option<crate::connect::PositionAnchor>, now: Instant) -> u64 {
    match anchor {
        Some(a) if a.playing => {
            u64::from(a.position_ms) + now.saturating_duration_since(a.at).as_millis() as u64
        }
        Some(a) => u64::from(a.position_ms),
        None => 0,
    }
}

/// Build the intent at the moment the loss is seen (Fable decision 1 item 1),
/// set `recovering`, disarm 88-05's one-shot transfer play (the recovery decides
/// play itself, D-09) and log the anchor line. Does NOT wake the Spirc.
async fn begin_recovery(
    rs: &RecoveryShared,
    session: &Session,
    spirc_active: &AtomicBool,
    mode_state: &tokio::sync::Mutex<ActiveMode>,
    lms: &LMS,
    transfer_state: &TransferState,
) -> RecoveryIntent {
    let was_active = was_active_at_loss(spirc_active, rs);
    let in_connect = *mode_state.lock().await == ActiveMode::Connect;
    let anchor = *lms.position_anchor.lock().unwrap_or_else(|e| e.into_inner());
    let was_playing = was_active && in_connect && anchor.map(|a| a.playing).unwrap_or(false);
    let now = Instant::now();
    let track_id = rs.cursor();
    *rs.old_connection.lock().unwrap_or_else(|e| e.into_inner()) =
        (session.connection_id(), session.username());
    rs.recovering.store(true, Ordering::Release);
    let _ = transfer_state.take_play_arm();
    log::info!(
        "[spoton/unified] session lost (active={} playing={} track={} pos={})",
        was_active as u8,
        was_playing as u8,
        track_id.as_deref().unwrap_or("none"),
        anchor_position_ms(&anchor, now)
    );
    RecoveryIntent {
        was_active,
        was_playing,
        track_id,
        session_id: session.session_id(),
        at: now,
    }
}

/// Result of the re-acquire step.
struct Reacquired {
    outcome: RecoveryOutcome,
    /// `play()` was sent (the session was playing at the loss and we took over).
    playing: bool,
    /// Fixed reason text for `recovery failed: <reason>`.
    reason: &'static str,
}

/// Fable decision 1 item 4: after `Spirc::new` succeeded on the recovery path.
/// Wait up to 3 s for the automatic takeover, then act on `recovery_plan`.
async fn reacquire_after_rebuild(
    intent: &RecoveryIntent,
    spirc_handle: &std::sync::Mutex<Option<Spirc>>,
    spirc_active: &AtomicBool,
) -> Reacquired {
    let mut active = if intent.was_active {
        wait_active(spirc_active, RECOVERY_ACTIVE_WAIT).await
    } else {
        spirc_active.load(Ordering::Acquire)
    };
    let step = recovery_plan(intent, active, intent.at.elapsed());
    let send = |f: &dyn Fn(&Spirc) -> bool| -> bool {
        let guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
        guard.as_ref().map(|s| f(s)).unwrap_or(false)
    };
    let failed = |outcome, reason| Reacquired { outcome, playing: false, reason };
    match step {
        RecoveryStep::Quiet => {
            if intent.was_active && active {
                log::info!("[spoton/unified] recovery: takeover via session-id");
            }
            Reacquired { outcome: RecoveryOutcome::Recovered, playing: false, reason: "" }
        }
        RecoveryStep::GiveUp => failed(RecoveryOutcome::GaveUp, "no takeover within 30 s"),
        RecoveryStep::Play => {
            log::info!("[spoton/unified] recovery: takeover via session-id");
            if send(&|s| s.play().is_ok()) {
                Reacquired { outcome: RecoveryOutcome::Recovered, playing: true, reason: "" }
            } else {
                failed(RecoveryOutcome::Failed, "spirc command channel closed")
            }
        }
        RecoveryStep::TransferThenPlay | RecoveryStep::TransferOnly => {
            if !send(&|s| s.transfer(None).is_ok()) {
                return failed(RecoveryOutcome::Failed, "spirc command channel closed");
            }
            active = wait_active(spirc_active, RECOVERY_TRANSFER_WAIT).await;
            if !active {
                return failed(RecoveryOutcome::Failed, "no takeover after transfer");
            }
            log::info!("[spoton/unified] recovery: takeover via transfer");
            let play = step == RecoveryStep::TransferThenPlay;
            if play && !send(&|s| s.play().is_ok()) {
                return failed(RecoveryOutcome::Failed, "spirc command channel closed");
            }
            Reacquired { outcome: RecoveryOutcome::Recovered, playing: play, reason: "" }
        }
    }
}

// -------------------------------------------------------------------------
// PassthroughMixer — GH #144: eliminates PCM double attenuation
// -------------------------------------------------------------------------
//
// A librespot Mixer that tracks Spirc's volume state (so the Spotify app
// slider and VolumeChanged events keep working) but NEVER attenuates audio
// samples. attenuation_factor() always returns 1.0 (the trait's default
// NoOpVolume — see below), making LMS/squeezelite the single attenuator in
// every SpotOn playback mode (Browse, Connect PCM fallback, Connect OGG
// passthrough).
//
// Rationale (GH #144): in PCM fallback mode (normalization on, non-OGG
// player, mixed sync group) users got ~-6 dB extra attenuation at LMS
// volume 50 because both librespot's SoftMixer and squeezelite attenuated
// the same PCM samples. VolumeCtrl::Fixed was also broken in the pinned
// librespot rev (mappings.rs treats Fixed like Linear); upstream compensates
// with disable_volume=true, which SpotOn cannot use because Spirc must keep
// reporting/accepting volume changes for the Spotify app slider to work.
//
// Prior art: Music Assistant's librespot fork carries the identical pattern
// — https://github.com/music-assistant/librespot/commit/1d68d603
struct PassthroughMixer {
    volume: AtomicU16,
}

impl Mixer for PassthroughMixer {
    fn open(_config: MixerConfig) -> Result<Self, librespot_core::Error>
    where
        Self: Sized,
    {
        // MixerConfig::volume_ctrl (Fixed/Linear/Log) is intentionally ignored —
        // ignoring the volume curve IS the GH #144 fix. There is no audio
        // attenuation path left for a curve to apply to.
        Ok(Self {
            // Matches ConnectConfig::default().initial_volume; Spirc overwrites
            // this immediately at startup from the real initial_volume
            // (librespot connect/src/spirc.rs:269-277).
            volume: AtomicU16::new(u16::MAX / 2),
        })
    }

    fn volume(&self) -> u16 {
        self.volume.load(Ordering::Relaxed)
    }

    fn set_volume(&self, volume: u16) {
        log::debug!("[spoton/unified] PassthroughMixer::set_volume({volume})");
        self.volume.store(volume, Ordering::Relaxed);
    }

    // Deliberately NOT overriding get_soft_volume(): the trait's default
    // implementation returns NoOpVolume, whose attenuation_factor() is
    // hardcoded 1.0. Do not "fix" this by adding an override that reads
    // `self.volume` — that would reintroduce the double-attenuation bug
    // this struct exists to eliminate (GH #144).
}

/// MixerFn-compatible constructor for PassthroughMixer — slots into the
/// existing `mixer_fn_opt` reconnect plumbing used by both Spirc creation
/// sites (initial startup and ZeroConf reconnect).
fn passthrough_mixer(config: MixerConfig) -> Result<Arc<dyn Mixer>, librespot_core::Error> {
    Ok(Arc::new(PassthroughMixer::open(config)?))
}

// -------------------------------------------------------------------------
// Fresh-stream burst credit (quick 261109-f4r, C)
// -------------------------------------------------------------------------
//
// squeezelite starts its output only once it holds its OGG output threshold (LMS
// Squeezebox.pm:695, 20 tenths = 88200 frames), and the sink delivers at 1x, so every
// fresh `/stream` connection waits ~2.0 s for sound (claim-lms rows: loud fraction
// 0.790 / 0.770 against 0.8). The credit lets the sink run ahead of wall time by
// threshold + one maximal Spotify OGG page ONCE, at a relay start that coincides with a
// fresh sink timeline, so the player's threshold is met from the burst alone.
//
// Granted by `UnifiedHttpStreamSink::maybe_grant_credit` iff ALL hold at an audio write:
//   (a) the relay armed a start (`BurstArm::arm`) no longer than BURST_ARM_MAX_AGE ago,
//   (b) the sink timeline is younger than BURST_FRESH_WINDOW (since start()/stop()),
//   (c) no credit has been granted since the last start()/stop().
// The arm is consumed by the FIRST audio write after it, granted or not, so a reconnect
// in the middle of a track never leaves a pending arm that a later pause/resume could
// pick up. start() and stop() reset the credit. Never on pause/resume (no relay start
// there), never repeated within a start().

/// LMS's OGG output threshold (20 tenths of a second at 44.1 kHz) ...
const BURST_THRESHOLD_FRAMES: u64 = 20 * 4410;
/// ... plus one maximal observed Spotify OGG page (230 ms, rounded up to 10240 frames).
const BURST_PAGE_FRAMES: u64 = 10_240;
/// 98440 frames = 2.232 s of lead the sink may build once per start().
const BURST_CREDIT_FRAMES: u64 = BURST_THRESHOLD_FRAMES + BURST_PAGE_FRAMES;
/// A sink timeline younger than this is "fresh" (rule b). Covers the LMS reaction time
/// between `Playing` and the GET; older timelines are mid-track and get no credit.
const BURST_FRESH_WINDOW: Duration = Duration::from_secs(5);
/// An arm older than this is stale (rule a). Covers a PCM relay that starts before the
/// sink does (the GET precedes `Playing` by the Spotify transfer-to-resume gap, 2.5 s
/// normal, 4 s slow).
const BURST_ARM_MAX_AGE: Duration = Duration::from_secs(10);

/// Relay -> sink signal "a fresh /stream relay just started" (see the block above).
struct BurstArm {
    armed: AtomicBool,
    at: std::sync::Mutex<Option<Instant>>,
}

impl BurstArm {
    fn new() -> Self {
        Self { armed: AtomicBool::new(false), at: std::sync::Mutex::new(None) }
    }

    /// Relay side: a relay start was just served.
    fn arm(&self) {
        self.arm_at(Instant::now());
    }

    fn arm_at(&self, when: Instant) {
        *self.at.lock().unwrap_or_else(|e| e.into_inner()) = Some(when);
        self.armed.store(true, Ordering::Release);
    }

    /// Sink side: consume the arm; true iff there was one and it is no older than `max_age`.
    /// A stale arm is consumed (dropped) too.
    fn take(&self, max_age: Duration) -> bool {
        if !self.armed.swap(false, Ordering::AcqRel) {
            return false;
        }
        let at = self.at.lock().unwrap_or_else(|e| e.into_inner()).take();
        at.is_some_and(|t| t.elapsed() <= max_age)
    }
}

// -------------------------------------------------------------------------
// UnifiedHttpStreamSink — rate-limited PCM sink for Connect path
// -------------------------------------------------------------------------
//
// The only Connect sink. (It started as a reimplementation of connect.rs'
// HttpStreamSink, which was dead for a long time and was removed in quick
// 261109-ath.) It paces at 1x since start() with no hold-back, never blocks the
// librespot player thread (GH #202) and hands chunks to the /stream relay.

/// D-10 / Fable decision 2 item 2: where the time of a reload goes. One DEBUG line per
/// sink start() / OGG serial change:
/// `reload timing: headers at +X ms, first audio page at +Y ms, parked Z ms`,
/// X = first header page written, Y = first audio page written (both measured from the
/// start()/serial-change instant), Z = time the player thread spent in the pacing sleep
/// before Y. Observation only: no behaviour change.
struct ReloadTiming {
    since: Instant,
    headers_at: Option<Duration>,
    parked: Duration,
    done: bool,
}

impl ReloadTiming {
    fn new(since: Instant) -> Self {
        Self { since, headers_at: None, parked: Duration::ZERO, done: false }
    }

    /// A new start()/serial change: measure from `at` again.
    fn restart(&mut self, at: Instant) {
        *self = Self::new(at);
    }

    /// First header page written after the restart (later ones are ignored).
    fn note_headers(&mut self, now: Instant) {
        if !self.done && self.headers_at.is_none() {
            self.headers_at = Some(now.saturating_duration_since(self.since));
        }
    }

    /// Time spent in the pacing sleep (counted until the first audio page is out).
    fn add_parked(&mut self, d: Duration) {
        if !self.done {
            self.parked += d;
        }
    }

    /// First audio page written: yields the line once per restart.
    fn finish(&mut self, now: Instant) -> Option<String> {
        if self.done {
            return None;
        }
        self.done = true;
        let headers = self
            .headers_at
            .map_or_else(|| "n/a".to_owned(), |d| d.as_millis().to_string());
        Some(format!(
            "[spoton/unified] reload timing: headers at +{headers} ms, first audio page at +{} ms, parked {} ms",
            now.saturating_duration_since(self.since).as_millis(),
            self.parked.as_millis()
        ))
    }
}

struct UnifiedHttpStreamSink {
    pcm_tx: mpsc::Sender<Bytes>,
    #[allow(dead_code)]
    flush_tx: watch::Sender<u64>,
    track_gen: Arc<AtomicU64>,
    last_track_gen: u64,
    began_at: Instant,
    frames_consumed: u64,
    // Phase 43 (D-03): shared with the /stream HTTP handler so buffered OGG BOS +
    // Vorbis header pages can be replayed after the handler drains stale chunks
    // from the main channel on each new connection.
    ogg_header_buf: Arc<std::sync::Mutex<Vec<Bytes>>>,
    ogg_header_serial: Arc<AtomicU32>,
    ogg_headers_complete: Arc<AtomicBool>,
    // True while we are still buffering header pages for the current track.
    // Only meaningful when `passthrough` is true; cleared on the first audio page.
    collecting_headers: bool,
    passthrough: bool,
    // Phase 44 fix: granule_position offset captured on the first audio page after
    // each start(). On pause/resume librespot re-sends OGG from the resume position,
    // so granule_position is already deep into the track. Without subtracting this
    // offset, the rate-limiting formula would sleep for the entire track prefix.
    // -1 = sentinel meaning "not yet captured".
    granule_offset: i64,
    // Phase 44 fix: OGG serial number of the current logical bitstream.
    // Gapless Connect transitions can change this without stop()/start().
    ogg_serial: u32,
    // Continuous OGG timeline across serial changes. Librespot may stream
    // gapless track transitions without calling stop()/start(), while OGG
    // granule positions reset per logical bitstream. Keep a synthetic
    // cumulative frame count so the rate-limiter does not add a fresh
    // buffer-latency gap at every track boundary.
    ogg_track_base_frames: u128,
    ogg_timeline_frames: u128,
    // GH #202: set by the sink when it had to drop a chunk because nobody reads
    // pcm_rx; consumed by the /stream relay, which then discards the stale backlog.
    overflow: Arc<AtomicBool>,
    // GH #202: chunks dropped on a full channel since the sink was opened.
    dropped: u64,
    // Rate-limited WARN bookkeeping for the drop counter.
    dropped_since_log: u64,
    last_drop_log: Option<Instant>,
    // Chunks dropped since the channel last accepted one (for the recovery INFO).
    drops_in_episode: u64,
    // Quick 261109-f4r (C): relay -> sink "fresh relay start" signal and the credit it may buy.
    burst: Arc<BurstArm>,
    // Frames of lead granted by the credit since the last start()/stop() (0 = none).
    credit_frames: u64,
    // Rule (b) bound; a field only so tests can shrink it (production: BURST_FRESH_WINDOW).
    burst_fresh_window: Duration,
    // D-10: reload timing line state (see ReloadTiming).
    reload_timing: ReloadTiming,
}

impl UnifiedHttpStreamSink {
    #[allow(clippy::too_many_arguments)]
    fn new(
        _device: Option<String>,
        format: AudioFormat,
        pcm_tx: mpsc::Sender<Bytes>,
        flush_tx: watch::Sender<u64>,
        track_gen: Arc<AtomicU64>,
        // Inert since quick 261109-ath: the CON-14 hold-back is gone (see write()).
        // The parameter stays so `--buffer-latency-ms` keeps parsing end to end.
        _buffer_latency_ms: u64,
        ogg_header_buf: Arc<std::sync::Mutex<Vec<Bytes>>>,
        ogg_header_serial: Arc<AtomicU32>,
        ogg_headers_complete: Arc<AtomicBool>,
        overflow: Arc<AtomicBool>,
        burst: Arc<BurstArm>,
        passthrough: bool,
    ) -> Self {
        if format != AudioFormat::S16 {
            panic!(
                "UnifiedHttpStreamSink: only AudioFormat::S16 supported, got {:?}",
                format
            );
        }
        Self {
            pcm_tx,
            flush_tx,
            last_track_gen: track_gen.load(Ordering::Acquire),
            track_gen,
            began_at: Instant::now(),
            frames_consumed: 0,
            ogg_header_buf,
            ogg_header_serial,
            ogg_headers_complete,
            collecting_headers: passthrough,
            passthrough,
            granule_offset: -1,
            ogg_serial: 0,
            ogg_track_base_frames: 0,
            ogg_timeline_frames: 0,
            overflow,
            dropped: 0,
            dropped_since_log: 0,
            last_drop_log: None,
            drops_in_episode: 0,
            burst,
            credit_frames: 0,
            burst_fresh_window: BURST_FRESH_WINDOW,
            reload_timing: ReloadTiming::new(Instant::now()),
        }
    }

    /// Quick 261109-f4r (C): called right before the 1x pacing of an AUDIO write (an OGG chunk
    /// holding an audio page, or a PCM packet). Consumes the relay's arm (see the rules above
    /// `BURST_THRESHOLD_FRAMES`) at the first audio write after it, and grants the one-off lead
    /// iff the sink has none yet and its timeline is still fresh.
    fn maybe_grant_credit(&mut self) {
        // Consumed whatever the verdict, so a mid-track arm cannot linger for a later restart.
        let armed = self.burst.take(BURST_ARM_MAX_AGE);
        if !armed || self.credit_frames != 0 {
            return;
        }
        let age = self.began_at.elapsed();
        if age > self.burst_fresh_window {
            log::debug!(
                "[spoton/unified] fresh-relay credit not granted: sink timeline is {}ms old (mid-track relay restart)",
                age.as_millis()
            );
            return;
        }
        self.credit_frames = BURST_CREDIT_FRAMES;
        log::info!(
            "[spoton/unified] fresh relay start on a fresh sink timeline ({}ms old): burst credit {} frames ({}ms)",
            age.as_millis(),
            BURST_CREDIT_FRAMES,
            BURST_CREDIT_FRAMES * 1000 / u64::from(SAMPLE_RATE)
        );
    }

    /// Non-blocking hand-over of one chunk to the /stream relay (GH #202).
    ///
    /// Runs on the librespot player thread, so it must never wait for the reader:
    /// the old spin-on-Full loop froze Spirc (no pause, no Load, no Browse
    /// preemption) for as long as nobody read, 64 s of Send-Q fill plus the
    /// 256-slot channel after LMS stopped taking the stream. On `Full` the chunk
    /// is dropped, `overflow` tells the relay to discard the stale backlog when a
    /// reader returns (so it gets live audio, not a minute-old queue), and a
    /// rate-limited WARN carries the drop counter. 1x pacing is untouched, so the
    /// Spirc position stays honest. `Closed` (server gone) stays an error.
    fn push_live(&mut self, chunk: Bytes) -> SinkResult<()> {
        match self.pcm_tx.try_send(chunk) {
            Ok(()) => {
                if self.drops_in_episode > 0 {
                    log::info!(
                        "[spoton/unified] Connect sink: channel accepts chunks again after {} dropped (total {})",
                        self.drops_in_episode,
                        self.dropped
                    );
                    self.drops_in_episode = 0;
                }
                Ok(())
            }
            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                self.dropped += 1;
                self.drops_in_episode += 1;
                self.dropped_since_log += 1;
                self.overflow.store(true, Ordering::Release);
                let now = Instant::now();
                let due = self
                    .last_drop_log
                    .map_or(true, |t| now.duration_since(t) >= Duration::from_secs(5));
                if due {
                    log::warn!(
                        "[spoton/unified] Connect sink: no reader on /stream, dropped {} chunks \
                         (total {})",
                        self.dropped_since_log,
                        self.dropped
                    );
                    self.dropped_since_log = 0;
                    self.last_drop_log = Some(now);
                }
                Ok(())
            }
            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => Err(SinkError::OnWrite(
                "Unified HTTP stream server shut down".into(),
            )),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn open(
        device: Option<String>,
        format: AudioFormat,
        pcm_tx: mpsc::Sender<Bytes>,
        flush_tx: watch::Sender<u64>,
        track_gen: Arc<AtomicU64>,
        buffer_latency_ms: u64,
        ogg_header_buf: Arc<std::sync::Mutex<Vec<Bytes>>>,
        ogg_header_serial: Arc<AtomicU32>,
        ogg_headers_complete: Arc<AtomicBool>,
        overflow: Arc<AtomicBool>,
        burst: Arc<BurstArm>,
        passthrough: bool,
    ) -> Box<dyn Sink> {
        Box::new(Self::new(
            device,
            format,
            pcm_tx,
            flush_tx,
            track_gen,
            buffer_latency_ms,
            ogg_header_buf,
            ogg_header_serial,
            ogg_headers_complete,
            overflow,
            burst,
            passthrough,
        ))
    }
}

/// Bound of the relay's wait for the sink's OGG header pages at a new `/stream` GET
/// (quick 261109-f4r, D; was 3 s). See the call site.
const OGG_HEADER_WAIT_SECS: u64 = 10;

/// Quick 261110-r38 (W2): how much audio, measured on granules behind the youngest queued
/// page of the snapshot serial, a new `/stream` connection takes over from the backlog.
/// 98440 frames = 2.232 s, on purpose `BURST_CREDIT_FRAMES`:
/// - on a late reconnect the sink timeline is older than `BURST_FRESH_WINDOW`, so
///   `maybe_grant_credit` grants nothing and the kept backlog is the only lead the player
///   gets; 2.232 s is LMS's OGG output threshold plus one maximal page, so it still fills
///   the threshold at once;
/// - the #128 resync anchors the LMS clock on the LIVE position at relay start, so every
///   kept second older than live is a second of sound behind that clock; the cap bounds
///   that lag at 2.232 s plus at most one page (about 2.5 s).
/// Not `2 * BURST_CREDIT_FRAMES`: that is 4.46 s and would double the lag bound.
const RELAY_BACKLOG_MAX_FRAMES: u64 = BURST_CREDIT_FRAMES;

/// Discards everything queued on the Connect channel; returns the count.
fn drain_all(rx: &mut mpsc::Receiver<Bytes>) -> u64 {
    let mut n = 0u64;
    while rx.try_recv().is_ok() {
        n += 1;
    }
    n
}

/// One complete OGG page found inside a chunk (no CRC check, like the sink).
struct OggPageInfo {
    range: std::ops::Range<usize>,
    granule: i64,
    serial: u32,
}

/// Walks the complete OGG pages of a chunk; stops at the first malformed or
/// truncated page. Same framing rules as `UnifiedHttpStreamSink::write`.
fn ogg_pages(chunk: &[u8]) -> Vec<OggPageInfo> {
    let mut pages = Vec::new();
    let mut pos = 0usize;
    while pos + 27 <= chunk.len() {
        if &chunk[pos..pos + 4] != b"OggS" {
            break;
        }
        let granule = i64::from_le_bytes(chunk[pos + 6..pos + 14].try_into().expect("8 bytes"));
        let serial = u32::from_le_bytes(chunk[pos + 14..pos + 18].try_into().expect("4 bytes"));
        let n_segments = chunk[pos + 26] as usize;
        if pos + 27 + n_segments > chunk.len() {
            break;
        }
        let body_size: usize = chunk[pos + 27..pos + 27 + n_segments]
            .iter()
            .map(|&b| b as usize)
            .sum();
        let end = pos + 27 + n_segments + body_size;
        if end > chunk.len() {
            break;
        }
        pages.push(OggPageInfo { range: pos..end, granule, serial });
        pos = end;
    }
    pages
}

/// Serial of the LAST complete OGG page in `chunk` (None for PCM / garbage).
fn last_ogg_serial(chunk: &[u8]) -> Option<u32> {
    ogg_pages(chunk).last().map(|p| p.serial)
}

/// What a NEW `/stream` connection takes over from the backlog the Connect channel
/// holds at relay start (review W-1).
///
/// With the 2 s hold-back gone, the sink has usually already queued the header chunk
/// AND the first audio page(s) by the time the GET is served (the GET lags `Playing`
/// by the LMS reaction time). A total drain would throw that audio away, so the
/// backlog is sorted instead of dropped:
///
/// - overflow flag set at relay start -> everything is stale (nobody was reading);
/// - PCM -> no way to tell stale from fresh: total drain, as before;
/// - OGG without a header snapshot -> keep every queued chunk in order. This is reached
///   (a) when the header wait timed out with fewer than two header pages of the current
///   serial (fresh daemon, slow session start: a header chunk can still sit in the queue and
///   must go out in order; quick 261109-f4r) and (b) at the early exit of the wait (the
///   current serial's headers are known absent: its queued audio is undecodable either way
///   until the next BOS, and keeping the queue never drops a following serial's header
///   chunk; quick 261110-r38);
/// - OGG with a header snapshot -> per PAGE: keep audio pages (granule != 0) of the
///   snapshot's serial; discard header pages (replayed from the snapshot, a second
///   BOS would only confuse the decoder), pages of any other serial (pre-seek audio
///   or the previous track) and trailing partial pages. Of those, only the pages from
///   the first one (granule > 0) that lies within `RELAY_BACKLOG_MAX_FRAMES` of the
///   youngest queued page OF THAT SERIAL onwards are kept (quick 261110-r38, W2): older
///   audio would play behind the LMS clock that the #128 resync sets to the live
///   position. Granule -1 continuation pages inside the window stay, earlier ones go;
///   pages of other serials never move the window.
///
/// Returns (pages kept, in order, to forward right after the header replay;
/// number of queued chunks that contributed nothing).
fn relay_start_backlog(
    rx: &mut mpsc::Receiver<Bytes>,
    overflow: &AtomicBool,
    passthrough: bool,
    header_snapshot: &[Bytes],
) -> (Vec<Bytes>, u64) {
    // Clear the flag first: the drain below handles an earlier overflow, and a
    // `Full` during/after it just costs one extra relay pass (review I-1).
    let was_overflow = overflow.swap(false, Ordering::AcqRel);
    let mut pending: Vec<Bytes> = Vec::new();
    while let Ok(chunk) = rx.try_recv() {
        pending.push(chunk);
    }
    let snapshot_serial = header_snapshot
        .iter()
        .find_map(|p| ogg_pages(p).first().map(|pg| pg.serial));
    let serial = match (was_overflow, passthrough, snapshot_serial) {
        (false, true, Some(serial)) => serial,
        // Quick 261109-f4r (D), premise reworded in quick 261110-r38: OGG without a header
        // snapshot and without an overflow. Reached at a header-wait timeout with fewer than
        // two header pages of the current serial (the queue may still hold the header chunk,
        // which must go out in order) or at the early exit of the wait (headers known absent;
        // keeping the queue never drops a following serial's header chunk). Keep it all, in
        // order; there is no replay to duplicate and no serial to filter by.
        (false, true, None) => {
            return (pending, 0);
        }
        _ => return (Vec::new(), pending.len() as u64),
    };
    // W2: youngest granule > 0 of the snapshot serial over everything queued; pages of
    // other serials never take part. Without one there is no cap.
    let youngest = pending
        .iter()
        .flat_map(|c| ogg_pages(c))
        .filter(|pg| pg.serial == serial && pg.granule > 0)
        .map(|pg| pg.granule)
        .max();
    let cutoff: Option<i64> = youngest.map(|y| y.saturating_sub(RELAY_BACKLOG_MAX_FRAMES as i64));
    // Flips once, at the first page of `serial` with granule > 0 inside the window.
    let mut in_window = cutoff.is_none();
    let mut dropped_by_cap = 0u64;
    let mut kept: Vec<Bytes> = Vec::new();
    let mut discarded = 0u64;
    for chunk in pending {
        let mut chunk_kept = false;
        let mut run: Option<(usize, usize)> = None;
        for pg in ogg_pages(&chunk) {
            if !in_window && pg.serial == serial && pg.granule > 0 && Some(pg.granule) >= cutoff {
                in_window = true;
            }
            if !in_window && pg.serial == serial && pg.granule != 0 {
                dropped_by_cap += 1;
            }
            if in_window && pg.serial == serial && pg.granule != 0 {
                run = Some(match run {
                    Some((start, _)) => (start, pg.range.end),
                    None => (pg.range.start, pg.range.end),
                });
            } else if let Some((start, end)) = run.take() {
                kept.push(chunk.slice(start..end));
                chunk_kept = true;
            }
        }
        if let Some((start, end)) = run.take() {
            kept.push(chunk.slice(start..end));
            chunk_kept = true;
        }
        if !chunk_kept {
            discarded += 1;
        }
    }
    if dropped_by_cap > 0 {
        log::info!(
            "[spoton/unified] /stream: relay start dropped {} audio pages more than {} ms behind the newest queued page",
            dropped_by_cap,
            RELAY_BACKLOG_MAX_FRAMES * 1000 / u64::from(SAMPLE_RATE)
        );
    }
    (kept, discarded)
}

/// The relay's wait for the sink's OGG header pages at a new `/stream` GET. Returns the
/// header snapshot (empty if there is none). Extracted from the handler (quick 261110-r38)
/// so the wait can be tested without a socket.
async fn wait_for_ogg_headers(
    buf: &std::sync::Mutex<Vec<Bytes>>,
    complete: Option<&AtomicBool>,
    serial: Option<&AtomicU32>,
    wait: Duration,
) -> Vec<Bytes> {
    let mut header_snapshot: Vec<Bytes> = Vec::new();
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        // Read order matters (quick 261110-r38): buffer, then the flag, then the serial.
        let read_buf = || {
            let guard = buf.lock().unwrap_or_else(|e| e.into_inner());
            let s = guard
                .first()
                .filter(|p| p.len() >= 18)
                .map(|p| u32::from_le_bytes(p[14..18].try_into().unwrap_or([0; 4])))
                .unwrap_or(0);
            (guard.len(), s, guard.clone())
        };
        let (n, buf_serial, snapshot) = read_buf();
        let headers_done = complete
            .map(|b| b.load(Ordering::Acquire))
            .unwrap_or(false);
        let expected_serial = serial
            .map(|s| s.load(Ordering::Acquire))
            .unwrap_or(0);
        let serial_ok = expected_serial == 0 || buf_serial == expected_serial;
        if headers_done && n >= 2 && serial_ok {
            header_snapshot = snapshot;
            break;
        }
        // Headers of the confirmed serial are known absent: the first buffer read was empty
        // and the flag is true, so read the buffer a second time under the lock.
        //
        // Proof that two empty reads around a true flag mean "no header page of the
        // confirmed serial is buffered": (1) every emptying of the buffer is preceded by a
        // store of `complete = false` (start() long before the first page after it; the
        // serial-change branch of write() at its `complete` store before it clears), and
        // (2) every header page of a serial is pushed under the mutex before the store of
        // `complete = true` that confirms that serial (pages are processed in order, and the
        // decoder delivers its headers and the first audio page in separate write() calls).
        // A flag load that sees true synchronizes with that store, so the second lock
        // acquisition sees every header push of the confirmed serial. The first read alone
        // would admit "buffer read old and empty, flag read new and true" (the headers were
        // pushed between the two loads); the second read closes that.
        if n == 0 && headers_done {
            let (n2, _, _) = read_buf();
            if n2 == 0 {
                log::warn!(
                    "[spoton/unified] /stream: OGG headers of serial {} are not buffered \
                     (first page after start() was audio) - starting without header replay",
                    expected_serial
                );
                break;
            }
        }
        if tokio::time::Instant::now() >= deadline {
            if n >= 2 && serial_ok {
                header_snapshot = snapshot;
            }
            log::warn!(
                "[spoton/unified] /stream: OGG header wait \
                 timeout after {}s (pages={}, done={}, serial match={}){}",
                wait.as_secs(), n, headers_done, serial_ok,
                if header_snapshot.is_empty() {
                    " - skipping replay, keeping queued chunks"
                } else { "" }
            );
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    header_snapshot
}

/// Shared header state the relay needs to repair a stream after an overflow.
#[derive(Clone)]
struct RelayHeaders {
    buf: Arc<std::sync::Mutex<Vec<Bytes>>>,
    serial: Arc<AtomicU32>,
    complete: Arc<AtomicBool>,
}

/// Per-connection relay state: what was last forwarded to the client.
struct RelayCursor {
    passthrough: bool,
    /// Serial of the last OGG page forwarded to this client (0 = none yet / PCM).
    last_serial: u32,
    headers: Option<RelayHeaders>,
}

/// Outcome of one relay pass over the Connect channel.
enum RelayStep {
    /// Forward this chunk.
    Chunk(Bytes),
    /// Forward these header pages (a new logical stream starts after an overflow).
    Replay(Vec<Bytes>),
    /// Nothing to forward this pass.
    Idle,
}

/// One relay read step on the Connect channel (GH #202).
///
/// When the sink flagged an overflow (it dropped chunks because nobody read), the
/// queued backlog is stale: discard it in one go and report Idle for this pass, so
/// the first chunk forwarded after the stall is live. That is drop-oldest on a
/// bounded `mpsc` without replacing it. Otherwise a plain FIFO `try_recv`.
///
/// A `Full` that lands between the `swap` and the drain sets the flag again and
/// costs one extra pass (at most one page at 1x); accepted, no lock.
fn relay_step(
    rx: &mut mpsc::Receiver<Bytes>,
    overflow: &AtomicBool,
    cursor: &mut RelayCursor,
) -> RelayStep {
    if overflow.swap(false, Ordering::AcqRel) {
        let n = drain_all(rx);
        // W-2: if the stream moved to a new logical stream (serial) while this
        // connection was not reading, its header pages were dropped or drained with
        // the backlog. Replay them before any live page of that serial; never when
        // the serial is unchanged (a second BOS of the same serial re-opens the link).
        let replay = cursor.headers.as_ref().filter(|_| cursor.passthrough).and_then(|h| {
            let current = h.serial.load(Ordering::Acquire);
            if !h.complete.load(Ordering::Acquire) || current == 0 || current == cursor.last_serial {
                return None;
            }
            let snapshot = h.buf.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let matches = snapshot
                .first()
                .and_then(|p| ogg_pages(p).first().map(|pg| pg.serial))
                == Some(current);
            if matches { Some((current, snapshot)) } else { None }
        });
        log::info!(
            "[spoton/unified] /stream: sink overflowed while nobody read - discarded {} queued stale chunks{}",
            n,
            if replay.is_some() { ", replaying headers of the new stream" } else { "" }
        );
        if let Some((current, snapshot)) = replay {
            cursor.last_serial = current;
            return RelayStep::Replay(snapshot);
        }
        return RelayStep::Idle;
    }
    match rx.try_recv() {
        Ok(chunk) => {
            if cursor.passthrough {
                if let Some(serial) = last_ogg_serial(&chunk) {
                    cursor.last_serial = serial;
                }
            }
            RelayStep::Chunk(chunk)
        }
        Err(_) => RelayStep::Idle,
    }
}

impl Sink for UnifiedHttpStreamSink {
    fn start(&mut self) -> SinkResult<()> {
        self.last_track_gen = self.track_gen.load(Ordering::Acquire);
        self.began_at = Instant::now();
        self.reload_timing.restart(self.began_at);
        self.frames_consumed = 0;
        self.granule_offset = -1; // Phase 44 fix: re-capture on first audio page
        self.ogg_serial = 0;
        self.ogg_track_base_frames = 0;
        self.ogg_timeline_frames = 0;
        self.credit_frames = 0; // quick 261109-f4r (C): the credit is once per start()
        // Quick 261110-r38 (W1): a resume continues the same logical stream and the
        // decoder does not resend its headers, so a /stream connection opened after the
        // resume needs the pages already buffered: the buffer and its serial are kept.
        // The first page after start() confirms them (same serial, audio page) or
        // replaces them (new serial, or a header set), see write(). Until then
        // `complete` is false, so the relay waits instead of taking the buffer.
        if self.passthrough {
            self.ogg_headers_complete.store(false, Ordering::Release);
            self.collecting_headers = true;
        }
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        // CRITICAL: do NOT call exit() here (Pitfall 1).
        // Connect daemon must not exit on track boundary.
        self.frames_consumed = 0;
        self.began_at = Instant::now();
        self.granule_offset = -1;
        self.ogg_serial = 0;
        self.ogg_track_base_frames = 0;
        self.ogg_timeline_frames = 0;
        self.credit_frames = 0;
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let current_track_gen = self.track_gen.load(Ordering::Acquire);
        if current_track_gen != self.last_track_gen {
            log::info!(
                "[spoton/unified] Connect track generation {} -> {}",
                self.last_track_gen,
                current_track_gen
            );
            self.last_track_gen = current_track_gen;
            if self.passthrough {
                log::debug!(
                    "[spoton/unified] Connect TrackChanged observed in OGG passthrough; \
                     waiting for OGG serial boundary before resetting stream headers"
                );
            }
            // PCM gapless: no reset needed — frames_consumed and began_at
            // continue naturally across track boundaries.
        }

        match packet {
            AudioPacket::Samples(samples) => {
                let samples_s16 = converter.f64_to_s16(&samples);
                // SAFETY: i16 values are valid as two u8 bytes.
                let bytes: &[u8] = unsafe {
                    std::slice::from_raw_parts(
                        samples_s16.as_ptr().cast::<u8>(),
                        samples_s16.len() * std::mem::size_of::<i16>(),
                    )
                };

                // Wall-clock rate-limiter (CON-14), 1x since start(), shifted by the one-off
                // fresh-relay credit (`credit_frames`, 0 unless granted). There is NO
                // buffer-latency addend any more: it held the first packet of every
                // start() back by 2 s on the player thread, which opened a data gap at
                // squeezelite after every pause/resume (quick 261109-ath).
                let frames_in_packet = (samples.len() / NUM_CHANNELS as usize) as u64;
                self.frames_consumed = self.frames_consumed.saturating_add(frames_in_packet);
                self.maybe_grant_credit();
                let expected_ns: u128 = u128::from(self.frames_consumed.saturating_sub(self.credit_frames))
                    * 1_000_000_000u128
                    / u128::from(SAMPLE_RATE);
                let elapsed_ns: u128 = self.began_at.elapsed().as_nanos();

                if expected_ns > elapsed_ns {
                    let park_ns = (expected_ns - elapsed_ns) as u64;
                    self.reload_timing.add_parked(Duration::from_nanos(park_ns));
                    std::thread::sleep(Duration::from_nanos(park_ns));
                }

                let chunk = Bytes::copy_from_slice(bytes);
                self.push_live(chunk)?;
                if let Some(line) = self.reload_timing.finish(Instant::now()) {
                    log::debug!("{line}");
                }
            }
            AudioPacket::Raw(bytes) => {
                let chunk = Bytes::from(bytes);

                // Unified per-page OGG parsing: serial tracking, header
                // buffering, and granule-based rate-limiting in one pass.
                // Replaces three separate passes (header check on whole chunk,
                // serial check on first page only, granule scan on all pages).
                let mut last_timeline_frames: Option<u128> = None;
                let mut pos = 0usize;
                while pos + 27 <= chunk.len() {
                    if &chunk[pos..pos + 4] != b"OggS" {
                        break;
                    }
                    let granule = i64::from_le_bytes(
                        chunk[pos + 6..pos + 14]
                            .try_into()
                            .expect("OGG granule_position slice is exactly 8 bytes"),
                    );
                    let serial = u32::from_le_bytes(
                        chunk[pos + 14..pos + 18]
                            .try_into()
                            .expect("OGG serial is 4 bytes"),
                    );
                    let n_segments = chunk[pos + 26] as usize;
                    if pos + 27 + n_segments > chunk.len() {
                        break;
                    }
                    let body_size: usize = chunk[pos + 27..pos + 27 + n_segments]
                        .iter()
                        .map(|&b| b as usize)
                        .sum();
                    let page_size = 27 + n_segments + body_size;
                    if pos + page_size > chunk.len() {
                        break;
                    }

                    // Serial tracking — detect gapless track transitions.
                    // Accumulate timeline instead of resetting began_at so the
                    // rate-limiter does not re-apply buffer latency as a gap.
                    if self.ogg_serial == 0 {
                        if granule != 0
                            && serial == self.ogg_header_serial.load(Ordering::Acquire)
                        {
                            // Quick 261110-r38 (W1), keep branch: the first page after
                            // start() is an audio page of the retained serial (a resume;
                            // also the EOS page that opens a seek-shaped chunk). The
                            // retained headers are confirmed. Close the collection so no
                            // audio or granule -1 page is ever appended behind them.
                            self.ogg_serial = serial;
                            self.collecting_headers = false;
                            self.ogg_headers_complete.store(true, Ordering::Release);
                        } else {
                            // Replace branch: another serial, or a header set (granule 0,
                            // also a re-emission of the same serial: a second BOS behind
                            // the retained one would re-open the link at the decoder).
                            // `complete` is false here (start() stored it), and is stored
                            // again before the buffer is emptied.
                            self.ogg_serial = serial;
                            self.ogg_headers_complete.store(false, Ordering::Release);
                            let mut buf = self.ogg_header_buf.lock().unwrap_or_else(|e| e.into_inner());
                            buf.clear();
                            drop(buf);
                            self.ogg_header_serial.store(serial, Ordering::Release);
                        }
                    } else if serial != self.ogg_serial {
                        log::info!(
                            "[spoton/unified] OGG serial change: {} -> {} — \
                             continuing rate-limiter timeline",
                            self.ogg_serial, serial
                        );
                        self.ogg_serial = serial;
                        self.reload_timing.restart(Instant::now());
                        self.ogg_header_serial.store(serial, Ordering::Release);
                        self.ogg_headers_complete.store(false, Ordering::Release);
                        self.ogg_track_base_frames = last_timeline_frames
                            .unwrap_or(self.ogg_timeline_frames);
                        self.granule_offset = 0;
                        self.collecting_headers = true;
                        let mut buf = self.ogg_header_buf.lock().unwrap_or_else(|e| e.into_inner());
                        buf.clear();
                    }

                    // Per-page header buffering. A decoder packet may span old
                    // audio and the next track's headers during rapid skips;
                    // buffering individual pages (not whole chunks) ensures
                    // reconnecting clients get valid stream setup data.
                    if self.collecting_headers {
                        if granule <= 0 {
                            let header_page = chunk.slice(pos..pos + page_size);
                            self.reload_timing.note_headers(Instant::now());
                            let mut buf = self.ogg_header_buf.lock().unwrap_or_else(|e| e.into_inner());
                            buf.push(header_page);
                        } else {
                            self.collecting_headers = false;
                            self.ogg_headers_complete.store(true, Ordering::Release);
                        }
                    }

                    // Granule tracking — build continuous timeline across tracks.
                    if granule > 0 {
                        if self.granule_offset < 0 {
                            self.granule_offset = granule;
                        }
                        let relative_granule = (granule - self.granule_offset).max(0) as u128;
                        last_timeline_frames = Some(
                            self.ogg_track_base_frames.saturating_add(relative_granule)
                        );
                    }

                    pos += page_size;
                }

                // Rate limiting — continuous timeline across gapless tracks, 1x since
                // start(). No buffer-latency addend (see the PCM path above): in
                // passthrough librespot skips PositionCorrection, so the addend was
                // pure delay on the first page after every start().
                if let Some(timeline_frames) = last_timeline_frames {
                    self.ogg_timeline_frames = timeline_frames;
                    self.maybe_grant_credit();
                    let expected_ns: u128 = timeline_frames
                        .saturating_sub(u128::from(self.credit_frames))
                        * 1_000_000_000u128
                        / u128::from(SAMPLE_RATE);
                    let elapsed_ns: u128 = self.began_at.elapsed().as_nanos();

                    if expected_ns > elapsed_ns {
                        let park_ns = (expected_ns - elapsed_ns) as u64;
                        self.reload_timing.add_parked(Duration::from_nanos(park_ns));
                        std::thread::sleep(Duration::from_nanos(park_ns));
                    }
                }

                // Header pages were captured into ogg_header_buf above, before this
                // send, so a dropped chunk never loses the replay data.
                self.push_live(chunk)?;
                if last_timeline_frames.is_some() {
                    if let Some(line) = self.reload_timing.finish(Instant::now()) {
                        log::debug!("{line}");
                    }
                }
            }
        }

        Ok(())
    }
}

// -------------------------------------------------------------------------
// unified_http_server — combined route dispatch for Browse + Connect
// -------------------------------------------------------------------------

/// Combined HTTP server for the unified daemon.
///
/// Routes:
///   GET  /stream         — Connect PCM relay (rate-limited, D-01 only when enable_connect)
///   GET  /track/{id}     — Browse track decode (unbuffered PCM, D-10 priority)
///   POST /control/*      — Spirc commands (D-01 only when enable_connect)
///   GET  /health         — 200 OK for watchdog keepalive (optional LMS use)
///   *                    — 404
///
/// Mode transitions (D-09, D-10):
///   Connect -> Browse:   GET /track/{id} arrives while Connect active.
///     => Lock mode_state, if Connect: call spirc.pause() (D-10), set mode to Browse(id).
///   Browse -> Connect:   Spirc TrackChanged fires while Browse active.
///     => browse_cancel.notify_waiters() -> Browse handler drops pcm_tx -> EOF to LMS (D-09).
///     => Set mode to Connect.
#[allow(clippy::too_many_arguments)]
async fn unified_http_server(
    listener: TcpListener,
    session: Arc<tokio::sync::Mutex<Session>>,
    spirc_active: Arc<AtomicBool>,
    spirc_handle: Arc<std::sync::Mutex<Option<Spirc>>>,
    mode_state: Arc<tokio::sync::Mutex<ActiveMode>>,
    browse_cancel: Arc<tokio::sync::Notify>,
    enable_connect: bool,
    // Connect-path PCM pipeline (None when enable_connect is false)
    pcm_rx: Option<Arc<std::sync::Mutex<mpsc::Receiver<Bytes>>>>,
    flush_rx: Option<Arc<std::sync::Mutex<watch::Receiver<u64>>>>,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
    // browse_preempting: signals the /stream relay to exit cleanly on D-10 takeover
    browse_preempting: Arc<AtomicBool>,
    // browse_abort_gen: monotonic counter incremented on each /track/ request to detect
    // rapid-skip supersession (T-30-05). Pre-spawn check drops pcm_tx if a newer request
    // arrived while waiting for Player::load() to complete.
    browse_abort_gen: Arc<AtomicU64>,
    // Session reconnect infrastructure: Browse requests signal the main event loop
    // when consecutive track failures indicate a dead Spotify session.
    browse_reconnect_signal: Arc<tokio::sync::Notify>,
    browse_reconnect_pending: Arc<AtomicBool>,
    consecutive_browse_fails: Arc<AtomicU32>,
    // Session health monitoring (Phase 36): track session creation time and last audio activity for /health endpoint
    session_created_at: Arc<std::sync::Mutex<Instant>>,
    last_activity: Arc<std::sync::Mutex<Instant>>,
    // Phase 42: OGG/Vorbis passthrough — determines Content-Type and AudioPacket handling
    passthrough: bool,
    // Phase 43 (D-03): OGG header buffer for /stream replay after drain. Some when
    // enable_connect is true, None in Browse-only mode.
    ogg_header_buf: Option<Arc<std::sync::Mutex<Vec<Bytes>>>>,
    ogg_header_serial: Option<Arc<AtomicU32>>,
    ogg_headers_complete: Option<Arc<AtomicBool>>,
    // GH #202: overflow flag shared with the Connect sink (Some when enable_connect).
    connect_overflow: Option<Arc<AtomicBool>>,
    // Quick 261109-f4r (C): relay -> sink fresh-start signal (Some when enable_connect).
    connect_burst: Option<Arc<BurstArm>>,
    // Issue #97: bitrate for Browse Player creation
    bitrate: Bitrate,
    enable_normalisation: bool,
    // GH #128: LMS notifier clone for the relay-start position resync.
    // Some when enable_connect and --lms are configured; None otherwise.
    lms_notify: Option<LMS>,
    // D-03: /control/transfer bookkeeping (rate limit + play arm).
    transfer_state: Arc<TransferState>,
    // GH #207: AP-drop recovery state (/control answers 503, /health reports it).
    recovery_shared: Arc<RecoveryShared>,
) {
    let graceful = GracefulShutdown::new();
    let mut shutdown_rx = std::pin::pin!(shutdown_rx);

    // CR-01: guard against concurrent relay tasks that would split the PCM stream.
    let relay_active = Arc::new(AtomicBool::new(false));
    // M15: relay takeover generation — each new /stream connection bumps this.
    // The old relay's loop exits on generation mismatch, and its RelayGuard
    // only clears relay_active if the generation still matches (so a stale
    // guard cannot clear the flag out from under the new relay).
    let relay_gen = Arc::new(AtomicU64::new(0));
    let last_data_time: Arc<std::sync::Mutex<Option<Instant>>> = Arc::new(std::sync::Mutex::new(None));

    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                let (stream, _addr) = match accept_result {
                    Ok(pair) => pair,
                    Err(_) => continue,
                };

                let session = Arc::clone(&session);
                let spirc_active = Arc::clone(&spirc_active);
                let spirc_handle = Arc::clone(&spirc_handle);
                let mode_state = Arc::clone(&mode_state);
                let browse_cancel = Arc::clone(&browse_cancel);
                let relay_active = Arc::clone(&relay_active);
                let relay_gen = Arc::clone(&relay_gen);
                let last_data_time = Arc::clone(&last_data_time);
                let browse_preempting = Arc::clone(&browse_preempting);
                let browse_abort_gen = Arc::clone(&browse_abort_gen);
                let browse_reconnect_signal = Arc::clone(&browse_reconnect_signal);
                let browse_reconnect_pending = Arc::clone(&browse_reconnect_pending);
                let consecutive_browse_fails = Arc::clone(&consecutive_browse_fails);
                let session_created_at = Arc::clone(&session_created_at);
                let last_activity = Arc::clone(&last_activity);
                let pcm_rx = pcm_rx.as_ref().map(Arc::clone);
                let flush_rx = flush_rx.as_ref().map(Arc::clone);
                let ogg_header_buf = ogg_header_buf.as_ref().map(Arc::clone);
                let ogg_header_serial = ogg_header_serial.as_ref().map(Arc::clone);
                let ogg_headers_complete = ogg_headers_complete.as_ref().map(Arc::clone);
                let connect_overflow = connect_overflow.as_ref().map(Arc::clone);
                let connect_burst = connect_burst.as_ref().map(Arc::clone);
                let lms_notify = lms_notify.clone();
                let transfer_state = Arc::clone(&transfer_state);
                let recovery_shared = Arc::clone(&recovery_shared);

                let svc = hyper::service::service_fn(move |req: hyper::Request<hyper::body::Incoming>| {
                    let session = Arc::clone(&session);
                    let spirc_active = Arc::clone(&spirc_active);
                    let spirc_handle = Arc::clone(&spirc_handle);
                    let mode_state = Arc::clone(&mode_state);
                    let browse_cancel = Arc::clone(&browse_cancel);
                    let relay_active = Arc::clone(&relay_active);
                    let relay_gen = Arc::clone(&relay_gen);
                    let last_data_time = Arc::clone(&last_data_time);
                    let browse_preempting = Arc::clone(&browse_preempting);
                    let browse_abort_gen = Arc::clone(&browse_abort_gen);
                    let browse_reconnect_signal = Arc::clone(&browse_reconnect_signal);
                    let browse_reconnect_pending = Arc::clone(&browse_reconnect_pending);
                    let consecutive_browse_fails = Arc::clone(&consecutive_browse_fails);
                    let session_created_at = Arc::clone(&session_created_at);
                    let last_activity = Arc::clone(&last_activity);
                    let pcm_rx = pcm_rx.as_ref().map(Arc::clone);
                    let flush_rx = flush_rx.as_ref().map(Arc::clone);
                    let ogg_header_buf = ogg_header_buf.as_ref().map(Arc::clone);
                    let ogg_header_serial = ogg_header_serial.as_ref().map(Arc::clone);
                    let ogg_headers_complete = ogg_headers_complete.as_ref().map(Arc::clone);
                    let connect_overflow = connect_overflow.as_ref().map(Arc::clone);
                    let connect_burst = connect_burst.as_ref().map(Arc::clone);
                    let lms_notify = lms_notify.clone();
                    let transfer_state = Arc::clone(&transfer_state);
                    let recovery_shared = Arc::clone(&recovery_shared);

                    async move {
                        let path = req.uri().path().to_owned();
                        let method = req.method().clone();

                        // ---- GET /health ----
                        if method == Method::GET && path == "/health" {
                            // One session lock: validity, the user (masked inside
                            // health_json, never logged) and the refused-key count
                            // (Phase 89, CONTRACT-89).
                            let (session_valid, username, audio_key_denials) = {
                                let s = session.lock().await;
                                (!s.is_invalid(), s.username(), s.audio_key().consecutive_denials())
                            };
                            let age_secs = {
                                let t = session_created_at.lock().unwrap_or_else(|e| e.into_inner());
                                t.elapsed().as_secs()
                            };
                            let idle_secs = {
                                let t = last_activity.lock().unwrap_or_else(|e| e.into_inner());
                                t.elapsed().as_secs()
                            };
                            let json = health_json(
                                session_valid,
                                age_secs,
                                idle_secs,
                                recovery_shared.is_recovering(),
                                &username,
                                audio_key_denials,
                            );
                            let body = Full::new(Bytes::from(json))
                                .map_err(|e| match e {})
                                .boxed();
                            let resp = Response::builder()
                                .status(StatusCode::OK)
                                .header("Content-Type", "application/json")
                                .body(body)
                                .expect("health response builder");
                            return Ok::<Response<BoxBody<Bytes, hyper::Error>>, hyper::Error>(resp);
                        }


                        // ---- GET /stream — Connect PCM relay ----
                        if method == Method::GET && path == "/stream" {
                            if !enable_connect {
                                // Unified daemon started without --enable-connect.
                                // /stream is only available in Connect mode.
                                return Ok(empty_response(StatusCode::NOT_FOUND));
                            }

                            let pcm_rx = match pcm_rx {
                                Some(rx) => rx,
                                None => return Ok(empty_response(StatusCode::SERVICE_UNAVAILABLE)),
                            };
                            let flush_rx = match flush_rx {
                                Some(rx) => rx,
                                None => return Ok(empty_response(StatusCode::SERVICE_UNAVAILABLE)),
                            };

                            let overflow = connect_overflow.unwrap_or_default();
                            let burst = connect_burst;

                            log::debug!("[spoton/unified] /stream: GET request received");

                            // Wait up to 5s for Spirc to become active (Pitfall 2 / T-05-06).
                            let mut waited = 0u32;
                            while !spirc_active.load(Ordering::Acquire) && waited < 50 {
                                tokio::time::sleep(Duration::from_millis(100)).await;
                                waited += 1;
                            }
                            if !spirc_active.load(Ordering::Acquire) {
                                let body = Full::new(Bytes::new())
                                    .map_err(|e| match e {})
                                    .boxed();
                                let resp = Response::builder()
                                    .status(StatusCode::SERVICE_UNAVAILABLE)
                                    .header("Retry-After", "2")
                                    .header("Content-Length", "0")
                                    .body(body)
                                    .expect("static 503 spirc-inactive builder");
                                return Ok(resp);
                            }

                            // T-05.3-03: health-check for stuck relay_active (> 60s with no data).
                            if relay_active.load(Ordering::Acquire) {
                                let stuck = {
                                    let t = last_data_time.lock().unwrap_or_else(|e| e.into_inner());
                                    t.map(|ts| ts.elapsed() > Duration::from_secs(60)).unwrap_or(false)
                                };
                                if stuck {
                                    log::warn!("[spoton/unified] /stream: relay_active stuck for >60s — force-clearing");
                                    relay_active.store(false, Ordering::Release);
                                }
                            }

                            // Connection takeover: if relay_active is true, the old relay
                            // is likely stale. Force-clear and accept the new connection.
                            if relay_active.swap(true, Ordering::AcqRel) {
                                log::warn!("[spoton/unified] /stream: relay_active was true — taking over (old relay likely stale)");
                            }

                            // M15: claim a new relay generation. The old relay (if any)
                            // observes the mismatch and exits within one loop iteration;
                            // its RelayGuard then leaves relay_active alone.
                            let my_relay_gen = relay_gen.fetch_add(1, Ordering::AcqRel) + 1;

                            // Reset browse_preempting flag for this new relay session.
                            browse_preempting.store(false, Ordering::Release);

                            // Wait for OGG headers before draining — on track
                            // transitions LMS reconnects before the sink has
                            // buffered the new track's header pages. Wait for
                            // the sink's completion signal rather than a fixed
                            // page count (Vorbis Comment+Setup may share a page).
                            let mut header_snapshot: Vec<Bytes> = Vec::new();
                            if passthrough {
                                if let Some(ref buf) = ogg_header_buf {
                                    // Quick 261109-f4r (D): Spotify delivers a transfer paused and the
                                    // `resume` follows 2.5 s (normal) to 4 s (slow) later, so the old 3 s
                                    // bound was load-bearing against the normal case and timed out on the
                                    // slow one. squeezelite waits on the socket indefinitely.
                                    header_snapshot = wait_for_ogg_headers(
                                        buf,
                                        ogg_headers_complete.as_deref(),
                                        ogg_header_serial.as_deref(),
                                        Duration::from_secs(OGG_HEADER_WAIT_SECS),
                                    )
                                    .await;
                                }
                            }

                            // Relay-start backlog: discard what is stale, keep the
                            // audio of the current stream that was pushed while the
                            // GET was on its way (see relay_start_backlog).
                            let (kept_audio, drained) = {
                                let mut rx = pcm_rx.lock().unwrap_or_else(|e| e.into_inner());
                                relay_start_backlog(&mut rx, &overflow, passthrough, &header_snapshot)
                            };
                            log::debug!(
                                "[spoton/unified] /stream: relay starting, drained {} stale chunks, kept {} audio chunks",
                                drained, kept_audio.len()
                            );

                            // Quick 261109-f4r (C): tell the sink a fresh relay just started; it
                            // grants the one-off burst credit iff its own timeline is fresh too
                            // (rules at BURST_THRESHOLD_FRAMES). Armed after the backlog drain so
                            // the pages kept above stay at their original pace.
                            if let Some(ref burst) = burst {
                                burst.arm();
                            }

                            // GH #128: the relay is now actually about to serve audio.
                            // Push a fresh position notification anchored to THIS moment
                            // — the transfer-time position LMS received via the Playing
                            // event is stale by the whole buffer-fill gap on a mid-song
                            // handoff. Spawned so a slow/unreachable LMS (notify has a
                            // 5s timeout) can never delay the relay itself.
                            if let Some(ref lms) = lms_notify {
                                let lms = lms.clone();
                                tokio::spawn(async move {
                                    lms.resync_position_at_relay_start().await;
                                });
                            }

                            // Per-connection relay channel: 64 live frames plus room for
                            // the header replay and the kept backlog, which are queued
                            // before the response (and so the reader) exists.
                            let (conn_tx, conn_rx) = mpsc::channel::<Bytes>(
                                64 + header_snapshot.len() + kept_audio.len(),
                            );

                            // Replay snapshotted OGG headers (BOS + Vorbis setup)
                            // before the relay begins. The drain above removed them
                            // from the main channel; the decoder needs them.
                            if passthrough && !header_snapshot.is_empty() {
                                let mut replayed = 0u64;
                                'replay: for header_chunk in &header_snapshot {
                                    loop {
                                        match conn_tx.try_send(header_chunk.clone()) {
                                            Ok(()) => { replayed += 1; break; }
                                            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                                                tokio::time::sleep(Duration::from_millis(1)).await;
                                            }
                                            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                                                log::warn!("[spoton/unified] /stream: conn_tx closed during header replay");
                                                break 'replay;
                                            }
                                        }
                                    }
                                }
                                log::debug!("[spoton/unified] /stream: replayed {} OGG header pages", replayed);
                            }

                            // Audio of the current stream that was already queued: it
                            // follows the headers, in order. Capacity was reserved above.
                            for chunk in &kept_audio {
                                if conn_tx.try_send(chunk.clone()).is_err() {
                                    break;
                                }
                            }

                            let mut relay_cursor = RelayCursor {
                                passthrough,
                                last_serial: kept_audio
                                    .iter()
                                    .rev()
                                    .find_map(|c| last_ogg_serial(c))
                                    .or_else(|| header_snapshot.iter().rev().find_map(|c| last_ogg_serial(c)))
                                    .unwrap_or(0),
                                headers: match (&ogg_header_buf, &ogg_header_serial, &ogg_headers_complete) {
                                    (Some(b), Some(s), Some(c)) if passthrough => Some(RelayHeaders {
                                        buf: Arc::clone(b),
                                        serial: Arc::clone(s),
                                        complete: Arc::clone(c),
                                    }),
                                    _ => None,
                                },
                            };

                            let pcm_rx_clone = Arc::clone(&pcm_rx);
                            let overflow_clone = Arc::clone(&overflow);
                            let flush_rx_clone = Arc::clone(&flush_rx);
                            let relay_active_clone = Arc::clone(&relay_active);
                            let relay_gen_clone = Arc::clone(&relay_gen);
                            let last_data_time_clone = Arc::clone(&last_data_time);
                            let browse_preempting_clone = Arc::clone(&browse_preempting);
                            let last_activity_relay = Arc::clone(&last_activity);
                            tokio::spawn(async move {
                                // M15: the guard clears relay_active only if this relay is
                                // still the current generation — a superseded relay's guard
                                // must not clear the flag out from under the new relay.
                                struct RelayGuard {
                                    active: Arc<AtomicBool>,
                                    gen: Arc<AtomicU64>,
                                    my_gen: u64,
                                }
                                impl Drop for RelayGuard {
                                    fn drop(&mut self) {
                                        if self.gen.load(Ordering::Acquire) == self.my_gen {
                                            self.active.store(false, Ordering::Release);
                                        }
                                    }
                                }
                                let _guard = RelayGuard {
                                    active: Arc::clone(&relay_active_clone),
                                    gen: Arc::clone(&relay_gen_clone),
                                    my_gen: my_relay_gen,
                                };

                                let mut last_seen_gen: u64 = {
                                    let rx = flush_rx_clone.lock().unwrap_or_else(|e| e.into_inner());
                                    let val: u64 = *rx.borrow();
                                    drop(rx);
                                    val
                                };

                                loop {
                                    // Pitfall 2: Browse preemption — exit relay cleanly when Browse
                                    // takes over (D-10). browse_preempting is set before the Browse
                                    // handler pauses Spirc; relay exits so conn_tx is dropped,
                                    // sending EOF on /stream to LMS, freeing relay_active.
                                    if browse_preempting_clone.load(Ordering::Acquire) {
                                        log::debug!("[spoton/unified] /stream: browse_preempting — relay exiting");
                                        break;
                                    }

                                    // M15: a newer /stream connection has taken over — exit so
                                    // both relays do not poll the shared pcm_rx.
                                    if relay_gen_clone.load(Ordering::Acquire) != my_relay_gen {
                                        log::debug!("[spoton/unified] /stream: relay generation superseded — relay exiting");
                                        break;
                                    }

                                    // Seek-flush drain: poll before each read.
                                    let flush_pending = {
                                        let rx = flush_rx_clone.lock().unwrap_or_else(|e| e.into_inner());
                                        let changed = rx.has_changed().unwrap_or(false);
                                        drop(rx);
                                        changed
                                    };
                                    if flush_pending {
                                        let new_gen = {
                                            let mut rx = flush_rx_clone.lock().unwrap_or_else(|e| e.into_inner());
                                            let val: u64 = *rx.borrow_and_update();
                                            drop(rx);
                                            val
                                        };
                                        if new_gen > last_seen_gen {
                                            let mut count: u64 = 0;
                                            let mut rx = pcm_rx_clone.lock().unwrap_or_else(|e| e.into_inner());
                                            while rx.try_recv().is_ok() { count += 1; }
                                            last_seen_gen = new_gen;
                                            let _ = count;
                                        }
                                    }

                                    let step = {
                                        let mut rx = pcm_rx_clone.lock().unwrap_or_else(|e| e.into_inner());
                                        relay_step(&mut rx, &overflow_clone, &mut relay_cursor)
                                    };
                                    match step {
                                        RelayStep::Chunk(bytes) => {
                                            if conn_tx.send(bytes).await.is_err() {
                                                log::debug!("[spoton/unified] /stream: relay client disconnected");
                                                break;
                                            }
                                            *last_data_time_clone.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                                            *last_activity_relay.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
                                        }
                                        RelayStep::Replay(pages) => {
                                            let mut gone = false;
                                            for page in pages {
                                                if conn_tx.send(page).await.is_err() {
                                                    gone = true;
                                                    break;
                                                }
                                            }
                                            if gone {
                                                log::debug!("[spoton/unified] /stream: relay client disconnected");
                                                break;
                                            }
                                        }
                                        RelayStep::Idle => {
                                            tokio::time::sleep(Duration::from_millis(1)).await;
                                        }
                                    }
                                }
                            });

                            let stream = TokioStreamExt::map(ReceiverStream::new(conn_rx), |chunk| {
                                Ok::<Frame<Bytes>, hyper::Error>(Frame::data(chunk))
                            });
                            let body = BodyExt::boxed(StreamBody::new(stream));

                            let content_type = if passthrough {
                                "audio/ogg"
                            } else {
                                "audio/L16;rate=44100;channels=2"
                            };
                            let resp = Response::builder()
                                .status(StatusCode::OK)
                                .header("Content-Type", content_type)
                                .body(body)
                                .expect("stream response builder");
                            return Ok(resp);
                        }

                        // ---- GET /track/{id} or /episode/{id} — Browse decode ----
                        let (content_prefix, content_id_raw) =
                            if method == Method::GET && path.starts_with("/track/") {
                                ("track", &path["/track/".len()..])
                            } else if method == Method::GET && path.starts_with("/episode/") {
                                ("episode", &path["/episode/".len()..])
                            } else {
                                ("", "")
                            };
                        if !content_prefix.is_empty() {
                            let track_id_raw = content_id_raw;

                            // T-29-01 (mitigate): validate track ID as [A-Za-z0-9]+ before
                            // building SpotifyUri (same as browse.rs line 250).
                            if track_id_raw.is_empty() || !track_id_raw.chars().all(|c| c.is_ascii_alphanumeric()) {
                                log::warn!("[spoton/unified] rejected invalid track ID: {:?}", track_id_raw);
                                return Ok(empty_response(StatusCode::BAD_REQUEST));
                            }

                            // Parse optional ?start_position=N query parameter (seconds as f64).
                            let start_position_ms: u32 = req.uri().query()
                                .and_then(|q| {
                                    q.split('&')
                                        .find(|kv| kv.starts_with("start_position="))
                                        .and_then(|kv| kv.strip_prefix("start_position="))
                                        .and_then(|v| v.parse::<f64>().ok())
                                })
                                .map(|secs| {
                                    if secs < 0.0 { 0u32 } else { (secs * 1000.0).min(u32::MAX as f64) as u32 }
                                })
                                .unwrap_or(0);

                            let track_id = track_id_raw.to_owned();
                            let content_type = content_prefix.to_owned();
                            log::debug!("[spoton/unified] GET /{}/{} start_position_ms={}", content_type, track_id, start_position_ms);

                            // Wait for ongoing session reconnect before using the session.
                            if browse_reconnect_pending.load(Ordering::Acquire) {
                                log::debug!("[spoton/unified] /track: waiting for session reconnect...");
                                for _ in 0..50 {
                                    tokio::time::sleep(Duration::from_millis(100)).await;
                                    if !browse_reconnect_pending.load(Ordering::Acquire) { break; }
                                }
                                if browse_reconnect_pending.load(Ordering::Acquire) {
                                    log::warn!("[spoton/unified] /track: reconnect timed out after 5s — returning 503");
                                    return Ok(empty_response(StatusCode::SERVICE_UNAVAILABLE));
                                }
                            }

                            // T-30-05 (mitigate): increment browse_abort_gen to signal any
                            // in-flight /track/ task that it has been superseded by this request.
                            // fetch_add returns the OLD value; after our increment the counter is
                            // my_gen + 1. A subsequent request will push it to my_gen + 2 or higher.
                            let my_gen = browse_abort_gen.fetch_add(1, Ordering::SeqCst);

                            // D-10: Browse has priority. If Connect is active, pause Spirc first.
                            // Pitfall 3: Check ActiveMode mutex before proceeding.
                            // Pitfall 2: Set browse_preempting BEFORE pausing Spirc so the relay
                            //            exits cleanly before pcm_tx drains (race-free teardown).
                            {
                                let mut mode = mode_state.lock().await;
                                if *mode == ActiveMode::Connect {
                                    // Signal the /stream relay to exit (Pitfall 2).
                                    browse_preempting.store(true, Ordering::Release);

                                    // Shut down Spirc completely so no Connect events
                                    // leak into Browse mode (metadata, skip, control).
                                    // ZeroConf re-creates Spirc when the user re-selects
                                    // the device in the Spotify app.
                                    if let Ok(mut guard) = spirc_handle.lock() {
                                        if let Some(ref spirc) = *guard {
                                            let _ = spirc.shutdown();
                                        }
                                        *guard = None;
                                    }
                                    recovery_shared.clear_active(&spirc_active);
                                    log::info!("[spoton/unified] Browse preempting Connect -- Spirc shut down");
                                }
                                *mode = ActiveMode::Browse(track_id.clone());
                            }

                            // Per-request PCM channel.
                            let (pcm_tx, mut pcm_rx) = mpsc::channel::<Bytes>(256);

                            // Status channel: the verdict of serve_track_request (404 Unavailable,
                            // 409 superseded) when it ends.
                            let (status_tx, mut status_rx) = tokio::sync::oneshot::channel::<StatusCode>();

                            // 89-09: tells the serve task that the handler gave up at
                            // BROWSE_FIRST_SIGNAL_BOUND (notify_one keeps a permit, so the order of
                            // the two tasks does not matter).
                            let give_up = Arc::new(tokio::sync::Notify::new());
                            let give_up_for_task = Arc::clone(&give_up);

                            // H13: shared slot for the cancel-listener's abort handle. The serve
                            // task must be spawned FIRST (it consumes pcm_tx by move) so its
                            // AbortHandle exists when the cancel listener is spawned; the serve
                            // task in turn needs to abort the cancel listener from its tail —
                            // this Option slot resolves the ordering.
                            let cancel_listener_abort: Arc<std::sync::Mutex<Option<tokio::task::AbortHandle>>> =
                                Arc::new(std::sync::Mutex::new(None));

                            let session_snap = {
                                let s = session.lock().await;
                                s.clone()
                            };
                            // 89 review WR-04: the refused-key count of the session this load
                            // uses, before it asks for its key; read again at a 404 verdict.
                            let key_session = session_snap.clone();
                            let denials_before = key_session.audio_key().consecutive_denials();
                            let track_id_for_task = track_id.clone();
                            let content_type_for_task = content_type.clone();
                            let mode_state_for_task = Arc::clone(&mode_state);
                            let cancel_listener_abort_for_task = Arc::clone(&cancel_listener_abort);
                            let browse_abort_gen_task = Arc::clone(&browse_abort_gen);
                            let serve_task = tokio::spawn(async move {
                                // T-30-05 (mitigate): pre-spawn supersession check.
                                // If another /track/ request arrived while we were setting up
                                // (e.g. acquiring the session lock), abort before Player::load().
                                // Our increment set the counter to my_gen + 1; if it's already
                                // higher, a newer request has arrived and superseded us.
                                // H11: signal supersession as 409 CONFLICT — NOT 404 — so the
                                // outer handler does not count it as a browse failure (rapid
                                // skipping must not tear down a healthy session).
                                let current_gen = browse_abort_gen_task.load(Ordering::SeqCst);
                                if current_gen > my_gen + 1 {
                                    log::info!(
                                        "[spoton/unified] /track/{}: superseded by newer request (gen {} > {}+1) — aborting before Player::load",
                                        track_id_for_task, current_gen, my_gen
                                    );
                                    drop(pcm_tx);
                                    if let Some(h) = cancel_listener_abort_for_task
                                        .lock().unwrap_or_else(|e| e.into_inner()).take() {
                                        h.abort();
                                    }
                                    let _ = status_tx.send(StatusCode::CONFLICT);
                                    return;
                                }

                                // 89-09: the serve future owns the Player. It is boxed so that a
                                // give-up can hand it to the blocking pool: dropping a Player joins
                                // its threads, and its load thread runs until the load ends (up to
                                // about 58 s in a key back-off). Dropped on an async worker, that
                                // wait would stall the HTTP server (on a four-core host after four
                                // give-ups).
                                let content_type_for_serve = content_type_for_task.clone();
                                let track_id_for_serve = track_id_for_task.clone();
                                let mut serve: std::pin::Pin<Box<dyn std::future::Future<Output = StatusCode> + Send>> = Box::pin(async move {
                                    serve_track_request(&content_type_for_serve, &track_id_for_serve, session_snap, pcm_tx, start_position_ms, passthrough, bitrate, enable_normalisation).await
                                });
                                let status = tokio::select! {
                                    status = &mut serve => status,
                                    _ = give_up_for_task.notified() => {
                                        log::debug!("[spoton/unified] /track/{}: load abandoned at the bound, the Player is dropped off the async workers", track_id_for_task);
                                        tokio::task::spawn_blocking(move || drop(serve));
                                        StatusCode::GATEWAY_TIMEOUT
                                    }
                                };

                                // T-30-05 (informational): post-load gen check.
                                // serve_track_request drops pcm_tx when it returns, causing
                                // ReceiverStream EOF on the response side automatically.
                                // Log if we were superseded mid-stream for diagnostics.
                                let post_gen = browse_abort_gen_task.load(Ordering::SeqCst);
                                if post_gen > my_gen + 1 {
                                    log::debug!(
                                        "[spoton/unified] /track/{}: superseded during streaming (gen {} > {}+1)",
                                        track_id_for_task, post_gen, my_gen
                                    );
                                }
                                // Abort the cancel listener — serve is done, nothing to cancel.
                                if let Some(h) = cancel_listener_abort_for_task
                                    .lock().unwrap_or_else(|e| e.into_inner()).take() {
                                    h.abort();
                                }
                                // H12: only reset the mode if it still holds OUR track — a newer
                                // request may already have installed ITS track in the mode, and
                                // resetting it to Idle would corrupt Connect/Browse arbitration.
                                {
                                    let mut mode = mode_state_for_task.lock().await;
                                    if matches!(*mode, ActiveMode::Browse(ref t) if *t == track_id_for_task) {
                                        *mode = ActiveMode::Idle;
                                        log::debug!("[spoton/unified] Browse track completed — mode set to Idle");
                                    }
                                }
                                let _ = status_tx.send(status);
                            });
                            let serve_abort = serve_task.abort_handle();

                            // H13: the cancel listener aborts the SERVE TASK itself. Aborting
                            // drops the ORIGINAL pcm_tx held inside serve_track_request, which
                            // produces a real EOF on /track for LMS. (The old code dropped a
                            // CLONE of pcm_tx — a no-op, since serve kept the original sender
                            // and LMS held on to the dead stream.)
                            // Mode reset is intentionally NOT done on this path: browse_cancel
                            // is only notified from Spirc-takeover paths, and every one of them
                            // sets ActiveMode::Connect itself right after notify_waiters().
                            let cancel = Arc::clone(&browse_cancel);
                            let cancel_task = tokio::spawn(async move {
                                cancel.notified().await;
                                log::debug!("[spoton/unified] /track: browse_cancel notified — aborting serve task (EOF to LMS)");
                                serve_abort.abort();
                            });
                            let cancel_abort = cancel_task.abort_handle();
                            *cancel_listener_abort.lock().unwrap_or_else(|e| e.into_inner()) = Some(cancel_abort.clone());
                            // Close the registration race: if serve finished before the listener
                            // handle was stored, the tail's take() found None — abort it now so
                            // the listener does not linger waiting on browse_cancel.
                            if serve_task.is_finished() {
                                cancel_abort.abort();
                            }

                            // 89-09 (ACC-02): answer on the Player's first real signal, never on a
                            // timer. 200 only with the first audio chunk in hand; a verdict is
                            // answered as what it is however late it comes; without either the
                            // request gives up at BROWSE_FIRST_SIGNAL_BOUND.
                            let waited_from = Instant::now();
                            let first_signal = browse_first_signal(&mut pcm_rx, &mut status_rx, BROWSE_FIRST_SIGNAL_BOUND).await;

                            // H11: supersession is signalled as 409 CONFLICT and is NOT a
                            // browse failure — rapid skipping produces supersessions as a
                            // matter of course, and counting them tore down healthy sessions
                            // after only 2 skips. No failure-counter increment, no reconnect
                            // trigger, no mode touch (the newer request owns the mode; the
                            // superseded response goes to a connection LMS already abandoned).
                            if first_signal == BrowseFirstSignal::Verdict(StatusCode::CONFLICT) {
                                log::info!("[spoton/unified] /track/{}: superseded — 409, not counted as failure", track_id);
                                cancel_abort.abort();
                                return Ok(empty_response(StatusCode::CONFLICT));
                            }

                            if first_signal == BrowseFirstSignal::Verdict(StatusCode::NOT_FOUND) {
                                // Phase 88 Pitfall 4, redone for 89-09: a refused audio key during
                                // the fork's #1844 back-off cannot land here as code 2. The Player
                                // load path awaits `audio_key().request()` (playback/src/player.rs),
                                // which waits out every back-off (3, 5, 10 s ...) and asks again up
                                // to seven times; it hands the refusal back only after about 58 s,
                                // and this request gave up at BROWSE_FIRST_SIGNAL_BOUND (10 s) long
                                // before, in the NoAnswer arm below, which does not count.
                                // `try_request`, the call that answers at once during a back-off,
                                // has no caller in the Player. Pinned by
                                // browse_first_signal_bound_sits_between_the_three_clocks.
                                //
                                // Phase 89 (ACC-02): a code-1 (any non-2) refusal lands here,
                                // because the fork returns it at once and the load then fails on
                                // the undecrypted file, however long the load took. It is
                                // told apart through the core counter, per request (89 review
                                // WR-04, BrowseKeyRefusals): a 404 whose load saw a refusal, or
                                // that retries a refused title, says nothing about the session
                                // and is not counted toward the reconnect (a refused key is no
                                // dead session). A 404 with 0 denials, or one whose load saw
                                // none (a key timeout on a dead channel), counts as before.
                                let denials = key_session.audio_key().consecutive_denials();
                                let counts = BROWSE_KEY_REFUSALS
                                    .lock()
                                    .unwrap_or_else(|e| e.into_inner())
                                    .counts_toward_reconnect(&track_id, denials_before, denials);
                                let fails = if counts {
                                    let fails = consecutive_browse_fails.fetch_add(1, Ordering::SeqCst) + 1;
                                    log::info!("[spoton/unified] track unavailable — returning 404 (consecutive_fails={})", fails);
                                    fails
                                } else {
                                    log::info!(
                                        "[spoton/unified] track unavailable after a refused audio key - 404, not counted toward reconnect (audio_key_denials={})",
                                        denials
                                    );
                                    0
                                };
                                cancel_abort.abort();
                                // Reset mode to Idle since the track failed.
                                // H12: only when the mode still holds OUR track — a newer
                                // request may already have installed its own track.
                                {
                                    let mut mode = mode_state.lock().await;
                                    if matches!(*mode, ActiveMode::Browse(ref t) if *t == track_id) {
                                        *mode = ActiveMode::Idle;
                                    }
                                }
                                // Trigger session reconnect after 2+ consecutive failures.
                                // Single failure = likely genuinely unavailable track.
                                // Multiple failures = likely dead session (audio key channel closed).
                                if counts && fails >= 2 && !browse_reconnect_pending.swap(true, Ordering::AcqRel) {
                                    log::warn!("[spoton/unified] {} consecutive Browse failures — triggering session reconnect", fails);
                                    browse_reconnect_signal.notify_one();
                                }
                                return Ok(empty_response(StatusCode::NOT_FOUND));
                            }

                            // 89-09: the remaining signals. A 200 goes out only with audio in hand,
                            // with one exception that is kept as it was (the takeover abort).
                            let first_chunk = match first_signal {
                                BrowseFirstSignal::Verdict(status) => {
                                    // The Player ended the title without a single audio byte and
                                    // without calling it unavailable (EndOfTrack or Stopped before any
                                    // audio, a URI the core rejects, a closed event channel). No 2xx:
                                    // LMS would start the empty stream as a short track. Not a 404
                                    // either: nothing here gets better by asking again, LMS moves on.
                                    let answer = status_for_an_end_without_audio(status);
                                    log::info!(
                                        "[spoton/unified] track unavailable: the Player ended the title without audio (status {}) - answering {}",
                                        status.as_u16(), answer.as_u16()
                                    );
                                    cancel_abort.abort();
                                    {
                                        let mut mode = mode_state.lock().await;
                                        if matches!(*mode, ActiveMode::Browse(ref t) if *t == track_id) {
                                            *mode = ActiveMode::Idle;
                                        }
                                    }
                                    return Ok(empty_response(answer));
                                }
                                BrowseFirstSignal::NoAnswer => {
                                    // Neither audio nor a verdict within the bound: the request gives up
                                    // with the 404 the plugin retries (3 x 2 s, then skip). It says nothing
                                    // about the session, so the reconnect counter is neither raised nor
                                    // reset (Phase 88 Pitfall 4: a key back-off ends here, never in the
                                    // counted arm above). The load itself cannot be cancelled; the serve
                                    // task drops its Player off the async workers.
                                    log::warn!(
                                        "[spoton/unified] track unavailable: no audio and no verdict from the Player within {} s - 404, not counted toward reconnect, load abandoned",
                                        BROWSE_FIRST_SIGNAL_BOUND.as_secs()
                                    );
                                    give_up.notify_one();
                                    cancel_abort.abort();
                                    {
                                        let mut mode = mode_state.lock().await;
                                        if matches!(*mode, ActiveMode::Browse(ref t) if *t == track_id) {
                                            *mode = ActiveMode::Idle;
                                        }
                                    }
                                    return Ok(empty_response(StatusCode::NOT_FOUND));
                                }
                                BrowseFirstSignal::Aborted => {
                                    // The serve task was dropped before any audio and without a
                                    // verdict: the Connect takeover listener aborted it (H13). Answered
                                    // as before 89-09, 200 with a body that is already closed. An error
                                    // status here would make LMS ask for the next title, and that
                                    // request would preempt the Connect session that just took over
                                    // (D-10). The counter is not reset (WR-01).
                                    log::debug!("[spoton/unified] /track/{}: serve task dropped before any audio (takeover) - 200 with a closed body", track_id);
                                    None
                                }
                                BrowseFirstSignal::Audio(chunk) => {
                                    log::debug!(
                                        "[spoton/unified] /track/{}: first audio after {} ms - 200",
                                        track_id, waited_from.elapsed().as_millis()
                                    );
                                    // A title that sends audio is a live session.
                                    consecutive_browse_fails.store(0, Ordering::SeqCst);
                                    Some(chunk)
                                }
                            };
                            // Phase 36: update activity timestamp on successful Browse track
                            { *last_activity.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now(); }

                            // Build streaming response: the first chunk, then the rest of the channel.
                            let body = browse_audio_body(first_chunk, pcm_rx);

                            let content_type = if passthrough {
                                "audio/ogg"
                            } else {
                                "audio/L16;rate=44100;channels=2"
                            };
                            let resp = Response::builder()
                                .status(StatusCode::OK)
                                .header("Content-Type", content_type)
                                .body(body)
                                .expect("browse stream response builder");

                            return Ok(resp);
                        }

                        // ---- POST /control/* — Spirc commands ----
                        if method == Method::POST && path.starts_with("/control/") {
                            if !enable_connect {
                                return Ok(empty_response(StatusCode::NOT_FOUND));
                            }

                            let cmd = &path["/control/".len()..];

                            // T-29-02 (mitigate): reuse connect.rs control dispatch with full
                            // validation (volume clamped, seek validated as u32).
                            let body_bytes = {
                                use http_body_util::{BodyExt as _, Limited};
                                match Limited::new(req.into_body(), 4096).collect().await {
                                    Ok(collected) => collected.to_bytes(),
                                    Err(_) => Bytes::new(),
                                }
                            };

                            // D-03: /control/transfer pulls a moved session back. It has
                            // its own status mapping (transfer_status) and never goes
                            // through control_status: inactive is its precondition, so the
                            // 409-when-inactive rule must not apply (Pitfall 5, GH #223).
                            if cmd == "transfer" {
                                let status = dispatch_transfer(&spirc_handle, &transfer_state, recovery_shared.is_recovering());
                                let mut builder = Response::builder()
                                    .status(status)
                                    .header("Content-Length", "0");
                                if status == StatusCode::SERVICE_UNAVAILABLE {
                                    builder = builder.header("Retry-After", "2");
                                }
                                let body = Full::new(Bytes::new())
                                    .map_err(|e| match e {})
                                    .boxed();
                                return Ok(builder
                                    .body(body)
                                    .expect("transfer response builder"));
                            }

                            let spirc_guard = match spirc_handle.lock() {
                                Ok(g) => g,
                                Err(_) => return Ok(Response::builder()
                                    .status(StatusCode::SERVICE_UNAVAILABLE)
                                    .body(BoxBody::new(Full::new(Bytes::from("Spirc mutex poisoned")).map_err(|e| match e {})))
                                    .unwrap()),
                            };
                            // GH #207: while recovering nothing is dispatched (the old Spirc is
                            // being woken, the new one is not up): control_status answers 503.
                            let recovering = recovery_shared.is_recovering();
                            let result = if recovering {
                                None
                            } else if let Some(spirc) = spirc_guard.as_ref() {
                                match cmd {
                                    "pause" => spirc.pause().ok(),
                                    "play" => spirc.play().ok(),
                                    "next" => spirc.next().ok(),
                                    "prev" => spirc.prev().ok(),
                                    "volume" => {
                                        // T-29-02 (mitigate): parse volume as u64, clamp 0..=100,
                                        // convert to 0..=65535 range.
                                        if let Ok(json_val) = serde_json::from_slice::<serde_json::Value>(&body_bytes) {
                                            if let Some(vol) = json_val.get("volume").and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))) {
                                                let vol_clamped = vol.min(100) as u32;
                                                let vol_u16 = (vol_clamped * 65535 / 100) as u16;
                                                spirc.set_volume(vol_u16).ok()
                                            } else {
                                                None
                                            }
                                        } else {
                                            None
                                        }
                                    }
                                    "seek" => {
                                        // T-29-03 (mitigate): parse position_ms as u64, reject if >u32::MAX.
                                        if let Ok(json_val) = serde_json::from_slice::<serde_json::Value>(&body_bytes) {
                                            if let Some(pos) = json_val.get("position_ms").and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))) {
                                                if let Ok(pos_u32) = u32::try_from(pos) {
                                                    spirc.set_position_ms(pos_u32).ok()
                                                } else {
                                                    None
                                                }
                                            } else {
                                                None
                                            }
                                        } else {
                                            None
                                        }
                                    }
                                    _ => None,
                                }
                            } else {
                                None
                            };
                            drop(spirc_guard);

                            // GH #159: a transport command that Spirc drops because the
                            // device is not the active Connect target must NOT look like
                            // success to the Perl side. Note the fork's Spirc handle only
                            // returns Err when the command CHANNEL is closed — the
                            // "SpircCommand::X will be ignored while Not Active" drop
                            // happens asynchronously inside the Spirc task AFTER a
                            // successful send, so `result.is_some()` alone cannot detect
                            // it. The spirc_active flag (cleared on SessionDisconnected,
                            // which the fork emits from handle_disconnect() whenever the
                            // device stops being the active target) is the authoritative
                            // signal. The command is still dispatched above regardless:
                            // Spirc safely ignores it while Not Active, and if the flag
                            // is momentarily stale the dispatch keeps behavior identical
                            // to before.
                            let active = spirc_active.load(Ordering::Acquire);
                            let status = control_status(recovering, active, result.is_some(), cmd);
                            if status == StatusCode::CONFLICT {
                                log::warn!(
                                    "[spoton/unified] /control/{cmd}: 409 — device is not \
                                     the active Connect target (GH #159, spirc_active={}, \
                                     dispatched={})",
                                    active, result.is_some()
                                );
                            }

                            let body = Full::new(Bytes::new())
                                .map_err(|e| match e {})
                                .boxed();
                            let mut builder = Response::builder()
                                .status(status)
                                .header("Content-Length", "0");
                            if status == StatusCode::SERVICE_UNAVAILABLE {
                                builder = builder.header("Retry-After", "2");
                            }
                            let resp = builder
                                .body(body)
                                .expect("control response builder");
                            return Ok(resp);
                        }

                        // ---- 404 for everything else ----
                        Ok(empty_response(StatusCode::NOT_FOUND))
                    }
                });

                let io = TokioIo::new(stream);
                let conn = HyperHttp1::Builder::new().serve_connection(io, svc);
                let fut = graceful.watch(conn);
                tokio::spawn(async move {
                    let _ = fut.await;
                });
            }
            _ = &mut shutdown_rx => {
                break;
            }
        }
    }

    // Give in-progress Browse requests up to 5s to complete (D-11 graceful shutdown).
    // M18: BOUNDED — graceful.shutdown() waits for ALL watched connections, and an
    // active /stream connection is long-lived, so an unbounded await hangs forever.
    if tokio::time::timeout(Duration::from_secs(5), graceful.shutdown()).await.is_err() {
        log::warn!("[spoton/unified] graceful shutdown timed out after 5s — long-lived connections abandoned");
    }
}

// -------------------------------------------------------------------------
// run_unified — main orchestrator
// -------------------------------------------------------------------------

/// Run the unified Browse+Connect daemon.
///
/// Startup sequence:
///   1. Cache + Credentials
///   2. FNV-1a device_id (cache_dir + player_mac)
///   3. Session::new + session.connect() — IMMEDIATE (D-03)
///   4. Port binding + stream_port=N announcement (D-04, Pitfall 4)
///   5. Shared state initialisation (mode_state, spirc_active, spirc_handle, browse_cancel)
///   6. [if enable_connect] PassthroughMixer + Connect Player (UnifiedHttpStreamSink) + LMS + Spirc
///   7. Spirc event watcher — D-09 takeover + spirc_active updates
///   8. Spawn unified_http_server (combined routes)
///   9. Main event loop (Spirc task + ZeroConf reconnect + ctrl_c)
///  10. Graceful shutdown
// unused_assignments: variables declared before the if/else branch are assigned None in the
// else branch for definite-assignment safety; those assignments are intentionally unused because
// the else branch doesn't use those values (it only runs the HTTP server + ctrl_c wait).
#[allow(unused_assignments)]
pub async fn run_unified(
    cache_dir: &str,
    device_name: &str,
    player_mac: Option<&str>,
    lms_host_port: Option<&str>,
    lms_auth: Option<&str>,
    enable_connect: bool,
    disable_discovery: bool,
    buffer_latency_ms: u64,
    autoplay: Option<bool>,
    initial_volume: Option<u16>,
    passthrough: bool,
    bitrate_kbps: u32,
    enable_normalisation: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    // Issue #97: convert kbps to librespot Bitrate enum once, reuse everywhere.
    let bitrate_enum = match bitrate_kbps {
        96 => Bitrate::Bitrate96,
        160 => Bitrate::Bitrate160,
        _ => Bitrate::Bitrate320,
    };
    log::info!("[spoton/unified] Bitrate: {} kbps", bitrate_kbps);
    log::info!(
        "[spoton/unified] --buffer-latency-ms {} accepted but inert: the Connect sink \
         paces at 1x and no longer holds the first page after start() back",
        buffer_latency_ms
    );

    // 1. Cache + Credentials
    //    Third arg (audio_path = Some(cache_dir)) enables audio key cache (D-02).
    let cache = Cache::new(Some(cache_dir), None::<&str>, Some(cache_dir), None)?;
    let credentials = match cache.credentials() {
        Some(c) => c,
        None => {
            return Err(format!(
                "No cached credentials in '{}'. Run --authenticate or --discover-once first.",
                cache_dir
            ).into());
        }
    };

    // Phase 14 (Credential Isolation): reconnect cache WITHOUT credentials_location.
    // Spirc::new() always calls session.connect(creds, store_credentials=true), so
    // the only way to prevent credential overwrite on reconnect (ZeroConf from a
    // different user, Spirc death, Browse failure) is to strip credentials_location
    // from the cache. Audio key caching is preserved via audio_path.
    let reconnect_cache = Cache::new(None::<&str>, None::<&str>, Some(cache_dir), None)?;

    // 2. Device ID — FNV-1a hash of cache_dir + player_mac (same as connect.rs lines 878-885).
    //    Ensures per-player uniqueness even when sharing the same Spotify account.
    let device_id_shared = {
        let mut h: u64 = 14695981039346656037;
        for b in cache_dir.as_bytes() { h ^= *b as u64; h = h.wrapping_mul(1099511628211); }
        if let Some(mac) = player_mac {
            for b in mac.as_bytes() { h ^= *b as u64; h = h.wrapping_mul(1099511628211); }
        }
        format!("{:016x}", h)
    };
    log::info!("[spoton/unified] Device ID: {device_id_shared}");

    // 3. Session — connect when Browse-only; Spirc::new() connects when Connect enabled.
    //    Spirc::new() calls session.connect() internally; calling it here too causes
    //    "Session is not connected" because the second connect invalidates the first.
    let mut session_config = SessionConfig::default();
    session_config.device_id = device_id_shared.clone();
    if let Some(ap) = autoplay {
        session_config.autoplay = Some(ap);
    }
    let session = Session::new(session_config.clone(), Some(cache.clone()));
    if !enable_connect {
        session.connect(credentials.clone(), false).await?;
    }

    // Wrap session in Arc<Mutex> so Browse requests and the reconnect loop can swap it.
    let session_shared = Arc::new(tokio::sync::Mutex::new(session));

    // 4. Bind port, announce stream_port=N (D-04, Pitfall 4).
    //    "stream_port" — NOT "unified_port" — Perl Daemon code matches `stream_port=(\d+)`.
    let listener = TcpListener::bind("0.0.0.0:0").await?;
    let port = listener.local_addr()?.port();
    let port_announcement = format!("stream_port={}", port);
    println!("{}", port_announcement);
    // Explicit flush — stdout is pipe-buffered; without this Perl IO::Select times out.
    std::io::stdout().flush()?;
    // SPOTON_PORT_FILE: Windows services have broken stdout piping in Proc::Background.
    // When this env var is set, write the port to a file directly.
    if let Ok(port_file) = std::env::var("SPOTON_PORT_FILE") {
        if let Ok(mut f) = std::fs::File::create(&port_file) {
            let _ = writeln!(f, "{}", port_announcement);
        }
    }

    // 5. Shared state.
    let mode_state = Arc::new(tokio::sync::Mutex::new(ActiveMode::Idle));
    let spirc_active = Arc::new(AtomicBool::new(false));
    let spirc_handle: Arc<std::sync::Mutex<Option<Spirc>>> =
        Arc::new(std::sync::Mutex::new(None));
    // D-03: /control/transfer rate limit + one-shot play-after-takeover arm.
    let transfer_state = Arc::new(TransferState::default());
    // browse_cancel: fired by Spirc event watcher when Connect takes over Browse (D-09).
    let browse_cancel = Arc::new(tokio::sync::Notify::new());
    // browse_preempting: signals /stream relay to exit cleanly on D-10 Browse takeover (Pitfall 2).
    let browse_preempting = Arc::new(AtomicBool::new(false));
    // browse_abort_gen: monotonic counter for rapid-skip debounce (T-30-05).
    // Incremented on each /track/ request; in-flight tasks check if gen advanced.
    let browse_abort_gen = Arc::new(AtomicU64::new(0));
    // Session reconnect: Browse handler signals main loop when consecutive failures
    // indicate a dead Spotify session (audio key channel closed).
    let browse_reconnect_signal = Arc::new(tokio::sync::Notify::new());
    let browse_reconnect_pending = Arc::new(AtomicBool::new(false));
    let consecutive_browse_fails = Arc::new(AtomicU32::new(0));
    // Session health monitoring (Phase 36): track session creation time and last audio activity for /health endpoint
    let session_created_at: Arc<std::sync::Mutex<Instant>> = Arc::new(std::sync::Mutex::new(Instant::now()));
    let last_activity: Arc<std::sync::Mutex<Instant>> = Arc::new(std::sync::Mutex::new(Instant::now()));

    // 6. Conditional Connect infrastructure (D-01).

    // PCM + flush channels — only created when enable_connect (None in else branch).
    // The if/else branches below handle both cases.
    let pcm_rx_arc: Option<Arc<std::sync::Mutex<mpsc::Receiver<Bytes>>>>;
    let flush_rx_arc: Option<Arc<std::sync::Mutex<watch::Receiver<u64>>>>;
    // Phase 43 (D-03): OGG header buffer for /stream replay after drain (None when
    // enable_connect is false).
    let ogg_header_buf_arc: Option<Arc<std::sync::Mutex<Vec<Bytes>>>>;
    let ogg_header_serial_arc: Option<Arc<AtomicU32>>;
    let ogg_headers_complete_arc: Option<Arc<AtomicBool>>;
    let connect_overflow_arc: Option<Arc<AtomicBool>>;
    let connect_burst_arc: Option<Arc<BurstArm>>;

    // Reconnect infrastructure.
    let mixer_fn_opt: Option<librespot_playback::mixer::MixerFn>;
    let lms_for_reconnect: Option<LMS>;
    // Player::new returns Arc<Player>; Player does not implement Clone, but Arc<Player> does.
    let connect_player_opt: Option<Arc<Player>>;

    if enable_connect {
        // PCM channel (256 slots = ~1.5s of audio at 44100Hz S16LE stereo).
        let (pcm_tx, pcm_rx) = mpsc::channel::<Bytes>(256);
        let (flush_tx, flush_rx) = watch::channel::<u64>(0);
        let flush_tx_for_lms = flush_tx.clone();
        let connect_track_gen = Arc::new(AtomicU64::new(0));

        pcm_rx_arc = Some(Arc::new(std::sync::Mutex::new(pcm_rx)));
        flush_rx_arc = Some(Arc::new(std::sync::Mutex::new(flush_rx)));

        // Phase 43 (D-03): OGG header buffer — shared between the Connect sink (which
        // fills it during header collection) and the /stream handler (which replays
        // it after draining stale chunks on new connections).
        let ogg_header_buf: Arc<std::sync::Mutex<Vec<Bytes>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        let ogg_header_serial: Arc<AtomicU32> = Arc::new(AtomicU32::new(0));
        let ogg_headers_complete: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        // GH #202: sink -> relay overflow signal (see UnifiedHttpStreamSink::overflow).
        let connect_overflow: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        connect_overflow_arc = Some(Arc::clone(&connect_overflow));
        // Quick 261109-f4r (C): relay -> sink fresh-start signal for the burst credit.
        let connect_burst: Arc<BurstArm> = Arc::new(BurstArm::new());
        connect_burst_arc = Some(Arc::clone(&connect_burst));
        ogg_header_buf_arc = Some(Arc::clone(&ogg_header_buf));
        ogg_header_serial_arc = Some(Arc::clone(&ogg_header_serial));
        ogg_headers_complete_arc = Some(Arc::clone(&ogg_headers_complete));

        // PassthroughMixer (GH #144) — tracks Spirc volume state without
        // attenuating audio; LMS/squeezelite is the single attenuator.
        let mixer_fn: librespot_playback::mixer::MixerFn = passthrough_mixer;
        let mixer: Arc<dyn Mixer> = mixer_fn(MixerConfig::default())?;
        let soft_volume = mixer.get_soft_volume();

        // Connect Player with rate-limited UnifiedHttpStreamSink.
        let pcm_tx_clone = pcm_tx.clone();
        let flush_tx_for_sink = flush_tx.clone();
        let track_gen_for_sink = Arc::clone(&connect_track_gen);
        let buffer_latency_ms_copy = buffer_latency_ms;
        let ogg_buf_for_sink = Arc::clone(&ogg_header_buf);
        let ogg_serial_for_sink = Arc::clone(&ogg_header_serial);
        let ogg_complete_for_sink = Arc::clone(&ogg_headers_complete);
        let overflow_for_sink = Arc::clone(&connect_overflow);
        let burst_for_sink = Arc::clone(&connect_burst);
        let session_for_player = {
            let s = session_shared.lock().await;
            s.clone()
        };
        let connect_player = Player::new(
            PlayerConfig { passthrough, bitrate: bitrate_enum, normalisation: enable_normalisation, ..PlayerConfig::default() },
            session_for_player,
            soft_volume,
            move || {
                UnifiedHttpStreamSink::open(
                    None,
                    AudioFormat::S16,
                    pcm_tx_clone,
                    flush_tx_for_sink,
                    Arc::clone(&track_gen_for_sink),
                    buffer_latency_ms_copy,
                    ogg_buf_for_sink,
                    ogg_serial_for_sink,
                    ogg_complete_for_sink,
                    overflow_for_sink,
                    burst_for_sink,
                    passthrough,
                )
            },
        );

        // LMS event notifier — T-29-04: auth header sanitized in LMS::new().
        let lms = LMS::new(
            lms_host_port.map(String::from),
            player_mac.map(String::from),
            lms_auth.map(String::from),
            Some(flush_tx_for_lms),
        );
        let lms_reconnect = lms.clone();
        lms_for_reconnect = Some(lms_reconnect);

        // Clone LMS for event dispatcher respawn on reconnect (R-WR-07).
        // lms.clone() drops flush_tx (watch::Sender is not Clone), which is fine:
        // seek-flush signals go through UnifiedHttpStreamSink's own flush_tx,
        // and the Seeked event still sends "seek" via notify() (unaffected by flush_tx).
        let lms_for_dispatcher = lms.clone();

        // GH #128: clone for the /stream relay-start position resync. Shares
        // the position_anchor Arc with the dispatcher's LMS instance.
        let lms_for_relay = lms.clone();

        // GH #207 / D-07: recovery state shared by the dispatchers and the main loop.
        let recovery_shared = Arc::new(RecoveryShared::new(lms.is_configured()));

        // LMS event dispatcher + mode transition (combined to avoid race condition).
        // Previously two separate tasks raced on the mode mutex: the LMS dispatcher
        // could see Browse mode and drop a TrackChanged event before the mode-watcher
        // transitioned to Connect, losing the "start" notification to LMS.
        // R-WR-07: Track event dispatcher JoinHandle so we can abort+respawn on reconnect.
        let mut event_dispatcher_handle: Option<tokio::task::JoinHandle<()>>;

        if lms.is_configured() {
            let mut event_chan = connect_player.get_player_event_channel();
            let mode_state_lms = Arc::clone(&mode_state);
            let sa = Arc::clone(&spirc_active);
            let browse_cancel_lms = Arc::clone(&browse_cancel);
            let track_gen_lms = Arc::clone(&connect_track_gen);
            let transfer_lms = Arc::clone(&transfer_state);
            let spirc_handle_lms = Arc::clone(&spirc_handle);
            let rs_lms = Arc::clone(&recovery_shared);
            let session_lms = Arc::clone(&session_shared);
            event_dispatcher_handle = Some(tokio::spawn(async move {
                let mut current_track: Option<String> = None;
                let mut current_sink_track: Option<String> = None;
                loop {
                    // GH #207: the next player event, or a recovery outcome. A failed
                    // recovery hands the held (or rebuilt) SessionDisconnected back as
                    // `event` with `replayed` set, so it takes the SAME
                    // `lms.handle_player_event` call below as every other event.
                    let (event, replayed, _ack) = tokio::select! {
                        ev = event_chan.recv() => match ev {
                            Some(e) => (e, false, None::<AckOnDrop>),
                            None => break,
                        },
                        (outcome, ack) = rs_lms.next_outcome() => {
                            let ack = AckOnDrop(Some(ack));
                            match held_event_after_recovery(outcome, rs_lms.take_held(), &rs_lms.old_connection()) {
                                Some(e) => (e, true, Some(ack)),
                                None => continue,
                            }
                        }
                    };
                    advance_connect_track_generation(&event, &mut current_sink_track, &track_gen_lms);

                    // GH #207: is this event part of an AP-drop recovery?
                    let kind = event_kind(&event);
                    let session_invalid = !replayed
                        && matches!(kind, EventKind::SessionDisconnected | EventKind::Paused | EventKind::Stopped)
                        && !rs_lms.deliberate.load(Ordering::Acquire)
                        && session_lms.lock().await.is_invalid();
                    let suppressed = !replayed
                        && suppress_for_recovery(kind, rs_lms.is_recovering(), session_invalid);

                    // Track spirc_active for SessionConnected/Playing/TrackChanged
                    if matches!(event,
                        PlayerEvent::SessionConnected { .. } |
                        PlayerEvent::Playing { .. } |
                        PlayerEvent::TrackChanged { .. }
                    ) {
                        sa.store(true, Ordering::SeqCst);
                        rs_lms.active_snapshot.store(true, Ordering::SeqCst);
                    }

                    // GH #159: the Spirc fork emits SessionDisconnected from
                    // handle_disconnect() whenever the device stops being the
                    // active Connect target (cluster update picked another
                    // device, explicit Disconnect, Spirc shutdown). Clear the
                    // flag so /control rejects transport commands with 409
                    // instead of reporting success while Spirc drops them.
                    if matches!(event, PlayerEvent::SessionDisconnected { .. }) {
                        sa.store(false, Ordering::SeqCst);
                        // A suppressed end (invalid session) keeps the snapshot: the
                        // recovery still has to know the device was active.
                        if !suppressed {
                            rs_lms.active_snapshot.store(false, Ordering::SeqCst);
                        }
                    }

                    // GH #207 / D-08: the session end and the pause it causes stay away
                    // from LMS while the helper rebuilds the session.
                    if suppressed {
                        rs_lms.hold(&event);
                        continue;
                    }

                    // D-03 / GH #223: a takeover this helper itself requested via
                    // /control/transfer loads paused when the restored remote state
                    // was paused. One-shot arm: play once; an app selection, a
                    // recovery takeover or an expired arm never plays (D-09).
                    if matches!(event, PlayerEvent::SessionConnected { .. }) {
                        let armed = transfer_lms.take_play_arm();
                        if play_after_takeover(armed, Instant::now()) {
                            let guard = spirc_handle_lms.lock().unwrap_or_else(|e| e.into_inner());
                            if let Some(spirc) = guard.as_ref() {
                                let _ = spirc.play();
                                log::info!("[spoton/unified] /control/transfer: play after takeover");
                            }
                        }
                    }

                    let mut mode = mode_state_lms.lock().await;

                    // D-09: Connect takes over from Browse — transition mode first,
                    // then forward the event to LMS in a single atomic step.
                    if matches!(*mode, ActiveMode::Browse(_))
                        && matches!(event, PlayerEvent::TrackChanged { .. } | PlayerEvent::Playing { .. })
                    {
                        browse_cancel_lms.notify_waiters();
                        log::info!("[spoton/unified] Connect taking over -- Browse cancelled");
                        *mode = ActiveMode::Connect;
                    } else if *mode == ActiveMode::Idle
                        && matches!(event, PlayerEvent::TrackChanged { .. } | PlayerEvent::Playing { .. })
                    {
                        *mode = ActiveMode::Connect;
                    }

                    // Suppress non-Connect events while Browse is active (e.g. Spirc
                    // shutdown/paused events that would confuse LMS during Browse playback).
                    if matches!(*mode, ActiveMode::Browse(_)) {
                        continue;
                    }
                    drop(mode);

                    // GH #207 / D-09: the takeover's own paused load after a Recovered
                    // outcome is not the user's pause; the first Playing ends the window.
                    if !replayed && suppress_after_recovery(kind, rs_lms.settle_until(), Instant::now()) {
                        continue;
                    }
                    // GH #207 / 88-08 V4: the takeover's re-announce of the title the
                    // session was on is not a track change (relinked id vs Spirc id).
                    if !replayed
                        && suppress_takeover_announce(
                            kind,
                            rs_lms.is_recovering(),
                            rs_lms.settle_until(),
                            Instant::now(),
                            current_track.is_some(),
                        )
                    {
                        log::info!(
                            "[spoton/unified] takeover TrackChanged held back from LMS (same session, cursor {:?})",
                            current_track.as_deref()
                        );
                        continue;
                    }
                    if kind == EventKind::Playing {
                        rs_lms.end_settle();
                    }

                    lms.handle_player_event(&event, &mut current_track).await;
                    rs_lms.set_cursor(&current_track);
                }
            }));
        } else {
            // No LMS configured — still need spirc_active tracking for mode transitions.
            let mut event_chan = connect_player.get_player_event_channel();
            let sa = Arc::clone(&spirc_active);
            let mode_state_w = Arc::clone(&mode_state);
            let browse_cancel_w = Arc::clone(&browse_cancel);
            let track_gen_w = Arc::clone(&connect_track_gen);
            event_dispatcher_handle = Some(tokio::spawn(async move {
                let mut current_sink_track: Option<String> = None;
                while let Some(event) = event_chan.recv().await {
                    advance_connect_track_generation(&event, &mut current_sink_track, &track_gen_w);

                    // GH #159: mirror the LMS-configured dispatcher — clear
                    // spirc_active when the device stops being the active
                    // Connect target so /control can answer 409.
                    if matches!(event, PlayerEvent::SessionDisconnected { .. }) {
                        sa.store(false, Ordering::SeqCst);
                    }

                    if matches!(event,
                        PlayerEvent::SessionConnected { .. } |
                        PlayerEvent::Playing { .. } |
                        PlayerEvent::TrackChanged { .. }
                    ) {
                        sa.store(true, Ordering::SeqCst);

                        if matches!(event, PlayerEvent::TrackChanged { .. } | PlayerEvent::Playing { .. }) {
                            let mut mode = mode_state_w.lock().await;
                            if matches!(*mode, ActiveMode::Browse(_)) {
                                browse_cancel_w.notify_waiters();
                                log::info!("[spoton/unified] Connect taking over -- Browse cancelled");
                                *mode = ActiveMode::Connect;
                            } else if *mode == ActiveMode::Idle {
                                *mode = ActiveMode::Connect;
                            }
                        }
                    }
                }
            }));
        }

        // ConnectConfig + Spirc::new().
        let connect_config = ConnectConfig {
            name: device_name.to_string(),
            device_type: DeviceType::Speaker,
            initial_volume: initial_volume.unwrap_or(u16::MAX / 2),
            disable_volume: false,
            ..ConnectConfig::default()
        };

        let session_for_spirc = {
            let s = session_shared.lock().await;
            s.clone()
        };
        let (spirc, spirc_task) = Spirc::new(
            connect_config,
            session_for_spirc,
            credentials.clone(),
            connect_player.clone(),
            mixer,
        )
        .await?;

        {
            let mut guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
            *guard = Some(spirc);
        }

        mixer_fn_opt = Some(mixer_fn);
        connect_player_opt = Some(connect_player);

        // ZeroConf Discovery for reconnect (conditional on --disable-discovery).
        let discovery = if disable_discovery {
            None
        } else {
            // DISCOVERY_CLIENT_ID — standard librespot client ID used for mDNS
            // Discovery identity (not a Web API OAuth client — this is librespot-core's
            // built-in ZeroConf/Spotify-Connect discovery identity).
            const DISCOVERY_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
            let route_addr = match lms_host_port {
                Some(hp) => {
                    let host = hp.rsplit_once(':').map(|(h, _)| h).unwrap_or(hp);
                    if host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" || host == "localhost" {
                        "1.1.1.1:80".to_string()
                    } else if hp.contains(':') {
                        hp.to_string()
                    } else {
                        format!("{}:80", hp)
                    }
                }
                None => "1.1.1.1:80".to_string(),
            };
            let zeroconf_ip = match std::net::UdpSocket::bind("0.0.0.0:0")
                .and_then(|s| { s.connect(&route_addr)?; s.local_addr() })
            {
                Ok(addr) => vec![addr.ip()],
                Err(_) => vec![],
            };
            match librespot_discovery::Discovery::builder(device_id_shared.clone(), DISCOVERY_CLIENT_ID.to_string())
                .name(device_name.to_string())
                .device_type(DeviceType::Speaker)
                .zeroconf_ip(zeroconf_ip)
                .launch()
            {
                Ok(d) => Some(d),
                Err(_) => None,
            }
        };

        // Spawn unified HTTP server.
        let (http_shutdown_tx, http_shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let http_handle = tokio::spawn(unified_http_server(
            listener,
            Arc::clone(&session_shared),
            Arc::clone(&spirc_active),
            Arc::clone(&spirc_handle),
            Arc::clone(&mode_state),
            Arc::clone(&browse_cancel),
            enable_connect,
            pcm_rx_arc,
            flush_rx_arc,
            http_shutdown_rx,
            Arc::clone(&browse_preempting),
            Arc::clone(&browse_abort_gen),
            Arc::clone(&browse_reconnect_signal),
            Arc::clone(&browse_reconnect_pending),
            Arc::clone(&consecutive_browse_fails),
            Arc::clone(&session_created_at),
            Arc::clone(&last_activity),
            passthrough,
            ogg_header_buf_arc,
            ogg_header_serial_arc,
            ogg_headers_complete_arc,
            connect_overflow_arc,
            connect_burst_arc,
            bitrate_enum,
            enable_normalisation,
            Some(lms_for_relay), // GH #128: relay-start position resync
            Arc::clone(&transfer_state),
            Arc::clone(&recovery_shared),
        ));

        // Main event loop — Spirc reconnect, ZeroConf, ctrl_c.
        let mut reconnect_times: Vec<std::time::Instant> = Vec::new();
        let mut last_credentials: Option<Credentials> = Some(credentials);
        let mut connecting = false;
        let mut current_spirc_task: Option<tokio::task::JoinHandle<()>> =
            Some(tokio::spawn(spirc_task));
        let mut current_discovery = discovery;

        // GH #207 / D-07: AP-drop recovery inside the helper.
        // The intent of the running recovery (None outside one).
        let mut recovery_intent: Option<RecoveryIntent> = None;
        // Ack receiver of the last recovery outcome; the graceful shutdown waits for
        // it so a replayed `stop inactive` is delivered before the dispatcher is aborted.
        let mut pending_outcome_ack: Option<tokio::sync::oneshot::Receiver<()>> = None;
        // Fable decision 1 item 1: 1 s poll of the shared session's `is_invalid()`.
        let mut loss_tick = tokio::time::interval(Duration::from_secs(1));
        loss_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            tokio::select! {
                // GH #207: a lost AP session is noticed within about 1 s. The Spirc task
                // itself only tests `is_invalid()` at the top of its loop and would sleep
                // until the next preload event (30 s before the track end).
                _ = loss_tick.tick() => {
                    let session_cur = {
                        let s = session_shared.lock().await;
                        s.clone()
                    };
                    let recovering_now = recovery_shared.is_recovering();
                    if loss_poll_fires(connecting, recovering_now, session_cur.is_invalid()) {
                        let intent = begin_recovery(
                            &recovery_shared,
                            &session_cur,
                            &spirc_active,
                            &mode_state,
                            &lms_for_dispatcher,
                            &transfer_state,
                        ).await;
                        let was_playing = intent.was_playing;
                        recovery_intent = Some(intent);
                        // Wake the Spirc with ONE command: pause() when it was playing (exact
                        // position, a silent gap instead of a replay), else shutdown(). After
                        // it the Spirc loop sees is_invalid() and leaves via handle_disconnect.
                        let woke = {
                            let guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
                            match guard.as_ref() {
                                Some(sp) => (if was_playing { sp.pause() } else { sp.shutdown() }).is_ok(),
                                None => false,
                            }
                        };
                        if !woke {
                            // No Spirc to wake: rebuild directly. The intent above has
                            // read the activity flag; the re-acquire must not (WR-02).
                            mark_inactive_for_rebuild(&spirc_active);
                            reconnect_times.push(std::time::Instant::now());
                            connecting = true;
                        }
                    } else if let Some(ref i) = recovery_intent {
                        if recovery_wake_stuck(recovering_now, connecting, i.at.elapsed()) {
                            log::warn!("[spoton/unified] recovery: Spirc did not leave after the wake-up, forcing the rebuild");
                            if let Some(ref task) = current_spirc_task {
                                task.abort();
                            }
                            current_spirc_task = None;
                            {
                                let mut guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
                                *guard = None;
                            }
                            // The aborted Spirc never emitted its SessionDisconnected (WR-02).
                            mark_inactive_for_rebuild(&spirc_active);
                            reconnect_times.push(std::time::Instant::now());
                            connecting = true;
                        }
                    }
                },

                // ZeroConf new credentials (Pitfall 6: reconnect path).
                new_creds = async {
                    match current_discovery.as_mut() {
                        Some(d) => futures_util::StreamExt::next(d).await,
                        None => None,
                    }
                }, if current_discovery.is_some() => {
                    if let Some(creds) = new_creds {
                        last_credentials = Some(creds);
                        {
                            let mut guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
                            if let Some(ref s) = *guard {
                                let _ = s.shutdown();
                            }
                            *guard = None;
                        }
                        recovery_shared.clear_active(&spirc_active);
                        let session_cur = {
                            let s = session_shared.lock().await;
                            s.clone()
                        };
                        recovery_shared.deliberate.store(true, Ordering::Release);
                        if !session_cur.is_invalid() {
                            session_cur.shutdown();
                        }
                        connecting = true;
                    }
                },

                // Reconnect with new credentials (Pitfall 6: session update for Browse too).
                // GH #207: also the rebuild of an AP-drop recovery (`recovery_intent`).
                _ = async {}, if connecting && last_credentials.is_some() => {
                    let recovery = recovery_intent.clone();
                    let session_cur = {
                        let s = session_shared.lock().await;
                        s.clone()
                    };
                    let new_session = if session_cur.is_invalid() {
                        let ns = Session::new(session_config.clone(), Some(reconnect_cache.clone()));
                        // GH #207 / D-08 (Fable decision 1 item 3): the rebuilt session carries
                        // the old session id, so Spotify's transfer data matches and Spirc
                        // takes over by itself. ONLY when the device was active: otherwise it
                        // could adopt a foreign playing state (D-09, T-88-09).
                        if let Some(ref i) = recovery {
                            if i.was_active {
                                ns.set_session_id(&i.session_id);
                                log::debug!("[spoton/unified] recovery: session id carried over");
                            }
                        }
                        // Update the shared Session reference so Browse requests use new session.
                        {
                            let mut s = session_shared.lock().await;
                            *s = ns.clone();
                        }
                        if let Some(ref cp) = connect_player_opt {
                            cp.set_session(ns.clone());
                        }
                        ns
                    } else {
                        session_cur
                    };

                    if let Some(ref mf) = mixer_fn_opt {
                        // GH #207 / Fable decision 1 item 6: on the recovery path a failed
                        // Spirc::new is retried after 1/2/4 s with a NEW Session each time
                        // (the 1 s / 2 s / 4 s pattern of the Browse-only reconnect) instead
                        // of the immediate break; when the schedule is exhausted the helper
                        // exits as before and the Perl backoff (GH #147) takes over. Every
                        // retry is bounded by the shared RECONNECT_RATE_LIMIT, which counted
                        // this recovery once when its Spirc task ended.
                        let mut session_try = new_session;
                        let mut attempt = 0usize;
                        let spirc_result = loop {
                            let try_config = ConnectConfig {
                                name: device_name.to_string(),
                                device_type: DeviceType::Speaker,
                                initial_volume: initial_volume.unwrap_or(u16::MAX / 2),
                                disable_volume: false,
                                ..ConnectConfig::default()
                            };
                            // 88 review WR-03: bounded on the recovery path, so a rebuild
                            // that never returns cannot hold `recovering` (and this arm).
                            let limit = rebuild_limit(recovery.is_some());
                            let attempt_started = Instant::now();
                            match bounded_rebuild(
                                Spirc::new(
                                    try_config,
                                    session_try.clone(),
                                    last_credentials.clone().unwrap(),
                                    connect_player_opt.clone().unwrap(),
                                    mf(MixerConfig::default()).unwrap_or_else(|_| panic!("mixer")),
                                ),
                                limit,
                            ).await {
                                Ok(pair) => break Ok(pair),
                                Err(e) => match (recovery.as_ref(), recovery_retry_delay(attempt)) {
                                    (Some(i), Some(delay)) => {
                                        log::warn!(
                                            "[spoton/unified] recovery: Spirc::new failed ({e}), retry {}/3 in {} s",
                                            attempt + 1,
                                            delay.as_secs()
                                        );
                                        // An attempt dropped at the limit may have left its
                                        // Session connected: invalidate it before the next one.
                                        if limit.map(|l| attempt_started.elapsed() >= l).unwrap_or(false)
                                            && !session_try.is_invalid()
                                        {
                                            session_try.shutdown();
                                        }
                                        tokio::time::sleep(delay).await;
                                        attempt += 1;
                                        let retry = Session::new(session_config.clone(), Some(reconnect_cache.clone()));
                                        if i.was_active {
                                            retry.set_session_id(&i.session_id);
                                        }
                                        {
                                            let mut s = session_shared.lock().await;
                                            *s = retry.clone();
                                        }
                                        if let Some(ref cp) = connect_player_opt {
                                            cp.set_session(retry.clone());
                                        }
                                        session_try = retry;
                                    }
                                    _ => break Err(e),
                                },
                            }
                        };
                        match spirc_result {
                            Ok((new_spirc, new_task)) => {
                                {
                                    let mut guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
                                    *guard = Some(new_spirc);
                                }
                                current_spirc_task = Some(tokio::spawn(new_task));
                                connecting = false;

                                // R-WR-07: respawn the event dispatcher with a fresh player event
                                // channel; the old one may have exited when the Player's internal
                                // sender closed during Spirc shutdown. GH #207 / Fable decision 1
                                // item 5: on the recovery path the RUNNING dispatcher is kept (it
                                // holds `current_track`; aborting it would turn the takeover's
                                // TrackChanged into a `start`) and respawned, seeded with the
                                // cursor, only when it has finished.
                                let dispatcher_finished = event_dispatcher_handle
                                    .as_ref()
                                    .map(|h| h.is_finished())
                                    .unwrap_or(true);
                                let respawn = recovery.is_none() || dispatcher_finished;
                                let dispatcher_seed = recovery
                                    .as_ref()
                                    .and_then(|i| recovery_shared.cursor().or_else(|| i.track_id.clone()));
                                if respawn {
                                    if let Some(ref h) = event_dispatcher_handle {
                                        h.abort();
                                    }
                                    // R-WR-07: Abort old event dispatcher and respawn with fresh
                                    // player event channel. The old dispatcher's recv loop may have
                                    // exited when the Player's internal sender closed during Spirc
                                    // shutdown, so we must create a new one.
                                    let mut event_chan = connect_player_opt.as_ref().unwrap().get_player_event_channel();
                                    if lms_for_dispatcher.is_configured() {
                                        let lms_d = lms_for_dispatcher.clone();
                                        let mode_state_d = Arc::clone(&mode_state);
                                        let sa_d = Arc::clone(&spirc_active);
                                        let browse_cancel_d = Arc::clone(&browse_cancel);
                                        let track_gen_d = Arc::clone(&connect_track_gen);
                                        let transfer_d = Arc::clone(&transfer_state);
                                        let spirc_handle_d = Arc::clone(&spirc_handle);
                                        let rs_d = Arc::clone(&recovery_shared);
                                        let session_d = Arc::clone(&session_shared);
                                        let seed_track = dispatcher_seed.clone();
                                        event_dispatcher_handle = Some(tokio::spawn(async move {
                                            // GH #207: a dispatcher respawned on the recovery path
                                            // starts from the cursor of the one it replaces.
                                            let mut current_track: Option<String> = seed_track;
                                            let mut current_sink_track: Option<String> = None;
                                            loop {
                                                // Same outcome/replay handling as the initial dispatcher.
                                                let (event, replayed, _ack) = tokio::select! {
                                                    ev = event_chan.recv() => match ev {
                                                        Some(e) => (e, false, None::<AckOnDrop>),
                                                        None => break,
                                                    },
                                                    (outcome, ack) = rs_d.next_outcome() => {
                                                        let ack = AckOnDrop(Some(ack));
                                                        match held_event_after_recovery(outcome, rs_d.take_held(), &rs_d.old_connection()) {
                                                            Some(e) => (e, true, Some(ack)),
                                                            None => continue,
                                                        }
                                                    }
                                                };
                                                advance_connect_track_generation(&event, &mut current_sink_track, &track_gen_d);

                                                let kind = event_kind(&event);
                                                let session_invalid = !replayed
                                                    && matches!(kind, EventKind::SessionDisconnected | EventKind::Paused | EventKind::Stopped)
                                                    && !rs_d.deliberate.load(Ordering::Acquire)
                                                && session_d.lock().await.is_invalid();
                                                let suppressed = !replayed
                                                    && suppress_for_recovery(kind, rs_d.is_recovering(), session_invalid);

                                                if matches!(event,
                                                    PlayerEvent::SessionConnected { .. } |
                                                    PlayerEvent::Playing { .. } |
                                                    PlayerEvent::TrackChanged { .. }
                                                ) {
                                                    sa_d.store(true, Ordering::SeqCst);
                                                    rs_d.active_snapshot.store(true, Ordering::SeqCst);
                                                }
                                                // GH #159: device no longer the active Connect target.
                                                if matches!(event, PlayerEvent::SessionDisconnected { .. }) {
                                                    sa_d.store(false, Ordering::SeqCst);
                                                    if !suppressed {
                                                        rs_d.active_snapshot.store(false, Ordering::SeqCst);
                                                    }
                                                }
                                                // GH #207 / D-08: hold the session end during a recovery.
                                                if suppressed {
                                                    rs_d.hold(&event);
                                                    continue;
                                                }
                                                // D-03 / GH #223: same one-shot play arm as the
                                                // initial dispatcher (respawn copy).
                                                if matches!(event, PlayerEvent::SessionConnected { .. }) {
                                                    let armed = transfer_d.take_play_arm();
                                                    if play_after_takeover(armed, Instant::now()) {
                                                        let guard = spirc_handle_d.lock().unwrap_or_else(|e| e.into_inner());
                                                        if let Some(spirc) = guard.as_ref() {
                                                            let _ = spirc.play();
                                                            log::info!("[spoton/unified] /control/transfer: play after takeover");
                                                        }
                                                    }
                                                }
                                                let mut mode = mode_state_d.lock().await;
                                                if matches!(*mode, ActiveMode::Browse(_))
                                                    && matches!(event, PlayerEvent::TrackChanged { .. } | PlayerEvent::Playing { .. })
                                                {
                                                    browse_cancel_d.notify_waiters();
                                                    log::info!("[spoton/unified] Connect taking over -- Browse cancelled");
                                                    *mode = ActiveMode::Connect;
                                                } else if *mode == ActiveMode::Idle
                                                    && matches!(event, PlayerEvent::TrackChanged { .. } | PlayerEvent::Playing { .. })
                                                {
                                                    *mode = ActiveMode::Connect;
                                                }
                                                if matches!(*mode, ActiveMode::Browse(_)) {
                                                    continue;
                                                }
                                                drop(mode);
                                                // GH #207 / D-09: settle window after a Recovered outcome.
                                                if !replayed && suppress_after_recovery(kind, rs_d.settle_until(), Instant::now()) {
                                                    continue;
                                                }
                                                // GH #207 / 88-08 V4: same hold as the initial dispatcher.
                                                if !replayed
                                                    && suppress_takeover_announce(
                                                        kind,
                                                        rs_d.is_recovering(),
                                                        rs_d.settle_until(),
                                                        Instant::now(),
                                                        current_track.is_some(),
                                                    )
                                                {
                                                    log::info!(
                                                        "[spoton/unified] takeover TrackChanged held back from LMS (same session, cursor {:?})",
                                                        current_track.as_deref()
                                                    );
                                                    continue;
                                                }
                                                if kind == EventKind::Playing {
                                                    rs_d.end_settle();
                                                }
                                                lms_d.handle_player_event(&event, &mut current_track).await;
                                                rs_d.set_cursor(&current_track);
                                            }
                                        }));
                                    } else {
                                        let sa_d = Arc::clone(&spirc_active);
                                        let mode_state_d = Arc::clone(&mode_state);
                                        let browse_cancel_d = Arc::clone(&browse_cancel);
                                        let track_gen_d = Arc::clone(&connect_track_gen);
                                        event_dispatcher_handle = Some(tokio::spawn(async move {
                                            let mut current_sink_track: Option<String> = None;
                                            while let Some(event) = event_chan.recv().await {
                                                advance_connect_track_generation(&event, &mut current_sink_track, &track_gen_d);

                                                // GH #159: device no longer the active Connect target.
                                                if matches!(event, PlayerEvent::SessionDisconnected { .. }) {
                                                    sa_d.store(false, Ordering::SeqCst);
                                                }

                                                if matches!(event,
                                                    PlayerEvent::SessionConnected { .. } |
                                                    PlayerEvent::Playing { .. } |
                                                    PlayerEvent::TrackChanged { .. }
                                                ) {
                                                    sa_d.store(true, Ordering::SeqCst);
                                                    if matches!(event, PlayerEvent::TrackChanged { .. } | PlayerEvent::Playing { .. }) {
                                                        let mut mode = mode_state_d.lock().await;
                                                        if matches!(*mode, ActiveMode::Browse(_)) {
                                                            browse_cancel_d.notify_waiters();
                                                            log::info!("[spoton/unified] Connect taking over -- Browse cancelled");
                                                            *mode = ActiveMode::Connect;
                                                        } else if *mode == ActiveMode::Idle {
                                                            *mode = ActiveMode::Connect;
                                                        }
                                                    }
                                                }
                                            }
                                        }));
                                    }
                                    log::info!("[spoton/unified] Event dispatcher respawned after reconnect");
                                }

                                // Send "ready" to LMS so Connect.pm re-issues playlist play
                                // after a ZeroConf credential rotation + Spirc reconnect.
                                // Skip while Browse is active — the reconnect is just restoring
                                // Spirc visibility in the Spotify app, not taking over playback.
                                // GH #207 / Fable decision 1 item 5: never on the recovery path
                                // (it would make Connect.pm re-issue `playlist play`).
                                let is_browsing = matches!(*mode_state.lock().await, ActiveMode::Browse(_));
                                if recovery.is_none() && !is_browsing {
                                    if let Some(ref lms) = lms_for_reconnect {
                                        lms.notify("ready", "", "", "").await;
                                    }
                                }
                                log::debug!("[spoton/unified] Spirc reconnected");
                                { *session_created_at.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now(); }
                                browse_reconnect_pending.store(false, Ordering::Release);

                                // A deliberate reconnect is over: its SessionDisconnected was
                                // forwarded long ago; whatever is still held is stale.
                                recovery_shared.deliberate.store(false, Ordering::Release);
                                if recovery.is_none() {
                                    let _ = recovery_shared.take_held();
                                }

                                // GH #207 / D-08: re-acquire the device and end the recovery.
                                if let Some(intent) = recovery {
                                    let r = reacquire_after_rebuild(&intent, &spirc_handle, &spirc_active).await;
                                    match r.outcome {
                                        RecoveryOutcome::Recovered => log::info!(
                                            "[spoton/unified] recovered in {} ms (playing={})",
                                            intent.at.elapsed().as_millis(),
                                            r.playing as u8
                                        ),
                                        _ => log::info!("[spoton/unified] recovery failed: {}", r.reason),
                                    }
                                    pending_outcome_ack = Some(recovery_shared.finish(r.outcome));
                                    recovery_intent = None;
                                }
                            }
                            Err(e) => {
                                browse_reconnect_pending.store(false, Ordering::Release);
                                log::error!("[spoton/unified] Spirc reconnect failed: {e}");
                                if recovery.is_some() {
                                    log::info!("[spoton/unified] recovery failed: Spirc::new: {e}");
                                    pending_outcome_ack = Some(recovery_shared.finish(RecoveryOutcome::Failed));
                                    recovery_intent = None;
                                }
                                break;
                            }
                        }
                    }
                },

                // Browse-triggered session reconnect: consecutive Browse failures
                // indicate the Spotify TCP connection is dead. Tear down Spirc + session,
                // then let the existing reconnect logic (connecting=true) rebuild everything.
                _ = browse_reconnect_signal.notified(), if !connecting => {
                    log::warn!("[spoton/unified] Browse-triggered session reconnect");
                    consecutive_browse_fails.store(0, Ordering::SeqCst);

                    // Shut down Spirc (if alive).
                    {
                        let mut guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
                        if let Some(ref s) = *guard {
                            let _ = s.shutdown();
                        }
                        *guard = None;
                    }
                    recovery_shared.clear_active(&spirc_active);

                    // Abort the old Spirc task so "Spirc task died" doesn't also fire.
                    if let Some(ref task) = current_spirc_task {
                        task.abort();
                    }
                    current_spirc_task = None;

                    // Shut down session to force is_invalid() → true for reconnect path.
                    let session_cur = {
                        let s = session_shared.lock().await;
                        s.clone()
                    };
                    recovery_shared.deliberate.store(true, Ordering::Release);
                    if !session_cur.is_invalid() {
                        session_cur.shutdown();
                    }

                    connecting = true;
                },

                // Spirc task died — attempt reconnect with backoff.
                result = async {
                    if let Some(task) = current_spirc_task.as_mut() {
                        task.await
                    } else {
                        std::future::pending().await
                    }
                }, if current_spirc_task.is_some() && !connecting => {
                    current_spirc_task = None;
                    // GH #207: the Spirc task noticed the loss before the poll did. Build the
                    // intent BEFORE spirc_active is cleared below (was_active reads it).
                    {
                        let session_now = {
                            let s = session_shared.lock().await;
                            s.clone()
                        };
                        if loss_poll_fires(false, recovery_shared.is_recovering(), session_now.is_invalid()) {
                            recovery_intent = Some(begin_recovery(
                                &recovery_shared,
                                &session_now,
                                &spirc_active,
                                &mode_state,
                                &lms_for_dispatcher,
                                &transfer_state,
                            ).await);
                        }
                    }
                    // 88 review WR-06: flag and snapshot (the intent above has read both).
                    recovery_shared.clear_active(&spirc_active);
                    let _ = result;

                    const RECONNECT_RATE_LIMIT: usize = 5;
                    let rate_window = Duration::from_secs(60);
                    reconnect_times.retain(|&t: &std::time::Instant| t.elapsed() < rate_window);
                    if last_credentials.is_some() && reconnect_times.len() < RECONNECT_RATE_LIMIT {
                        reconnect_times.push(std::time::Instant::now());
                        let session_cur = {
                            let s = session_shared.lock().await;
                            s.clone()
                        };
                        // 88 review WR-06: the third deliberate session shutdown.
                        end_valid_session_on_purpose(&recovery_shared, &session_cur);
                        connecting = true;
                    } else {
                        eprintln!("Spirc shut down too often. Not reconnecting.");
                        // GH #207: a recovery that hits the shared 5-per-60 s limit ends like an
                        // ordinary session end; the exit below hands over to the Perl backoff.
                        if recovery_intent.take().is_some() {
                            log::info!("[spoton/unified] recovery failed: reconnect rate limit");
                            pending_outcome_ack = Some(recovery_shared.finish(RecoveryOutcome::Failed));
                        }
                        break;
                    }
                },

                // Player died unexpectedly.
                _ = async {}, if connect_player_opt.as_ref().map(|p| p.is_invalid()).unwrap_or(false) => {
                    eprintln!("Connect player shut down unexpectedly");
                    break;
                },

                // Ctrl+C / SIGINT.
                _ = tokio::signal::ctrl_c() => {
                    break;
                },

                else => break,
            }
        }

        // Graceful shutdown.
        // GH #207: a failed recovery handed the replayed SessionDisconnected to the
        // dispatcher; the replay is a TCP round trip (notify bound 5 s). Wait for its
        // ack, bounded, BEFORE the dispatcher is aborted below, so `stop inactive` is
        // delivered (or the bound elapsed) before the process ends. Every exit path of
        // the main loop reaches this block. No pending outcome: no wait.
        if let Some(ack_rx) = pending_outcome_ack.take() {
            let waited_from = Instant::now();
            if await_outcome_ack(ack_rx, OUTCOME_ACK_TIMEOUT).await == AckResult::TimedOut {
                log::warn!(
                    "[spoton/unified] recovery outcome not acknowledged within {} ms",
                    waited_from.elapsed().as_millis()
                );
            }
        }
        // R-WR-07: abort event dispatcher on shutdown to prevent orphaned tasks.
        if let Some(ref h) = event_dispatcher_handle {
            h.abort();
        }
        event_dispatcher_handle = None;
        {
            let mut guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(ref s) = *guard {
                let _ = s.shutdown();
            }
            *guard = None;
        }
        spirc_active.store(false, Ordering::SeqCst);
        let _ = http_shutdown_tx.send(());
        let _ = http_handle.await;

    } else {
        // Pure Browse mode — no Connect infrastructure, no Spirc.
        // Session is live for Browse requests. Daemon runs until killed.
        pcm_rx_arc = None;
        flush_rx_arc = None;
        ogg_header_buf_arc = None;
        ogg_header_serial_arc = None;
        ogg_headers_complete_arc = None;
        connect_overflow_arc = None;
        connect_burst_arc = None;
        mixer_fn_opt = None;
        lms_for_reconnect = None;
        connect_player_opt = None;

        let (http_shutdown_tx, http_shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let http_handle = tokio::spawn(unified_http_server(
            listener,
            Arc::clone(&session_shared),
            Arc::clone(&spirc_active),
            Arc::clone(&spirc_handle),
            Arc::clone(&mode_state),
            Arc::clone(&browse_cancel),
            false, // enable_connect
            None,  // pcm_rx
            None,  // flush_rx
            http_shutdown_rx,
            Arc::clone(&browse_preempting),
            Arc::clone(&browse_abort_gen),
            Arc::clone(&browse_reconnect_signal),
            Arc::clone(&browse_reconnect_pending),
            Arc::clone(&consecutive_browse_fails),
            Arc::clone(&session_created_at),
            Arc::clone(&last_activity),
            passthrough,
            None,  // ogg_header_buf
            None,  // ogg_header_serial
            None,  // ogg_headers_complete
            None,  // connect_overflow
            None,  // connect_burst
            bitrate_enum,
            enable_normalisation,
            None,  // lms_notify (GH #128) — no Connect, no relay
            Arc::clone(&transfer_state),
            Arc::new(RecoveryShared::new(false)),
        ));

        // Pure Browse: wait for Ctrl+C or session reconnect.
        loop {
            tokio::select! {
                _ = browse_reconnect_signal.notified() => {
                    log::warn!("[spoton/unified] Browse-only session reconnect");
                    consecutive_browse_fails.store(0, Ordering::SeqCst);
                    let session_cur = {
                        let s = session_shared.lock().await;
                        s.clone()
                    };
                    if !session_cur.is_invalid() {
                        session_cur.shutdown();
                    }
                    let ns = Session::new(session_config.clone(), Some(reconnect_cache.clone()));
                    match ns.connect(credentials.clone(), false).await {
                        Ok(()) => {
                            *session_shared.lock().await = ns;
                            log::info!("[spoton/unified] Browse-only session reconnected");
                            { *session_created_at.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now(); }
                        }
                        Err(e) => {
                            log::error!("[spoton/unified] Browse-only session reconnect failed: {e}");

                            // M19: retry with exponential backoff (1s/2s/4s) before
                            // installing a fallback. The old behavior installed a brand-new
                            // UNCONNECTED session immediately and cleared the pending flag,
                            // so the next browse failure instantly re-triggered reconnect —
                            // a tight fail loop hammering Spotify APs.
                            let mut reconnected = false;
                            for (attempt, delay_secs) in [1u64, 2, 4].iter().enumerate() {
                                tokio::time::sleep(Duration::from_secs(*delay_secs)).await;
                                log::warn!("[spoton/unified] Browse-only reconnect retry {}/3", attempt + 1);
                                let retry = Session::new(session_config.clone(), Some(reconnect_cache.clone()));
                                match retry.connect(credentials.clone(), false).await {
                                    Ok(()) => {
                                        *session_shared.lock().await = retry;
                                        log::info!("[spoton/unified] Browse-only session reconnected (retry {})", attempt + 1);
                                        { *session_created_at.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now(); }
                                        reconnected = true;
                                        break;
                                    }
                                    Err(retry_err) => {
                                        log::error!("[spoton/unified] Browse-only reconnect retry {} failed: {retry_err}", attempt + 1);
                                    }
                                }
                            }
                            if !reconnected {
                                // All attempts exhausted — install a fallback so callers
                                // hold a Session object, but it is UNHEALTHY (unconnected).
                                // browse_reconnect_pending is still cleared below so a
                                // future failure can retry (the backoff has already
                                // spaced things out).
                                log::error!("[spoton/unified] Browse-only reconnect exhausted (1s/2s/4s backoff) — installing unconnected fallback session (unhealthy)");
                                let fallback = Session::new(session_config.clone(), Some(reconnect_cache.clone()));
                                *session_shared.lock().await = fallback;
                            }
                        }
                    }
                    browse_reconnect_pending.store(false, Ordering::Release);
                }
                _ = tokio::signal::ctrl_c() => break,
            }
        }

        let _ = http_shutdown_tx.send(());
        let _ = http_handle.await;
    }

    Ok(())
}

// -------------------------------------------------------------------------
// /health body (Phase 89, ACC-03; CONTRACT-89)
// -------------------------------------------------------------------------

/// Mask of the session username for the LAN-visible /health body: the first
/// min(4, L - 2) code points followed by `****`, plus L (the code-point count).
/// At least two code points always stay hidden, so prefix plus length never
/// spell out a short name (89 review WR-02); a name of one or two code points
/// gives `****`. An empty name gives ("", 0). Code points, never bytes, so a
/// multibyte name is never cut inside a character.
fn mask_session_user(name: &str) -> (String, usize) {
    let len = name.chars().count();
    if len == 0 {
        return (String::new(), 0);
    }
    let keep = len.saturating_sub(2).min(4);
    let mut masked: String = name.chars().take(keep).collect();
    masked.push_str("****");
    (masked, len)
}

/// The GET /health JSON body. The full username never enters it; serde_json
/// escapes whatever the mask holds.
fn health_json(
    session_valid: bool,
    age_secs: u64,
    idle_secs: u64,
    recovering: bool,
    username: &str,
    audio_key_denials: u32,
) -> String {
    let (session_user, session_user_len) = mask_session_user(username);
    serde_json::json!({
        "status": "ok",
        "session_valid": session_valid,
        "session_age_secs": age_secs,
        "idle_secs": idle_secs,
        "recovering": recovering,
        "session_user": session_user,
        "session_user_len": session_user_len,
        "audio_key_denials": audio_key_denials,
    })
    .to_string()
}

#[cfg(test)]
mod health_json_tests {
    use super::*;

    #[test]
    fn mask_keeps_the_first_four_code_points() {
        assert_eq!(mask_session_user("31abcdefgh"), ("31ab****".to_string(), 10));
    }

    #[test]
    fn mask_of_a_short_name_hides_at_least_two_code_points() {
        // 89 review WR-02: prefix plus length must never spell out a short name
        assert_eq!(mask_session_user("a"), ("****".to_string(), 1));
        assert_eq!(mask_session_user("ab"), ("****".to_string(), 2));
        assert_eq!(mask_session_user("abc"), ("a****".to_string(), 3));
        assert_eq!(mask_session_user("abcd"), ("ab****".to_string(), 4));
        assert_eq!(mask_session_user("abcde"), ("abc****".to_string(), 5));
        assert_eq!(mask_session_user("abcdef"), ("abcd****".to_string(), 6));
    }

    #[test]
    fn mask_of_an_empty_name_is_empty() {
        assert_eq!(mask_session_user(""), (String::new(), 0));
    }

    #[test]
    fn mask_counts_code_points_not_bytes() {
        // four 2-byte letters + "user": 8 code points, 12 bytes
        assert_eq!(
            mask_session_user("\u{e4}\u{f6}\u{fc}\u{df}user"),
            ("\u{e4}\u{f6}\u{fc}\u{df}****".to_string(), 8)
        );
        // eight 3-byte CJK characters: 8 code points, 24 bytes
        assert_eq!(
            mask_session_user("\u{65e5}\u{672c}\u{8a9e}\u{6f22}\u{5b57}\u{6587}\u{5b57}\u{5217}"),
            ("\u{65e5}\u{672c}\u{8a9e}\u{6f22}****".to_string(), 8)
        );
    }

    #[test]
    fn health_json_carries_the_session_fields() {
        let v: serde_json::Value =
            serde_json::from_str(&health_json(true, 12, 3, false, "31abcdefgh", 5))
                .expect("health_json must be valid JSON");
        assert_eq!(v["status"], "ok");
        assert_eq!(v["session_valid"], true);
        assert_eq!(v["session_age_secs"], 12);
        assert_eq!(v["idle_secs"], 3);
        assert_eq!(v["recovering"], false);
        assert_eq!(v["session_user"], "31ab****");
        assert_eq!(v["session_user_len"], 10);
        assert_eq!(v["audio_key_denials"], 5);
    }

    #[test]
    fn health_json_escapes_the_mask() {
        let body = health_json(true, 0, 0, false, "\"\\abcdef", 0);
        let v: serde_json::Value =
            serde_json::from_str(&body).expect("a quote and a backslash must not break the JSON");
        assert_eq!(v["session_user"], "\"\\ab****");
    }

    #[test]
    fn health_json_never_carries_the_full_name() {
        let body = health_json(true, 0, 0, false, "31abcdefgh", 0);
        assert!(!body.contains("31abcdefgh"), "full name leaked: {body}");
        // not vacuous: the masked form must be there
        let v: serde_json::Value = serde_json::from_str(&body).expect("valid JSON");
        assert_eq!(v["session_user"], "31ab****");
        // 89 review WR-02: short names too (upper case: no key or value of the
        // body holds these letters, so a hit can only be the name itself)
        for name in ["Q", "QZ", "QZX", "QZXW", "QZXWV"] {
            let body = health_json(true, 0, 0, false, name, 0);
            assert!(!body.contains(name), "full short name leaked: {body}");
            let v: serde_json::Value = serde_json::from_str(&body).expect("valid JSON");
            assert_eq!(v["session_user_len"], name.chars().count());
        }
    }
}

/// Whether a Browse 404 verdict counts toward the dead-session reconnect,
/// decided per request (89 review WR-04). The fork's refused-key count
/// (`consecutive_denials`) is sticky: only a key that arrives resets it, so
/// "above 0" alone would switch the reconnect off after one refusal, also for
/// a dead key channel (key timeout), which never delivers a key. Instead the
/// count is read before the load and at the verdict:
/// - 0 at the verdict: no refusal is standing, the 404 counts as before (and
///   the remembered titles are dropped, a key has arrived);
/// - changed during the load: a refusal landed (this title's, or one beside
///   it), the 404 does not count, and the title is remembered;
/// - unchanged and above 0: the fork does not count the same title twice in a
///   row, so a title remembered here is a retry or replay of a refused title
///   and does not count either (else a refused account would reconnect on
///   every title); any other title saw no refusal and counts.
struct BrowseKeyRefusals {
    tracks: Vec<String>,
}

/// More titles than the halt limit (5) lets a session refuse in a row.
const BROWSE_KEY_REFUSALS_CAP: usize = 16;

static BROWSE_KEY_REFUSALS: std::sync::Mutex<BrowseKeyRefusals> =
    std::sync::Mutex::new(BrowseKeyRefusals::new());

impl BrowseKeyRefusals {
    const fn new() -> Self {
        BrowseKeyRefusals { tracks: Vec::new() }
    }

    fn counts_toward_reconnect(&mut self, track: &str, before: u32, after: u32) -> bool {
        if after == 0 {
            self.tracks.clear();
            return true;
        }
        let known = self.tracks.iter().any(|t| t == track);
        if after != before {
            if !known {
                if self.tracks.len() >= BROWSE_KEY_REFUSALS_CAP {
                    self.tracks.remove(0);
                }
                self.tracks.push(track.to_owned());
            }
            return false;
        }
        !known
    }
}

#[cfg(test)]
mod browse_denial_tests {
    use super::*;

    #[test]
    fn a_refused_key_404_is_not_a_dead_session() {
        let mut r = BrowseKeyRefusals::new();
        assert!(!r.counts_toward_reconnect("T1", 0, 1));
        assert!(!r.counts_toward_reconnect("T2", 4, 5));
    }

    #[test]
    fn a_plain_404_still_counts_toward_reconnect() {
        let mut r = BrowseKeyRefusals::new();
        assert!(r.counts_toward_reconnect("T1", 0, 0));
    }

    /// 89 review WR-04: the count stays above 0 until a key arrives, and a dead
    /// key channel never delivers one. A 404 whose own load saw no refusal
    /// (count unchanged, a title not refused before) counts again.
    #[test]
    fn a_key_timeout_after_an_earlier_refusal_counts() {
        let mut r = BrowseKeyRefusals::new();
        assert!(!r.counts_toward_reconnect("T1", 0, 1));
        assert!(r.counts_toward_reconnect("T2", 1, 1));
        assert!(r.counts_toward_reconnect("T3", 1, 1));
    }

    /// The loop guard: the fork does not count the same title twice in a row,
    /// so the LMS retries of a refused title (3 x 2 s) and a replay of it after
    /// the halt (D-14) leave the count unchanged. None of them may count, or a
    /// refused account would reconnect on every title.
    #[test]
    fn the_retries_and_replays_of_a_refused_title_never_count() {
        let mut r = BrowseKeyRefusals::new();
        for (n, t) in ["T1", "T2", "T3", "T4", "T5"].iter().enumerate() {
            let n = n as u32;
            assert!(!r.counts_toward_reconnect(t, n, n + 1), "{t}: first refusal");
            for _ in 0..3 {
                assert!(!r.counts_toward_reconnect(t, n + 1, n + 1), "{t}: LMS retry");
            }
        }
        assert!(!r.counts_toward_reconnect("T5", 5, 5), "replay of the halted title");
    }

    #[test]
    fn a_key_that_arrives_clears_the_memory() {
        let mut r = BrowseKeyRefusals::new();
        assert!(!r.counts_toward_reconnect("T1", 0, 1));
        // a key arrived (count back at 0); the 404 counts as before
        assert!(r.counts_toward_reconnect("X", 0, 0));
        // T2 refused, then T1 times out: T1 is no refused title any more
        assert!(!r.counts_toward_reconnect("T2", 0, 1));
        assert!(r.counts_toward_reconnect("T1", 1, 1));
    }

    #[test]
    fn the_memory_is_bounded() {
        let mut r = BrowseKeyRefusals::new();
        for i in 0..(BROWSE_KEY_REFUSALS_CAP as u32 + 8) {
            assert!(!r.counts_toward_reconnect(&format!("T{i}"), i, i + 1));
        }
        assert_eq!(r.tracks.len(), BROWSE_KEY_REFUSALS_CAP);
    }
}

#[cfg(test)]
mod log_filter_tests {
    use log::Log;

    /// The WARN marker of the fork core (CONTRACT-89) must pass the filter the
    /// plugin sets in RUST_LOG (Plugins/SpotOn/Unified/Daemon.pm), or it never
    /// reaches the stderr the plugin tails.
    fn marker_enabled(filter: &str, level: log::Level) -> bool {
        let logger = env_logger::Builder::new().parse_filters(filter).build();
        logger.enabled(
            &log::Metadata::builder()
                .level(level)
                .target("librespot_core::audio_key")
                .build(),
        )
    }

    #[test]
    fn the_shipped_log_filter_passes_the_core_marker() {
        let f = "spoton=info,librespot=warn";
        assert!(marker_enabled(f, log::Level::Warn));
        assert!(!marker_enabled(f, log::Level::Info));
    }

    #[test]
    fn the_diagnostic_log_filter_passes_the_core_marker() {
        let f = "spoton=debug,librespot_connect=debug,librespot_core=debug,librespot=info";
        assert!(marker_enabled(f, log::Level::Warn));
    }
}

// -------------------------------------------------------------------------
// PassthroughMixer unit tests (GH #144)
// -------------------------------------------------------------------------

#[cfg(test)]
mod passthrough_mixer_tests {
    use super::*;

    /// SpircTask::set_volume's change-guard compares self.mixer.volume()
    /// (connect/src/spirc.rs:1917) — unfaithful state breaks VolumeChanged
    /// emission, so the mixer must round-trip volume exactly.
    #[test]
    fn volume_state_round_trip() {
        for v in [0u16, 12345, u16::MAX] {
            let mixer = PassthroughMixer::open(MixerConfig::default())
                .expect("PassthroughMixer::open never fails");
            mixer.set_volume(v);
            assert_eq!(
                mixer.volume(),
                v,
                "volume() must faithfully return the last set_volume value"
            );
        }
    }

    /// Regression test for the GH #144 double-attenuation fix: the audio
    /// pipeline's VolumeGetter must be volume-independent at every setting.
    #[test]
    fn unity_attenuation_invariant() {
        for v in [0u16, 1, 32767, u16::MAX] {
            let mixer = PassthroughMixer::open(MixerConfig::default())
                .expect("PassthroughMixer::open never fails");
            mixer.set_volume(v);
            let soft_volume = mixer.get_soft_volume();
            assert_eq!(
                soft_volume.attenuation_factor(),
                1.0,
                "attenuation_factor must be 1.0 at volume={v} — GH #144 regression test"
            );
        }
    }
}

// -------------------------------------------------------------------------
// /control status mapping unit tests (GH #159)
// -------------------------------------------------------------------------

#[cfg(test)]
mod control_status_tests {
    use super::*;

    const TRANSPORT_CMDS: [&str; 4] = ["play", "pause", "next", "prev"];

    /// Active device + dispatched command — unchanged success contract.
    #[test]
    fn active_dispatched_transport_is_204() {
        for cmd in TRANSPORT_CMDS {
            assert_eq!(
                control_status(false, true, true, cmd),
                StatusCode::NO_CONTENT,
                "active + dispatched {cmd} must stay 204 (no behavior change, GH #159)"
            );
        }
    }

    /// GH #159 core: transport commands while the device is not the active
    /// Connect target must be 409, NOT 204 — regardless of whether the
    /// channel send succeeded (Spirc drops them asynchronously).
    #[test]
    fn inactive_transport_is_409() {
        for cmd in TRANSPORT_CMDS {
            assert_eq!(
                control_status(false, false, true, cmd),
                StatusCode::CONFLICT,
                "inactive {cmd} (send ok, Spirc drops it) must be 409 — GH #159"
            );
            assert_eq!(
                control_status(false, false, false, cmd),
                StatusCode::CONFLICT,
                "inactive {cmd} (handle gone / channel closed) must be 409 — GH #159"
            );
        }
    }

    /// Second None-producing path: Spirc handle gone or command channel
    /// closed while the flag still reads active — also "not an active
    /// Connect target", also 409.
    #[test]
    fn result_absent_transport_is_409() {
        for cmd in TRANSPORT_CMDS {
            assert_eq!(
                control_status(false, true, false, cmd),
                StatusCode::CONFLICT,
                "{cmd} with no Spirc handle must be 409 — GH #159"
            );
        }
    }

    /// volume/seek keep their existing mappings (204 dispatched / 422 body
    /// parse failure) — GH #159 changes only transport commands.
    #[test]
    fn volume_seek_unchanged() {
        for cmd in ["volume", "seek"] {
            assert_eq!(control_status(false, true, true, cmd), StatusCode::NO_CONTENT);
            assert_eq!(control_status(false, false, true, cmd), StatusCode::NO_CONTENT);
            assert_eq!(
                control_status(false, true, false, cmd),
                StatusCode::UNPROCESSABLE_ENTITY,
                "{cmd} body-parse failure must stay 422"
            );
            assert_eq!(
                control_status(false, false, false, cmd),
                StatusCode::UNPROCESSABLE_ENTITY,
                "{cmd} body-parse failure must stay 422 even while inactive"
            );
        }
    }

    /// Unknown commands stay 404.
    #[test]
    fn unknown_command_is_404() {
        assert_eq!(control_status(false, true, false, "bogus"), StatusCode::NOT_FOUND);
        assert_eq!(control_status(false, false, false, "bogus"), StatusCode::NOT_FOUND);
    }

    /// 89-09 (Phase 88 Pitfall 4 redone, PITFALL4=unreachable): the bound of a Browse
    /// title request is 10 s. Above the fork's key timeout chain (4.5 s: three attempts of
    /// `KEY_RESPONSE_TIMEOUT` 1.5 s in core/src/audio_key.rs), so a dead key channel still
    /// ends as a counted 404. Below the 15 s LMS waits for a status line when it opens the
    /// stream itself (`remotestreamtimeout`, a blocking read). Below the 58 s after which
    /// the fork's `request` hands back a code-2 refusal (it asks again at 3, 8, 18, 28, 38,
    /// 48 and 58 s), so that refusal cannot reach the counted 404 arm of one request. If
    /// the bound is ever moved past one of the three, the analysis in the handler must be
    /// redone.
    #[test]
    fn browse_first_signal_bound_sits_between_the_three_clocks() {
        assert_eq!(BROWSE_FIRST_SIGNAL_BOUND, Duration::from_secs(10));
        assert!(BROWSE_FIRST_SIGNAL_BOUND > Duration::from_millis(4500));
        assert!(BROWSE_FIRST_SIGNAL_BOUND < Duration::from_secs(15));
        assert!(BROWSE_FIRST_SIGNAL_BOUND < Duration::from_secs(58));
    }

    /// D-10: the reload timing line is produced once per restart, carries the three
    /// measurements and says `n/a` when no header page was seen (PCM).
    #[test]
    fn reload_timing_line_is_emitted_once_per_restart() {
        let t0 = Instant::now();
        let mut rt = ReloadTiming::new(t0);
        rt.note_headers(t0 + Duration::from_millis(40));
        rt.note_headers(t0 + Duration::from_millis(90)); // ignored: first header page only
        rt.add_parked(Duration::from_millis(120));
        let line = rt.finish(t0 + Duration::from_millis(300)).expect("first audio page");
        assert_eq!(
            line,
            "[spoton/unified] reload timing: headers at +40 ms, first audio page at +300 ms, parked 120 ms"
        );
        assert_eq!(rt.finish(t0 + Duration::from_millis(400)), None, "once per restart");
        rt.restart(t0 + Duration::from_secs(1));
        let line = rt.finish(t0 + Duration::from_millis(1250)).expect("after a restart");
        assert_eq!(
            line,
            "[spoton/unified] reload timing: headers at +n/a ms, first audio page at +250 ms, parked 0 ms"
        );
    }

    /// D-03: a Spirc handle is present and the last dispatch is older than
    /// TRANSFER_MIN_INTERVAL (or there was none) - the transfer goes out, 204.
    #[test]
    fn transfer_is_204_when_dispatched() {
        assert_eq!(transfer_status(false, true, None), StatusCode::NO_CONTENT);
        assert_eq!(
            transfer_status(false, true, Some(Duration::from_secs(10))),
            StatusCode::NO_CONTENT
        );
    }

    /// GH #223 / Pitfall 5: the transfer-back is requested precisely while
    /// the device is NOT the active Connect target, so `transfer_status` takes
    /// no activity flag at all and can never produce the 409 that
    /// `control_status` gives inactive transport commands. A present handle is
    /// the only precondition; the two calls below differ in nothing the
    /// function can see, which is the point.
    #[test]
    fn transfer_is_not_409_when_inactive() {
        let st = transfer_status(false, true, None);
        assert_ne!(st, StatusCode::CONFLICT, "inactive is the precondition of a transfer (GH #223)");
        assert_eq!(st, StatusCode::NO_CONTENT);
        // control_status keeps refusing the same inactive device for transport.
        assert_eq!(control_status(false, false, true, "play"), StatusCode::CONFLICT);
    }

    /// No Spirc handle (Browse preemption / reconnect window): 503, and the
    /// dispatch arm adds `Retry-After: 2`. The Perl side does NOT retry a
    /// refused transfer: `Backend/Librespot.pm::transferBack` takes the refusal
    /// as final for that Play gesture and falls back to Browse at once (one
    /// gesture, at most one /control/transfer, T-88-12). Only a refused
    /// /control/play or /control/pause is retried after the Retry-After
    /// (`_sendControlCommand`, 88 review WR-01).
    #[test]
    fn transfer_without_spirc_is_503() {
        assert_eq!(transfer_status(false, false, None), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(
            transfer_status(false, false, Some(Duration::from_secs(60))),
            StatusCode::SERVICE_UNAVAILABLE
        );
    }

    /// T-88-12: a second dispatch inside TRANSFER_MIN_INTERVAL (3 s) is
    /// refused with 503 - proactive burst prevention.
    #[test]
    fn transfer_within_min_interval_is_503() {
        assert_eq!(
            transfer_status(false, true, Some(Duration::from_secs(1))),
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(
            transfer_status(false, true, Some(TRANSFER_MIN_INTERVAL)),
            StatusCode::NO_CONTENT,
            "exactly the interval is old enough"
        );
    }

    /// D-03 / GH #223: the pull-back this helper was asked for loads PAUSED
    /// when the restored remote state was paused; the helper starts audio
    /// itself on the SessionConnected that follows (armed 2 s ago).
    #[test]
    fn takeover_after_requested_transfer_plays() {
        let t0 = Instant::now();
        assert!(play_after_takeover(Some(t0), t0 + Duration::from_secs(2)));
    }

    /// D-09: a takeover nobody asked for (app selection of a paused session,
    /// 88-04's recovery takeover) never auto-plays.
    #[test]
    fn takeover_without_requested_transfer_does_not_play() {
        assert!(!play_after_takeover(None, Instant::now()));
    }

    /// T-88-30: the arm expires after TRANSFER_PLAY_WINDOW (15 s); a takeover
    /// later than that was not requested by any waiting LMS gesture. Instants
    /// are built by adding to t0 (subtracting from now can underflow).
    #[test]
    fn takeover_after_play_window_does_not_play() {
        let t0 = Instant::now();
        assert!(!play_after_takeover(Some(t0), t0 + Duration::from_secs(16)));
    }
}

// -------------------------------------------------------------------------
// Connect sink pacing tests (post-resume stall, quick 261109-ath)
// -------------------------------------------------------------------------
//
// The Connect sink must pace at 1x since start() but must NOT hold the first
// audio page back by the buffer latency: in OGG passthrough the hold-back is
// pure delay (no PositionCorrection) and every pause/resume restart then opens
// a data gap at squeezelite that is longer than the audio it still holds.
//
// Real-time tests with generous margins: no clock seam exists, and the
// thresholds (500 ms vs the 2000 ms hold-back, against operations that take microseconds) leave wide margins both ways.

#[cfg(test)]
mod sink_test_support {
    use super::*;

    /// A synthetic single-segment OGG page: "OggS", version 0, granule LE i64
    /// at 6..14, serial at 14..18, one lacing value. The sink parser checks no CRC.
    pub fn ogg_page(granule: i64, serial: u32, body_len: usize) -> Vec<u8> {
        let mut p = Vec::with_capacity(28 + body_len);
        p.extend_from_slice(b"OggS");
        p.push(0); // version
        p.push(0); // header type
        p.extend_from_slice(&granule.to_le_bytes());
        p.extend_from_slice(&serial.to_le_bytes());
        p.extend_from_slice(&0u32.to_le_bytes()); // page sequence
        p.extend_from_slice(&0u32.to_le_bytes()); // crc (unchecked)
        p.push(1); // one segment
        p.push(body_len as u8);
        p.extend(std::iter::repeat(0u8).take(body_len));
        p
    }

    pub struct Rig {
        pub sink: UnifiedHttpStreamSink,
        pub rx: mpsc::Receiver<Bytes>,
        pub overflow: Arc<AtomicBool>,
        pub header_buf: Arc<std::sync::Mutex<Vec<Bytes>>>,
        pub header_serial: Arc<AtomicU32>,
        pub headers_complete: Arc<AtomicBool>,
        pub burst: Arc<BurstArm>,
    }

    pub fn rig(capacity: usize, latency_ms: u64, passthrough: bool) -> Rig {
        let (pcm_tx, rx) = mpsc::channel::<Bytes>(capacity);
        let (flush_tx, _flush_rx) = watch::channel::<u64>(0);
        let header_buf = Arc::new(std::sync::Mutex::new(Vec::new()));
        let overflow = Arc::new(AtomicBool::new(false));
        let header_serial = Arc::new(AtomicU32::new(0));
        let headers_complete = Arc::new(AtomicBool::new(false));
        let burst = Arc::new(BurstArm::new());
        let sink = UnifiedHttpStreamSink::new(
            None,
            AudioFormat::S16,
            pcm_tx,
            flush_tx,
            Arc::new(AtomicU64::new(0)),
            latency_ms,
            Arc::clone(&header_buf),
            Arc::clone(&header_serial),
            Arc::clone(&headers_complete),
            Arc::clone(&overflow),
            Arc::clone(&burst),
            passthrough,
        );
        Rig { sink, rx, overflow, header_buf, header_serial, headers_complete, burst }
    }

    pub fn write_raw(sink: &mut UnifiedHttpStreamSink, page: Vec<u8>) {
        let mut conv = Converter::new(None);
        sink.write(AudioPacket::Raw(page), &mut conv).expect("write");
    }
}

#[cfg(test)]
mod sink_pacing_tests {
    use super::sink_test_support::*;
    use super::*;

    const SERIAL: u32 = 0x1111;

    /// RED before the fix: the first audio page after start() waits the 2000 ms
    /// buffer latency on the player thread.
    #[test]
    fn first_audio_page_after_start_is_sent_at_once() {
        let mut r = rig(256, 2000, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30)); // header (granule 0)
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(4410, SERIAL, 30)); // first audio page
        let took = t.elapsed();
        assert!(
            took < Duration::from_millis(500),
            "first audio page after start() was held back {took:?} (hold-back must be 0, bound 500 ms)"
        );
    }

    /// RED before the fix: pause then play restarts the sink; the restart must not
    /// re-apply any hold-back to the first page.
    #[test]
    fn restart_after_stop_does_not_reapply_hold_back() {
        let mut r = rig(256, 2000, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        write_raw(&mut r.sink, ogg_page(4410, SERIAL, 30));
        write_raw(&mut r.sink, ogg_page(8820, SERIAL, 30));
        r.sink.stop().unwrap();
        r.sink.start().unwrap();
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(13230, SERIAL, 30)); // mid-track resume page
        let took = t.elapsed();
        assert!(
            took < Duration::from_millis(500),
            "first page after stop()+start() was held back {took:?}"
        );
    }

    /// RED before the fix (PCM twin): the first Samples packet is released after
    /// its own duration (50 ms), not after 50 ms + the 2000 ms buffer latency.
    #[test]
    fn pcm_first_packet_after_start_is_not_held_back() {
        let mut r = rig(256, 2000, false);
        r.sink.start().unwrap();
        let mut conv = Converter::new(None);
        // 2205 frames * 2 channels = 50 ms of stereo silence.
        let samples = vec![0.0f64; 2205 * NUM_CHANNELS as usize];
        let t = Instant::now();
        r.sink.write(AudioPacket::Samples(samples), &mut conv).unwrap();
        let took = t.elapsed();
        assert!(
            took < Duration::from_millis(500),
            "first PCM packet after start() was held back {took:?}"
        );
    }

    /// Guard (green before and after): pacing stays 1x. The page whose granule is
    /// 100 ms past the first audio page is not released before ~100 ms since start().
    #[test]
    fn pacing_stays_one_x() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        let t0 = Instant::now();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        write_raw(&mut r.sink, ogg_page(4410, SERIAL, 30)); // offset capture, relative 0
        write_raw(&mut r.sink, ogg_page(8820, SERIAL, 30)); // relative 4410 = 100 ms
        let took = t0.elapsed();
        assert!(
            took >= Duration::from_millis(90),
            "second audio page released after {took:?}, expected >= ~100 ms (1x pacing lost)"
        );
    }

    /// Guard (green before and after): a serial change keeps the continuous
    /// timeline (existing branch), it must not reset to zero.
    #[test]
    fn serial_change_continues_timeline() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        let t0 = Instant::now();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        write_raw(&mut r.sink, ogg_page(4410, SERIAL, 30));
        write_raw(&mut r.sink, ogg_page(8820, SERIAL, 30)); // timeline 100 ms
        write_raw(&mut r.sink, ogg_page(0, SERIAL + 1, 30)); // next track headers
        write_raw(&mut r.sink, ogg_page(4410, SERIAL + 1, 30)); // base 100 ms + 100 ms
        let took = t0.elapsed();
        assert!(
            took >= Duration::from_millis(190),
            "timeline reset on serial change: finished after {took:?}, expected >= ~200 ms"
        );
    }
}

// -------------------------------------------------------------------------
// Fresh-stream burst credit tests (quick 261109-f4r, C)
// -------------------------------------------------------------------------
//
// Real-time tests with wide margins, like the pacing tests above. The credit is
// BURST_CREDIT_FRAMES = 98440 frames (2.232 s). With the first audio page captured as
// granule offset (relative 0), page k at granule 8820*k has relative 8820*(k-1) frames:
// k = 12 is still inside the credit (97020), k = 13 is the first one that waits
// (105840 - 98440 = 7400 frames = 168 ms).

#[cfg(test)]
mod sink_burst_credit_tests {
    use super::sink_test_support::*;
    use super::*;

    const SERIAL: u32 = 0x5555;
    const STEP: i64 = 8820; // 200 ms

    fn drive(r: &mut Rig, ks: std::ops::RangeInclusive<i64>) {
        for k in ks {
            write_raw(&mut r.sink, ogg_page(STEP * k, SERIAL, 30));
        }
    }

    /// RED before the fix: today the 12 pages take ~2.2 s.
    #[test]
    fn fresh_relay_start_releases_first_two_seconds_unpaced() {
        let mut r = rig(256, 0, true);
        r.burst.arm();
        r.sink.start().unwrap();
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30)); // header
        drive(&mut r, 1..=12);
        let took = t.elapsed();
        assert!(
            took < Duration::from_millis(300),
            "first 2.2 s of a fresh relay start took {took:?} (credit missing, bound 300 ms)"
        );
        let mut n = 0;
        while r.rx.try_recv().is_ok() {
            n += 1;
        }
        assert_eq!(n, 13, "header + 12 audio pages all delivered");
    }

    /// Guard (green before, and after): the first page past the credit waits, and 1x holds
    /// from there on: no burst beyond the credit.
    #[test]
    fn page_after_credit_is_paced_and_one_x_holds() {
        let mut r = rig(256, 0, true);
        r.burst.arm();
        r.sink.start().unwrap();
        let t0 = Instant::now();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        drive(&mut r, 1..=12);
        let t = Instant::now();
        drive(&mut r, 13..=13);
        let took = t.elapsed();
        assert!(
            took >= Duration::from_millis(150),
            "page 13 (7400 frames past the credit) was released after {took:?}, expected >= ~168 ms"
        );
        drive(&mut r, 14..=15);
        let total = t0.elapsed();
        // page 15: relative 123480 - 98440 = 25040 frames = 568 ms
        assert!(
            total >= Duration::from_millis(520),
            "page 15 released after {total:?} since start, expected >= ~568 ms (1x lost after the credit)"
        );
    }

    /// Guard (green before and after): without an arm there is no credit, 1x from start().
    #[test]
    fn no_credit_without_relay_start() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        drive(&mut r, 1..=6); // relative 44100 = 1.0 s
        let took = t.elapsed();
        assert!(took >= Duration::from_millis(900), "no arm, yet 6 pages took only {took:?}");
    }

    /// Guard (green before, and after): the credit is once per start(). After a pause/resume
    /// cycle (stop(), start()) the arm is gone and the restart gets no credit.
    #[test]
    fn no_credit_on_resume() {
        let mut r = rig(256, 0, true);
        r.burst.arm();
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        drive(&mut r, 1..=3);
        r.sink.stop().unwrap();
        r.sink.start().unwrap();
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(STEP * 20, SERIAL, 30)); // resume page, offset capture
        write_raw(&mut r.sink, ogg_page(STEP * 21, SERIAL, 30)); // 200 ms later
        write_raw(&mut r.sink, ogg_page(STEP * 22, SERIAL, 30)); // 400 ms later
        let took = t.elapsed();
        assert!(
            took >= Duration::from_millis(380),
            "the resume restart took {took:?} for 400 ms of audio, a credit leaked into it"
        );
    }

    /// A reconnect in the middle of a track (timeline older than the fresh window) gets no
    /// credit, and its arm is consumed by that write, so a pause/resume right afterwards
    /// does not pick it up either. (The window is shrunk to 100 ms; production: 5 s.)
    #[test]
    fn no_credit_on_relay_restart_mid_track() {
        let mut r = rig(256, 0, true);
        r.sink.burst_fresh_window = Duration::from_millis(100);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        write_raw(&mut r.sink, ogg_page(STEP, SERIAL, 30)); // relative 0
        write_raw(&mut r.sink, ogg_page(STEP + 4410, SERIAL, 30)); // 100 ms, paced
        std::thread::sleep(Duration::from_millis(150)); // timeline now ~250 ms old > window
        r.burst.arm(); // mid-track relay restart
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(STEP + 22050, SERIAL, 30)); // 500 ms since start
        let took = t.elapsed();
        assert!(
            took >= Duration::from_millis(200),
            "mid-track relay restart: page released after {took:?}, expected ~250 ms (credit leaked)"
        );
        // The arm was consumed above: pause/resume right after gets nothing.
        r.sink.stop().unwrap();
        r.sink.start().unwrap();
        r.sink.burst_fresh_window = BURST_FRESH_WINDOW;
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(STEP * 50, SERIAL, 30));
        write_raw(&mut r.sink, ogg_page(STEP * 52, SERIAL, 30)); // 400 ms later
        let took = t.elapsed();
        assert!(
            took >= Duration::from_millis(380),
            "resume after a mid-track restart took {took:?} for 400 ms, the consumed arm came back"
        );
    }

    /// An arm older than BURST_ARM_MAX_AGE (relay started long before the sink did) is stale.
    #[test]
    fn stale_arm_gives_no_credit() {
        let mut r = rig(256, 0, true);
        r.burst.arm_at(Instant::now().checked_sub(Duration::from_secs(20)).expect("clock"));
        r.sink.start().unwrap();
        let t = Instant::now();
        write_raw(&mut r.sink, ogg_page(0, SERIAL, 30));
        drive(&mut r, 1..=3); // relative 17640 = 400 ms
        let took = t.elapsed();
        assert!(took >= Duration::from_millis(380), "stale arm bought a credit: {took:?}");
    }

    /// PCM twin. 44 packets of 2205 frames = 97020 frames, inside the credit.
    #[test]
    fn pcm_fresh_relay_start_releases_first_two_seconds_unpaced() {
        let mut r = rig(256, 0, false);
        r.burst.arm(); // PCM: the relay may start before the sink does
        r.sink.start().unwrap();
        let mut conv = Converter::new(None);
        let t = Instant::now();
        for _ in 0..44 {
            let samples = vec![0.0f64; 2205 * NUM_CHANNELS as usize];
            r.sink.write(AudioPacket::Samples(samples), &mut conv).unwrap();
        }
        let took = t.elapsed();
        assert!(took < Duration::from_millis(300), "PCM: 2.2 s of a fresh relay start took {took:?}");
    }

    /// PCM guard: no arm, 1x.
    #[test]
    fn pcm_no_credit_without_relay_start() {
        let mut r = rig(256, 0, false);
        r.sink.start().unwrap();
        let mut conv = Converter::new(None);
        let t = Instant::now();
        for _ in 0..10 {
            let samples = vec![0.0f64; 2205 * NUM_CHANNELS as usize];
            r.sink.write(AudioPacket::Samples(samples), &mut conv).unwrap();
        }
        let took = t.elapsed();
        assert!(took >= Duration::from_millis(450), "PCM, no arm: 10 packets (500 ms) took only {took:?}");
    }
}

// -------------------------------------------------------------------------
// Connect sink back-pressure tests (GH #202, quick 261109-ath)
// -------------------------------------------------------------------------
//
// Nobody reading pcm_rx (LMS paused/cut the stream, Browse took over, relay
// gone) must never freeze the librespot player thread: the sink drops what it
// cannot deliver, flags the overflow, and the relay discards the stale backlog
// when a reader returns.

#[cfg(test)]
mod sink_backpressure_tests {
    use super::sink_test_support::*;
    use super::*;

    const SERIAL: u32 = 0x2222;

    /// A PCM-style cursor (no header state): the plain GH #202 relay step.
    fn pcm_cursor() -> RelayCursor {
        RelayCursor { passthrough: false, last_serial: 0, headers: None }
    }

    /// The Chunk of one relay pass, None for Idle (Replay is not expected here).
    fn take(rx: &mut mpsc::Receiver<Bytes>, overflow: &AtomicBool, cur: &mut RelayCursor) -> Option<Bytes> {
        match relay_step(rx, overflow, cur) {
            RelayStep::Chunk(b) => Some(b),
            RelayStep::Idle => None,
            RelayStep::Replay(_) => panic!("unexpected header replay"),
        }
    }

    /// Runs `f` on a worker thread; None when it does not finish in time. A red run
    /// (the old spin loop) must fail the test, not hang the suite.
    fn within<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = done_tx.send(f());
        });
        done_rx.recv_timeout(Duration::from_secs(3)).ok()
    }

    /// RED before the fix: write into a full, unread channel never returns.
    #[test]
    fn write_returns_when_nobody_reads() {
        let out = within(|| {
            let mut r = rig(4, 0, true);
            r.sink.start().unwrap();
            let mut results = Vec::new();
            let mut conv = Converter::new(None);
            for _ in 0..6 {
                // header pages: no pacing, but captured into ogg_header_buf
                results.push(
                    r.sink
                        .write(AudioPacket::Raw(ogg_page(0, SERIAL, 30)), &mut conv)
                        .is_ok(),
                );
            }
            let queued = {
                let mut n = 0;
                while r.rx.try_recv().is_ok() {
                    n += 1;
                }
                n
            };
            let captured = r.header_buf.lock().unwrap().len();
            (results, r.sink.dropped, r.overflow.load(Ordering::Acquire), queued, captured)
        });
        let (results, dropped, overflow, queued, captured) = out
            .expect("write() into an unread full channel did not return within 3 s (player thread frozen, GH #202)");
        assert!(results.iter().all(|ok| *ok), "every write must return Ok on a full channel");
        assert_eq!(queued, 4, "the channel holds its 4 slots");
        assert_eq!(dropped, 2, "the 2 chunks that did not fit are dropped");
        assert!(overflow, "overflow flag must be set for the relay");
        assert_eq!(captured, 6, "header capture happens before the send, so replay survives a drop");
    }

    /// RED before the fix: the relay step discards the stale backlog once after an
    /// overflow instead of replaying it.
    #[test]
    fn relay_drains_backlog_after_overflow() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(8);
        let overflow = AtomicBool::new(false);
        for i in 0..3u8 {
            tx.try_send(Bytes::from(vec![i])).unwrap();
        }
        // no overflow: plain FIFO
        let mut cur = pcm_cursor();
        assert_eq!(take(&mut rx, &overflow, &mut cur).as_deref(), Some(&[0u8][..]));
        overflow.store(true, Ordering::Release);
        assert!(take(&mut rx, &overflow, &mut cur).is_none(), "overflow pass returns None once");
        assert!(!overflow.load(Ordering::Acquire), "flag is consumed");
        assert!(rx.try_recv().is_err(), "stale backlog is gone");
        tx.try_send(Bytes::from(vec![9u8])).unwrap();
        assert_eq!(take(&mut rx, &overflow, &mut cur).as_deref(), Some(&[9u8][..]), "live audio flows again");
    }

    /// RED before the fix: after the reader returns the player is not stuck and the
    /// first chunk the reader sees is live audio, not the stale backlog.
    #[test]
    fn reader_returning_gets_live_audio_not_backlog() {
        let out = within(|| {
            let mut r = rig(2, 0, true);
            r.sink.start().unwrap();
            let mut conv = Converter::new(None);
            // 4 pages into 2 slots: 2 stale queued, 2 dropped
            for g in [0i64, 0, 0, 0] {
                r.sink.write(AudioPacket::Raw(ogg_page(g, SERIAL, 30)), &mut conv).unwrap();
            }
            let mut cur = pcm_cursor();
            let stale_pass = take(&mut r.rx, &r.overflow, &mut cur); // reader returns
            // the player kept going while nobody read: a distinguishable live page
            r.sink.write(AudioPacket::Raw(ogg_page(0, SERIAL, 77)), &mut conv).unwrap();
            let live = take(&mut r.rx, &r.overflow, &mut cur);
            (stale_pass.is_none(), live.map(|b| b.len()))
        });
        let (stale_none, live_len) = out.expect("sink froze with nobody reading (GH #202)");
        assert!(stale_none, "first relay pass after the overflow discards the backlog");
        assert_eq!(live_len, Some(28 + 77), "reader then receives the live page");
    }

    /// Guard (green before and after): a closed receiver (Browse/relay gone for
    /// good) still surfaces as a sink error, distinct from a merely full channel.
    #[test]
    fn closed_receiver_returns_error() {
        let mut r = rig(4, 0, true);
        r.sink.start().unwrap();
        drop(r.rx);
        let mut conv = Converter::new(None);
        let res = r.sink.write(AudioPacket::Raw(ogg_page(0, SERIAL, 30)), &mut conv);
        assert!(res.is_err(), "Closed must stay an error");
    }
}

// -------------------------------------------------------------------------
// Sink edge cases that the review (sink-fix-review.md section 4) asked for
// -------------------------------------------------------------------------

#[cfg(test)]
mod sink_edge_tests {
    use super::sink_test_support::*;
    use super::*;

    const S: u32 = 0x3333;

    /// The exact shape of the `same` row and of every tap (double `endpoint: play`):
    /// ONE chunk holding [EOS page of the old serial][BOS][setup of the new serial]
    /// [first audio page of the new serial], written right after start(). Must not be
    /// held back, must leave exactly the two new-serial header pages in the buffer.
    #[test]
    fn same_track_reload_chunk_is_not_held_back() {
        let mut r = rig(256, 2000, true);
        r.sink.start().unwrap();
        let mut chunk = ogg_page(1_300_000, S, 30); // old serial, EOS-ish page
        chunk.extend(ogg_page(0, S + 1, 40)); // BOS new serial
        chunk.extend(ogg_page(0, S + 1, 50)); // setup new serial
        chunk.extend(ogg_page(5000, S + 1, 30)); // first audio new serial
        let t = Instant::now();
        write_raw(&mut r.sink, chunk);
        let took = t.elapsed();
        assert!(took < Duration::from_millis(500), "reload chunk held back {took:?}");
        let buf = r.header_buf.lock().unwrap();
        assert_eq!(buf.len(), 2, "exactly the two new-serial header pages are buffered");
        assert!(buf.iter().all(|p| u32::from_le_bytes(p[14..18].try_into().unwrap()) == S + 1));
        assert_eq!(r.header_serial.load(Ordering::Acquire), S + 1);
        assert!(r.headers_complete.load(Ordering::Acquire));
    }

    /// Upper bound for the serial-change branch (the pacing test only had a lower
    /// bound): no hidden hold-back at a track boundary.
    #[test]
    fn serial_change_first_page_released_promptly() {
        let mut r = rig(256, 2000, true);
        r.sink.start().unwrap();
        let t0 = Instant::now();
        write_raw(&mut r.sink, ogg_page(0, S, 30));
        write_raw(&mut r.sink, ogg_page(4410, S, 30));
        write_raw(&mut r.sink, ogg_page(8820, S, 30)); // timeline 100 ms
        write_raw(&mut r.sink, ogg_page(0, S + 1, 30));
        write_raw(&mut r.sink, ogg_page(4410, S + 1, 30)); // timeline 200 ms
        let took = t0.elapsed();
        assert!(took < Duration::from_millis(600), "boundary page held back: {took:?}");
    }

    /// PCM twin of write_returns_when_nobody_reads.
    #[test]
    fn pcm_write_returns_when_nobody_reads() {
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut r = rig(2, 0, false);
            r.sink.start().unwrap();
            let mut conv = Converter::new(None);
            let mut oks = 0;
            for _ in 0..3 {
                let samples = vec![0.0f64; 2205 * NUM_CHANNELS as usize]; // 50 ms
                if r.sink.write(AudioPacket::Samples(samples), &mut conv).is_ok() {
                    oks += 1;
                }
            }
            let _ = done_tx.send((oks, r.sink.dropped, r.overflow.load(Ordering::Acquire)));
        });
        let (oks, dropped, overflow) = done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("PCM write() into an unread full channel did not return within 3 s");
        assert_eq!(oks, 3, "every PCM write returns Ok");
        assert_eq!(dropped, 1, "third 50 ms packet does not fit the 2 slots");
        assert!(overflow);
    }
}

// -------------------------------------------------------------------------
// Relay start and overflow recovery (review W-1 / W-2, quick 261109-ath)
// -------------------------------------------------------------------------

#[cfg(test)]
mod relay_recovery_tests {
    use super::sink_test_support::*;
    use super::*;

    const S: u32 = 0x4444;

    fn serial_of(b: &[u8]) -> u32 {
        u32::from_le_bytes(b[14..18].try_into().unwrap())
    }

    fn granule_of(b: &[u8]) -> i64 {
        i64::from_le_bytes(b[6..14].try_into().unwrap())
    }

    fn queue(tx: &mpsc::Sender<Bytes>, pages: Vec<Vec<u8>>) {
        for p in pages {
            tx.try_send(Bytes::from(p)).unwrap();
        }
    }

    /// W-1, RED before the fix: at relay start the sink has already pushed the header
    /// chunk and the first audio page (no hold-back any more). The audio page of the
    /// current stream must survive the drain; only the header chunk (replayed from
    /// the snapshot) is discarded.
    #[test]
    fn relay_start_keeps_first_audio_page_of_current_serial() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(0, S, 30)); // chunk 1: headers
        write_raw(&mut r.sink, ogg_page(4410, S, 30)); // chunk 2: first audio page
        let snapshot: Vec<Bytes> = r.header_buf.lock().unwrap().clone();
        let (kept, discarded) = relay_start_backlog(&mut r.rx, &r.overflow, true, &snapshot);
        assert_eq!(kept.len(), 1, "the first audio page must be kept (discarded {discarded})");
        assert_eq!(granule_of(&kept[0]), 4410);
        assert_eq!(serial_of(&kept[0]), S);
        assert_eq!(discarded, 1, "only the header chunk is discarded");
        assert!(r.rx.try_recv().is_err(), "channel is empty afterwards");
    }

    /// W-1, RED before the fix: a queued chunk of a foreign serial (pre-seek /
    /// previous track) is dropped, the rest survives.
    #[test]
    fn relay_start_drops_only_foreign_serial_chunks() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(16);
        queue(&tx, vec![ogg_page(9000, S - 1, 30), ogg_page(0, S, 30), ogg_page(4410, S, 30)]);
        let snapshot = vec![Bytes::from(ogg_page(0, S, 30))];
        let overflow = AtomicBool::new(false);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &snapshot);
        assert_eq!(kept.len(), 1);
        assert_eq!(serial_of(&kept[0]), S);
        assert_eq!(granule_of(&kept[0]), 4410);
        assert_eq!(discarded, 2, "foreign-serial chunk + header chunk");
    }

    /// W-1, RED before the fix: filtering is per page, so a chunk spanning the old
    /// stream's tail and the new stream (the same-track reload shape) keeps only the
    /// new stream's audio page.
    #[test]
    fn relay_start_splits_mixed_chunk_by_page() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(16);
        let mut chunk = ogg_page(9000, S - 1, 30);
        chunk.extend(ogg_page(0, S, 30));
        chunk.extend(ogg_page(4410, S, 31));
        queue(&tx, vec![chunk]);
        let snapshot = vec![Bytes::from(ogg_page(0, S, 30))];
        let overflow = AtomicBool::new(false);
        let (kept, _) = relay_start_backlog(&mut rx, &overflow, true, &snapshot);
        let all: Vec<u8> = kept.iter().flat_map(|b| b.to_vec()).collect();
        let pages = ogg_pages(&all);
        assert_eq!(pages.len(), 1, "exactly one page kept");
        assert_eq!(pages[0].serial, S);
        assert_eq!(pages[0].granule, 4410);
    }

    /// Guard (green before and after): an overflow means the whole backlog is stale.
    #[test]
    fn relay_start_after_overflow_discards_everything() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(16);
        queue(&tx, vec![ogg_page(4410, S, 30), ogg_page(8820, S, 30)]);
        let snapshot = vec![Bytes::from(ogg_page(0, S, 30))];
        let overflow = AtomicBool::new(true);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &snapshot);
        assert!(kept.is_empty());
        assert_eq!(discarded, 2);
        assert!(!overflow.load(Ordering::Acquire), "flag cleared by the relay start");
        assert!(rx.try_recv().is_err());
    }

    /// Guard: PCM cannot tell stale from fresh, so it keeps the total drain. (The OGG
    /// without-snapshot half of review I-7 moved to
    /// `relay_start_without_snapshot_keeps_pending_chunks`, quick 261109-f4r.)
    #[test]
    fn relay_start_without_serial_knowledge_drains_everything() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(16);
        let overflow = AtomicBool::new(false);
        queue(&tx, vec![vec![1, 2, 3], vec![4, 5, 6]]);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, false, &[]);
        assert!(kept.is_empty());
        assert_eq!(discarded, 2, "PCM: total drain");
    }

    /// Quick 261109-f4r (D), RED before the fix: an OGG stream without a header snapshot
    /// must NOT discard what is queued. The state is reached at a header-wait timeout with
    /// fewer than two header pages of the current serial (fresh daemon, slow session start:
    /// a header chunk can still sit in the queue, or land between the wait's timeout and this
    /// drain, and would otherwise be thrown away and leave the connection headerless until
    /// the next serial) and, since quick 261110-r38, at the early exit of the wait (headers
    /// of the current serial known absent: the queued audio is undecodable either way until
    /// the next BOS, and keeping the queue never drops a following serial's header chunk).
    /// Nothing is forwarded out of order: the chunks go out as queued, right after the
    /// (non-existent) replay. Replaces the review I-7 half of the guard above, which asserted
    /// the opposite for this one case; PCM and the overflow case keep the total drain.
    #[test]
    fn relay_start_without_snapshot_keeps_pending_chunks() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(16);
        let overflow = AtomicBool::new(false);
        queue(&tx, vec![ogg_page(0, S, 30), ogg_page(4410, S, 30)]);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &[]);
        assert_eq!(kept.len(), 2, "both queued chunks are kept (discarded {discarded})");
        assert_eq!(granule_of(&kept[0]), 0, "header chunk first, in queue order");
        assert_eq!(granule_of(&kept[1]), 4410);
        assert_eq!(discarded, 0);
        assert!(rx.try_recv().is_err(), "channel is empty afterwards");
    }

    /// Guard (green before and after): the overflow flag still means everything is stale,
    /// snapshot or not.
    #[test]
    fn relay_start_without_snapshot_after_overflow_still_discards() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(16);
        let overflow = AtomicBool::new(true);
        queue(&tx, vec![ogg_page(0, S, 30), ogg_page(4410, S, 30)]);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &[]);
        assert!(kept.is_empty());
        assert_eq!(discarded, 2);
    }

    /// Review test 6: the relay-start step clears the flag before it drains; a flag
    /// set afterwards (sink Full during/after the drain) costs exactly one more
    /// Idle pass and then live data flows (documents I-1).
    #[test]
    fn relay_start_clears_overflow_before_drain() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(16);
        let overflow = AtomicBool::new(true);
        queue(&tx, vec![ogg_page(4410, S, 30)]);
        let _ = relay_start_backlog(&mut rx, &overflow, true, &[]);
        assert!(!overflow.load(Ordering::Acquire));
        overflow.store(true, Ordering::Release); // Full right after the drain
        queue(&tx, vec![ogg_page(8820, S, 30)]);
        let mut cur = RelayCursor { passthrough: true, last_serial: S, headers: None };
        assert!(matches!(relay_step(&mut rx, &overflow, &mut cur), RelayStep::Idle), "one extra drain pass");
        queue(&tx, vec![ogg_page(13230, S, 30)]);
        assert!(matches!(relay_step(&mut rx, &overflow, &mut cur), RelayStep::Chunk(_)), "then live");
    }

    fn headers_of(r: &Rig) -> RelayHeaders {
        RelayHeaders {
            buf: Arc::clone(&r.header_buf),
            serial: Arc::clone(&r.header_serial),
            complete: Arc::clone(&r.headers_complete),
        }
    }

    /// W-2, RED before the fix: an overflow that spans a track boundary on a
    /// surviving connection. The new serial's header pages were dropped (channel
    /// full); the relay must replay them before any live page of that serial.
    #[test]
    fn overflow_across_serial_change_replays_headers_to_same_reader() {
        let mut r = rig(2, 0, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(0, S, 30)); // fills slot 1
        write_raw(&mut r.sink, ogg_page(4410, S, 30)); // fills slot 2
        write_raw(&mut r.sink, ogg_page(0, S + 1, 30)); // dropped: new track headers
        write_raw(&mut r.sink, ogg_page(4410, S + 1, 30)); // dropped
        assert!(r.overflow.load(Ordering::Acquire));
        // the connection had forwarded serial S before the reader stalled
        let mut cur = RelayCursor { passthrough: true, last_serial: S, headers: Some(headers_of(&r)) };
        let mut delivered: Vec<Vec<u8>> = Vec::new();
        let mut collect = |step: RelayStep| match step {
            RelayStep::Chunk(b) => delivered.push(b.to_vec()),
            RelayStep::Replay(pages) => delivered.extend(pages.into_iter().map(|p| p.to_vec())),
            RelayStep::Idle => {}
        };
        collect(relay_step(&mut r.rx, &r.overflow, &mut cur)); // overflow pass
        write_raw(&mut r.sink, ogg_page(8820, S + 1, 30)); // live audio of the new serial
        collect(relay_step(&mut r.rx, &r.overflow, &mut cur));
        assert!(!delivered.is_empty(), "something must reach the reader");
        assert_eq!(serial_of(&delivered[0]), S + 1);
        assert_eq!(granule_of(&delivered[0]), 0, "headers of the new serial come first, got granule {}", granule_of(&delivered[0]));
        assert_eq!(cur.last_serial, S + 1);
    }

    /// W-2 guard: the serial did not change across the overflow, so the headers must
    /// NOT be replayed (a second BOS of the same serial would re-open the link).
    #[test]
    fn overflow_same_serial_does_not_replay_headers() {
        let mut r = rig(2, 0, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(0, S, 30));
        write_raw(&mut r.sink, ogg_page(4410, S, 30));
        write_raw(&mut r.sink, ogg_page(8820, S, 30)); // dropped
        assert!(r.overflow.load(Ordering::Acquire));
        let mut cur = RelayCursor { passthrough: true, last_serial: S, headers: Some(headers_of(&r)) };
        assert!(matches!(relay_step(&mut r.rx, &r.overflow, &mut cur), RelayStep::Idle));
        assert!(matches!(relay_step(&mut r.rx, &r.overflow, &mut cur), RelayStep::Idle));
    }

    // ---- quick 261110-r38 (W1): header buffer across sink stop()/start() ----

    /// The decoder's real header shape: ONE chunk holding the BOS and the setup page.
    fn header_chunk(serial: u32, body_a: usize, body_b: usize) -> Vec<u8> {
        let mut c = ogg_page(0, serial, body_a);
        c.extend(ogg_page(0, serial, body_b));
        c
    }

    async fn wait_headers(r: &Rig, secs: u64) -> (Vec<Bytes>, Duration) {
        let t = Instant::now();
        let got = wait_for_ogg_headers(
            &*r.header_buf,
            Some(&*r.headers_complete),
            Some(&*r.header_serial),
            Duration::from_secs(secs),
        )
        .await;
        (got, t.elapsed())
    }

    /// Sink state of a track that was paused and resumed: headers + audio, stop(), start(),
    /// then the first page after the resume (an audio page: the decoder keeps its serial and
    /// does not resend the headers).
    fn paused_and_resumed(r: &mut Rig) {
        r.sink.start().unwrap();
        write_raw(&mut r.sink, header_chunk(S, 30, 31));
        write_raw(&mut r.sink, ogg_page(4410, S, 30));
        r.sink.stop().unwrap();
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(8820, S, 30));
    }

    /// W1, RED before the fix: a pause/resume must not lose the header pages.
    #[test]
    fn resume_keeps_header_buffer_for_reconnect() {
        let mut r = rig(256, 0, true);
        paused_and_resumed(&mut r);
        let buf = r.header_buf.lock().unwrap();
        assert_eq!(buf.len(), 2, "both header pages survive stop()/start()");
        assert!(buf.iter().all(|p| serial_of(p) == S && granule_of(p) == 0));
        assert_eq!(r.header_serial.load(Ordering::Acquire), S);
        assert!(r.headers_complete.load(Ordering::Acquire));
    }

    /// W1, RED before the fix: a /stream GET after the resume gets the headers at once,
    /// not after the full wait bound.
    #[tokio::test]
    async fn reconnect_after_resume_gets_buffered_headers_at_once() {
        let mut r = rig(256, 0, true);
        paused_and_resumed(&mut r);
        let (got, took) = wait_headers(&r, 2).await;
        assert!(took < Duration::from_millis(500), "header wait took {took:?}");
        assert_eq!(got.len(), 2, "the two header pages of S");
        assert!(got.iter().all(|p| serial_of(p) == S && granule_of(p) == 0));
    }

    /// W1, RED before the fix: the headers of the current serial are known absent (first
    /// page after start() was audio, nothing buffered): the wait ends at once and the
    /// queued audio page is kept (None arm unchanged).
    #[tokio::test]
    async fn header_wait_ends_at_once_when_headers_are_known_absent() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, ogg_page(4410, S, 30));
        assert!(r.headers_complete.load(Ordering::Acquire));
        assert!(r.header_buf.lock().unwrap().is_empty());
        let (got, took) = wait_headers(&r, 2).await;
        assert!(took < Duration::from_millis(500), "header wait took {took:?}");
        assert!(got.is_empty());
        let (kept, discarded) = relay_start_backlog(&mut r.rx, &r.overflow, true, &got);
        assert_eq!(kept.len(), 1, "the queued audio page is kept (discarded {discarded})");
        assert_eq!(granule_of(&kept[0]), 4410);
    }

    /// W1 guard (mutation a): a new track after a pause replaces the retained headers.
    #[test]
    fn track_change_after_pause_replaces_buffered_headers() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, header_chunk(S, 30, 31));
        write_raw(&mut r.sink, ogg_page(4410, S, 30));
        r.sink.stop().unwrap();
        r.sink.start().unwrap();
        assert!(
            !r.headers_complete.load(Ordering::Acquire),
            "start() must reopen the wait until the first page decides"
        );
        write_raw(&mut r.sink, header_chunk(S + 1, 30, 31));
        write_raw(&mut r.sink, ogg_page(4410, S + 1, 30));
        let buf = r.header_buf.lock().unwrap();
        assert_eq!(buf.len(), 2, "only the headers of the new serial");
        assert!(buf.iter().all(|p| serial_of(p) == S + 1));
        assert_eq!(r.header_serial.load(Ordering::Acquire), S + 1);
        assert!(r.headers_complete.load(Ordering::Acquire));
    }

    /// W1 guard (mutation b): the same serial re-emitting its header set after start()
    /// (granule 0) replaces the retained set; it is neither stacked behind it nor ignored.
    /// The re-emitted pages carry other body sizes (40/41) so a kept stale set is visible.
    #[test]
    fn same_serial_header_reemission_after_start_is_not_duplicated() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, header_chunk(S, 30, 31));
        write_raw(&mut r.sink, ogg_page(4410, S, 30));
        r.sink.stop().unwrap();
        r.sink.start().unwrap();
        write_raw(&mut r.sink, header_chunk(S, 40, 41));
        assert!(
            !r.headers_complete.load(Ordering::Acquire),
            "a header page does not close the collection"
        );
        write_raw(&mut r.sink, ogg_page(13230, S, 30));
        let buf = r.header_buf.lock().unwrap();
        assert_eq!(buf.len(), 2, "exactly one header set");
        assert_eq!(buf[0].len(), 28 + 40, "the re-emitted BOS replaced the retained one");
        assert_eq!(buf[1].len(), 28 + 41);
        assert!(r.headers_complete.load(Ordering::Acquire));
    }

    /// W1 guard (mutation c): a seek-shaped chunk right after start() (seek while paused, the
    /// `same` row, every tap): [EOS of the old serial][BOS][setup][first audio page of S + 1].
    /// The reader must end with exactly the two S + 1 pages, never the old serial's headers.
    #[tokio::test]
    async fn seek_shaped_chunk_after_resume_replaces_buffered_headers() {
        let mut r = rig(256, 0, true);
        r.sink.start().unwrap();
        write_raw(&mut r.sink, header_chunk(S, 30, 31));
        write_raw(&mut r.sink, ogg_page(4410, S, 30));
        r.sink.stop().unwrap();
        r.sink.start().unwrap();
        let mut chunk = ogg_page(1_300_000, S, 30); // EOS page of the old serial
        chunk.extend(ogg_page(0, S + 1, 40)); // BOS new serial
        chunk.extend(ogg_page(0, S + 1, 50)); // setup new serial
        chunk.extend(ogg_page(5000, S + 1, 30)); // first audio page new serial
        write_raw(&mut r.sink, chunk);
        {
            let buf = r.header_buf.lock().unwrap();
            assert_eq!(buf.len(), 2, "exactly the two new-serial header pages");
            assert!(buf.iter().all(|p| serial_of(p) == S + 1));
        }
        assert_eq!(r.header_serial.load(Ordering::Acquire), S + 1);
        assert!(r.headers_complete.load(Ordering::Acquire));
        let (got, took) = wait_headers(&r, 2).await;
        assert!(took < Duration::from_millis(500), "header wait took {took:?}");
        assert_eq!(got.len(), 2);
        assert!(got.iter().all(|p| serial_of(p) == S + 1 && granule_of(p) == 0));
    }

    // ---- quick 261110-r38 (W2): age cap of the relay-start backlog ----

    /// Pages of serial `serial` at granules `8820 * k`, chunked `per_chunk` pages each.
    fn audio_chunks(serial: u32, ks: std::ops::RangeInclusive<i64>, per_chunk: usize) -> Vec<Vec<u8>> {
        let pages: Vec<Vec<u8>> = ks.map(|k| ogg_page(8820 * k, serial, 30)).collect();
        pages.chunks(per_chunk).map(|c| c.concat()).collect()
    }

    fn kept_pages(kept: &[Bytes]) -> Vec<(u32, i64)> {
        let all: Vec<u8> = kept.iter().flat_map(|b| b.to_vec()).collect();
        ogg_pages(&all).iter().map(|p| (p.serial, p.granule)).collect()
    }

    /// W2, RED before the fix: only the last BURST_CREDIT_FRAMES of audio behind the newest
    /// queued page survive, cut by page inside a chunk.
    #[test]
    fn relay_start_backlog_keeps_only_the_last_credit_of_audio() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(64);
        queue(&tx, audio_chunks(S, 1..=30, 4));
        let snapshot = vec![Bytes::from(ogg_page(0, S, 30))];
        let overflow = AtomicBool::new(false);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &snapshot);
        let pages = kept_pages(&kept);
        let granules: Vec<i64> = pages.iter().map(|p| p.1).collect();
        let want: Vec<i64> = (19..=30).map(|k| 8820 * k).collect();
        assert_eq!(granules, want, "exactly k = 19..30 survive");
        assert_eq!(granules[0], 167_580);
        assert_eq!(*granules.last().unwrap(), 264_600);
        assert!(granules.iter().all(|g| *g >= 264_600 - BURST_CREDIT_FRAMES as i64));
        assert_eq!(discarded, 4, "the four chunks before the window contribute nothing");
    }

    /// W2, RED before the fix: the cut is by position. The window starts at the first page
    /// of the serial with granule > 0 inside it; a granule -1 continuation page before that
    /// goes, one inside stays.
    #[test]
    fn relay_start_backlog_cap_starts_at_the_first_page_inside_the_window() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(64);
        let mut pages: Vec<Vec<u8>> = Vec::new();
        pages.extend(audio_chunks(S, 1..=3, 1));
        pages.push(ogg_page(-1, S, 30));
        pages.extend(audio_chunks(S, 4..=15, 1));
        pages.push(ogg_page(-1, S, 30));
        pages.extend(audio_chunks(S, 16..=20, 1));
        assert_eq!(pages.len(), 22);
        queue(&tx, pages);
        let snapshot = vec![Bytes::from(ogg_page(0, S, 30))];
        let overflow = AtomicBool::new(false);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &snapshot);
        let got = kept_pages(&kept);
        assert_eq!(got.len(), 13, "k = 9..15, the second -1 page, k = 16..20");
        assert_eq!(got[0].1, 79_380, "first kept granule (k = 9)");
        let neg: Vec<usize> = got.iter().enumerate().filter(|(_, p)| p.1 == -1).map(|(i, _)| i).collect();
        assert_eq!(neg.len(), 1, "exactly one granule -1 page");
        assert_eq!(got[neg[0] - 1].1, 132_300);
        assert_eq!(got[neg[0] + 1].1, 141_120);
        assert_eq!(discarded, 9);
    }

    /// Guard (mutation d): a backlog younger than the cap is kept whole.
    #[test]
    fn relay_start_backlog_keeps_a_young_backlog_whole() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(64);
        queue(&tx, audio_chunks(S, 1..=10, 1));
        let snapshot = vec![Bytes::from(ogg_page(0, S, 30))];
        let overflow = AtomicBool::new(false);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &snapshot);
        assert_eq!(kept_pages(&kept).len(), 10, "span 79380 < cap, nothing dropped");
        assert_eq!(discarded, 0);
    }

    /// Guard (mutation e): the window is anchored on the snapshot serial only. A foreign
    /// serial deep into its length (the previous track) must not discard the new track.
    #[test]
    fn relay_start_backlog_window_ignores_foreign_serials() {
        let (tx, mut rx) = mpsc::channel::<Bytes>(64);
        queue(&tx, vec![ogg_page(8_000_000, S - 1, 30), ogg_page(8_008_820, S - 1, 30)]);
        queue(&tx, audio_chunks(S, 1..=10, 1));
        let snapshot = vec![Bytes::from(ogg_page(0, S, 30))];
        let overflow = AtomicBool::new(false);
        let (kept, discarded) = relay_start_backlog(&mut rx, &overflow, true, &snapshot);
        let got = kept_pages(&kept);
        assert_eq!(got.len(), 10, "all audio of the new serial survives");
        assert!(got.iter().all(|p| p.0 == S));
        assert_eq!(discarded, 2, "the two foreign-serial chunks");
    }
}

// -------------------------------------------------------------------------
// AP-drop recovery decision tests (GH #207, D-07/D-08/D-09)
// -------------------------------------------------------------------------

#[cfg(test)]
mod recovery_tests {
    use super::*;

    fn intent(was_active: bool, was_playing: bool) -> RecoveryIntent {
        RecoveryIntent {
            was_active,
            was_playing,
            track_id: Some("4uLU6hMCjMI75M1A2tKUQC".to_owned()),
            session_id: "old-session".to_owned(),
            at: Instant::now(),
        }
    }

    fn conn() -> (String, String) {
        ("old-conn".to_owned(), "old-user".to_owned())
    }

    fn disconnected(id: &str) -> PlayerEvent {
        PlayerEvent::SessionDisconnected {
            connection_id: id.to_owned(),
            user_name: "user".to_owned(),
        }
    }

    fn connection_id_of(e: &PlayerEvent) -> Option<String> {
        match e {
            PlayerEvent::SessionDisconnected { connection_id, .. } => Some(connection_id.clone()),
            _ => None,
        }
    }

    // --- suppress_for_recovery ------------------------------------------

    /// D-08: while a recovery runs, the session end is not forwarded.
    #[test]
    fn suppress_for_recovery_hides_disconnect_while_recovering() {
        assert!(suppress_for_recovery(EventKind::SessionDisconnected, true, false));
    }

    /// The Spirc task noticed the loss before the poll did: the session is
    /// invalid at event time, which covers it without a recovering flag.
    #[test]
    fn suppress_for_recovery_hides_disconnect_on_invalid_session() {
        assert!(suppress_for_recovery(EventKind::SessionDisconnected, false, true));
    }

    /// A valid session and no recovery: the honest end, forwarded as
    /// `stop inactive` (deselected in the app).
    #[test]
    fn suppress_for_recovery_forwards_disconnect_on_valid_session() {
        assert!(!suppress_for_recovery(EventKind::SessionDisconnected, false, false));
    }

    /// The pause the wake-up command causes (and the Stopped of the old
    /// Spirc) never reach LMS as `stop` while recovering.
    #[test]
    fn suppress_for_recovery_hides_paused_and_stopped_while_recovering() {
        for invalid in [false, true] {
            assert!(suppress_for_recovery(EventKind::Paused, true, invalid));
            assert!(suppress_for_recovery(EventKind::Stopped, true, invalid));
        }
    }

    /// TrackChanged and Playing are the takeover's own progress and must pass.
    #[test]
    fn suppress_for_recovery_forwards_track_and_playing() {
        for invalid in [false, true] {
            assert!(!suppress_for_recovery(EventKind::TrackChanged, true, invalid));
            assert!(!suppress_for_recovery(EventKind::Playing, true, invalid));
        }
    }

    /// Outside a recovery a plain pause is the user's pause.
    #[test]
    fn suppress_for_recovery_forwards_paused_when_not_recovering() {
        assert!(!suppress_for_recovery(EventKind::Paused, false, false));
        assert!(!suppress_for_recovery(EventKind::Stopped, false, false));
    }

    // --- recovery_plan ---------------------------------------------------

    /// D-09: a device that was not active never gets a transfer or a play,
    /// whatever else holds (it could adopt a foreign playing state).
    #[test]
    fn recovery_plan_inactive_at_loss_is_always_quiet() {
        for playing in [false, true] {
            for active_after in [false, true] {
                for age in [0u64, 5, 29, 30, 45] {
                    assert_eq!(
                        recovery_plan(&intent(false, playing), active_after, Duration::from_secs(age)),
                        RecoveryStep::Quiet,
                        "was_active=false playing={playing} active_after={active_after} age={age}"
                    );
                }
            }
        }
    }

    /// Takeover already happened and it was playing: play, at any age.
    #[test]
    fn recovery_plan_active_after_rebuild_and_playing_plays_at_any_age() {
        assert_eq!(
            recovery_plan(&intent(true, true), true, Duration::from_secs(2)),
            RecoveryStep::Play
        );
        assert_eq!(
            recovery_plan(&intent(true, true), true, Duration::from_secs(45)),
            RecoveryStep::Play,
            "a takeover that succeeded is never a give-up because of elapsed time"
        );
    }

    /// Takeover happened, it was paused: quiet, never GiveUp (age 45 s).
    #[test]
    fn recovery_plan_active_after_rebuild_and_paused_is_quiet_at_any_age() {
        assert_eq!(
            recovery_plan(&intent(true, false), true, Duration::from_secs(2)),
            RecoveryStep::Quiet
        );
        assert_eq!(
            recovery_plan(&intent(true, false), true, Duration::from_secs(45)),
            RecoveryStep::Quiet
        );
    }

    /// Not active after the rebuild and the age limit reached: give up.
    #[test]
    fn recovery_plan_not_active_at_age_limit_gives_up() {
        assert_eq!(
            recovery_plan(&intent(true, true), false, Duration::from_secs(30)),
            RecoveryStep::GiveUp
        );
        assert_eq!(
            recovery_plan(&intent(true, false), false, Duration::from_secs(60)),
            RecoveryStep::GiveUp
        );
    }

    /// Not active, young enough: one transfer, then play only if it was playing.
    #[test]
    fn recovery_plan_not_active_young_transfers() {
        assert_eq!(
            recovery_plan(&intent(true, true), false, Duration::from_secs(29)),
            RecoveryStep::TransferThenPlay
        );
        assert_eq!(
            recovery_plan(&intent(true, false), false, Duration::from_secs(4)),
            RecoveryStep::TransferOnly
        );
    }

    /// D-09: a session that was paused at the loss never yields Play or
    /// TransferThenPlay, in any cell.
    #[test]
    fn recovery_plan_paused_at_loss_never_plays() {
        for was_active in [false, true] {
            for active_after in [false, true] {
                for age in [0u64, 3, 29, 30, 45] {
                    let step = recovery_plan(&intent(was_active, false), active_after, Duration::from_secs(age));
                    assert!(
                        step != RecoveryStep::Play && step != RecoveryStep::TransferThenPlay,
                        "paused at loss must not play: was_active={was_active} active_after={active_after} age={age} -> {step:?}"
                    );
                }
            }
        }
    }

    // --- held_event_after_recovery ----------------------------------------

    /// Recovered: the session continues, the held end is dropped.
    #[test]
    fn held_event_after_recovery_drops_held_disconnect_when_recovered() {
        assert!(held_event_after_recovery(RecoveryOutcome::Recovered, Some(disconnected("held")), &conn()).is_none());
        assert!(held_event_after_recovery(RecoveryOutcome::Recovered, None, &conn()).is_none());
    }

    /// Failed / GaveUp with the end held: that very event is replayed.
    #[test]
    fn held_event_after_recovery_replays_held_disconnect_on_failure() {
        for outcome in [RecoveryOutcome::Failed, RecoveryOutcome::GaveUp] {
            let got = held_event_after_recovery(outcome, Some(disconnected("held")), &conn());
            assert_eq!(got.as_ref().and_then(connection_id_of).as_deref(), Some("held"), "{outcome:?}");
        }
    }

    /// Failed / GaveUp with nothing held: a SessionDisconnected built from the
    /// old session's connection id, so the ordinary arm still ends the session.
    #[test]
    fn held_event_after_recovery_builds_disconnect_when_nothing_held() {
        for outcome in [RecoveryOutcome::Failed, RecoveryOutcome::GaveUp] {
            let got = held_event_after_recovery(outcome, None, &conn());
            assert_eq!(got.as_ref().and_then(connection_id_of).as_deref(), Some("old-conn"), "{outcome:?}");
        }
    }

    /// A held event that is not a SessionDisconnected is never replayed; the
    /// replayed disconnect's `stop inactive` pauses LMS anyway.
    #[test]
    fn held_event_after_recovery_never_replays_a_held_pause() {
        let stopped = || PlayerEvent::Stopped {
            play_request_id: 1,
            track_id: librespot_core::spotify_uri::SpotifyUri::from_uri("spotify:track:4uLU6hMCjMI75M1A2tKUQC")
                .expect("valid track uri"),
        };
        let held = stopped();
        let got = held_event_after_recovery(RecoveryOutcome::Failed, Some(held), &conn());
        assert_eq!(got.as_ref().and_then(connection_id_of).as_deref(), Some("old-conn"));
        let held = stopped();
        assert!(held_event_after_recovery(RecoveryOutcome::Recovered, Some(held), &conn()).is_none());
    }

    // --- loss_poll_fires ---------------------------------------------------

    /// Round-3 finding: the poll must fire ONCE per loss. A running recovery
    /// (or the reconnect arm) is never restarted, its intent and `at` stay.
    #[test]
    fn loss_poll_fires_only_for_an_idle_invalid_session() {
        assert!(loss_poll_fires(false, false, true));
        assert!(!loss_poll_fires(false, true, true), "a running recovery is not restarted");
        assert!(!loss_poll_fires(true, false, true), "the reconnect arm already runs");
        assert!(!loss_poll_fires(true, true, true));
        assert!(!loss_poll_fires(false, false, false), "a valid session is no loss");
        assert!(!loss_poll_fires(false, true, false));
    }

    // --- RecoveryShared / recovery_wake_stuck ------------------------------

    /// finish(Recovered) opens the settle window and clears `recovering`; the
    /// outcome reaches the dispatcher side with its ack handle.
    #[tokio::test]
    async fn shared_finish_recovered_opens_window_and_clears_flag() {
        let rs = RecoveryShared::new(true);
        rs.recovering.store(true, Ordering::Release);
        let mut ack = rs.finish(RecoveryOutcome::Recovered);
        assert!(!rs.is_recovering());
        let until = rs.settle_until().expect("settle window opened");
        assert!(until > Instant::now() + Duration::from_secs(10), "RECOVERY_SETTLE is 15 s");
        let (outcome, tx) = rs.next_outcome().await;
        assert_eq!(outcome, RecoveryOutcome::Recovered);
        assert!(ack.try_recv().is_err(), "not acknowledged before the dispatcher acted");
        drop(AckOnDrop(Some(tx)));
        assert!(ack.await.is_ok(), "the ack fires when the dispatcher side drops its guard");
    }

    /// 88 review WR-09: `RecoveryShared` owns BOTH halves of the outcome channel
    /// and nothing closes the receiver, so the channel cannot close while the
    /// shared state exists. With nothing queued `next_outcome` waits (it never
    /// reports a closed channel), and every outcome `finish` hands over arrives.
    #[tokio::test]
    async fn outcome_channel_stays_open_for_the_life_of_the_shared_state() {
        let rs = RecoveryShared::new(true);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), rs.next_outcome()).await.is_err(),
            "an empty channel is a wait, not an end"
        );
        for outcome in [RecoveryOutcome::Failed, RecoveryOutcome::GaveUp, RecoveryOutcome::Recovered] {
            rs.recovering.store(true, Ordering::Release);
            let _ack = rs.finish(outcome);
            let (got, _tx) = rs.next_outcome().await;
            assert_eq!(got, outcome);
        }
    }

    /// finish(Failed) opens no window; without LMS nothing consumes outcomes, so
    /// the ack is already fired (the shutdown wait must not run into its bound).
    #[tokio::test]
    async fn shared_finish_failed_without_lms_is_acked_at_once() {
        let rs = RecoveryShared::new(false);
        rs.recovering.store(true, Ordering::Release);
        let ack = rs.finish(RecoveryOutcome::Failed);
        assert!(rs.settle_until().is_none());
        assert!(!rs.is_recovering());
        assert!(ack.await.is_ok());
    }

    /// Only a held SessionDisconnected is kept; a held pause is dropped.
    #[test]
    fn shared_hold_keeps_only_the_disconnect() {
        let rs = RecoveryShared::new(true);
        rs.hold(&PlayerEvent::Stopped {
            play_request_id: 1,
            track_id: librespot_core::spotify_uri::SpotifyUri::from_uri("spotify:track:4uLU6hMCjMI75M1A2tKUQC")
                .expect("valid track uri"),
        });
        assert!(rs.take_held().is_none());
        rs.hold(&disconnected("held"));
        assert_eq!(rs.take_held().as_ref().and_then(connection_id_of).as_deref(), Some("held"));
        assert!(rs.take_held().is_none(), "taking consumes the hold");
    }

    /// Round-4 safety net: a Spirc that never leaves after the wake-up is
    /// forced after RECOVERY_WAKE_TIMEOUT, never earlier, never when idle.
    #[test]
    fn recovery_wake_stuck_only_after_timeout_while_waiting() {
        assert!(!recovery_wake_stuck(true, false, Duration::from_secs(9)));
        assert!(recovery_wake_stuck(true, false, RECOVERY_WAKE_TIMEOUT));
        assert!(!recovery_wake_stuck(true, true, Duration::from_secs(60)), "the rebuild already runs");
        assert!(!recovery_wake_stuck(false, false, Duration::from_secs(60)), "no recovery, nothing to force");
    }

    // --- deliberate session end / active snapshot (88 review WR-06) --------

    /// The Spirc-task-ended arm shuts a still VALID session down on purpose
    /// (Spirc ended after a Browse preemption or an internal error). That end
    /// must be marked deliberate like the other two (ZeroConf rotation,
    /// Browse-triggered reconnect): otherwise the dispatcher reads the old
    /// Spirc's SessionDisconnected as an AP drop (invalid session, not
    /// deliberate), holds it and discards it - LMS never gets `stop inactive`
    /// and keeps the claim.
    #[tokio::test]
    async fn ending_a_valid_session_is_marked_deliberate() {
        let rs = RecoveryShared::new(true);
        let session = Session::new(SessionConfig::default(), None);
        assert!(!session.is_invalid());
        assert!(end_valid_session_on_purpose(&rs, &session));
        assert!(session.is_invalid(), "the session is shut down");
        assert!(rs.deliberate.load(Ordering::Acquire), "... and the end is deliberate");
        // what the dispatcher derives from it: not part of an AP drop, so forwarded
        let ap_drop = !rs.deliberate.load(Ordering::Acquire) && session.is_invalid();
        assert!(!suppress_for_recovery(EventKind::SessionDisconnected, rs.is_recovering(), ap_drop));
    }

    /// A session that is ALREADY invalid when the Spirc task ends is the AP drop
    /// itself: nothing is shut down and nothing is marked, the recovery keeps
    /// holding the session end back.
    #[tokio::test]
    async fn an_already_lost_session_is_not_marked_deliberate() {
        let rs = RecoveryShared::new(true);
        let session = Session::new(SessionConfig::default(), None);
        session.shutdown();
        assert!(!end_valid_session_on_purpose(&rs, &session));
        assert!(!rs.deliberate.load(Ordering::Acquire));
        let ap_drop = !rs.deliberate.load(Ordering::Acquire) && session.is_invalid();
        assert!(suppress_for_recovery(EventKind::SessionDisconnected, false, ap_drop));
    }

    /// The main loop and the HTTP handler take the device off the session on
    /// purpose in four places. Each cleared only `spirc_active`; the snapshot
    /// (kept on purpose by a SUPPRESSED SessionDisconnected) stayed set when the
    /// disconnect event was suppressed or never emitted (the Browse-triggered arm
    /// aborts the Spirc task). The next loss then read `was_active`, carried the
    /// old session id over and could `transfer(None)` for a device that was not
    /// active (D-09, T-88-09).
    #[test]
    fn deliberate_inactive_clears_the_snapshot_too() {
        let rs = RecoveryShared::new(true);
        let flag = AtomicBool::new(true);
        rs.active_snapshot.store(true, Ordering::SeqCst);
        assert!(was_active_at_loss(&flag, &rs));

        // the old code: only the flag - the stale snapshot still reads "was active"
        flag.store(false, Ordering::SeqCst);
        assert!(was_active_at_loss(&flag, &rs), "the stale snapshot alone reads as active");

        // the fix: both
        flag.store(true, Ordering::SeqCst);
        rs.clear_active(&flag);
        assert!(!flag.load(Ordering::Acquire));
        assert!(!was_active_at_loss(&flag, &rs), "a device taken off on purpose was not active at a later loss");
    }

    /// A suppressed SessionDisconnected (the Spirc task noticed the loss before
    /// the poll) still keeps the snapshot: that is what it exists for.
    #[test]
    fn snapshot_alone_still_counts_as_active_at_the_loss() {
        let rs = RecoveryShared::new(true);
        let flag = AtomicBool::new(false);
        rs.active_snapshot.store(true, Ordering::SeqCst);
        assert!(was_active_at_loss(&flag, &rs));
        rs.active_snapshot.store(false, Ordering::SeqCst);
        assert!(!was_active_at_loss(&flag, &rs));
    }

    /// Wiring guard: the four deliberate sites (HTTP Browse preemption, ZeroConf
    /// rotation, Browse-triggered reconnect, Spirc-task-ended arm) clear flag AND
    /// snapshot, and the Spirc-task-ended arm ends its session through the
    /// deliberate marker.
    #[test]
    fn deliberate_sites_are_wired() {
        let src = include_str!("unified.rs");
        let production = src.split("#[cfg(test)]").next().expect("production part");
        assert_eq!(production.matches("recovery_shared.clear_active(&spirc_active)").count(), 4);
        assert_eq!(production.matches("end_valid_session_on_purpose(&recovery_shared, &session_cur)").count(), 1);
        assert_eq!(production.matches("was_active_at_loss(spirc_active, rs)").count(), 1);
    }

    // --- mark_inactive_for_rebuild (88 review WR-02) ------------------------

    /// The two shortcuts into the rebuild bypass the Spirc-task-ended arm, so the
    /// activity flag of the session that was lost is still set (a Spirc stuck in
    /// `handle_disconnect` never emitted its SessionDisconnected). Left set, the
    /// re-acquire reads "took over" at its first poll and plans `Play` for a
    /// rebuilt Spirc that is not active yet; the fork drops that command. Cleared,
    /// the re-acquire waits for the takeover and, without one, takes the transfer
    /// path.
    #[tokio::test]
    async fn forced_rebuild_does_not_report_a_takeover_that_has_not_happened() {
        let i = intent(true, true);
        let age = RECOVERY_WAKE_TIMEOUT + Duration::from_secs(1);

        // what the stale flag did: Play at once, before any takeover
        let stale = AtomicBool::new(true);
        assert!(wait_active(&stale, Duration::from_millis(60)).await);
        assert_eq!(recovery_plan(&i, true, age), RecoveryStep::Play);

        // the shortcut clears it: no takeover is seen until the rebuilt Spirc reports one
        let flag = AtomicBool::new(true);
        mark_inactive_for_rebuild(&flag);
        assert!(!flag.load(Ordering::Acquire));
        let seen = wait_active(&flag, Duration::from_millis(60)).await;
        assert!(!seen, "no takeover before the rebuilt Spirc is active");
        assert_eq!(recovery_plan(&i, seen, age), RecoveryStep::TransferThenPlay);

        // a takeover that arrives during the wait is still seen
        let flag = Arc::new(AtomicBool::new(true));
        mark_inactive_for_rebuild(&flag);
        let setter = Arc::clone(&flag);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(80)).await;
            setter.store(true, Ordering::SeqCst);
        });
        assert!(wait_active(&flag, Duration::from_secs(2)).await);
    }

    /// Wiring guard: both shortcuts into the rebuild (no Spirc to wake, the
    /// forced rebuild of a stuck Spirc) must clear the flag: the definition and
    /// the two call sites in the production part of this file.
    #[test]
    fn both_rebuild_shortcuts_clear_the_activity_flag() {
        let src = include_str!("unified.rs");
        let production = src.split("#[cfg(test)]").next().expect("production part");
        assert_eq!(production.matches("mark_inactive_for_rebuild(").count(), 3);
    }

    // --- suppress_after_recovery -------------------------------------------

    /// The takeover loads paused (D-09): inside the window Paused and Stopped
    /// stay away from LMS - for the play case and the idle case alike.
    #[test]
    fn suppress_after_recovery_hides_pause_inside_window() {
        let now = Instant::now();
        let until = Some(now + Duration::from_secs(10));
        assert!(suppress_after_recovery(EventKind::Paused, until, now));
        assert!(suppress_after_recovery(EventKind::Stopped, until, now));
    }

    /// Playing is never suppressed (the caller ends the window on it).
    #[test]
    fn suppress_after_recovery_never_hides_playing() {
        let now = Instant::now();
        let until = Some(now + Duration::from_secs(10));
        assert!(!suppress_after_recovery(EventKind::Playing, until, now));
        assert!(!suppress_after_recovery(EventKind::TrackChanged, until, now));
    }

    /// A pause after the window is the user's.
    #[test]
    fn suppress_after_recovery_forwards_pause_after_window() {
        let now = Instant::now();
        let until = Some(now);
        assert!(!suppress_after_recovery(EventKind::Paused, until, now), "now >= settle_until");
        assert!(!suppress_after_recovery(EventKind::Paused, until, now + Duration::from_secs(1)));
    }

    /// No window open: nothing is suppressed.
    #[test]
    fn suppress_after_recovery_without_window_hides_nothing() {
        let now = Instant::now();
        assert!(!suppress_after_recovery(EventKind::Paused, None, now));
        assert!(!suppress_after_recovery(EventKind::Stopped, None, now));
    }

    /// A new drop inside the window is an honest end or a new recovery, never
    /// hidden by the window.
    #[test]
    fn suppress_after_recovery_never_hides_a_new_disconnect() {
        let now = Instant::now();
        let until = Some(now + Duration::from_secs(10));
        assert!(!suppress_after_recovery(EventKind::SessionDisconnected, until, now));
    }

    // --- suppress_takeover_announce (GH #207, 88-08 finding 1, V4) ---------

    /// The live shape of run 88-gh207-play-exploratory-flac-261117-0033: the
    /// takeover's `TrackChanged` (relinked id) arrives while the recovery still
    /// runs - the daemon log has it BEFORE `recovered in 810 ms`.
    #[test]
    fn takeover_announce_is_held_while_recovering() {
        let now = Instant::now();
        assert!(suppress_takeover_announce(EventKind::TrackChanged, true, None, now, true));
    }

    /// Same event landing just after `finish(Recovered)` opened the settle window.
    #[test]
    fn takeover_announce_is_held_inside_the_settle_window() {
        let now = Instant::now();
        let until = Some(now + Duration::from_secs(10));
        assert!(suppress_takeover_announce(EventKind::TrackChanged, false, until, now, true));
    }

    /// Outside a recovery and its window a `TrackChanged` is an ordinary title
    /// change (or a re-announce after a user action) and reaches LMS.
    #[test]
    fn takeover_announce_is_forwarded_outside_recovery_and_window() {
        let now = Instant::now();
        assert!(!suppress_takeover_announce(EventKind::TrackChanged, false, None, now, true));
        // an expired window is no window (now >= settle_until)
        assert!(!suppress_takeover_announce(EventKind::TrackChanged, false, Some(now), now, true));
        assert!(!suppress_takeover_announce(
            EventKind::TrackChanged,
            false,
            Some(now),
            now + Duration::from_secs(1),
            true
        ));
    }

    /// No cursor = no session the takeover could re-announce: the `TrackChanged`
    /// is a session start (None -> Some, `start` to LMS) and must reach it, also
    /// inside the window of a Quiet recovery of a device that was not active.
    #[test]
    fn takeover_announce_without_cursor_is_a_session_start_and_forwarded() {
        let now = Instant::now();
        let until = Some(now + Duration::from_secs(10));
        assert!(!suppress_takeover_announce(EventKind::TrackChanged, true, None, now, false));
        assert!(!suppress_takeover_announce(EventKind::TrackChanged, false, until, now, false));
    }

    /// Only `TrackChanged` is held. Playing carries the restored position and
    /// ends the window (caller); Paused/Stopped have their own gates; a new
    /// SessionDisconnected is never hidden.
    #[test]
    fn takeover_announce_never_holds_other_events() {
        let now = Instant::now();
        let until = Some(now + Duration::from_secs(10));
        for kind in [
            EventKind::Playing,
            EventKind::Paused,
            EventKind::Stopped,
            EventKind::SessionDisconnected,
            EventKind::Other,
        ] {
            assert!(!suppress_takeover_announce(kind, true, until, now, true), "{kind:?} while recovering");
            assert!(!suppress_takeover_announce(kind, false, until, now, true), "{kind:?} in window");
        }
    }

    /// Wiring guard: the decision function is only worth anything if BOTH
    /// dispatcher copies (the initial one and the respawn copy) call it. The
    /// production part of this file must name it exactly three times: the
    /// definition and the two call sites. (A unit test cannot reach the dispatcher
    /// closures; the live rig row gh207 play, V4, is the end-to-end check.)
    #[test]
    fn takeover_announce_gate_is_wired_into_both_dispatchers() {
        let src = include_str!("unified.rs");
        let production = src.split("#[cfg(test)]").next().expect("production part");
        let calls = production.matches("suppress_takeover_announce(").count();
        assert_eq!(calls, 3, "definition + initial dispatcher + respawn dispatcher");
    }
}

// -------------------------------------------------------------------------
// Damping, 503 while recovering, ack before abort (GH #207, D-07/D-08)
// -------------------------------------------------------------------------

#[cfg(test)]
mod recovery_damping_tests {
    use super::*;

    /// D-08 "Play from LMS works again (no 409)": a recovering helper answers
    /// 503 for every transport/volume/seek command, never 409, whatever the
    /// activity flag says (the old Spirc is being woken, the new one is not up).
    #[test]
    fn control_status_is_503_while_recovering() {
        for cmd in ["pause", "play", "next", "prev", "volume", "seek"] {
            for active in [false, true] {
                for present in [false, true] {
                    let st = control_status(true, active, present, cmd);
                    assert_eq!(st, StatusCode::SERVICE_UNAVAILABLE, "{cmd} active={active} present={present}");
                    assert_ne!(st, StatusCode::CONFLICT);
                }
            }
        }
        // An unknown command stays a 404 even while recovering.
        assert_eq!(control_status(true, true, false, "bogus"), StatusCode::NOT_FOUND);
    }

    /// The transfer-back is refused with 503 (Retry-After 2 added by the
    /// caller) while recovering, whatever the handle and the rate limit say.
    #[test]
    fn transfer_is_503_while_recovering() {
        assert_eq!(transfer_status(true, true, None), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(
            transfer_status(true, true, Some(Duration::from_secs(60))),
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(transfer_status(true, false, None), StatusCode::SERVICE_UNAVAILABLE);
        // Outside a recovery the old mapping is unchanged.
        assert_eq!(transfer_status(false, true, None), StatusCode::NO_CONTENT);
    }

    /// Fable item 6: a failed Spirc::new on the recovery path is retried after
    /// 1, 2, 4 s, then the schedule ends (the Perl backoff takes over).
    #[test]
    fn recovery_retry_delay_is_1_2_4_then_ends() {
        assert_eq!(recovery_retry_delay(0), Some(Duration::from_secs(1)));
        assert_eq!(recovery_retry_delay(1), Some(Duration::from_secs(2)));
        assert_eq!(recovery_retry_delay(2), Some(Duration::from_secs(4)));
        assert_eq!(recovery_retry_delay(3), None);
        assert_eq!(recovery_retry_delay(100), None);
    }

    // --- bounded_rebuild (88 review WR-03) ---------------------------------

    /// A rebuild that never returns (an AP that completes the handshake and then
    /// goes quiet: `connection::authenticate` has no timeout) ends as an ordinary
    /// failed attempt after the limit. The outer 2 s timeout turns an unbounded
    /// wait into a failure, not a hang.
    #[tokio::test]
    async fn bounded_rebuild_turns_a_hang_into_a_failed_attempt() {
        let t0 = Instant::now();
        let hang = std::future::pending::<Result<u8, librespot_core::Error>>();
        let r = tokio::time::timeout(
            Duration::from_secs(2),
            bounded_rebuild(hang, Some(Duration::from_millis(200))),
        )
        .await
        .expect("the rebuild attempt must be bounded");
        let waited = t0.elapsed();
        let err = r.expect_err("an elapsed limit is a failed attempt");
        assert!(err.to_string().contains("timed out"), "reason names the timeout: {err}");
        assert!(
            waited >= Duration::from_millis(150) && waited < Duration::from_secs(1),
            "failed after {waited:?}, expected about 200 ms"
        );
    }

    /// Inside the limit the attempt's own result passes through unchanged.
    #[tokio::test]
    async fn bounded_rebuild_passes_the_attempts_own_result_through() {
        let ok = async { Ok::<u8, librespot_core::Error>(7) };
        assert_eq!(bounded_rebuild(ok, Some(Duration::from_secs(5))).await.expect("ok"), 7);
        let failed = async { Err::<u8, _>(librespot_core::Error::unavailable("ap refused")) };
        let err = bounded_rebuild(failed, Some(Duration::from_secs(5))).await.expect_err("err");
        assert!(err.to_string().contains("ap refused"), "the attempt's own error: {err}");
    }

    /// No limit (the ZeroConf / Browse-triggered reconnect, where `recovering`
    /// is not set and the Perl health restart stays armed): today's unbounded
    /// await, unchanged.
    #[tokio::test]
    async fn bounded_rebuild_without_a_limit_is_todays_await() {
        let slow = async {
            tokio::time::sleep(Duration::from_millis(120)).await;
            Ok::<u8, librespot_core::Error>(3)
        };
        assert_eq!(bounded_rebuild(slow, None).await.expect("ok"), 3);
    }

    /// The limit must not cut the fork's own access-point rotation short
    /// (Session::connect: 6 access points, 5 s connect timeout each): a new
    /// Session starts that rotation over, so a shorter limit could never get past
    /// the same dead access points. And only the recovery path is bounded.
    #[test]
    fn rebuild_limit_covers_the_ap_rotation_and_only_the_recovery_path() {
        assert!(RECOVERY_SPIRC_NEW_TIMEOUT >= Duration::from_secs(6 * 5));
        assert_eq!(rebuild_limit(true), Some(RECOVERY_SPIRC_NEW_TIMEOUT));
        assert_eq!(rebuild_limit(false), None);
    }

    /// Wiring guard: the recovery rebuild (`Spirc::new` in the reconnect arm of
    /// the Connect main loop) goes through `bounded_rebuild` with the limit of
    /// `rebuild_limit`: one call site each in the production part of this file
    /// (the generic definition reads `bounded_rebuild<T, F>(` and is not counted).
    #[test]
    fn recovery_rebuild_is_wired_through_the_bound() {
        let src = include_str!("unified.rs");
        let production = src.split("#[cfg(test)]").next().expect("production part");
        assert_eq!(production.matches("match bounded_rebuild(").count(), 1);
        assert_eq!(production.matches("= rebuild_limit(recovery.is_some())").count(), 1);
    }

    /// The wait returns when the dispatcher acks (after about 100 ms), so the
    /// caller may abort the dispatcher only after the replay was delivered.
    #[tokio::test]
    async fn outcome_ack_awaited_before_abort() {
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            let _ = tx.send(());
        });
        let t0 = Instant::now();
        let r = await_outcome_ack(rx, OUTCOME_ACK_TIMEOUT).await;
        let waited = t0.elapsed();
        assert_eq!(r, AckResult::Acked);
        assert!(
            waited >= Duration::from_millis(80) && waited < Duration::from_secs(2),
            "returned after {waited:?}, expected about 100 ms"
        );
    }

    /// The wait is bounded: a sender that never acks (kept alive) times out
    /// after about the given bound; a dropped sender returns at once. The
    /// outer 2 s timeout turns an unbounded wait into a failure, not a hang.
    #[tokio::test]
    async fn outcome_ack_wait_is_bounded() {
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let t0 = Instant::now();
        let r = tokio::time::timeout(Duration::from_secs(2), await_outcome_ack(rx, Duration::from_millis(200)))
            .await
            .expect("the wait must be bounded");
        let waited = t0.elapsed();
        assert_eq!(r, AckResult::TimedOut);
        assert!(
            waited >= Duration::from_millis(150) && waited < Duration::from_secs(1),
            "timed out after {waited:?}, expected about 200 ms"
        );
        drop(tx);

        let (tx2, rx2) = tokio::sync::oneshot::channel::<()>();
        drop(tx2);
        let t1 = Instant::now();
        let r2 = tokio::time::timeout(Duration::from_secs(2), await_outcome_ack(rx2, Duration::from_secs(6)))
            .await
            .expect("a dropped sender must not hang");
        assert_eq!(r2, AckResult::Dropped);
        assert!(t1.elapsed() < Duration::from_millis(500), "a dropped sender returns at once");
    }
}

// ---------------------------------------------------------------------------
// 89-09 (ACC-02): what a Browse title request is answered.
//
// Moved here from the debug session 89-refused-track-plays-silent (2026-11-19, module
// dbg89_refused_track_plays_silent of a scratch copy). The cells drive the REAL
// unified_http_server, the REAL serve_track_request and the REAL fork Player. The only
// stand-in is the upstream: the session's HTTP proxy points at a local listener that
// holds every connection `stall` long and then drops it, so the Player's load fails
// (PlayerEvent::Unavailable -> StatusCode::NOT_FOUND on the status channel) after about
// `stall`. That stands for the network-bound load in front of the verdict
// (extended-metadata, storage-resolve, file head, key round trip). The verdict comes from
// a failed metadata load, not from a refused key; the handler sees the same NOT_FOUND on
// the same channel in both cases (the session has 0 refused keys, so these 404s count
// toward the reconnect).
//
// On the code before 89-09 the handler answered `200 OK` 500 ms after the request
// whenever the verdict was not in yet, and the body then ended with 0 bytes: LMS started
// that empty stream as a short track (run 89-05 of 2026-11-19 12:22, a player silent for
// 275 s).
// ---------------------------------------------------------------------------
#[cfg(test)]
mod browse_title_answer_tests {
    use super::*;
    use std::net::SocketAddr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// The time a request waits for the Player's first signal before it gives up. Written
    /// out here on purpose: the cell below measures the real wait against it.
    const EXPECTED_BOUND: Duration = Duration::from_secs(10);

    /// Local stand-in for everything upstream of the helper. It runs on plain threads, not
    /// on the cell's runtime: a load that is still held when a cell ends has to be let go by
    /// the clock, not by a runtime that is already shutting down (dropping a Player waits
    /// for its load).
    fn stalled_upstream(stall: Duration) -> SocketAddr {
        let l = std::net::TcpListener::bind("127.0.0.1:0").expect("bind upstream");
        let addr = l.local_addr().expect("upstream addr");
        std::thread::spawn(move || {
            for sock in l.incoming() {
                let Ok(sock) = sock else { break };
                std::thread::spawn(move || {
                    std::thread::sleep(stall);
                    drop(sock);
                });
            }
        });
        addr
    }

    struct Helper {
        addr: SocketAddr,
        /// The handler's count of consecutive Browse failures (2 trigger a session reconnect).
        fails: Arc<AtomicU32>,
        /// The Connect takeover signal (D-09): notifying it aborts a running serve task.
        cancel: Arc<tokio::sync::Notify>,
        _shutdown: tokio::sync::oneshot::Sender<()>,
    }

    /// The helper's HTTP server exactly as the Browse-only arm of run_unified starts it
    /// (enable_connect = false), passthrough on (the rig's vm-flac player is served audio/ogg).
    async fn start_helper(upstream: SocketAddr) -> Helper {
        let config = SessionConfig {
            proxy: Some(format!("http://{upstream}").parse().expect("proxy url")),
            ..SessionConfig::default()
        };
        let session = Session::new(config, None);
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind helper");
        let addr = listener.local_addr().expect("helper addr");
        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let fails = Arc::new(AtomicU32::new(0));
        let cancel = Arc::new(tokio::sync::Notify::new());
        tokio::spawn(unified_http_server(
            listener,
            Arc::new(tokio::sync::Mutex::new(session)),
            Arc::new(AtomicBool::new(false)),
            Arc::new(std::sync::Mutex::new(None)),
            Arc::new(tokio::sync::Mutex::new(ActiveMode::Idle)),
            Arc::clone(&cancel),
            false,
            None,
            None,
            shutdown_rx,
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicU64::new(0)),
            Arc::new(tokio::sync::Notify::new()),
            Arc::new(AtomicBool::new(false)),
            Arc::clone(&fails),
            Arc::new(std::sync::Mutex::new(Instant::now())),
            Arc::new(std::sync::Mutex::new(Instant::now())),
            true,
            None,
            None,
            None,
            None,
            None,
            Bitrate::Bitrate320,
            false,
            None,
            Arc::new(TransferState::default()),
            Arc::new(RecoveryShared::new(false)),
        ));
        Helper { addr, fails, cancel, _shutdown: shutdown_tx }
    }

    struct Answer {
        status_line: String,
        headers_after: Duration,
        body_len: usize,
        /// None when the body was still open after `body_wait`.
        eof_after: Option<Duration>,
    }

    /// One GET as squeezelite sends it (run 1222, squeezelite-flac.log). Reads the header
    /// block, then the body until EOF or until `body_wait` has passed since the headers.
    async fn get(helper: SocketAddr, path: &str, body_wait: Duration) -> Answer {
        let mut s = tokio::net::TcpStream::connect(helper).await.expect("connect helper");
        let t0 = Instant::now();
        let req = format!(
            "GET {path} HTTP/1.0\r\nAccept: */*\r\nCache-Control: no-cache\r\nConnection: close\r\nHost: {helper}\r\n\r\n"
        );
        s.write_all(req.as_bytes()).await.expect("send request");
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        let mut headers_after = None;
        let mut head_len = 0usize;
        let mut eof_after = None;
        loop {
            let limit = match headers_after {
                None => Duration::from_secs(30),
                Some(_) => body_wait,
            };
            let n = match tokio::time::timeout(limit, s.read(&mut chunk)).await {
                Ok(n) => n.expect("read answer"),
                Err(_) => {
                    assert!(headers_after.is_some(), "no header block from the helper within 30 s");
                    break;
                }
            };
            if n == 0 {
                eof_after = Some(t0.elapsed());
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
            if headers_after.is_none() {
                if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    headers_after = Some(t0.elapsed());
                    head_len = p + 4;
                }
            }
        }
        let text = String::from_utf8_lossy(&buf).to_string();
        Answer {
            status_line: text.lines().next().unwrap_or("").to_string(),
            headers_after: headers_after.expect("no complete header block"),
            body_len: buf.len() - head_len,
            eof_after,
        }
    }

    /// One title request against a helper whose upstream lets the load fail after `stall_ms`.
    async fn cell(stall_ms: u64, body_wait: Duration) -> (Answer, Helper) {
        let upstream = stalled_upstream(Duration::from_millis(stall_ms));
        let helper = start_helper(upstream).await;
        let a = get(helper.addr, "/track/1111111111111111111111", body_wait).await;
        eprintln!(
            "BROWSE-ANSWER cell stall_ms={stall_ms} status_line={:?} headers_after_ms={} body_len={} eof_after_ms={} consecutive_fails={}",
            a.status_line,
            a.headers_after.as_millis(),
            a.body_len,
            a.eof_after.map(|d| d.as_millis().to_string()).unwrap_or_else(|| "open".into()),
            helper.fails.load(Ordering::SeqCst)
        );
        (a, helper)
    }

    fn assert_404_for_a_judged_title(a: &Answer, helper: &Helper, stall_ms: u64) {
        assert!(
            a.status_line.contains(" 404 "),
            "a title the Player judged unavailable {stall_ms} ms after the request was answered {:?} after {} ms, with a body of {} bytes",
            a.status_line, a.headers_after.as_millis(), a.body_len
        );
        assert_eq!(a.body_len, 0, "a 404 carries no body");
        assert_eq!(
            helper.fails.load(Ordering::SeqCst), 1,
            "a 404 without a refused key counts once toward the reconnect, however late the verdict came"
        );
    }

    /// Control: the load fails at once. Passes before 89-09 too: it shows that this harness
    /// CAN read a 404 for a title the Player judges unavailable.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn control_a_title_judged_unavailable_at_once_is_answered_404() {
        let (a, helper) = cell(0, Duration::from_secs(20)).await;
        assert_404_for_a_judged_title(&a, &helper, 0);
    }

    /// Control: a load time as in 47 of the 48 field requests of 2026-11-19 (230 to 556 ms
    /// on the player's clock). Passes before 89-09 too (300 ms was inside the old window).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn control_a_title_judged_unavailable_after_300_ms_is_answered_404() {
        let (a, helper) = cell(300, Duration::from_secs(20)).await;
        assert_404_for_a_judged_title(&a, &helper, 300);
    }

    /// The edge: 700 ms was 200 ms past the old 500 ms window.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_title_judged_unavailable_after_700_ms_is_answered_404_not_an_empty_200() {
        let (a, helper) = cell(700, Duration::from_secs(20)).await;
        assert_404_for_a_judged_title(&a, &helper, 700);
    }

    /// The field case: run 1222, second request for title 0, verdict 1860 ms after the GET.
    /// The title is judged unavailable all the same, so the answer has to be the 404 the
    /// plugin's retry and skip handling is built on (ProtocolHandler handleDirectError).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_title_judged_unavailable_after_1860_ms_is_answered_404_not_an_empty_200() {
        let (a, helper) = cell(1860, Duration::from_secs(20)).await;
        assert_404_for_a_judged_title(&a, &helper, 1860);
    }

    /// No verdict and no audio: the upstream holds the load for 12 s. The request gives up
    /// at the bound with a 404 (never a 200 without audio), leaves the reconnect counter
    /// alone, and the helper keeps answering while the abandoned load is still running. One
    /// async worker on purpose: a give-up that waited for the load on a worker would stall
    /// the /health answer until the upstream lets go.
    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn a_title_without_a_verdict_is_answered_404_at_the_bound_not_200() {
        let upstream = stalled_upstream(Duration::from_secs(12));
        let helper = start_helper(upstream).await;
        helper.fails.store(1, Ordering::SeqCst);
        let a = get(helper.addr, "/track/1111111111111111111111", Duration::from_secs(1)).await;
        eprintln!(
            "BROWSE-ANSWER cell stall_ms=12000 status_line={:?} headers_after_ms={} body_len={} eof_after_ms={} consecutive_fails={}",
            a.status_line,
            a.headers_after.as_millis(),
            a.body_len,
            a.eof_after.map(|d| d.as_millis().to_string()).unwrap_or_else(|| "open".into()),
            helper.fails.load(Ordering::SeqCst)
        );
        assert!(
            a.status_line.contains(" 404 "),
            "a title without a verdict was answered {:?} after {} ms (a 200 without audio is an empty stream LMS starts as a short track)",
            a.status_line, a.headers_after.as_millis()
        );
        assert!(
            a.headers_after >= EXPECTED_BOUND - Duration::from_millis(500)
                && a.headers_after <= EXPECTED_BOUND + Duration::from_millis(1500),
            "the request gave up after {} ms, expected about {} ms",
            a.headers_after.as_millis(), EXPECTED_BOUND.as_millis()
        );
        assert_eq!(a.body_len, 0, "the give-up answer carries no body");
        assert_eq!(
            helper.fails.load(Ordering::SeqCst), 1,
            "a give-up says nothing about the session: the reconnect counter is neither raised nor reset"
        );
        let t = Instant::now();
        let h = get(helper.addr, "/health", Duration::from_secs(1)).await;
        let health_after = t.elapsed();
        eprintln!("BROWSE-ANSWER health status_line={:?} after_ms={}", h.status_line, health_after.as_millis());
        assert!(h.status_line.contains(" 200 "), "health status line: {:?}", h.status_line);
        assert!(
            health_after < Duration::from_secs(1),
            "the helper answered /health only after {} ms: the abandoned load was waited for on an async worker",
            health_after.as_millis()
        );
    }

    /// The one 200 without audio that stays (89-09 orchestrator decision W2): the serve task
    /// aborted by the Connect takeover listener (D-09, H13) before any audio and without a
    /// verdict. The request is answered `200` with a body that is already closed, never an
    /// error status: an error would make LMS ask for the next title, and that request would
    /// preempt the Connect session that just took over (D-10). Two workers: the abort drops
    /// the Player on a worker, which waits for the held load.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_takeover_abort_during_the_wait_is_answered_200_with_a_closed_body() {
        let upstream = stalled_upstream(Duration::from_secs(4));
        let helper = start_helper(upstream).await;
        let cancel = Arc::clone(&helper.cancel);
        // The listener of the cancel signal is spawned by the handler: give it time to
        // register before notifying (notify_waiters keeps no permit).
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(700)).await;
            cancel.notify_waiters();
        });
        let a = get(helper.addr, "/track/1111111111111111111111", Duration::from_secs(20)).await;
        eprintln!(
            "BROWSE-ANSWER cell takeover_abort status_line={:?} headers_after_ms={} body_len={} eof_after_ms={} consecutive_fails={}",
            a.status_line,
            a.headers_after.as_millis(),
            a.body_len,
            a.eof_after.map(|d| d.as_millis().to_string()).unwrap_or_else(|| "open".into()),
            helper.fails.load(Ordering::SeqCst)
        );
        assert!(
            a.status_line.contains(" 200 "),
            "a takeover abort was answered {:?} after {} ms: an error status makes LMS ask for the next title and preempt the Connect session (D-10)",
            a.status_line, a.headers_after.as_millis()
        );
        assert_eq!(a.body_len, 0, "the aborted serve task sent no audio");
        assert!(a.eof_after.is_some(), "the body of a takeover abort is closed, not left open");
        assert_eq!(helper.fails.load(Ordering::SeqCst), 0, "a takeover abort says nothing about the session: not counted");
    }
}

// ---------------------------------------------------------------------------
// 89-09 (ACC-02): the first signal of a Browse title request, without a Player. The
// cells of browse_title_answer_tests above cover the verdict and the give-up through the
// real handler; a real Player cannot deliver audio without Spotify, so the audio side is
// pinned here on the function the handler waits in.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod browse_first_signal_tests {
    use super::*;

    fn channels() -> (
        mpsc::Sender<Bytes>,
        mpsc::Receiver<Bytes>,
        tokio::sync::oneshot::Sender<StatusCode>,
        tokio::sync::oneshot::Receiver<StatusCode>,
    ) {
        let (pcm_tx, pcm_rx) = mpsc::channel::<Bytes>(4);
        let (status_tx, status_rx) = tokio::sync::oneshot::channel::<StatusCode>();
        (pcm_tx, pcm_rx, status_tx, status_rx)
    }

    /// Audio that comes after the old 500 ms window (here after 700 ms) is the first signal.
    #[tokio::test]
    async fn the_first_audio_chunk_is_the_first_signal_however_late_before_the_bound() {
        let (pcm_tx, mut pcm_rx, _status_tx, mut status_rx) = channels();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(700)).await;
            let _ = pcm_tx.send(Bytes::from_static(b"OggS first page")).await;
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        let t0 = Instant::now();
        let signal = browse_first_signal(&mut pcm_rx, &mut status_rx, Duration::from_secs(5)).await;
        let waited = t0.elapsed();
        assert_eq!(signal, BrowseFirstSignal::Audio(Bytes::from_static(b"OggS first page")));
        assert!(
            waited >= Duration::from_millis(650) && waited < Duration::from_secs(3),
            "returned after {waited:?}, expected about 700 ms"
        );
    }

    /// serve_track_request drops its audio sender when it ends and the verdict follows a
    /// moment later: the closed channel is not the answer, the verdict is.
    #[tokio::test]
    async fn a_verdict_that_follows_the_closed_audio_channel_is_the_first_signal() {
        let (pcm_tx, mut pcm_rx, status_tx, mut status_rx) = channels();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            drop(pcm_tx);
            tokio::time::sleep(Duration::from_millis(100)).await;
            let _ = status_tx.send(StatusCode::NOT_FOUND);
        });
        let signal = browse_first_signal(&mut pcm_rx, &mut status_rx, Duration::from_secs(5)).await;
        assert_eq!(signal, BrowseFirstSignal::Verdict(StatusCode::NOT_FOUND));
    }

    /// Neither audio nor a verdict: the wait ends at the bound, not before and not much later.
    #[tokio::test]
    async fn no_audio_and_no_verdict_within_the_bound_is_no_answer() {
        let (_pcm_tx, mut pcm_rx, _status_tx, mut status_rx) = channels();
        let t0 = Instant::now();
        let signal = browse_first_signal(&mut pcm_rx, &mut status_rx, Duration::from_millis(400)).await;
        let waited = t0.elapsed();
        assert_eq!(signal, BrowseFirstSignal::NoAnswer);
        assert!(
            waited >= Duration::from_millis(380) && waited < Duration::from_secs(2),
            "returned after {waited:?}, expected about 400 ms"
        );
    }

    /// The serve task dropped (the Connect takeover listener aborted it): both senders go
    /// without audio and without a verdict.
    #[tokio::test]
    async fn a_dropped_serve_task_without_audio_is_an_abort_not_a_verdict() {
        let (pcm_tx, mut pcm_rx, status_tx, mut status_rx) = channels();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            drop(pcm_tx);
            drop(status_tx);
        });
        let signal = browse_first_signal(&mut pcm_rx, &mut status_rx, Duration::from_secs(5)).await;
        assert_eq!(signal, BrowseFirstSignal::Aborted);
    }

    /// A title short enough to fit the channel whole has audio AND its end verdict ready
    /// at the same time: it still plays.
    #[tokio::test]
    async fn audio_wins_over_a_verdict_that_is_ready_at_the_same_time() {
        let (pcm_tx, mut pcm_rx, status_tx, mut status_rx) = channels();
        pcm_tx.send(Bytes::from_static(b"OggS whole title")).await.expect("channel has room");
        drop(pcm_tx);
        status_tx.send(StatusCode::OK).expect("receiver alive");
        let signal = browse_first_signal(&mut pcm_rx, &mut status_rx, Duration::from_secs(5)).await;
        assert_eq!(signal, BrowseFirstSignal::Audio(Bytes::from_static(b"OggS whole title")));
    }

    /// An end without audio is never answered 2xx; an error status stays what it is.
    #[test]
    fn an_end_without_audio_is_never_answered_2xx() {
        assert_eq!(status_for_an_end_without_audio(StatusCode::OK), StatusCode::BAD_GATEWAY);
        assert_eq!(status_for_an_end_without_audio(StatusCode::INTERNAL_SERVER_ERROR), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(status_for_an_end_without_audio(StatusCode::BAD_REQUEST), StatusCode::BAD_REQUEST);
    }

    /// The chunk the handler took out of the channel to decide the status is the first
    /// thing the body sends (in passthrough mode it is the Ogg header page).
    #[tokio::test]
    async fn the_answer_body_starts_with_the_chunk_that_was_the_first_signal() {
        let (pcm_tx, mut pcm_rx, _status_tx, mut status_rx) = channels();
        pcm_tx.send(Bytes::from_static(b"one,")).await.expect("room");
        pcm_tx.send(Bytes::from_static(b"two,")).await.expect("room");
        pcm_tx.send(Bytes::from_static(b"three")).await.expect("room");
        drop(pcm_tx);
        let first = match browse_first_signal(&mut pcm_rx, &mut status_rx, Duration::from_secs(5)).await {
            BrowseFirstSignal::Audio(chunk) => chunk,
            other => panic!("expected audio, got {other:?}"),
        };
        let body = browse_audio_body(Some(first), pcm_rx);
        let all = BodyExt::collect(body).await.expect("body").to_bytes();
        assert_eq!(&all[..], b"one,two,three");
    }
}
