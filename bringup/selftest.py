#!/usr/bin/env python3
"""Bring-up self-check for tt_um_pryzm_cordic on the TinyTapeout demo board.

The goal: a person with the kit can confirm the die works, without a logic
analyser or a custom harness. This is the script that does it.

Two modes
---------
  python3 bringup/selftest.py --virtual   # no hardware, runs in CI
  mpremote run bringup/selftest.py        # on the demo board

The virtual mode runs the exact same sequence against the golden model in
`model/cordic16.py`. That matters because a bug in the pin wiggling would
otherwise show up as a confusing dead LED on real hardware; here it shows up as
a failing assertion. `--virtual --defect` corrupts the model so the run must
FAIL - without that pair a self-test that always prints PASS looks identical to
a working one.

Hardware mode uses the official `ttboard` SDK, which is what the demo board's
MicroPython firmware provides:

    from ttboard.demoboard import DemoBoard
    tt = DemoBoard()
    tt.shuttle.tt_um_pryzm_cordic.enable()
    tt.clock_project_PWM(20e6)      # the design's rated 20 MHz
    tt.ui_in.value = b             # 8 input pins
    tt.uo_out.value                # 8 output pins
    tt.uio_in[i] / tt.uio_oe[i]    # bidirectional pins

That SDK sets the MUX, the clock and the pin directions, so nothing here pokes
RP2040 GPIOs directly.

Protocol (see src/project.v and info.yaml)
------------------------------------------
  ui_in[7:0]   D0..D7   operand / data byte in
  uo_out[7:0]  Q0..Q7   result / data byte out
  uio[0]       WR       latch ui_in as the next operand byte
  uio[1]       GO       start
  uio[2]       ACK      host consumed the byte on uo_out
  uio[4:3]     OP       0 SINCOS, 1 ATAN2, 2 HYPOT, 3 MUL
  uio[5]       SRST     clear the operand byte counter
  uio[6]       VALID    a result byte is on uo_out      (chip -> host)
  uio[7]       BUSY     engine working                  (chip -> host)

Operands low byte first. SINCOS takes `phase`; ATAN2/HYPOT take `y` then `x`;
MUL takes `a` then `b`. Results low byte first; SINCOS returns `sin` then `cos`.
"""

import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "model"))

import cordic16 as M  # noqa: E402

# --- pin/bit constants, mirroring the RTL --------------------------------
OP_SINCOS, OP_ATAN2, OP_HYPOT, OP_MUL = 0, 1, 2, 3
OP_NAMES = {OP_SINCOS: "sincos", OP_ATAN2: "atan2", OP_HYPOT: "hypot", OP_MUL: "mul"}

BIT_WR, BIT_GO, BIT_ACK, BIT_SRST = 0, 1, 2, 5
BIT_OP_LO = 3
BIT_VALID, BIT_BUSY = 6, 7

#: uio_oe on the chip side: 1 = the chip drives the pin.
#: VALID and BUSY come out of the die; the rest are inputs to it.
UIO_OE_MASK = (1 << BIT_VALID) | (1 << BIT_BUSY)

#: How long to wait for VALID before declaring the die hung, in seconds.
#: A CORDIC operation is ~15 iterations at 20 MHz, i.e. under 2 us. A second is
#: ~500,000x that, so a timeout here means the die is not responding rather
#: than that it is slow.
VALID_TIMEOUT_S = 1.0


