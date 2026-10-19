# ECMAScript parseFloat longest-prefix decimal conversion over UTF-16 strings.
# Uses W's correctly rounded decimal parser after restricting its lexical input.
# https://tc39.es/ecma262/#sec-parsefloat-string
import libs.extras.javascript.runtime

js_text* js_runtime_string_text(js_runtime* rt, js_value* value);

int js_number_space(int unit):
	return (unit >= 9 && unit <= 13) || unit == 32 || unit == 160 || unit == 0xfeff || unit == 0x1680 || (unit >= 0x2000 && unit <= 0x200a) || unit == 0x2028 || unit == 0x2029 || unit == 0x202f || unit == 0x205f || unit == 0x3000

float64 js_number_parse_float(js_runtime* rt, js_text* text):
	int length = text.units.length
	if (rt.running):
		if (length > rt.remaining):
			js_runtime_fail(rt, 5, c"parseFloat execution limit")
			return 0.0
		rt.remaining = rt.remaining - length
		rt.completion.steps = rt.completion.steps + length
	int start = 0
	while (start < length && js_number_space(text.units[start])): start = start + 1
	int first = start
	int negative = 0
	if (first < length && (text.units[first] == '+' || text.units[first] == '-')):
		negative = text.units[first] == '-'
		first = first + 1
	if (length - first >= 8):
		char* infinity = c"Infinity"
		int matches = 1
		for i in range(8):
			if (text.units[first + i] != infinity[i]): matches = 0
		if (matches):
			int bits = 0x7ff << 52
			if (negative): bits = bits | (1 << 63)
			return float64_from_bits(bits)
	if (first >= length): return js_builtin_nan()
	int unit = text.units[first]
	if ((unit < '0' || unit > '9') && unit != '.'): return js_builtin_nan()
	string_builder* prefix = string_new()
	for i in range(start, length):
		unit = text.units[i]
		if (unit == 0 || unit > 127): break
		string_append_char(prefix, unit)
	int consumed = 0
	float64 number = parse_float64(prefix.data, &consumed)
	string_free(prefix)
	if (consumed == 0): return js_builtin_nan()
	return number

js_value* js_number_parse_float_host(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_text* text = js_runtime_string_text(rt, value)
	if (text == 0): return rt.undefined_value
	float64 number = js_number_parse_float(rt, text)
	js_text_free(text)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_number(rt, number)

void js_runtime_install_number_parse(js_runtime* rt):
	js_value* function = js_runtime_host_callable(rt, 0, js_number_parse_float_host)
	js_text* length = js_runtime_key(c"length")
	js_runtime_define_data(rt, function, length, js_runtime_number(rt, 1.0), 0, 0, 1)
	js_text_free(length)
	js_text* name = js_runtime_key(c"name")
	js_text* spelling = js_runtime_key(c"parseFloat")
	js_runtime_define_data(rt, function, name, js_runtime_string(rt, spelling), 0, 0, 1)
	js_text_free(name)
	js_text_free(spelling)
	js_text* key = js_runtime_key(c"parseFloat")
	js_runtime_set(rt, rt.global, c"parseFloat", function)
	js_runtime_define_data(rt, rt.global, key, function, 1, 0, 1)
	js_runtime_define_data(rt, js_runtime_get(rt, rt.global, c"Number"), key, function, 1, 0, 1)
	js_text_free(key)
