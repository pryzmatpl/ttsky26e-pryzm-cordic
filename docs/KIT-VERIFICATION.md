# Kit-board verification: what "padded so the kit can verify it" means

The reference design you linked (`joaln27/CORDIC`) tapes out as a **1x1** tile
with a pinout a beginner can drive from switches:

```
ui[6:0] = FREQ0..FREQ6      uo[0]   = HEARTBEAT
                            uo[1:5] = LEVEL0..LEVEL4
                            uo[6]   = SQUARE sync
                            uo[7]   = SINE sigma-delta (Audio Pmod)
uio[*]  = unused
```

Everything is readable on the demo board's LEDs with no host. That is why it is
"verifiable on the kit".

## What this design is, by contrast

`tt_um_pryzm_cordic` is a **2x2** tile (334.88 x 225.76 um) exposing a
byte-serial protocol:

| pin | role |
|---|---|
| `ui[7:0]` | `D0..D7` — data in |
| `uo[7:0]` | `Q0..Q7` — data out |
| `uio[0]` | `WR` — write strobe |
| `uio[1]` | `GO` — start operation |
| `uio[2]` | `ACK` — operation complete |
| `uio[3:4]` | `OP0..OP1` — operation select |
| `uio[5]` | `SRST` — synchronous reset |
| `uio[6]` | `VALID` — output valid |
| `uio[7]` | `BUSY` — busy |

This is a **coprocessor interface**, not a switch interface. Reaching any result
requires clocking a multi-byte sequence onto `D` with `WR`, selecting an
operation, strobing `GO`, and reading `Q` while `VALID` is high. On a bare demo
board — 8 switches, 8 LEDs, no sequencer — that is not something a person can
do by hand.

So the honest statement is:

- The die **builds**, **routes DRC-clean**, **passes LVS**, and its hardened
  gate-level netlist is **word-exact against the golden model over 1936
  vectors**. That is proven.
- The die is **not** verifiable on the demo board as it stands, because the
  protocol needs a host. That is a pinout/interface gap, not a silicon defect.

## Three ways to close that gap, in increasing cost

### 1. Add a self-test sequencer to the existing pins (no re-tapeout)

The core already has a golden model that runs in software. A small FSM hung off
`SRST` could run a fixed vector set on power-up and report pass/fail on `Q[0]`
and a step counter on `Q[7:1]`, with `BUSY` as the "running" flag. Then the kit
verification is: press reset, watch `uo[0]` go high and stay high, and the
7-bit counter reach `0x7F`. Costs a few hundred cells; fits inside the 2x2 tile
that is already paid for.

This is the cheapest path and it is additive — the byte-serial protocol stays
available for real use.

### 2. Repurpose pins for a switch-driven mode (no re-tapeout)

Because `ui`/`uo` are already 8+8, a mode bit could map `ui[3:0]` to a phase
nibble, `ui[4:6]` to an operation, and `uo[7:0]` to the sine value — exactly the
reference's shape. Select it with `uio[5]` (currently `SRST`) held at reset.
No new logic, only a mux on the existing ports. But it makes the protocol
ambiguous, which is worse for anyone driving it from a host.

### 3. Shrink to 1x1 and mirror the reference pinout

Cleanest for kit verification, most expensive: the datapath measured 62,362
um2 once placed and a 1x1 tile gives ~18,000. Removing operations does not
shrink the shared 18-bit adder, arctangent operand mux and 34-bit accumulate
path. Not achievable without an architectural rewrite.

## Recommended

Option 1. It keeps the paid-for 2x2 tile, keeps the documented protocol, and
turns "cannot be checked on the kit" into "press reset and read one LED" —
which is the property that made the reference verifiable.

## What is already true, so the above is not confused with progress

Verified today, on the hardened netlist rather than the RTL:

| check | result |
|---|---|
| gate-level vs golden model (word-exact) | **1936/1936 vectors, 0 fail** |
| sincos | 314/314 |
| atan2 | 787/787 |
| hypot | 782/782 |
| mul | 53/53 |
| KLayout manufacturing DRC | 0 errors |
| LVS | circuits match uniquely |

Not proven: the die's power straps were 10.64 um inside the die edge, which the
shuttle's precheck rejects (limit 10 um). That fix is in flight — see
`docs/PRECHECK.md`.
