//! Flommodore — `vic256.zig` (Block 6).
//!
//! The VIC-256 video chip: control registers ($80200–$802FF), the per-
//! scanline renderer (background, bitmap, tile, text, sprites), raster and
//! VBLANK interrupts, double buffering, and the RGB24 output buffer, per
//! Phase 3 as amended by v1.1 §5 (LOCKED).
//!
//! Integration contract (machine.zig drives this):
//!   startFrame()        before line 0 — latches geometry/legality, clears
//!                       VSTAT.VBLANK; returns this frame's line timing
//!   startLine(line)     before each line's CPU quantum — evaluates the
//!                       raster IRQ (start of the target visible line,
//!                       §5.6) and, at the first VBLANK line, sets
//!                       VSTAT.VBLANK, executes a pending VSWAP, and
//!                       requests the VBLANK IRQ
//!   renderLine(line,…)  after the line's CPU quantum — draws visible
//!                       lines with post-handler register state (this is
//!                       what makes raster splits land on the target line)
//!
//! Implementation decisions where the spec is silent (marked at use sites;
//! candidates for a v1.3 amendment):
//!   A. Frame-start latch: geometry (VRESX/VRESY/VPALETTE), legality, and
//!      therefore line timing latch at startFrame; mid-frame writes take
//!      effect next frame. VMODE, VBGCOL, scroll, bases, VSPRENA, palette
//!      contents, and VSCAN are live per scanline (raster effects).
//!   B. Tile map grid = exactly (resX/tilepx) × (resY/tilepx) cells, one
//!      byte per cell; fine scroll wraps the layer toroidally.
//!   C. Base pointers are range-checked at *use*; an out-of-range pointer
//!      sets VSTAT bit 3 and the affected layer/table is skipped for that
//!      use (invalid palette renders black).
//!   D. Palette entry i = 3 bytes [R, G, B] at VPALBASE×16 + 3i.
//!   E. Pixel packing follows the global MSB→LSB rule: 1bpp bit 7 and the
//!      4bpp high nibble are the leftmost pixel.
//!   F. Sprite palette offset: opaque pixels map to (value + offset) & $FF;
//!      index 0 stays transparent regardless of offset. Sprite depth = the
//!      latched frame depth (v1.1 §3.6 "shares the active palette mode").
//!   G. Collision is evaluated among the ≤8 sprites actually rendered on a
//!      scanline (skipped sprites can't collide — they aren't processed).
//!   H. The text-mode font is fetched from the ROM image directly (offset
//!      $2000 = $FE000), unaffected by the CPU's shadow mapping; text cells
//!      paint their background nibble (opaque). Partial bottom cell rows
//!      (180/540 lines) clip.
//!   I. VSTAT bit 1 (raster hit) is w1c like bits 2–3; bit 0 is timing-
//!      driven and read-only.

const std = @import("std");
const util = @import("util");
const ram_mod = @import("ram");
const rom_mod = @import("rom");

const Ram = ram_mod.Ram;
const Rom = rom_mod.Rom;

// ---------------------------------------------------------------------------
// Register addresses (Phase 3 §3.8).
// ---------------------------------------------------------------------------

pub const base_addr: u32 = 0x80200;
pub const end_addr: u32 = 0x802FF;

const reg_vmode: u32 = 0x80200;
const reg_vpalette: u32 = 0x80201;
const reg_vresx: u32 = 0x80202;
const reg_vresy: u32 = 0x80203;
const reg_vbgcol: u32 = 0x80204;
const reg_vtilesize: u32 = 0x80205;
const reg_vbuflo: u32 = 0x80206;
const reg_vbufhi: u32 = 0x80207;
const reg_vbuf2lo: u32 = 0x80208;
const reg_vbuf2hi: u32 = 0x80209;
const reg_vswap: u32 = 0x8020A;
const reg_vpalbase_lo: u32 = 0x8020B;
const reg_vpalbase_hi: u32 = 0x8020C;
const reg_vsatbase_lo: u32 = 0x8020D;
const reg_vsatbase_hi: u32 = 0x8020E;
const reg_vtmapbase_lo: u32 = 0x8020F;
const reg_vtmapbase_hi: u32 = 0x80210;
const reg_vscrollx: u32 = 0x80211;
const reg_vscrolly: u32 = 0x80212;
const reg_vsprena: u32 = 0x80213;
const reg_vscanlo: u32 = 0x80214;
const reg_vscanhi: u32 = 0x80215;
const reg_virqen: u32 = 0x80216;
const reg_vstat: u32 = 0x80217;

pub const max_width = 1280;
pub const max_height = 720;

const vram_base: u32 = 0x40000;
const vram_end: u32 = 0x7FFFF; // inclusive
const tile_gfx_base: u32 = 0x40000; // §3.7: 16KB tile graphics RAM
const font_rom_offset: u32 = 0x2000; // $FE000 − $FC000 (Phase 6 §6.1)

const res_x_table = [4]u32{ 320, 640, 960, 1280 }; // VRESX (v1.1 §5.2)
const res_y_table = [4]u32{ 180, 360, 540, 720 }; // VRESY

/// Legal (X, Y, bpp) combinations — exactly the §3.4 table rows (v1.1 §5.2).
fn modeLegal(xi: u2, yi: u2, bpp: u8) bool {
    const w = res_x_table[xi];
    const h = res_y_table[yi];
    return switch (bpp) {
        8 => (w == 320 and h == 180) or (w == 640 and h == 360),
        4 => (w == 320 and h == 180) or (w == 640 and h == 360),
        1 => (w == 640 and h == 360) or (w == 960 and h == 540) or (w == 1280 and h == 720),
        else => false,
    };
}

fn bppOf(vpalette: u8) ?u8 {
    return switch (vpalette) {
        0 => 1,
        1 => 4,
        3 => 8,
        else => null, // 2 = reserved (5bpp removed, v1.1 §5.1)
    };
}

