# pdk/ — the place-and-route run

`flow.sh` runs LibreLane on `src/project.v`, with the PDK the shuttle pins
(`sky130A` @ `8afc8346…`, LibreLane `3.0.14` upstream / `3.1.0.dev3` in the
image available here). It is deliberately the same shape as the shuttle's own
`.github/workflows/gds.yaml`, so a local pass means the CI pass is not the
first time the design has been routed.

```bash
./pdk/flow.sh                 # 20 MHz (CLOCK_NS=50)
CLOCK_NS=40 ./pdk/flow.sh     # 25 MHz — fails setup at the slow corner
```

## What it writes

Inside the `tt26e-sim` volume, under `pdk/runs/tt26e/`:

| Artefact | What it is |
|---|---|
| `final/metrics.json` | every number the flow measured |
| `final/gds/tt_um_pryzm_cordic.gds` | the streamed layout |
| `70-netgen-lvs/reports/lvs.netgen.rpt` | the LVS verdict |
| `44-openroad-detailedrouting/*.log` | the routed database and its DRC count |

## Reading the result

```bash
./pdk/signoff.sh                                  # stage list, DRC, LVS, GDS
python3 pdk/metrics.py pdk/metrics.last.json      # area, timing per corner
./pdk/netlist.sh                                  # cell mix of the mapped netlist
./pdk/cells.sh                                    # the same, with the log's own rows
./pdk/report.sh                                   # area against the three tile sizes
```

## The die

`DIE_AREA: [0, 0, 320, 202]` — a 2x2 tile is 334 x 216 µm and the shuttle adds
its own pad ring and multiplexer, so the user core is inside that.

This is not a guess. The measurements that fix it:

| Quantity | Value |
|---|---|
| synthesized cells (LibreLane mapper) | 34,036 µm² |
| placed instance area after resizing | 58,890 µm² |
| 1x1 tile | 18,036 µm² |
| 1x2 tile | 36,072 µm² |
| 2x2 tile | 72,144 µm² |

A 1x2 die makes the flow refuse with
`[GPL-0301] Utilization 142 % exceeds 100 %`, which is the correct answer:
the design does not fit. `synth/README.md` records the experiments that
established that removing operations does not change it.

## Clock

20 MHz. At 50 ns the worst (slow, 100 °C, 1.60 V) corner has **+26.87 ns** of
setup slack and every corner has TNS 0. At 40 ns (25 MHz) the slow corner is
**−1.67 ns**, so 20 MHz is the figure the datasheet publishes.

## Known limits of this run

- It is LibreLane 3.1.0.dev3, not the `3.0.14` the shuttle pins. The RTL is
  plain Verilog-2001 with no tool-specific pragmas, so the mapping difference
  is expected to be small — but "expected" is not "measured", and §5 of
  `docs/evidence/README.md` says so.
- The shuttle's `tt-gds-action` will route this again inside the multiplexer.
  That run, not this one, is the submission.
