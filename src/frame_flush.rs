//! Deadline-driven trailing frames for on-demand capture streams.
use std::time::{Duration, Instant};

#[derive(Default)]
pub(crate) struct FrameFlush {
    remaining: u32,
    next: Option<Instant>,
    refresh_at: Option<Instant>,
    trailing_after_refresh: u32,
}

impl FrameFlush {
    pub(crate) fn arm(&mut self, count: u32, submitted: bool, now: Instant, interval: Duration) {
        // Start ordinary trailing pictures at frame cadence. Waiting for the
        // quiet-period IDR first leaves sparse typing in the client's
        // presentation buffer for at least 100 ms.
        // Keep the independent IDR and its own trailing pictures after quiet;
        // continuous content rearms it, so motion doesn't force an IDR per tick.
        self.trailing_after_refresh = count;
        self.refresh_at = (count > 0).then_some(now + interval.max(Duration::from_millis(100)));
        self.remaining = if count > 0 {
            count
        } else {
            u32::from(!submitted)
        };
        self.next = (self.remaining > 0).then_some(now + interval);
    }

    pub(crate) fn force_keyframe(&self) -> bool {
        self.refresh_at.is_some() && self.remaining == 0
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.next
    }

    pub(crate) fn attempted(&mut self, submitted: bool, now: Instant, interval: Duration) {
        if submitted {
            if self.remaining > 0 {
                self.remaining -= 1;
            } else if self.refresh_at.take().is_some() {
                self.remaining = self.trailing_after_refresh;
            }
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
        assert!(flush.force_keyframe());
        assert_eq!(flush.deadline(), Some(later + INTERVAL));
        flush.attempted(false, later + INTERVAL, INTERVAL);
        assert!(flush.force_keyframe());
        assert_eq!(flush.deadline(), Some(later + INTERVAL * 2));
        for n in 2..=4 {
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
}
