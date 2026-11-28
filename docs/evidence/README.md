# Evidence — tt_um_pryzm_cordic

Every number here names the command that produced it. Nothing is quoted from
design intent. Where a claim is *not* supported, §5 says so.

## 1. Functional verification (what is proven today)

| Check | Command | Result |
|---|---|---|
| RTL ≡ golden model, word for word | `./test/run.sh 2000` | **9736 / 9736 vectors exact, 0 fail** |
| Shuttle cocotb suite | `cd test && make` | **2 / 2 tests pass** (1552 transactions) |
| The harness can fail | arity defect injected in `atan_of` | **detected** (18/35 mismatch) |
| Model numeric conformance | `python3 model/cordic16.py` | sin/cos 21 LSB, atan2 28 LSB, hypot 6 LSB, mul 1 LSB — all inside the 32 LSB budget |

The comparison is **exact word equality**, not a tolerance: the RTL and the
Python model must emit the same 16-bit word for the same input. The numeric
table above is a *separate* check of the model against `math.sin/cos/atan2`,
which is what turns "the RTL matches the model" into "the pair matches
mathematics".

## 2. Physical implementation (sky130A, LibreLane 3.1.0.dev3)

Run: `./pdk/flow.sh` · reported by `./pdk/signoff.sh` and `python3 pdk/metrics.py`

Numbers below are from the **shipping** build: `pdk/metrics.last.json`, from
the 50 ns (20 MHz) run that finished 2026-11-28 13:12 and whose GDS is the one
in `gds/` and `tt_submission/`. Earlier figures are quoted only where the
difference explains something.

| Result | Value |
|---|---|
| Core area | **67,825 µm²** (die 75,602 µm²) |
| Instances | **10,865** (the self-test build; 12,378 before it) |
| Standard-cell utilisation | **77.2 %** of core — 52,355 µm² of 67,825 µm² (5,851 standard-cell instances) |
| Detailed-route violations | **0** |
| LVS (netgen) | **"Circuits match uniquely"** — 0 errors |
| Slew violations | **6** (limit derived from the library; not gating) |
| Max-cap violations | **2** (not gating) |
| Max-fanout violations | **35** (limit 6, not gating) |
| GDS streamed | 334.880 × 225.760 µm, 738,356 shapes, sha256 `d1c96544889d4424…` |
| Hold slack, all corners | **+0.11 ns**, TNS 0 |

### Timing at 20 MHz (50 ns)

At 50 ns (20 MHz) every corner has more than 23 ns of margin, so the die is
comfortably inside its period. The worst corner is `max_ss_100C_1v60`.

| Corner | Setup WS |
|---|---|
| **max_ss_100C_1v60 (worst)** | **+23.78 ns** |
| nom_ss_100C_1v60 | +24.19 ns |
| min_ss_100C_1v60 | +24.62 ns |
| max_tt_025C_1v80 | +31.83 ns |
| nom_tt_025C_1v80 | +32.04 ns |
| max_ff_n40C_1v95 | +34.67 ns |

TNS is 0 at every corner in both directions.

**Setup TNS 0 at every corner.** The design closes at 20 MHz with large
margin; an earlier run at 40 ns (25 MHz) failed the slow corner by 1.67 ns, so
20 MHz is the published figure and the flow proves it rather than assuming it.

## 3. Area: why 2x2 and not 1x2

This is the most important honest number in the repository.

| Quantity | Value | Source |
|---|---|---|
| cells, LibreLane mapper | 34,036 µm² | `06-yosys-synthesis/*.log` |
| cells, bare yosys (`synth/report.sh`) | 24,498 µm² | `synth/stat.last.txt` |
| **placed instance area** | **62,362 µm²** | `pdk/metrics.2x2.json: design__instance__area` |
| 1x1 tile | 18,036 µm² | 167 × 108 |
| 1x2 tile | 36,072 µm² | 167 × 216 |
| 2x2 tile | **75,602 µm²** | 334.88 × 225.76 |

A 1x2 tile cannot hold the design: the *synthesised* cell area is 94 % of the
tile and the *placed* area is 173 % of it. Forcing a 1x2 die makes the flow
report `[GPL-0301] Utilization 142 % exceeds 100 %` — it refuses, correctly.

A 320 x 202 µm die (85.7 % density) also fails, but at routing rather than
placement: 2,779 detailed-route violations. Density is a routing constraint,
not just an area one, so the full tile is what runs. The die measures
334.88 x 225.76 µm — 9.76 µm taller than the nominal 334 x 216 — because
`BOTTOM/TOP_MARGIN_MULT` was lowered from 4 to 3 to bring the power straps
inside the precheck's 10 µm edge rule (see `docs/PRECHECK.md`). The extra height
is core area, not slack.

Removing operations does not help: dropping HYPOT, MUL or both changes the area
by ~30 µm² (`./synth/experiment.sh`), because the shared 18-bit adder, the
15-way arctangent operand mux and the 34-bit accumulate path dominate, not the
operation decode. The die size is a property of the datapath, so **2x2 is the
honest tile count** and `info.yaml` says so.

