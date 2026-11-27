# Precheck: what failed, and why the fix is what it is

The shuttle's `tt-gds-action` runs four jobs. On commit `3d2edff`:

| job | result |
|---|---|
| `gds` | **success** — GDS built |
| `gl_test` | **success** — gate-level testbench ran against the built netlist |
| `precheck` | **failure** — 32 LEF errors |
| `viewer` | failure (follows precheck) |

So the die builds and the gate-level simulation passes. What failed is a
static check on the LEF the packer wrote:

```
ERROR: Port VGND  is too far from bottom edge of module: 10.64 > 10 um
ERROR: Port VGND  is too far from top edge of module: 10.64 > 10 um
ERROR: Port VDPWR is too far from bottom edge of module: 10.64 > 10 um
ERROR: Port VDPWR is too far from top edge of module: 10.64 > 10 um
```

16 pairs = 32 errors, all the same number, all on the two power ports. Every
signal port passed, and every DRC check the precheck runs reported
`0 total error(s)`.

## Not a DRC problem

The precheck's KLayout decks all reported zero:

| deck | result |
|---|---|
| `sky130A_mr.drc` (manufacturing rules) | 0 errors |
| `drc_offgrid` | passed |
| `drc_pin_label_purposes_overlapping_drawing` | 0 errors, 33 checks |
| `zero_area` | 0 objects |
| forbidden-layer, prBoundary, top-macro-name | passed |

The failure is geometric intent, not manufacturability: the pins are legal but
in the wrong place for the shuttle's assembly.

## The arithmetic

The die is 225.76 µm tall. The met4 straps the PDN produced span
`y = 10.64 … 215.12`, so each end is inset by 10.64 µm. The limit is 10 µm.

10.64 is not arbitrary. It is the core boundary: the shuttle's own config sets

```
BOTTOM_MARGIN_MULT = 4      TOP_MARGIN_MULT = 4
LEFT_MARGIN_MULT  = 12      RIGHT_MARGIN_MULT = 12
```

and the PDN variable that decides how far a strap travels is

```
PDN_EXTEND_TO = core_ring        # the default
```

There is no core ring here — the shuttle config sets `PDN_CORE_RING = False` —
so `core_ring` resolves to the core boundary, and the straps stop 10.64 µm
short of the die edge.

## The fix, and why this one

```json
"PDN_EXTEND_TO": "boundary"
```

`boundary` is the value that means "run the strap to the die edge", which is
both what the precheck wants and what the shuttle's own blocks look like. It is
a one-key change and it does not weaken any check.

Considered and rejected:

- **Increase `PDN_VOFFSET`** so the *first* strap lands nearer the edge. That
  moves every strap; it does not change where the straps *end*, and the top
  edge would still be 10.64 µm short. Wrong axis.
- **Raise `MAX_TRANSITION_CONSTRAINT` to buy area back.** The straps are a
  geometry problem, not a density problem. Conflating the two would change the
  design to fix a drawing.
- **Edit the LEF after the flow.** The shuttle regenerates the LEF from the
  GDS, so a hand edit would vanish on the next run and the evidence would stop
  matching the artefact.

The important distinction: the floorplan is derived from the *shuttle's*
config (`BOTTOM_MARGIN_MULT`, `FP_DEF_TEMPLATE`), so the design cannot fix this
by changing its own die — it has to tell the PDN to cross the boundary.

## What is still not proven

- The re-run with `PDN_EXTEND_TO: boundary` has to pass precheck. Until it
  does, this is a diagnosis plus a targeted fix, not a green build.
- `tt_submission` from the failing run exists and is complete (GDS, LEF, OAS,
  netlist, three SPEF corners, metrics) — that is what made this diagnosable
  without re-running an hour of PnR.