# ---------------------------------------------------------------------------
# Transports - the same four methods each, so the sequence is written once.
# ---------------------------------------------------------------------------
class VirtualDie:
    """The golden model behind the die's interface. No clocks, no timing.

    Its only job is to let the sequence logic be tested. It computes eagerly on
    GO, like the hardware, but synchronously, because a laptop has no clocks.
    """

    def __init__(self, defect: bool = False):
        self._defect = defect
        self._operands: list[int] = []
        self._op = OP_SINCOS
        self._results: list[int] = []
        self._rb = 0

    # host side
    def write_byte(self, value: int) -> None:
        self._operands.append(value & 0xFF)

    def set_op(self, op: int) -> None:
        self._op = op

    def start(self) -> None:
        self._results = self._compute()
        self._rb = 0

    def srst(self) -> None:
        self._operands = []
        self._results = []
        self._rb = 0

    def read_byte(self) -> int:
        if self._rb >= len(self._results):
            return 0
        b = self._results[self._rb]
        self._rb += 1
        return b

    def valid(self) -> bool:
        return self._rb < len(self._results)

    # die side
    def _operand16(self, i: int) -> int:
        lo = self._operands[2 * i] if 2 * i < len(self._operands) else 0
        hi = self._operands[2 * i + 1] if 2 * i + 1 < len(self._operands) else 0
        return M.s16((hi << 8) | lo)

    def _compute(self) -> list[int]:
        op = self._op
        if op == OP_SINCOS:
            sn, cs = M.sincos(self._operand16(0))
            words = [sn & 0xFFFF, cs & 0xFFFF]
        elif op == OP_ATAN2:
            words = [M.atan2(self._operand16(0), self._operand16(1)) & 0xFFFF]
        elif op == OP_HYPOT:
            words = [M.hypot(self._operand16(0), self._operand16(1)) & 0xFFFF]
        else:
            words = [M.mul(self._operand16(0), self._operand16(1)) & 0xFFFF]
        out: list[int] = []
        for w in words:
            out.append(w & 0xFF)          # low byte first
            out.append((w >> 8) & 0xFF)
        if self._defect and out:
            out[0] ^= 0x01                # stuck-at on Q0, first byte
        return out


class DemoBoardDie:
    """The real die, driven through the demo board's `ttboard` SDK.

    Every pin touch goes through the SDK: it owns the project MUX, the clock and
    the pin directions, and it validates the pin indices.
    """

    def __init__(self, top: str = "tt_um_pryzm_cordic", clock_hz: float = 20e6):
        from ttboard.demoboard import DemoBoard  # noqa: PLC0415  (MicroPython)

        self.tt = DemoBoard()
        self.top = top
        self._clock_hz = clock_hz
        self._enter()

    def _enter(self) -> None:
        tt = self.tt
        # Enable this project (sets the MUX) and check the design is actually
        # present: enabling a project the shuttle does not have is the most
        # common way to get a silent all-zero read.
        if not hasattr(tt.shuttle, self.top):
            raise SystemExit(
                f"shuttle has no project '{self.top}'. Present: "
                + ", ".join(sorted(n for n in dir(tt.shuttle) if n.startswith("tt_um_")))
            )
        getattr(tt.shuttle, self.top).enable()
        tt.clock_project_PWM(self._clock_hz)

        # uio: WR/GO/ACK/OP/SRST are host-driven, VALID/BUSY are chip-driven.
        tt.uio_oe_pico.value = (~UIO_OE_MASK) & 0xFF

    # host side
    def write_byte(self, value: int) -> None:
        tt = self.tt
        tt.ui_in.value = value & 0xFF
        tt.uio_in[BIT_WR] = 1
        tt.uio_in[BIT_WR] = 0

    def set_op(self, op: int) -> None:
        tt = self.tt
        tt.uio_in[BIT_OP_LO] = (op >> 0) & 1
        tt.uio_in[BIT_OP_LO + 1] = (op >> 1) & 1

    def start(self) -> None:
        tt = self.tt
        tt.uio_in[BIT_GO] = 1
        tt.uio_in[BIT_GO] = 0

    def srst(self) -> None:
        tt = self.tt
        tt.uio_in[BIT_SRST] = 1
        tt.uio_in[BIT_SRST] = 0

    def read_byte(self) -> int:
        tt = self.tt
        v = int(tt.uo_out.value) & 0xFF
        tt.uio_in[BIT_ACK] = 1
        tt.uio_in[BIT_ACK] = 0
        return v

    def valid(self) -> bool:
        return bool(self.tt.uio_out[BIT_VALID])


