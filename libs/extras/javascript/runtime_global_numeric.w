# Global numeric conversion differs from Number's noncoercing predicates.
# Integer parsing accumulates exact decimal digits before one binary64 rounding,
# avoiding accumulated floating-point error for long strings and every radix.
import libs.extras.javascript.runtime

int js_parse_integer_digit(int unit):
	if (unit >= '0' && unit <= '9'): return unit - '0'
	if (unit >= 'a' && unit <= 'z'): return unit - 'a' + 10
	if (unit >= 'A' && unit <= 'Z'): return unit - 'A' + 10
	return 36

float64 js_parse_integer(js_runtime* rt, js_text* text, int radix):
	int position = 0
	int length = text.units.length
	while (position < length && js_number_space(text.units[position])):
		if (js_runtime_compat_step(rt) == 0): return 0.0
		position = position + 1
	int negative = 0
	if (position < length && (text.units[position] == '+' || text.units[position] == '-')):
		negative = text.units[position] == '-'
		position = position + 1
	int strip = radix == 0 || radix == 16
	if (radix != 0 && (radix < 2 || radix > 36)): return js_builtin_nan()
	if (radix == 0): radix = 10
	if (strip && length - position >= 2 && text.units[position] == '0' && (text.units[position + 1] == 'x' || text.units[position + 1] == 'X')):
		position = position + 2
		radix = 16
	ftx_decimal* integer = ftx_new()
	int count = 0
	int overflow = 0
	while (position < length):
		int digit = js_parse_integer_digit(text.units[position])
		if (digit >= radix): break
		if (js_runtime_compat_step(rt) == 0): break
		count = count + 1
		position = position + 1
		if (overflow): continue
		int carry = digit
		int i = integer.nd - 1
		while (i >= 0):
			if (js_runtime_compat_step(rt) == 0): break
			int next = (integer.d[i] - '0') * radix + carry
			integer.d[i] = '0' + next % 10
			carry = next / 10
			i = i - 1
		if (rt.completion.status != 0): break
		while (carry != 0):
			int j = integer.nd
			while (j > 0):
				integer.d[j] = integer.d[j - 1]
				j = j - 1
			integer.d[0] = '0' + carry % 10
			carry = carry / 10
			integer.nd = integer.nd + 1
		# Every 310-digit positive integer overflows binary64. Continue scanning
		# input to enforce the same bound without growing the accumulator.
		if (integer.nd >= 310): overflow = 1
	int bits = 0
	if (count == 0): bits = float64_bits(js_builtin_nan())
	else if (overflow): bits = 0x7ff << 52
	else if (rt.completion.status == 0):
		integer.dp = integer.nd
		ftx_trim(integer)
		bits = ftx_float_bits(integer, 64)
	ftx_free(integer)
	if (negative && count != 0): bits = bits | (1 << 63)
	return float64_from_bits(bits)

js_value* js_global_numeric(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int operation = cast(int, context)
	js_value* argument = js_object_argument(rt, args, 0)
	if (operation == 0):
		js_text* text = js_runtime_string_text(rt, argument)
		if (text == 0): return rt.undefined_value
		float64 raw_radix = js_array_like_number(rt, js_object_argument(rt, args, 1))
		float64 number = 0.0
		if (rt.completion.status == 0): number = js_parse_integer(rt, text, js_runtime_int32(raw_radix))
		js_text_free(text)
		if (rt.completion.status != 0): return rt.undefined_value
		return js_runtime_number(rt, number)
	float64 number = js_array_like_number(rt, argument)
	if (rt.completion.status != 0): return rt.undefined_value
	if (operation == 1): return js_runtime_boolean(rt, f64is_nan(number))
	return js_runtime_boolean(rt, js_builtin_finite(number))

void js_global_numeric_method(js_runtime* rt, char* name, int code, int length):
	js_value* method = js_runtime_host_callable(rt, cast(void*, code), js_global_numeric)
	js_class_define(rt, method, c"name", js_class_string(rt, name), 0, 1)
	js_class_define(rt, method, c"length", js_runtime_number(rt, cast(float64, length)), 0, 1)
	js_runtime_set(rt, rt.global, name, method)
	js_text* key = js_runtime_key(name)
	js_value* binding = js_runtime_property(rt.global, key)
	if (binding != 0): binding.enumerable = 0
	js_text_free(key)

void js_runtime_install_global_numeric(js_runtime* rt):
	js_global_numeric_method(rt, c"parseInt", 0, 2)
	js_global_numeric_method(rt, c"isNaN", 1, 1)
	js_global_numeric_method(rt, c"isFinite", 2, 1)
	js_value* number = js_runtime_get(rt, rt.global, c"Number")
	js_text* key = js_runtime_key(c"parseInt")
	js_runtime_define_data(rt, number, key, js_runtime_get(rt, rt.global, c"parseInt"), 1, 0, 1)
	js_text_free(key)
