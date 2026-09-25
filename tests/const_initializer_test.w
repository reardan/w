# wbuild: x64 arch=arm64 arch=wasm
# wbuild: step="bin/wv2 tests/const_initializer_overflow_fixture.w -o bin/const_initializer_overflow_fixture" expect_fail expect_stderr="initializer for global 'too_big': constant expression overflows 32 bits"
# wbuild: step="bin/wv2 tests/const_initializer_variable_fixture.w -o bin/const_initializer_variable_fixture" expect_fail expect_stderr="initializer for global 'derived' must be a compile-time constant, got 'mutable_base'"
# wbuild: step="bin/wv2 tests/const_initializer_divzero_fixture.w -o bin/const_initializer_divzero_fixture" expect_fail expect_stderr="enum value 'broken': division by zero in constant expression"
# wbuild: step="bin/wv2 tests/enum_name_error_fixture.w -o bin/enum_name_error_fixture" expect_fail expect_stderr="enum_name argument must be an enum value, got 'int'"
# Compile-time constant expressions in global initializers, parameter
# defaults and enum values (grammar/program.w): arithmetic, shifts,
# bit operations, unary minus/~, parentheses, sizeof, __word_size__,
# enum constants and earlier const globals fold at compile time. Also
# enum_name(e) reflection (grammar/print_builtin.w).
import lib.testing


const int KB = 1024
const int PAGE = 4 * KB
int buffer_words = PAGE / __word_size__
const int MASK = (1 << 12) - 1
const int FLAGS = 0x0f & ~0x3 | 0x100
const int NEG = -(3 + 4) * 2
const int SHIFTED = -64 >> 3
const int MODULO = 17 % 5
const char NEXT_LETTER = 'a' + 1
const int WORDS = sizeof(int) + sizeof(char)


enum perm:
	perm_read = 1 << 2
	perm_write = 1 << 1
	perm_exec = 1
	perm_all = perm_read | perm_write | perm_exec
	perm_after


const int ALL_TWICE = perm_all * 2
const int MIN32 = -2147483647 - 1
const int XOR = 0xff ^ 0x0f
bool ENABLED = true
const bool DISABLED = false


int with_default(int x = 2 * 21):
	return x


void test_arithmetic_folds():
	assert_equal(4096, PAGE)
	assert_equal(4096 / __word_size__, buffer_words)
	assert_equal(4095, MASK)
	assert_equal(0x10c, FLAGS)
	assert_equal(-14, NEG)
	assert_equal(-8, SHIFTED)
	assert_equal(2, MODULO)
	assert_equal('b', NEXT_LETTER)
	assert_equal(__word_size__ + 1, WORDS)
	assert_equal(0xf0, XOR)
	assert_equal(1, ENABLED)
	assert_equal(0, DISABLED)
	assert_equal(1, MIN32 < 0)
	assert_equal(-1, MIN32 - 1 + 1 >> 31)


void test_enum_values_fold():
	assert_equal(4, perm_read)
	assert_equal(2, perm_write)
	assert_equal(7, perm_all)
	assert_equal(8, perm_after)
	assert_equal(14, ALL_TWICE)


void test_parameter_default_folds():
	assert_equal(42, with_default())
	assert_equal(5, with_default(5))


enum shade:
	shade_light
	shade_dark = 10
	shade_black
	shade_alias = 10


void test_enum_name():
	shade s = shade_black
	assert_strings_equal(c"shade_black", enum_name(s))
	assert_strings_equal(c"shade_light", enum_name(shade_light))
	# the first name of a shared value wins
	assert_strings_equal(c"shade_dark", enum_name(shade_alias))
	assert_strings_equal(c"perm_all", enum_name(perm_all))
	# a value no constant carries renders as its digits
	assert_strings_equal(c"99", enum_name(cast(shade, 99)))
	assert_strings_equal(c"-3", enum_name(cast(shade, -3)))
	assert_strings_equal(c"color shade_dark", f"color {enum_name(shade_dark)}")
