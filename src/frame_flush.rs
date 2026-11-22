//! Deadline-driven trailing frames for on-demand capture streams.
use std::time::{Duration, Instant};

const RETRY_WINDOW: Duration = Duration::from_secs(2);

#[derive(Default)]
pub(crate) struct FrameFlush {
    remaining: u32,
    next: Option<Instant>,
    refresh_at: Option<Instant>,
    trailing_after_refresh: u32,
    retry_until: Option<Instant>,
}

impl FrameFlush {
    pub(crate) fn arm(&mut self, count: u32, submitted: bool, now: Instant, interval: Duration) {
        self.retry_until = None;
        // Start ordinary trailing pictures at frame cadence. Waiting for the
        // quiet-period IDR first leaves sparse typing in the client's
        // presentation buffer for at least 100 ms.
        // Keep the independent IDR and its own trailing pictures after quiet;
        // continuous content rearms it, so motion doesn't force an IDR per tick.
        self.trailing_after_refresh = count;
        self.refresh_at = (count > 0).then_some(now + interval.max(Duration::from_millis(100)));
        // A deferred picture still needs its first submission in addition
        // to the pictures that push it through the presentation buffer.
        self.remaining = count.saturating_add(u32::from(!submitted));
        self.next = (self.remaining > 0).then_some(now + interval);
    }

    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn repaint_now(&mut self, count: u32, now: Instant) {
        self.retry_until = None;
        self.remaining = 0;
        self.next = Some(now);
        self.refresh_at = Some(now);
        self.trailing_after_refresh = count;
    }

    pub(crate) fn force_keyframe(&self) -> bool {
        self.refresh_at.is_some() && self.remaining == 0
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.next
    }

    pub(crate) fn attempted(&mut self, submitted: bool, now: Instant, interval: Duration) {
        if submitted {
            self.retry_until = None;
            if self.remaining > 0 {
                self.remaining -= 1;
            } else if self.refresh_at.take().is_some() {
                self.remaining = self.trailing_after_refresh;
            }
        } else if now >= *self.retry_until.get_or_insert(now + RETRY_WINDOW) {
            self.clear();
            return;
        }
        self.next = if self.remaining > 0 {
            Some(now + interval)
        } else {
            self.refresh_at.map(|deadline| {
                if submitted {
                    deadline.max(now)
                } else {
                    now + interval
                }
            })
        };
    }

    pub(crate) fn clear(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const INTERVAL: Duration = Duration::from_millis(16);
    const QUIET: Duration = Duration::from_millis(100);

    #[test]
    fn manual_repaint_is_immediate_retries_and_sends_trailing_frames() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.repaint_now(2, now);
        assert_eq!(flush.deadline(), Some(now));
        assert!(flush.force_keyframe());
        flush.attempted(false, now, INTERVAL);
        assert_eq!(flush.deadline(), Some(now + INTERVAL));
        assert!(flush.force_keyframe());
        for n in 1..=3 {
            flush.attempted(true, now + INTERVAL * n, INTERVAL);
            assert!(!flush.force_keyframe());
        }
        assert_eq!(flush.deadline(), None);
        flush.repaint_now(0, now);
        assert!(flush.force_keyframe());
        flush.attempted(true, now, INTERVAL);
        assert_eq!(flush.deadline(), None);
    }

