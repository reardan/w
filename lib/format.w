/*
printf-style formatting.

Supported verbs: %d (decimal), %x (hex), %s (string), %c (character), %%.
The language has no varargs, so printf1/printf2/printf3 cover the common
fixed-arity cases; all of them funnel into vfprintf with a word array.
*/
import lib.lib
import lib.assert


char* ftoa(float f):
	char* s = malloc(64)
	int pos = 0
	if (f < 0.0):
		s[pos] = '-'
		pos = pos + 1
		f = -f
	int whole = f
	char* whole_digits = itoa(whole)
	strcpy(s + pos, whole_digits)
	free(whole_digits)
	pos = strlen(s)
	s[pos] = '.'
	pos = pos + 1
	float frac = f - whole
	int i = 0
	while (i < 6):
		frac = frac * 10.0
		int digit = frac
		s[pos] = digit + '0'
		pos = pos + 1
		frac = frac - digit
		i = i + 1
	s[pos] = 0
	return s


# Print fmt to fd, pulling one word from args for each verb.
void vfprintf(int fd, char* fmt, int* args, int num_args):
	int i = 0
	int used = 0
	while (fmt[i] != 0):
		if ((fmt[i] == '%') & (fmt[i + 1] != 0)):
			int verb = fmt[i + 1]
			i = i + 2
			if (verb == '%'):
				putc(fd, '%')
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
				else if (verb == 'c'):
					putc(fd, value)
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
	int* args = malloc(4)
	args[0] = a
	vfprintf(1, fmt, args, 1)
	free(args)


void printf2(char* fmt, int a, int b):
	int* args = malloc(8)
	args[0] = a
	args[1] = b
	vfprintf(1, fmt, args, 2)
	free(args)


void printf3(char* fmt, int a, int b, int c):
	int* args = malloc(12)
	args[0] = a
	args[1] = b
	args[2] = c
	vfprintf(1, fmt, args, 3)
	free(args)