/// Line timing per vertical resolution (v1.1 §5.6 / util.mode_timing).
fn timingFor(height: u32) util.ModeTiming {
    return switch (height) {
        180 => util.mode_timing[0],
        360 => util.mode_timing[1],
        540 => util.mode_timing[2],
        else => util.mode_timing[3],
    };
}

/// IRQ requests returned from startLine; machine.zig raises them on the
/// controller (keeps this module free of an io dependency).
pub const LineIrqs = struct {
    vblank: bool = false,
    raster: bool = false,
};

/// Frame-latched configuration (DECISION A).
const FrameConfig = struct {
    mode_err: bool, // this frame is running the fallback
    width: u32,
    height: u32,
    bpp: u8,
    visible_lines: u32,
    timing: util.ModeTiming,
};

pub const Vic = struct {
    // Live registers (byte-wide unless noted).
    vmode: u8 = 0,
    vpalette: u8 = 0,
    vresx: u8 = 0,
    vresy: u8 = 0,
    vbgcol: u8 = 0,
    vtilesize: u8 = 0,
    vbuf: u16 = 0, // address ÷ 16 (v1.1 §5.3)
    vbuf2: u16 = 0,
    vswap_pending: bool = false,
    vpalbase: u16 = 0,
    vsatbase: u16 = 0,
    vtmapbase: u16 = 0,
    vscrollx: u8 = 0,
    vscrolly: u8 = 0,
    vsprena: u8 = 0,
    vscan: u16 = 0,
    virqen: u8 = 0,
    // VSTAT latches.
    stat_vblank: bool = false,
    stat_raster: bool = false, // w1c (DECISION I)
    stat_collision: bool = false, // w1c (v1.1 §5.5)
    stat_moderr: bool = false, // w1c (v1.1 §5.2/§5.3)

    frame: FrameConfig = undefined,
    frame_valid: bool = false,

    /// RGB24 output, row-major, tightly packed at the frame's width.
    rgb: [max_width * max_height * 3]u8 = undefined,

    pub fn init(vic: *Vic) void {
        vic.* = .{};
        vic.latchFrame(); // sane frame config even before the first startFrame
        @memset(&vic.rgb, 0);
    }

    // ------------------------------------------------------------------
    // Register file (task 6.1). Byte registers: reads zero-extend, writes
    // take the low byte (§3.1 model — io.zig dispatches exact-address).
    // ------------------------------------------------------------------

    pub fn read(vic: *const Vic, addr: u32) u16 {
        return switch (addr) {
            reg_vmode => vic.vmode,
            reg_vpalette => vic.vpalette,
            reg_vresx => vic.vresx,
            reg_vresy => vic.vresy,
            reg_vbgcol => vic.vbgcol,
            reg_vtilesize => vic.vtilesize,
            reg_vbuflo => vic.vbuf & 0xFF,
            reg_vbufhi => vic.vbuf >> 8,
            reg_vbuf2lo => vic.vbuf2 & 0xFF,
            reg_vbuf2hi => vic.vbuf2 >> 8,
            reg_vswap => @intFromBool(vic.vswap_pending), // pending until the swap (§3.10)
            reg_vpalbase_lo => vic.vpalbase & 0xFF,
            reg_vpalbase_hi => vic.vpalbase >> 8,
            reg_vsatbase_lo => vic.vsatbase & 0xFF,
            reg_vsatbase_hi => vic.vsatbase >> 8,
            reg_vtmapbase_lo => vic.vtmapbase & 0xFF,
            reg_vtmapbase_hi => vic.vtmapbase >> 8,
            reg_vscrollx => vic.vscrollx,
            reg_vscrolly => vic.vscrolly,
            reg_vsprena => vic.vsprena,
            reg_vscanlo => vic.vscan & 0xFF,
            reg_vscanhi => vic.vscan >> 8,
            reg_virqen => vic.virqen,
            reg_vstat => @as(u16, @intFromBool(vic.stat_vblank)) |
                (@as(u16, @intFromBool(vic.stat_raster)) << 1) |
                (@as(u16, @intFromBool(vic.stat_collision)) << 2) |
                (@as(u16, @intFromBool(vic.stat_moderr)) << 3),
            else => 0x0000, // $80218–$802FF reserved
        };
    }

    pub fn write(vic: *Vic, addr: u32, value16: u16) void {
        const v: u8 = @truncate(value16);
        switch (addr) {
            reg_vmode => vic.vmode = v & 0x03,
            reg_vpalette => vic.vpalette = v & 0x03,
            reg_vresx => vic.vresx = v & 0x03,
            reg_vresy => vic.vresy = v & 0x03,
            reg_vbgcol => vic.vbgcol = v,
            reg_vtilesize => vic.vtilesize = v & 0x01,
            reg_vbuflo => vic.vbuf = (vic.vbuf & 0xFF00) | v,
            reg_vbufhi => vic.vbuf = (vic.vbuf & 0x00FF) | (@as(u16, v) << 8),
            reg_vbuf2lo => vic.vbuf2 = (vic.vbuf2 & 0xFF00) | v,
            reg_vbuf2hi => vic.vbuf2 = (vic.vbuf2 & 0x00FF) | (@as(u16, v) << 8),
            reg_vswap => {
                if (v & 0x01 != 0) vic.vswap_pending = true; // executes at VBLANK
            },
            reg_vpalbase_lo => vic.vpalbase = (vic.vpalbase & 0xFF00) | v,
            reg_vpalbase_hi => vic.vpalbase = (vic.vpalbase & 0x00FF) | (@as(u16, v) << 8),
            reg_vsatbase_lo => vic.vsatbase = (vic.vsatbase & 0xFF00) | v,
            reg_vsatbase_hi => vic.vsatbase = (vic.vsatbase & 0x00FF) | (@as(u16, v) << 8),
            reg_vtmapbase_lo => vic.vtmapbase = (vic.vtmapbase & 0xFF00) | v,
            reg_vtmapbase_hi => vic.vtmapbase = (vic.vtmapbase & 0x00FF) | (@as(u16, v) << 8),
            reg_vscrollx => vic.vscrollx = v & 0x0F, // 0–15 (§3.8)
            reg_vscrolly => vic.vscrolly = v & 0x0F,
            reg_vsprena => vic.vsprena = v,
            reg_vscanlo => vic.vscan = (vic.vscan & 0xFF00) | v,
            reg_vscanhi => vic.vscan = (vic.vscan & 0x00FF) | (@as(u16, v) << 8),
            reg_virqen => vic.virqen = v & 0x03,
            reg_vstat => {
                // w1c for raster/collision/mode-error; bit 0 is timing-driven.
                if (v & 0x02 != 0) vic.stat_raster = false;
                if (v & 0x04 != 0) vic.stat_collision = false;
                if (v & 0x08 != 0) vic.stat_moderr = false;
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // Frame and line sequencing (tasks 6.2, 6.17–6.19).
    // ------------------------------------------------------------------

    fn latchFrame(vic: *Vic) void {
        const bpp = bppOf(vic.vpalette);
        const legal = bpp != null and modeLegal(@truncate(vic.vresx), @truncate(vic.vresy), bpp.?);
        if (legal) {
            const w = res_x_table[@as(u2, @truncate(vic.vresx))];
            const h = res_y_table[@as(u2, @truncate(vic.vresy))];
            vic.frame = .{
                .mode_err = false,
                .width = w,
                .height = h,
                .bpp = bpp.?,
                .visible_lines = h,
                .timing = timingFor(h),
            };
        } else {
            // Fallback 320×180 @ 8bpp + VSTAT bit 3 (v1.1 §5.2, task 6.4).
            vic.frame = .{
                .mode_err = true,
                .width = 320,
                .height = 180,
                .bpp = 8,
                .visible_lines = 180,
                .timing = timingFor(180),
            };
            vic.stat_moderr = true;
        }
        vic.frame_valid = true;
    }

    /// Called before line 0: latch geometry (DECISION A), clear
    /// VSTAT.VBLANK ("clears at line 0", §5.6), return this frame's timing.
    pub fn startFrame(vic: *Vic) util.ModeTiming {
        vic.latchFrame();
        vic.stat_vblank = false;
        return vic.frame.timing;
    }

    /// Called before each line's CPU quantum.
    pub fn startLine(vic: *Vic, line: u32) LineIrqs {
        var irqs = LineIrqs{};
        if (line == vic.frame.visible_lines) {
            // Start of the first VBLANK line (§5.6): VSTAT bit 0 sets, a
            // pending VSWAP executes (register contents exchange, §3.10),
            // and the VBLANK IRQ is requested if enabled.
            vic.stat_vblank = true;
            if (vic.vswap_pending) {
                const t = vic.vbuf;
                vic.vbuf = vic.vbuf2;
                vic.vbuf2 = t;
                vic.vswap_pending = false;
            }
            if (vic.virqen & 0x01 != 0) irqs.vblank = true;
        }
        if (line < vic.frame.visible_lines and line == vic.vscan) {
            // Raster IRQ at the start of the target visible line (§5.6);
            // the handler runs during this line's quantum, so its register
            // writes affect this very line (task 6.18).
            vic.stat_raster = true;
            if (vic.virqen & 0x02 != 0) irqs.raster = true;
        }
        return irqs;
    }

    // ------------------------------------------------------------------
    // Rendering (tasks 6.3–6.16, 6.20). Called after the line's quantum.
    // ------------------------------------------------------------------

    pub fn renderLine(vic: *Vic, line: u32, ram: *const Ram, rom: *const Rom) void {
        const f = &vic.frame;
        if (line >= f.visible_lines) return;
        const w = f.width;

        // Per-line index composition buffer (final palette indices).
        var idx: [max_width]u8 = undefined;

        // 1. Background fill (task 6.5).
        @memset(idx[0..w], vic.vbgcol);

        // 2. Bitmap layer — modes 0 and 2; opaque (it *is* the picture).
        if (vic.vmode == 0 or vic.vmode == 2) {
            vic.renderBitmapLine(line, ram, idx[0..w]);
        }

        // 3–5. Sprites and the tile/text layer, with priority interleave:
        //    bg → bitmap → behind-sprites → tile/text → front-sprites
        // (v1.1 §5.5: priority 1 = behind the tile layer, above the bitmap).
        var spr_color: [max_width]u8 = undefined;
        var spr_behind: [max_width]bool = undefined;
        var spr_present: [max_width]bool = undefined;
        @memset(spr_present[0..w], false);
        vic.renderSpriteLine(line, ram, spr_color[0..w], spr_behind[0..w], spr_present[0..w]);

        for (0..w) |x| {
            if (spr_present[x] and spr_behind[x]) idx[x] = spr_color[x];
        }
        switch (vic.vmode) {
            1, 2 => vic.renderTileLine(line, ram, idx[0..w]),
            3 => vic.renderTextLine(line, ram, rom, idx[0..w]),
            else => {},
        }
        for (0..w) |x| {
            if (spr_present[x] and !spr_behind[x]) idx[x] = spr_color[x];
        }

        // 6. Palette lookup → RGB24 row (task 6.6, DECISION C/D).
        const pal_base = @as(u32, vic.vpalbase) * 16;
        const pal_ok = pal_base <= 0x3FFFF;
        if (!pal_ok) vic.stat_moderr = true;
        const row = vic.rgb[line * w * 3 ..][0 .. w * 3];
        for (0..w) |x| {
            const i = idx[x];
            if (pal_ok) {
                const e = pal_base + 3 * @as(u32, i);
                if (e + 2 < ram_mod.size) {
                    row[x * 3 + 0] = ram.readByte(e);
                    row[x * 3 + 1] = ram.readByte(e + 1);
                    row[x * 3 + 2] = ram.readByte(e + 2);
                    continue;
                }
            }
            row[x * 3 + 0] = 0;
            row[x * 3 + 1] = 0;
            row[x * 3 + 2] = 0;
        }
    }

    /// Unpack one pixel at (px) from a packed row starting at byte address
    /// `row_addr` in RAM, at the frame depth (DECISION E: MSB→LSB).
    fn fetchPixel(ram: *const Ram, row_addr: u32, px: u32, bpp: u8) u8 {
        return switch (bpp) {
            8 => ram.readByte(row_addr + px),
            4 => blk: {
                const byte = ram.readByte(row_addr + px / 2);
                break :blk if (px % 2 == 0) byte >> 4 else byte & 0x0F;
            },
            else => blk: { // 1bpp
                const byte = ram.readByte(row_addr + px / 8);
                const bit: u3 = @intCast(7 - (px % 8));
                break :blk (byte >> bit) & 1;
            },
        };
    }

    /// Bitmap layer (tasks 6.7–6.9): raw framebuffer at VBUF×16.
    fn renderBitmapLine(vic: *Vic, line: u32, ram: *const Ram, out: []u8) void {
        const f = &vic.frame;
        const buf = @as(u32, vic.vbuf) * 16;
        const stride = f.width * f.bpp / 8;
        const row_addr = buf + line * stride;
        // DECISION C: validated at use — VBUF must resolve into VRAM and
        // the row must fit; otherwise skip the layer and flag mode error.
        if (buf < vram_base or buf > vram_end or row_addr + stride > ram_mod.size) {
            vic.stat_moderr = true;
            return;
        }
        for (0..f.width) |x| {
            out[x] = fetchPixel(ram, row_addr, @intCast(x), f.bpp);
        }
    }

    /// Tile layer (tasks 6.10–6.12): map in general RAM (one byte per cell,
    /// §3.5), graphics in tile RAM, fine scroll wraps toroidally
    /// (DECISION B). Tile pixel 0 is transparent.
    fn renderTileLine(vic: *Vic, line: u32, ram: *const Ram, out: []u8) void {
        const f = &vic.frame;
        const map_base = @as(u32, vic.vtmapbase) * 16;
        if (map_base > 0x3FFFF) {
            vic.stat_moderr = true;
            return;
        }
        const tilepx: u32 = if (vic.vtilesize == 0) 8 else 16;
        const cols = f.width / tilepx;
        const rows = f.height / tilepx;
        if (cols == 0 or rows == 0) return;
        const bytes_per_tile = tilepx * tilepx * f.bpp / 8;

        const src_y = (line + vic.vscrolly) % f.height;
        const trow = src_y / tilepx;
        const in_ty = src_y % tilepx;
        for (0..f.width) |x| {
            const src_x = (@as(u32, @intCast(x)) + vic.vscrollx) % f.width;
            const tcol = src_x / tilepx;
            const in_tx = src_x % tilepx;
            const cell = map_base + (@min(trow, rows - 1)) * cols + tcol;
            if (cell >= ram_mod.size) continue;
            const tile_index: u32 = ram.readByte(cell);
            const gfx = tile_gfx_base + tile_index * bytes_per_tile;
            const row_addr = gfx + in_ty * (tilepx * f.bpp / 8);
            if (row_addr + tilepx * f.bpp / 8 > ram_mod.size) continue;
            const pix = fetchPixel(ram, row_addr, in_tx, f.bpp);
            if (pix != 0) out[x] = pix; // index 0 transparent
        }
    }

    /// Text mode (task 6.20): 2-byte cells via VTMAPBASE, ROM font at
    /// $FE000, bit 7 = leftmost, fg = attr[3:0], bg = attr[7:4] from
    /// palette entries 0–15 (v1.1 §5.4). Cells are opaque (DECISION H).
    fn renderTextLine(vic: *Vic, line: u32, ram: *const Ram, rom: *const Rom, out: []u8) void {
        const f = &vic.frame;
        const map_base = @as(u32, vic.vtmapbase) * 16;
        if (map_base > 0x3FFFF) {
            vic.stat_moderr = true;
            return;
        }
        const cols = f.width / 8;
        const cell_row = line / 8;
        const glyph_row: u3 = @intCast(line % 8);
        for (0..cols) |c| {
            const cell_addr = map_base + 2 * (cell_row * cols + @as(u32, @intCast(c)));
            if (cell_addr + 1 >= ram_mod.size) continue;
            const ch = ram.readByte(cell_addr);
            const attr = ram.readByte(cell_addr + 1);
            const fg = attr & 0x0F;
            const bg = attr >> 4;
            const glyph = rom.readByte(font_rom_offset + 8 * @as(u32, ch) + glyph_row);
            for (0..8) |px| {
                const bit: u3 = @intCast(7 - px); // bit 7 = leftmost (§5.4)
                out[c * 8 + px] = if ((glyph >> bit) & 1 != 0) fg else bg;
            }
        }
    }

    /// Sprite layer (tasks 6.13–6.16): select ≤8 sprites covering this
    /// line in index order (lower index = higher priority — first writer
    /// wins per pixel), detect opaque overlap → VSTAT bit 2.
    fn renderSpriteLine(vic: *Vic, line: u32, ram: *const Ram, color: []u8, behind: []bool, present: []bool) void {
        const f = &vic.frame;
        const sat_base = @as(u32, vic.vsatbase) * 16;
        if (sat_base > 0x3FFFF) {
            vic.stat_moderr = true;
            return;
        }
        const y_line: i32 = @intCast(line);
        var rendered: u32 = 0;
        var sprite: u32 = 0;
        while (sprite < 64 and rendered < 8) : (sprite += 1) {
            // Group enable: VSPRENA bit per group of 8 (§3.8).
            if ((vic.vsprena >> @intCast(sprite / 8)) & 1 == 0) continue;
            const e = sat_base + 8 * sprite;
            if (e + 7 >= ram_mod.size) continue;
            const flags = ram.readByte(e + 5);
            if (flags & 0x80 == 0) continue; // enable bit 7 (MSB→LSB, §5.5)
            const size_sel: u2 = @truncate(flags >> 3);
            if (size_sel == 3) continue; // reserved
            const size: u32 = @as(u32, 8) << size_sel; // 8 / 16 / 32
            const sy = readI16(ram, e + 2);
            if (y_line < sy or y_line >= sy + @as(i32, @intCast(size))) continue;

            // This sprite covers the line — one of the 8 hardware units
            // (task 6.15: excess silently skipped).
            rendered += 1;
            const sx = readI16(ram, e + 0);
            const tile_index: u32 = ram.readByte(e + 4);
            const pal_offset = ram.readByte(e + 6);
            const flip_x = flags & 0x40 != 0;
            const flip_y = flags & 0x20 != 0;
            const is_behind = flags & 0x04 != 0; // priority bit 2

            const stride = size * size * f.bpp / 8; // §5.5
            const gfx = tile_gfx_base + tile_index * stride;
            var row_in: u32 = @intCast(y_line - sy);
            if (flip_y) row_in = size - 1 - row_in;
            const row_addr = gfx + row_in * (size * f.bpp / 8);
            if (row_addr + size * f.bpp / 8 > ram_mod.size) continue;

            var px: u32 = 0;
            while (px < size) : (px += 1) {
                const screen_x = sx + @as(i32, @intCast(px));
                if (screen_x < 0 or screen_x >= f.width) continue;
                const col_in = if (flip_x) size - 1 - px else px;
                const value = fetchPixel(ram, row_addr, col_in, f.bpp);
                if (value == 0) continue; // index 0 transparent (§3.6)
                const x: usize = @intCast(screen_x);
                if (present[x]) {
                    // A lower-index sprite already owns this pixel: opaque
                    // overlap → global collision flag (§5.5, DECISION G).
                    vic.stat_collision = true;
                    continue; // lower index = higher priority
                }
                present[x] = true;
                color[x] = value +% pal_offset; // DECISION F: (value + offset) & $FF
                behind[x] = is_behind;
            }
        }
    }

    // ------------------------------------------------------------------
    // Output access (task 6.21 golden harness; main.zig presentation).
    // ------------------------------------------------------------------

    pub fn visibleWidth(vic: *const Vic) u32 {
        return vic.frame.width;
    }
    pub fn visibleHeight(vic: *const Vic) u32 {
        return vic.frame.height;
    }

    /// SHA-256 of the visible RGB24 buffer (task 6.21).
    pub fn frameHash(vic: *const Vic) [32]u8 {
        var h: [32]u8 = undefined;
        const n = vic.frame.width * vic.frame.height * 3;
        std.crypto.hash.sha2.Sha256.hash(vic.rgb[0..n], &h, .{});
        return h;
    }
};

fn readI16(ram: *const Ram, addr: u32) i32 {
    const lo: u16 = ram.readByte(addr);
    const hi: u16 = ram.readByte(addr + 1);
    return @as(i16, @bitCast(lo | (hi << 8)));
}

/// Retained for the Block 1 module-liveness check pattern.
pub fn init() void {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const expectEqual = testing.expectEqual;

const Fixture = struct {
    ram: *Ram,
    rom: *Rom,
    vic: *Vic,

    fn setup() !Fixture {
        const ram = try testing.allocator.create(Ram);
        errdefer testing.allocator.destroy(ram);
        const rom = try testing.allocator.create(Rom);
        errdefer testing.allocator.destroy(rom);
        const vic = try testing.allocator.create(Vic);
        ram.init();
        rom.init();
        vic.init();
        return .{ .ram = ram, .rom = rom, .vic = vic };
    }

    fn teardown(f: *Fixture) void {
        testing.allocator.destroy(f.ram);
        testing.allocator.destroy(f.rom);
        testing.allocator.destroy(f.vic);
    }

    /// 320×180 @ 8bpp, VBUF=$44000, palette at $02100, SAT at $02400,
    /// tile map at $02600 (the BIOS conventions) — identity palette
    /// (entry i = (i, i, i)) for easy assertions.
    fn standardMode(f: *Fixture) void {
        f.vic.write(reg_vmode, 0);
        f.vic.write(reg_vpalette, 3); // 8bpp
        f.vic.write(reg_vresx, 0); // 320
        f.vic.write(reg_vresy, 0); // 180
        setBase(f.vic, reg_vbuflo, 0x44000);
        setBase(f.vic, reg_vpalbase_lo, 0x02100);
        setBase(f.vic, reg_vsatbase_lo, 0x02400);
        setBase(f.vic, reg_vtmapbase_lo, 0x02600);
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            const v: u8 = @intCast(i);
            f.ram.writeByte(0x02100 + 3 * i + 0, v);
            f.ram.writeByte(0x02100 + 3 * i + 1, v);
            f.ram.writeByte(0x02100 + 3 * i + 2, v);
        }
        _ = f.vic.startFrame();
    }

    fn setBase(vic: *Vic, lo_reg: u32, addr: u32) void {
        const div16: u16 = @intCast(addr / 16);
        vic.write(lo_reg, div16 & 0xFF);
        vic.write(lo_reg + 1, div16 >> 8);
    }

    fn pixel(f: *Fixture, x: u32, y: u32) [3]u8 {
        const w = f.vic.visibleWidth();
        const o = (y * w + x) * 3;
        return .{ f.vic.rgb[o], f.vic.rgb[o + 1], f.vic.rgb[o + 2] };
    }
};

test "6.1 registers: byte round-trips, base ÷16 maths, reserved reads zero" {
    var f = try Fixture.setup();
    defer f.teardown();
    const vic = f.vic;
    vic.write(reg_vbgcol, 0x0142); // low byte lands
    try expectEqual(@as(u16, 0x42), vic.read(reg_vbgcol));
    // Base pair: $44000 ÷ 16 = $4400 → LO $00, HI $44.
    Fixture.setBase(vic, reg_vbuflo, 0x44000);
    try expectEqual(@as(u16, 0x00), vic.read(reg_vbuflo));
    try expectEqual(@as(u16, 0x44), vic.read(reg_vbufhi));
    try expectEqual(@as(u16, 0), vic.read(0x80218)); // reserved
    try expectEqual(@as(u16, 0), vic.read(0x802FF));
    vic.write(reg_vscanlo, 0x2C);
    vic.write(reg_vscanhi, 0x01);
    try expectEqual(@as(u16, 0x012C), vic.vscan); // 300
}

test "6.2 frame latch: every legal mode row gets exact timing; totals = 240,000" {
    var f = try Fixture.setup();
    defer f.teardown();
    const rows = [_]struct { x: u8, y: u8, pal: u8, w: u32, h: u32 }{
        .{ .x = 0, .y = 0, .pal = 3, .w = 320, .h = 180 },
        .{ .x = 0, .y = 0, .pal = 1, .w = 320, .h = 180 },
        .{ .x = 1, .y = 1, .pal = 3, .w = 640, .h = 360 },
        .{ .x = 1, .y = 1, .pal = 1, .w = 640, .h = 360 },
        .{ .x = 1, .y = 1, .pal = 0, .w = 640, .h = 360 },
        .{ .x = 2, .y = 2, .pal = 0, .w = 960, .h = 540 },
        .{ .x = 3, .y = 3, .pal = 0, .w = 1280, .h = 720 },
    };
    for (rows) |r| {
        f.vic.write(reg_vresx, r.x);
        f.vic.write(reg_vresy, r.y);
        f.vic.write(reg_vpalette, r.pal);
        const t = f.vic.startFrame();
        try expectEqual(r.w, f.vic.visibleWidth());
        try expectEqual(r.h, f.vic.visibleHeight());
        try testing.expect(!f.vic.frame.mode_err);
        try expectEqual(@as(u32, 240_000), t.cycles_per_line * t.total_lines);
        try expectEqual(r.h, f.vic.frame.visible_lines);
    }
}

test "6.4 illegal modes fall back to 320×180@8bpp + VSTAT bit 3 (w1c)" {
    var f = try Fixture.setup();
    defer f.teardown();
    const bad = [_]struct { x: u8, y: u8, pal: u8 }{
        .{ .x = 2, .y = 2, .pal = 3 }, // 960×540 @ 8bpp — over budget
        .{ .x = 3, .y = 3, .pal = 1 }, // 1280×720 @ 4bpp
        .{ .x = 0, .y = 0, .pal = 2 }, // reserved VPALETTE (5bpp removed)
        .{ .x = 0, .y = 3, .pal = 3 }, // 320×720 — not a table row
    };
    for (bad) |r| {
        f.vic.write(reg_vresx, r.x);
        f.vic.write(reg_vresy, r.y);
        f.vic.write(reg_vpalette, r.pal);
        _ = f.vic.startFrame();
        try testing.expect(f.vic.frame.mode_err);
        try expectEqual(@as(u32, 320), f.vic.visibleWidth());
        try expectEqual(@as(u32, 180), f.vic.visibleHeight());
        try expectEqual(@as(u16, 0x08), f.vic.read(reg_vstat) & 0x08);
        f.vic.write(reg_vstat, 0x08); // w1c
        try expectEqual(@as(u16, 0), f.vic.read(reg_vstat) & 0x08);
    }
}

test "6.5/6.6 background fill through the palette" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode();
    f.ram.writeByte(0x02100 + 3 * 7 + 0, 0xAA); // palette[7] = (AA, BB, CC)
    f.ram.writeByte(0x02100 + 3 * 7 + 1, 0xBB);
    f.ram.writeByte(0x02100 + 3 * 7 + 2, 0xCC);
    f.vic.write(reg_vbgcol, 7);
    f.vic.write(reg_vmode, 1); // tile mode with empty map: background shows
    f.vic.renderLine(0, f.ram, f.rom);
    // Empty tile map (index 0 → tile 0 = zeroed VRAM → transparent).
    try expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, f.pixel(0, 0));
    try expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, f.pixel(319, 0));
}

