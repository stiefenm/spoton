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
//   Pitfall 5: Rate-limiting is FORBIDDEN in BrowseHttpSink. Only HttpStreamSink is rate-limited.

use std::io::Write as IoWrite;
use std::sync::{Arc, atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering}};
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
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig, VolumeCtrl};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::softmixer::SoftMixer;
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

// -------------------------------------------------------------------------
// UnifiedHttpStreamSink — rate-limited PCM sink for Connect path
// -------------------------------------------------------------------------
//
// This is a local reimplementation of connect::HttpStreamSink to avoid
// exposing HttpStreamSink::flush_tx (watch::Sender is not Clone, so the
// connect::HttpStreamSink wraps flush_tx as an owned field with a private
// Clone impl that drops it). We replicate the struct in unified.rs to keep
// ownership clean.

struct UnifiedHttpStreamSink {
    pcm_tx: mpsc::Sender<Bytes>,
    #[allow(dead_code)]
    flush_tx: watch::Sender<u64>,
    began_at: Instant,
    frames_consumed: u64,
    buffer_latency_ns: u128,
    // Phase 43 (D-03): shared with the /stream HTTP handler so buffered OGG BOS +
    // Vorbis header pages can be replayed after the handler drains stale chunks
    // from the main channel on each new connection.
    ogg_header_buf: Arc<std::sync::Mutex<Vec<Bytes>>>,
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
    // Phase 44 fix: OGG serial number of the current track. When it changes
    // (gapless track transition without stop()/start()), reset rate-limiting
    // state so the new track is paced from its own beginning.
    ogg_serial: u32,
}

impl UnifiedHttpStreamSink {
    fn open(
        _device: Option<String>,
        format: AudioFormat,
        pcm_tx: mpsc::Sender<Bytes>,
        flush_tx: watch::Sender<u64>,
        buffer_latency_ms: u64,
        ogg_header_buf: Arc<std::sync::Mutex<Vec<Bytes>>>,
        passthrough: bool,
    ) -> Box<dyn Sink> {
        if format != AudioFormat::S16 {
            panic!(
                "UnifiedHttpStreamSink: only AudioFormat::S16 supported, got {:?}",
                format
            );
        }
        Box::new(Self {
            pcm_tx,
            flush_tx,
            began_at: Instant::now(),
            frames_consumed: 0,
            buffer_latency_ns: u128::from(buffer_latency_ms) * 1_000_000u128,
            ogg_header_buf,
            collecting_headers: passthrough,
            passthrough,
            granule_offset: -1,
            ogg_serial: 0,
        })
    }
}

