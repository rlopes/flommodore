# Flommodore — Phase 4: AUR-1 Sound Chip Specification

## Overview

The AUR-1 is the Flommodore's audio processor. It is a real-time synthesis chip inspired by
the C64 SID, Yamaha YM2149, and OPL3 — taking the best ideas from each. It operates
autonomously, generating audio output continuously based on the state of its registers, which
are memory-mapped at `$80100 – $801FF`.

---

## 4.1 — Design Philosophy

The AUR-1 is a **register-driven real-time synthesiser**. The CPU writes to its registers and
the chip continuously generates audio from those values. There is no built-in sample playback
engine — the AUR-1 is a pure synthesiser. However, the CPU can implement PCM sample playback
in software by rapidly updating registers via timer interrupts (see §4.12).

Three layers of inspiration:

- **C64 SID** — per-voice ADSR envelopes, filter, ring modulation, hard sync
- **Yamaha YM2149** — clean square wave voices, noise channel, simple mixer
- **Yamaha OPL3** — FM operator pairs for richer, more complex timbres

---

## 4.2 — Voice Architecture

The AUR-1 has **4 voices**. Each voice is an independent synthesis unit with its own waveform,
frequency, envelope, and modulation settings.

Each voice can operate in one of two modes:

| Mode | Description |
|---|---|
| **Standard mode** | Voice operates independently with its own waveform and ADSR |
| **FM mode** | Voice pairs with the next voice — one acts as carrier, one as modulator (OPL-style) |

In FM mode, voices pair as **Voice 0 + Voice 1** and **Voice 2 + Voice 3**. This gives either
4 independent voices, 2 FM operator pairs, or one pair and two independent voices.

---

## 4.3 — Waveforms

Each voice (in standard mode) can select one waveform at a time:

| ID | Waveform | Character |
|---|---|---|
| 0 | **Sine** | Pure, smooth tone |
| 1 | **Square** | Hollow, buzzy — classic chiptune |
| 2 | **Triangle** | Soft, flute-like |
| 3 | **Sawtooth** | Bright, brassy, rich harmonics |
| 4 | **Pulse** | Like square but with variable duty cycle |
| 5 | **Noise** | White noise — percussion, wind, effects (16-bit Galois LFSR, taps `$B400`, seeded `$ACE1` at reset) |
| 6 | **Wavetable** | Reads a 256-byte waveform from RAM (custom shape) |
| 7 | **Reserved** | — |

### Pulse waveform
Has a separate **duty cycle register** per voice (0–255, representing 0%–100% pulse width).
Varying the duty cycle in real time produces the classic PWM sweep sound of the SID.

### Wavetable waveform
Reads a 256-byte table from general RAM pointed to by the per-voice `VWTBLO/HI` register pair,
cycling through it at the voice's set frequency. Samples are **unsigned 8-bit** with `$80`
as the zero crossing; output = `(sample − 128) << 8` (full scale). This allows completely
custom waveforms — bells, organs, speech-like timbres, anything expressible as a single
cycle shape.

---

## 4.4 — ADSR Envelope

Every voice has a full **ADSR envelope generator**:

```
Amplitude
    │         ╱╲
    │        ╱  ╲
    │       ╱    ╲__________
    │      ╱                 ╲
    │     ╱                   ╲
    └────────────────────────────── Time
          A    D    S (held)   R
```

| Stage | Name | Description |
|---|---|---|
| **A** | Attack | Time to rise from 0 to peak amplitude |
| **D** | Decay | Time to fall from peak to sustain level |
| **S** | Sustain | Amplitude held while note is on (0–15 level) |
| **R** | Release | Time to fall from sustain to 0 after note off |

