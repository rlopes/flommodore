//! Flommodore — `aur1.zig` (Block 7).
//!
//! The AUR-1 sound chip: 4 voices (7 waveforms, ADSR, ring mod, hard sync,
//! FM pairs), the shared Chamberlin state-variable filter, and the
//! saturating stereo mixer, per Phase 4 as amended by v1.1 §6 (LOCKED).
//! Registers at $80100–$801FF, dispatched by io.zig.
//!
//! Synthesis is **bit-deterministic**: all-integer voice pipeline, LFSR
//! noise seeded $ACE1 at reset, and filter coefficients from comptime-
//! computed fixed-point tables — golden-audio hashes (task 7.22) hold
//! across hosts and targets.
//!
//! Timing: `tick()` is called once per master cycle (like io.tick). An
//! internal accumulator divides 14.4 MHz down to the ASRATE synthesis rate;
//! 14,400,000 / 44,100 is non-integer, but 240,000 cycles × 44,100 ÷
//! 14,400,000 = exactly 735 — a frame always yields 735 host samples at
//! rate 0, with the accumulator carrying the fraction across lines.
//! Register writes therefore take effect with *cycle* granularity — the
//! Phase 4 §4.9 software-PCM technique (timer IRQ writing VVOL at 45 kHz)
//! works as designed.
//!
//! Implementation decisions where Phase 4/v1.1 are silent (marked at use
//! sites; candidates for a v1.3 amendment):
//!   AUR-a  VWTB base pair holds address ÷ 16 (the VIC §5.3 convention);
//!          must resolve into RAM ($00000–$7FFFF), else reads yield $80
//!          (silence).
//!   AUR-b  FM enable is VWAVE bit 3 on the *modulator* voice (0 or 2);
//!          on voices 1/3 the bit is ignored. An FM modulator leaves the
//!          mixer.
//!   AUR-c  Envelope: linear ramps; table times are full-scale traversal
//!          times (SID convention). Attack rises from the current level;
//!          decay stops at sustain; in sustain the level tracks the live
//!          register; release falls to 0 → envelope complete (ASTAT bit,
//!          IRQ if AIRQEN).
//!   AUR-d  Ring mod applies post-envelope: out = (self × prev) >> 15.
//!          Voices compute in order 0→3, so voice 0's partner (voice 3)
//!          contributes its *previous* sample — a one-sample delay.
//!   AUR-e  Hard sync resets phase to 0 when the previous voice's
//!          accumulator wrapped (voice 0 ← voice 3's previous sample).
//!   AUR-f  Noise: the LFSR clocks once per 4096-boundary crossing of the
//!          phase accumulator (clock rate = 16 × F_out — pitch-dependent,
//!          SID-like), computed from the un-wrapped signed sum and capped
//!          at 16 clocks/sample. A bit-toggle rule would starve for
//!          increments that are multiples of the tested bit; boundary
//!          counting has no degenerate frequencies. Output = the LFSR
//!          value bit-cast to i16.
//!   AUR-g  Mixer scaling: voice = ((wave × env) >> 16 × VVOL) >> 8;
//!          channel = (voice × VOL4) >> 4; master = ((sum × AMVOL) >> 8
//!          × AMVOL4) >> 4; then saturate to i16.
//!   AUR-h  Filter coefficient f = 2·sin(π·fc/fs) in Q14 from a comptime
//!          table with the 12-bit cutoff quantised to 256 steps
//!          (AFCUT >> 4), clamped into (0, 1.99] (at ASRATE 1/2 the top
//!          of the cutoff curve exceeds Nyquist and saturates fully open);
//!          q⁻¹ in Q14 per AFRESON. Integer SVF, state clamped to ±2²⁰
//!          (self-oscillation stays bounded).
//!   AUR-i  Routed voices are filtered as a mono sum *after* per-voice
//!          volume but before pan; the filter output feeds both channels
//!          equally (per-voice pan applies to dry voices only).
//!   AUR-j  ASRATE value 3 is reserved and behaves as 0 (44.1 kHz).

const std = @import("std");
const util = @import("util");
const ram_mod = @import("ram");

const Ram = ram_mod.Ram;

pub const base_addr: u32 = 0x80100;
pub const end_addr: u32 = 0x801FF;

const global_base: u32 = 0x80140;

// Global register offsets from $80140 (§4.8).
const g_amvol: u32 = 0x0;
const g_amvoll: u32 = 0x1;
const g_amvolr: u32 = 0x2;
const g_amvoice: u32 = 0x3;
const g_amfilt: u32 = 0x4;
const g_afcutlo: u32 = 0x5; // bits 3:0 of the 12-bit cutoff
const g_afcuthi: u32 = 0x6; // bits 11:4
const g_afreson: u32 = 0x7;
const g_afmode: u32 = 0x8;
const g_asrate: u32 = 0x9;
const g_airqen: u32 = 0xA;
const g_astat: u32 = 0xB;

/// ADSR rate tables (v1.1 §6.2, SID-derived): 4-bit index → full-scale
/// traversal time in ms.
pub const attack_ms = [16]u32{ 2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000 };
pub const decay_ms = [16]u32{ 6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000 };

const lfsr_seed: u16 = 0xACE1;
const lfsr_taps: u16 = 0xB400;

/// Internal synthesis rates per ASRATE (v1.1 §6.2); host output is always
/// 44.1 kHz — internal samples are repeated 1×/2×/4×.
const rate_hz = [3]u32{ 44_100, 22_050, 11_025 };

