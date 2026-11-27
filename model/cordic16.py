"""tt_um_pryzm_cordic — 16-bit golden model, integer-exact. Reference for the RTL.

`src/project.v` must produce the *same words*. `test/test.py` compares them
word for word; there is no tolerance in that test.

## Scale bookkeeping (every line below cites its format)

| name | format | 1.0 == | note |
|---|---|---|---|
| `Q14` | Q2.14 | 16384 | x, y, hypot result |
| `Q13` | Q3.13 | 8192 | z (radians), atan2 result |
| `Q15` | Q1.15 | 32768 | sin, cos, mul operands, phase word |

Conversions used here and in the RTL:

- `Q14 -> Q15` : `<< 1`   (Q1.15 is finer)
- `Q15 -> Q14` : `>> 1`
- `Q15 -> Q13` : `>> 2`
- `Q14 * Q14 -> Q14` : `>> 14`

## Why the rotation starts at 1/K

The rotation mode multiplies the vector's magnitude by K = 1.6468. Feeding
`x0 = 1/K` makes `|out| = 1.0` by construction, so the gain is compensated
once, in a constant, instead of by a per-stage multiplier.

## Why the registers are wider than 16 bits

`K` pushes `|x|,|y|` to 1.65 and an intermediate reaches ~2.3. A 16-bit Q1.15
register would wrap (`s16(32768) = -32768`, i.e. `cos(0) = -1.0`); the model
and the RTL therefore carry 20-bit registers and narrow only the result.
"""

import math

IT = 15                       # stages: stage 15's atan() is 0 LSB, stage 14's is 1
REG_W = 20
REG_MIN, REG_MAX = -(1 << (REG_W - 1)), (1 << (REG_W - 1)) - 1

ATAN = [round(math.atan(2.0 ** -i) * 8192) for i in range(IT)]     # Q13
K = 1.0
for _i in range(IT):
    K *= math.sqrt(1 + 2.0 ** (-2 * _i))
KINV = round((1.0 / K) * 16384)      # Q14  = 9949
PI_Z = round(math.pi * 8192)         # Q13  = 25736
HALF_Z = round(math.pi / 2 * 8192)   # Q13  = 12868
PI_Q15 = round(math.pi * 32768)      # not used numerically; documented for users
PI_MUL = round(math.pi * 8192)       # Q15 phase * PI_MUL >> 15 -> Q13 radians (== PI_Z)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def sat16(v):
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)


def satreg(v):
    return REG_MAX if v > REG_MAX else (REG_MIN if v < REG_MIN else v)


def ash(v, n):
    """Arithmetic right shift, truncating (toward -inf) — what the RTL does."""
    return v >> n


def rot(x, y, z):
    """Rotation mode. x,y Q14, z Q13. Returns x,y Q14."""
    for i in range(IT):
        xi, yi = ash(x, i), ash(y, i)
        if z >= 0:
            x, y, z = satreg(x - yi), satreg(y + xi), z - ATAN[i]
        else:
            x, y, z = satreg(x + yi), satreg(y - xi), z + ATAN[i]
    return x, y


def vec(x, y):
    """Vectoring mode, valid for 0 <= y <= x. Returns (x Q14, angle Q13)."""
    z = 0
    for i in range(IT):
        xi, yi = ash(x, i), ash(y, i)
        if y < 0:
            x, y, z = satreg(x - yi), satreg(y + xi), z - ATAN[i]
        else:
            x, y, z = satreg(x + yi), satreg(y - xi), z + ATAN[i]
    return x, z


def absang(ax, ay):
    """atan of two non-negative Q14 operands -> Q13 in [0, pi/2].

    `vec` converges only while |y| <= |x|, so the 45..90 degree octant is
    `pi/2 - atan(x/y)`: one compare and one subtract, both exact.
    """
    if ay <= ax:
        return vec(ax, ay)[1]
    return HALF_Z - vec(ay, ax)[1]


def prescale(x, y, lo):
    """Shift a Q14 vector into [lo, hi] on its largest component.

    CORDIC precision is *relative*: a vector of magnitude 0.001 cannot resolve
    an angle better than ~1/1000 rad. Shifting it up is exact (power of two) and
    costs two compares. `hi` leaves headroom for K inside the register.

    Returns `(x, y, n)` where `n` is negative for up-shifts. A caller that needs
    the *magnitude* in the original scale must undo them, which is why `n` is
    returned rather than silently applied. The registers are 20-bit, so no
    down-shift is ever needed: K * sqrt(2) * 16383 = 38160 still fits.
    """
    m = max(abs(x), abs(y))
    n = 0
    while 0 < m < lo and n > -4:          # at most 4 up-shifts == a 4-bit barrel shifter
        x, y, m, n = x * 2, y * 2, m * 2, n - 1
    return x, y, n


