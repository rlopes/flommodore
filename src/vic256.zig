//! vic256.zig — VIC-256 video chip: scanline renderer.
//!
//! VIC-256 summary (spec §3):
//!   • 256KB VRAM at $40000 – $7FFFF (pixel + tile data only)
//!   • 4 display modes: Bitmap, Tile, Bitmap+Tile, Text
//!   • 64 hardware sprites (max 8 per scanline)
//!   • Raster IRQ per scanline, VBLANK IRQ at frame end
//!   • Control registers at $80200 – $802FF
//!   • Palette (768B), SAT (512B), tile maps — in general RAM,
//!     pointed to by VPALBASE, VSATBASE, VTMAPBASE registers
//!
//! Implemented in Block 6.

// TODO: Block 6 — implement Vic256 struct, render_frame(), register read/write

pub fn init() void {}
