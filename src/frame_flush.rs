//! Deadline-driven trailing frames for on-demand capture streams.
use std::time::{Duration, Instant};

#[derive(Default)]
pub(crate) struct FrameFlush {
    remaining: u32,
    next: Option<Instant>,
    refresh_pending: bool,
}

impl FrameFlush {
    pub(crate) fn arm(&mut self, count: u32, submitted: bool, now: Instant, interval: Duration) {
        // A quiet-period IDR refreshes small changes independently of the
        // preceding prediction chain. Keep all requested trailing pictures
        // AFTER that refresh to drain the client's presentation queue.
        // With trailing refresh disabled, a deferred real capture still needs
        // one retry: an explicit zero must not discard the final keystroke.
        self.refresh_pending = count > 0;
        self.remaining = if count > 0 {
            count.saturating_add(1)
        } else {
            u32::from(!submitted)
        };
        let delay = if self.refresh_pending {
            interval.max(Duration::from_millis(100))
        } else {
            interval
        };
        self.next = (self.remaining > 0).then_some(now + delay);
    }

    pub(crate) fn force_keyframe(&self) -> bool {
        self.refresh_pending
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.next
    }

    pub(crate) fn attempted(&mut self, submitted: bool, now: Instant, interval: Duration) {
        if submitted {
            self.refresh_pending = false;
            self.remaining = self.remaining.saturating_sub(1);
        }
        self.next = (self.remaining > 0).then_some(now + interval);
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
    fn typing_ls_then_stopping_refreshes_latest_frame_before_trailing_frames() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(2, true, now, INTERVAL); // l
        flush.arm(2, true, now + INTERVAL, INTERVAL); // ls supersedes l
        assert_eq!(flush.deadline(), Some(now + INTERVAL + QUIET));
        assert!(flush.force_keyframe());
        flush.attempted(true, now + INTERVAL + QUIET, INTERVAL);
        assert!(!flush.force_keyframe());
        for _ in 0..2 {
            assert!(flush.deadline().is_some());
            flush.attempted(true, now + QUIET, INTERVAL);
        }
        assert!(flush.deadline().is_none());
    }

    #[test]
    fn backpressure_does_not_consume_refresh_or_trailing_budget() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(2, false, now, INTERVAL);
        for _ in 0..20 {
            flush.attempted(false, now, INTERVAL);
            assert!(flush.force_keyframe());
        }
        for _ in 0..3 {
            assert!(flush.deadline().is_some());
            flush.attempted(true, now, INTERVAL);
        }
        assert!(flush.deadline().is_none());
    }

    #[test]
    fn idle_samples_do_not_postpone_refresh_deadline() {
        let now = Instant::now();
        let mut flush = FrameFlush::default();
        flush.arm(2, true, now, INTERVAL);
        for _ in 0..100 {
            assert_eq!(flush.deadline(), Some(now + QUIET));
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
    fn resize_or_suppression_cancels_refresh() {
        let mut flush = FrameFlush::default();
        flush.arm(4, true, Instant::now(), INTERVAL);
        flush.clear();
        assert!(flush.deadline().is_none());
        assert!(!flush.force_keyframe());
    }
}
