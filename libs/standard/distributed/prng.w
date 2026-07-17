/*
Seeded deterministic pseudo-random numbers for protocol code
(docs/projects/distributed.md, phase 3).

xorshift32 (Marsaglia 2003, the 13/17/5 triple). NOT cryptographic —
libs/standard/crypto/random.w is the CSPRNG; this exists for the
opposite reason: identical, reproducible sequences from a seed, on
every target, so simulation schedules (sim.w) and election jitter
(raft.w) replay exactly. The state is one 32-bit word kept under the
masked-32-bit-word convention (lib/sha256.w): on the 32-bit target the
mask is the full word and a state with bit 31 set is stored negative;
only the low 32 bits are ever observed, and the logical-shift steps go
through the shr intrinsic so host sign bits never smear in.

Outputs are masked to 31 bits, so every value returned is a
non-negative int with the same numeric value on every target.
*/
import lib.lib
import lib.memory
import lib.assert


struct prng:
	int state   # masked 32-bit xorshift word, never zero


# 0xffffffff as this target represents a masked 32-bit word
# (identity mask on the 32-bit target, where h * h wraps to 0).
int prng_mask32():
	int h = 1 << 16
	return h * h - 1


int prng_mask31():
	int q = 1 << 30
	return (q - 1) + q


# Any seed is accepted; seed 0 (xorshift's one forbidden state) maps to
# a fixed nonzero constant so prng_new(0) is still valid and
# deterministic.
prng* prng_new(int seed):
	prng* p = new prng()
	p.state = seed & prng_mask32()
	if (p.state == 0):
		p.state = 305419896   # 0x12345678
	return p


void prng_free(prng* p):
	free(p)


# Next value: uniform over [0, 2^31), non-negative on every target.
int prng_next(prng* p):
	int x = p.state
	x = (x ^ (x << 13)) & prng_mask32()
	x = x ^ shr(x, 17)
	x = (x ^ (x << 5)) & prng_mask32()
	p.state = x
	return x & prng_mask31()


# Uniform-ish over [0, n) — modulo, so a negligible bias for the small
# n protocol code uses (timeout jitter, delivery delays, drop rolls).
int prng_range(prng* p, int n):
	assert1(n >= 1)
	return prng_next(p) % n


# Uniform-ish over [lo, hi] inclusive.
int prng_between(prng* p, int lo, int hi):
	assert1(lo <= hi)
	return lo + prng_range(p, hi - lo + 1)
