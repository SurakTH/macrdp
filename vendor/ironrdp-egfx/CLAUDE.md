# Vendored ironrdp-egfx divergence

Source: Devolutions/IronRDP commit `a5d1c682fd1f65287f6f5727bdead2aef7a2bea7`.

This crate is vendored because the pinned `Avc420Region` helper treats
`right`/`bottom` as inclusive and emits `width - 1` / `height - 1` into the
RFX AVC metablock. MS-RDPEGFX 2.2.1.4.1 defines `RDPGFX_RECT16` right and bottom
as exclusive, including the `regionRects` embedded in RFX_AVC420 and AVC444.
The divergence makes `Avc420Region` exclusive, emits `width` / `height`, and
removes the compensating `+1` when computing the outer WireToSurface rectangle.

This is visually important for AVC444: the old full-HD metadata declared an
odd 1919x1079 reconstruction region, which can shift the B-area chroma mapping.
Drop this vendor once upstream carries the same semantic correction.
