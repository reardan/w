# wbuild: x64
# wbuild: step="bin/wv2 x64 --pie tests/global_address_init_test.w -o bin/global_address_init_pie_test"
# wbuild: step="bin/global_address_init_pie_test" expect_stdout="global address initializers OK"
# File-scope address initializers (grammar/program.w,
# global_address_initializer): a global word may hold the address of a
# global variable, of a function (defined before or after it), or of a
# c"..." literal, like a C static pointer table. --emit=obj relocates
# the same words (tests/object_file/library.w); here the x86, x64 and
# x64 PIE executables use them directly.
import lib.lib
import lib.assert

type unary = fn(int) -> int

int base = 40
int* base_cell = &base
int** base_cell_cell = &base_cell
char* banner = c"global address initializers OK"
int later(int x);
unary* later_op = later


int earlier(int x):
	return x * 2


unary* earlier_op = earlier


int later(int x):
	return x + 2


int main():
	assert_equal(40, *base_cell)
	base = 41
	assert_equal(41, **base_cell_cell)
	assert_equal(44, later_op(42))
	assert_equal(42, earlier_op(21))
	println(banner)
	return 0
