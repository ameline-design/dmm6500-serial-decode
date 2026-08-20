#!/usr/bin/env python3
"""MT19937, seeded by an integer key array, producing the reference sequence.

THE TWIN OF tools/mt19937.lua, AND THE OUTPUTS MUST MATCH WORD FOR WORD. The hardware sweep is
driven from here and the offline suites draw in Lua, so `iteration 129` only names one experiment if
both sides agree. tools/test_soakrand.py is what holds them together; it compares this against
CPython's random module -- which is this algorithm -- and then Lua against this.

WHY NOT random.Random. Nothing here is wrong with it; the Lua side is the constraint. 5.0.2 has no
bitwise operators, so its twin is arithmetic-on-doubles, and the only way to know that port is right
is to have something on this side that is deliberately the same algorithm rather than the same idea.

This module is idiomatic Python on purpose. The Lua file carries the exactness argument, because it
is the side where a product over 2^53 would silently lose the low bits it carries forward; here
integers are arbitrary precision and & 0xffffffff means what it says.
"""
import sys

N, M = 624, 397
MATRIX_A = 0x9908b0df
UPPER, LOWER = 0x80000000, 0x7fffffff
TEMPER_B, TEMPER_C = 0x9d2c5680, 0xefc60000
TWO32 = 1 << 32
MASK = TWO32 - 1


def _init_genrand(s):
    """Knuth's multiplicative fill. mt[0] is the only seed-dependent step."""
    mt = [0] * N
    mt[0] = s & MASK
    for i in range(1, N):
        mt[i] = (1812433253 * (mt[i - 1] ^ (mt[i - 1] >> 30)) + i) & MASK
    return mt


def _init_by_array(key):
    """Seed from a KEY ARRAY, so a decision addressed by (iteration, purpose, index) mixes properly.

    Concatenating those into one integer would make neighbouring cells neighbouring seeds.
    """
    if not key:
        raise ValueError('mt19937: the key array is empty')
    mt = _init_genrand(19650218)
    klen = len(key)
    i, j, k = 1, 0, max(N, klen)
    while k:
        mt[i] = ((mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) * 1664525)) + key[j] + j) & MASK
        i += 1
        j += 1
        if i >= N:
            mt[0] = mt[N - 1]
            i = 1
        if j >= klen:
            j = 0
        k -= 1
    k = N - 1
    while k:
        mt[i] = ((mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) * 1566083941)) - i) & MASK
        i += 1
        if i >= N:
            mt[0] = mt[N - 1]
            i = 1
        k -= 1
    mt[0] = UPPER
    return mt


class MT19937(object):
    def __init__(self, seed):
        """seed is an int or a sequence of ints. An int is wrapped, so a bare int and a one-element
        key are the same stream and there is no second convention to remember."""
        key = [seed] if isinstance(seed, int) else list(seed)
        for k in key:
            if not isinstance(k, int) or k < 0 or k > MASK:
                raise ValueError('mt19937: key words must be ints in [0, 2**32), got %r' % (k,))
        self.mt = _init_by_array(key)
        self.mti = N

    def u32(self):
        if self.mti >= N:
            mt = self.mt
            for kk in range(N - M):
                y = (mt[kk] & UPPER) | (mt[kk + 1] & LOWER)
                mt[kk] = mt[kk + M] ^ (y >> 1) ^ (MATRIX_A if y & 1 else 0)
            for kk in range(N - M, N - 1):
                y = (mt[kk] & UPPER) | (mt[kk + 1] & LOWER)
                mt[kk] = mt[kk + (M - N)] ^ (y >> 1) ^ (MATRIX_A if y & 1 else 0)
            y = (mt[N - 1] & UPPER) | (mt[0] & LOWER)
            mt[N - 1] = mt[M - 1] ^ (y >> 1) ^ (MATRIX_A if y & 1 else 0)
            self.mti = 0
        y = self.mt[self.mti]
        self.mti += 1
        y ^= y >> 11
        y ^= (y << 7) & TEMPER_B
        y ^= (y << 15) & TEMPER_C
        y ^= y >> 18
        return y & MASK

    def float(self):
        """[0,1). One word per draw, not the 53-bit form, so the two implementations stay comparable
        word for word. No decision in the soak plan needs more than 32 bits of resolution."""
        return self.u32() / float(TWO32)

    def below(self, n):
        """An integer in [0, n), REJECTING the ragged tail rather than taking a modulus of the whole
        range. A bare modulus favours the low residues, and a seeded rate draw is only worth having
        if its distribution is the one claimed."""
        if not isinstance(n, int) or n < 1:
            raise ValueError('mt19937 below() wants a positive integer, got %r' % (n,))
        if n == 1:
            return 0
        limit = TWO32 - (TWO32 % n)
        x = self.u32()
        while x >= limit:
            x = self.u32()
        return x % n

    def range(self, lo, hi):
        """Inclusive, for reading at the call site."""
        return lo + self.below(hi - lo + 1)

    def shuffle(self, seq):
        """Fisher-Yates, descending, in place; returns seq so a call reads as a value.

        DESCENDING AND below(i) MATCH THE LUA TWIN EXACTLY. Any other loop order is a different
        permutation from the same seed, which would break the one property this exists for.
        """
        for i in range(len(seq) - 1, 0, -1):
            j = self.below(i + 1)
            seq[i], seq[j] = seq[j], seq[i]
        return seq


def main():
    """Print words from a key given on the command line, for eyeballing against the Lua twin."""
    args = sys.argv[1:]
    if not args:
        print('usage: mt19937.py COUNT KEYWORD [KEYWORD ...]')
        return 2
    count, key = int(args[0]), [int(x) for x in args[1:]] or [0]
    g = MT19937(key)
    for _ in range(count):
        print(g.u32())
    return 0


if __name__ == '__main__':
    sys.exit(main())
