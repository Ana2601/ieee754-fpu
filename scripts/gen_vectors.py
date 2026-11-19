#!/usr/bin/env python3
"""Constrained-random vector generator for the FPU (uses fp_ref as golden model).

Also cross-checks the golden model itself against the host's IEEE hardware
(numpy float32, round-to-nearest-even) when numpy is available.
"""
import random
import struct
import sys

from fp_ref import fp_op

SPECIALS = [0x00000000, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7FA00000, 0xFFC00001,
            0x00000001, 0x80000001, 0x007FFFFF, 0x00800000, 0x80800000, 0x7F7FFFFF, 0xFF7FFFFF,
            0x3F800000, 0xBF800000, 0x3F7FFFFF, 0x3F800001, 0x40000000, 0x00FFFFFF, 0x01000000]


def rand_operand(rng):
    k = rng.randrange(10)
    if k == 0:
        return rng.choice(SPECIALS)
    if k == 1:   # subnormal
        return (rng.getrandbits(1) << 31) | rng.getrandbits(23)
    if k == 2:   # tiny normal
        return (rng.getrandbits(1) << 31) | (rng.randrange(1, 30) << 23) | rng.getrandbits(23)
    if k == 3:   # huge
        return (rng.getrandbits(1) << 31) | (rng.randrange(225, 255) << 23) | rng.getrandbits(23)
    if k == 4:   # sparse significand -> exact results and rounding ties
        return (rng.getrandbits(1) << 31) | (rng.randrange(100, 160) << 23) | (rng.getrandbits(3) << rng.randrange(21))
    if k in (5, 6):  # mid-range exponents so add/sub alignment paths are all hit
        return (rng.getrandbits(1) << 31) | (rng.randrange(110, 145) << 23) | rng.getrandbits(23)
    return rng.getrandbits(32)


def rand_pair(rng):
    a = rand_operand(rng)
    k = rng.randrange(8)
    if k == 0:   # near-cancellation: b within a few ulps / one binade of a
        b = ((a ^ (rng.getrandbits(1) << 31)) + rng.randrange(-4, 5)) & 0xFFFFFFFF
    elif k == 1:
        b = (a & 0x807FFFFF) | ((((a >> 23) & 0xFF) + rng.randrange(-2, 3)) & 0xFF) << 23
        b ^= rng.getrandbits(1) << 31
    else:
        b = rand_operand(rng)
    return a, b


def self_check(n=20000, seed=7):
    try:
        import numpy as np
    except ImportError:
        print("numpy not available - skipping reference-model self check")
        return
    rng = random.Random(seed)
    f = lambda x: np.frombuffer(struct.pack("<I", x), dtype=np.float32)[0]
    u = lambda x: struct.unpack("<I", np.float32(x).tobytes())[0]
    ops = [lambda x, y: x + y, lambda x, y: x - y, lambda x, y: x * y, lambda x, y: x / y]
    bad = 0
    with np.errstate(all="ignore"):
        for _ in range(n):
            a, b = rand_pair(rng)
            op = rng.randrange(4)
            got = u(ops[op](f(a), f(b)))
            exp, _ = fp_op(op, 0, a, b)
            if exp == 0x7FC00000:
                ok = (got & 0x7F800000) == 0x7F800000 and (got & 0x7FFFFF) != 0
            else:
                ok = got == exp
            if not ok:
                bad += 1
                print(f"model mismatch op={op} a={a:08x} b={b:08x} numpy={got:08x} model={exp:08x}")
    print(f"reference model vs numpy float32 (RNE): {n - bad}/{n} agree")
    if bad:
        sys.exit(1)


def main(path, n=40000, seed=1):
    self_check()
    rng = random.Random(seed)
    with open(path, "w") as fh:
        for i in range(n):
            a, b = rand_pair(rng)
            op, rm = rng.randrange(4), rng.randrange(5)
            res, flags = fp_op(op, rm, a, b)
            fh.write(f"{op} {rm} {a:08x} {b:08x} {res:08x} {flags:02x}\n")
    print(f"wrote {n} vectors to {path}")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 40000,
         int(sys.argv[3]) if len(sys.argv) > 3 else 1)