# ---------------------------------------------------------------------------
# The sequence
# ---------------------------------------------------------------------------
class SelfTest:
    def __init__(self, die, verbose: bool = False):
        self.die = die
        self.verbose = verbose
        self.fails = 0
        self.checks = 0
        self.timeouts = 0

    def _wait_valid(self) -> bool:
        deadline = time.time() + VALID_TIMEOUT_S
        while not self.die.valid():
            if time.time() > deadline:
                self.timeouts += 1
                return False
        return True

    def run_case(self, op: int, operands: list[int], expect_words: list[int]) -> bool:
        die = self.die
        die.srst()
        die.set_op(op)
        for w in operands:
            w &= 0xFFFF
            die.write_byte(w & 0xFF)           # low byte first
            die.write_byte((w >> 8) & 0xFF)
        die.start()

        got_words: list[int] = []
        for _ in expect_words:
            if not self._wait_valid():
                self.checks += 1
                self.fails += 1
                print(f"  FAIL {OP_NAMES[op]:6s} operands={operands} "
                      f"VALID never asserted within {VALID_TIMEOUT_S}s")
                return False
            lo = die.read_byte()
            hi = die.read_byte()
            got_words.append((hi << 8) | lo)

        ok = got_words == expect_words
        self.checks += 1
        if not ok:
            self.fails += 1
            print(f"  FAIL {OP_NAMES[op]:6s} operands={operands} "
                  f"got={got_words} want={expect_words}")
        elif self.verbose:
            print(f"  ok   {OP_NAMES[op]:6s} operands={operands} -> {got_words}")
        return ok


def cases() -> list[tuple[int, list[int], list[int]]]:
    """A vector set a human can watch finish.

    A deliberate subset of CI's sweep: the corners where a broken datapath fails
    first, plus interior points. The full 65,536-point sweep belongs in
    simulation; on a bench with a printout the value is in covering each
    operation's hard cases and finishing in seconds.
    """
    angles = [-32768, -16384, -8192, -1, 0, 1, 8192, 16384, 32767]
    vecs: list[tuple[int, list[int], list[int]]] = []
    for ph in angles:
        sn, cs = M.sincos(ph)
        vecs.append((OP_SINCOS, [ph & 0xFFFF], [sn & 0xFFFF, cs & 0xFFFF]))

    pairs = [(-32767, -32767), (-32767, 32767), (32767, -32767), (32767, 32767),
             (0, 32767), (32767, 0), (0, -32768), (-32768, 0), (1, 1),
             (16384, 16384), (-100, 250)]
    for y, x in pairs:
        vecs.append((OP_ATAN2, [y & 0xFFFF, x & 0xFFFF], [M.atan2(y, x) & 0xFFFF]))
        vecs.append((OP_HYPOT, [y & 0xFFFF, x & 0xFFFF], [M.hypot(y, x) & 0xFFFF]))

    muls = [(0, 0), (1, 32767), (-1, 32767), (32767, 32767), (-32768, -32768),
            (16384, 2), (-1234, 5678), (256, -256)]
    for a, b in muls:
        vecs.append((OP_MUL, [a & 0xFFFF, b & 0xFFFF], [M.mul(a, b) & 0xFFFF]))

    return vecs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--virtual", action="store_true",
                    help="run the sequence against the golden model, no hardware")
    ap.add_argument("--defect", action="store_true",
                    help="corrupt the virtual model so this run must FAIL; "
                         "proves the test can detect a fault")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--clock", type=float, default=20e6,
                    help="project clock in Hz (default 20e6, the rated clock)")
    args = ap.parse_args()

    if args.defect and not args.virtual:
        print("--defect requires --virtual", file=sys.stderr)
        return 2

    die = VirtualDie(defect=args.defect) if args.virtual else DemoBoardDie(clock_hz=args.clock)
    t = SelfTest(die, verbose=args.verbose)

    vecs = cases()
    mode = "virtual" if args.virtual else "hardware"
    print(f"tt_um_pryzm_cordic bring-up ({mode}), {len(vecs)} cases")
    print()

    for op, operands, expect in vecs:
        t.run_case(op, operands, expect)

    print()
    print(f"{t.checks - t.fails}/{t.checks} cases pass")
    if t.timeouts:
        print(f"  {t.timeouts} case(s) timed out waiting for VALID - "
              f"the die did not respond")
    if t.fails:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