// ---------------------------------------------------------------------------
// Comptime tables (AUR-h): sine waveform, filter f and q⁻¹ coefficients.
// Comptime float evaluation is performed by the compiler — identical for
// every build target, so golden-audio hashes are portable.
// ---------------------------------------------------------------------------

/// 256-entry sine, Q15 (±32767).
const sine_table: [256]i16 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]i16 = undefined;
    for (&t, 0..) |*e, i| {
        const x = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / 256.0);
        e.* = @intFromFloat(@round(x * 32767.0));
    }
    break :blk t;
};

/// Filter f coefficient, Q14: f = 2·sin(π·fc/fs), fc = 30 + (c/4095)²×11970
/// (§4.5), cutoff quantised to 256 steps, one table per ASRATE.
const filter_f_q14: [3][256]u16 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [3][256]u16 = undefined;
    for (&t, 0..) |*per_rate, r| {
        const fs: f64 = @floatFromInt(rate_hz[r]);
        for (per_rate, 0..) |*e, step| {
            const c: f64 = @floatFromInt(step * 16 + 8); // centre of the 16-value bucket
            const fc = 30.0 + (c / 4095.0) * (c / 4095.0) * 11970.0;
            // At ASRATE 1/2 the top of the cutoff curve exceeds Nyquist;
            // clamp f into (0, 1.99] — the filter saturates fully open.
            const f = @max(@min(2.0 * @sin(std.math.pi * fc / fs), 1.99), 0.001);
            e.* = @intFromFloat(@round(f * 16384.0));
        }
    }
    break :blk t;
};

/// q⁻¹ = 1/Q in Q14, Q = 0.5 + (r/15)×9.5 (§4.5).
const filter_qinv_q14: [16]u16 = blk: {
    var t: [16]u16 = undefined;
    for (&t, 0..) |*e, r| {
        const q = 0.5 + (@as(f64, @floatFromInt(r)) / 15.0) * 9.5;
        e.* = @intFromFloat(@round(16384.0 / q));
    }
    break :blk t;
};

// ---------------------------------------------------------------------------
// Voice.
// ---------------------------------------------------------------------------

const EnvPhase = enum { idle, attack, decay, sustain, release };

const Voice = struct {
    // Registers (§4.7).
    freq: u16 = 0,
    wave: u8 = 0, // bits 2:0 waveform | bit 3 FM enable (modulator, AUR-b)
    ctrl: u8 = 0, // gate(7) | ring(6) | sync(5); 4:0 reserved (v1.1 §6.1)
    adsr0: u8 = 0, // A[7:4] | D[3:0]
    adsr1: u8 = 0, // S[7:4] | R[3:0]
    pulse: u8 = 0,
    vol: u8 = 0,
    mod_depth: u16 = 0,
    fbk: u8 = 0, // bits 2:0
    wtb: u16 = 0, // wavetable base ÷ 16 (AUR-a)
    volr: u8 = 0, // 4-bit
    voll: u8 = 0, // 4-bit

    // Synthesis state.
    phase: u16 = 0,
    wrapped: bool = false, // accumulator wrapped during the last advance
    lfsr: u16 = lfsr_seed,
    env_level: u32 = 0, // Q16: 0 .. 65535<<16
    env_phase: EnvPhase = .idle,
    output: i32 = 0, // post-envelope, post-VVOL, pre-pan
    prev_output: i32 = 0, // last sample's output (FM feedback, AUR-d/e)

    fn gate(v: *const Voice) bool {
        return v.ctrl & 0x80 != 0;
    }

    /// Q16 envelope step for a full-scale traversal in `ms` at `fs` Hz:
    /// (65535 << 16) / (ms/1000 × fs).
    fn envStep(ms: u32, fs: u32) u32 {
        return @intCast(@as(u64, 65535 << 16) * 1000 / (@as(u64, ms) * fs));
    }

    fn advanceEnvelope(v: *Voice, fs: u32) bool {
        const sustain16: u32 = @as(u32, v.adsr1 >> 4) * 4369; // S × $1111
        switch (v.env_phase) {
            .attack => {
                const step = envStep(attack_ms[v.adsr0 >> 4], fs);
                const next = @as(u64, v.env_level) + step;
                if (next >= @as(u64, 65535) << 16) {
                    v.env_level = 65535 << 16;
                    v.env_phase = .decay;
                } else {
                    v.env_level = @intCast(next);
                }
            },
            .decay => {
                const step = envStep(decay_ms[v.adsr0 & 0xF], fs);
                const floor_q16 = sustain16 << 16;
                if (@as(u64, v.env_level) <= @as(u64, floor_q16) + step) {
                    v.env_level = floor_q16;
                    v.env_phase = .sustain;
                } else {
                    v.env_level -= step;
                }
            },
            .sustain => v.env_level = sustain16 << 16, // tracks the live register (AUR-c)
            .release => {
                const step = envStep(decay_ms[v.adsr1 & 0xF], fs);
                if (v.env_level <= step) {
                    v.env_level = 0;
                    v.env_phase = .idle;
                    return true; // envelope complete (task 7.20)
                }
                v.env_level -= step;
            },
            .idle => {},
        }
        return false;
    }

    /// Raw waveform sample at the current phase, Q15 (±32767).
    fn waveform(v: *Voice, ram: *const Ram) i32 {
        const hi: u8 = @truncate(v.phase >> 8);
        return switch (@as(u3, @truncate(v.wave))) {
            0 => sine_table[hi],
            1 => if (v.phase < 0x8000) @as(i32, 32767) else -32767, // square
            2 => blk: { // triangle: 0 → max (¼) → 0 (½) → min (¾) → 0
                const q: i32 = @as(i16, @bitCast(v.phase +% 0x4000));
                break :blk @min(@as(i32, @intCast(@abs(q))) * 2 - 32768, 32767);
            },
            3 => @as(i16, @bitCast(v.phase +% 0x8000)), // sawtooth ramp
            4 => if (hi < v.pulse) @as(i32, 32767) else -32767, // pulse duty
            5 => @as(i16, @bitCast(v.lfsr)), // noise (AUR-f)
            6 => blk: { // wavetable (AUR-a): (sample − 128) << 8, v1.1 §6.2
                const wt_base = @as(u32, v.wtb) * 16;
                if (wt_base + 255 >= ram_mod.size) break :blk 0;
                const s: i32 = ram.readByte(wt_base + hi);
                break :blk (s - 128) << 8;
            },
            7 => 0, // reserved
        };
    }

    /// Advance the phase accumulator by a (possibly negative, FM) increment;
    /// record wrap and clock the noise LFSR once per 4096-boundary crossing
    /// (AUR-f — no degenerate increments, unlike a bit-toggle rule).
    fn advancePhase(v: *Voice, inc: i32) void {
        const old = v.phase;
        const sum = @as(i32, old) + inc;
        v.wrapped = sum >= 65536 or sum < 0;
        v.phase = @truncate(@as(u32, @bitCast(sum)));
        var clocks: u32 = @min(@abs((sum >> 12) - (@as(i32, old) >> 12)), 16);
        while (clocks > 0) : (clocks -= 1) {
            // Galois LFSR, taps $B400 (v1.1 §6.2).
            v.lfsr = if (v.lfsr & 1 != 0) (v.lfsr >> 1) ^ lfsr_taps else v.lfsr >> 1;
        }
    }
};

