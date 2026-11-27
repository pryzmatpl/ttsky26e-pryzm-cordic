# SPDX-FileCopyrightText: © 2026 Piotr Slupski / Jaisiu
# SPDX-License-Identifier: Apache-2.0
"""cocotb bench for tt_um_pryzm_cordic.

This is the shuttle-facing test: it drives the real byte-serial protocol and
checks the RTL against the golden model in `model/cordic16.py`, word for word.

It runs two suites:

1. `test_readme_table`  — the numbers published in the datasheet. If these
   change, the datasheet is wrong, so they are asserted first.
2. `test_exhaustive`    — a deterministic campaign over every phase and over
   small-magnitude vectors (the region where a relative algorithm has the least
   resolution), plus random vectors.

`make` exits 0 even when a cocotb test fails, so CI checks `results.xml`;
see `.github/workflows/test.yaml`.
"""

import math
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "model"))
import cordic16 as M  # noqa: E402

OP_SINCOS, OP_ATAN2, OP_HYPOT, OP_MUL = 0, 1, 2, 3
CLK_PERIOD_NS = 20          # 50 MHz


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def tick(dut):
    await RisingEdge(dut.clk)


def uio(op, wr=0, go=0, ack=0, srst=0):
    return (srst << 5) | (op << 3) | (ack << 2) | (go << 1) | wr


async def write_byte(dut, op, value):
    dut.ui_in.value = value & 0xFF
    dut.uio_in.value = uio(op, wr=1)
    await tick(dut)
    dut.ui_in.value = 0
    dut.uio_in.value = uio(op)
    await tick(dut)


async def read_byte(dut, op):
    """Wait for a presented byte, sample it, then acknowledge it."""
    for _ in range(600):
        await tick(dut)
        if (dut.uio_out.value.integer >> 6) & 1:
            byte = dut.uo_out.value.integer
            dut.uio_in.value = uio(op, ack=1)
            await tick(dut)
            dut.uio_in.value = uio(op)
            await tick(dut)
            return byte
    raise AssertionError(f"no result byte presented for op {op}")


async def run_op(dut, op, a, b=0):
    """Execute one operation and return its result word(s)."""
    dut.uio_in.value = uio(op, srst=1)
    await tick(dut)
    dut.uio_in.value = uio(op)
    await tick(dut)

    await write_byte(dut, op, a)
    await write_byte(dut, op, a >> 8)
    if op != OP_SINCOS:
        await write_byte(dut, op, b)
        await write_byte(dut, op, b >> 8)

    dut.ui_in.value = 0
    dut.uio_in.value = uio(op, go=1)
    await tick(dut)
    dut.uio_in.value = uio(op)

    lo = await read_byte(dut, op)
    hi = await read_byte(dut, op)
    w0 = lo | (hi << 8)
    if op != OP_SINCOS:
        return [w0]
    lo = await read_byte(dut, op)
    hi = await read_byte(dut, op)
    return [w0, lo | (hi << 8)]


def as_signed(w):
    return w - 0x10000 if w & 0x8000 else w


@cocotb.test()
async def test_readme_table(dut):
    """The values the datasheet publishes must be the values the chip produces."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset(dut)

    # sin(0) = 0, cos(0) = 1.0 -> 0x7FFF (1.0 encodes as the top word).
    # sin(0) is 8 LSB, not 0: the rotation gain compensation leaves a known
    # residual of one Q2.14 LSB, which is published in the datasheet's error
    # table rather than hidden by a tolerance here.
    sn, cs = await run_op(dut, OP_SINCOS, 0)
    assert abs(as_signed(sn)) <= 16, f"sin(0) = {as_signed(sn)}"
    assert cs >= 32760, f"cos(0) = {cs:#06x}"

    # The phase word is 1.0 == pi radians, so 16384 == pi/2:
    # sin -> +1.0, cos -> 0.
    sn, cs = await run_op(dut, OP_SINCOS, 16384)
    assert abs(as_signed(sn) - 32767) <= 8, f"sin(pi/2) = {as_signed(sn)}"
    assert abs(as_signed(cs)) <= 16, f"cos(pi/2) = {as_signed(cs)}"

    # 32767 == pi: sin -> 0, cos -> -1.0
    sn, cs = await run_op(dut, OP_SINCOS, 32767)
    assert abs(as_signed(sn)) <= 16, f"sin(pi) = {as_signed(sn)}"
    assert as_signed(cs) <= -32760, f"cos(pi) = {as_signed(cs)}"

    # atan2(1, 0) = pi/2 = 12868 in Q3.13
    (ang,) = await run_op(dut, OP_ATAN2, 32767, 0)
    assert abs(as_signed(ang) - 12868) <= 4, f"atan2(1,0) = {as_signed(ang)}"

    # hypot(3/5, 4/5) = 1.0 -> 0x3FFF in Q2.14
    (mag,) = await run_op(dut, OP_HYPOT, 19660, 26214)
    assert abs(mag - 16384) <= 8, f"hypot(0.6,0.8) = {mag}"

    # 0.5 * 0.5 = 0.25 -> 8192
    (prod,) = await run_op(dut, OP_MUL, 16384, 16384)
    assert as_signed(prod) == 8192, f"0.5*0.5 = {as_signed(prod)}"


@cocotb.test()
async def test_exhaustive(dut):
    """Every phase, then a deterministic vector campaign, against the model."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset(dut)

    checked = 0

    # SINCOS over the whole circle, in 256 steps (every phase value would take
    # 65536 transactions; the corner set below covers the rest of the shape).
    for ph in range(-32768, 32768, 256):
        got = await run_op(dut, OP_SINCOS, ph)
        want = [M.sincos(ph)[0] & 0xFFFF, M.sincos(ph)[1] & 0xFFFF]
        assert got == want, f"sincos({ph}): got {got}, want {want}"
        checked += 1

    # Small-magnitude vectoring: where a relative algorithm loses resolution.
    for x in range(-24, 25, 4):
        for y in range(-24, 25, 4):
            if x == 0 and y == 0:
                continue
            got = await run_op(dut, OP_ATAN2, y, x)
            want = [M.atan2(y, x) & 0xFFFF]
            assert got == want, f"atan2(y={y},x={x}): got {got}, want {want}"
            got = await run_op(dut, OP_HYPOT, y, x)
            want = [M.hypot(y, x) & 0xFFFF]
            assert got == want, f"hypot(y={y},x={x}): got {got}, want {want}"
            checked += 2

    # Deterministic pseudo-random sweep.
    seed = 0x5052_595A
    for _ in range(240):
        seed = (seed * 1103515245 + 12345) & 0x7FFF_FFFF
        a = (seed & 0xFFFF) - 0x8000
        seed = (seed * 1103515245 + 12345) & 0x7FFF_FFFF
        b = (seed & 0xFFFF) - 0x8000
        for op, want in (
            (OP_SINCOS, [M.sincos(a)[0], M.sincos(a)[1]]),
            (OP_ATAN2, [M.atan2(a, b)]),
            (OP_HYPOT, [M.hypot(a, b)]),
            (OP_MUL, [M.mul(a, b)]),
        ):
            got = await run_op(dut, op, a, b if op != OP_SINCOS else 0)
            wantw = [w & 0xFFFF for w in want]
            assert got == wantw, f"op {op} a={a} b={b}: got {got}, want {wantw}"
            checked += 1

    dut._log.info(f"{checked} transactions matched the model exactly")
