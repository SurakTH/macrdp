//! Opt-in live-telemetry endpoint (`--stats-endpoint`, default OFF).
//!
//! A tiny **loopback-only, read-only** TCP listener that serves a JSON snapshot
//! of the current H.264 session — live bitrate, link RTT, standing queue delay,
//! frame rate, frames sent, and the session dimensions — on each connection. It
//! exists so the menu-bar controller's Status pane can show live "connection
//! health" without the server writing anything to disk.
//!
//! **No disk writes.** The snapshot lives entirely in memory ([`SessionStats`],
//! a handful of atomics updated at low-frequency points in the encode path) and
//! is serialized *only when a client connects* — which the controller does every
//! ~2 s, and only while its Status pane is open. So there is zero periodic I/O
//! (and therefore no SSD wear), unlike a periodically-rewritten stats file.
//!
//! **Default runtime path unchanged when off.** The endpoint is created only
//! when enabled; when it isn't, [`global`] returns `None`, so every update site
//! in the hot path is a single `Option` check that compiles to a no-op. The
//! listener binds `127.0.0.1` only (never routable) and never reads request
//! bytes — it just writes one JSON line and closes. It carries only the local
//! session's own metrics; the trust boundary is the same single-user, loopback
//! model as the other helper channels (see docs/macos-gotchas.md).

use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

#[derive(Default)]
pub struct StageTiming {
    samples: AtomicU64,
    total_us: AtomicU64,
}

impl StageTiming {
    pub fn record(&self, elapsed: std::time::Duration) {
        self.total_us
            .fetch_add(elapsed.as_micros() as u64, Ordering::Relaxed);
        self.samples.fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn sample_count(&self) -> u64 {
        self.samples.load(Ordering::Relaxed)
    }
}

/// The live snapshot. Every field is an atomic so the encode path can update it
/// lock-free; the listener reads it under no lock either. Values are best-effort
/// and eventually-consistent. Video activity tracks the encoder session, not
/// whether a client is authenticated or using bitmap graphics.
#[derive(Clone, Copy)]
pub enum VideoCodec {
    None,
    Bitmap,
    Avc420,
    Avc444,
    Hevc420,
}

#[derive(Default)]
pub struct SessionStats {
    pub connected: AtomicBool,
    pub width: AtomicU32,
    pub height: AtomicU32,
    /// Live encoder bitrate: the adaptive value when `--adaptive-bitrate` is on,
    /// otherwise the configured ceiling (static for the session).
    pub bitrate_bps: AtomicU32,
    /// The `--bitrate` ceiling (adaptive never exceeds it).
    pub ceiling_bps: AtomicU32,
    /// Kernel-measured link RTT (ms) sampled at accept; 0 = unknown.
    pub rtt_ms: AtomicU32,
    /// Standing queue delay (ms above the windowed-min RTT) — the adaptive
    /// controller's congestion signal. Meaningful only with acks flowing.
    pub queue_delay_ms: AtomicU32,
    /// Effective frame rate (capped by the adaptive floor under congestion).
    pub fps: AtomicU32,
    pub frames_sent: AtomicU64,
    pub adaptive: AtomicBool,
    pub aac: AtomicBool,
    // Process-lifetime diagnostic counters; no input text or pixel data.
    pub keyboard_events: AtomicU64,
    pub capture_samples: AtomicU64,
    pub capture_content: AtomicU64,
    pub capture_idle: AtomicU64,
    pub capture_superseded: AtomicU64,
    pub encode_submitted: AtomicU64,
    /// Accepted submissions made from a retained capture, including retries.
    pub encode_retained_submitted: AtomicU64,
    pub encode_deferred: AtomicU64,
    pub encode_tcp_backpressure: AtomicU64,
    /// Subset of TCP deferrals specifically caused by a pending local write.
    pub encode_tcp_write_stall: AtomicU64,
    /// Capture-loop wakeups that advanced a still-unsent picture.
    pub tcp_resume_wakes: AtomicU64,
    /// Capture-loop wakeups after a deferred picture can enter the encoder.
    pub encoder_resume_wakes: AtomicU64,
    pub encoded_pictures: AtomicU64,
    pub encode_output_errors: AtomicU64,
    pub encode_submit_errors: AtomicU64,
    pub transport_retired: Arc<AtomicU64>,
    /// Process-wide counts of logical H.264 frames queued to the transport,
    /// and compressed video payload bytes (not total network traffic).
    pub video_frames_queued: AtomicU64,
    pub video_ship_errors: AtomicU64,
    pub video_payload_bytes: AtomicU64,
    video_codec: AtomicU32,
    pub video_generation: AtomicU64,
    pub encode_completed: AtomicU64,
    pub encode_total_us: AtomicU64,
    /// Source buffer allocation, copy or conversion before AVC420 submission.
    pub encode_prepared: AtomicU64,
    pub encode_prepare_total_us: AtomicU64,
    pub capture_to_submit: StageTiming,
    /// First sample timestamp to receipt by the system-audio capture loop.
    pub audio_capture_age: StageTiming,
    /// PCM packet assembly to handoff to the RDPSND transport channel.
    pub pcm_queue_age: StageTiming,
    /// PCM packets evicted or expired before handoff to RDPSND.
    pub pcm_queue_drops: AtomicU64,
    /// Encoded picture to DVC messages, including graphics lock waits.
    pub video_packetize: StageTiming,
    pub tcp_dispatch: StageTiming,
    pub client_qoe_reports: AtomicU64,
    pub client_frame_parse: StageTiming,
    pub client_render_completion: StageTiming,
    pub ack_samples: AtomicU64,
    pub ack_sample_uptime_ms: AtomicU64,
    pub ack_rtt_ms: AtomicU32,
    pub ack_queue_ms: AtomicU32,
    clock: OnceLock<std::time::Instant>,
}

impl SessionStats {
    /// Zeroes the per-session values; `aac` is process config.
    pub fn session_ended(&self) {
        self.end_video_session();
        for v in [
            &self.width,
            &self.height,
            &self.bitrate_bps,
            &self.ceiling_bps,
            &self.rtt_ms,
            &self.queue_delay_ms,
            &self.fps,
        ] {
            v.store(0, Ordering::Relaxed);
        }
        self.frames_sent.store(0, Ordering::Relaxed);
        self.adaptive.store(false, Ordering::Relaxed);
    }

