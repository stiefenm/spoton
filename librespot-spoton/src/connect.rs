// SpotOn librespot-spoton/src/connect.rs
//
// Phase 5-01 implementation: --connect mode
// Phase 30: removed run_connect() and http_stream_server() (now in unified.rs)
//
// Provides:
//   - LMS struct: JSON-RPC event notifier (5 commands: start/change/stop/volume/seek)
//   - HttpStreamSink: wall-clock rate-limited PCM sink (S16LE) for HTTP streaming
//
// Architecture decisions:
//   D-01: HTTP streaming (not FIFO)
//   D-02: S16LE PCM as default
//   D-03: Dynamic port (bind :0, announce stream_port=N on stdout)
//   D-14: HTTP control endpoints (/control/pause|play|volume|seek|next|prev)
//   CON-11: Volume suppression on SessionConnected
//   CON-14: Nanosecond-accurate rate-limiting in HttpStreamSink::write()
//   CON-16: stream_port flushed to stdout immediately after println

use std::sync::{Arc, atomic::{AtomicBool, AtomicU64, Ordering}};
use std::time::{Duration, Instant};

use bytes::Bytes;
use serde_json::json;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};

use crate::metadata::track_metadata;
#[cfg(test)]
use librespot_metadata::audio::{AudioItem, UniqueFields};
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::AudioFormat;
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::player::PlayerEvent;
use librespot_playback::{NUM_CHANNELS, SAMPLE_RATE};

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
}

impl LMS {
    /// Initialize both event orderings with the same pause grace and position sync.
    fn begin_session(&self) {
        if let Ok(mut start) = self.last_session_start.lock() {
            *start = Some(std::time::Instant::now());
        }
        self.was_paused.store(false, Ordering::Release);
        self.needs_position_sync.store(true, Ordering::Release);
    }

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
        }
    }
}

// -------------------------------------------------------------------------
// PlayerEvent dispatcher
// -------------------------------------------------------------------------