test "6.7–6.9 bitmap layer at 8, 4, and 1 bpp (MSB→LSB packing)" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode(); // 8bpp
    f.ram.writeByte(0x44000 + 0, 10); // line 0, x 0
    f.ram.writeByte(0x44000 + 319, 20); // line 0, x 319
    f.ram.writeByte(0x44000 + 320 * 5 + 100, 30); // line 5, x 100
    f.vic.renderLine(0, f.ram, f.rom);
    f.vic.renderLine(5, f.ram, f.rom);
    try expectEqual([3]u8{ 10, 10, 10 }, f.pixel(0, 0));
    try expectEqual([3]u8{ 20, 20, 20 }, f.pixel(319, 0));
    try expectEqual([3]u8{ 30, 30, 30 }, f.pixel(100, 5));

    // 4bpp: high nibble = leftmost pixel.
    f.vic.write(reg_vpalette, 1);
    _ = f.vic.startFrame();
    f.ram.writeByte(0x44000, 0x5A); // x0 = 5, x1 = 10
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(0, 0));
    try expectEqual([3]u8{ 10, 10, 10 }, f.pixel(1, 0));

    // 1bpp at 640×360: bit 7 = leftmost.
    f.vic.write(reg_vpalette, 0);
    f.vic.write(reg_vresx, 1);
    f.vic.write(reg_vresy, 1);
    _ = f.vic.startFrame();
    f.ram.writeByte(0x44000, 0x80); // only x0 set
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 1, 1, 1 }, f.pixel(0, 0));
    try expectEqual([3]u8{ 0, 0, 0 }, f.pixel(1, 0));
}

