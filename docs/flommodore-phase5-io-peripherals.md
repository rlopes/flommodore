# Flommodore — Phase 5: I/O & Peripherals Specification

## Overview

All I/O devices are memory-mapped into the I/O region at `$80000 – $80FFF`. The CPU reads and
writes to peripheral registers exactly like normal memory — no special I/O instructions needed,
consistent with the Gab-16's clean RISC philosophy.

**Register access model:** every I/O register is a **16-bit value at its listed address**.
Access I/O with `LW`/`SW` at the exact register address — adjacent addresses are independent
registers and never combine into one word. `LB`/`SB` access the low byte of a register.

---

## 5.1 — System Configuration (`$80000 – $8000F`)

| Address | Register | Description |
|---|---|---|
| `$80000` | `SYSCFG` | System config: Bit 0 = ROM shadow enable |
| `$80001` | `SYSID` | Read-only machine ID byte (`$F1` = Flommodore) |
| `$80002` | `SYSVER` | Read-only firmware version byte |
| `$80003` | `SYSPWR` | Power control: Bit 0 = soft power off (the emulator exits cleanly) |
| `$80004 – $8000F` | — | Reserved |

---

## 5.2 — Timers (`$80010 – $8001F`)

The Flommodore has **two independent 16-bit countdown timers**, Timer A and Timer B. Both can
generate IRQs and are the primary mechanism for real-time scheduling, sound sequencing, and
PCM playback.

### Timer operation

Each timer counts down from a **16-bit reload value** at a configurable clock divisor. When it
reaches zero it:

1. Optionally fires a CPU IRQ
2. Optionally reloads and continues (repeating mode) or stops (one-shot mode)

### Timer registers

Timer A base address: `$80010` — Timer B base address: `$80018`

| Offset | Register | Description |
|---|---|---|
| `+00` | `TxLOADLO` | Reload value low byte |
| `+01` | `TxLOADHI` | Reload value high byte |
| `+02` | `TxCNTLO` | Current count low byte (read-only) |
| `+03` | `TxCNTHI` | Current count high byte (read-only) |
| `+04` | `TxCTRL` | Bit 0=enable \| Bit 1=repeat (0 = one-shot) \| Bit 2=IRQ enable \| bits 3–15 reserved |
| `+05` | `TxDIV` | Clock divisor (0=÷1, 1=÷8, 2=÷64, 3=÷256) |
| `+06` | `TxSTAT` | Bit 0=expired flag (write 1 to clear) |
| `+07` | — | Reserved |

### Practical timer rates

At the Flommodore's reference clock of **14.4 MHz** (exact — 14,400,000 Hz):

| Divisor | Tick rate | Useful for |
|---|---|---|
| ÷1 | 14.4 MHz | Very fine timing |
| ÷8 | 1.8 MHz | PCM playback — reload 40 → **45.0 kHz exact**, reload 80 → 22.5 kHz exact |
| ÷64 | 225 kHz | Music sequencing |
| ÷256 | 56.25 kHz | Game logic, UI events |

45 kHz and 22.5 kHz are the machine's natural PCM rates; 44.1 kHz is approximated with
reload 41 (≈ 43.9 kHz).

---

## 5.3 — Keyboard (`$80020 – $8002F`)

The keyboard interface uses a **scancode-based** system. The hardware maintains a small key
event queue — the CPU does not need to poll at cycle speed.

| Address | Register | Description |
|---|---|---|
| `$80020` | `KSTAT` | Bit 0=key event available \| Bit 1=queue full \| Bit 2=caps lock \| Bit 3=num lock |
| `$80021` | `KDATA` | Read: dequeue next scancode — 16-bit value; dequeues on **any** read width, so use `LW` |
| `$80022` | `KMOD` | Current modifier state: Bit 0=shift \| Bit 1=ctrl \| Bit 2=alt \| Bit 3=super |
| `$80023` | `KCTRL` | Bit 0=IRQ enable on key event \| Bit 1=flush queue (write-1, self-clearing) |
| `$80024 – $8002F` | — | Reserved |

### Scancode format

Each entry read from `KDATA` is a **16-bit value**:

```
Bit 15      Key up (1) or key down (0)
Bits 14:8   Reserved
Bits 7:0    Scancode (USB HID scancode table)
```

The key event queue holds **16 entries**. If the queue overflows, `KSTAT` bit 1 is set and
new events are dropped until the CPU drains the queue.

Using USB HID scancodes means the keyboard layout is well-defined, widely documented, and
easy to map to any physical keyboard in an emulator. `KSTAT` caps/num-lock bits mirror
the host keyboard state.

---

## 5.4 — Joystick Ports (`$80030 – $8003F`)

Two digital joystick ports, each supporting a classic **9-pin digital joystick**
(Atari / Amiga / C64 standard) plus two fire buttons.

