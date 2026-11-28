# RE-VERIFICATION — 2026-11-28 (T−2 to TTSKY26e close)

Independent re-check of `tt_um_pryzm_cordic` at `beff512`, two days before the
shuttle closes on **2026-11-30**. Every row states the command that produced it,
and every number was re-measured today rather than quoted from an earlier
session.

## Verdict

**The tapeout is in good shape. One real gap, and it is on the breadboard side,
not the silicon side.**

| Question | Answer |
|---|---|
| Does the die build on the shuttle's CI? | **Yes** — `gds` job success |
| Does it pass the shuttle's precheck? | **Yes** — 32 LEF errors → 0 (`98560e2`) |
| Does gate-level simulation pass? | **Yes** — `gl_test` success |
| Is the layout manufacturable? | **Yes** — DRC 0, LVS unique |
| Does it close timing at 20 MHz? | **Yes** — setup +26.70 ns, TNS 0 all corners |
| Is the RTL bit-exact to the model? | **Yes** — 9736/9736, 0 fail |
| **Can a human verify it on the demo board?** | **No** — and this is the one open item |

The last row is not a defect in the silicon. It is a pinout/interface gap: the
design is a byte-serial coprocessor that needs a host to clock a multi-byte
sequence. `docs/KIT-VERIFICATION.md` already diagnosed it and proposed the fix;
the fix is **not implemented**.

## 1. Shuttle CI (authoritative — this is the submission gate)

`pryzmatpl/ttsky26e-pryzm-cordic`, run `46022214129`, commit `beff512`:

| job | result |
|---|---|
| `gds` | **success** |
| `precheck` | **success** |
| `gl_test` | **success** |
| `viewer` | **success** |

Published viewer artefact: `tinytapeout.oas` (374,171 B) and
`tinytapeout.gds` (7,732,532 B) on GitHub Pages — HTTP 200, the real CI output.

The GDS the shuttle built and the GDS in `gds/` **agree independently**:
both read back as an outer bbox of 335.070 × 226.000 µm (die 334.880 × 225.760
plus pin labels), and both carry the same top cell. Two different builds, same
geometry — that is the cross-check worth having.

## 2. Physical signoff (shipping build, `pdk/metrics.last.json`)

| Metric | Value |
|---|---|
| Die | **334.880 × 225.760 µm** (75,603 µm²) |
| Core | 5.52…329.36 × 8.16…217.60 µm |
| Detailed-route violations | **0** |
| DRC (magic, manufacturing decks) | **0** |
| LVS (netgen) | **Circuits match uniquely** |
| Setup WS (worst corner) | **+26.70 ns** at 50 ns — TNS **0** |
| Hold WS | **+0.108 ns** — TNS **0** |
| Slew / max-cap violations | **0 / 0** |
| Max-fanout violations | 26 (limit 6) — not gating |
| Instances | 12,378 |
| Utilisation | 65.2 % of core |
| GDS | 729,117 shapes, 34 layers, 7,661,426 B |

### The die is 9.76 µm taller than nominal 2x2

Nominal 2x2 is 334 × 216 µm. This die is 334.88 × 225.76. That is **deliberate**:
`BOTTOM_MARGIN_MULT`/`TOP_MARGIN_MULT` were lowered 4 → 3 to pull the met4 power
straps from 10.64 µm inside the edge to 7.98 µm, inside the precheck's 10 µm
rule. The side effect is 2.66 µm more core at each edge — more routing area, not
less. `docs/PRECHECK.md` records the rejected alternative
(`PDN_EXTEND_TO=boundary`, which stalled detailed routing at 5 violations).

Anything still quoting **334 × 216 / 72,144 µm²** is describing the superseded
build. Corrected today in `README.md`, `info.yaml`, `gds/README.md` and
`docs/evidence/README.md`.

## 3. Functional verification (re-run today)

| Check | Command | Result |
|---|---|---|
| RTL ≡ golden model, word exact | `./test/run.sh 2000` | **9736 / 9736**, 0 fail |
| Model vs real mathematics | `python3 model/cordic16.py` | sin/cos **21.1** LSB, atan2 **27.5**, hypot **5.6**, mul **1.0** — inside 32 |
| Bring-up sequence (virtual) | `python3 bringup/selftest.py --virtual` | **39 / 39 pass** |
| Bring-up **can** fail | `... --virtual --defect` | **0 / 39**, RESULT: FAIL — as required |
| GDS ↔ LEF agreement | `./pdk/verify-gds.sh` | **MATCH**, 334.880 × 225.760 |

