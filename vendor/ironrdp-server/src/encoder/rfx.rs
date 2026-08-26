use std::io;

use ironrdp_acceptor::DesktopSize;
use ironrdp_core::{Encode as _, EncodeResult, cast_int, cast_length, other_err};
use ironrdp_graphics::color_conversion::to_64x64_ycbcr_tile;
use ironrdp_graphics::rfx_encode_component;
use ironrdp_graphics::rlgr::RlgrError;
use ironrdp_pdu::WriteCursor;
use ironrdp_pdu::codecs::rfx::{
    self, Block, ChannelsPdu, CodecChannel, CodecVersionsPdu, FrameBeginPdu, FrameEndPdu, OperatingMode, Quant,
    RegionPdu, RfxChannel, SyncPdu, TileSetPdu,
};
use ironrdp_pdu::rdp::capability_sets::EntropyBits;

use crate::BitmapUpdate;

#[derive(Debug)]
pub(crate) struct RfxEncoder {
    entropy_algorithm: rfx::EntropyAlgorithm,
    // RemoteFX needs 12 KiB of transform output per 64x64 tile. Reusing this
    // workspace avoids allocating and zero-initializing a potentially
    // multi-megabyte Vec for every dirty rectangle.
    tile_scratch: Vec<u8>,
}

impl Clone for RfxEncoder {
    fn clone(&self) -> Self {
        Self {
            entropy_algorithm: self.entropy_algorithm,
            // A clone represents a new connection/encoder; don't copy a large
            // idle scratch allocation into it.
            tile_scratch: Vec::new(),
        }
    }
}

impl RfxEncoder {
    pub(crate) fn new(entropy_bits: EntropyBits) -> Self {
        let entropy_algorithm = match entropy_bits {
            EntropyBits::Rlgr1 => rfx::EntropyAlgorithm::Rlgr1,
            EntropyBits::Rlgr3 => rfx::EntropyAlgorithm::Rlgr3,
        };
        Self {
            entropy_algorithm,
            tile_scratch: Vec::new(),
        }
    }

    pub(crate) fn encode(
        &mut self,
        bitmap: &BitmapUpdate,
        output: &mut [u8],
        desktop_size: Option<DesktopSize>,
    ) -> EncodeResult<usize> {
        let mut cursor = WriteCursor::new(output);
        let entropy_algorithm = self.entropy_algorithm;

        // header messages
        if let Some(desktop_size) = desktop_size {
            let width = desktop_size.width;
            let height = desktop_size.height;
            Block::Sync(SyncPdu).encode(&mut cursor)?;
            let context = rfx::ContextPdu {
                flags: OperatingMode::IMAGE_MODE,
                entropy_algorithm,
            };
            Block::CodecChannel(CodecChannel::Context(context)).encode(&mut cursor)?;

            let channels = ChannelsPdu(vec![RfxChannel {
                width: cast_length!("width", width)?,
                height: cast_length!("height", height)?,
            }]);
            Block::Channels(channels).encode(&mut cursor)?;

            Block::CodecVersions(CodecVersionsPdu).encode(&mut cursor)?;
        }

        // data messages
        let frame_begin = FrameBeginPdu {
            index: 0,
            number_of_regions: 1,
        };
        Block::CodecChannel(CodecChannel::FrameBegin(frame_begin)).encode(&mut cursor)?;

        let width = bitmap.width.get();
        let height = bitmap.height.get();
        let rectangles = vec![rfx::RfxRectangle {
            x: 0,
            y: 0,
            width,
            height,
        }];
        let region = RegionPdu { rectangles };
        Block::CodecChannel(CodecChannel::Region(region)).encode(&mut cursor)?;

        // 6 is the highest-fidelity quantizer permitted by MS-RDPRFX. The
        // protocol default increases high-frequency bands to 7..9, which saves
        // bandwidth but visibly softens small text and one-pixel UI strokes.
        // Native bitmap mode deliberately spends bandwidth on clarity and
        // controls load with dirty rectangles + a low capture frame cap.
        let quant = maximum_quality_quant();

        let encoder = UpdateEncoder::new(bitmap, quant.clone(), entropy_algorithm);
        self.tile_scratch.resize(encoder.required_data_len(), 0);
        let tiles = encoder.encode(&mut self.tile_scratch)?;

        let quants = vec![quant];
        let tile_set = TileSetPdu {
            entropy_algorithm,
            quants,
            tiles,
        };
        Block::CodecChannel(CodecChannel::TileSet(tile_set)).encode(&mut cursor)?;

        let frame_end = FrameEndPdu;
        Block::CodecChannel(CodecChannel::FrameEnd(frame_end)).encode(&mut cursor)?;

        Ok(cursor.pos())
    }
}

fn maximum_quality_quant() -> Quant {
    Quant {
        ll3: 6,
        lh3: 6,
        hl3: 6,
        hh3: 6,
        lh2: 6,
        hl2: 6,
        hh2: 6,
        lh1: 6,
        hl1: 6,
        hh1: 6,
    }
}

pub(crate) struct UpdateEncoder<'a> {
    bitmap: &'a BitmapUpdate,
    quant: Quant,
    entropy_algorithm: rfx::EntropyAlgorithm,
}

