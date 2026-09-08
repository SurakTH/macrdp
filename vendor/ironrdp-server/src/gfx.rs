//! EGFX (Graphics Pipeline Extension) server integration.
//!
//! Provides the bridge between `ironrdp-egfx`'s `GraphicsPipelineServer` and
//! `ironrdp-server`'s `RdpServer`, enabling H.264 video streaming via DVC.
//!
//! The bridge pattern (`GfxDvcBridge`) wraps an `Arc<Mutex<GraphicsPipelineServer>>`
//! so the display handler can call `send_avc420_frame()` proactively while the
//! DVC infrastructure handles client messages (capability negotiation, frame acks).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ironrdp_core::impl_as_any;
use ironrdp_dvc::{DvcMessage, DvcProcessor, DvcServerProcessor};
use ironrdp_egfx::server::{GraphicsPipelineHandler, GraphicsPipelineServer};
use ironrdp_pdu::PduResult;
use ironrdp_svc::SvcMessage;

use crate::server::ServerEventSender;

/// Shared handle to a `GraphicsPipelineServer`.
///
/// Uses `std::sync::Mutex` (not tokio) because `DvcProcessor` trait methods
/// are synchronous and cannot hold async locks.
pub type GfxServerHandle = Arc<Mutex<GraphicsPipelineServer>>;

/// Factory for creating EGFX graphics pipeline handlers.
///
/// Implements `ServerEventSender` so the factory can signal the server event loop
/// when EGFX frames are ready to be drained and sent.
pub trait GfxServerFactory: ServerEventSender + Send {
    /// Create a handler for EGFX callbacks (caps negotiation, frame acks).
    fn build_gfx_handler(&self) -> Box<dyn GraphicsPipelineHandler>;

    /// Create a bridge and shared server handle for proactive frame sending.
    ///
    /// When returning `Some`, the bridge is registered with DrdynvcServer for
    /// client messages, and the handle is available for direct frame submission.
    /// Returns `None` by default, falling back to `build_gfx_handler()`.
    fn build_server_with_handle(&self) -> Option<(GfxDvcBridge, GfxServerHandle)> {
        None
    }
}

/// DVC bridge wrapping a shared `GraphicsPipelineServer`.
///
/// Delegates all `DvcProcessor` methods to the inner server through a mutex,
/// enabling shared access from both the DVC layer and the display handler.
pub struct GfxDvcBridge {
    inner: GfxServerHandle,
    /// Optional "decline the graphics pipeline" flag, set by the application's
    /// `GraphicsPipelineHandler` (synchronously during `process` — the inner
    /// server invokes the handler before returning). When true, `process`
    /// discards the inner server's output instead of shipping it — most
    /// importantly the `CapabilitiesConfirm`, so a client whose advertised
    /// capabilities the application can't serve (e.g. EGFX offered but AVC
    /// disabled on every capset) is never told the pipeline is active and
    /// keeps rendering legacy updates. Confirming caps and then sending legacy
    /// updates anyway is a protocol violation some clients (Windows App for
    /// Android) hard-disconnect on. `None` = never decline (default).
    decline_output: Option<Arc<AtomicBool>>,
}

impl GfxDvcBridge {
    pub fn new(server: GfxServerHandle) -> Self {
        Self {
            inner: server,
            decline_output: None,
        }
    }

    /// Like [`Self::new`] but with a shared decline flag (see the field note).
    pub fn with_decline_flag(server: GfxServerHandle, decline: Arc<AtomicBool>) -> Self {
        Self {
            inner: server,
            decline_output: Some(decline),
        }
    }

    pub fn server(&self) -> &GfxServerHandle {
        &self.inner
    }
}

impl_as_any!(GfxDvcBridge);

impl DvcProcessor for GfxDvcBridge {
    fn channel_name(&self) -> &str {
        ironrdp_egfx::CHANNEL_NAME
    }

    fn start(&mut self, channel_id: u32) -> PduResult<Vec<DvcMessage>> {
        self.inner
            .lock()
            .expect("GfxServerHandle mutex poisoned")
            .start(channel_id)
    }

