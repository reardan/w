# wbuild: arch_only=x64 expect_stdout="dlcall OK"
# lib/dlcall.w: optional libraries at run time. A missing soname or
# symbol is a 0 return, never a loader failure, and the generated
# W->System V trampolines forward register AND stack arguments in order
# (snprintf with 8 arguments puts two on the stack, and is variadic, so
# it also checks al = 0), in both the W-argument and the argv form.
import lib.lib
import lib.assert
import lib.dlcall

type strlen_fn = fn(char*) -> int
type snprintf8_fn = fn(char*, int, char*, int, int, int, int, int) -> int
type abs_fn = fn(int) -> int


int main():
	asserts(c"missing library is non-fatal", cast(int, dl_open(c"libw_no_such_library.so.7")) == 0)
	char* libc = dl_open(c"libc.so.6")
	asserts(c"libc.so.6 opens", cast(int, libc) != 0)
	asserts(c"missing symbol is 0", cast(int, dl_sym(libc, c"w_no_such_symbol")) == 0)
	asserts(c"null sym gives no trampoline", dl_trampoline(cast(char*, 0), 1, 0) == 0)

	strlen_fn* my_strlen = cast(strlen_fn*, dl_trampoline(dl_sym(libc, c"strlen"), 1, 0))
	asserts(c"strlen via trampoline", my_strlen(c"trampoline") == 10)

	# C int result: the upper half of rax is garbage unless sign-extended.
	abs_fn* my_abs = cast(abs_fn*, dl_trampoline(dl_sym(libc, c"abs"), 1, 1))
	asserts(c"abs(-7)", my_abs(-7) == 7)
	asserts(c"abs(INT_MIN+1) through the 32-bit result", my_abs(-2147483647) == 2147483647)

	snprintf8_fn* my_snprintf = cast(snprintf8_fn*, dl_trampoline(dl_sym(libc, c"snprintf"), 8, 1))
	char* buf = malloc(64)
	int n = my_snprintf(buf, 64, c"%d %d %d %d %d", 1, 22, 333, 4444, -5)
	asserts(c"snprintf length", n == 16)
	asserts(c"snprintf text", strcmp(buf, c"1 22 333 4444 -5") == 0)

	# The array form: same call, arguments read from an int array (the
	# shape lib/cublas.w uses for 14-argument gemm calls).
	int snprintf_argv = dl_trampoline_argv(dl_sym(libc, c"snprintf"), 9, 1)
	int[9] args
	args[0] = cast(int, buf)
	args[1] = 64
	args[2] = cast(int, c"%d,%d,%d,%d,%d,%d")
	args[3] = 6
	args[4] = 5
	args[5] = 4
	args[6] = 3
	args[7] = 2
	args[8] = -1
	asserts(c"argv snprintf length", dl_call(snprintf_argv, &args[0]) == 12)
	asserts(c"argv snprintf text", strcmp(buf, c"6,5,4,3,2,-1") == 0)

	# Many stubs share a page; fill past one page to exercise the rollover.
	int i = 0
	while (i < 200):
		strlen_fn* s = cast(strlen_fn*, dl_trampoline(dl_sym(libc, c"strlen"), 7, 0))
		asserts(c"trampoline allocated", cast(int, s) != 0)
		i = i + 1
	asserts(c"earlier stub still valid after rollover", my_strlen(c"ok") == 2)
	println(c"dlcall OK")
	return 0