test "6.10/6.11 tile layer: map lookup, graphics fetch, fine scroll wrap" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode();
    f.vic.write(reg_vmode, 1);
    f.vic.write(reg_vbgcol, 99);
    // Tile 1: solid colour 5. Tile graphics at $40000, 64 B/tile @ 8bpp.
    var i: u32 = 0;
    while (i < 64) : (i += 1) f.ram.writeByte(0x40000 + 64 + i, 5);
    // Map: cell (0,0) = tile 1, everything else tile 0 (transparent).
    f.ram.writeByte(0x02600, 1);
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(0, 0));
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(7, 0));
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(8, 0)); // next cell: bg through
    // Fine scroll: +3 px shifts the tile left by 3.
    f.vic.write(reg_vscrollx, 3);
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(4, 0)); // src_x 7 still in tile
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(5, 0)); // src_x 8 out
    // Toroidal wrap: src for x=317 is (317+3)%320 = 0 → tile 1 again.
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(317, 0));
    // Vertical scroll: line 6 + scrolly 3 → src_y 9 → tile row 1 = map row 1
    // (tile 0, transparent).
    f.vic.write(reg_vscrollx, 0);
    f.vic.write(reg_vscrolly, 3);
    f.vic.renderLine(6, f.ram, f.rom);
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(0, 6));
    f.vic.renderLine(4, f.ram, f.rom); // src_y 7: still tile row 0
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(0, 4));
}

