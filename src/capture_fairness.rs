//! ScreenCaptureKit's custom future does not consume Tokio's cooperative
//! budget when samples are already buffered. The capture loop shares one task
//! with input and transport dispatch, so it must explicitly yield each turn.
pub(crate) async fn yield_capture_turn() {
    tokio::task::yield_now().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    // Model client_loop's sibling select branches with continuously ready SCK
    // samples. A finite cap makes the pre-fix starvation fail without hanging
    // the test runner (a timeout cannot run while its task is monopolized).
    async fn hot_capture_turns_before_dispatch(cooperate: bool) -> usize {
        let turns = Arc::new(AtomicUsize::new(0));
        let (video_tx, mut video_rx) = tokio::sync::mpsc::unbounded_channel();
        let (keyboard_tx, mut keyboard_rx) = tokio::sync::mpsc::unbounded_channel();
        keyboard_tx.send("ls\n").unwrap();
        let capture = async {
            for _ in 0..1024 {
                if cooperate {
                    yield_capture_turn().await;
                }
                // SCK's custom future can be immediately ready, unlike Tokio
                // channel receives that consume its cooperative budget.
                std::future::ready(()).await;
                turns.fetch_add(1, Ordering::Relaxed);
                video_tx.send(()).unwrap();
            }
            turns.load(Ordering::Relaxed)
        };
        let dispatch = async {
            assert_eq!(keyboard_rx.recv().await, Some("ls\n"));
            assert_eq!(video_rx.recv().await, Some(()));
            turns.load(Ordering::Relaxed)
        };
        tokio::select! {
            biased;
            count = capture => count,
            count = dispatch => count,
        }
    }

    #[tokio::test]
    async fn reproduces_starvation_without_a_capture_yield() {
        assert_eq!(hot_capture_turns_before_dispatch(false).await, 1024);
    }

    #[tokio::test]
    async fn keyboard_and_video_dispatch_run_without_a_cursor_update() {
        let turns = hot_capture_turns_before_dispatch(true).await;
        assert_eq!(
            turns, 1,
            "dispatch must run before capture can build a backlog"
        );
    }
}
