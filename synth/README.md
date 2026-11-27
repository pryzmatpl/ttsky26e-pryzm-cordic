# synth/ — area measurement

These scripts price the design so optimisation is aimed at numbers rather than
intuition. None of them is part of the submission; the shuttle never runs them.

## Provisioning the PDK

The Docker daemon lives on the host while this tree lives in the gateway
container, so a bind mount of this path arrives empty. Everything therefore
goes through named volumes.

```bash
docker volume create tt26e-pdk
docker run --rm -v tt26e-pdk:/pdk photonip/cocotb:2.2.0 bash -lc \
  'pip install -q volare && volare enable --pdk sky130 8afc8346a57fe1ab7934ba5a6056ea8b43078e71'
```

`8afc8346…` is the version the TTSKY26e shuttle pins in
`.github/config/librelane.txt`.

## The scripts

| Script | Answers |
|---|---|
| `report.sh` | bare-yosys area and cell families — the fast area reading |
| `experiment.sh` | area of each variant in `synth/variants/`, one row each |
| `variants.py` | builds the variants (multiplier removed, prescaler removed, 16-bit registers) |
| `topcells.py` | ranks cells by area, priced from the liberty file |
| `csd.py` | canonical-signed-digit form of a constant, with its term count |
| `consts.py` | compares the two ways to reach radians from a phase word |

## What the measurements actually said

| Experiment | Cells | Area |
|---|---|---|
| four-op design | 3,316 | 24,498 µm² |
| … with the 16×16 array multiplier | 3,984 | 28,412 µm² |
| … with the multiply accumulator removed | 3,250 | 23,887 µm² |
| … with a single arctangent constant (no 15-way mux) | 3,248 | 24,027 µm² |
| … with 16-bit CORDIC registers | 2,729 | 20,441 µm² |
| … with the prescaler removed | 2,996 | 22,593 µm² |

Two conclusions changed the design:

1. **The multiply is not the dominant block.** Removing it saved 611 µm²; the
   shared adder and the arctangent operand mux cost more. The 16×16 array had
   already been replaced by a shift-add sequencer, which is what turned
   28,412 µm² into 24,498 µm².
2. **Removing whole operations does not shrink the chip.** Dropping HYPOT,
   MUL, or both moved the area by ~30 µm². The die is sized by the datapath,
   so a 1x2 tile cannot be reached by deleting features — which is why the
   submission declares 2x2.

LibreLane's own mapper reports 34,036 µm² for the same RTL, and after resizing
for slew the placed area is 58,890 µm². The flow's number, not yosys's, is the
one that decides the tile count.
