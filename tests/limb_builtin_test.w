# wbuild: x64
/*
The 32-bit limb-arithmetic intrinsics (#213):

  mul_hi(a, b)             high 32 bits of the unsigned 32x32 product
  mul_wide(a, b, &hi)      low 32 bits returned, high 32 stored to hi
  add_carry(a, b, &carry)  (a+b) mod 2^32 returned, carry-out stored

All three read only the operands' low 32 bits, as unsigned. Results
follow the masked-32-bit-word convention (lib/sha256.w): the low 32
bits are the meaningful pattern, zero-extended on 64-bit targets. Every
expected value below is therefore built at runtime from the same
patterns (mask32() etc.), so the assertions hold verbatim on the
32-bit x86 target, the 64-bit targets, and arm64.
*/
import lib.testing


# 0xffffffff as this target represents a masked 32-bit word: -1 on the
# 32-bit target (h*h wraps to 0), 4294967294+1 zero-extended on 64-bit.
int mask32():
	int h = 1 << 16
	return h * h - 1


void test_mul_hi_small_products():
	assert_equal(0, mul_hi(0, 0))
	assert_equal(0, mul_hi(3, 5))
	assert_equal(0, mul_hi(mask32(), 0))
	# 65536 * 65536 = 2^32: the first product to reach the high half
	assert_equal(1, mul_hi(1 << 16, 1 << 16))


void test_mul_hi_full_width():
	int m = mask32()
	# (2^32-1)^2 = 0xfffffffe_00000001
	assert_equal(m - 1, mul_hi(m, m))
	# 0x80000000 * 0x80000000 = 2^62: hi = 2^30
	int h = 1 << 31
	assert_equal(1 << 30, mul_hi(h, h))
	assert_equal(1, mul_hi(h, 2))


void test_mul_hi_reads_low_32_bits_only():
	# -1 sign-extends to all ones on the 64-bit targets; only the low
	# 32 bits (0xffffffff) may participate: 0xffffffff * 2 = 0x1_fffffffe
	assert_equal(1, mul_hi(0 - 1, 2))
	assert_equal(mask32() - 1, mul_hi(0 - 1, 0 - 1))


void test_mul_wide():
	int hi = 7
	assert_equal(15, mul_wide(3, 5, &hi))
	assert_equal(0, hi)
	int m = mask32()
	# (2^32-1)^2 = 0xfffffffe_00000001
	assert_equal(1, mul_wide(m, m, &hi))
	assert_equal(m - 1, hi)
	# lo agrees with the wrapped `*` product's low 32 bits
	int a = 305419896   # 0x12345678
	int b = 461845907   # 0x1b873593
	int lo = mul_wide(a, b, &hi)
	assert_equal((a * b) & mask32(), lo & mask32())
	assert_equal(mul_hi(a, b), hi)


void test_add_carry():
	int c = 9
	assert_equal(8, add_carry(3, 5, &c))
	assert_equal(0, c)
	int m = mask32()
	# 0xffffffff + 1 wraps to 0 with carry-out
	assert_equal(0, add_carry(m, 1, &c))
	assert_equal(1, c)
	# 0xffffffff + 0xffffffff = 0x1_fffffffe
	assert_equal(m - 1, add_carry(m, m, &c))
	assert_equal(1, c)
	# carry out of bit 31: 0x80000000 + 0x80000000 = 0x1_00000000
	int h = 1 << 31
	assert_equal(0, add_carry(h, h, &c))
	assert_equal(1, c)
	# ... but not out of bit 30
	int q = 1 << 30
	assert_equal(h, add_carry(q, q, &c))
	assert_equal(0, c)


void test_add_carry_reads_low_32_bits_only():
	int c = 9
	# sign-extended -1 operands: low halves are 0xffffffff
	assert_equal(mask32() - 1, add_carry(0 - 1, 0 - 1, &c))
	assert_equal(1, c)


void test_carry_chain_ripple():
	# [0xffffffff, 0xffffffff, 0xffffffff] + 1 = [0, 0, 0] carry 1
	int m = mask32()
	int[3] limbs
	limbs[0] = m
	limbs[1] = m
	limbs[2] = m
	int carry = 1
	int i = 0
	while (i < 3):
		int c = 0
		limbs[i] = add_carry(limbs[i], carry, &c)
		carry = c
		i = i + 1
	assert_equal(0, limbs[0])
	assert_equal(0, limbs[1])
	assert_equal(0, limbs[2])
	assert_equal(1, carry)


# Schoolbook 96x96 -> 192-bit multiply on full 32-bit limbs: the shape
# the crypto modules migrate to (#194/#196/#197). out has 6 limbs, and
# each partial product's carries ripple up until absorbed.
void mul_limbs_3x3(int* a, int* b, int* out):
	int i = 0
	while (i < 6):
		out[i] = 0
		i = i + 1
	i = 0
	while (i < 3):
		int j = 0
		while (j < 3):
			int hi = 0
			int lo = mul_wide(a[i], b[j], &hi)
			int c = 0
			out[i + j] = add_carry(out[i + j], lo, &c)
			int k = i + j + 1
			while ((c != 0) | (hi != 0)):
				int add = hi
				hi = 0
				int c1 = 0
				out[k] = add_carry(out[k], add, &c1)
				int c2 = 0
				out[k] = add_carry(out[k], c, &c2)
				# c1 and c2 are never both set: a first-add carry
				# leaves out[k] below 0xffffffff
				c = c1 + c2
				k = k + 1
			j = j + 1
		i = i + 1


void test_schoolbook_multiply():
	# (2^96-1)^2 = 2^192 - 2^97 + 1 = [1, 0, 0, 0xfffffffe, -1, -1]
	int m = mask32()
	int[3] a
	int[3] b
	int[6] out
	a[0] = m
	a[1] = m
	a[2] = m
	b[0] = m
	b[1] = m
	b[2] = m
	mul_limbs_3x3(a, b, out)
	assert_equal(1, out[0])
	assert_equal(0, out[1])
	assert_equal(0, out[2])
	assert_equal(m - 1, out[3])
	assert_equal(m, out[4])
	assert_equal(m, out[5])
	# (2^32+2)(2^32+3) = 2^64 + 5*2^32 + 6 = [6, 5, 1, 0, 0, 0]
	a[0] = 2
	a[1] = 1
	a[2] = 0
	b[0] = 3
	b[1] = 1
	b[2] = 0
	mul_limbs_3x3(a, b, out)
	assert_equal(6, out[0])
	assert_equal(5, out[1])
	assert_equal(1, out[2])
	assert_equal(0, out[3])


void test_intrinsics_compose_in_expressions():
	# results are ordinary int values: usable inline, as arguments, and
	# with the same intrinsic feeding another call
	int c = 0
	assert_equal(1, mul_hi(add_carry(mask32(), 1, &c), 1 << 16) + mul_hi(1 << 16, 1 << 16))
	assert_equal(1, c)
	int hi = 0
	# lo(1*2) = 2, hi32(2^17 * 2^16) = hi32(2^33) = 2
	assert_equal(4, mul_wide(1, 2, &hi) * mul_hi(1 << 17, 1 << 16))