impl LMS {
    /// Consume one PlayerEvent and emit zero-or-one spottyconnect JSON-RPC dispatches.
    ///
    /// `current_track` is the dispatch loop's cursor: base62 id of the last-seen
    /// Playing track. Mutated in place.
    ///
    /// Wire vocabulary: start, change, metadata, stop, volume, seek, resume.
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
                        self.was_paused.store(false, Ordering::Release);
                        let prev = current_track.replace(new_id.clone()).unwrap_or_default();
                        self.notify("change", &new_id, &prev).await;
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
                        // Establish the LMS stream even if Playing precedes TrackChanged;
                        // the later TrackChanged delivers metadata for this same ID.
                        self.begin_session();
                        *current_track = Some(new_id.clone());
                        self.notify("start", &new_id, "").await;
                        // This event already supplies the initial transfer position.
                        self.needs_position_sync.store(false, Ordering::Release);
                        let secs = f64::from(*position_ms) / 1000.0;
                        if secs > 1.0 {
                            self.notify("seek", &format!("{secs:.3}"), "").await;
                        }
                    }
                }
            }

            // Paused: D-03 grace-timer suppresses spurious Paused within 2s of session start.
            // Stopped is NEVER suppressed — it is the authoritative end-of-track signal (CR-01 fix).
            PlayerEvent::Paused { .. } => {
                log::debug!("[spoton] Paused: current_track={:?}", current_track.as_deref());
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
                let metadata = track_metadata(audio_item);
                let new_id = audio_item.track_id.to_id();
                log::debug!("[spoton] TrackChanged: track_id={new_id}");
                match current_track.as_deref() {
                    Some(prev) if prev == new_id.as_str() => {
                        self.was_paused.store(false, Ordering::Release);
                        // Playing can precede TrackChanged. Deliver its metadata even
                        // when that earlier event already advanced the track cursor.
                        if metadata.is_some() {
                            self.notify_with_metadata("metadata", &new_id, "", metadata.as_ref()).await;
                        }
                    }
                    Some(_) => {
                        self.was_paused.store(false, Ordering::Release);
                        let prev = current_track.replace(new_id.clone()).unwrap_or_default();
                        self.notify_with_metadata("change", &new_id, &prev, metadata.as_ref()).await;
                    }
                    None => {
                        self.begin_session();
                        *current_track = Some(new_id.clone());
                        self.notify_with_metadata("start", &new_id, "", metadata.as_ref()).await;
                    }
                }
            }

            // All other events: no LMS equivalent.
            _ => {}
        }
    }

    /// POST a `spottyconnect <cmd> <p1> <p2>` JSON-RPC slim.request to LMS.
    ///
    /// Opens a fresh TCP connection per event (no keep-alive). Errors are
    /// swallowed with a warning — the daemon must never panic on LMS outage.
    /// If `auth` is set, adds `Authorization: Basic <creds>` header.
    pub async fn notify(&self, cmd: &str, p1: &str, p2: &str) {
        self.notify_with_metadata(cmd, p1, p2, None).await;
    }

    /// Send tagged metadata in the same dispatch as its track transition so LMS never
    /// races a separate metadata notification against playlist creation. Existing
    /// parameter positions are preserved, including the empty previous ID on start.
    async fn notify_with_metadata(
        &self, cmd: &str, p1: &str, p2: &str, metadata: Option<&serde_json::Value>,
    ) {
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
        if !p2.is_empty() || metadata.is_some() {
            params.push(json!(p2));
        }
        if let Some(metadata) = metadata {
            // LMS parses extra arguments as tag:value. Use an explicit tag so
            // colons inside JSON cannot be mistaken for a parameter name.
            params.push(json!(format!("metadata:{metadata}")));
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
// HttpStreamSink
// -------------------------------------------------------------------------

/// Audio sink for --connect mode.
///
/// Unlike StdoutSink (which calls exit(0) in stop()), this sink's stop()
/// only resets counters — the process outlives individual track boundaries
/// for gapless Spotify Connect playback (CON Pitfall 1).
///
/// Rate-limiting follows nanosecond wall-clock math with an optional
/// buffer_latency_ns addend that compensates for LMS's audio buffer depth
/// (CON-14). Without compensation, Spirc reports the decoder's position
/// (ahead of audio output by LMS buffer latency), causing Spotify's progress
/// bar to drift ahead of what the user hears.
pub struct HttpStreamSink {
    pcm_tx: mpsc::Sender<Bytes>,
    /// Held for ownership — actual flush signals are sent by LMS::handle_player_event.
    #[allow(dead_code)]
    flush_tx: watch::Sender<u64>,
    began_at: Instant,
    frames_consumed: u64,
    buffer_latency_ns: u128,
    // Phase 44 fix: granule_position offset captured on the first audio page after
    // each start(). See UnifiedHttpStreamSink for rationale.
    granule_offset: i64,
    ogg_serial: u32,
}

impl HttpStreamSink {
    pub fn open(
        _device: Option<String>,
        format: AudioFormat,
        pcm_tx: mpsc::Sender<Bytes>,
        flush_tx: watch::Sender<u64>,
        buffer_latency_ms: u64,
    ) -> Box<dyn Sink> {
        if format != AudioFormat::S16 {
            panic!(
                "HttpStreamSink: only AudioFormat::S16 supported, got {:?}",
                format
            );
        }
        Box::new(Self {
            pcm_tx,
            flush_tx,
            began_at: Instant::now(),
            frames_consumed: 0,
            buffer_latency_ns: u128::from(buffer_latency_ms) * 1_000_000u128,
            granule_offset: -1,
            ogg_serial: 0,
        })
    }
}

impl Sink for HttpStreamSink {
    fn start(&mut self) -> SinkResult<()> {
        self.began_at = Instant::now();
        self.frames_consumed = 0;
        self.granule_offset = -1; // Phase 44 fix: re-capture on first audio page
        self.ogg_serial = 0;
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        // CRITICAL: do NOT call exit() here (Pitfall 1).
        // StdoutSink/pipe backend calls exit(0) — Connect daemon must not do this.
        // Reset counters only. Process outlives track boundaries.
        self.frames_consumed = 0;
        self.began_at = Instant::now();
        self.granule_offset = -1;
        self.ogg_serial = 0;
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        match packet {
            AudioPacket::Samples(samples) => {
                // Convert f64 samples to S16LE bytes.
                let samples_s16 = converter.f64_to_s16(&samples);
                // SAFETY: i16 values are valid as two u8 bytes; ptr and len from valid Vec.
                let bytes: &[u8] = unsafe {
                    std::slice::from_raw_parts(
                        samples_s16.as_ptr().cast::<u8>(),
                        samples_s16.len() * std::mem::size_of::<i16>(),
                    )
                };

                // Wall-clock rate-limiter with buffer-latency compensation (CON-14).
                //
                // expected_ns = frames_consumed * 1e9 / SAMPLE_RATE + buffer_latency_ns
                //
                // Without rate-limiting: decoder races ahead of wall-clock, making Spotify
                // clients show nonsensical seek positions.
                //
                // With buffer_latency_ns > 0: decoder advances `buffer_latency_ms` ms slower
                // than wall-clock, so reported position matches actual audio output position.
                let frames_in_packet = (samples.len() / NUM_CHANNELS as usize) as u64;
                self.frames_consumed = self.frames_consumed.saturating_add(frames_in_packet);
                if self.frames_consumed % 1000 == 0 {
                    log::trace!("[spoton] sink write: {} frames consumed", self.frames_consumed);
                }
                let expected_ns: u128 =
                    u128::from(self.frames_consumed) * 1_000_000_000u128 / u128::from(SAMPLE_RATE)
                    + self.buffer_latency_ns;
                let elapsed_ns: u128 = self.began_at.elapsed().as_nanos();

                if expected_ns > elapsed_ns {
                    let park_ns = (expected_ns - elapsed_ns) as u64;
                    std::thread::sleep(Duration::from_nanos(park_ns));
                }

                // Send PCM bytes over the channel to the HTTP stream server.
                // Player::new spawns a std::thread with its own tokio Runtime; Sink::write
                // runs within a tokio context. blocking_send would panic.
                // try_send with spin-retry: the channel has 256 slots (~1.5s of audio)
                // and a single consumer — contention is transient, rate-limiter keeps us
                // at real-time, so the channel is nearly always empty.
                let chunk = Bytes::copy_from_slice(bytes);
                loop {
                    match self.pcm_tx.try_send(chunk.clone()) {
                        Ok(()) => break,
                        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                            std::thread::sleep(Duration::from_millis(1));
                        }
                        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                            return Err(SinkError::OnWrite(
                                "HTTP stream server shut down".into(),
                            ));
                        }
                    }
                }
            }
            AudioPacket::Raw(bytes) => {
                // Phase 44 (D-01): granule_position-based wall-clock rate-limiting for
                // OGG passthrough. Replaces the Phase 43 backpressure-only pacing — for
                // code consistency with UnifiedHttpStreamSink (D-05), even though this
                // standalone sink is not the primary production path.
                let chunk = Bytes::copy_from_slice(&bytes);

                // Phase 44 fix: detect gapless track transitions via OGG serial
                // change. See UnifiedHttpStreamSink for full rationale.
                // Note: no header buffer here (standalone sink has no /stream handler).
                // .max(0) guard on relative_granule prevents hangs if serial change
                // is missed in a multi-page chunk spanning a track boundary.
                if chunk.len() >= 18 && &chunk[0..4] == b"OggS" {
                    let serial = u32::from_le_bytes(
                        chunk[14..18].try_into().expect("OGG serial is 4 bytes"),
                    );
                    if self.ogg_serial != 0 && serial != self.ogg_serial {
                        log::info!(
                            "[spoton/connect] OGG serial change: {} -> {} — resetting rate-limiter",
                            self.ogg_serial, serial
                        );
                        self.began_at = Instant::now();
                        self.granule_offset = -1;
                    }
                    self.ogg_serial = serial;
                }

                // Phase 44: multi-page rate-limiting — see UnifiedHttpStreamSink
                // for full rationale. Scan ALL OGG pages, pace by the last one.
                {
                    let mut last_granule: i64 = -1;
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
                        let n_segments = chunk[pos + 26] as usize;
                        if pos + 27 + n_segments > chunk.len() {
                            break;
                        }
                        let body_size: usize = chunk[pos + 27..pos + 27 + n_segments]
                            .iter()
                            .map(|&b| b as usize)
                            .sum();
                        let page_size = 27 + n_segments + body_size;

                        if granule > 0 {
                            last_granule = granule;
                        }
                        pos += page_size;
                    }
                    if last_granule > 0 {
                        if self.granule_offset < 0 {
                            self.granule_offset = last_granule;
                        }
                        let relative_granule = (last_granule - self.granule_offset).max(0) as u128;
                        let expected_ns: u128 = relative_granule
                            * 1_000_000_000u128
                            / u128::from(SAMPLE_RATE)
                            + self.buffer_latency_ns;
                        let elapsed_ns: u128 = self.began_at.elapsed().as_nanos();

                        if expected_ns > elapsed_ns {
                            let park_ns = (expected_ns - elapsed_ns) as u64;
                            std::thread::sleep(Duration::from_nanos(park_ns));
                        }
                    }
                }

                loop {
                    match self.pcm_tx.try_send(chunk.clone()) {
                        Ok(()) => break,
                        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                            std::thread::sleep(Duration::from_millis(1));
                        }
                        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                            return Err(SinkError::OnWrite(
                                "HTTP stream server shut down".into(),
                            ));
                        }
                    }
                }
            }
        }

        Ok(())
    }
}