test "6.12 mode 2: tile overlay composites over the bitmap" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode();
    f.vic.write(reg_vmode, 2);
    // Bitmap: everything colour 40.
    var i: u32 = 0;
    while (i < 320) : (i += 1) f.ram.writeByte(0x44000 + i, 40);
    // Tile 1 solid 5 in map cell 0; tile 0 (transparent) elsewhere.
    i = 0;
    while (i < 64) : (i += 1) f.ram.writeByte(0x40000 + 64 + i, 5);
    f.ram.writeByte(0x02600, 1);
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(0, 0)); // tile over bitmap
    try expectEqual([3]u8{ 40, 40, 40 }, f.pixel(8, 0)); // bitmap through hole
}

test "6.20 text mode: cells, attributes, ROM font bit 7 leftmost" {
    var f = try Fixture.setup();
    defer f.teardown();
    // 640×360 text — integral 80×45 grid.
    f.vic.write(reg_vmode, 3);
    f.vic.write(reg_vpalette, 3);
    f.vic.write(reg_vresx, 1);
    f.vic.write(reg_vresy, 1);
    Fixture.setBase(f.vic, reg_vpalbase_lo, 0x02100);
    Fixture.setBase(f.vic, reg_vtmapbase_lo, 0x02600);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        const v: u8 = @intCast(i);
        f.ram.writeByte(0x02100 + 3 * i + 0, v);
        f.ram.writeByte(0x02100 + 3 * i + 1, v);
        f.ram.writeByte(0x02100 + 3 * i + 2, v);
    }
    _ = f.vic.startFrame();
    // Font: char 'A' (65) row 0 = $C1 (bits 7,6,0).
    var image: [rom_mod.size]u8 = @splat(0);
    image[font_rom_offset + 8 * 65 + 0] = 0xC1;
    try f.rom.loadFromSlice(&image);
    // Cell (0,0): char 65, fg 3, bg 12 → attr $C3.
    f.ram.writeByte(0x02600 + 0, 65);
    f.ram.writeByte(0x02600 + 1, 0xC3);
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 3, 3, 3 }, f.pixel(0, 0)); // bit 7 → fg
    try expectEqual([3]u8{ 3, 3, 3 }, f.pixel(1, 0)); // bit 6 → fg
    try expectEqual([3]u8{ 12, 12, 12 }, f.pixel(2, 0)); // bit 5 clear → bg
    try expectEqual([3]u8{ 3, 3, 3 }, f.pixel(7, 0)); // bit 0 → fg
    try expectEqual([3]u8{ 0, 0, 0 }, f.pixel(8, 0)); // next cell: char 0 → bg 0
}