| Address | Register | Description |
|---|---|---|
| `$80030` | `JOY1` | Joystick 1 state (see bit map below) |
| `$80031` | `JOY2` | Joystick 2 state |
| `$80032` | `JCTRL` | Bit 0=IRQ enable on joystick state change (fires on any bit transition of either port) |
| `$80033 – $8003F` | — | Reserved |

### Joystick state byte

```
Bit 7   Fire button 2
Bit 6   Fire button 1
Bit 5   Reserved
Bit 4   Reserved
Bit 3   Right
Bit 2   Left
Bit 1   Down
Bit 0   Up
```

Each bit is **1 = pressed, 0 = released**. Diagonal directions are represented naturally by
two direction bits set simultaneously (e.g. Up + Right = `$09`).

---

## 5.5 — IRQ Controller (`$80040 – $8004F`)

The IRQ controller manages all interrupt sources and presents them to the Gab-16 CPU as a
single IRQ line. It provides masking and a raw status view so the CPU's IRQ handler can
quickly identify and service the correct source.

| Address | Register | Description |
|---|---|---|
| `$80040` | `IRQSTAT` | Pending IRQ sources (read-only, see bit map below) |
| `$80041` | `IRQMASK` | IRQ enable mask (1 = source enabled) |
| `$80042` | `IRQACK` | Write source bit here to acknowledge and clear it |
| `$80043` | — | Reserved (the `IRQPRI` register of spec v1.0 is deleted) |
| `$80044 – $8004F` | — | Reserved |

**Semantics:** `IRQSTAT` always shows raw pending state regardless of `IRQMASK`. The CPU IRQ
line is asserted while `(IRQSTAT & IRQMASK) ≠ 0`. Device-level enables (`TxCTRL` bit 2,
`KCTRL` bit 0, `VIRQEN`, `AIRQEN`) gate whether a device *sets* its `IRQSTAT` bit in the
first place. All sources are delivered through **IVT entry 2** — software dispatch, see
Phase 2 §2.6.

### IRQ source bit map (IRQSTAT / IRQMASK / IRQACK)

| Bit | Source |
|---|---|
| 0 | Timer A expired |
| 1 | Timer B expired |
| 2 | Keyboard key event |
| 3 | Joystick state change |
| 4 | VIC-256 VBLANK |
| 5 | VIC-256 raster interrupt |
| 6 | AUR-1 envelope complete |
| 7 | Reserved |

### IRQ handler pattern

```
IRQ handler:
  Read  IRQSTAT          ; which sources are pending?
  Test  bit 4            ; VBLANK?
    → handle VBLANK
  Test  bit 0            ; Timer A?
    → handle Timer A
  ... etc.
  Write handled bits to IRQACK   ; clear serviced sources
  RTI                            ; restore FLAGS and PC
```

---

## 5.6 — Reserved Expansion Space (`$80050 – $800FF`)

176 bytes reserved for future peripherals. Candidates include:

- Serial / UART port
- SPI or I²C bus controller
- Real-time clock (RTC)
- Cartridge port registers
- DMA controller for bulk VRAM transfers

---

## 5.7 — Full I/O Address Map

```
$80000 – $8000F    16 B     System config & ID
$80010 – $80017     8 B     Timer A
$80018 – $8001F     8 B     Timer B
$80020 – $8002F    16 B     Keyboard
$80030 – $8003F    16 B     Joystick ports A & B
$80040 – $8004F    16 B     IRQ controller
$80050 – $800FF   176 B     Reserved expansion
$80100 – $801FF   256 B     AUR-1 sound chip        (Phase 4)
$80200 – $802FF   256 B     VIC-256 video control   (Phase 3)
$80300 – $80FFF   ~3.5 KB   Reserved
```

---

## Phase 5 — Key Facts (carry forward to all phases)

| Item | Address | Detail |
|---|---|---|
| System config | `$80000` | ROM shadow enable, machine ID, power off |
| Timer A | `$80010` | 16-bit countdown, repeat/one-shot, 4 divisors, IRQ |
| Timer B | `$80018` | Same as Timer A, independent |
| Keyboard | `$80020` | 16-entry scancode queue, USB HID, 16-bit events, modifiers |
| Joystick 1 | `$80030` | 9-pin digital, 4 directions + 2 fire buttons |
| Joystick 2 | `$80031` | Same as Joystick 1, independent |
| IRQ controller | `$80040` | 8 sources, maskable, write-to-ack, software dispatch via IVT entry 2 |
| Expansion | `$80050` | 176 bytes reserved for future devices |

---

*Flommodore Fantasy Computer — Design Document*
*Phase 5: I/O & Peripherals Specification — Status: LOCKED (v1.1 — Block 0 amendments applied)*
