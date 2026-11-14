# ECMAScript parseFloat longest-prefix decimal conversion over UTF-16 strings.
# Uses W's correctly rounded decimal parser after restricting its lexical input.
# https://tc39.es/ecma262/#sec-parsefloat-string
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_object

int js_number_space(int unit):
	return js_runtime_white_space(unit)

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

# Argument-count charge plus an ownership check: a value of another runtime
# must never be converted or stored in this heap.
int js_number_arguments(js_runtime* rt, list[js_value*] args):
	if (js_builtin_arguments(rt, args) == 0): return 0
	for i in range(args.length):
		if (args[i] == 0 || args[i].owner != rt):
			js_runtime_fail(rt, 2, c"numeric builtin argument belongs to another runtime")
			return 0
	return 1

js_value* js_number_parse_float_host(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_number_arguments(rt, args) == 0): return rt.undefined_value
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_text* text = js_runtime_to_text(rt, value)
	if (text == 0): return rt.undefined_value
	float64 number = js_number_parse_float(rt, text)
	js_text_free(text)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_number(rt, number)

# Shaped like a standard built-in: name/length are configurable and readonly.
void js_number_shape(js_runtime* rt, js_value* function, char* name, int length):
	js_object_define_named(rt, function, c"name", js_runtime_string_value(rt, name), 0, 1)
	js_object_define_named(rt, function, c"length", js_runtime_number(rt, cast(float64, length)), 0, 1)

# Global property: writable, nonenumerable, configurable.
void js_number_global(js_runtime* rt, char* name, js_value* function):
	js_runtime_set(rt, rt.global, name, function)
	js_text* key = js_runtime_key(name)
	js_value* binding = js_runtime_property(rt.global, key)
	if (binding != 0): binding.enumerable = 0
	js_text_free(key)

void js_runtime_install_number_parse(js_runtime* rt):
	js_value* number = js_runtime_get(rt, rt.global, c"Number")
	if (js_runtime_object(number) == 0): return
	js_value* function = js_runtime_host_callable(rt, 0, js_number_parse_float_host)
	js_number_shape(rt, function, c"parseFloat", 1)
	js_number_global(rt, c"parseFloat", function)
	js_object_define_named(rt, number, c"parseFloat", function, 1, 1)
