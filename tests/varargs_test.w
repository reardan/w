# Variadic C imports on both targets: extern declarations with a trailing
# '...' accept any number of extra arguments. Fixed arguments follow the
# declared types; the variadic tail gets the C default argument
# promotions (float32 widens to float64). On x64 the inline call places
# floats in xmm registers and sets al; on x86 everything passes on the
# 16-byte-aligned stack with float64 spanning two words.
import lib.lib
import lib.assert

c_lib "libc.so.6"

extern int snprintf(char* buf, int size, char* fmt, ...)
extern int printf(char* fmt, ...)
extern int fflush(int stream)


char* buf


void check(char* want, int got_len):
	assert_equal(strlen(want), got_len)
	assert_strings_equal(want, buf)


int main(int argc, int argv):
	buf = malloc(128)

	# Integers, strings and chars in the variadic tail
	check(c"42 str X", snprintf(buf, 128, c"%d %s %c", 42, c"str", 'X'))

	# Enough integers to spill past the x64 register file
	check(c"1 2 3 4 5 6 7 8 9", snprintf(buf, 128, c"%d %d %d %d %d %d %d %d %d", 1, 2, 3, 4, 5, 6, 7, 8, 9))

	# Float literals promote to float64
	check(c"1.5 2.25", snprintf(buf, 128, c"%.1f %.2f", 1.5, 2.25))

	# Interleaved integer and float classes
	check(c"1 2.5 3 4.5 end", snprintf(buf, 128, c"%d %.1f %d %.1f %s", 1, 2.5, 3, 4.5, c"end"))

	# Ten floats: xmm0..xmm7 plus two stack floats on x64, with a trailing
	# integer whose position must survive the spill
	check(c"1 2 3 4 5 6 7 8 9 10 11",
		snprintf(buf, 128, c"%.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %d",
			1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11))

	# A float32 variable widens to float64 (C default argument promotion)
	float32 f = 7.5
	check(c"7.5", snprintf(buf, 128, c"%.1f", f))

	# No variadic tail at all
	check(c"plain", snprintf(buf, 128, c"plain"))

	# printf goes to buffered stdout; the entry stub exits with a raw
	# syscall, so flush explicitly.
	printf(c"printf: %d %s %.2f\x0a", 7, c"seven", 7.25)
	fflush(0)

	println(c"varargs OK")
	return 0
