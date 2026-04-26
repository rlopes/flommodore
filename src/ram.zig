//! ram.zig — 512KB flat RAM.
//!
//! Memory map (from spec §1.1):
//!   $00000 – $3FFFF   256KB general-purpose RAM
//!   $40000 – $7FFFF   256KB VRAM (VIC-256 pixel data)
//!
//! Implemented in Block 2.

// TODO: Block 2 — implement read_byte, write_byte, read_u16, write_u16

pub fn init() void {}
