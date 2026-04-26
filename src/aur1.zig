//! aur1.zig — AUR-1 sound chip: real-time synthesiser.
//!
//! AUR-1 summary (spec §4):
//!   • 4 voices, each with: phase accumulator, 6 waveforms, ADSR envelope
//!   • Waveforms: square, sine, triangle, sawtooth, pulse (PWM), noise (LFSR),
//!     wavetable (256-byte table from RAM)
//!   • Ring modulation and hard sync between adjacent voices
//!   • FM synthesis: modulator voice drives carrier frequency
//!   • Stereo 16-bit output @ 44.1 KHz, pushed to SDL3 audio stream
//!   • Voice registers at $80100 + (N × $10), N = 0–3
//!   • Global registers at $80140
//!
//! Implemented in Block 7.

// TODO: Block 7 — implement Aur1 struct, generate_frame(), register read/write

pub fn init() void {}