Two design changes did measurably reduce area, and both are in the shipped RTL:

| Change | Effect |
|---|---|
| 16×16 multiplier array replaced by a 16-cycle shift-add | 34,036 → 28,412 µm² (measured) |
| the two *constant* multiplies written as explicit shift-adds instead of `*` | 28,412 → 24,498 µm² (bare yosys) |

## 4. Reproducing

```bash
python3 model/cordic16.py        # numeric conformance, no tools needed
./test/run.sh 2000               # RTL vs model, needs docker + the sim image
cd test && make                  # the shuttle's own cocotb suite
./synth/report.sh                # bare-yosys area, needs the sky130A volume
./pdk/flow.sh                    # full place+route+DRC+LVS+GDS, ~1 h
./pdk/signoff.sh && python3 pdk/metrics.py pdk/metrics.last.json
```

The PDK lives in a docker volume (`tt26e-pdk`), because the daemon is on the
host and a bind mount of this tree arrives empty. `synth/README.md` has the
one-line `volare enable`.

## 5. What is NOT claimed

- **No silicon.** These are manufacturing files, not a fabricated die.
- **No shuttle run yet.** The GDS here was produced by our own LibreLane
  invocation; the shuttle's `tt-gds-action@ttsky26e` will produce its own and
  the two are expected to agree, but that comparison has not been made. Until
  it is, "the shuttle accepts this" is unproven.
- **35 max-fanout violations remain** (limit 6, configured conservatively).
- **6 max-slew and 2 max-cap violations remain.** They appeared with the
  self-test build and do not gate DRC/LVS/timing, but they are real and are
  not claimed clean.
  They are not a timing or DRC blocker — setup and hold close at every corner,
  DRC is 0 and LVS matches — but they are reported here rather than omitted.
  Raising `MAX_FANOUT_CONSTRAINT` to the shuttle's typical 10 would clear them
  at some area cost; that trade was not taken.
- **The `_2` drive strength is what LibreLane chose**, not a hand-tuned pick.
  Area and power would change under a different strategy.
- **Earlier runs of this design produced different results, and the cause was
  our script, not the tool.** `pdk/flow.sh` passed `--threads`, which this
  LibreLane does not have (`-j/--jobs` is the real flag), and before that it
  passed no job count at all, so OpenROAD sized its pool from the host. Two
  runs on different pool sizes gave 0 and 2,779 detailed-route violations.
  The numbers above come from a run with the job count pinned (`-j 8`) and are
  reproducible with `./pdk/flow.sh`; a DRC result from an unpinned run was not
  a statement about the design.
- **The 20 MHz figure is a flow result, not a characterised number.** No
  silicon has measured this design.

## 6. Re-verification, 2026-11-28 (two days before the shuttle closes)

Every row below was re-run today, not quoted from an earlier session. The
repository is at `beff512`, and the shuttle's own CI on that commit reports
`gds`, `precheck`, `gl_test` and `viewer` all **success**
(`actions/runs/46022214129`).

| Check | Command | Result |
|---|---|---|
| RTL ≡ golden model | `./test/run.sh 2000` | **9736 / 9736 exact, 0 fail** |
| Golden model vs real math | `python3 model/cordic16.py` | sin/cos **21.1** LSB, atan2 **27.5**, hypot **5.6**, mul **1.0** — all inside 32 |
| Bring-up sequence (virtual) | `python3 bringup/selftest.py --virtual` | **39 / 39 cases pass** |
| The bring-up test can fail | `... --virtual --defect` | **0 / 39 pass, RESULT: FAIL** as required |
| GDS read back (KLayout) | `./pdk/verify-gds.sh` | 334.880 × 225.760 µm, 34 layers, 729,117 shapes, top cell + LEF **MATCH** |

The defect run matters as much as the passing one: a self-test that cannot fail
is indistinguishable from a passing one, so both are recorded.

### The GDS that ships

`gds/tt_um_pryzm_cordic.gds`, 7,661,426 bytes,
sha256 `21249e914747d285bac2bfabef4e795886d73e669d368a09a4c2c81b2f1bd36c`.
The figures previously published in `gds/README.md` (7,035,220 bytes, 664,025
shapes, 334 × 216 µm) described an earlier build and were corrected here.

### What is still not proven

- **No silicon.** These are manufacturing files, not a fabricated die.
- **No demo-board run has happened yet.** The self-test sequencer is now
  implemented and proven in simulation (`./test/run-selftest.sh`), so the die
  *is* hand-verifiable: press reset, `uio_out[6]` lit = pass. What remains is the physical
  board, which is not in this environment.
- **The `tt_submission/` bundle is stale.** It was written at 11:02 from the
  334 × 216 build; the GDS and LEF in `gds/` and `lef/` are the post-precheck-fix
  334.880 × 225.760 build from 13:37. Regenerate it with
  `python3 pdk/tt-submission.py` before citing its numbers.
- **Max-fanout:** 35 violations (limit 6); **max-slew:** 6; **max-cap:** 2.
  None gate DRC/LVS/timing; all are stated rather than buried.