struct EncodedTile<'a> {
    y_data: &'a [u8],
    cb_data: &'a [u8],
    cr_data: &'a [u8],
}

impl<'a> UpdateEncoder<'a> {
    fn new(bitmap: &'a BitmapUpdate, quant: Quant, entropy_algorithm: rfx::EntropyAlgorithm) -> Self {
        Self {
            bitmap,
            quant,
            entropy_algorithm,
        }
    }

    fn required_data_len(&self) -> usize {
        let (tiles_x, tiles_y) = self.tiles_xy();
        64 * 64 * 3 * tiles_x * tiles_y
    }

    fn tiles_xy(&self) -> (usize, usize) {
        (
            self.bitmap.width.get().div_ceil(64).into(),
            self.bitmap.height.get().div_ceil(64).into(),
        )
    }

    fn encode(&self, data: &'a mut [u8]) -> EncodeResult<Vec<rfx::Tile<'a>>> {
        #[cfg(feature = "rayon")]
        use rayon::prelude::*;

        let (tiles_x, tiles_y) = self.tiles_xy();
        debug_assert!(data.len() >= self.required_data_len());

        #[cfg(not(feature = "rayon"))]
        let chunks = data.chunks_mut(64 * 64 * 3);
        #[cfg(feature = "rayon")]
        let chunks = data.par_chunks_mut(64 * 64 * 3);

        let tiles: Vec<_> = (0..tiles_y).flat_map(|y| (0..tiles_x).map(move |x| (x, y))).collect();

        chunks
            .zip(tiles)
            .map(|(buf, (tile_x, tile_y))| {
                let EncodedTile {
                    y_data,
                    cb_data,
                    cr_data,
                } = self
                    .encode_tile(tile_x, tile_y, buf)
                    .map_err(|e| other_err!("rfxenc", source: e))?;

                let tile = rfx::Tile {
                    y_quant_index: 0,
                    cb_quant_index: 0,
                    cr_quant_index: 0,
                    x: cast_int!("tile_x", tile_x)?,
                    y: cast_int!("tile_y", tile_y)?,
                    y_data,
                    cb_data,
                    cr_data,
                };
                Ok(tile)
            })
            .collect()
    }

    fn encode_tile<'b>(&self, tile_x: usize, tile_y: usize, buf: &'b mut [u8]) -> Result<EncodedTile<'b>, RlgrError> {
        #![allow(clippy::similar_names)] // It’s hard to find better names for cr, cb, etc.

        assert!(buf.len() >= 4096 * 3);

        let bpp: usize = self.bitmap.format.bytes_per_pixel().into();
        let width: usize = self.bitmap.width.get().into();
        let height: usize = self.bitmap.height.get().into();

        let x = tile_x * 64;
        let y = tile_y * 64;
        let tile_width = u32::try_from(core::cmp::min(width - x, 64)).expect("can always fit in u32");
        let tile_height = u32::try_from(core::cmp::min(height - y, 64)).expect("can always fit in u32");
        let stride = self.bitmap.stride.get();
        let input = &self.bitmap.data[y * stride + x * bpp..];

        let stride = u32::try_from(stride).map_err(io::Error::other)?;
        let y = &mut [0i16; 4096];
        let cb = &mut [0i16; 4096];
        let cr = &mut [0i16; 4096];

        to_64x64_ycbcr_tile(input, tile_width, tile_height, stride, self.bitmap.format, y, cb, cr)
            .map_err(RlgrError::Yuv)?;

        let (y_data, buf) = buf.split_at_mut(4096);
        let (cb_data, cr_data) = buf.split_at_mut(4096);

        let len = rfx_encode_component(y, y_data, &self.quant, self.entropy_algorithm)?;
        let y_data = &y_data[..len];
        let len = rfx_encode_component(cb, cb_data, &self.quant, self.entropy_algorithm)?;
        let cb_data = &cb_data[..len];
        let len = rfx_encode_component(cr, cr_data, &self.quant, self.entropy_algorithm)?;
        let cr_data = &cr_data[..len];

        Ok(EncodedTile {
            y_data,
            cb_data,
            cr_data,
        })
    }
}

#[cfg(feature = "__bench")]
#[expect(clippy::missing_panics_doc, reason = "panics in benches are allowed")]
pub(crate) mod bench {
    use super::*;

    pub fn rfx_enc_tile(
        bitmap: &BitmapUpdate,
        quant: &Quant,
        algo: rfx::EntropyAlgorithm,
        tile_x: usize,
        tile_y: usize,
    ) {
        let enc = UpdateEncoder::new(bitmap, quant.clone(), algo);
        let mut data = vec![0; enc.required_data_len()];

        enc.encode_tile(tile_x, tile_y, &mut data)
            .expect("cannot propagate error in benchmark");
    }

    pub fn rfx_enc(bitmap: &BitmapUpdate, quant: &Quant, algo: rfx::EntropyAlgorithm) {
        let enc = UpdateEncoder::new(bitmap, quant.clone(), algo);
        let mut data = vec![0; enc.required_data_len()];

        enc.encode(&mut data).expect("cannot propagate error in benchmark");
    }
}