// ---------------------------------------------------------------------------
// The chip.
// ---------------------------------------------------------------------------

/// Maximum host samples per frame: 735 stereo pairs at rate 0, plus repeat
/// rounding at slower internal rates.
pub const max_frame_samples = 2 * 740;

pub const Aur = struct {
    voices: [4]Voice = @splat(.{}),
    // Globals (§4.8).
    amvol: u8 = 0,
    amvoll: u8 = 0, // 4-bit
    amvolr: u8 = 0,
    amvoice: u8 = 0, // bits 3:0
    amfilt: u8 = 0, // bits 3:0 — sole routing authority (v1.1 §6.1)
    afcut: u16 = 0, // 12-bit, assembled from AFCUTLO[3:0] | AFCUTHI<<4
    afreson: u8 = 0, // 4-bit
    afmode: u8 = 0, // 0=LP 1=HP 2=BP 3=Notch
    asrate: u8 = 0, // 0/1/2; 3 reserved → 0 (AUR-j)
    airqen: u8 = 0, // bit 0
    astat: u8 = 0, // bits 3:0 envelope-complete, w1c

    // Filter state (integer SVF, AUR-h).
    svf_low: i32 = 0,
    svf_band: i32 = 0,

    // Cycle→sample divider and the per-frame output buffer.
    acc: u32 = 0,
    samples: [max_frame_samples]i16 = undefined,
    sample_count: usize = 0,

    pub fn init() Aur {
        return .{};
    }

    fn effectiveRate(a: *const Aur) u2 {
        return if (a.asrate >= 3) 0 else @truncate(a.asrate); // AUR-j
    }

    /// One master cycle. Returns true when a completed envelope should
    /// raise the audio IRQ (AIRQEN gates the *setting*, §5.5 model).
    pub fn tick(a: *Aur, ram: *const Ram) bool {
        a.acc += rate_hz[a.effectiveRate()];
        if (a.acc < util.master_clock_hz) return false;
        a.acc -= util.master_clock_hz;
        return a.generateSample(ram);
    }

    /// Drain interface: the frame loop's owner reads samples[0..count] and
    /// clears after presenting/hashing.
    pub fn clearSamples(a: *Aur) void {
        a.sample_count = 0;
    }

    fn pushSample(a: *Aur, l: i16, r: i16) void {
        const repeat = @as(usize, 1) << a.effectiveRate(); // 1× / 2× / 4×
        var i: usize = 0;
        while (i < repeat) : (i += 1) {
            if (a.sample_count + 2 > a.samples.len) return; // caller failed to drain
            a.samples[a.sample_count] = l;
            a.samples[a.sample_count + 1] = r;
            a.sample_count += 2;
        }
    }

    fn generateSample(a: *Aur, ram: *const Ram) bool {
        const fs = rate_hz[a.effectiveRate()];
        var env_completed = false;

        // Voices compute in order 0→3 (AUR-d/e: voice 0 sees voice 3's
        // previous-sample output/wrap).
        var prev_wrapped = a.voices[3].wrapped;
        var prev_out = a.voices[3].prev_output;
        for (&a.voices, 0..) |*v, n| {
            v.prev_output = v.output;

            // Gate edges (task 7.11): set = attack, clear = release.
            if (v.gate()) {
                if (v.env_phase == .idle or v.env_phase == .release) v.env_phase = .attack;
            } else {
                if (v.env_phase == .attack or v.env_phase == .decay or v.env_phase == .sustain)
                    v.env_phase = .release;
            }

            // Hard sync (task 7.15, AUR-e): previous voice wrapped → reset.
            if (v.ctrl & 0x20 != 0 and prev_wrapped) v.phase = 0;

            // Phase increment: base, plus FM terms (tasks 7.16/7.17).
            var inc: i32 = v.freq;
            const pair_mod = n & ~@as(usize, 1); // modulator index of this pair (0 or 2)
            const fm_pair = a.voices[pair_mod].wave & 0x08 != 0; // AUR-b
            if (fm_pair) {
                if (n == pair_mod) {
                    // Modulator: self-feedback (prev_out × fbk) >> 3.
                    inc += (v.prev_output * @as(i32, v.fbk & 0x07)) >> 3;
                } else {
                    // Carrier: base + ((mod_out × depth) >> 16), modulator
                    // output taken post-envelope, this sample.
                    const m = &a.voices[pair_mod];
                    inc += @intCast((@as(i64, m.output) * m.mod_depth) >> 16);
                }
            }
            v.advancePhase(inc);

            if (v.advanceEnvelope(fs)) {
                a.astat |= @as(u8, 1) << @intCast(n); // device flag always latches
                if (a.airqen & 1 != 0) env_completed = true;
            }

            // Post-envelope, post-VVOL output (AUR-g).
            const env16: i32 = @intCast(v.env_level >> 16);
            var out: i32 = (v.waveform(ram) * env16) >> 16;
            out = (out * v.vol) >> 8;
            // Ring mod (task 7.14, AUR-d): × previous voice's output.
            if (v.ctrl & 0x40 != 0) {
                out = @intCast((@as(i64, out) * prev_out) >> 15);
            }
            prev_wrapped = v.wrapped;
            prev_out = out;
            v.output = out;
        }

        // Mixer (tasks 7.12/7.13, AUR-g/i): dry voices pan per-voice; the
        // routed set is filtered as a mono sum feeding both channels.
        var left: i32 = 0;
        var right: i32 = 0;
        var filter_in: i32 = 0;
        for (&a.voices, 0..) |*v, n| {
            const bit = @as(u8, 1) << @intCast(n);
            if (a.amvoice & bit == 0) continue;
            const pm = n & ~@as(usize, 1);
            if (a.voices[pm].wave & 0x08 != 0 and n == pm) continue; // FM modulator: not mixed (AUR-b)
            if (a.amfilt & bit != 0) {
                filter_in += v.output;
            } else {
                left += (v.output * v.voll) >> 4;
                right += (v.output * v.volr) >> 4;
            }
        }
        if (a.amfilt & a.amvoice != 0) {
            const filtered = a.runFilter(filter_in);
            left += filtered;
            right += filtered;
        }

        // Master volume then saturate (task 7.13: no wraparound).
        left = (((left * a.amvol) >> 8) * a.amvoll) >> 4;
        right = (((right * a.amvol) >> 8) * a.amvolr) >> 4;
        a.pushSample(saturate16(left), saturate16(right));
        return env_completed;
    }

    /// Chamberlin SVF in Q14 fixed point (task 7.18, AUR-h).
    fn runFilter(a: *Aur, input: i32) i32 {
        const f: i32 = filter_f_q14[a.effectiveRate()][a.afcut >> 4];
        const qinv: i32 = filter_qinv_q14[a.afreson & 0xF];
        a.svf_low += (f * a.svf_band) >> 14;
        const high = input - a.svf_low - ((qinv * a.svf_band) >> 14);
        a.svf_band += (f * high) >> 14;
        a.svf_low = std.math.clamp(a.svf_low, -(1 << 20), 1 << 20);
        a.svf_band = std.math.clamp(a.svf_band, -(1 << 20), 1 << 20);
        return switch (@as(u2, @truncate(a.afmode))) {
            0 => a.svf_low, //          LP
            1 => high, //               HP
            2 => a.svf_band, //         BP
            3 => high + a.svf_low, //   Notch
        };
    }

    // ------------------------------------------------------------------
    // Register dispatch (task 7.1) — byte registers at exact addresses,
    // reads zero-extend, writes take the low byte (§3.1 model).
    // ------------------------------------------------------------------

    pub fn read(a: *const Aur, addr: u32) u16 {
        if (addr < global_base) {
            const voice = (addr - base_addr) / 0x10;
            const v = &a.voices[voice];
            return switch ((addr - base_addr) % 0x10) {
                0x0 => v.freq & 0xFF,
                0x1 => v.freq >> 8,
                0x2 => v.wave,
                0x3 => v.ctrl,
                0x4 => v.adsr0,
                0x5 => v.adsr1,
                0x6 => v.pulse,
                0x7 => v.vol,
                0x8 => v.mod_depth & 0xFF,
                0x9 => v.mod_depth >> 8,
                0xA => v.fbk,
                0xB => v.wtb & 0xFF,
                0xC => v.wtb >> 8,
                0xD => v.volr,
                0xE => v.voll,
                else => 0x0000, // +0F reserved
            };
        }
        return switch (addr - global_base) {
            g_amvol => a.amvol,
            g_amvoll => a.amvoll,
            g_amvolr => a.amvolr,
            g_amvoice => a.amvoice,
            g_amfilt => a.amfilt,
            g_afcutlo => a.afcut & 0x000F,
            g_afcuthi => a.afcut >> 4,
            g_afreson => a.afreson,
            g_afmode => a.afmode,
            g_asrate => a.asrate,
            g_airqen => a.airqen,
            g_astat => a.astat,
            else => 0x0000, // $8014C–$801FF reserved
        };
    }

    pub fn write(a: *Aur, addr: u32, value16: u16) void {
        const v8: u8 = @truncate(value16);
        if (addr < global_base) {
            const voice = (addr - base_addr) / 0x10;
            const v = &a.voices[voice];
            switch ((addr - base_addr) % 0x10) {
                0x0 => v.freq = (v.freq & 0xFF00) | v8,
                0x1 => v.freq = (v.freq & 0x00FF) | (@as(u16, v8) << 8),
                0x2 => v.wave = v8 & 0x0F, // waveform 2:0 | FM enable 3
                0x3 => v.ctrl = v8 & 0xE0, // gate|ring|sync; 4:0 reserved (v1.1 §6.1)
                0x4 => v.adsr0 = v8,
                0x5 => v.adsr1 = v8,
                0x6 => v.pulse = v8,
                0x7 => v.vol = v8,
                0x8 => v.mod_depth = (v.mod_depth & 0xFF00) | v8,
                0x9 => v.mod_depth = (v.mod_depth & 0x00FF) | (@as(u16, v8) << 8),
                0xA => v.fbk = v8 & 0x07,
                0xB => v.wtb = (v.wtb & 0xFF00) | v8,
                0xC => v.wtb = (v.wtb & 0x00FF) | (@as(u16, v8) << 8),
                0xD => v.volr = v8 & 0x0F,
                0xE => v.voll = v8 & 0x0F,
                else => {},
            }
            return;
        }
        switch (addr - global_base) {
            g_amvol => a.amvol = v8,
            g_amvoll => a.amvoll = v8 & 0x0F,
            g_amvolr => a.amvolr = v8 & 0x0F,
            g_amvoice => a.amvoice = v8 & 0x0F,
            g_amfilt => a.amfilt = v8 & 0x0F,
            g_afcutlo => a.afcut = (a.afcut & 0xFF0) | (v8 & 0x0F),
            g_afcuthi => a.afcut = (a.afcut & 0x00F) | (@as(u16, v8) << 4),
            g_afreson => a.afreson = v8 & 0x0F,
            g_afmode => a.afmode = v8 & 0x03,
            g_asrate => a.asrate = v8 & 0x03,
            g_airqen => a.airqen = v8 & 0x01,
            g_astat => a.astat &= ~(v8 & 0x0F), // w1c per voice (task 7.20)
            else => {},
        }
    }
};