test "6.13–6.16 sprites: position, flip, priority, group enable, 8/line, collision" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode();
    f.vic.write(reg_vmode, 1); // tile layer for priority testing
    f.vic.write(reg_vbgcol, 99);
    // Tile 1 solid 5 in cell (1,0) → pixels x 8..15.
    var i: u32 = 0;
    while (i < 64) : (i += 1) f.ram.writeByte(0x40000 + 64 + i, 5);
    f.ram.writeByte(0x02600 + 1, 1);
    // Sprite graphic tile 2 (8×8 @ 8bpp): left half colour 7, right half 0.
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) f.ram.writeByte(0x40000 + 2 * 64 + y * 8 + x, 7);
    }
    const sat = 0x02400;
    // Sprite 0 at (0, 0), front.
    writeSat(f.ram, sat, 0, 0, 0, 2, 0x80, 0);
    // Sprite 1 at (8, 0), behind the tile layer (priority bit 2).
    writeSat(f.ram, sat, 1, 8, 0, 2, 0x80 | 0x04, 0);
    // Sprite 2 at (20, 0), flip-X — opaque half moves to the right.
    writeSat(f.ram, sat, 2, 20, 0, 2, 0x80 | 0x40, 0);
    // Sprite 3 overlaps sprite 0 → collision; lower index wins the pixel.
    writeSat(f.ram, sat, 3, 2, 0, 2, 0x80, 10); // palette offset 10
    f.vic.write(reg_vsprena, 0x01); // group 0 enabled
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 7, 7, 7 }, f.pixel(0, 0)); // sprite 0 over bg
    try expectEqual([3]u8{ 5, 5, 5 }, f.pixel(8, 0)); // sprite 1 hidden behind tile
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(20, 0)); // flip-X: left now transparent
    try expectEqual([3]u8{ 7, 7, 7 }, f.pixel(24, 0)); // flip-X: right opaque
    try expectEqual([3]u8{ 7, 7, 7 }, f.pixel(2, 0)); // sprite 0 wins over 3
    // x=4: sprite 0's right half is transparent; sprite 3 (at x=2, opaque
    // cols 2..5) shows alone with its palette offset: 7 + 10 = 17.
    try expectEqual([3]u8{ 17, 17, 17 }, f.pixel(4, 0));
    try expectEqual(@as(u16, 0x04), f.vic.read(reg_vstat) & 0x04); // collision
    f.vic.write(reg_vstat, 0x04);
    try expectEqual(@as(u16, 0), f.vic.read(reg_vstat) & 0x04); // w1c

    // Sprite 1 behind-tile but over background where no tile: move to x 40.
    writeSat(f.ram, sat, 1, 40, 0, 2, 0x80 | 0x04, 0);
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 7, 7, 7 }, f.pixel(40, 0)); // above bg/bitmap

    // Group enable off → nothing renders.
    f.vic.write(reg_vsprena, 0x00);
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(0, 0));
    f.vic.write(reg_vsprena, 0xFF);

    // 8-per-scanline limit: ten sprites on line 40; index 8 and 9 skipped.
    var s: u32 = 0;
    while (s < 10) : (s += 1) {
        writeSat(f.ram, sat, s, @intCast(10 * s), 40, 2, 0x80, 0);
    }
    f.vic.renderLine(40, f.ram, f.rom);
    try expectEqual([3]u8{ 7, 7, 7 }, f.pixel(70, 40)); // sprite 7 rendered
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(80, 40)); // sprite 8 skipped
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(90, 40)); // sprite 9 skipped

    // 16×16 sprite (size sel 1): stride 256, covers 16 lines.
    var g: u32 = 0;
    while (g < 256) : (g += 1) f.ram.writeByte(0x40000 + 1 * 256 + g, 9);
    writeSat(f.ram, sat, 20, 100, 60, 1, 0x80 | (1 << 3), 0);
    f.vic.renderLine(75, f.ram, f.rom); // last covered line: 60+15
    try expectEqual([3]u8{ 9, 9, 9 }, f.pixel(115, 75));
    f.vic.renderLine(76, f.ram, f.rom);
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(115, 76));
    // Negative X clips cleanly.
    writeSat(f.ram, sat, 21, -4, 100, 2, 0x80, 0);
    f.vic.renderLine(100, f.ram, f.rom);
    try expectEqual([3]u8{ 99, 99, 99 }, f.pixel(2, 100)); // cols 0..3 off-screen; col 4+ transparent half? no: left half opaque → x -4..-1 clipped, x 0..? sprite cols 4..7 are colour 0
}

