# tt_submission/ (local build)

This is `pdk/tt-submission.py` reproducing the bundle the shuttle's
`tt_tool.py --create-tt-submission` writes — from **our** LibreLane run, not
from the shuttle's CI.

```bash
python3 pdk/tt-submission.py     # rebuilds this directory from the flow volume
```

| file | what it is |
|---|---|
| `tt_um_pryzm_cordic.v` | gate-level netlist (pnl, power-annotated) |
| `tt_um_pryzm_cordic.lef` | design abstract, 334.000 × 216.000 µm |
| `metrics.csv` | every metric the flow recorded |
| `resolved.json` | the full resolved config the flow actually used |
| `commit_id.json` | the commit *our* flow ran on |
| `stats/synthesis-stats.txt` | synthesis cell and area report |

## What this is not

It is **not** a submission artifact. The real one is produced by
`tt-gds-action@ttsky26e` and contains:

- the die **with** the shuttle's pad ring and multiplexer assembled around it
- an `.oas` carrying the `TT_PDK` property
- the shuttle's own `pdk.json` and `commit_id.json`

None of that exists here, and none of it can: it requires the shuttle's run.
`docs/EVIDENCE.md` §5 says the same thing, and this directory should never be
uploaded as if it were the submission.

The layout is kept once, in `../gds/` (LFS), not duplicated here.
