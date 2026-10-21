// browse.rs — SpotOn Browse HTTP streaming support
//
// Used by unified.rs for Browse mode track serving.
//
// Responsibilities:
//   - BrowseHttpSink: unbuffered PCM sink (no rate-limiting — no Spirc position sync)
//   - serve_track_request(): per-request handler — load Player, stream PCM, close on EOF/Unavailable
//   - empty_response(): helper for building empty HTTP error responses
//
// Key differences from connect.rs:
//   - NO Spirc (no Connect crate) — browse sessions are invisible to Spotify app (Pitfall 1)
//   - NO rate-limiting in BrowseHttpSink (Pitfall 3)
//   - NO flush watch-channel — seek is via ?start_position=N query param
//   - Per-request Player instances for concurrent requests (D-04, Pitfall 2)
//   - HTTP endpoint: GET /track/{id} (served by unified.rs HTTP router)

use std::convert::Infallible;
use std::time::Duration;
use std::sync::Arc;

use crate::metadata::MetadataStore;

use bytes::Bytes;
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use hyper::{Response, StatusCode};
use tokio::sync::mpsc;

use librespot_core::{Session, SpotifyUri};
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::{Player, PlayerEvent};

// -------------------------------------------------------------------------
// BrowseHttpSink — unbuffered PCM sender, no rate-limiting
// -------------------------------------------------------------------------

/// Audio sink for --browse mode.
///
/// Unlike HttpStreamSink in connect.rs, this sink does NOT rate-limit PCM delivery.
/// Browse mode has no Spirc position sync — PCM should be sent as fast as librespot
/// produces it (Pitfall 3). LMS controls playback timing via its own audio buffer.
///
/// stop() is a no-op — daemon outlives track boundaries (same as HttpStreamSink,
/// but without the frame counter reset since there is nothing to reset here).
pub struct BrowseHttpSink {
    pcm_tx: mpsc::Sender<Bytes>,
}

impl BrowseHttpSink {
    /// Construct a new BrowseHttpSink.
    ///
    /// Only AudioFormat::S16 is supported — panics on any other format.
    /// The factory closure passed to Player::new() captures `pcm_tx` by clone.
    pub fn open(
        _device: Option<String>,
        format: AudioFormat,
        pcm_tx: mpsc::Sender<Bytes>,
    ) -> Box<dyn Sink> {
        if format != AudioFormat::S16 {
            panic!(
                "BrowseHttpSink: only AudioFormat::S16 supported, got {:?}",
                format
            );
        }
        Box::new(Self { pcm_tx })
    }
}

impl Sink for BrowseHttpSink {
    fn start(&mut self) -> SinkResult<()> {
        // No state to initialise — Browse daemon is stateless per-packet.
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        // CRITICAL: do NOT call exit() here (same as HttpStreamSink Pitfall 1).
        // Browse daemon outlives track boundaries — stop() is called between tracks,
        // NOT when the process should exit.
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let chunk = match packet {
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
                Bytes::copy_from_slice(bytes)
            }
            AudioPacket::Raw(bytes) => {
                // Phase 42: Forward raw Ogg/Vorbis pages as-is (passthrough mode).
                Bytes::copy_from_slice(&bytes)
            }
        };

        // try_send loop: channel has 256 slots (~1.5s of audio).
        // Spin on Full (backpressure from LMS reading PCM at real-time speed).
        // Return SinkError on Closed (HTTP client disconnected, LMS gave up).
        // NOTE: No wall-clock sleep or frame accounting — Browse has no Spirc position sync.
        loop {
            match self.pcm_tx.try_send(chunk.clone()) {
                Ok(()) => break,
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                    std::thread::sleep(Duration::from_millis(1));
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    return Err(SinkError::OnWrite(
                        "Browse HTTP connection closed".into(),
                    ));
                }
            }
        }

        Ok(())
    }
}

// -------------------------------------------------------------------------
// run_browse — entry point
// -------------------------------------------------------------------------

