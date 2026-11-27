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

Run on a 2x2-sized die (320 x 202 µm user core). Numbers from
`pdk/metrics.2x2.json`:

| Result | Value |
|---|---|
| Placed instance area | **55,410 µm²** on a 64,640 µm² die |
| Instances | 8,789 |
| Routed wirelength | 128,833 µm |
| Detailed-route violations | **0** |
| LVS (netgen) | **"Circuits match uniquely"** — 0 errors |
| **Slew violations** | **0** |
| Max-cap violations | **0** |
| Max-fanout violations | 26 (not gating; see §5) |
| GDS streamed | `final/gds/tt_um_pryzm_cordic.gds` |
| Hold slack, all corners | **+0.11 ns**, TNS 0 |

### Timing at 20 MHz (50 ns)

| Corner | Setup WS |
|---|---|
| max_ss_100C_1v60 (worst) | **+24.73 ns** |
| nom_ss_100C_1v60 | +25.18 ns |
| min_ss_100C_1v60 | +25.70 ns |
| max_tt_025C_1v80 | +36.14 ns |
| max_ff_n40C_1v95 | +37.46 ns |

**Setup TNS 0 at every corner.** The design closes at 20 MHz with large
margin; an earlier run at 40 ns (25 MHz) failed the slow corner by 1.67 ns, so
20 MHz is the published figure and the flow proves it rather than assuming it.

## 3. Area: why 2x2 and not 1x2

This is the most important honest number in the repository.

| Quantity | Value | Source |
|---|---|---|
| cells, LibreLane mapper | 34,036 µm² | `06-yosys-synthesis/*.log` |
| cells, bare yosys (`synth/report.sh`) | 24,498 µm² | `synth/stat.last.txt` |
| **placed instance area** | **55,410 µm²** | `pdk/metrics.2x2.json: design__instance__area` |
| 1x1 tile | 18,036 µm² | 167 × 108 |
| 1x2 tile | 36,072 µm² | 167 × 216 |
| 2x2 tile | 72,144 µm² | 334 × 216 |

A 1x2 tile cannot hold the design: the *synthesised* cell area is 94 % of the
tile and the *placed* area is 154 % of it. Forcing a 1x2 die makes the flow
report `[GPL-0301] Utilization 142 % exceeds 100 %` — it refuses, correctly.

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
- **26 max-fanout violations remain** (limit 6, configured conservatively).
  They are not a timing or DRC blocker — setup and hold close at every corner,
  DRC is 0 and LVS matches — but they are reported here rather than omitted.
  Raising `MAX_FANOUT_CONSTRAINT` to the shuttle's typical 10 would clear them
  at some area cost; that trade was not taken.
- **The `_2` drive strength is what LibreLane chose**, not a hand-tuned pick.
  Area and power would change under a different strategy.
- **The 20 MHz figure is a flow result, not a characterised number.** No
  silicon has measured this design.