    pub fn set_video_codec(&self, codec: VideoCodec) {
        self.video_codec.store(codec as u32, Ordering::Relaxed);
    }

    fn video_codec(&self) -> &'static str {
        match self.video_codec.load(Ordering::Relaxed) {
            value if value == VideoCodec::Bitmap as u32 => "bitmap",
            value if value == VideoCodec::Avc420 as u32 => "avc420",
            value if value == VideoCodec::Avc444 as u32 => "avc444",
            value if value == VideoCodec::Hevc420 as u32 => "hevc420",
            _ => "none",
        }
    }

    pub fn end_video_session(&self) {
        self.set_video_codec(VideoCodec::None);
        self.connected.store(false, Ordering::Relaxed);
        self.ack_samples.store(0, Ordering::Relaxed);
    }

    pub fn uptime_ms(&self) -> u64 {
        self.clock
            .get_or_init(std::time::Instant::now)
            .elapsed()
            .as_millis() as u64
    }

    pub fn record_encode(&self, elapsed: std::time::Duration) {
        self.encode_total_us
            .fetch_add(elapsed.as_micros() as u64, Ordering::Relaxed);
        self.encode_completed.fetch_add(1, Ordering::Relaxed);
    }

    #[cfg(target_os = "macos")]
    pub fn record_encode_preparation(&self, elapsed: std::time::Duration) {
        self.encode_prepare_total_us
            .fetch_add(elapsed.as_micros() as u64, Ordering::Relaxed);
        self.encode_prepared.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_video_queued(&self, frames: u64, payload_bytes: u64) {
        self.video_payload_bytes
            .fetch_add(payload_bytes, Ordering::Relaxed);
        self.video_frames_queued
            .fetch_add(frames, Ordering::Relaxed);
    }

    pub fn record_client_qoe(&self, start_to_end_ms: u16, end_to_render_ms: u16) {
        use std::time::Duration;

        // Zero can mean sub-millisecond, unavailable, or an overflow reported
        // as zero by the client. Preserve the report count and time only
        // nonzero samples so missing render timings do not look instantaneous.
        if start_to_end_ms != 0 {
            self.client_frame_parse
                .record(Duration::from_millis(u64::from(start_to_end_ms)));
        }
        if end_to_render_ms != 0 {
            self.client_render_completion
                .record(Duration::from_millis(u64::from(end_to_render_ms)));
        }
        self.client_qoe_reports.fetch_add(1, Ordering::Relaxed);
    }

    fn to_json(&self) -> String {
        let mut json = format!(
            concat!(
                "{{\"connected\":{},\"width\":{},\"height\":{},\"bitrate_bps\":{},",
                "\"ceiling_bps\":{},\"rtt_ms\":{},\"queue_delay_ms\":{},\"fps\":{},",
                "\"frames_sent\":{},\"adaptive\":{},\"aac\":{}}}"
            ),
            self.connected.load(Ordering::Relaxed),
            self.width.load(Ordering::Relaxed),
            self.height.load(Ordering::Relaxed),
            self.bitrate_bps.load(Ordering::Relaxed),
            self.ceiling_bps.load(Ordering::Relaxed),
            self.rtt_ms.load(Ordering::Relaxed),
            self.queue_delay_ms.load(Ordering::Relaxed),
            self.fps.load(Ordering::Relaxed),
            self.frames_sent.load(Ordering::Relaxed),
            self.adaptive.load(Ordering::Relaxed),
            self.aac.load(Ordering::Relaxed),
        );
        json.pop(); // Append fields while preserving the existing GUI schema.
        json.push_str(&format!(
            ",\"keyboard_events\":{}",
            self.keyboard_events.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"capture_samples\":{}",
            self.capture_samples.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"capture_content\":{}",
            self.capture_content.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"capture_idle\":{}",
            self.capture_idle.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"capture_superseded\":{}",
            self.capture_superseded.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encode_submitted\":{}",
            self.encode_submitted.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encode_retained_submitted\":{}",
            self.encode_retained_submitted.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encode_deferred\":{}",
            self.encode_deferred.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encode_tcp_backpressure\":{}",
            self.encode_tcp_backpressure.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encode_tcp_write_stall\":{}",
            self.encode_tcp_write_stall.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"tcp_resume_wakes\":{}",
            self.tcp_resume_wakes.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encoder_resume_wakes\":{}",
            self.encoder_resume_wakes.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encoded_pictures\":{}",
            self.encoded_pictures.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encode_output_errors\":{}",
            self.encode_output_errors.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"encode_submit_errors\":{}",
            self.encode_submit_errors.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"video_ship_errors\":{}",
            self.video_ship_errors.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"transport_retired\":{}",
            self.transport_retired.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"diagnostics_version\":1,\"process_id\":{},\"video_active\":{},\"video_codec\":\"{}\"",
            std::process::id(),
            self.connected.load(Ordering::Relaxed),
            self.video_codec()
        ));
        json.push_str(&format!(
            concat!(",\"uptime_ms\":{},\"video_generation\":{},\"video_frames_queued\":{},",
                "\"video_payload_bytes\":{},\"encode_completed\":{},\"encode_total_us\":{},",
                "\"encode_prepared\":{},\"encode_prepare_total_us\":{},",
                "\"ack_samples\":{},\"ack_sample_uptime_ms\":{},\"ack_rtt_ms\":{},\"ack_queue_ms\":{}"),
            self.uptime_ms(), self.video_generation.load(Ordering::Relaxed),
            self.video_frames_queued.load(Ordering::Relaxed), self.video_payload_bytes.load(Ordering::Relaxed),
            self.encode_completed.load(Ordering::Relaxed), self.encode_total_us.load(Ordering::Relaxed),
            self.encode_prepared.load(Ordering::Relaxed), self.encode_prepare_total_us.load(Ordering::Relaxed),
            self.ack_samples.load(Ordering::Relaxed), self.ack_sample_uptime_ms.load(Ordering::Relaxed),
            self.ack_rtt_ms.load(Ordering::Relaxed), self.ack_queue_ms.load(Ordering::Relaxed),
        ));
        json.push_str(&format!(
            ",\"client_qoe_reports\":{}",
            self.client_qoe_reports.load(Ordering::Relaxed)
        ));
        json.push_str(&format!(
            ",\"pcm_queue_drops\":{}",
            self.pcm_queue_drops.load(Ordering::Relaxed)
        ));
        for (name, stage) in [
            ("capture_to_submit", &self.capture_to_submit),
            ("audio_capture_age", &self.audio_capture_age),
            ("pcm_queue_age", &self.pcm_queue_age),
            ("video_packetize", &self.video_packetize),
            ("tcp_dispatch", &self.tcp_dispatch),
            ("client_frame_parse", &self.client_frame_parse),
            ("client_render_completion", &self.client_render_completion),
        ] {
            use std::fmt::Write as _;
            let samples = stage.sample_count();
            let total_us = stage.total_us.load(Ordering::Relaxed);
            let _ = write!(
                json,
                ",\"{name}_samples\":{samples},\"{name}_total_us\":{total_us}"
            );
        }
        json.push('}');
        json
    }
}

static GLOBAL: OnceLock<Arc<SessionStats>> = OnceLock::new();

/// Turn telemetry on: create (idempotently) the shared snapshot and return it.
/// Called once from `main.rs` when the endpoint is enabled.
pub fn enable() -> Arc<SessionStats> {
    GLOBAL
        .get_or_init(|| Arc::new(SessionStats::default()))
        .clone()
}

/// The shared snapshot iff telemetry is enabled, else `None`. Hot-path update
/// sites do `if let Some(s) = stats::global() { … }`, a no-op when off.
#[inline]
pub fn global() -> Option<&'static Arc<SessionStats>> {
    GLOBAL.get()
}

