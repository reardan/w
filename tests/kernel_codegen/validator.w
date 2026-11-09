# Code shapes a kernel's stack validator (objtool) and ORC unwinder
# read, for tests/kernel_codegen_test.w (test_kernel_codegen_validator):
# compiled with --emit=obj --freestanding --kernel-codegen --c-abi, and
# with the thunk-extern return and indirect-branch flags. Enum constants
# (kept out of .text), calls through function pointers with stack
# arguments (the frameless inline C call), C-variadic and many-argument
# extern calls, static and global functions.
type kv_binary = fn(int, int) -> int
type kv_wide = fn(int, int, int, int, int, int, int, int) -> int

extern int kv_c_sum(int n, ...)
extern int kv_c_wide(int a, int b, int c, int d, int e, int f, int g, int h)

enum kv_color:
	kv_red
	kv_green = 5
	kv_blue


static int kv_mul(int a, int b):
	return a * b


int kv_wide8(int a, int b, int c, int d, int e, int f, int g, int h):
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8


int kv_color_value(kv_color c):
	if (c == kv_blue): return 100
	return c


int kv_run(int x):
	kv_binary* op = kv_mul
	kv_wide* wide = kv_wide8
	int total = op(x, 3)
	total = total + wide(1, 2, 3, 4, 5, 6, 7, x)
	total = total + kv_c_sum(9, 1, 2, 3, 4, 5, 6, 7, 8, x)
	total = total + kv_c_wide(x, 1, 1, 1, 1, 1, 1, 2)
	return total + kv_color_value(kv_green) + kv_color_value(kv_blue)
