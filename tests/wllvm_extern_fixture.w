# wllvm differential fixture: extern functions and objects without a W
# body, called through the C ABI and linked dynamically against libc and
# libm. tests/wllvm_test.w builds it with bin/wv2 x64 and with bin/wllvm
# and compares the runs; the exit status is 54.
import lib.lib

c_lib "libc.so.6"
c_lib "libm.so.6"

c_import "libc.so.6" c"/usr/include/errno.h"

extern int getppid()
extern int puts(char* s)
extern int printf(char* fmt, ...)
extern int snprintf(char* buf, int size, char* fmt, ...)
extern int fflush(int stream)
extern int fputs(char* s, void* stream)
extern int32 abs(int32 x)
extern int toupper(int c)
extern void* memchr(void* s, int c, int n)
extern float64 sqrt(float64 x)
extern float64 ldexp(float64 x, int exp)
extern float32 sqrtf(float32 x)
extern float32 fmaxf(float32 a, float32 b)
# An alias: W calls say_hello, the loader binds puts.
extern int say_hello(char* s) = "puts"
# Statically initialized libc data, read in place.
extern void* stdout

type text_fn = fn(char*) -> int
type int_fn = fn(int) -> int
extern int labs(int x)


# Imports passed as W function values.
int call_text(text_fn f, char* s):
	return f(s)


int call_int(int_fn f, int x):
	return f(x)


int main(int argc, int argv):
	int total = 0
	if (getppid() > 0): total = total + 1
	puts(c"puts")
	say_hello(c"alias")
	fputs(c"fputs to stdout\x0a", stdout)
	char* buf = cast(char*, malloc(128))
	snprintf(buf, 128, c"%d %s %c %ld", 42, c"str", 'X', 0 - 5)
	println(buf)
	# Floats in the variadic tail travel as doubles, float32 promoted.
	float32 narrow = 7.5
	snprintf(buf, 128, c"%.1f %.2f %.1f %d", 1.5, 2.25, narrow, 9)
	println(buf)
	char[8] word
	word[0] = 'o'
	word[1] = 'k'
	word[2] = 0
	snprintf(buf, 128, c"<%s>", word)
	println(buf)
	# Narrow parameters and results: the int32 result sign-extends.
	total = total + abs(0 - 7)
	total = total + toupper('a') - 'A'
	char* text = c"hello"
	char* hit = cast(char*, memchr(text, 'l', 5))
	total = total + cast(int, hit - text)
	float64 root = sqrt(2.25)
	total = total + cast(int, root * 4.0)
	total = total + cast(int, ldexp(1.5, 4))
	float32 root32 = sqrtf(6.25)
	total = total + cast(int, fmaxf(root32, 1.0) * 2.0)
	# c_import constants
	total = total + ENOENT
	if (call_text(puts, c"callback") >= 0): total = total + 1
	total = total + call_int(labs, 0 - 6)
	printf(c"printf %d %s %.3f\x0a", total, c"done", root)
	fflush(0)
	return total
