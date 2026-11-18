# Rendering investigation snapshot

This branch includes the latest Controller GUI from commit f56ad82 (settings
persistence, editable port, and connection status). The user reports that this
GUI works well. Keep the rendering experiments separate from the main release
until live-client verification is complete.

## Bitmap and RemoteFX

- Seed the framebuffer cache from full-width capture strips on large desktops.
- Reset cached pixels when desktop size or pixel format changes.
- Coalesce redundant rectangular damage without adding repaint area.

## H.264: unresolved

The user still reports stale terminal output after rapid typing without mouse
movement; moving the mouse or changing windows makes the display update.
None of the experimental changes below has resolved the reported live-client
issue. Passing automated tests is not evidence that this symptom is fixed.

Experiments retained here for investigation:

- Deadline-based trailing-frame scheduling and retry of deferred final captures.
- A quiet-period IDR followed by trailing pictures.
- Pipeline completion accounting through transport dispatch instead of enqueue.
- Explicit capture-loop yielding to let sibling input and event loops run.

Next step: collect correlated input, capture, encode, transport, and client
presentation evidence during a real stall; compare a second client before
making further speculative changes.

## Validation at snapshot

- Controller tests: 27 passed (rerun before publishing this branch).
- Vendored server tests: 25 passed, including delayed transport completion.
- Final-frame scheduler tests: 5 passed.
- Capture fairness tests: 2 passed, including a pre-fix starvation simulation.
- Bitmap damage tests: 5 passed.
- macOS optimized build and preview app signature verification passed.

These are targeted checks. The full root suite was not certified passing;
earlier runs encountered platform-service and sandbox-dependent failures.
Preview application archives are local artifacts, not committed release assets.
