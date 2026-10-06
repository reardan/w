/*
f-string float32 formatting (grammar/template_string.w): '{value}' and
'{value:spec}' of a float32, plus the bit-pattern formatter
structures/template_float64.w shares. Kept apart from
structures/string.w so only programs that interpolate a float import
the formatter (lib/float_text.w).

Like the other __w_ runtimes this file must stay compatible with the
oldest compiler that may compile it: plain W only.
*/
import structures.string
import lib.float_text


# The float formatter shared with structures/template_float64.w, on
# the raw bit pattern of a float of the given width (32 or 64).
void __w_template_float_bits(string_builder* s, int bits, int float_width, int width, int precision, int flags):
	char* text = 0
	if (precision < 0): text = float_text_shortest(bits, float_width)
	else: text = float_text_fixed(bits, float_width, precision)
	__w_template_pad(s, text, strlen(text), width, flags)
	free(text)


# '{value}' / '{value:spec}' of a float32: the shortest text that
# parses back to the same value (lib/float_text.w, Python repr
# spelling) when the spec gives no precision, else exactly precision
# fraction digits, correctly rounded.
void __w_template_float(string_builder* s, float f, int width, int precision, int flags):
	int32* p = cast(int32*, &f)
	__w_template_float_bits(s, *p, 32, width, precision, flags)
