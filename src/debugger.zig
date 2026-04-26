//! debugger.zig — Built-in debugger and monitor.
//!
//! Activated by F12 or BRK instruction.
//! Renders via Dear ImGui (cimgui) alongside the emulator window.
//! Can also be driven from stdin/stdout for headless/scripted sessions.
//!
//! Features (spec §7.5):
//!   • Register viewer (R0–R15, PC, FLAGS, SP, LR, CYC)
//!   • Disassembler (instructions around PC)
//!   • Memory viewer (hex + ASCII)
//!   • Step / step-over / continue / breakpoints / watchpoints
//!   • VRAM viewer, I/O register viewer, audio monitor
//!   • Symbol file loader (.flsym)
//!
//! Implemented in Block 9.

// TODO: Block 9 — implement Debugger struct, activate(), step(), render()

pub fn init() void {}