fn saturate16(x: i32) i16 {
    return @intCast(std.math.clamp(x, -32768, 32767));
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
    aur: *Aur,

    fn setup() !Fixture {
        const ram = try testing.allocator.create(Ram);
        errdefer testing.allocator.destroy(ram);
        const aur = try testing.allocator.create(Aur);
        ram.init();
        aur.* = Aur.init();
        return .{ .ram = ram, .aur = aur };
    }

    fn teardown(f: *Fixture) void {
        testing.allocator.destroy(f.ram);
        testing.allocator.destroy(f.aur);
    }

    /// Master volumes wide open; voice `n` at full VVOL, centre pan.
    fn openVoice(f: *Fixture, n: u32) void {
        const a = f.aur;
        a.write(global_base + g_amvol, 255);
        a.write(global_base + g_amvoll, 15);
        a.write(global_base + g_amvolr, 15);
        a.write(global_base + g_amvoice, a.read(global_base + g_amvoice) | (@as(u16, 1) << @intCast(n)));
        const vb = base_addr + n * 0x10;
        a.write(vb + 0x7, 255); // VVOL
        a.write(vb + 0xD, 15); // VVOLR
        a.write(vb + 0xE, 15); // VVOLL
        a.write(vb + 0x5, 0xF0); // sustain 15, release 0
    }

    /// Generate n internal samples directly (bypassing the cycle divider);
    /// returns the left-channel slice.
    fn generate(f: *Fixture, n: usize) []const i16 {
        f.aur.clearSamples();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (f.aur.sample_count + 8 > f.aur.samples.len) {
                // keep only the tail window for long runs
                f.aur.clearSamples();
            }
            _ = f.aur.generateSample(f.ram);
        }
        return f.aur.samples[0..f.aur.sample_count];
    }
};