Each of A, D, R is a **4-bit value** (0–15) representing a time constant from ~2ms to ~8
seconds on a non-linear curve (matching the SID's feel). Sustain is a **4-bit amplitude
level** (0–15).

A, D, S, R for each voice are packed into **2 bytes**:

```
Byte 0 (VADSR0)   [A: 4 bits][D: 4 bits]
Byte 1 (VADSR1)   [S: 4 bits][R: 4 bits]
```

**Gate bit** (VCTRL bit 7): setting this bit triggers the ADSR Attack phase (note on).
Clearing it triggers the Release phase (note off). This is identical to how the SID gate works.

### ADSR rate tables (4-bit value → time)

| Value | Attack | Decay / Release | Value | Attack | Decay / Release |
|---|---|---|---|---|---|
| 0 | 2 ms | 6 ms | 8 | 100 ms | 300 ms |
| 1 | 8 ms | 24 ms | 9 | 250 ms | 750 ms |
| 2 | 16 ms | 48 ms | 10 | 500 ms | 1.5 s |
| 3 | 24 ms | 72 ms | 11 | 800 ms | 2.4 s |
| 4 | 38 ms | 114 ms | 12 | 1 s | 3 s |
| 5 | 56 ms | 168 ms | 13 | 3 s | 9 s |
| 6 | 68 ms | 204 ms | 14 | 5 s | 15 s |
| 7 | 80 ms | 240 ms | 15 | 8 s | 24 s |

---

## 4.5 — Per-Voice Filter (SID-inspired)

The AUR-1 has a **shared analogue-style filter** that any combination of voices can be routed
through. The filter mode is selected via the global `AFMODE` register:

| Mode | Type | Character |
|---|---|---|
| 0 | **Low-pass** | Removes high frequencies — warm, muffled |
| 1 | **High-pass** | Removes low frequencies — thin, bright |
| 2 | **Band-pass** | Passes a band around the cutoff — nasal, vocal |
| 3 | **Notch** | Removes a band around the cutoff — phaser-like |

**Filter parameters:**

| Parameter | Width | Description |
|---|---|---|
| Cutoff frequency | 12-bit (0–4095) | Controls the filter centre/cutoff frequency |
| Resonance | 4-bit (0–15) | Controls sharpness and peak at the cutoff point |

Voices are routed into the filter via the global **`AMFILT`** register (bits 0–3 = voices
0–3) — the sole routing authority (the per-voice VCTRL filter bit of spec v1.0 is deleted).
The filter is a Chamberlin state-variable filter running at the output sample rate:
`f = 2·sin(π·fc/fs)`, with `cutoff_hz = 30 + (AFCUT/4095)² × 11970` (30 Hz – 12 kHz) and
`Q = 0.5 + (AFRESON/15) × 9.5`.

---

## 4.6 — Ring Modulation & Hard Sync (SID-inspired)

Each voice can optionally enable either or both of:

**Ring modulation** — multiplies this voice's output with the output of the previous voice:
- Voice 1 rings Voice 0
- Voice 2 rings Voice 1
- Voice 3 rings Voice 2
- Voice 0 rings Voice 3 (wraparound)

Produces metallic, bell-like, inharmonic timbres. Enabled by a single bit in `VCTRL`.

**Hard sync** — resets this voice's oscillator phase whenever the previous voice's oscillator
completes a full cycle (voice 0 syncs from voice 3 — wraparound). Produces the
characteristic hard sync growl classic in lead synth sounds. Enabled by a single bit in `VCTRL`.

---

## 4.7 — FM Synthesis Mode (OPL-inspired)

When a voice pair is set to FM mode, the **modulator** voice's output modulates the frequency
of the **carrier** voice rather than being sent to the mixer directly:

```
Modulator (Voice N)   →  [frequency output]
                                ↓
                      added to Carrier frequency
                                ↓
Carrier (Voice N+1)   →  [audio output]  →  Mixer
```

**FM parameters (per modulator voice):**

| Parameter | Width | Description |
|---|---|---|
| Modulation depth | 16-bit | How strongly the modulator affects carrier frequency |
| Feedback | 3-bit (0–7) | Modulator self-feedback depth for richer timbres |

**FM math (per output sample):** carrier effective phase increment =
`base_inc + ((modulator_output × depth) >> 16)`; the modulator's own phase input additionally
receives `(previous_modulator_output × feedback) >> 3`. Modulator output is taken post-envelope.

FM mode unlocks a wide range of timbres from just two oscillators: piano, bells, brass, organs,
bass, and more — exactly as the OPL3 achieved on PC sound cards.

Voice pairing:
- `VWAVE` bit 3 = 1 on Voice 0 → Voice 0 is modulator, Voice 1 is carrier
- `VWAVE` bit 3 = 1 on Voice 2 → Voice 2 is modulator, Voice 3 is carrier

---

## 4.8 — Mixer & Master Output

All active voices (after envelope, filter, and modulation processing) are summed in the
mixer — into a signed 32-bit accumulator; after master volume the result **saturates** to
16-bit (no wraparound distortion).

| Register | Description |
|---|---|
| `AMVOL` | Master volume, 8-bit (0–255) |
| `AMVOLL` | Master left channel volume, 4-bit |
| `AMVOLR` | Master right channel volume, 4-bit |
| `AMVOICE` | Per-voice enable bits (bit 0–3 = voice 0–3) |
| `AMFILT` | Per-voice filter route bits (bit 0–3 = voice 0–3) |

The AUR-1 outputs **stereo 16-bit audio at up to 44.1KHz**. Each voice also has individual
left/right volume registers (`VVOLL`, `VVOLR`) for panning.

---

## 4.9 — Voice Register Map (per voice)

Each voice occupies **16 bytes**. With 4 voices that is 64 bytes total, well within the 256-byte
block at `$80100 – $801FF`.

**Voice N base address:** `$80100 + (N × $10)`

| Offset | Register | Description |
|---|---|---|
| `+00` | `VFREQLO` | Frequency low byte |
| `+01` | `VFREQHI` | Frequency high byte — the 16-bit word is a **phase increment**: `F_out = freq × sample_rate / 65536` |
| `+02` | `VWAVE` | Waveform select (bits 2:0) \| FM mode enable (bit 3) |
| `+03` | `VCTRL` | Gate(bit 7) \| Ring mod(bit 6) \| Sync(bit 5) \| bits 4:0 reserved — filter routing lives in `AMFILT`, panning in `VVOLL`/`VVOLR` |
| `+04` | `VADSR0` | Attack[7:4] \| Decay[3:0] |
| `+05` | `VADSR1` | Sustain[7:4] \| Release[3:0] |
| `+06` | `VPULSE` | Pulse width duty cycle (0–255, waveform 4 only) |
| `+07` | `VVOL` | Voice volume (8-bit, pre-mixer) |
| `+08` | `VMODLO` | FM modulation depth low byte |
| `+09` | `VMODHI` | FM modulation depth high byte |
| `+0A` | `VFBK` | FM feedback depth (bits 2:0) |
| `+0B` | `VWTBLO` | Wavetable base address low byte (waveform 6 only) |
| `+0C` | `VWTBHI` | Wavetable base address high byte |
| `+0D` | `VVOLR` | Right channel individual volume (4-bit) |
| `+0E` | `VVOLL` | Left channel individual volume (4-bit) |
| `+0F` | `Reserved` | — |

### Voice base addresses

| Voice | Base address |
|---|---|
| Voice 0 | `$80100` |
| Voice 1 | `$80110` |
| Voice 2 | `$80120` |
| Voice 3 | `$80130` |

---

## 4.10 — Global Register Map

Global registers follow the 4 voice blocks, starting at `$80140`:

| Address | Register | Description |
|---|---|---|
| `$80140` | `AMVOL` | Master volume (8-bit, 0–255) |
| `$80141` | `AMVOLL` | Master left volume (4-bit) |
| `$80142` | `AMVOLR` | Master right volume (4-bit) |
| `$80143` | `AMVOICE` | Voice enable flags (bits 0–3 = voices 0–3) |
| `$80144` | `AMFILT` | Voice filter route flags (bits 0–3 = voices 0–3) |
| `$80145` | `AFCUTLO` | Filter cutoff low byte (bits 3:0 of 12-bit value) |
| `$80146` | `AFCUTHI` | Filter cutoff high byte (bits 11:4) |
| `$80147` | `AFRESON` | Filter resonance (4-bit, 0–15) |
| `$80148` | `AFMODE` | Filter mode (0=LP, 1=HP, 2=BP, 3=Notch) |
| `$80149` | `ASRATE` | Sample rate (0=44.1KHz, 1=22.05KHz, 2=11KHz) |
| `$8014A` | `AIRQEN` | Bit 0: enable IRQ on voice envelope completion |
| `$8014B` | `ASTAT` | Bits 0–3: voice envelope-complete flags (write 1 to clear) |
| `$8014C – $801FF` | — | Reserved |

`ASRATE` selects the internal synthesis tick rate; the emulator's host output stream remains
44.1 kHz (samples repeated 2×/4× at the lower rates).

---

## 4.11 — Audio IRQ

The AUR-1 can fire a CPU interrupt when any voice completes its Release phase (envelope reaches
zero). This is useful for:

- Sequencing the next note without polling
- Triggering sound effects precisely at the end of another
- Driving software PCM playback timing

The `ASTAT` register indicates which voice(s) triggered the IRQ. Flags are cleared by writing
`1` to the relevant bit (write-1-to-clear pattern).

---

## 4.12 — Software PCM Playback

The AUR-1 has no built-in sample playback. PCM audio can be implemented in software using a
**Timer A interrupt** at the desired sample rate:

1. Set Timer A to fire at the target sample rate (e.g. 11KHz for low-quality, 44.1KHz for full)
2. In the IRQ handler, read the next sample byte from a buffer in general RAM
3. Write it to `VVOL` of a voice set to square or sawtooth wave at a fixed high frequency
4. Increment the buffer pointer; loop or stop when the buffer is exhausted

This technique is CPU-intensive but workable for short sound effects at lower sample rates,
exactly as was done on the C64 and Amiga for sampled audio playback.

---

## Phase 4 — Key Facts (carry forward to all phases)

| Item | Detail |
|---|---|
| Voices | 4, each 16 bytes of registers |
| Voice 0 base | `$80100` |
| Voice 1 base | `$80110` |
| Voice 2 base | `$80120` |
| Voice 3 base | `$80130` |
| Global registers | `$80140` |
| Waveforms | Sine, Square, Triangle, Sawtooth, Pulse, Noise, Wavetable |
| Envelope | ADSR per voice, gate-triggered (SID-style) |
| Pulse width | Per-voice duty cycle register for PWM sweep |
| Wavetable | 256-byte custom waveform from general RAM |
| FM pairing | Voice 0+1, Voice 2+3 (OPL-style carrier/modulator) |
| Ring mod & sync | Per voice, SID-style |
| Filter | Shared LP/HP/BP/Notch, 12-bit cutoff, 4-bit resonance |
| Output | Stereo, 16-bit, up to 44.1KHz |
| Audio IRQ | Fires on voice envelope completion |
| PCM playback | Software only, via Timer A IRQ |
| Control registers | `$80100 – $801FF` |

---

*Flommodore Fantasy Computer — Design Document*
*Phase 4: AUR-1 Sound Chip Specification — Status: LOCKED (v1.1 — Block 0 amendments applied)*
