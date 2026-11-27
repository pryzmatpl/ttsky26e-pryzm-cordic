# SUBMIT.md — what to do to close TTSKY26e

The repo is built, verified and committed at
`/home/node/.jaisiu/workspace/ttsky26e-pryzm-cordic` (branch `main`, 4 commits).
What remains is the mechanical submission, and one decision that is yours.

Deadline: **2026-11-30** (TTSKY26E on `app.tinytapeout.com`, ~3 days).

## 1. Push to GitHub (needs your credential)

There is no GitHub token in this environment — the GitLab remote on the Jaisiu
repo is a PAT for `test.pryzmat.pl`, not GitHub. So the push is yours:

```bash
cd /home/node/.jaisiu/workspace/ttsky26e-pryzm-cordic
git remote add origin git@github.com:<you>/ttsky26e-pryzm-cordic.git
git push -u origin main
```

The repo name matters: Tiny Tapeout identifiers the submission by repository,
and `top_module` is already claimed (`tt_um_pryzm_cordic`). If `<you>` is not
the account you want credited, say which and the README author line changes
with it.

As soon as it is pushed, `.github/workflows/gds.yaml` runs the shuttle's own
`tt-gds-action@ttsky26e`: build GDS → precheck → gate-level test → viewer. That
CI run is the actual submission evidence. Our local LibreLane run is a
rehearsal, not a substitute.

## 2. Reserve the tile

On `app.tinytapeout.com`: shuttle **TTSKY26E**, project from repo, **2x2 tiles**.

2x2 is measured, not chosen: placed cell area is **62,362 µm²** on a
72,144 µm² die, a 1x2 tile provides 36,072 µm², and a 1x2 die makes LibreLane
refuse with `[GPL-0301] Utilization 142 % exceeds 100 %`. Removing operations
does not help (~30 µm² per operation — the shared datapath sizes the die).
A 320×202 µm die fits the *area* but fails *routing*: 2,779 DRC violations at
85.7 % density. Evidence: `docs/evidence/README.md` §3, `synth/README.md`.

## 3. Decide the clock claim

`info.yaml` says **20 MHz**. What the flow measured:

| clock period | worst-corner setup WS | verdict |
|---|---|---|
| 50 ns (20 MHz) | **+26.14 ns** | closes, TNS 0 |
| 40 ns (25 MHz) | **−1.67 ns** | fails |

20 MHz is the honest number and it is what the datasheet publishes. If you
would rather claim more, the change is a re-run of `./pdk/flow.sh` at a shorter
period — not an edit to the YAML.

## 4. What is already proven

| Check | Result | Command |
|---|---|---|
| GDS read back | 334.000 × 216.000 µm, 42 layers, 664,025 shapes, LEF matches | `./pdk/verify-gds.sh` |
| RTL ≡ golden model (word equality) | **9736/9736 exact** | `./test/run.sh 2000` |
| cocotb suite | **2/2 pass** (1552 transactions) | `cd test && make` |
| the check can fail | fault injection detected | see `docs/evidence/README.md` §1 |
| model vs real math | inside the 32 LSB budget on all four ops | `python3 model/cordic16.py` |
| DRC | **0** | `./pdk/flow.sh` |
| LVS | **circuits match uniquely** | same |
| setup/hold | TNS 0 every corner, hold +0.11 ns | `python3 pdk/metrics.py` |
| slew / max-cap | **0 / 0** | same |
| GDS | streamed | `final/gds/tt_um_pryzm_cordic.gds` |

## 5. What is NOT proven (say this if asked)

- **No silicon.** Manufacturing files, not a fabricated die.
- **No shuttle CI run yet** — blocked on §1. Until `tt-gds-action` runs in your
  repo, "the shuttle accepts this" is unproven. This is the single remaining
  gate.
- **The local flow used LibreLane 3.1.0.dev3**; the shuttle pins 3.0.14. The RTL
  is plain Verilog-2001 with no tool pragmas, so the difference should be small
  — but the shuttle's own run is the measurement.
- **26 max-fanout violations** remain (limit 6). Not a timing/DRC blocker;
  `MAX_FANOUT_CONSTRAINT=10` would clear them at some area cost.

## 6. Why this chip, in one paragraph

`tt_um_cordic` on this same shuttle is a 1-tile, 987-cell CORDIC — proof that
the class closes on sky130A at this PDK, LibreLane version and tile size. This
submission re-implements that shape with four operations, a bit-serial
multiplier and a documented error budget, and takes it all the way through
place, route, DRC, LVS, STA and GDS in a flow we own. That is the thing worth
demonstrating: not that a CORDIC is hard, but that Jaisiu/PhotonIP produces a
**manufacturable** chip with every number re-derivable from the command that
made it.