impl Sink for UnifiedHttpStreamSink {
    fn start(&mut self) -> SinkResult<()> {
        self.began_at = Instant::now();
        self.frames_consumed = 0;
        self.granule_offset = -1; // Phase 44 fix: re-capture on first audio page
        self.ogg_serial = 0;
        // Phase 43 (D-03): clear the header buffer on every track start so the
        // /stream handler always replays THIS track's headers, not a stale track's.
        if self.passthrough {
            let mut buf = self.ogg_header_buf.lock().unwrap_or_else(|e| e.into_inner());
            buf.clear();
            drop(buf);
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
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
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

                // Wall-clock rate-limiter with buffer-latency compensation (CON-14).
                let frames_in_packet = (samples.len() / NUM_CHANNELS as usize) as u64;
                self.frames_consumed = self.frames_consumed.saturating_add(frames_in_packet);
                let expected_ns: u128 =
                    u128::from(self.frames_consumed) * 1_000_000_000u128 / u128::from(SAMPLE_RATE)
                    + self.buffer_latency_ns;
                let elapsed_ns: u128 = self.began_at.elapsed().as_nanos();

                if expected_ns > elapsed_ns {
                    let park_ns = (expected_ns - elapsed_ns) as u64;
                    std::thread::sleep(Duration::from_nanos(park_ns));
                }

                let chunk = Bytes::copy_from_slice(bytes);
                loop {
                    match self.pcm_tx.try_send(chunk.clone()) {
                        Ok(()) => break,
                        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                            std::thread::sleep(Duration::from_millis(1));
                        }
                        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                            return Err(SinkError::OnWrite(
                                "Unified HTTP stream server shut down".into(),
                            ));
                        }
                    }
                }
            }
            AudioPacket::Raw(bytes) => {
                // Phase 44 (D-01): granule_position-based wall-clock rate-limiting for
                // OGG passthrough. Replaces the Phase 42 backpressure-only pacing —
                // without this, the decoder raced through compressed OGG data in
                // seconds, causing Spirc to advance its track index far ahead of
                // actual audio playback (44-CONTEXT.md).
                let chunk = Bytes::copy_from_slice(&bytes);

                // Phase 43 (D-03): buffer OGG header pages (BOS + Vorbis headers) so the
                // /stream handler can replay them after draining stale chunks on new
                // connections. granule_position == 0 (bytes 6..14 of the Ogg page header)
                // identifies header pages; the first page with a non-zero granule_position
                // is the first audio data page, which ends header collection for this track.
                if self.collecting_headers {
                    let is_header_page = chunk.len() >= 27
                        && &chunk[0..4] == b"OggS"
                        && chunk[6..14].iter().all(|&b| b == 0);
                    if is_header_page {
                        let mut buf = self.ogg_header_buf.lock().unwrap_or_else(|e| e.into_inner());
                        buf.push(chunk.clone());
                    } else {
                        self.collecting_headers = false;
                    }
                }

                // Phase 44 fix: detect gapless track transitions by watching the
                // OGG serial number (bytes 14..18). In Connect mode, librespot
                // does NOT call stop()/start() between gapless tracks — the data
                // flows continuously. When the serial changes, reset began_at and
                // granule_offset so the new track is paced from its own beginning.
                //
                // Note: checks only the FIRST page's serial. If a multi-page chunk
                // spans a track boundary, the change triggers on the next chunk.
                // The .max(0) guard on relative_granule prevents hangs in between.
                if chunk.len() >= 18 && &chunk[0..4] == b"OggS" {
                    let serial = u32::from_le_bytes(
                        chunk[14..18].try_into().expect("OGG serial is 4 bytes"),
                    );
                    if self.ogg_serial != 0 && serial != self.ogg_serial {
                        log::info!(
                            "[spoton/unified] OGG serial change: {} -> {} — resetting rate-limiter \
                             (gapless track transition)",
                            self.ogg_serial, serial
                        );
                        self.began_at = Instant::now();
                        self.granule_offset = -1;
                        self.collecting_headers = true;
                        // Re-buffer headers for the new track
                        let mut buf = self.ogg_header_buf.lock().unwrap_or_else(|e| e.into_inner());
                        buf.clear();
                        // This page is a BOS header — buffer it
                        buf.push(chunk.clone());
                        drop(buf);
                    }
                    self.ogg_serial = serial;
                }

                // Phase 44: granule_position-based wall-clock rate-limiting.
                // Scan ALL OGG pages in the chunk (the passthrough decoder may
                // deliver multiple pages concatenated in a single Raw packet).
                // Use the LAST audio page's granule_position for the sleep formula
                // so the pacing matches real-time regardless of chunk size.
                //
                // granule_offset: captured on the first audio page after each
                // start()/resume so pause/resume works correctly.
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
                        // Parse page size: 27-byte header + segment_count bytes of
                        // segment table + sum of segment sizes.
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
                        // Capture offset on first audio page after start/resume.
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
                                "Unified HTTP stream server shut down".into(),
                            ));
                        }
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
    // Issue #97: bitrate for Browse Player creation
    bitrate: Bitrate,
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

                    async move {
                        let path = req.uri().path().to_owned();
                        let method = req.method().clone();

                        // ---- GET /health ----
                        if method == Method::GET && path == "/health" {
                            let session_valid = {
                                let s = session.lock().await;
                                !s.is_invalid()
                            };
                            let age_secs = {
                                let t = session_created_at.lock().unwrap_or_else(|e| e.into_inner());
                                t.elapsed().as_secs()
                            };
                            let idle_secs = {
                                let t = last_activity.lock().unwrap_or_else(|e| e.into_inner());
                                t.elapsed().as_secs()
                            };
                            let json = format!(
                                r#"{{"status":"ok","session_valid":{},"session_age_secs":{},"idle_secs":{}}}"#,
                                session_valid, age_secs, idle_secs
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

                            // Drain stale pre-seek audio from the channel.
                            {
                                let mut rx = pcm_rx.lock().unwrap_or_else(|e| e.into_inner());
                                let mut drained = 0u64;
                                while rx.try_recv().is_ok() { drained += 1; }
                                log::debug!("[spoton/unified] /stream: relay starting, drained {} stale chunks", drained);
                            }

                            // Per-connection relay channel (64 frames capacity).
                            let (conn_tx, conn_rx) = mpsc::channel::<Bytes>(64);

                            // Phase 43 (D-03): replay buffered OGG headers (BOS + Vorbis
                            // headers) before the relay begins. The drain above removed them
                            // from the main channel; the decoder needs them to parse the stream.
                            if passthrough {
                                if let Some(ref buf) = ogg_header_buf {
                                    let headers = {
                                        let guard = buf.lock().unwrap_or_else(|e| e.into_inner());
                                        guard.clone()
                                    };
                                    let mut replayed = 0u64;
                                    'replay: for header_chunk in headers {
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
                                    log::debug!("[spoton/unified] /stream: replayed {} OGG header chunks", replayed);
                                }
                            }

                            let pcm_rx_clone = Arc::clone(&pcm_rx);
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

                                    let chunk = {
                                        let mut rx = pcm_rx_clone.lock().unwrap_or_else(|e| e.into_inner());
                                        rx.try_recv().ok()
                                    };
                                    match chunk {
                                        Some(bytes) => {
                                            if conn_tx.send(bytes).await.is_err() {
                                                log::debug!("[spoton/unified] /stream: relay client disconnected");
                                                break;
                                            }
                                            *last_data_time_clone.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                                            *last_activity_relay.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
                                        }
                                        None => {
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
                                    spirc_active.store(false, Ordering::SeqCst);
                                    log::info!("[spoton/unified] Browse preempting Connect -- Spirc shut down");
                                }
                                *mode = ActiveMode::Browse(track_id.clone());
                            }

                            // Per-request PCM channel.
                            let (pcm_tx, pcm_rx) = mpsc::channel::<Bytes>(256);

                            // Status channel: serve_track_request signals 404 (Unavailable) early.
                            let (status_tx, mut status_rx) = tokio::sync::oneshot::channel::<StatusCode>();

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

                                let status = serve_track_request(&content_type_for_task, &track_id_for_task, session_snap, pcm_tx, start_position_ms, passthrough, bitrate).await;

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

                            // Wait briefly for early 404 from serve_track_request.
                            let early_status = tokio::time::timeout(
                                Duration::from_millis(500),
                                &mut status_rx,
                            ).await;

                            // H11: supersession is signalled as 409 CONFLICT and is NOT a
                            // browse failure — rapid skipping produces supersessions as a
                            // matter of course, and counting them tore down healthy sessions
                            // after only 2 skips. No failure-counter increment, no reconnect
                            // trigger, no mode touch (the newer request owns the mode; the
                            // superseded response goes to a connection LMS already abandoned).
                            if let Ok(Ok(StatusCode::CONFLICT)) = early_status {
                                log::info!("[spoton/unified] /track/{}: superseded — 409, not counted as failure", track_id);
                                cancel_abort.abort();
                                return Ok(empty_response(StatusCode::CONFLICT));
                            }

                            if let Ok(Ok(StatusCode::NOT_FOUND)) = early_status {
                                let fails = consecutive_browse_fails.fetch_add(1, Ordering::SeqCst) + 1;
                                log::info!("[spoton/unified] track unavailable — returning 404 (consecutive_fails={})", fails);
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
                                if fails >= 2 && !browse_reconnect_pending.swap(true, Ordering::AcqRel) {
                                    log::warn!("[spoton/unified] {} consecutive Browse failures — triggering session reconnect", fails);
                                    browse_reconnect_signal.notify_one();
                                }
                                return Ok(empty_response(StatusCode::NOT_FOUND));
                            }

                            // Track started streaming — reset consecutive failure counter ONLY if
                            // the status channel confirmed the track actually loaded (not a slow 404).
                            // early_was_success: channel replied with a non-404 status (happy path)
                            // timed_out: channel did not reply in 500ms (optimistic reset; the spawned
                            //   task's eventual drop of pcm_tx will deliver EOF if it was really a 404)
                            // Ok(Err(_)): channel dropped without sending — don't reset (WR-01)
                            let early_was_success = matches!(early_status, Ok(Ok(ref s)) if *s != StatusCode::NOT_FOUND);
                            let timed_out         = early_status.is_err();
                            if early_was_success || timed_out {
                                consecutive_browse_fails.store(0, Ordering::SeqCst);
                            }
                            // Phase 36: update activity timestamp on successful Browse track
                            { *last_activity.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now(); }

                            // Build streaming response.
                            let stream = TokioStreamExt::map(
                                ReceiverStream::new(pcm_rx),
                                |chunk| Ok::<Frame<Bytes>, hyper::Error>(Frame::data(chunk)),
                            );
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

                            let spirc_guard = match spirc_handle.lock() {
                                Ok(g) => g,
                                Err(_) => return Ok(Response::builder()
                                    .status(StatusCode::SERVICE_UNAVAILABLE)
                                    .body(BoxBody::new(Full::new(Bytes::from("Spirc mutex poisoned")).map_err(|e| match e {})))
                                    .unwrap()),
                            };
                            let result = if let Some(spirc) = spirc_guard.as_ref() {
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

                            let status = match (result.is_some(), cmd) {
                                (true, _) => StatusCode::NO_CONTENT,
                                (false, "pause") | (false, "play") | (false, "next") | (false, "prev") => {
                                    StatusCode::NO_CONTENT
                                }
                                (false, "volume") | (false, "seek") => {
                                    log::debug!("[spoton/unified] /control/{cmd}: body parse failed, returning 422");
                                    StatusCode::UNPROCESSABLE_ENTITY
                                }
                                _ => StatusCode::NOT_FOUND,
                            };

                            let body = Full::new(Bytes::new())
                                .map_err(|e| match e {})
                                .boxed();
                            let resp = Response::builder()
                                .status(status)
                                .header("Content-Length", "0")
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
///   6. [if enable_connect] SoftMixer + Connect Player (UnifiedHttpStreamSink) + LMS + Spirc
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
    volume_ctrl_str: &str,
    passthrough: bool,
    bitrate_kbps: u32,
) -> Result<(), Box<dyn std::error::Error>> {
    // Issue #97: convert kbps to librespot Bitrate enum once, reuse everywhere.
    let bitrate_enum = match bitrate_kbps {
        96 => Bitrate::Bitrate96,
        160 => Bitrate::Bitrate160,
        _ => Bitrate::Bitrate320,
    };
    log::info!("[spoton/unified] Bitrate: {} kbps", bitrate_kbps);

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
    let volume_ctrl_enum = match volume_ctrl_str {
        "linear" => VolumeCtrl::Linear,
        "fixed" => VolumeCtrl::Fixed,
        _ => VolumeCtrl::Log(VolumeCtrl::DEFAULT_DB_RANGE),
    };

    // PCM + flush channels — only created when enable_connect (None in else branch).
    // The if/else branches below handle both cases.
    let pcm_rx_arc: Option<Arc<std::sync::Mutex<mpsc::Receiver<Bytes>>>>;
    let flush_rx_arc: Option<Arc<std::sync::Mutex<watch::Receiver<u64>>>>;
    // Phase 43 (D-03): OGG header buffer for /stream replay after drain (None when
    // enable_connect is false).
    let ogg_header_buf_arc: Option<Arc<std::sync::Mutex<Vec<Bytes>>>>;

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

        pcm_rx_arc = Some(Arc::new(std::sync::Mutex::new(pcm_rx)));
        flush_rx_arc = Some(Arc::new(std::sync::Mutex::new(flush_rx)));

        // Phase 43 (D-03): OGG header buffer — shared between the Connect sink (which
        // fills it during header collection) and the /stream handler (which replays
        // it after draining stale chunks on new connections).
        let ogg_header_buf: Arc<std::sync::Mutex<Vec<Bytes>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        ogg_header_buf_arc = Some(Arc::clone(&ogg_header_buf));

        // SoftMixer — required for Spirc volume control.
        let mixer_fn = librespot_playback::mixer::find(Some(SoftMixer::NAME))
            .ok_or("SoftMixer not found")?;
        let mixer: Arc<dyn Mixer> = mixer_fn(MixerConfig { volume_ctrl: volume_ctrl_enum, ..MixerConfig::default() })?;
        let soft_volume = mixer.get_soft_volume();

        // Connect Player with rate-limited UnifiedHttpStreamSink.
        let pcm_tx_clone = pcm_tx.clone();
        let flush_tx_for_sink = flush_tx.clone();
        let buffer_latency_ms_copy = buffer_latency_ms;
        let ogg_buf_for_sink = Arc::clone(&ogg_header_buf);
        let session_for_player = {
            let s = session_shared.lock().await;
            s.clone()
        };
        let connect_player = Player::new(
            PlayerConfig { passthrough, bitrate: bitrate_enum, ..PlayerConfig::default() },
            session_for_player,
            soft_volume,
            move || {
                UnifiedHttpStreamSink::open(
                    None,
                    AudioFormat::S16,
                    pcm_tx_clone,
                    flush_tx_for_sink,
                    buffer_latency_ms_copy,
                    ogg_buf_for_sink,
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
            event_dispatcher_handle = Some(tokio::spawn(async move {
                let mut current_track: Option<String> = None;
                while let Some(event) = event_chan.recv().await {
                    // Track spirc_active for SessionConnected/Playing/TrackChanged
                    if matches!(event,
                        PlayerEvent::SessionConnected { .. } |
                        PlayerEvent::Playing { .. } |
                        PlayerEvent::TrackChanged { .. }
                    ) {
                        sa.store(true, Ordering::SeqCst);
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

                    lms.handle_player_event(&event, &mut current_track).await;
                }
            }));
        } else {
            // No LMS configured — still need spirc_active tracking for mode transitions.
            let mut event_chan = connect_player.get_player_event_channel();
            let sa = Arc::clone(&spirc_active);
            let mode_state_w = Arc::clone(&mode_state);
            let browse_cancel_w = Arc::clone(&browse_cancel);
            event_dispatcher_handle = Some(tokio::spawn(async move {
                while let Some(event) = event_chan.recv().await {
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
            const KEYMASTER_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
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
            match librespot_discovery::Discovery::builder(device_id_shared.clone(), KEYMASTER_CLIENT_ID.to_string())
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
            bitrate_enum,
        ));

        // Main event loop — Spirc reconnect, ZeroConf, ctrl_c.
        let mut reconnect_times: Vec<std::time::Instant> = Vec::new();
        let mut last_credentials: Option<Credentials> = Some(credentials);
        let mut connecting = false;
        let mut current_spirc_task: Option<tokio::task::JoinHandle<()>> =
            Some(tokio::spawn(spirc_task));
        let mut current_discovery = discovery;

        loop {
            tokio::select! {
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
                        spirc_active.store(false, Ordering::SeqCst);
                        let session_cur = {
                            let s = session_shared.lock().await;
                            s.clone()
                        };
                        if !session_cur.is_invalid() {
                            session_cur.shutdown();
                        }
                        connecting = true;
                    }
                },

                // Reconnect with new credentials (Pitfall 6: session update for Browse too).
                _ = async {}, if connecting && last_credentials.is_some() => {
                    let session_cur = {
                        let s = session_shared.lock().await;
                        s.clone()
                    };
                    let new_session = if session_cur.is_invalid() {
                        let ns = Session::new(session_config.clone(), Some(reconnect_cache.clone()));
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

                    let new_connect_config = ConnectConfig {
                        name: device_name.to_string(),
                        device_type: DeviceType::Speaker,
                        initial_volume: initial_volume.unwrap_or(u16::MAX / 2),
                        disable_volume: false,
                        ..ConnectConfig::default()
                    };

                    if let Some(ref mf) = mixer_fn_opt {
                        match Spirc::new(
                            new_connect_config,
                            new_session,
                            last_credentials.clone().unwrap(),
                            connect_player_opt.clone().unwrap(),
                            mf(MixerConfig { volume_ctrl: volume_ctrl_enum, ..MixerConfig::default() }).unwrap_or_else(|_| panic!("mixer")),
                        ).await {
                            Ok((new_spirc, new_task)) => {
                                {
                                    let mut guard = spirc_handle.lock().unwrap_or_else(|e| e.into_inner());
                                    *guard = Some(new_spirc);
                                }
                                current_spirc_task = Some(tokio::spawn(new_task));
                                connecting = false;

                                // R-WR-07: Abort old event dispatcher and respawn with fresh
                                // player event channel. The old dispatcher's recv loop may have
                                // exited when the Player's internal sender closed during Spirc
                                // shutdown, so we must create a new one.
                                if let Some(ref h) = event_dispatcher_handle {
                                    h.abort();
                                }
                                let mut event_chan = connect_player_opt.as_ref().unwrap().get_player_event_channel();
                                if lms_for_dispatcher.is_configured() {
                                    let lms_d = lms_for_dispatcher.clone();
                                    let mode_state_d = Arc::clone(&mode_state);
                                    let sa_d = Arc::clone(&spirc_active);
                                    let browse_cancel_d = Arc::clone(&browse_cancel);
                                    event_dispatcher_handle = Some(tokio::spawn(async move {
                                        let mut current_track: Option<String> = None;
                                        while let Some(event) = event_chan.recv().await {
                                            if matches!(event,
                                                PlayerEvent::SessionConnected { .. } |
                                                PlayerEvent::Playing { .. } |
                                                PlayerEvent::TrackChanged { .. }
                                            ) {
                                                sa_d.store(true, Ordering::SeqCst);
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
                                            lms_d.handle_player_event(&event, &mut current_track).await;
                                        }
                                    }));
                                } else {
                                    let sa_d = Arc::clone(&spirc_active);
                                    let mode_state_d = Arc::clone(&mode_state);
                                    let browse_cancel_d = Arc::clone(&browse_cancel);
                                    event_dispatcher_handle = Some(tokio::spawn(async move {
                                        while let Some(event) = event_chan.recv().await {
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

                                // Send "ready" to LMS so Connect.pm re-issues playlist play
                                // after a ZeroConf credential rotation + Spirc reconnect.
                                // Skip while Browse is active — the reconnect is just restoring
                                // Spirc visibility in the Spotify app, not taking over playback.
                                let is_browsing = matches!(*mode_state.lock().await, ActiveMode::Browse(_));
                                if !is_browsing {
                                    if let Some(ref lms) = lms_for_reconnect {
                                        lms.notify("ready", "", "").await;
                                    }
                                }
                                log::debug!("[spoton/unified] Spirc reconnected");
                                { *session_created_at.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now(); }
                                browse_reconnect_pending.store(false, Ordering::Release);
                            }
                            Err(e) => {
                                browse_reconnect_pending.store(false, Ordering::Release);
                                log::error!("[spoton/unified] Spirc reconnect failed: {e}");
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
                    spirc_active.store(false, Ordering::SeqCst);

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
                    spirc_active.store(false, Ordering::SeqCst);
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
                        if !session_cur.is_invalid() {
                            session_cur.shutdown();
                        }
                        connecting = true;
                    } else {
                        eprintln!("Spirc shut down too often. Not reconnecting.");
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
            bitrate_enum,
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