/// Exercise the actual JSON-RPC transport without a Spotify account or LMS server.
#[cfg(test)]
mod metadata_tests {
    use super::*;
    use librespot_core::SpotifyUri;
    use librespot_metadata::{
        artist::{ArtistRole, ArtistWithRole, ArtistsWithRole},
        audio::item::CoverImage,
        image::ImageSize,
    };
    use tokio::{io::AsyncReadExt, net::TcpListener};

    /// Representative loaded track includes Unicode and punctuation requiring JSON escaping.
    fn item(id: &str) -> AudioItem {
        AudioItem {
            track_id: SpotifyUri::from_uri(&format!("spotify:track:{id}")).unwrap(),
            uri: format!("spotify:track:{id}"),
            files: Default::default(),
            name: "Björk: \"Live\" — 東京".into(),
            covers: vec![CoverImage {
                url: "https://i.scdn.co/image/example".into(),
                size: ImageSize::LARGE,
                width: 640,
                height: 640,
            }],
            language: vec![],
            duration_ms: 237_360,
            is_explicit: false,
            availability: Ok(()),
            alternatives: None,
            unique_fields: UniqueFields::Track {
                artists: ArtistsWithRole(vec![ArtistWithRole {
                    id: SpotifyUri::from_uri("spotify:artist:0000000000000000000001").unwrap(),
                    name: "Artist & guest".into(),
                    role: ArtistRole::ARTIST_ROLE_MAIN_ARTIST,
                }]),
                album: "Album: one".into(),
                album_artists: vec![],
                popularity: 0,
                number: 1,
                disc_number: 1,
            },
        }
    }

