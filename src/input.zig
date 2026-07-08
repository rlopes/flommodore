//! Flommodore — `input.zig` (Block 8).
//!
//! Host-input mapping: translates keyboard and gamepad activity into the
//! machine's §5.3/§5.4 device model via io.zig's host entry points. This
//! module never imports SDL — main.zig is the SDL boundary and forwards
//! events here in plain integer/enum terms, so the whole layer runs under
//! the headless `zig build test`. (Layout note: added beyond the Phase 7
//! §7.2 file list for the same SDL-isolation reason the harness cites —
//! everything below main.zig must build with no display.)
//!
//! Task 8.1 is nearly the identity: SDL3 scancodes ARE USB HID usage-page
//! 0x07 values (SDL_scancode.h: "values ... from usage page 0x07"), which
//! is exactly the §5.3 scancode table. The mapping is therefore a filter,
//! not a table.
//!
//! Implementation decisions where the spec/plan is silent (marked at use
//! sites; candidates for a v1.3 amendment, continuing io.zig's a–e list):
//!   f. Keyboard fallback (task 8.8) MERGES with gamepad state: JOY1 =
//!      pad-on-port-1 OR WASD+Space bits. No mode switch, keyboard and pad
//!      players coexist, and the fallback keys still reach the keyboard
//!      queue — nothing reads a device it doesn't care about.
//!   g. Left-stick → direction bits with hysteresis: press at |v| ≥ 16000,
//!      release at |v| < 8000 (of ±32767). Without it, jitter around a
//!      single threshold becomes a JCTRL IRQ storm (§5.4 fires on ANY bit
//!      transition).
//!   h. Key repeats are host-OS synthesis, not HID events — a real
//!      keyboard sends one make and one break. Repeats never enqueue.
//!   i. Scancodes outside the HID keyboard page ($01–$E7) are dropped
//!      (audit G19: the 8-bit KDATA scancode field holds exactly that
//!      page; SDL values ≥ 232 are consumer-page media keys).
//!   j. Host-reserved keys are never forwarded: Escape quits (task 5.3)
//!      and F12 will open the Block 9 debugger. Reserving F12 now keeps
//!      guest programs from ever depending on it.
//!
//! Gamepad ports: first pad connected → port 1, second → port 2, further
//! pads ignored. Removal frees the port and zeroes its state (a real
//! unplug releases every line).

const std = @import("std");
const io_mod = @import("io");

// ---------------------------------------------------------------------------
// HID scancodes this module knows by value (USB HID usage page 0x07;
// identical to the SDL_SCANCODE_* values by SDL3's definition).
// ---------------------------------------------------------------------------

pub const hid_a: u16 = 0x04;
pub const hid_d: u16 = 0x07;
pub const hid_s: u16 = 0x16;
pub const hid_w: u16 = 0x1A;
pub const hid_space: u16 = 0x2C;
pub const hid_escape: u16 = 0x29; // decision j: host quit key
pub const hid_f12: u16 = 0x45; //   decision j: Block 9 debugger key
/// Last usage on the HID keyboard page (Right GUI) — decision i.
pub const hid_max: u16 = 0xE7;

/// KDATA bit 15: key up (§5.3 scancode format).
pub const key_up_bit: u16 = 0x8000;

// Joystick state bits (§5.4).
pub const joy_up: u8 = 0x01;
pub const joy_down: u8 = 0x02;
pub const joy_left: u8 = 0x04;
pub const joy_right: u8 = 0x08;
pub const joy_fire1: u8 = 0x40;
pub const joy_fire2: u8 = 0x80;

/// Decision g: stick hysteresis thresholds (of the ±32767 SDL axis range).
pub const axis_press: i16 = 16000;
pub const axis_release: i16 = 8000;

/// Modifier and lock snapshot, host terms (main.zig builds it from
/// SDL_Keymod; tests build it directly).
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    gui: bool = false,
    caps: bool = false,
    num: bool = false,
};

/// Gamepad inputs the machine model cares about, host terms. main.zig
/// translates SDL_GAMEPAD_BUTTON_* to these; everything else is dropped.
pub const PadButton = enum {
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    fire1, // south face button (Xbox A)
    fire2, // east face button (Xbox B)

    fn bit(b: PadButton) u8 {
        return switch (b) {
            .dpad_up => joy_up,
            .dpad_down => joy_down,
            .dpad_left => joy_left,
            .dpad_right => joy_right,
            .fire1 => joy_fire1,
            .fire2 => joy_fire2,
        };
    }
};

