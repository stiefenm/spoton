// SpotOn librespot-spoton/src/connect.rs
//
// Phase 5-01 implementation: --connect mode
// Phase 30: removed run_connect() and http_stream_server() (now in unified.rs)
//
// Provides:
//   - LMS struct: JSON-RPC event notifier (5 commands: start/change/stop/volume/seek)
//   (the old HttpStreamSink lived here; it was dead since unified.rs got its own
//    UnifiedHttpStreamSink and was removed in quick 261109-ath)
//
// Architecture decisions:
//   D-01: HTTP streaming (not FIFO)
//   D-02: S16LE PCM as default
//   D-03: Dynamic port (bind :0, announce stream_port=N on stdout)
//   D-14: HTTP control endpoints (/control/pause|play|volume|seek|next|prev)
//   CON-11: Volume suppression on SessionConnected
//   CON-14: Nanosecond-accurate rate-limiting, now in UnifiedHttpStreamSink::write()
//   CON-16: stream_port flushed to stdout immediately after println

use std::sync::{Arc, atomic::{AtomicBool, AtomicU64, Ordering}};
use std::time::{Duration, Instant};

use serde_json::json;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::watch;

use librespot_playback::player::PlayerEvent;

// -------------------------------------------------------------------------
// Position anchor — GH #128 relay-start resync
// -------------------------------------------------------------------------

/// Last known playback position, captured from position-carrying PlayerEvents
/// (Playing/Paused/Seeked/PositionCorrection). Cleared on TrackChanged/Stopped
/// so a stale anchor from the previous track can never be replayed onto a new
/// one.
///
/// GH #128: during a mid-song Connect handoff there is a real multi-second gap
/// between the `transfer` command (whose Playing event carries the
/// transfer-time position) and the /stream relay actually serving audio. The
/// relay-start hook extrapolates this anchor to "now" and pushes a fresh seek
/// notification, so the first position LMS trusts corresponds to when audio
/// actually flows — not the stale transfer-time position.
#[derive(Debug, Clone, Copy)]
pub struct PositionAnchor {
    pub position_ms: u32,
    pub at: Instant,
    pub playing: bool,
}

/// Pure extrapolation for the GH #128 relay-start resync.
///
/// Returns the anchor position extrapolated to `now` when the anchor says
/// playback is running; `None` when there is no anchor, playback is paused
/// (the resume path syncs position itself, CON-13), or the extrapolated
/// position is <= 1s (mirrors the needs_position_sync `secs > 1.0` guard —
/// fresh track starts need no resync and must not jitter the progress bar).
pub fn relay_resync_position_ms(anchor: &Option<PositionAnchor>, now: Instant) -> Option<u64> {
    let a = anchor.as_ref()?;
    if !a.playing {
        return None;
    }
    let elapsed_ms = now.saturating_duration_since(a.at).as_millis() as u64;
    let extrapolated = u64::from(a.position_ms) + elapsed_ms;
    if extrapolated <= 1000 {
        return None;
    }
    Some(extrapolated)
}

// -------------------------------------------------------------------------
// LMS struct — JSON-RPC notifier
// -------------------------------------------------------------------------

/// LMS-side notification target.
///
/// Sends JSON-RPC POST requests to LMS /jsonrpc.js when Spirc fires PlayerEvents.
/// Supports 6 command vocabulary: start, change, stop, volume, seek, resume.
///
/// `suppress_next_volume` is set on SessionConnected, then cleared on the first
/// VolumeChanged event — prevents the Spotify-stored device volume from clobbering
/// the LMS-side volume immediately after a Connect transfer (CON-11).
pub struct LMS {
    pub host_port: Option<String>,
    pub player_mac: Option<String>,
    pub auth: Option<String>,
    pub suppress_next_volume: Arc<AtomicBool>,
    /// Sender half of the flush watch-channel. Incremented on Seeked events to
    /// signal the HTTP relay task to drain pre-seek PCM bytes.
    pub flush_tx: Option<watch::Sender<u64>>,
    pub seek_gen: Arc<AtomicU64>,
    pub needs_position_sync: Arc<AtomicBool>,
    /// Monotonic timestamp of the last None->Some TrackChanged (session start).
    /// Used by the grace-timer to suppress spurious Paused within 2s of session start.
    /// Per D-03: only set on None->Some, never on Some->Some (track change within active session).
    /// Uses Instant (not SystemTime) to be immune to NTP clock adjustments (WR-05).
    pub last_session_start: Arc<std::sync::Mutex<Option<std::time::Instant>>>,
    /// Set to true when Paused/Stopped fires after grace-timer check passes (real pause/stop).
    /// Cleared atomically by the Playing handler to detect resume-after-pause (D-01).
    pub was_paused: Arc<AtomicBool>,
    /// GH #128: last known playback position for the relay-start resync.
    /// Updated by handle_player_event; consumed by resync_position_at_relay_start.
    pub position_anchor: Arc<std::sync::Mutex<Option<PositionAnchor>>>,
}