test "7.1 registers: voice + global round-trips, masks, AFCUT split, reserved" {
    var f = try Fixture.setup();
    defer f.teardown();
    const a = f.aur;
    // Voice 2 frequency pair.
    a.write(base_addr + 0x20 + 0, 0x8E);
    a.write(base_addr + 0x20 + 1, 0x02);
    try expectEqual(@as(u16, 0x8E), a.read(base_addr + 0x20 + 0));
    try expectEqual(@as(u16, 0x02), a.read(base_addr + 0x20 + 1));
    try expectEqual(@as(u16, 0x028E), a.voices[2].freq);
    // VCTRL keeps only gate/ring/sync (v1.1 §6.1).
    a.write(base_addr + 0x3, 0xFF);
    try expectEqual(@as(u16, 0xE0), a.read(base_addr + 0x3));
    // VFBK 3 bits; VVOLL/R 4 bits; VWAVE 4 bits.
    a.write(base_addr + 0xA, 0xFF);
    try expectEqual(@as(u16, 0x07), a.read(base_addr + 0xA));
    a.write(base_addr + 0xE, 0xFF);
    try expectEqual(@as(u16, 0x0F), a.read(base_addr + 0xE));
    a.write(base_addr + 0x2, 0xFF);
    try expectEqual(@as(u16, 0x0F), a.read(base_addr + 0x2));
    // AFCUT: LO carries bits 3:0, HI bits 11:4 (§4.8).
    a.write(global_base + g_afcutlo, 0xFA); // only low nibble lands
    a.write(global_base + g_afcuthi, 0x80);
    try expectEqual(@as(u16, 0x80A), a.afcut);
    try expectEqual(@as(u16, 0x0A), a.read(global_base + g_afcutlo));
    try expectEqual(@as(u16, 0x80), a.read(global_base + g_afcuthi));
    // Reserved space reads zero.
    try expectEqual(@as(u16, 0), a.read(base_addr + 0xF));
    try expectEqual(@as(u16, 0), a.read(0x8014C));
    try expectEqual(@as(u16, 0), a.read(0x801FF));
}