    #[test]
    fn stalled_encoder_does_not_retry_forever() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(2, false, now, INTERVAL);
        let first_attempt = now + INTERVAL;
        flush.attempted(false, first_attempt, INTERVAL);
        flush.attempted(false, first_attempt + RETRY_WINDOW, INTERVAL);
        assert_eq!(flush.deadline(), None);
        assert!(!flush.force_keyframe());
    }

    #[test]
    fn sparse_typing_gets_immediate_trailing_pictures_before_quiet_refresh() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(2, true, now, INTERVAL); // l
        flush.arm(2, true, now + INTERVAL, INTERVAL); // ls supersedes l
        let last_change = now + INTERVAL;
        // Push the latest capture through presentation buffering without first
        // waiting 100 ms or forcing a keyframe for every keystroke.
        for n in 1..=2 {
            assert_eq!(flush.deadline(), Some(last_change + INTERVAL * n));
            assert!(!flush.force_keyframe());
            flush.attempted(true, last_change + INTERVAL * n, INTERVAL);
        }
        assert_eq!(flush.deadline(), Some(last_change + QUIET));
        assert!(flush.force_keyframe());
        flush.attempted(true, last_change + QUIET, INTERVAL);
        for n in 1..=2 {
            assert_eq!(flush.deadline(), Some(last_change + QUIET + INTERVAL * n));
            assert!(!flush.force_keyframe());
            flush.attempted(true, last_change + QUIET + INTERVAL * n, INTERVAL);
        }
        assert!(flush.deadline().is_none());
    }

    #[test]
    fn backpressure_preserves_both_bursts_and_retries_quiet_refresh() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(2, false, now, INTERVAL);
        for n in 1..=20 {
            flush.attempted(false, now + INTERVAL * n, INTERVAL);
            assert!(!flush.force_keyframe());
        }
        let later = now + INTERVAL * 21;
        flush.attempted(true, later, INTERVAL);
        flush.attempted(true, later + INTERVAL, INTERVAL);
        assert!(!flush.force_keyframe());
        flush.attempted(true, later + INTERVAL * 2, INTERVAL);
        assert!(flush.force_keyframe());
        assert_eq!(flush.deadline(), Some(later + INTERVAL * 2));
        flush.attempted(false, later + INTERVAL * 2, INTERVAL);
        assert!(flush.force_keyframe());
        assert_eq!(flush.deadline(), Some(later + INTERVAL * 3));
        for n in 3..=5 {
            flush.attempted(true, later + INTERVAL * n, INTERVAL);
        }
        assert!(flush.deadline().is_none());
    }

    #[test]
    fn continuous_content_postpones_idr_without_postponing_early_trailing_frames() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        for n in 0..100 {
            let change = now + INTERVAL * n;
            flush.arm(2, true, change, INTERVAL);
            assert_eq!(flush.deadline(), Some(change + INTERVAL));
            assert!(!flush.force_keyframe());
            flush.attempted(true, change + INTERVAL, INTERVAL);
            assert!(!flush.force_keyframe());
        }
    }

    #[test]
    fn idle_samples_do_not_postpone_either_deadline() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(2, true, now, INTERVAL);
        for _ in 0..100 {
            assert_eq!(flush.deadline(), Some(now + INTERVAL));
        }
        flush.attempted(true, now + INTERVAL, INTERVAL);
        flush.attempted(true, now + INTERVAL * 2, INTERVAL);
        for _ in 0..100 {
            assert_eq!(flush.deadline(), Some(now + QUIET));
            assert!(flush.force_keyframe());
        }
    }

    #[test]
    fn disabled_trailing_frames_still_retry_a_deferred_final_capture() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(0, false, now, INTERVAL);
        assert_eq!(flush.deadline(), Some(now + INTERVAL));
        assert!(!flush.force_keyframe());
        flush.attempted(false, now, INTERVAL);
        assert!(flush.deadline().is_some());
        flush.attempted(true, now, INTERVAL);
        assert!(flush.deadline().is_none());
        flush.arm(0, true, now, INTERVAL);
        assert!(flush.deadline().is_none());
    }

    #[test]
    fn fast_burst_keeps_the_quiet_idr_delay_and_the_same_frame_budget() {
        let now = Instant::now();
        let interval = Duration::from_millis(8);
        let mut flush = FrameFlush::default();
        flush.arm(2, true, now, interval);
        for n in 1..=2 {
            assert_eq!(flush.deadline(), Some(now + interval * n));
            assert!(!flush.force_keyframe());
            flush.attempted(true, now + interval * n, interval);
        }
        assert_eq!(flush.deadline(), Some(now + QUIET));
        assert!(flush.force_keyframe());
        flush.attempted(true, now + QUIET, interval);
        for n in 1..=2 {
            assert_eq!(flush.deadline(), Some(now + QUIET + interval * n));
            assert!(!flush.force_keyframe());
            flush.attempted(true, now + QUIET + interval * n, interval);
        }
        assert!(flush.deadline().is_none());
    }

    #[test]
    fn resize_or_suppression_cancels_refresh() {
        let mut flush = FrameFlush::default();
        flush.arm(4, true, Instant::now(), INTERVAL);
        flush.clear();
        flush.attempted(false, Instant::now(), INTERVAL);
        assert!(flush.deadline().is_none());
        assert!(!flush.force_keyframe());
    }

    #[test]
    fn resize_discards_a_deferred_explicit_repaint() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.repaint_now(4, now);
        flush.attempted(false, now, INTERVAL);

        flush.clear();
        flush.arm(4, true, now + INTERVAL, INTERVAL);

        assert!(!flush.force_keyframe());
        assert_eq!(flush.deadline(), Some(now + INTERVAL * 2));
    }
}
