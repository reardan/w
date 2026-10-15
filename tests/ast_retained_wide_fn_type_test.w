# wbuild: binary=ast_retained_wide_fn_type_test tag=tests dep=build
# wbuild: step="bin/ast_retained_wide_fn_type_test"
# Regression: a function type with more than 10 parameters. type_rec keeps
# at most 10 parameter types (type_push_function); the retained type notes
# (grammar/retained_ast.w) must not index past them. zstd's huf_compress_f,
# translated by w-private's c_to_w, has 11.
import lib.testing


type wide_fn = fn(int, int, int, int, int, int, int, int, int, int, int) -> int


int sum11(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j, int k):
	return a + b + c + d + e + f + g + h + i + j + k


void test_eleven_parameter_function_type():
	wide_fn* f = cast(wide_fn*, sum11)
	assert_equal(66, f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11))
