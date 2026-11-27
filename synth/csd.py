#!/usr/bin/env python3
"""Emit Verilog for a constant multiply in canonical signed digit (CSD) form.

A constant multiply is a sum of shifted copies of the input. Binary needs one
term per set bit; CSD allows -1 digits and so uses ~1/3 as many, which is
exactly the difference between a general multiplier array and a couple of
adders in synthesis.

    python3 synth/csd.py                 # the two coefficients this design needs
    python3 synth/csd.py 25736 name w    # one coefficient: value, signal, width
"""

import sys


def csd(value: int, width: int) -> list[tuple[int, int]]:
    """Return [(digit, shift)] with digit in {-1, +1}, value == sum(d<<s)."""
    terms = []
    i = 0
    v = value
    while v:
        if v & 1:
            # a run of 1s can be replaced by 1 at the bottom and -1 one above
            if v & 3 == 3:
                terms.append((-1, i))
                v += 1
            else:
                terms.append((+1, i))
            v >>= 1
        else:
            v >>= 1
        i += 1
    return terms


def emit(value: int, name: str, width: int, signed: bool = True) -> str:
    terms = csd(value, width)
    lines = [f"// {name} = {value} in CSD: {len(terms)} terms"]
    # widen the input to give the partial sums headroom
    ext = width + 8
    s = "signed " if signed else ""
    lines.append(f"wire {s}[{ext - 1}:0] {name}_x = x_in;")
    parts = []
    for d, sh in terms:
        body = f"({name}_x" + (f" <<< {sh})" if sh else ")")
        if sh:
            body += ")"
        parts.append(("- " if d < 0 else "+ ") + body if parts else body)
    lines.append(f"wire {s}[{ext - 1}:0] {name}_sum =")
    for k, p in enumerate(parts):
        lines.append(f"    {p}" + (";" if k == len(parts) - 1 else ""))
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) >= 5:
        print(emit(int(sys.argv[1], 0), sys.argv[2], int(sys.argv[3])))
        return 0

    for value, name in ((25736, "pi"), (9949, "kinv")):
        terms = csd(value, 16)
        print(f"{name:6s} {value:6d}: {len(terms)} CSD terms -> "
              + " ".join(f"{'+' if d > 0 else '-'}2^{s}" for d, s in terms))
    print()
    print(emit(25736, "pi", 16))
    print()
    print(emit(9949, "kinv", 18))
    return 0


if __name__ == "__main__":
    sys.exit(main())