/// Run the Browse daemon: load credentials, connect session, bind port, serve HTTP.
///
/// Contract:
///   stdout line 1: "browse_port=N"   (N = dynamically assigned TCP port)
///   stdout is flushed immediately (Perl IO::Select requires this — Pitfall 5)
///
/// Session is persistent — audio keys are cached across track boundaries.
/// Daemon runs until killed by DaemonManager.

/// Build an empty response body (for error responses).
pub fn empty_response(status: StatusCode) -> Response<BoxBody<Bytes, hyper::Error>> {
    let body = Full::new(Bytes::new())
        .map_err(|e: Infallible| match e {})
        .boxed();
    Response::builder()
        .status(status)
        .header("Content-Length", "0")
        .body(body)
        .expect("empty response builder")
}

// -------------------------------------------------------------------------
// serve_track_request — per-request track handler
// -------------------------------------------------------------------------

/// Load a single track and stream decoded PCM into `pcm_tx`.
///
/// Returns the HTTP status that should be sent to the client:
///   - StatusCode::OK (200) on EndOfTrack / Stopped — normal completion
///   - StatusCode::NOT_FOUND (404) on Unavailable — track not in catalog or region-locked
///   - StatusCode::INTERNAL_SERVER_ERROR on unexpected channel close
///
/// Per-request Player instances: a new Player is created for each request.
/// The Session is shared — audio keys cached at session level are reused across
/// Players on the same session, preserving the audio-key caching benefit (Pitfall 2 / D-04).
pub async fn serve_track_request(
    content_type: &str,
    track_id: &str,
    session: Session,
    pcm_tx: mpsc::Sender<Bytes>,
    start_position_ms: u32,
    passthrough: bool,
    bitrate: Bitrate,
    normalisation: bool,
    metadata: Arc<MetadataStore>,
) -> StatusCode {
    // Create a per-request Player.
    // The factory closure captures a clone of pcm_tx for BrowseHttpSink.
    // Player::new() spawns its own std::thread with tokio Runtime for decoding.
    let pcm_tx_clone = pcm_tx.clone();
    let player = Player::new(
        PlayerConfig { passthrough, bitrate, normalisation, ..PlayerConfig::default() },
        session,
        Box::new(NoOpVolume),
        move || BrowseHttpSink::open(None, AudioFormat::S16, pcm_tx_clone),
    );

    // Build Spotify URI from validated ID — "track" or "episode".
    let uri_str = format!("spotify:{}:{}", content_type, track_id);
    let uri = match SpotifyUri::from_uri(&uri_str) {
        Ok(u) => u,
        Err(e) => {
            log::warn!("[spoton/browse] SpotifyUri::from_uri failed for {}: {}", uri_str, e);
            return StatusCode::BAD_REQUEST;
        }
    };

    // Load and start playback.
    // true = play immediately, start_position_ms = seek offset (0 for normal start).
    let mut events = player.get_player_event_channel();
    player.load(uri, true, start_position_ms);

    // Event loop: wait for Unavailable (404) or EndOfTrack/Stopped (200).
    // Other events (Loading, Playing, VolumeChanged, etc.) are ignored.
    loop {
        match events.recv().await {
            Some(PlayerEvent::TrackChanged { audio_item }) => {
                metadata.remember(&audio_item);
            }
            Some(PlayerEvent::Unavailable { track_id: tid, .. }) => {
                log::info!("[spoton/browse] track {} unavailable", tid);
                return StatusCode::NOT_FOUND;
            }
            Some(PlayerEvent::EndOfTrack { .. }) => {
                log::debug!("[spoton/browse] track {} EndOfTrack", track_id);
                // pcm_tx is dropped here (out of scope), which closes the channel and
                // signals EOF to the ReceiverStream → StreamBody → LMS HTTP client.
                return StatusCode::OK;
            }
            Some(PlayerEvent::Stopped { .. }) => {
                log::debug!("[spoton/browse] track {} Stopped", track_id);
                return StatusCode::OK;
            }
            Some(_) => {
                // Ignore other events (Loading, Playing, etc.).
                continue;
            }
            None => {
                // Player event channel closed unexpectedly (Player dropped or panicked).
                log::warn!("[spoton/browse] player event channel closed for track {}", track_id);
                return StatusCode::INTERNAL_SERVER_ERROR;
            }
        }
    }
}