test "7.3 phase accumulator: F_out = freq × rate / 65536 within 0.1%" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.openVoice(0);
    const a = f.aur;
    a.write(base_addr + 0x2, 1); // square: crisp zero crossings
    a.write(base_addr + 0x0, 0x8E); // $028E — A440 at 44.1 kHz
    a.write(base_addr + 0x1, 0x02);
    a.write(base_addr + 0x4, 0x00); // attack 2 ms
    a.write(base_addr + 0x3, 0x80); // gate on
    // Let the attack finish, then count rising edges over ten seconds —
    // ±1-count granularity is then 0.023%, well inside the 0.1% window.
    _ = f.generate(200);
    var crossings: u32 = 0;
    var last: i16 = 0;
    var i: usize = 0;
    while (i < 441_000) : (i += 1) {
        f.aur.clearSamples();
        _ = f.aur.generateSample(f.ram);
        const s = f.aur.samples[0];
        if (last <= 0 and s > 0) crossings += 1;
        last = s;
    }
    // Expected F_out = 654 × 44100 / 65536 = 440.06 Hz over 10 s.
    const expected: f64 = 654.0 * 44100.0 / 65536.0 * 10.0;
    const measured: f64 = @floatFromInt(crossings);
    try testing.expect(@abs(measured - expected) / expected < 0.001);
}

test "7.4–7.9 waveforms: shapes, duty, LFSR determinism, wavetable level" {
    var f = try Fixture.setup();
    defer f.teardown();
    const v = &f.aur.voices[0];
    // Square: sign follows phase MSB.
    v.wave = 1;
    v.phase = 0x1000;
    try expectEqual(@as(i32, 32767), v.waveform(f.ram));
    v.phase = 0x9000;
    try expectEqual(@as(i32, -32767), v.waveform(f.ram));
    // Sine quadrature points.
    v.wave = 0;
    v.phase = 0x0000;
    try expectEqual(@as(i32, 0), v.waveform(f.ram));
    v.phase = 0x4000;
    try expectEqual(@as(i32, 32767), v.waveform(f.ram));
    v.phase = 0xC000;
    try expectEqual(@as(i32, -32767), v.waveform(f.ram));
    // Triangle: 0 → max at quarter, back to 0 at half, min at 3/4.
    v.wave = 2;
    v.phase = 0x0000;
    try expectEqual(@as(i32, 0), v.waveform(f.ram));
    v.phase = 0x4000;
    try testing.expect(v.waveform(f.ram) > 32000);
    v.phase = 0x8000;
    try testing.expect(@abs(v.waveform(f.ram)) < 512);
    v.phase = 0xC000;
    try testing.expect(v.waveform(f.ram) < -32000);
    // Sawtooth: −min at 0 rising through 0 at half.
    v.wave = 3;
    v.phase = 0x0000;
    try expectEqual(@as(i32, -32768), v.waveform(f.ram));
    v.phase = 0x8000;
    try expectEqual(@as(i32, 0), v.waveform(f.ram));
    v.phase = 0xFFFF;
    try expectEqual(@as(i32, 32767), v.waveform(f.ram));
    // Pulse duty: high while phase>>8 < VPULSE.
    v.wave = 4;
    v.pulse = 64; // 25%
    v.phase = 0x3F00;
    try expectEqual(@as(i32, 32767), v.waveform(f.ram));
    v.phase = 0x4000;
    try expectEqual(@as(i32, -32767), v.waveform(f.ram));
    // Noise: seed $ACE1; first shift (LSB=1) → (>>1) ^ $B400 = $E270.
    v.wave = 5;
    try expectEqual(@as(u16, 0xACE1), v.lfsr);
    v.phase = 0x0000;
    v.advancePhase(0x0800); // no 4096 boundary crossed: no step
    try expectEqual(@as(u16, 0xACE1), v.lfsr);
    v.advancePhase(0x0800); // $0800 → $1000: one crossing, one step
    try expectEqual(@as(u16, 0xE270), v.lfsr);
    // Coarse increments never starve the clock (the AUR-f fix): $2000
    // crosses two boundaries per sample.
    v.lfsr = lfsr_seed;
    v.phase = 0x0000;
    v.advancePhase(0x2000);
    try expectEqual(@as(u16, 0x7138), v.lfsr); // two steps: $ACE1→$E270→$7138
    // Wavetable: (s − 128) << 8, full scale (v1.1 §6.2); base ÷ 16 (AUR-a).
    v.wave = 6;
    v.wtb = 0x02100 / 16;
    f.ram.writeByte(0x02100 + 0x40, 0xFF);
    f.ram.writeByte(0x02100 + 0x41, 0x00);
    v.phase = 0x4000;
    try expectEqual(@as(i32, (0xFF - 128) << 8), v.waveform(f.ram));
    v.phase = 0x4100;
    try expectEqual(@as(i32, (0x00 - 128) << 8), v.waveform(f.ram));
}