    fn process(&mut self, channel_id: u32, payload: &[u8]) -> PduResult<Vec<DvcMessage>> {
        let out = self
            .inner
            .lock()
            .expect("GfxServerHandle mutex poisoned")
            .process(channel_id, payload)?;
        // The handler ran synchronously inside `process` above, so the decline
        // flag is current for the PDU just handled. Discarding the output here
        // (rather than not processing) keeps the inner server's state machine
        // consistent while the client is never told the pipeline came up.
        if let Some(declined) = &self.decline_output
            && declined.load(Ordering::Relaxed)
        {
            return Ok(Vec::new());
        }
        Ok(out)
    }

    fn close(&mut self, channel_id: u32) {
        self.inner
            .lock()
            .expect("GfxServerHandle mutex poisoned")
            .close(channel_id)
    }
}

impl DvcServerProcessor for GfxDvcBridge {}

/// Retires a batch only when the transport write finishes (or the batch is
/// abandoned on disconnect/error). Keeping this in the queued event includes
/// socket backpressure in the producer's outstanding-frame count.
#[derive(Debug)]
pub struct EgfxFrameCompletion {
    completed: std::sync::Arc<std::sync::atomic::AtomicU64>,
    frames: u64,
}

impl EgfxFrameCompletion {
    pub fn new(completed: std::sync::Arc<std::sync::atomic::AtomicU64>, frames: u64) -> Self {
        Self { completed, frames }
    }
}

impl Drop for EgfxFrameCompletion {
    fn drop(&mut self) {
        self.completed
            .fetch_add(self.frames, std::sync::atomic::Ordering::Relaxed);
    }
}

/// Message for routing EGFX PDUs to the wire via `ServerEvent`.
#[derive(Debug)]
pub enum EgfxServerMessage {
    /// Pre-encoded DVC messages from `GraphicsPipelineServer::drain_output()`.
    SendMessages { messages: Vec<SvcMessage> },
    /// Video batch whose pipeline slot remains occupied until transport dispatch.
    SendTrackedMessages {
        messages: Vec<SvcMessage>,
        completion: EgfxFrameCompletion,
    },
}

impl core::fmt::Display for EgfxServerMessage {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::SendMessages { messages } | Self::SendTrackedMessages { messages, .. } => {
                write!(f, "SendMessages(count={})", messages.len())
            }
        }
    }
}

#[cfg(test)]
mod completion_tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn slow_transport_keeps_video_slots_occupied_until_write_completes() {
        let completed = Arc::new(AtomicU64::new(0));
        let event = EgfxServerMessage::SendTrackedMessages {
            messages: vec![],
            completion: EgfxFrameCompletion::new(completed.clone(), 2),
        };
        let (mut writer, mut reader) = tokio::io::duplex(1);
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let EgfxServerMessage::SendTrackedMessages { completion, .. } = event else {
                panic!()
            };
            started_tx.send(()).unwrap();
            writer.write_all(&[1; 16]).await.unwrap();
            drop(completion);
        });
        started_rx.await.unwrap();
        // The writer cannot finish: sixteen bytes into a one-byte socket.
        assert_eq!(completed.load(Ordering::Relaxed), 0);
        let mut data = [0; 16];
        reader.read_exact(&mut data).await.unwrap();
        task.await.unwrap();
        assert_eq!(completed.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn queued_batches_are_not_completed_just_by_enqueueing() {
        let completed = Arc::new(AtomicU64::new(0));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        for _ in 0..2 {
            tx.send(EgfxServerMessage::SendTrackedMessages {
                messages: vec![],
                completion: EgfxFrameCompletion::new(completed.clone(), 1),
            })
            .unwrap();
        }
        assert_eq!(completed.load(Ordering::Relaxed), 0);
        let writing = rx.recv().await.unwrap();
        assert_eq!(completed.load(Ordering::Relaxed), 0);
        drop(writing);
        assert_eq!(completed.load(Ordering::Relaxed), 1);
        // Disconnect also retires queued batches instead of leaking slots.
        drop(rx);
        assert_eq!(completed.load(Ordering::Relaxed), 2);
    }
}