The defect run is recorded alongside the passing one on purpose: a self-test
that cannot fail is indistinguishable from a passing one.

## 4. THE OPEN ITEM — the breadboard

The operator's requirement is that the project is verifiable on the demo board
it ships with. **As it stands, it is not.**

The die exposes a byte-serial coprocessor interface:

```
ui[7:0] D0..D7      uo[7:0] Q0..Q7
uio[0] WR  uio[1] GO  uio[2] ACK  uio[3:4] OP  uio[5] SRST
uio[6] VALID  uio[7] BUSY
```

Reaching one result needs: select an op, write N operand bytes with `WR`, pulse
`GO`, poll `VALID`, read result bytes with `ACK`. The demo board has 8 switches,
8 LEDs and no sequencer. A human cannot clock that sequence by hand, so
"press a button and read an LED" — the property that makes a reference design
verifiable on the kit — does not exist here.

**`bringup/selftest.py` does not close this.** It is a good script (it has a
virtual mode and a defect mode), but its hardware path requires `mpremote` and
the `ttboard` SDK driving the board over USB from a host. That is a *host-driven*
check, not a hand-verifiable one. It proves the die when a laptop is attached;
it does not prove it on a breadboard.

### The fix, already designed in `docs/KIT-VERIFICATION.md`

A self-test sequencer hung off `SRST`:

- On reset, run a fixed vector set against the on-die datapath.
- Report pass on `uo[0]` and a step counter on `uo[7:1]`, `BUSY` as "running".
- Kit verification becomes: press reset, watch `uo[0]` go high and stay high.

Cost: a few hundred cells, and the 2x2 tile is already paid for. It is additive
— the byte-serial protocol stays available. **It is not implemented**: there is
no self-test logic in `src/project.v` (462 lines, 9 always/assign blocks).

### Why this still fits in two days

The datapath, the golden model and the vector set all exist. The sequencer is a
small FSM that reads a ROM of `{op, operand_a, operand_b, expect}` entries and
compares against the existing engine — roughly the same logic `bringup/selftest.py`
already runs in software, moved on-die. Then one re-run of `./pdk/flow.sh` and
one push. That is a day of work with a day of margin, but it is the only path
that makes the breadboard claim true, and it must start now or not at all.

## 5. Defects found and fixed in this pass

| # | Defect | Fix |
|---|---|---|
| 1 | `gds/README.md` published 7,035,220 B / 664,025 shapes / sha `7978d442…` — all from a superseded build | corrected to 7,661,426 B / 729,117 shapes / sha `21249e91…` |
| 2 | `gds/README.md` said 334.000 × 216.000 µm | 334.880 × 225.760 |
| 3 | `README.md`, `info.yaml`, `docs/evidence/README.md` all quoted 334 × 216 / 72,144 µm² | corrected, with the reason for the extra height recorded |
| 4 | `tt_submission/` bundle described the pre-fix 334 × 216 build (written 11:02, GDS is 13:37) | regenerated from the flow volume; LEF now 334.880 × 225.760, `commit_id.json` refreshed |
| 5 | README pointed twice at `docs/evidence/limitations.md`, which does not exist | repointed to `docs/evidence/README.md` §5, which is where the limitations actually are |
| 6 | `pdk/metrics.2x2.json` carries the superseded build's numbers | left in place (it is a historical record) but every doc that cited it now names `pdk/metrics.last.json` instead |

## 6. Ordered next steps

1. **Implement the self-test sequencer** (`src/project.v`) — the only thing
   standing between this and a true breadboard claim.
2. Re-run `./pdk/flow.sh`, re-verify with `pdk/verify-gds.sh`, push.
3. Confirm the shuttle CI is green again on the new commit.
4. Reserve the 2x2 tile on `app.tinytapeout.com` (deadline 2026-11-30).
5. Optional, not gating: raise `MAX_FANOUT_CONSTRAINT` to 10 to clear the 26
   fanout violations at some area cost.

## What this report does not claim

- No silicon exists. These are manufacturing files.
- No demo-board run has happened. Nothing here was measured on hardware.
- The local flow is LibreLane 3.1.0.dev3; the shuttle pins 3.0.14. The shuttle's
  own green CI is what makes that difference immaterial.
