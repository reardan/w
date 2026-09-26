/*
f-string float64 formatting (grammar/template_string.w): '{value}' and
'{value:spec}' of a float64. float64 exists only on the 64-bit-word
targets, so this lives apart from structures/string.w (compiled on
every target) and is imported on demand only by programs that
interpolate a float64. Same rendering as __w_template_float.

Like the other __w_ runtimes this file must stay compatible with the
oldest compiler that may compile it: plain W only.
*/
import structures.string


void __w_template_float64(string_builder* s, float64 f, int width, int precision, int flags):
	if (precision < 0): precision = 6
	char* buffer = malloc(precision + 48)
	int pos = 0
	if (f < 0.0):
		buffer[pos] = '-'
		pos = pos + 1
		f = -f
	float64 half = 0.5
	int i = 0
	while (i < precision):
		half = half / 10.0
		i = i + 1
	f = f + half
	int whole = f
	char* digits = itoa(whole)
	__w_template_copy(buffer + pos, digits, strlen(digits))
	pos = pos + strlen(digits)
	free(digits)
	if (precision > 0):
		buffer[pos] = '.'
		pos = pos + 1
		float64 frac = f - whole
		i = 0
		while (i < precision):
			frac = frac * 10.0
			int digit = frac
			buffer[pos] = digit + '0'
			pos = pos + 1
			frac = frac - digit
			i = i + 1
	__w_template_pad(s, buffer, pos, width, flags)
	free(buffer)
