# Can this chip go on a breadboard?

Short answer: **not directly, and not by itself.** You get there in three
steps, and only after the shuttle ships silicon.

## What you actually receive

Tiny Tapeout does not post you a bare die. The packaged part is delivered
already mounted on a **breakout PCB**, and that breakout plugs into the
**demo board** (`TinyTapeout/tt-demo-pcb`). Both are open hardware, so you can
also design your own host board — the breakout is keyed and uses standard
100 mil headers since the TT08 iteration, which is what makes that practical.

So the realistic chain is:

```
die  →  QFN package  →  breakout PCB  →  100 mil headers  →  your board
                                                          →  demo board (USB-C)
```

**Breadboard: yes, at the header level.** The breakout's 100 mil headers have
the same pitch as a breadboard, so a breakout + jumper wires onto a breadboard
works — that is a supported, documented way to use it. What you cannot do is
solder the chip itself to a breadboard, because it arrives as a QFN on a PCB.

## What you need electrically

| Item | Value | Source |
|---|---|---|
| I/O logic level | **3.3 V** | demo board guide: "All the I/O expects 3.3V logic levels" |
| Power | 5 V in via USB-C on the demo board, or back-power 3v3 on a marked header pin | same |
| Design selection | **not optional** — see below | breakout card guide |

The MUX is the part people miss. The die holds many designs sharing one set of
pins, so **your design is not connected until it is selected**: pulse
`ctrl_sel_rst_n` low, pulse `ctrl_sel_inc` N times for address N, then raise
`ctrl_ena`. On the demo board the on-board RP2040 does this for you and the
commander app drives it; on a custom host board you have to do it yourself.
That is why the guide says "you will need a microcontroller to configure the
chip".

## Talking to *this* design once selected

`tt_um_pryzm_cordic` uses a byte-serial port, so any MCU with 12 GPIOs can
drive it — no special hardware, no analog pins, no external parts:

| Pin | Direction | Meaning |
|---|---|---|
| `ui_in[7:0]` | in | operand byte |
| `uo_out[7:0]` | out | result byte |
| `uio_in[0]` | in | `wr` — latch `ui_in` as the next operand byte |
| `uio_in[1]` | in | `go` — start with the operands already written |
| `uio_in[2]` | in | `ack` — host consumed the byte on `uo_out` |
| `uio_in[4:3]` | in | `op` — 0 sin/cos, 1 atan2, 2 hypot, 3 multiply |
| `uio_in[5]` | in | `srst` — clear the operand byte counter |
| `uio_out[6]` | out | `valid` — a result byte is on `uo_out` |
| `uio_out[7]` | out | `busy` — the engine is working |

Sequence per operation: `srst`, write operands with `wr`, pulse `go`, wait for
`valid`, read bytes, pulse `ack` per byte. A 3.3 V Arduino/RP2040/Pi Pico does
this with plain `digitalWrite`/`digitalRead` — no level shifters, since both
sides are 3.3 V.

## The honest caveats

1. **There is no silicon yet.** This is manufacturing data. Nothing here has
   been fabricated, so "put it on a breadboard" is a plan, not a result.
2. **The shuttle must accept it first.** That needs the GDS built by
   `tt-gds-action` in the repo. Local closure (DRC 0, LVS match, TNS 0) is
   necessary but not the acceptance.
3. **You cannot wire it up without the MUX step.** A breadboard alone is not
   enough; you need something to select the design.
4. **2×2 tiles.** The breakout and demo board do not care about tile count —
   the mux presents the same pins either way — so the tile count costs money
   per shuttle slot, not board compatibility.
5. **20 MHz is the design's own limit**, not the board's. The demo board's
   clock is what it is; if you drive `clk` faster than 20 MHz from your own
   board, the arithmetic is outside what the flow closed at.

## Cheapest way to try it before silicon

The shuttle publishes an FPGA "ASIC simulator" breakout
(`TinyTapeout/breakout-pcb`, `fpga-brkout`) that is demoboard-compatible, and
the gate-level netlist behind this design can also be run in simulation. Both
exercise the same RTL and the same pin protocol, so the firmware you write
against a simulator is the firmware you run on the chip.
