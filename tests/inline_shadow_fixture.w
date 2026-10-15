# Fixture of tests/inline_shadow_test.w (not a test by itself): the
# shape of lib/memory_freelist.w's freelist_malloc that --profile-use
# miscompiled on x64. sf_take keeps its local 'block' in a caller-saved
# register; the hot site of sf_push (whose parameter is also named
# 'block') is inlined, and the body's call of sf_slot has to park the
# caller's register around it: the parameter shadowing the name must
# not make the caller's register look dead.

import lib.lib


int[64] sf_heads
int sf_top


# A callee that uses the caller-saved registers itself (its loop keeps
# it a call).
int sf_slot(int size):
	int a = size >> 3
	int b = 0
	int c = 1
	int d = 0
	while (d < a):
		b = b + (c & 3)
		c = c + d
		d = d + 1
	return (a + b + c) & 63


void sf_push(int block, int size):
	int b = sf_slot(size)
	sf_heads[b] = block


int sf_take(int size):
	int header = 16
	int block = sf_top
	# a loop keeps sf_take itself a call
	int spins = 0
	while (spins < (size & 3)): spins = spins + 1
	block = block + spins
	if (block < 0): block = 0
	block = block + (spins & 1)
	if (block > 2000000): block = block - 8
	sf_top = sf_top + size + header
	if (size > 8):
		sf_push(block + header + 8, size - 8)
	int r = block + header
	return r


int main():
	int total = 0
	sf_top = 1000
	for i in range(200000):
		int got = sf_take(16 + (i & 7) * 8)
		total = total + (got & 1023)
		if (sf_top > 1000000): sf_top = 1000
	println(itoa(total))
	return 0
