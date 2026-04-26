//! bus.zig — Memory bus: central address decoder.
//!
//! All CPU reads and writes pass through here.  The bus inspects the 20-bit
//! address and routes the operation to the correct handler.
//!
//! Routing table (spec §1.2):
//!   $00000 – $7FFFF   → RAM  (512KB: general + VRAM)
//!   $80000 – $80FFF   → I/O  (device registers)
//!   $81000 – $FBFFF   → open bus (returns $0000, writes ignored)
//!   $FC000 – $FFFFF   → ROM  (or RAM if shadow enabled via SYSCFG bit 0)
//!
//! All addresses are masked to 20 bits before routing.
//!
//! Implemented in Block 2.

// TODO: Block 2 — implement read_byte, write_byte, read_u16, write_u16
//                 with 20-bit masking and shadow-ROM logic.

pub fn init() void {}