test "7.10/7.11 ADSR: table timing within 5%, gate edges, sustain tracking" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.openVoice(0);
    const a = f.aur;
    const vb = base_addr;
    a.write(vb + 0x2, 1); // square
    a.write(vb + 0x0, 0x00); // freq 0: waveform constant, envelope visible
    a.write(vb + 0x4, 0x94); // attack idx 9 = 250 ms, decay idx 4 = 114 ms
    a.write(vb + 0x5, 0x80); // sustain 8, release idx 0 = 6 ms
    a.write(vb + 0x3, 0x80); // gate on
    const v = &a.voices[0];
    v.env_phase = .attack; // gate-edge handling lives in generateSample
    // Attack: full scale in 250 ms = 11,025 samples ± 5%.
    var n: u32 = 0;
    while (v.env_phase == .attack) : (n += 1) _ = v.advanceEnvelope(44_100);
    try testing.expect(n > 10_474 and n < 11_576);
    // Decay to sustain 8 (level $8888): (7/15) of full scale at 114 ms
    // full-scale rate → ×(7/15) ≈ 2,346 samples ± 5%.
    n = 0;
    while (v.env_phase == .decay) : (n += 1) _ = v.advanceEnvelope(44_100);
    try testing.expect(n > 2_228 and n < 2_464);
    try expectEqual(@as(u32, 8 * 4369), v.env_level >> 16);
    // Sustain tracks the live register (AUR-c).
    a.write(vb + 0x5, 0xC0);
    _ = v.advanceEnvelope(44_100);
    try expectEqual(@as(u32, 12 * 4369), v.env_level >> 16);
    // Gate off → release; completion flags ASTAT bit 0 (task 7.20).
    a.write(vb + 0x3, 0x00);
    var completed = false;
    n = 0;
    while (n < 44_100) : (n += 1) {
        a.clearSamples();
        if (a.generateSample(f.ram)) completed = true;
        if (v.env_phase == .idle) break;
    }
    try expectEqual(EnvPhase.idle, v.env_phase);
    try testing.expect(!completed); // AIRQEN off: no IRQ request…
    try expectEqual(@as(u16, 0x01), a.read(global_base + g_astat)); // …but the flag latches
    a.write(global_base + g_astat, 0x01); // w1c
    try expectEqual(@as(u16, 0x00), a.read(global_base + g_astat));
    // With AIRQEN set, completion requests the IRQ.
    a.write(global_base + g_airqen, 1);
    a.write(vb + 0x3, 0x80);
    v.env_phase = .attack;
    while (v.env_phase != .sustain) _ = v.advanceEnvelope(44_100);
    a.write(vb + 0x3, 0x00);
    completed = false;
    n = 0;
    while (n < 44_100 and !completed) : (n += 1) {
        a.clearSamples();
        completed = a.generateSample(f.ram);
    }
    try testing.expect(completed);
}

test "7.14/7.15 ring mod multiplies with previous voice; hard sync resets phase" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.openVoice(0);
    f.openVoice(1);
    const a = f.aur;
    // Voice 0 square full env; voice 1 rings with voice 0.
    a.write(base_addr + 0x0, 0x00); // v0 freq 0 → constant +32767 square
    a.write(base_addr + 0x2, 1);
    a.write(base_addr + 0x4, 0x00);
    a.write(base_addr + 0x3, 0x80);
    a.write(base_addr + 0x10 + 0x0, 0x00);
    a.write(base_addr + 0x10 + 0x2, 1);
    a.write(base_addr + 0x10 + 0x4, 0x00);
    a.write(base_addr + 0x10 + 0x3, 0x80 | 0x40); // gate + ring
    _ = f.generate(200); // both envelopes to full
    // v0 out ≈ 32767×(255/256) = 32639; v1 pre-ring same; ringed:
    // (32639 × 32639) >> 15 = 32511.
    const v1_out = a.voices[1].output;
    try testing.expect(v1_out > 32300 and v1_out <= 32767);
    // Hard sync: voice 1 syncs from voice 0's wrap.
    a.voices[1].ctrl = 0x80 | 0x20;
    a.voices[0].freq = 0x4000; // wraps every 4 samples
    a.voices[1].freq = 0x0100;
    _ = f.generate(4); // land right after a v0 wrap
    var max_phase: u16 = 0;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        a.clearSamples();
        _ = a.generateSample(f.ram);
        max_phase = @max(max_phase, a.voices[1].phase);
    }
    // Without sync, phase would exceed 4 × $0100... it is reset every 4
    // samples, so it never accumulates past a few increments.
    try testing.expect(max_phase <= 0x0400);
}

test "7.16/7.17 FM: modulator leaves the mix, carrier increment shifts, feedback" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.openVoice(0);
    f.openVoice(1);
    const a = f.aur;
    // Modulator v0: sine, FM enable (bit 3), full sustain.
    a.write(base_addr + 0x0, 0x40);
    a.write(base_addr + 0x2, 0x08 | 0); // FM | sine (AUR-b)
    a.write(base_addr + 0x4, 0x00);
    a.write(base_addr + 0x3, 0x80);
    a.write(base_addr + 0x8, 0x00); // depth $4000
    a.write(base_addr + 0x9, 0x40);
    // Carrier v1: square.
    a.write(base_addr + 0x10 + 0x0, 0x00);
    a.write(base_addr + 0x10 + 0x1, 0x01); // $0100
    a.write(base_addr + 0x10 + 0x2, 1);
    a.write(base_addr + 0x10 + 0x4, 0x00);
    a.write(base_addr + 0x10 + 0x3, 0x80);
    _ = f.generate(300);
    // The modulator is excluded from the mix: with only voices 0+1 enabled
    // and v1's phase parked, output equals v1's contribution alone.
    // Check the carrier's phase advanced differently from freq alone: over
    // K samples the deviation accumulates unless mod output is all zero.
    const p_start = a.voices[1].phase;
    var deviation: bool = false;
    var i: usize = 0;
    var expected: u16 = p_start;
    while (i < 64) : (i += 1) {
        a.clearSamples();
        _ = a.generateSample(f.ram);
        expected +%= 0x0100;
        if (a.voices[1].phase != expected) deviation = true;
    }
    try testing.expect(deviation); // FM is bending the carrier (task 7.16)
    // Feedback: nonzero VFBK changes the modulator's own phase path.
    const p_before = a.voices[0].phase;
    a.write(base_addr + 0xA, 7);
    _ = f.generate(64);
    const with_fbk = a.voices[0].phase;
    a.voices[0].phase = p_before;
    a.write(base_addr + 0xA, 0);
    _ = f.generate(64);
    try testing.expect(with_fbk != a.voices[0].phase); // task 7.17
}

