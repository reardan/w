/*
f-string float64 formatting (grammar/template_string.w): '{value}' and
'{value:spec}' of a float64. float64 exists only on the 64-bit-word
targets, so this lives apart from structures/string.w (compiled on
every target) and is imported on demand only by programs that
interpolate a float64. Same rendering as __w_template_float: shortest
round-trip text without a precision, correctly rounded fixed digits
with one.

Like the other __w_ runtimes this file must stay compatible with the
oldest compiler that may compile it: plain W only.
*/
import structures.string
import structures.template_float


void __w_template_float64(string_builder* s, float64 f, int width, int precision, int flags):
	int* p = cast(int*, &f)
	__w_template_float_bits(s, *p, 64, width, precision, flags)