test "6.17/6.19 VBLANK timing and VSWAP exchange at VBLANK" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode();
    f.vic.write(reg_virqen, 0x01); // VBLANK IRQ enable
    Fixture.setBase(f.vic, reg_vbuflo, 0x44000);
    Fixture.setBase(f.vic, reg_vbuf2lo, 0x54000);
    f.vic.write(reg_vswap, 1);
    try expectEqual(@as(u16, 1), f.vic.read(reg_vswap)); // pending, readable
    _ = f.vic.startFrame();
    try expectEqual(@as(u16, 0), f.vic.read(reg_vstat) & 1); // cleared at line 0
    var irqs = f.vic.startLine(0);
    try testing.expect(!irqs.vblank);
    irqs = f.vic.startLine(179);
    try testing.expect(!irqs.vblank);
    irqs = f.vic.startLine(180); // first VBLANK line
    try testing.expect(irqs.vblank);
    try expectEqual(@as(u16, 1), f.vic.read(reg_vstat) & 1);
    // VSWAP executed: register contents exchanged, bit auto-cleared (§3.10).
    try expectEqual(@as(u16, 0x54), f.vic.read(reg_vbufhi)); // $54000/16 = $5400 → HI $54
    try expectEqual(@as(u16, 0x44), f.vic.read(reg_vbuf2hi)); // old front now back
    try expectEqual(@as(u16, 0), f.vic.read(reg_vswap));
    const t = f.vic.startFrame(); // next frame: bit 0 clears again
    try expectEqual(@as(u16, 0), f.vic.read(reg_vstat) & 1);
    try expectEqual(@as(u32, 1200), t.cycles_per_line);
}

