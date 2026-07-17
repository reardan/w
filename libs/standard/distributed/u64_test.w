# wbuild: x64
import lib.testing
import libs.standard.distributed.u64


void test_new_is_zero():
	u64* a = u64_new()
	assert_equal(1, u64_is_zero(a))
	assert_equal(1, u64_fits_int(a))
	assert_equal(0, u64_to_int(a))
	u64_free(a)


void test_set_int_roundtrip():
	u64* a = u64_new_int(123456789)
	assert_equal(0, u64_is_zero(a))
	assert_equal(1, u64_fits_int(a))
	assert_equal(123456789, u64_to_int(a))
	u64_set_int(a, 0)
	assert_equal(1, u64_is_zero(a))
	u64_free(a)


void test_limbs_from_parts():
	int hi = (291 << 16) | 17767           # 0x01234567
	int lo = (35243 << 16) | 52719         # 0x89abcdef (bit 31 set, built at runtime)
	u64* a = u64_new_parts(hi, lo)
	assert_equal(291, a.w3)                # 0x0123
	assert_equal(17767, a.w2)              # 0x4567
	assert_equal(35243, a.w1)              # 0x89ab
	assert_equal(52719, a.w0)              # 0xcdef
	assert_equal(hi, u64_hi32(a))
	# u64_lo32 returns a masked 32-bit word: on a 32-bit host it is the
	# same (negative) int the runtime-built lo already is.
	assert_equal(lo & 65535, u64_lo32(a) & 65535)
	assert_equal((lo >> 16) & 65535, (u64_lo32(a) >> 16) & 65535)
	assert_equal(0, u64_fits_int(a))
	char* h = u64_to_hex(a)
	assert_strings_equal(c"0123456789abcdef", h)
	free(h)
	u64_free(a)


void test_add_carry_chain():
	# 0x00000000ffffffff + 1 = 0x0000000100000000
	u64* a = u64_new_parts(0, (65535 << 16) | 65535)
	u64_inc(a)
	assert_equal(0, a.w0)
	assert_equal(0, a.w1)
	assert_equal(1, a.w2)
	assert_equal(0, a.w3)
	u64_free(a)


void test_add_full_wraparound():
	# max u64 + 1 wraps to zero
	u64* a = u64_new()
	a.w0 = 65535
	a.w1 = 65535
	a.w2 = 65535
	a.w3 = 65535
	u64_inc(a)
	assert_equal(1, u64_is_zero(a))
	u64_free(a)


void test_add_u64():
	u64* a = u64_new_int(1000000000)
	u64* b = u64_new_int(2000000000)
	u64_add(a, b)                          # 3e9 > 2^31: crosses into w1/w2 space
	char* d = u64_to_dec(a)
	assert_strings_equal(c"3000000000", d)
	free(d)
	u64_free(a)
	u64_free(b)


void test_sub_and_borrow():
	u64* a = u64_new_int(1000)
	u64* b = u64_new_int(1)
	assert_equal(0, u64_sub(a, b))
	assert_equal(999, u64_to_int(a))
	# 0 - 1 borrows and wraps to max u64
	u64* z = u64_new()
	assert_equal(1, u64_sub(z, b))
	assert_equal(65535, z.w0)
	assert_equal(65535, z.w1)
	assert_equal(65535, z.w2)
	assert_equal(65535, z.w3)
	u64_free(a)
	u64_free(b)
	u64_free(z)


void test_cmp_orders_across_limbs():
	u64* small = u64_new_parts(0, (65535 << 16) | 65535)   # 0x00000000ffffffff
	u64* big = u64_new_parts(1, 0)                          # 0x0000000100000000
	assert_equal(0 - 1, u64_cmp(small, big))
	assert_equal(1, u64_cmp(big, small))
	assert_equal(0, u64_cmp(small, small))
	assert_equal(1, u64_eq(small, small))
	assert_equal(0, u64_eq(small, big))
	u64_max(small, big)                                     # small = max(small, big)
	assert_equal(1, u64_eq(small, big))
	u64_free(small)
	u64_free(big)


void test_shifts():
	u64* a = u64_new_int(1)
	u64_shl(a, 63)
	assert_equal(32768, a.w3)              # 0x8000
	assert_equal(0, a.w2)
	assert_equal(0, a.w1)
	assert_equal(0, a.w0)
	u64_shr(a, 63)
	assert_equal(1, u64_to_int(a))
	u64_shl(a, 20)
	assert_equal(1048576 & 65535, a.w0)    # bit 20 lives in w1
	assert_equal(16, a.w1)
	u64_shl(a, 64)
	assert_equal(1, u64_is_zero(a))
	u64_set_int(a, 12345)
	u64_shr(a, 64)
	assert_equal(1, u64_is_zero(a))
	u64_free(a)


void test_hlc_style_packing():
	# 48-bit physical ms | 16-bit logical counter round-trips through
	# shifts, the packing clock.w uses.
	u64* ts = u64_new_int(1720000000)      # some "ms" value
	u64_shl(ts, 16)
	u64_add_int(ts, 77)                    # logical counter
	u64* logical = u64_clone(ts)
	# low 16 bits are the counter
	assert_equal(77, logical.w0)
	u64_shr(ts, 16)
	assert_equal(1, u64_fits_int(ts))
	assert_equal(1720000000, u64_to_int(ts))
	u64_free(ts)
	u64_free(logical)


void test_wire_roundtrip():
	int hi = (291 << 16) | 17767           # 0x01234567
	int lo = (35243 << 16) | 52719         # 0x89abcdef
	u64* a = u64_new_parts(hi, lo)
	char* buf = malloc(8)
	u64_save_le(buf, a)
	assert_equal(239, buf[0] & 255)        # 0xef
	assert_equal(205, buf[1] & 255)        # 0xcd
	assert_equal(171, buf[2] & 255)        # 0xab
	assert_equal(137, buf[3] & 255)        # 0x89
	assert_equal(103, buf[4] & 255)        # 0x67
	assert_equal(69, buf[5] & 255)         # 0x45
	assert_equal(35, buf[6] & 255)         # 0x23
	assert_equal(1, buf[7] & 255)          # 0x01
	u64* b = u64_new()
	u64_load_le(b, buf)
	assert_equal(1, u64_eq(a, b))
	free(buf)
	u64_free(a)
	u64_free(b)


void test_to_dec():
	u64* a = u64_new()
	char* d = u64_to_dec(a)
	assert_strings_equal(c"0", d)
	free(d)
	# max u64
	a.w0 = 65535
	a.w1 = 65535
	a.w2 = 65535
	a.w3 = 65535
	d = u64_to_dec(a)
	assert_strings_equal(c"18446744073709551615", d)
	free(d)
	u64_set_int(a, 1000000)
	d = u64_to_dec(a)
	assert_strings_equal(c"1000000", d)
	free(d)
	u64_free(a)
