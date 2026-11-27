#!/usr/bin/env python3
"""Generate design variants that answer "what actually costs area" with numbers.

The LibreLane-synthesised design is 34,036 um2 — 94 % of a 1x2 tile, which
will not route. These variants price the candidates for getting it under a
tile, so the rewrite is aimed rather than guessed:

  base      the design as it stands
  nomul     the multiply accumulator removed (its adder + 34-bit state)
  noatan    the atan table forced to one constant (the adder's operand mux)
  wide16    the CORDIC registers narrowed from 18 to 16 bits
  nopresc   the prescaler removed

    python3 synth/variants.py && ./synth/experiment.sh
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "src", "project.v")
OUT = os.path.join(HERE, "variants")


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    base = open(SRC).read()

    def write(name: str, text: str) -> None:
        open(os.path.join(OUT, f"{name}.v"), "w").write(text)

    write("base", base)

    # 1. the bit-serial multiply: keep everything else
    write("nomul", base.replace(
        "    if (!mcb[0])    accn = acc;",
        "    if (1'b0)       accn = acc;"))

    # 2. the atan table: a single operand instead of a 15-way mux
    write("noatan", base.replace(
        "wire signed [15:0] atn16 = atan_of(iter);",
        "wire signed [15:0] atn16 = A0;"))

    # 3. register width
    write("wide16", base
          .replace("reg signed [17:0] cx, cy, cz;", "reg signed [15:0] cx, cy, cz;")
          .replace("reg signed [17:0] sxn, syn, szn;", "reg signed [15:0] sxn, syn, szn;")
          .replace("wire signed [17:0] atn ", "wire signed [15:0] atn ")
          .replace("wire signed [17:0] axi ", "wire signed [15:0] axi ")
          .replace("wire signed [17:0] ayi ", "wire signed [15:0] ayi ")
          .replace("wire signed [17:0] atn16", "wire signed [15:0] atn"))
    # 4. prescaler
    write("nopresc", base.replace(
        "          if (bigs < 16'd4096 && shf < 3'd4) begin",
        "          if (1'b0) begin"))

    print("wrote:", ", ".join(sorted(os.listdir(OUT))))


if __name__ == "__main__":
    main()
