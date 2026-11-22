use std::ffi::c_void;
use std::ptr::NonNull;
use std::time::{Duration, Instant};

unsafe extern "C" {
    fn macrdp_audio_tap_open(error: *mut i32) -> *mut c_void;
    fn macrdp_audio_tap_close(tap: *mut c_void);
    fn macrdp_audio_tap_output_running() -> bool;
    fn macrdp_audio_tap_read(
        tap: *mut c_void,
        left: *mut f32,
        right: *mut f32,
        capacity: u32,
        age_nanos: *mut u64,
    ) -> u32;
}

pub(super) struct CoreAudioTap {
    native: NonNull<c_void>,
    next_silence_at: Instant,
    last_health_check: Instant,
    missing_while_playing: bool,
}

impl CoreAudioTap {
    pub(super) fn open() -> Result<Self, i32> {
        let mut error = 0;
        let tap = unsafe { macrdp_audio_tap_open(&mut error) };
        let native = NonNull::new(tap).ok_or(error)?;
        let now = Instant::now();
        Ok(Self {
            native,
            next_silence_at: now + Duration::from_millis(25),
            last_health_check: now,
            missing_while_playing: false,
        })
    }

    pub(super) async fn next(
        &mut self,
        stats: Option<&crate::stats::SessionStats>,
    ) -> Option<(Vec<f32>, Vec<f32>)> {
        // Must match TapMaxFrames in audio_tap.m.
        const MAX_FRAMES: usize = 1024;
        let mut left = [0.0; MAX_FRAMES];
        let mut right = [0.0; MAX_FRAMES];
        let mut age_nanos = u64::MAX;
        loop {
            let frames = unsafe {
                macrdp_audio_tap_read(
                    self.native.as_ptr(),
                    left.as_mut_ptr(),
                    right.as_mut_ptr(),
                    MAX_FRAMES as u32,
                    &mut age_nanos,
                )
            } as usize;
            let now = Instant::now();
            if frames != 0 {
                // Even a 512-frame device normally delivers several buffers
                // within 25 ms. Wait for a genuine gap before adding silence.
                self.next_silence_at = now + Duration::from_millis(25);
                self.last_health_check = now;
                self.missing_while_playing = false;
                if let Some(stats) = stats {
                    if age_nanos <= Duration::from_secs(10).as_nanos() as u64 {
                        stats
                            .audio_capture_age
                            .record(Duration::from_nanos(age_nanos));
                    }
                }
                return Some((left[..frames].to_vec(), right[..frames].to_vec()));
            }
            if now >= self.next_silence_at {
                if now.duration_since(self.last_health_check) >= Duration::from_millis(750) {
                    self.last_health_check = now;
                    let playing = unsafe { macrdp_audio_tap_output_running() };
                    if playing && self.missing_while_playing {
                        return None;
                    }
                    self.missing_while_playing = playing;
                }
                // An idle output can stop the hardware callback. Keep the
                // client clock fed while allowing the tap to wake up again.
                let next = self.next_silence_at + Duration::from_millis(10);
                self.next_silence_at = if next <= now {
                    now + Duration::from_millis(10)
                } else {
                    next
                };
                let muted = vec![0.0; super::RESAMPLE_CHUNK];
                return Some((muted.clone(), muted));
            }
            // Poll on the dedicated audio worker. The real-time Core Audio
            // callback only copies into its preallocated buffer.
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }
}

impl Drop for CoreAudioTap {
    fn drop(&mut self) {
        unsafe { macrdp_audio_tap_close(self.native.as_ptr()) };
    }
}
