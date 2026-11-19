#!/usr/bin/env python3
"""Exact IEEE-754 binary32 reference model built on Python rationals.

Every operation is computed exactly with fractions.Fraction and then rounded
straight from the definition in the standard, so it shares no structure (GRS
bits, alignment shifters, ...) with the RTL it checks.
"""
from fractions import Fraction

RNE, RTZ, RDN, RUP, RMM = range(5)
NV, DZ, OF, UF, NX = 16, 8, 4, 2, 1
QNAN = 0x7FC00000
EMIN, EMAX, P = -126, 127, 24


def classify(x):
    s, e, f = x >> 31, (x >> 23) & 0xFF, x & 0x7FFFFF
    if e == 255:
        return ("nan" if f else "inf"), s, None, (f >> 22) == 0 and f != 0
    if e == 0:
        return ("zero" if f == 0 else "num"), s, Fraction(f, 1 << 149), False
    return "num", s, Fraction((1 << 23) | f) * Fraction(2) ** (e - 150), False


def _round_int(q, sign, rm):
    """Round non-negative rational q to an integer; return (int, inexact)."""
    m = q.numerator // q.denominator
    rest = q - m
    if rest == 0:
        return m, False
    half = Fraction(1, 2)
    if rm == RNE:
        up = rest > half or (rest == half and (m & 1))
    elif rm == RTZ:
        up = False
    elif rm == RDN:
        up = bool(sign)
    elif rm == RUP:
        up = not sign
    else:
        up = rest >= half
    return m + (1 if up else 0), True


def round_pack(sign, mag, rm):
    """Round a positive rational magnitude to binary32. Returns (bits, flags)."""
    e = mag.numerator.bit_length() - mag.denominator.bit_length()
    if Fraction(2) ** e > mag:
        e -= 1
    # rounding with an unbounded exponent range
    m, inexact = _round_int(mag / Fraction(2) ** (e - (P - 1)), sign, rm)
    eu = e + 1 if m == (1 << P) else e
    if m == (1 << P):
        m >>= 1
    tiny = eu < EMIN            # tininess detected after rounding
    if e >= EMIN:
        if eu > EMAX:
            to_inf = rm in (RNE, RMM) or (rm == RDN and sign) or (rm == RUP and not sign)
            return (sign << 31) | (0x7F800000 if to_inf else 0x7F7FFFFF), OF | NX
        return (sign << 31) | ((eu + 127) << 23) | (m & 0x7FFFFF), NX if inexact else 0
    # subnormal range: quantum is 2^-149
    m, inexact = _round_int(mag * (1 << 149), sign, rm)
    flags = (NX if inexact else 0) | (UF if (inexact and tiny) else 0)
    return (sign << 31) | m, flags


def fp_op(op, rm, a, b):
    ca, sa, va, siga = classify(a)
    cb, sb, vb, sigb = classify(b)
    if ca == "nan" or cb == "nan":
        return QNAN, (NV if (siga or sigb) else 0)
    inf = lambda s: (s << 31) | 0x7F800000
    zero = lambda s: s << 31
    sx = sa ^ sb
    if op in (0, 1):
        if op == 1:
            sb ^= 1
        if ca == "inf" and cb == "inf":
            return (inf(sa), 0) if sa == sb else (QNAN, NV)
        if ca == "inf":
            return inf(sa), 0
        if cb == "inf":
            return inf(sb), 0
        r = (-va if sa else va) + (-vb if sb else vb)
        if r == 0:
            if ca == "zero" and cb == "zero" and sa == sb:
                return zero(sa), 0
            return zero(1 if rm == RDN else 0), 0
        return round_pack(1 if r < 0 else 0, abs(r), rm)
    if op == 2:
        if (ca == "inf" and cb == "zero") or (ca == "zero" and cb == "inf"):
            return QNAN, NV
        if ca == "inf" or cb == "inf":
            return inf(sx), 0
        if ca == "zero" or cb == "zero":
            return zero(sx), 0
        return round_pack(sx, va * vb, rm)
    if (ca == "inf" and cb == "inf") or (ca == "zero" and cb == "zero"):
        return QNAN, NV
    if ca == "inf":
        return inf(sx), 0
    if cb == "inf" or ca == "zero":
        return zero(sx), 0
    if cb == "zero":
        return inf(sx), DZ
    return round_pack(sx, va / vb, rm)
