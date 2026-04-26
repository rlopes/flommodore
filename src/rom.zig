//! rom.zig — 16KB ROM image ($FC000 – $FFFFF).
//!
//! Loads a binary ROM file into a fixed-size buffer.
//! Out-of-range reads return $0000.
//! Shadow RAM logic (SYSCFG bit 0) is enforced at the bus level.
//!
//! Implemented in Block 2.

// TODO: Block 2 — implement load(path), read_byte(addr), read_u16(addr)

pub fn init() void {}