impl LMS {
    pub fn new(
        host_port: Option<String>,
        player_mac: Option<String>,
        auth: Option<String>,
        flush_tx: Option<watch::Sender<u64>>,
    ) -> Self {
        Self {
            host_port: host_port.map(|raw| raw.trim().replace(['\r', '\n'], "").to_owned()),
            player_mac: player_mac.map(|raw| raw.trim().replace(['\r', '\n'], "").to_owned()),
            auth: auth.map(|raw| raw.trim().replace(['\r', '\n'], "").to_owned()),
            suppress_next_volume: Arc::new(AtomicBool::new(false)),
            flush_tx,
            seek_gen: Arc::new(AtomicU64::new(0)),
            needs_position_sync: Arc::new(AtomicBool::new(false)),
            last_session_start: Arc::new(std::sync::Mutex::new(None)),
            was_paused: Arc::new(AtomicBool::new(false)),
            position_anchor: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    /// True iff both host_port and player_mac are configured.
    /// Without either, notify() is a no-op.
    pub fn is_configured(&self) -> bool {
        self.host_port.is_some() && self.player_mac.is_some()
    }
}

impl Clone for LMS {
    fn clone(&self) -> Self {
        Self {
            host_port: self.host_port.clone(),
            player_mac: self.player_mac.clone(),
            auth: self.auth.clone(),
            suppress_next_volume: Arc::clone(&self.suppress_next_volume),
            // flush_tx is not Clone (watch::Sender doesn't implement Clone).
            // Only the original LMS instance fires flush signals.
            flush_tx: None,
            seek_gen: Arc::clone(&self.seek_gen),
            needs_position_sync: Arc::clone(&self.needs_position_sync),
            last_session_start: Arc::clone(&self.last_session_start),
            was_paused: Arc::clone(&self.was_paused),
            position_anchor: Arc::clone(&self.position_anchor),
        }
    }
}

// -------------------------------------------------------------------------
// PlayerEvent dispatcher
// -------------------------------------------------------------------------

impl LMS {
    /// GH #128: replace the position anchor with a fresh (position, now, playing) triple.
    fn set_anchor(&self, position_ms: u32, playing: bool) {
        let mut a = self.position_anchor.lock().unwrap_or_else(|e| e.into_inner());
        *a = Some(PositionAnchor { position_ms, at: Instant::now(), playing });
    }

    /// GH #128: update the anchor position, preserving the playing flag
    /// (Seeked/PositionCorrection carry a position but not a play state).
    /// With no prior anchor the state defaults to paused — no extrapolated
    /// resync until a Playing event confirms playback for the current track.
    fn update_anchor_position(&self, position_ms: u32) {
        let mut a = self.position_anchor.lock().unwrap_or_else(|e| e.into_inner());
        let playing = a.map(|x| x.playing).unwrap_or(false);
        *a = Some(PositionAnchor { position_ms, at: Instant::now(), playing });
    }

    /// GH #128: drop the anchor (TrackChanged/Stopped) — a stale anchor from
    /// the previous track must never be replayed onto a new one.
    fn clear_anchor(&self) {
        let mut a = self.position_anchor.lock().unwrap_or_else(|e| e.into_inner());
        *a = None;
    }

    /// GH #128: called by the /stream relay the moment it actually starts
    /// serving audio. Pushes the SAME position-carrying notification the
    /// needs_position_sync mechanism uses ("seek", seconds) — but anchored to
    /// relay start instead of the transfer-time Playing event, so the LMS
    /// progress bar no longer lags by the buffer-fill gap after a mid-song
    /// Connect handoff.
    pub async fn resync_position_at_relay_start(&self) {
        if !self.is_configured() {
            return;
        }
        let pos_ms = {
            let anchor = self.position_anchor.lock().unwrap_or_else(|e| e.into_inner());
            relay_resync_position_ms(&anchor, Instant::now())
        };
        if let Some(ms) = pos_ms {
            let secs = ms as f64 / 1000.0;
            log::info!(
                "[spoton] /stream relay start — resyncing LMS position to {secs:.3}s (GH #128)"
            );
            self.notify("seek", &format!("{secs:.3}"), "").await;
        } else {
            log::debug!(
                "[spoton] /stream relay start — no position resync (no anchor / paused / <=1s, GH #128)"
            );
        }
    }

    /// Consume one PlayerEvent and emit zero-or-one spottyconnect JSON-RPC dispatches.
    ///
    /// `current_track` is the dispatch loop's cursor: base62 id of the last-seen
    /// Playing track. Mutated in place.
    ///
    /// Wire vocabulary (6 commands): start, change, stop, volume, seek, resume.
    /// "pause" is intentionally not emitted — Paused and Stopped collapse to "stop".
    pub async fn handle_player_event(
        &self,
        event: &PlayerEvent,
        current_track: &mut Option<String>,
    ) {
        if !self.is_configured() {
            return;
        }

        match event {
            // Playing fires for: track-start, un-pause, post-seek, buffer-underrun re-emit.
            // Emit `start` only on None→Some transition; same-id re-emits are no-ops;
            // different id is a `change`.
            // Exception: after TrackChanged sent `start`, the next same-id Playing carries
            // position_ms — send `seek` to sync LMS progress bar.
            PlayerEvent::Playing { track_id, position_ms, .. } => {
                let new_id = track_id.to_id();
                log::debug!("[spoton] Playing: track_id={new_id}, position_ms={position_ms}");
                // GH #128: Playing is the authoritative "position + running" signal.
                self.set_anchor(*position_ms, true);
                match current_track.as_deref() {
                    Some(prev) if prev == new_id.as_str() => {
                        // D-01: Check was_paused first — if set, this Playing is a resume.
                        // swap(false) clears the flag atomically to avoid double-resume.
                        if self.was_paused.swap(false, Ordering::AcqRel) {
                            let secs = f64::from(*position_ms) / 1000.0;
                            self.notify("resume", &new_id, &format!("{secs:.3}")).await;
                        }
                        // Position sync runs independently of resume (05.2 review fix).
                        if self.needs_position_sync.swap(false, Ordering::AcqRel) {
                            let secs = f64::from(*position_ms) / 1000.0;
                            if secs > 1.0 {
                                self.notify("seek", &format!("{secs:.3}"), "").await;
                            }
                        }
                    }
                    Some(_) => {
                        // GH #201: a pause that is still pending (set by Paused, kept
                        // across TrackChanged) means this Playing is the app starting
                        // a title after a pause. LMS stays paused on `change` alone
                        // (Connect.pm #158 contract), so `resume` follows `change`.
                        let resumed = self.was_paused.swap(false, Ordering::AcqRel);
                        let prev = current_track.replace(new_id.clone()).unwrap_or_default();
                        self.notify("change", &new_id, &prev).await;
                        if resumed {
                            let secs = f64::from(*position_ms) / 1000.0;
                            self.notify("resume", &new_id, &format!("{secs:.3}")).await;
                        }
                        // A session-start sync armed before this change (TrackChanged
                        // None->Some -> TrackChanged Some->Some -> Playing) is still
                        // pending here — honor it the same way the same-id branch does.
                        if self.needs_position_sync.swap(false, Ordering::AcqRel) {
                            let secs = f64::from(*position_ms) / 1000.0;
                            if secs > 1.0 {
                                self.notify("seek", &format!("{secs:.3}"), "").await;
                            }
                        }
                    }
                    None => {
                        self.was_paused.store(false, Ordering::Release);
                        // TrackChanged is the authoritative "start" source.
                        // Only set cursor here as fallback (Playing without prior TrackChanged).
                        *current_track = Some(new_id.clone());
                    }
                }
            }

            // Paused: D-03 grace-timer suppresses spurious Paused within 2s of session start.
            // Stopped is NEVER suppressed — it is the authoritative end-of-track signal (CR-01 fix).
            PlayerEvent::Paused { position_ms, .. } => {
                log::debug!("[spoton] Paused: current_track={:?}", current_track.as_deref());
                // GH #128: paused — keep the position but stop extrapolating.
                self.set_anchor(*position_ms, false);
                let grace = std::time::Duration::from_secs(2);
                if let Ok(start) = self.last_session_start.lock() {
                    if let Some(t) = *start {
                        if t.elapsed() < grace {
                            log::debug!("[spoton] Paused suppressed (grace timer, {:?} elapsed)", t.elapsed());
                            return;
                        }
                    }
                }
                if current_track.is_some() {
                    self.was_paused.store(true, Ordering::Release);
                    self.notify("stop", "", "").await;
                }
            }
            PlayerEvent::Stopped { .. } => {
                log::debug!("[spoton] Stopped: current_track={:?}", current_track.as_deref());
                // GH #128: playback ended — no position to resync to.
                self.clear_anchor();
                if current_track.is_some() {
                    self.notify("stop", "", "").await;
                    // Reset cursor so that the next SessionConnected + TrackChanged(same_id)
                    // takes the None→Some branch and emits "start" to LMS.
                    // Without this, reconnect with the same track silently hits the
                    // Some(prev)==new_id branch and never notifies LMS (reconnect-no-audio bug).
                    *current_track = None;
                }
            }

            // VolumeChanged: librespot reports 0..=65535; LMS speaks 0..=100.
            // Suppress the first event after SessionConnected (CON-11): that's a
            // Spotify-cloud echo, not a user action, and would clobber LMS-side volume.
            PlayerEvent::VolumeChanged { volume } => {
                log::debug!("[spoton] VolumeChanged: volume={volume}");
                if self.suppress_next_volume.swap(false, Ordering::Relaxed) {
                    // Suppress initial volume echo from Spotify on connect (CON-11)
                    return;
                }
                let pct = (u32::from(*volume) * 100 + 32767) / 65535;
                self.notify("volume", &pct.to_string(), "").await;
            }

            // Seeked: report position in seconds (3 decimals).
            // Also fire the flush watch-channel so the relay drains pre-seek PCM bytes.
            PlayerEvent::Seeked { position_ms, .. } => {
                log::debug!("[spoton] Seeked: position_ms={position_ms}");
                // GH #128: position moved; play state unchanged by a seek.
                self.update_anchor_position(*position_ms);
                if current_track.is_some() {
                    let secs = f64::from(*position_ms) / 1000.0;
                    self.notify("seek", &format!("{secs:.3}"), "").await;
                }
                if let Some(tx) = &self.flush_tx {
                    let new_gen = self.seek_gen.fetch_add(1, Ordering::Release) + 1;
                    tx.send(new_gen).ok();
                }
            }

            // SessionConnected: arm the suppress flag (CON-11).
            // The next VolumeChanged will be the Spotify-stored volume echo — suppress it.
            PlayerEvent::SessionConnected { .. } => {
                log::debug!("[spoton] SessionConnected");
                self.suppress_next_volume.store(true, Ordering::Relaxed);
            }

            // TrackChanged: authoritative source for "start" and "change" notifications.
            // Playing only handles seek-sync for the same track.
            PlayerEvent::TrackChanged { audio_item } => {
                let new_id = audio_item.track_id.to_id();
                self.handle_track_changed(&new_id, current_track).await;
            }

            // GH #128: no LMS notification, but the corrected position feeds
            // the relay-start resync anchor.
            PlayerEvent::PositionCorrection { position_ms, .. } => {
                self.update_anchor_position(*position_ms);
            }

            // GH #151: SessionDisconnected — this device stopped being the
            // active Connect target (deselected in the app, transfer-away,
            // explicit disconnect). Emit a session-end-marked stop so
            // Connect.pm can restore the pre-Connect power state. The plain
            // "stop" (Paused/Stopped) never carries the marker — it means
            // pause, not session end. Parity with SoloistWS's
            // device_changed(is_active:false) 'inactive' emission.
            PlayerEvent::SessionDisconnected { .. } => {
                log::debug!("[spoton] SessionDisconnected: current_track={:?}", current_track.as_deref());
                if current_track.is_some() {
                    self.notify("stop", "inactive", "").await;
                }
            }

            // All other events: no LMS equivalent.
            _ => {}
        }
    }

    /// TrackChanged handling, split out of `handle_player_event` so the unit
    /// tests can drive it without building an `AudioItem` (that type lives in
    /// librespot-metadata, which this crate does not depend on directly).
    /// Behaviour is exactly the former TrackChanged arm.
    async fn handle_track_changed(&self, new_id: &str, current_track: &mut Option<String>) {
        log::debug!("[spoton] TrackChanged: track_id={new_id}");
        // GH #128: new (or re-announced) track — the old anchor no
        // longer describes this track's position. Cleared until the
        // next position-carrying event; a relay start in between
        // performs no resync (better none than a wrong one).
        self.clear_anchor();
        match current_track.as_deref() {
            // GH #201: was_paused is NOT cleared here. After a pause the app's
            // "play this title" arrives as TrackChanged -> Playing with no Paused in
            // between (start_playback emits TrackChanged first, then Playing); the
            // Playing must still find the pause and notify `resume`, for a different
            // id (after `change`) and for the same id (reload of the paused title).
            Some(prev) if prev == new_id => {}
            Some(_) => {
                let prev = current_track.replace(new_id.to_owned()).unwrap_or_default();
                self.notify("change", new_id, &prev).await;
            }
            None => {
                // D-03: Session start — set grace timer to suppress spurious
                // Paused that Spirc fires immediately after TrackChanged.
                // ONLY on None->Some (session start), never on Some->Some (track change).
                // Uses Instant for NTP immunity (WR-05 fix).
                if let Ok(mut start) = self.last_session_start.lock() {
                    *start = Some(std::time::Instant::now());
                }
                log::debug!("[spoton] TrackChanged (session start): grace timer set");
                self.needs_position_sync.store(true, Ordering::Release);
                *current_track = Some(new_id.to_owned());
                self.notify("start", new_id, "").await;
            }
        }
    }

    /// POST a `spottyconnect <cmd> <p1> <p2>` JSON-RPC slim.request to LMS.
    ///
    /// Opens a fresh TCP connection per event (no keep-alive). Errors are
    /// swallowed with a warning — the daemon must never panic on LMS outage.
    /// If `auth` is set, adds `Authorization: Basic <creds>` header.
    pub async fn notify(&self, cmd: &str, p1: &str, p2: &str) {
        let host_port = match self.host_port.as_deref() {
            Some(h) => h,
            None => return,
        };
        let player_mac = match self.player_mac.as_deref() {
            Some(m) => m,
            None => return,
        };

        // Build variadic spottyconnect command array. Empty trailing params are dropped.
        let mut params: Vec<serde_json::Value> = Vec::with_capacity(4);
        params.push(json!("spottyconnect"));
        params.push(json!(cmd));
        if !p1.is_empty() {
            params.push(json!(p1));
        }
        if !p2.is_empty() {
            params.push(json!(p2));
        }
        let body = json!({
            "id": 1,
            "method": "slim.request",
            "params": [player_mac, params],
        })
        .to_string();

        let auth_header = match self.auth.as_deref() {
            Some(creds) => format!("Authorization: Basic {creds}\r\n"),
            None => String::new(),
        };

        let request = format!(
            "POST /jsonrpc.js HTTP/1.0\r\n\
             Host: {host_port}\r\n\
             Content-Type: application/json\r\n\
             Content-Length: {len}\r\n\
             X-Scanner: 1\r\n\
             {auth_header}\
             \r\n\
             {body}",
            len = body.len(),
        );

        // M16: bound the whole connect+write+shutdown at 5s — TcpStream::connect
        // has no timeout of its own, and an unreachable LMS host would otherwise
        // stall the notify caller for the OS TCP timeout (minutes).
        let send = async {
            match TcpStream::connect(host_port).await {
                Ok(mut stream) => {
                    if let Err(e) = stream.write_all(request.as_bytes()).await {
                        log::debug!("[spoton] notify({cmd}): write failed: {e}");
                    } else {
                        let _ = stream.shutdown().await;
                    }
                }
                Err(e) => {
                    log::debug!("[spoton] notify({cmd}): connect failed: {e}");
                }
            }
        };
        if tokio::time::timeout(Duration::from_secs(5), send).await.is_err() {
            log::debug!("[spoton] notify({cmd}): timed out after 5s");
        }
    }
}

// -------------------------------------------------------------------------
// Relay-start position resync unit tests (GH #128)
// -------------------------------------------------------------------------

#[cfg(test)]
mod relay_resync_tests {
    use super::*;

    fn anchor(position_ms: u32, age: Duration, playing: bool) -> Option<PositionAnchor> {
        Some(PositionAnchor {
            position_ms,
            at: Instant::now() - age,
            playing,
        })
    }

    /// GH #128 core: a playing anchor is extrapolated by the elapsed wall
    /// clock — the handoff gap between the transfer-time Playing event and
    /// the relay actually serving audio.
    #[test]
    fn playing_anchor_extrapolates_by_elapsed() {
        let now = Instant::now();
        let a = anchor(60_000, Duration::from_secs(5), true);
        let got = relay_resync_position_ms(&a, now).expect("playing anchor must resync");
        // 60s anchor + ~5s gap; allow small scheduling slack.
        assert!(
            (64_900..=65_200).contains(&got),
            "expected ~65000 ms, got {got}"
        );
    }

    /// Paused anchors never extrapolate — the resume path (CON-13) owns
    /// position sync for paused sessions.
    #[test]
    fn paused_anchor_is_skipped() {
        let a = anchor(60_000, Duration::from_secs(5), false);
        assert_eq!(relay_resync_position_ms(&a, Instant::now()), None);
    }

    /// No anchor (fresh TrackChanged, no Playing yet) — no resync. Better
    /// none than replaying the previous track's position onto a new one.
    #[test]
    fn missing_anchor_is_skipped() {
        assert_eq!(relay_resync_position_ms(&None, Instant::now()), None);
    }

    /// Positions <= 1s are suppressed (mirrors the needs_position_sync
    /// `secs > 1.0` guard) — fresh track starts must not jitter the bar.
    #[test]
    fn near_zero_position_is_skipped() {
        let a = anchor(200, Duration::from_millis(300), true);
        assert_eq!(relay_resync_position_ms(&a, Instant::now()), None);
    }
}


// -------------------------------------------------------------------------
// Event-translation unit tests (GH #201: resume across TrackChanged)
// -------------------------------------------------------------------------

#[cfg(test)]
mod event_translation_tests {
    use super::*;
    use librespot_core::spotify_uri::SpotifyUri;
    use std::sync::Mutex;
    use tokio::io::AsyncReadExt;
    use tokio::net::TcpListener;

    const TRACK_A: &str = "4uLU6hMCjMI75M1A2tKUQC";
    const TRACK_B: &str = "7ouMYWpwJ422jRcDASZB7P";

    /// A loopback "LMS": accepts the one-connection-per-notify POSTs of
    /// `LMS::notify` strictly in arrival order and records
    /// `<cmd> <p1> <p2>` (the params after "spottyconnect") per request.
    struct FakeLms {
        seen: Arc<Mutex<Vec<String>>>,
    }

    impl FakeLms {
        async fn start() -> (Self, String) {
            let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
            let addr = listener.local_addr().expect("addr").to_string();
            let seen = Arc::new(Mutex::new(Vec::new()));
            let seen_task = Arc::clone(&seen);
            tokio::spawn(async move {
                loop {
                    let (mut sock, _) = match listener.accept().await {
                        Ok(c) => c,
                        Err(_) => return,
                    };
                    let mut raw = Vec::new();
                    if sock.read_to_end(&mut raw).await.is_err() {
                        continue;
                    }
                    let text = String::from_utf8_lossy(&raw).into_owned();
                    let body = text.split("\r\n\r\n").nth(1).unwrap_or("");
                    let v: serde_json::Value =
                        serde_json::from_str(body).expect("notify body is JSON");
                    let params = v["params"][1].as_array().expect("params array");
                    // params[0] is "spottyconnect"; the rest is `cmd p1 p2`.
                    let line = params[1..]
                        .iter()
                        .map(|p| p.as_str().unwrap_or("?").to_owned())
                        .collect::<Vec<_>>()
                        .join(" ");
                    seen_task.lock().unwrap().push(line);
                }
            });
            (Self { seen }, addr)
        }

        /// notify() calls are awaited one by one and the fake handles its
        /// connections in arrival order, so once a sentinel is recorded
        /// everything sent before it is recorded too.
        async fn drain(&self, lms: &LMS) -> Vec<String> {
            lms.notify("sentinel", "", "").await;
            for _ in 0..200 {
                {
                    let seen = self.seen.lock().unwrap();
                    if seen.last().map(String::as_str) == Some("sentinel") {
                        let mut out = seen.clone();
                        out.pop();
                        return out;
                    }
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            panic!("fake LMS never saw the sentinel: {:?}", self.seen.lock().unwrap());
        }
    }

    fn uri(id: &str) -> SpotifyUri {
        SpotifyUri::from_uri(&format!("spotify:track:{id}")).expect("valid track uri")
    }

    fn playing(id: &str, position_ms: u32) -> PlayerEvent {
        PlayerEvent::Playing {
            play_request_id: 1,
            track_id: uri(id),
            position_ms,
        }
    }

    fn paused(id: &str, position_ms: u32) -> PlayerEvent {
        PlayerEvent::Paused {
            play_request_id: 1,
            track_id: uri(id),
            position_ms,
        }
    }

    /// A configured LMS pointing at the fake, plus a cursor already inside a
    /// session on TRACK_A that is past the 2 s grace window (no grace timer
    /// armed), i.e. the state of a Connect session in steady playback.
    async fn session_on_a() -> (FakeLms, LMS, Option<String>) {
        let (fake, addr) = FakeLms::start().await;
        let lms = LMS::new(Some(addr), Some("aa:bb:cc:dd:ee:ff".into()), None, None);
        (fake, lms, Some(TRACK_A.to_owned()))
    }

    /// GH #201 core (different track): pause, then a tap in the app. Spirc
    /// emits TrackChanged -> Playing with no Paused in between. LMS has to be
    /// told to resume or it stays paused (Connect.pm refuses to unpause on
    /// `change` while the session is paused, the #158 contract).
    #[tokio::test]
    async fn pause_then_tap_other_track_emits_stop_change_resume() {
        let (fake, lms, mut cur) = session_on_a().await;
        lms.handle_player_event(&paused(TRACK_A, 84_858), &mut cur).await;
        lms.handle_track_changed(TRACK_B, &mut cur).await;
        lms.handle_player_event(&playing(TRACK_B, 0), &mut cur).await;
        assert_eq!(
            fake.drain(&lms).await,
            vec![
                "stop".to_owned(),
                format!("change {TRACK_B} {TRACK_A}"),
                format!("resume {TRACK_B} 0.000"),
            ]
        );
    }

    /// GH #201 sibling E4: tapping the CURRENT paused title again reloads the
    /// same id (TrackChanged same id -> Playing). Same drop, no `change`.
    #[tokio::test]
    async fn pause_then_tap_same_track_emits_stop_resume() {
        let (fake, lms, mut cur) = session_on_a().await;
        lms.handle_player_event(&paused(TRACK_A, 84_858), &mut cur).await;
        lms.handle_track_changed(TRACK_A, &mut cur).await;
        lms.handle_player_event(&playing(TRACK_A, 0), &mut cur).await;
        assert_eq!(
            fake.drain(&lms).await,
            vec!["stop".to_owned(), format!("resume {TRACK_A} 0.000")]
        );
    }

    /// Fallback branch: a Playing for a different id with no TrackChanged
    /// before it (the cursor still names the old title) after a pause gets the
    /// same treatment: `change`, then `resume`.
    #[tokio::test]
    async fn pause_then_playing_other_id_without_track_changed_emits_change_resume() {
        let (fake, lms, mut cur) = session_on_a().await;
        lms.handle_player_event(&paused(TRACK_A, 84_858), &mut cur).await;
        lms.handle_player_event(&playing(TRACK_B, 0), &mut cur).await;
        assert_eq!(
            fake.drain(&lms).await,
            vec![
                "stop".to_owned(),
                format!("change {TRACK_B} {TRACK_A}"),
                format!("resume {TRACK_B} 0.000"),
            ]
        );
    }

    /// Unchanged: a track change WITHOUT a pause is a plain `change`, never a
    /// `resume` (LMS is playing; a resume would re-anchor its clock).
    #[tokio::test]
    async fn track_change_without_pause_emits_change_only() {
        let (fake, lms, mut cur) = session_on_a().await;
        lms.handle_player_event(&playing(TRACK_A, 30_000), &mut cur).await;
        lms.handle_track_changed(TRACK_B, &mut cur).await;
        lms.handle_player_event(&playing(TRACK_B, 0), &mut cur).await;
        assert_eq!(
            fake.drain(&lms).await,
            vec![format!("change {TRACK_B} {TRACK_A}")]
        );
    }

    /// Unchanged: pause then play on the same track is exactly one `resume`
    /// carrying the paused position; a second Playing (buffer re-emit) adds none.
    #[tokio::test]
    async fn pause_then_play_same_track_emits_one_resume() {
        let (fake, lms, mut cur) = session_on_a().await;
        lms.handle_player_event(&paused(TRACK_A, 84_858), &mut cur).await;
        lms.handle_player_event(&playing(TRACK_A, 84_858), &mut cur).await;
        lms.handle_player_event(&playing(TRACK_A, 84_900), &mut cur).await;
        assert_eq!(
            fake.drain(&lms).await,
            vec!["stop".to_owned(), format!("resume {TRACK_A} 84.858")]
        );
    }

    /// Unchanged: a Paused inside the 2 s grace window after a session start is
    /// suppressed (no `stop`), and the following Playing is no resume.
    #[tokio::test]
    async fn pause_inside_grace_window_is_suppressed() {
        let (fake, lms, mut cur) = session_on_a().await;
        *lms.last_session_start.lock().unwrap() = Some(Instant::now());
        lms.handle_player_event(&paused(TRACK_A, 0), &mut cur).await;
        lms.handle_player_event(&playing(TRACK_A, 0), &mut cur).await;
        assert_eq!(fake.drain(&lms).await, Vec::<String>::new());
    }

    /// Edge: a pause that is followed by a load which stays paused (app
    /// start_playing=false: TrackChanged -> Paused) keeps exactly one pending
    /// resume; the later Playing resumes once.
    #[tokio::test]
    async fn pause_then_load_paused_then_play_emits_one_resume() {
        let (fake, lms, mut cur) = session_on_a().await;
        lms.handle_player_event(&paused(TRACK_A, 84_858), &mut cur).await;
        lms.handle_track_changed(TRACK_B, &mut cur).await;
        lms.handle_player_event(&paused(TRACK_B, 0), &mut cur).await;
        lms.handle_player_event(&playing(TRACK_B, 0), &mut cur).await;
        let got = fake.drain(&lms).await;
        assert_eq!(
            got.iter().filter(|l| l.starts_with("resume")).count(),
            1,
            "{got:?}"
        );
        assert_eq!(got.last().unwrap(), &format!("resume {TRACK_B} 0.000"));
    }
}