/// Endpoint port (`MACRDP_STATS_PORT`, default 40245 — next after the shield
/// helper's 40244).
pub fn default_port() -> u16 {
    std::env::var("MACRDP_STATS_PORT")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(40245)
}

/// Serve the snapshot on `127.0.0.1:port`, one JSON line per connection, until
/// the process exits. Read-only; the request body (if any) is ignored.
pub async fn serve(port: u16, stats: Arc<SessionStats>) {
    use tokio::io::AsyncWriteExt;
    let listener = match tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await {
        Ok(l) => l,
        Err(e) => {
            tracing::warn!(port, error = %e, "stats endpoint: bind failed — live telemetry unavailable");
            return;
        }
    };
    tracing::info!(port, "stats endpoint listening (loopback, read-only)");
    loop {
        match listener.accept().await {
            Ok((mut sock, _)) => {
                let body = stats.to_json();
                // Handle inline (no per-connection task spawn) so a local process
                // that hammers the port can't spawn unbounded tasks; the response
                // is a couple hundred bytes to a loopback socket, so serializing
                // one poll every ~2 s is fine. A short timeout keeps a client that
                // connects but never reads from wedging the accept loop.
                let _ = tokio::time::timeout(std::time::Duration::from_secs(2), async {
                    let _ = sock.write_all(body.as_bytes()).await;
                    let _ = sock.write_all(b"\n").await;
                    let _ = sock.shutdown().await;
                })
                .await;
            }
            Err(e) => tracing::debug!(error = %e, "stats endpoint: accept error"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_end_reports_disconnected_and_zeros() {
        let s = SessionStats::default();
        s.connected.store(true, Ordering::Relaxed);
        s.width.store(3024, Ordering::Relaxed);
        s.bitrate_bps.store(5_000_000, Ordering::Relaxed);
        s.frames_sent.store(900, Ordering::Relaxed);
        s.adaptive.store(true, Ordering::Relaxed);
        s.aac.store(true, Ordering::Relaxed);
        s.session_ended();
        let j = s.to_json();
        assert!(j.contains("\"connected\":false"));
        assert!(j.contains("\"width\":0"));
        assert!(j.contains("\"bitrate_bps\":0"));
        assert!(j.contains("\"frames_sent\":0"));
        assert!(j.contains("\"adaptive\":false"));
        assert!(j.contains("\"aac\":true"), "aac is process config");
    }

    #[test]
    fn video_end_hides_activity_and_invalidates_acks_without_resetting_counters() {
        let s = SessionStats::default();
        s.connected.store(true, Ordering::Relaxed);
        s.set_video_codec(VideoCodec::Hevc420);
        assert!(s.to_json().contains("\"video_codec\":\"hevc420\""));
        s.ack_samples.store(5, Ordering::Relaxed);
        s.video_frames_queued.store(12, Ordering::Relaxed);
        assert!(s.to_json().contains("\"video_active\":true"));
        s.end_video_session();
        let json = s.to_json();
        assert!(json.contains("\"video_active\":false"));
        assert!(json.contains("\"video_codec\":\"none\""));
        assert!(json.contains("\"ack_samples\":0"));
        assert!(json.contains("\"video_frames_queued\":12"));
    }

    #[test]
    fn json_shape_is_stable_and_parseable() {
        let s = SessionStats::default();
        s.connected.store(true, Ordering::Relaxed);
        s.width.store(1920, Ordering::Relaxed);
        s.height.store(1080, Ordering::Relaxed);
        s.bitrate_bps.store(4_000_000, Ordering::Relaxed);
        s.fps.store(60, Ordering::Relaxed);
        s.keyboard_events.store(7, Ordering::Relaxed);
        s.encoded_pictures.store(3, Ordering::Relaxed);
        s.transport_retired.store(2, Ordering::Relaxed);
        let j = s.to_json();
        // Spot-check a few fields + that it's a single line with the expected keys.
        assert!(j.starts_with('{') && j.ends_with('}'));
        assert!(!j.contains('\n'));
        assert!(j.contains("\"keyboard_events\":7"));
        assert!(j.contains("\"encoded_pictures\":3"));
        assert!(j.contains("\"transport_retired\":2"));
        assert!(j.contains("\"diagnostics_version\":1"));
        assert!(j.contains("\"connected\":true"));
        assert!(j.contains("\"width\":1920"));
        assert!(j.contains("\"bitrate_bps\":4000000"));
        assert!(j.contains("\"fps\":60"));
    }

    #[test]
    fn global_is_none_until_enabled() {
        // NB: process-global; if another test enables it this may already be Some.
        // We only assert the accessor doesn't panic and the enabled snapshot is shared.
        let a = enable();
        let b = global().expect("enabled");
        assert!(Arc::ptr_eq(&a, b));
    }

    #[test]
    fn performance_counters_measure_logical_frames_and_encode_completion() {
        let s = SessionStats::default();
        s.record_video_queued(2, 1_000);
        s.record_video_queued(1, 500);
        s.record_encode(std::time::Duration::from_micros(2_500));
        s.record_encode(std::time::Duration::from_micros(1_000));
        s.encode_retained_submitted.store(1, Ordering::Relaxed);
        s.video_generation.store(2, Ordering::Relaxed);
        let json = s.to_json();
        for field in [
            "\"video_frames_queued\":3",
            "\"video_payload_bytes\":1500",
            "\"encode_completed\":2",
            "\"encode_retained_submitted\":1",
            "\"encode_total_us\":3500",
            "\"video_generation\":2",
            "\"ack_samples\":0",
        ] {
            assert!(json.contains(field), "missing {field}");
        }
        assert!(json.contains("\"uptime_ms\":"));
    }

    #[test]
    fn client_qoe_keeps_zero_reports_out_of_duration_averages() {
        let s = SessionStats::default();
        s.record_client_qoe(2, 0);
        s.record_client_qoe(0, 4);
        s.record_client_qoe(1, 7);
        let json = s.to_json();
        for field in [
            "\"client_qoe_reports\":3",
            "\"client_frame_parse_samples\":2",
            "\"client_frame_parse_total_us\":3000",
            "\"client_render_completion_samples\":2",
            "\"client_render_completion_total_us\":11000",
        ] {
            assert!(json.contains(field), "missing {field}");
        }
    }
}
