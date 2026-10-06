/*
printf-style formatting.

Supported verbs: %d (decimal), %x (hex), %s (string), %c (character), %%.
The language has no varargs, so printf1/printf2/printf3 cover the common
fixed-arity cases; all of them funnel into vfprintf with a word array.
*/
import lib.lib
import lib.assert
import lib.float_text


# Reinterpret a float32 as its bit pattern (a private copy of
# lib/fmath.w's float_bits, so importing lib.format does not pull the
# fmath names into every consumer).
int format_float32_bits(float f):
	int32* p = cast(int32*, &f)
	return *p


# Shortest text that parses back to the same float32, spelled like
# Python's repr: 3.25 -> "3.25", 0.1 -> "0.1", 1e20 -> "1e+20",
# 1e-7 -> "1e-07", whole values keep ".0", plus inf / -inf / nan
# (lib/float_text.w). Returns a malloc'd string.
char* ftoa(float f):
	return float_text_shortest(format_float32_bits(f), 32)


# Exactly precision fraction digits, correctly rounded ("%.Nf"):
# ftoa_fixed(2.5, 6) -> "2.500000". Returns a malloc'd string.
char* ftoa_fixed(float f, int precision):
	return float_text_fixed(format_float32_bits(f), 32, precision)


# The float32 nearest the decimal number at the start of s (strtod
# rules; see float_text_parse): *consumed (if consumed is nonzero) gets
# the number of chars used, 0 when s does not start with a number.
float parse_float(char* s, int* consumed):
	float f
	int32* p = cast(int32*, &f)
	*p = float_text_parse(s, 32, consumed)
	return f


# Print fmt to fd, pulling one word from args for each verb.
void vfprintf(int fd, char* fmt, int* args, int num_args):
	int i = 0
	int used = 0
	while (fmt[i] != 0):
		if ((fmt[i] == '%') && (fmt[i + 1] != 0)):
			int verb = fmt[i + 1]
			i = i + 2
			if (verb == '%'): putc(fd, '%')
			else:
				asserts(c"printf: more verbs than arguments", used < num_args)
				int value = args[used]
				used = used + 1
				if (verb == 'd'):
					char* digits = itoa(value)
					write(fd, digits, strlen(digits))
					free(digits)
				else if (verb == 'x'):
					char* digits = hex(value)
					write(fd, digits, strlen(digits))
					free(digits)
				else if (verb == 's'):
					char* text = cast(char*, value)
					write(fd, text, strlen(text))
				else if (verb == 'c'): putc(fd, value)
				else:
					# Unknown verb: print it verbatim
					putc(fd, '%')
					putc(fd, verb)
		else:
			putc(fd, fmt[i])
			i = i + 1


void printf(char* fmt):
	vfprintf(1, fmt, 0, 0)


void printf1(char* fmt, int a):
	int* args = malloc(__word_size__)
	args[0] = a
	vfprintf(1, fmt, args, 1)
	free(args)


void printf2(char* fmt, int a, int b):
	int* args = malloc(2 * __word_size__)
	args[0] = a
	args[1] = b
	vfprintf(1, fmt, args, 2)
	free(args)


void printf3(char* fmt, int a, int b, int c):
	int* args = malloc(3 * __word_size__)
	args[0] = a
	args[1] = b
	args[2] = c
	vfprintf(1, fmt, args, 3)
	free(args)
