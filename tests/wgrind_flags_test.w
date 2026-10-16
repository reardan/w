# wbuild: x64
import lib.assert
import libs.wgrind.flags


int flags_concrete(int op, int a, int b):
	int result = 0
	int carry = 0
	int overflow = 0
	if (op == WG_AND): result = a & b
	elif (op == WG_OR): result = a | b
	elif (op == WG_XOR): result = a ^ b
	else:
		int sa = a
		int sb = b
		if (a >= 128): sa = a - 256
		if (b >= 128): sb = b - 256
		int signed_result = sa + sb
		result = (a + b) & 255
		carry = a + b > 255
		if (op == WG_SUB):
			signed_result = sa - sb
			result = (a - b) & 255
			carry = a < b
		overflow = (signed_result < -128) || (signed_result > 127)
	int parity = 1
	for i in range(8): parity = parity ^ ((result >> i) & 1)
	return (result == 0) | ((result >= 128) << 1) | (carry << 2) | (overflow << 3) | (parity << 4)


void flags_abstract(int state, wg_value* value):
	int v = 0
	int u = 0
	for i in range(4):
		int bit = i
		if (i == 2): bit = 3
		if (i == 3): bit = 7
		int trit = state % 3
		state = state / 3
		if (trit == 1): v = v | (1 << bit)
		if (trit == 2): u = u | (1 << bit)
	wg_value_set(value, v, u, 123)


void check_flags_oracle():
	wg_context* c = wg_create(1, 1, 0)
	assert1(c != 0)
	assert_equal(0, c.error)
	wg_value a
	wg_value b
	wg_value result
	wg_x64_flags f
	for op in range(WG_AND, WG_SUB + 1):
		for sa in range(81):
			flags_abstract(sa, &a)
			for sb in range(81):
				flags_abstract(sb, &b)
				int combinations = 0
				int auxiliary = 0
				for rawx in range(16):
					int x = (rawx & 3) | ((rawx & 4) << 1) | ((rawx & 8) << 4)
					if ((x & ~a.undefined) != a.value): continue
					for rawy in range(16):
						int y = (rawy & 3) | ((rawy & 4) << 1) | ((rawy & 8) << 4)
						if ((y & ~b.undefined) != b.value): continue
						combinations = combinations | (1 << flags_concrete(op, x, y))
						int af = (x & 15) + (y & 15) > 15
						if (op == WG_SUB): af = (x & 15) < (y & 15)
						auxiliary = auxiliary | (1 << af)
				assert1(wg_binary(c, op, 1, &a, &b, &result))
				assert1(wg_flags_update(c, &f, op, 1, &a, &b, &result, 1))
				assert_equal(combinations, f.combinations)
				if ((op == WG_ADD) || (op == WG_SUB)):
					assert_equal(auxiliary == 3, f.af.undefined)
					int af = (a.value & 15) + (b.value & 15) > 15
					if (op == WG_SUB): af = (a.value & 15) < (b.value & 15)
					assert_equal(af, f.af.value)
				else: assert_equal(1, f.af.undefined)
				int every = 31
				int any = 0
				for state in range(32):
					if ((combinations >> state) & 1):
						every = every & state
						any = any | state
				int unknown = any ^ every
				int actual = flags_concrete(op, a.value, b.value)
				assert_equal(actual & 1, f.zf.value)
				assert_equal((actual >> 1) & 1, f.sf.value)
				assert_equal((actual >> 2) & 1, f.cf.value)
				assert_equal((actual >> 3) & 1, f.of.value)
				assert_equal((actual >> 4) & 1, f.pf.value)
				assert_equal(unknown & 1, f.zf.undefined)
				assert_equal((unknown >> 1) & 1, f.sf.undefined)
				assert_equal((unknown >> 2) & 1, f.cf.undefined)
				assert_equal((unknown >> 3) & 1, f.of.undefined)
				assert_equal((unknown >> 4) & 1, f.pf.undefined)
	wg_destroy(c)


void check_flags_conditions():
	wg_context* c = wg_create(1, 1, 0)
	assert1(c != 0)
	assert_equal(0, c.error)
	wg_x64_flags f
	wg_value a
	wg_value b
	wg_value result
	wg_value condition
	# Either 0 or -128 is less than 1, although CMP makes both SF and
	# OF undefined. Their correlated XOR is a defined signed comparison.
	wg_value_set(&a, 0, 128, 111)
	wg_value_set(&b, 1, 0, 0)
	assert1(wg_binary(c, WG_SUB, 1, &a, &b, &result))
	assert1(wg_flags_update(c, &f, WG_SUB, 1, &a, &b, &result, 1))
	assert_equal(1, f.sf.undefined)
	assert_equal(1, f.of.undefined)
	assert1(wg_flags_condition(c, &f, 12, 2, &condition))
	assert_equal(1, condition.value)
	assert_equal(0, condition.undefined)
	assert1(wg_use(c, &condition, 3))
	assert1(wg_flags_condition(c, &f, 2, 4, &condition))
	assert_equal(1, condition.undefined)
	assert_equal(0, wg_use(c, &condition, 5))
	assert_equal(WG_UNDEFINED, c.error)
	assert_equal(111, c.error_origin)
	wg_clear_error(c)
	wg_flags_forget_joint(&f)
	assert1(wg_flags_condition(c, &f, 12, 6, &condition))
	assert_equal(1, condition.undefined)
	int top = 1 << (__word_size__ * 8 - 1)
	wg_value_set(&a, top - 1, 0, 0)
	assert1(wg_binary(c, WG_ADD, __word_size__, &a, &b, &result))
	assert1(wg_flags_update(c, &f, WG_ADD, __word_size__, &a, &b, &result, 7))
	assert_equal(1, f.of.value)
	assert_equal(0, f.cf.value)
	assert_equal(0, f.of.undefined)
	wg_value_set(&a, -1, 0, 0)
	assert1(wg_binary(c, WG_ADD, __word_size__, &a, &b, &result))
	assert1(wg_flags_update(c, &f, WG_ADD, __word_size__, &a, &b, &result, 8))
	assert_equal(1, f.cf.value)
	assert_equal(1, f.zf.value)
	assert_equal(0, f.of.value)
	# A defined true carry makes BE true even when zero is unknown.
	wg_flags_init(&f, 1, 64, 222)
	assert1(wg_flags_condition(c, &f, 6, 9, &condition))
	assert_equal(1, condition.value)
	assert_equal(0, condition.undefined)
	assert1(wg_flags_condition(c, &f, 7, 10, &condition))
	assert_equal(0, condition.value)
	wg_flags_init(&f, 0, 0, 0)
	wg_value_set(&a, 1, 1, 333)
	wg_flags_preserve_carry(&f, &a)
	assert1(wg_flags_condition(c, &f, 2, 11, &condition))
	assert_equal(1, condition.value)
	assert_equal(1, condition.undefined)
	assert_equal(333, condition.origin)
	assert_equal(0, wg_flags_condition(c, &f, 16, 12, &condition))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


int main():
	check_flags_oracle()
	check_flags_conditions()
	println(c"wgrind_flags_test: OK")
	return 0
