#!/usr/bin/env python3
"""Choose the cheapest shift-add form for the two phase constants.

The design needs one constant multiply to turn a phase word into radians.
Two equivalent routes exist and they are not equally expensive in silicon:

  A. radians = phase * pi      (Q1.15 -> Q3.13), then fold at |theta| > pi/2
  B. radians = phase * (pi/2)  (Q1.15 -> Q3.13), a factor of two cheaper in
     shift-add terms, with the quadrant decided from |radians| > pi/2

Both reach the same angles; B's constant has fewer set bits. This script prints
the CSD term count for each so the choice is recorded as a measurement.

    python3 synth/consts.py
"""

import math

import csd

PHASE_Q15 = 1 << 15


def csd_terms(value: int) -> int:
    return len(csd.csd(value, 20))


def main() -> None:
    pi_q13 = round(math.pi * 8192)            # 25736
    half_q13 = round(math.pi / 2 * 8192)      # 12868
    # pi/2 in the phase word's own scaling: phase * (pi/2) >> 15 -> Q3.13
    half_coef = round((math.pi / 2) * 8192)   # 12868

    print(f"{'route':6s} {'coefficient':>12s} {'CSD terms':>10s}")
    print(f"{'A':6s} {pi_q13:12d} {csd_terms(pi_q13):10d}   radians = phase*pi >> 15")
    print(f"{'B':6s} {half_coef:12d} {csd_terms(half_coef):10d}   radians = phase*(pi/2) >> 15")

    print()
    for v, n in ((pi_q13, "pi"), (half_coef, "pi/2")):
        terms = csd.csd(v, 20)
        print(f"{n:5s} {v:6d}: " + " ".join(
            f"{'+' if d > 0 else '-'}2^{s}" for d, s in terms))

    # Route B doubles the angle in range: |phase| <= 1.0 gives |theta| <= pi.
    print()
    print("route B range check: max |theta| = "
          f"{PHASE_Q15 * half_coef >> 15} Q3.13 LSB = "
          f"{(PHASE_Q15 * half_coef >> 15) / 8192:.4f} rad")


if __name__ == "__main__":
    main()
