# gds/

`tt_um_pryzm_cordic.gds` — the streamed layout of this design, produced by
`./pdk/flow.sh` (LibreLane 3.1.0.dev3, sky130A).

| | |
|---|---|
| top cell | `tt_um_pryzm_cordic` |
| die | **334.000 × 216.000 µm** (2x2 tile) |
| layers | 42 |
| shapes | 664,025 |
| size | 7,035,220 bytes |
| sha256 | `7978d44247264e85620d7dcab7700f20b19f776e9dc9d93ca22899cbc848786c` |

Verified by `./pdk/verify-gds.sh`, which reads the file back with KLayout and
compares its bbox against the LEF's `SIZE` — a file called `.gds` is not
evidence of a die.

## Why this is not the submission

The shuttle builds its own GDS with `tt-gds-action` and that run is the
submission. This file is **the user core only**: it has no pad ring and no
multiplexer, because those belong to the shuttle's assembly. It is here so the
design can be inspected, plotted and diffed without re-running an hour of
place-and-route.

Tracked with Git LFS (`.gitattributes`: `*.gds filter=lfs`).