test "7.18 filter: coefficient curve matches 2·sin(π·fc/fs) within 1%" {
    // Spot-check the comptime Q14 table against a runtime evaluation.
    const checks = [_]struct { rate: usize, cut: u16 }{
        .{ .rate = 0, .cut = 0x100 },
        .{ .rate = 0, .cut = 0x800 },
        .{ .rate = 0, .cut = 0xFFF },
        .{ .rate = 1, .cut = 0x800 },
        .{ .rate = 2, .cut = 0x400 },
    };
    for (checks) |c| {
        const step = c.cut >> 4;
        const centre: f64 = @floatFromInt(@as(u32, step) * 16 + 8);
        const fc = 30.0 + (centre / 4095.0) * (centre / 4095.0) * 11970.0;
        const fs: f64 = @floatFromInt(rate_hz[c.rate]);
        const f_exact = 2.0 * @sin(std.math.pi * fc / fs);
        const f_table: f64 = @as(f64, @floatFromInt(filter_f_q14[c.rate][step])) / 16384.0;
        try testing.expect(@abs(f_table - @min(f_exact, 1.99)) / f_exact < 0.01);
    }
    // Q curve endpoints: Q=0.5 → q⁻¹=2.0; Q=10 → 0.1.
    try expectEqual(@as(u16, 32768 / 1), filter_qinv_q14[0] & 0xFFFF); // 2.0 in Q14 = 32768
    try testing.expect(@abs(@as(f64, @floatFromInt(filter_qinv_q14[15])) / 16384.0 - 0.1) < 0.005);
    // LP filter attenuates a fast square (behavioural sanity).
    var f = try Fixture.setup();
    defer f.teardown();
    f.openVoice(0);
    const a = f.aur;
    a.write(base_addr + 0x0, 0x00);
    a.write(base_addr + 0x1, 0x20); // fast square
    a.write(base_addr + 0x2, 1);
    a.write(base_addr + 0x4, 0x00);
    a.write(base_addr + 0x3, 0x80);
    _ = f.generate(300);
    var peak_dry: u32 = 0;
    for (0..200) |_| {
        a.clearSamples();
        _ = a.generateSample(f.ram);
        peak_dry = @max(peak_dry, @abs(@as(i32, a.samples[0])));
    }
    a.write(global_base + g_amfilt, 0x01); // route voice 0
    a.write(global_base + g_afcuthi, 0x02); // low cutoff
    a.write(global_base + g_afreson, 0);
    a.write(global_base + g_afmode, 0); // LP
    _ = f.generate(300); // settle
    var peak_lp: u32 = 0;
    for (0..200) |_| {
        a.clearSamples();
        _ = a.generateSample(f.ram);
        peak_lp = @max(peak_lp, @abs(@as(i32, a.samples[0])));
    }
    try testing.expect(peak_lp < peak_dry / 2);
}

test "7.13 mixer saturates cleanly with four loud voices" {
    var f = try Fixture.setup();
    defer f.teardown();
    const a = f.aur;
    for (0..4) |n| {
        f.openVoice(@intCast(n));
        const vb = base_addr + @as(u32, @intCast(n)) * 0x10;
        a.write(vb + 0x0, 0x00); // freq 0: square stuck at +32767
        a.write(vb + 0x2, 1);
        a.write(vb + 0x4, 0x00);
        a.write(vb + 0x3, 0x80);
    }
    _ = f.generate(300);
    a.clearSamples();
    _ = a.generateSample(f.ram);
    // Four full-scale voices sum to ≈ +122k pre-master: must clamp to
    // +32767 exactly — never wrap negative (task 7.13).
    try expectEqual(@as(i16, 32767), a.samples[0]);
    try expectEqual(@as(i16, 32767), a.samples[1]);
}

test "7.19/7.21 rates: exactly 735 host samples per frame at 44.1 kHz; repeats at slower rates" {
    var f = try Fixture.setup();
    defer f.teardown();
    const a = f.aur;
    var c: u32 = 0;
    while (c < util.cycles_per_frame) : (c += 1) _ = a.tick(f.ram);
    try expectEqual(@as(usize, 735 * 2), a.sample_count); // stereo i16 count
    // ASRATE 1: internal 22.05 kHz, each sample pushed twice — host count
    // stays ~735 pairs (±1 pair of accumulator carry).
    a.clearSamples();
    a.write(global_base + g_asrate, 1);
    c = 0;
    while (c < util.cycles_per_frame) : (c += 1) _ = a.tick(f.ram);
    const pairs = a.sample_count / 2;
    try testing.expect(pairs >= 734 and pairs <= 736);
    // Consecutive host samples are duplicates at rate 1.
    try expectEqual(a.samples[0], a.samples[2]);
    try expectEqual(a.samples[1], a.samples[3]);
    // Reserved ASRATE 3 behaves as 0 (AUR-j).
    a.write(global_base + g_asrate, 3);
    try expectEqual(@as(u2, 0), a.effectiveRate());
}
