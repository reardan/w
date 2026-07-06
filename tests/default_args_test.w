# Default parameter values: trailing parameters may declare a compile-time
# constant default ("int times = 1") that direct call sites push when the
# argument is omitted. See docs/projects/default_args_variadics.md.
import lib.testing


int da_add(int base, int bonus = 5):
	return base + bonus


void test_one_default_used_and_overridden():
	assert_equal(15, da_add(10))
	assert_equal(11, da_add(10, 1))


int da_mix(int a, int b = 2, int c = 30, int d = 400):
	return a + b + c + d


void test_multiple_defaults():
	assert_equal(433, da_mix(1))
	assert_equal(438, da_mix(1, 7))
	assert_equal(409, da_mix(1, 7, 1))
	assert_equal(18, da_mix(1, 7, 1, 9))


int da_all_defaulted(int a = 3, int b = 4):
	return a * 10 + b


void test_all_parameters_defaulted():
	assert_equal(34, da_all_defaulted())
	assert_equal(94, da_all_defaulted(9))
	assert_equal(98, da_all_defaulted(9, 8))


char da_sep(char sep = ','):
	return sep


char da_newline(char c = '\n'):
	return c


void test_char_defaults():
	assert_equal(',', da_sep())
	assert_equal(';', da_sep(';'))
	assert_equal(10, da_newline())


int da_shift(int value, int offset = -4, int mask = 0x1f):
	return (value + offset) & mask


void test_negative_and_hex_defaults():
	assert_equal(6, da_shift(10))
	assert_equal(31, da_shift(66, -3))
	assert_equal(63, da_shift(66, -3, 0xff))


enum da_color:
	da_red
	da_green
	da_blue


int da_paint(da_color c = da_green):
	return c


void test_enum_constant_default():
	assert_equal(1, da_paint())
	assert_equal(2, da_paint(da_blue))


struct da_point:
	int x
	int y


int da_point_scaled(da_point* self, int factor = 3):
	return (self.x + self.y) * factor


void test_struct_method_defaults():
	da_point p
	p.x = 2
	p.y = 5
	assert_equal(21, p.scaled())
	assert_equal(70, p.scaled(10))


# Defaults on a prototype apply to calls even when the definition (below)
# repeats none of them: the defaults live on whichever declaration
# provided them.
int da_proto(int a, int b = 6);


int da_call_through_prototype():
	return da_proto(1)


int da_proto(int a, int b):
	return a * 100 + b


void test_prototype_provides_defaults():
	assert_equal(106, da_call_through_prototype())
	assert_equal(106, da_proto(1))
	assert_equal(102, da_proto(1, 2))


# When both prototype and definition declare defaults, the definition's
# values win for every call site compiled after it.
int da_both(int a, int b = 1);


int da_both(int a, int b = 9):
	return a * 10 + b


void test_definition_defaults_win():
	assert_equal(49, da_both(4))
	assert_equal(42, da_both(4, 2))


void test_defaults_in_expressions():
	int total = da_add(1) + da_add(2, 3) * da_all_defaulted()
	assert_equal(6 + 5 * 34, total)
	assert_equal(15, da_add(da_add(5)))
	if (da_add(0) == 5):
		total = da_mix(da_add(0))
	assert_equal(437, total)