pub const Input = struct {
    io: *io_mod.Io,
    /// Gamepad instance id per port, or null if the port is empty.
    pads: [2]?u32 = .{ null, null },
    /// Per-port direction+fire bits from dpad/buttons, and from the left
    /// stick — kept separate so dpad-release doesn't clear a held stick.
    button_bits: [2]u8 = .{ 0, 0 },
    axis_bits: [2]u8 = .{ 0, 0 },
    /// Decision f: WASD+Space bits, merged into port 1.
    kbd_bits: u8 = 0,

    pub fn init(io_dev: *io_mod.Io) Input {
        return .{ .io = io_dev };
    }

    // ------------------------------------------------------------------
    // Keyboard (tasks 8.1, 8.8).
    // ------------------------------------------------------------------

    /// One host key event. `scancode` is the SDL3 scancode == HID usage.
    pub fn keyEvent(inp: *Input, scancode: u32, down: bool, repeat: bool) void {
        if (scancode == 0 or scancode > hid_max) return; // decision i
        const hid: u16 = @intCast(scancode);
        if (hid == hid_escape or hid == hid_f12) return; // decision j

        // Decision f: fallback keys drive JOY1 *and* fall through to the
        // queue. Repeats are no-ops here (the bit is already set, so the
        // §5.4 transition IRQ cannot re-fire).
        const joy_bit: u8 = switch (hid) {
            hid_w => joy_up,
            hid_s => joy_down,
            hid_a => joy_left,
            hid_d => joy_right,
            hid_space => joy_fire1,
            else => 0,
        };
        if (joy_bit != 0) {
            if (down) inp.kbd_bits |= joy_bit else inp.kbd_bits &= ~joy_bit;
            inp.push(0);
        }

        if (repeat) return; // decision h: never enqueue synthetic repeats
        const event_word = hid | (if (down) @as(u16, 0) else key_up_bit);
        inp.io.keyEvent(event_word); // queue + KCTRL-gated IRQ live in io.zig
    }

    /// Snapshot of the host modifier/lock state (KMOD + KSTAT bits 2/3).
    /// Called on every key event — lock toggles are themselves key events,
    /// so this is always fresh — and once at startup.
    pub fn syncModifiers(inp: *Input, mods: Mods) void {
        const bits: u16 = (@as(u16, @intFromBool(mods.shift)) << 0) |
            (@as(u16, @intFromBool(mods.ctrl)) << 1) |
            (@as(u16, @intFromBool(mods.alt)) << 2) |
            (@as(u16, @intFromBool(mods.gui)) << 3);
        inp.io.setModifiers(bits);
        inp.io.setLocks(mods.caps, mods.num);
    }

    // ------------------------------------------------------------------
    // Gamepads (task 8.6).
    // ------------------------------------------------------------------

    /// A gamepad appeared. Returns the port it was assigned (0 or 1) so
    /// main.zig can open the SDL handle, or null if both ports are taken
    /// or the id is already assigned (SDL re-announces on hotplug races).
    pub fn padAdded(inp: *Input, id: u32) ?u1 {
        if (inp.portOf(id) != null) return null;
        for (&inp.pads, 0..) |*slot, port| {
            if (slot.* == null) {
                slot.* = id;
                return @intCast(port);
            }
        }
        return null;
    }

    /// A gamepad left. Frees the port and releases every line (which
    /// raises the JCTRL transition IRQ if anything was held — an unplug
    /// is a state change the guest asked to hear about).
    pub fn padRemoved(inp: *Input, id: u32) ?u1 {
        const port = inp.portOf(id) orelse return null;
        inp.pads[port] = null;
        inp.button_bits[port] = 0;
        inp.axis_bits[port] = 0;
        inp.push(port);
        return port;
    }

    pub fn padButton(inp: *Input, id: u32, button: PadButton, down: bool) void {
        const port = inp.portOf(id) orelse return;
        const bit = button.bit();
        if (down) inp.button_bits[port] |= bit else inp.button_bits[port] &= ~bit;
        inp.push(port);
    }

    /// Left-stick X axis → left/right bits with hysteresis (decision g).
    pub fn padAxisX(inp: *Input, id: u32, value: i16) void {
        inp.padAxis(id, value, joy_left, joy_right);
    }

    /// Left-stick Y axis → up/down bits (SDL: negative is up).
    pub fn padAxisY(inp: *Input, id: u32, value: i16) void {
        inp.padAxis(id, value, joy_up, joy_down);
    }

    fn padAxis(inp: *Input, id: u32, value: i16, neg_bit: u8, pos_bit: u8) void {
        const port = inp.portOf(id) orelse return;
        var bits = inp.axis_bits[port];
        if (value <= -axis_press) bits |= neg_bit;
        if (value > -axis_release) bits &= ~neg_bit;
        if (value >= axis_press) bits |= pos_bit;
        if (value < axis_release) bits &= ~pos_bit;
        if (bits != inp.axis_bits[port]) {
            inp.axis_bits[port] = bits;
            inp.push(port);
        }
    }

    // ------------------------------------------------------------------

    fn portOf(inp: *const Input, id: u32) ?u1 {
        for (inp.pads, 0..) |slot, port| {
            if (slot == id) return @intCast(port);
        }
        return null;
    }

    /// Compose a port's state byte and hand it to the machine. io.zig owns
    /// the §5.4 transition-IRQ semantics, so redundant pushes are free.
    fn push(inp: *Input, port: u1) void {
        var state = inp.button_bits[port] | inp.axis_bits[port];
        if (port == 0) state |= inp.kbd_bits; // decision f
        inp.io.setJoystick(port, state);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const expectEqual = testing.expectEqual;

const kstat_addr = io_mod.kstat_addr;
const kdata_addr = io_mod.kdata_addr;
const kmod_addr = io_mod.kmod_addr;
const joy1_addr = io_mod.joy1_addr;
const joy2_addr = io_mod.joy2_addr;

test "8.1 keyboard: HID pass-through, key-up bit, filters (0, >E7, repeat, reserved)" {
    var io = io_mod.Io.init();
    var inp = Input.init(&io);
    inp.keyEvent(0x04, true, false); //  'a' down
    inp.keyEvent(0x04, true, true); //   auto-repeat: dropped (decision h)
    inp.keyEvent(0x04, false, false); // 'a' up
    inp.keyEvent(0, true, false); //     SDL_SCANCODE_UNKNOWN: dropped
    inp.keyEvent(0x100, true, false); // consumer page: dropped (decision i)
    inp.keyEvent(hid_escape, true, false); // host-reserved (decision j)
    inp.keyEvent(hid_f12, true, false); //   host-reserved (decision j)
    try expectEqual(@as(u16, 0x0004), io.read16(kdata_addr));
    try expectEqual(@as(u16, 0x8004), io.read16(kdata_addr));
    try expectEqual(@as(u16, 0x0000), io.read16(kdata_addr)); // queue empty
    try expectEqual(@as(u16, 0x0000), io.read16(kstat_addr));
}

test "8.4/8.3 modifiers and locks reach KMOD and KSTAT" {
    var io = io_mod.Io.init();
    var inp = Input.init(&io);
    inp.syncModifiers(.{ .shift = true, .alt = true, .num = true });
    try expectEqual(@as(u16, 0x0005), io.read16(kmod_addr));
    try expectEqual(@as(u16, 0x0008), io.read16(kstat_addr)); // num lock
    inp.syncModifiers(.{});
    try expectEqual(@as(u16, 0x0000), io.read16(kmod_addr));
    try expectEqual(@as(u16, 0x0000), io.read16(kstat_addr));
}

test "8.8 WASD+Space fallback drives JOY1 and still reaches the queue" {
    var io = io_mod.Io.init();
    var inp = Input.init(&io);
    inp.keyEvent(hid_w, true, false);
    inp.keyEvent(hid_d, true, false);
    try expectEqual(@as(u16, joy_up | joy_right), io.read16(joy1_addr)); // diagonal
    inp.keyEvent(hid_w, true, true); // repeat: joy state unchanged, no enqueue
    try expectEqual(@as(u16, joy_up | joy_right), io.read16(joy1_addr));
    inp.keyEvent(hid_space, true, false);
    try expectEqual(@as(u16, joy_up | joy_right | joy_fire1), io.read16(joy1_addr));
    inp.keyEvent(hid_w, false, false);
    inp.keyEvent(hid_d, false, false);
    inp.keyEvent(hid_space, false, false);
    try expectEqual(@as(u16, 0), io.read16(joy1_addr));
    // Decision f: the same keys also produced queue events (make+break ×3).
    try expectEqual(@as(u16, hid_w), io.read16(kdata_addr));
    try expectEqual(@as(u16, hid_d), io.read16(kdata_addr));
    try expectEqual(@as(u16, hid_space), io.read16(kdata_addr));
    try expectEqual(@as(u16, hid_w | key_up_bit), io.read16(kdata_addr));
}

test "8.6 gamepad ports: assignment, buttons, removal releases lines" {
    var io = io_mod.Io.init();
    var inp = Input.init(&io);
    try expectEqual(@as(?u1, 0), inp.padAdded(77));
    try expectEqual(@as(?u1, null), inp.padAdded(77)); // duplicate announce
    try expectEqual(@as(?u1, 1), inp.padAdded(99));
    try expectEqual(@as(?u1, null), inp.padAdded(55)); // both ports taken

    inp.padButton(77, .dpad_up, true);
    inp.padButton(77, .fire2, true);
    inp.padButton(99, .fire1, true);
    inp.padButton(55, .fire1, true); // unassigned id: ignored
    try expectEqual(@as(u16, joy_up | joy_fire2), io.read16(joy1_addr));
    try expectEqual(@as(u16, joy_fire1), io.read16(joy2_addr));

    // Removal zeroes the port; the freed port is reused by the next pad.
    try expectEqual(@as(?u1, 0), inp.padRemoved(77));
    try expectEqual(@as(u16, 0), io.read16(joy1_addr));
    try expectEqual(@as(?u1, null), inp.padRemoved(77)); // already gone
    try expectEqual(@as(?u1, 0), inp.padAdded(55));
    try expectEqual(@as(u16, joy_fire1), io.read16(joy2_addr)); // port 2 untouched
}

test "8.6 axis hysteresis: press at 16000, release below 8000" {
    var io = io_mod.Io.init();
    var inp = Input.init(&io);
    _ = inp.padAdded(1);
    inp.padAxisX(1, 15999); // below press threshold
    try expectEqual(@as(u16, 0), io.read16(joy1_addr));
    inp.padAxisX(1, 16000); // press
    try expectEqual(@as(u16, joy_right), io.read16(joy1_addr));
    inp.padAxisX(1, 9000); //  inside the hysteresis band: held
    try expectEqual(@as(u16, joy_right), io.read16(joy1_addr));
    inp.padAxisX(1, 7999); //  release
    try expectEqual(@as(u16, 0), io.read16(joy1_addr));
    inp.padAxisX(1, -20000); // press the other way (left)
    try expectEqual(@as(u16, joy_left), io.read16(joy1_addr));
    inp.padAxisY(1, -32768); // stick up (SDL: negative Y is up)
    try expectEqual(@as(u16, joy_left | joy_up), io.read16(joy1_addr));
    inp.padAxisX(1, 0);
    inp.padAxisY(1, 0);
    try expectEqual(@as(u16, 0), io.read16(joy1_addr));
}

test "8.6/8.8 dpad, stick, and keyboard bits merge; releases don't cross-clear" {
    var io = io_mod.Io.init();
    var inp = Input.init(&io);
    _ = inp.padAdded(5);
    inp.padButton(5, .dpad_right, true); // dpad holds right...
    inp.padAxisX(5, 20000); //             ...stick also right...
    inp.keyEvent(hid_d, true, false); //   ...and so does the keyboard.
    try expectEqual(@as(u16, joy_right), io.read16(joy1_addr));
    inp.padAxisX(5, 0); // stick releases: dpad + keyboard still hold
    try expectEqual(@as(u16, joy_right), io.read16(joy1_addr));
    inp.padButton(5, .dpad_right, false);
    try expectEqual(@as(u16, joy_right), io.read16(joy1_addr)); // keyboard holds
    inp.keyEvent(hid_d, false, false);
    try expectEqual(@as(u16, 0), io.read16(joy1_addr));
}
