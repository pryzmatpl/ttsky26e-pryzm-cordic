# DESIGN — tt_um_pryzm_cordic

Frozen decisions. Changing one of these invalidates the numeric evidence, so
each carries the reason it was chosen.

## 1. Numeric formats

| Quantity | Format | Why |
|---|---|---|
| phase operand | Q2.14 signed, full turn = ±1.0 | one 16-bit word covers the whole circle; the quadrant reduction is then a compare on the sign of `|p| - 0.5`, not a modulo |
| trig result | Q1.15 signed | 1.0 is the largest magnitude sin/cos can take; the encoding of exactly 1.0 is `0x7FFF` |
| vector operand | Q1.15 signed | same format as the trig result, so `SINCOS → ATAN2/HYPOT` composes without a conversion |
| angle result | Q3.13 radians | π = 3.14159 does not fit Q1.15; Q3.13 covers ±4.0 rad, so ±π and the `ATAN2` quadrant offset both fit |
| product | Q1.15 | `(a*b) >> 15`, one truncation, one saturation |
| CORDIC internal | Q2.14 for x, y, z | the rotation gain K = 1.6468 pushes `sqrt(x²+y²)` up by 1.65x; Q2.14 (range ±2.0) absorbs both the gain and the `|x|=|y|=1` corner, Q1.15 would saturate |

Rejected: Q1.15 internal. `KINV = 0.6073` in Q1.15 times K = 1.0 exactly, and
`s16(32768)` wraps to `-32768`, i.e. `cos(0) = -1.0`. That defect was found by
the prototype before any RTL was written (see §7).

## 2. Iteration count

**15 stages.** Rules out 14 and below because the final `atan(2^-14)` is the
last term that can move a Q3.13 LSB (it is 1 LSB at stage 14, 0 at stage 15).
Above 15 the added stage can no longer change a 16-bit result, only the area.

Angle table (Q3.13): `6434, 3798, 2007, 1019, 511, 256, 128, 64, 32, 16, 8, 4,
2, 1, 0`.

## 3. Gain compensation

`KINV = round(1/K * 2^14) = 9950` in Q2.14, applied as the initial `x` of a
rotation. One constant, no per-stage multiplier, no data dependence — that is
what makes the compensation a constant instead of a division.

## 4. Interface

Byte-serial, because 16-bit operands do not fit the 8-bit `ui_in` bus and the
analog pins are deliberately unused (digital submission, no `tt_asw_3v3`).

Write phase: `uio[7:4] = {opcode[1:0], operand_index[1:0]}`, `uio[3:0]` unused;
`ui_in[7:0]` carries the byte. Strobe on `uio[7]`-qualified transfer is avoided
— instead `uio_oe = 8'h00` (inputs), so the host drives everything and the
engine latches on the clock edge where `uio[6]` (`wr`) is high.

Read phase: engine drives `uo_out[7:0]` and sets `uio_out[6] = valid`.

| `uio` | direction | meaning |
|---|---|---|
| `[0]` | in | `wr` — latch `ui_in` into the addressed operand slot |
| `[1]` | in | `go` — start the computation |
| `[2]` | in | `sel` — 0 = low byte addressed first, 1 = high byte |
| `[5:3]` | in | `opcode` (0 SINCOS, 1 ATAN2, 2 HYPOT, 3 MUL) |
| `[6]` | out | `valid` — result byte present on `uo_out` |
| `[7]` | out | `busy` |

`uio_oe = 8'b1100_0000`.

Rejected: an SPI/I2C slave. It needs a synchroniser, a bit counter and a
command decoder, roughly doubling the control logic to save the host three
wires it already has.

## 5. Tile count

**1x2, chosen by measurement, not by comfort.** The `tt_um_cordic` reference on
this shuttle is 987 cells / 10,581 µm² on **1x1**. Our engine adds a 16x16
multiplier and a four-op register file, so it is expected to land above the 1x1
budget; 1x2 doubles the area to 167 x 216 µm. The claim in `docs/evidence/`
records the synthesised area, and if it fits 1x1 the info.yaml is changed to
`1x1` — the gate is the area report, not the estimate.

## 6. Verification chain

1. `model/cordic16.py` (or `.mjs`) — the 16-bit golden model, integer-exact.
2. `test/test.py` — cocotb, drives RTL and model with the same vectors, asserts
   word equality; second test asserts the model against `math.sin/cos/atan2`
   within 2^-10.
3. PhotonIP's own `photonip.tinyrisc.cordic` 32-bit model and conformance
   harness (`tests/cordic-conformance.ts`) stay the cross-check on the
   *algorithm*, not on the 16-bit words.
4. LibreLane synthesis → area, timing, DRC, LVS. The shuttle's CI and our own
   run are compared cell-for-cell.

## 7. Defects found during design (kept, so they are not re-introduced)

- **Q1.15 internal state overflows.** `s16(32768) = -32768`; `cos(0)` came back
  `-1.0`. Fixed by taking x, y, z to Q2.14.
- **Angle in Q1.14 cannot represent π.** A wrapped phase word needs ±π; the
  first prototype wrapped in the same format it rotated in and lost the sign of
  the half-plane. Fixed by wrapping in the interface format (Q2.14 phase word,
  ±1.0 turn) and converting to the internal angle once.
- **`INV_CORDIC_GAIN` in Q1.15 is `19898`, not `32768`.** Reading it as a
  fraction of 1.0 rather than a Q1.15 word was the source of a silent 2x gain
  error in the first sn/cs prototype.
