//! io.zig — I/O region: timers, keyboard, joystick, IRQ controller.
//!
//! I/O region: $80000 – $80FFF (spec §5)
//!
//!   $80000 – $800FF   IRQ controller (IRQSTAT, IRQMASK, IRQVEC)
//!   $80010 – $8001F   Timer A
//!   $80020 – $8002F   Timer B
//!   $80030 – $8003F   Keyboard (KDATA, KSTAT, KMOD, KCTRL)
//!   $80040 – $8004F   Joystick 1 & 2
//!   $80050            SYSCFG (shadow ROM bit 0)
//!   $80100 – $801FF   AUR-1 (handled by aur1.zig)
//!   $80200 – $802FF   VIC-256 (handled by vic256.zig)
//!
//! Implemented in Block 4.

// TODO: Block 4 — implement IoState struct, timer_tick(), register read/write,
//                 keyboard queue, joystick state, IRQ assertion

pub fn init() void {}