    /// Read one complete HTTP request and verify its byte count before parsing JSON.
    async fn receive(listener: &TcpListener) -> serde_json::Value {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).await.unwrap();
        let request = String::from_utf8(bytes).unwrap();
        let (headers, body) = request.split_once("\r\n\r\n").unwrap();
        assert!(headers.contains(&format!("Content-Length: {}", body.len())));
        serde_json::from_str(body).unwrap()
    }

    /// Verify track metadata reaches the same positional argument on start and change.
    #[tokio::test]
    async fn start_change_and_same_track_metadata() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let lms = LMS::new(Some(listener.local_addr().unwrap().to_string()), Some("player".into()), None, None);
        let mut cursor = None;
        for (id, command, previous) in [
            ("6AFchAk1WiYMnWVZcm82s5", "start", ""),
            ("7AXVmFR9ewYFFB0fKEyGkW", "change", "6AFchAk1WiYMnWVZcm82s5"),
            ("7AXVmFR9ewYFFB0fKEyGkW", "metadata", ""),
        ] {
            let event = PlayerEvent::TrackChanged { audio_item: Box::new(item(id)) };
            lms.handle_player_event(&event, &mut cursor).await;
            let request = receive(&listener).await;
            let args = request["params"][1].as_array().unwrap();
            assert_eq!(args.len(), 5);
            assert_eq!(args[1], command);
            assert_eq!(args[2], id);
            assert_eq!(args[3], previous);
            let metadata: serde_json::Value = serde_json::from_str(args[4].as_str().unwrap().strip_prefix("metadata:").unwrap()).unwrap();
            assert_eq!(metadata["uri"], format!("spotify:track:{id}"));
            assert_eq!(metadata["name"], "Björk: \"Live\" — 東京");
            assert_eq!(metadata["artists"][0]["name"], "Artist & guest");
            assert_eq!(metadata["artists"][0]["id"], "0000000000000000000001");
            assert_eq!(metadata["album"]["name"], "Album: one");
            assert_eq!(metadata["album"]["images"][0]["width"], 640);
            assert_eq!(metadata["duration_ms"], 237_360);
        }
    }

    /// Playing-first ordering must establish the stream before metadata-only delivery.
    #[tokio::test]
    async fn playing_before_track_changed_starts_stream() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let lms = LMS::new(Some(listener.local_addr().unwrap().to_string()), Some("player".into()), None, None);
        let mut cursor = None;
        let audio_item = item("6AFchAk1WiYMnWVZcm82s5");
        let event = PlayerEvent::Playing {
            track_id: audio_item.track_id.clone(), play_request_id: 1, position_ms: 0,
        };
        lms.handle_player_event(&event, &mut cursor).await;
        assert_eq!(receive(&listener).await["params"][1][1], "start");
        lms.handle_player_event(&PlayerEvent::TrackChanged { audio_item: Box::new(audio_item) }, &mut cursor).await;
        assert_eq!(receive(&listener).await["params"][1][1], "metadata");
    }

    /// Both start orderings suppress transient pause and synchronize a mid-track transfer.
    #[tokio::test]
    async fn session_start_preserves_grace_and_position() {
        for playing_first in [true, false] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let lms = LMS::new(Some(listener.local_addr().unwrap().to_string()), Some("player".into()), None, None);
            let mut cursor = None;
            let audio_item = item("6AFchAk1WiYMnWVZcm82s5");
            let playing = PlayerEvent::Playing {
                track_id: audio_item.track_id.clone(), play_request_id: 1, position_ms: 42000,
            };
            let changed = PlayerEvent::TrackChanged { audio_item: Box::new(audio_item) };
            lms.handle_player_event(if playing_first { &playing } else { &changed }, &mut cursor).await;
            assert_eq!(receive(&listener).await["params"][1][1], "start");
            assert!(lms.last_session_start.lock().unwrap().is_some());
            if playing_first {
                let seek = receive(&listener).await;
                assert_eq!(seek["params"][1][1], "seek");
                assert_eq!(seek["params"][1][2], "42.000");
            }
            let paused = PlayerEvent::Paused {
                track_id: SpotifyUri::from_uri("spotify:track:6AFchAk1WiYMnWVZcm82s5").unwrap(),
                play_request_id: 1, position_ms: 42000,
            };
            lms.handle_player_event(&paused, &mut cursor).await;
            assert!(!lms.was_paused.load(Ordering::Acquire));
            assert!(tokio::time::timeout(std::time::Duration::from_millis(20), listener.accept()).await.is_err());
            lms.handle_player_event(if playing_first { &changed } else { &playing }, &mut cursor).await;
            let request = receive(&listener).await;
            assert_eq!(request["params"][1][1], if playing_first { "metadata" } else { "seek" });
            assert!(!lms.needs_position_sync.load(Ordering::Acquire));
        }
    }

    /// Missing track artists fall back to album artists, without requiring cover art.
    #[test]
    fn missing_artwork_and_track_artists() {
        let mut audio_item = item("6AFchAk1WiYMnWVZcm82s5");
        audio_item.covers.clear();
        if let UniqueFields::Track { artists, album_artists, .. } = &mut audio_item.unique_fields {
            artists.0.clear();
            album_artists.push("Album artist".into());
        }
        let metadata = track_metadata(&audio_item).unwrap();
        assert_eq!(metadata["artists"][0]["name"], "Album artist");
        assert_eq!(metadata["album"]["images"], json!([]));
    }
}
