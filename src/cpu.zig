//! cpu.zig — Gab-16 CPU: fetch / decode / execute.
//!
//! Gab-16 summary (spec §2):
//!   • 16-bit RISC, 20-bit address bus, 32-bit fixed instruction encoding
//!   • 24 registers: R0–R15 (general), PC, FLAGS, SP, LR, CYC, + 4 reserved
//!   • R0 writes are silently discarded (hardwired zero)
//!   • All ALU ops on lower 16 bits; address ops use lower 20 bits
//!   • Flags: Z (bit 0), N (bit 1), C (bit 2), V (bit 3)
//!   • ~14 MHz → ~233,333 cycles per frame at 60 Hz
//!
//! Implemented in Block 3.

// TODO: Block 3 — implement Gab16 struct, reset(), step(), irq()

pub fn init() void {}
