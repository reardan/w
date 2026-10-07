# Fixed 32-bit results from the retired AST experiment, now checked against
# the production compiler on both host widths. Do not add an x64 target twin:
# x64 arithmetic intentionally differs for overflow and hardware shift masks.
# wbuild: target=ast_integer32_test tag=tests dep=build_x64
# wbuild: step="bin/wv2 --streaming tests/ast_integer32_test.w -o bin/ast_integer32_test"
# wbuild: step="bin/ast_integer32_test"
# wbuild: step="bin/wv2 --ast-required tests/ast_integer32_test.w -o bin/ast_integer32_required"
# wbuild: step="cmp bin/ast_integer32_test bin/ast_integer32_required"
# wbuild: step="bin/ast_integer32_required"
# wbuild: step="bin/wv2_64 --streaming tests/ast_integer32_test.w -o bin/ast_integer32_legacy_host64"
# wbuild: step="bin/wv2_64 --ast-required tests/ast_integer32_test.w -o bin/ast_integer32_host64"
# wbuild: step="cmp bin/ast_integer32_legacy_host64 bin/ast_integer32_host64"
# wbuild: step="bin/ast_integer32_host64"
import lib.assert


int main():
	assert_equal(14, 2 + 3 * 4)
	assert_equal(20, (2 + 3) * 4)
	assert_equal(12, 20 - 5 - 3)
	assert_equal(18, 20 - (5 - 3))
	assert_equal(10, 120 / 3 / 4)
	assert_equal(-3, -17 / 5)
	assert_equal(-3, 17 / -5)
	assert_equal(-2, -17 % 5)
	assert_equal(2, 17 % -5)
	assert_equal(52, (100 / (3 + 2)) * (7 % 4) - 8)
	assert_equal(7, +(-(-7)))
	assert_equal(-1, ~0)
	assert_equal(2147483648, 2147483647 + 1)
	assert_equal(0, 65536 * 65536)
	assert_equal(-1, 4294967295)
	assert_equal(-1, cast(int, 0xffffffff))
	assert_equal(-2147483648, cast(int, 0x80000000))
	assert_equal(-1, cast(int, 0b11111111111111111111111111111111))
	assert_equal(14, 0000000000000000000000000000014)
	assert_equal(2147483648, 1 << 31)
	assert_equal(-2, -8 >> 2)
	assert_equal(2, 1 << 33)
	assert_equal(207, (0xabcd & 255) | (3 ^ 1))
	assert_equal(1, 1 | 2 ^ 3 & 6)
	assert_equal(1, -1 < 1)
	assert_equal(0, -1 > 1)
	assert_equal(1, 7 <= 7)
	assert_equal(1, 7 >= 7)
	assert_equal(0, 7 < 7)
	assert_equal(0, 7 > 7)
	assert_equal(1, 2147483648 < 2147483647)
	assert_equal(0, 65536 == 0)
	assert_equal(1, 65536 != 0)
	assert_equal(0, !65536)
	assert_equal(1, !0)
	assert_equal(1, true && !false)
	assert_equal(1, 2 && 7)
	assert_equal(1, 2 || 7)
	assert_equal(1, 0 || 65536)
	assert_equal(0, 2 && 0)
	assert_equal(0, 0 && (1 / 0))
	assert_equal(1, 9 || (1 / 0))
	assert_equal(1, 1 && (0 || (5 < 7)))
	assert_equal(1, (0 && (1 / 0)) + (1 || (1 / 0)))
	# Keep a forward short-circuit branch larger than a rel8 displacement.
	assert_equal(1, 1 || (1 / 0 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1))
	return 0
