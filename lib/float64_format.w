# float64 text conversion for the 8-byte-word targets (float64 is a
# compile error on 4-byte words); the engine is lib/float_text.w.
import lib.lib
import lib.float_text


int float64_format_bits(float64 f):
	int* p = cast(int*, &f)
	return *p


# Shortest text that parses back to the same float64, spelled like
# Python's repr: 0.1 -> "0.1", 1e20 -> "1e+20", 1e-7 -> "1e-07",
# 1.7976931348623157e+308, 5e-324, whole values keep ".0", plus
# inf / -inf / nan. Returns a malloc'd string.
char* f64toa(float64 f):
	return float_text_shortest(float64_format_bits(f), 64)


# Exactly precision fraction digits, correctly rounded ("%.Nf"), for
# any magnitude. Returns a malloc'd string.
char* f64toa_fixed(float64 f, int precision):
	return float_text_fixed(float64_format_bits(f), 64, precision)


# The float64 nearest the decimal number at the start of s (strtod
# rules; see float_text_parse): *consumed (if consumed is nonzero) gets
# the number of chars used, 0 when s does not start with a number.
float64 parse_float64(char* s, int* consumed):
	float64 f
	int* p = cast(int*, &f)
	*p = float_text_parse(s, 64, consumed)
	return f