def sincos(phase):
    """phase Q15, 1.0 == pi radians -> (sin Q15, cos Q15)."""
    z = (phase * PI_MUL) >> 15                   # Q13 radians, |z| <= pi
    q = 1 if z > HALF_Z else (-1 if z < -HALF_Z else 0)
    r = z - q * HALF_Z                           # |r| <= pi/2
    x, y = rot(KINV, 0, r)                       # gain-compensated: |out| == 1.0
    if q == 0:
        sn, cs = y, x
    elif q == 1:
        sn, cs = x, -y
    else:
        sn, cs = -x, y
    return sat16(sn << 1), sat16(cs << 1)        # Q14 -> Q15


def atan2(yq, xq):
    """Q15 operands -> angle Q13 radians."""
    if xq == 0 and yq == 0:
        return 0
    ax, ay, _ = prescale(abs(xq) >> 1, abs(yq) >> 1, 4096)   # Q15 -> Q14
    a = absang(ax, ay)
    if xq >= 0:
        return sat16(a if yq >= 0 else -a)
    off = PI_Z - a
    return sat16(off if yq >= 0 else -off)


def hypot(yq, xq):
    """Q15 operands -> sqrt(x^2+y^2) Q14, saturating at 2.0."""
    ax, ay, n = prescale(abs(xq) >> 1, abs(yq) >> 1, 4096)
    v = vec(ax, ay)[0] if ax >= ay else vec(ay, ax)[0]
    mag = (v * KINV) >> 14                      # Q14*Q14 >> 14 -> Q14, K divided out
    mag = ash(mag, -n) if n < 0 else mag          # undo the up-shifts (n <= 0)
    return sat16(mag)


def mul(a, b):
    """Q15 * Q15 -> Q15, truncating."""
    return sat16((a * b) >> 15)


def _selftest():
    import random

    es = ec = 0.0
    for k in range(-16384, 16384):
        sn, cs = sincos(k)
        th = k / 32768.0 * math.pi
        es = max(es, abs(sn - math.sin(th) * 32768))
        ec = max(ec, abs(cs - math.cos(th) * 32768))

    ea = eh = em = 0.0
    wa = wh = None
    random.seed(11)
    for _ in range(100000):
        y = random.randint(-32767, 32767)
        x = random.randint(-32767, 32767)
        if x == 0 and y == 0:
            continue
        a = atan2(y, x)
        ref = math.atan2(y, x)
        d = abs(a / 8192.0 - ref)
        d = min(d, abs(d - 2 * math.pi)) * 8192.0
        if d > ea:
            ea, wa = d, (x, y, a, round(ref * 8192))
        hr = math.hypot(y / 32768.0, x / 32768.0)
        h = hypot(y, x) / 16384.0
        if abs(h - hr) * 16384 > eh:
            eh, wh = abs(h - hr) * 16384, (x, y, round(h, 6), round(hr, 6))
        em = max(em, abs(mul(y, x) - (y * x) / 32768.0))

    print(f"SINCOS sin {es:6.1f}  cos {ec:6.1f} LSB   budget 32.0")
    print(f"ATAN2      {ea:6.1f} LSB = {ea / 8192:.6f} rad   worst {wa}")
    print(f"HYPOT      {eh:6.1f} LSB (Q14)        worst {wh}")
    print(f"MUL        {em:6.1f} LSB")
    print("sincos 0 / 45 / 90 / 180 / pi:",
          sincos(0), sincos(4096), sincos(8192), sincos(16384), sincos(32767))
    print("atan2  (1,1)/(0,1)/(1,0)/(-1,-1)/(0,-1):",
          atan2(23170, 23170), atan2(32767, 0), atan2(0, 32767),
          atan2(-23170, -23170), atan2(0, -32767))
    print("hypot  (1,1)/(0.6,0.8)/(1,0):", hypot(23170, 23170), hypot(19660, 26214), hypot(0, 32767))
    print("mul    0.5*0.5 / 1*-1 / 0:", mul(16384, 16384), mul(32767, -32768), mul(0, 0x1234))


if __name__ == "__main__":
    _selftest()