test "6.18 raster IRQ at the start of the target visible line only" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode();
    f.vic.write(reg_virqen, 0x02);
    f.vic.write(reg_vscanlo, 90);
    var irqs = f.vic.startLine(89);
    try testing.expect(!irqs.raster);
    irqs = f.vic.startLine(90);
    try testing.expect(irqs.raster);
    try expectEqual(@as(u16, 0x02), f.vic.read(reg_vstat) & 0x02);
    f.vic.write(reg_vstat, 0x02); // w1c (DECISION I)
    try expectEqual(@as(u16, 0), f.vic.read(reg_vstat) & 0x02);
    // Target in VBLANK region: never fires.
    f.vic.write(reg_vscanlo, 190);
    irqs = f.vic.startLine(190);
    try testing.expect(!irqs.raster);
    // Device gate: VIRQEN off → STAT still latches, no IRQ request.
    f.vic.write(reg_virqen, 0x00);
    f.vic.write(reg_vscanlo, 50);
    irqs = f.vic.startLine(50);
    try testing.expect(!irqs.raster);
    try expectEqual(@as(u16, 0x02), f.vic.read(reg_vstat) & 0x02);
}

test "6.4/C invalid VBUF at use: layer skipped, mode error set" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.standardMode();
    Fixture.setBase(f.vic, reg_vbuflo, 0x02000); // not in VRAM
    f.vic.write(reg_vbgcol, 3);
    f.vic.renderLine(0, f.ram, f.rom);
    try expectEqual([3]u8{ 3, 3, 3 }, f.pixel(0, 0)); // background only
    try expectEqual(@as(u16, 0x08), f.vic.read(reg_vstat) & 0x08);
}

fn writeSat(ram: *Ram, sat: u32, sprite: u32, x: i16, y: i16, tile: u8, flags: u8, pal_off: u8) void {
    const e = sat + 8 * sprite;
    const xu: u16 = @bitCast(x);
    const yu: u16 = @bitCast(y);
    ram.writeByte(e + 0, @truncate(xu));
    ram.writeByte(e + 1, @truncate(xu >> 8));
    ram.writeByte(e + 2, @truncate(yu));
    ram.writeByte(e + 3, @truncate(yu >> 8));
    ram.writeByte(e + 4, tile);
    ram.writeByte(e + 5, flags);
    ram.writeByte(e + 6, pal_off);
    ram.writeByte(e + 7, 0);
}
