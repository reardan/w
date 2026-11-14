# Generic UTF-16 substring: ToString(this), then start and end converted in
# order, clamped to the length and swapped when start > end.
# https://tc39.es/ecma262/#sec-string.prototype.substring
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_string_support


# Clamp an integer-valued double into [0, length].
int js_substring_clamp(float64 number, int length):
	if (number <= 0.0): return 0
	if (number >= cast(float64, length)): return length
	return cast(int, number)


js_value* js_string_substring(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_text* text = js_string_this_text(rt, receiver, args)
	if (text == 0): return rt.undefined_value
	int length = text.units.length
	int start = js_substring_clamp(js_string_integer(rt, args, 0), length)
	int end = length
	js_value* end_value = js_string_argument(rt, args, 1)
	if (rt.completion.status == 0 && end_value.kind != 0): end = js_substring_clamp(js_runtime_to_integer(rt, end_value), length)
	if (start > end):
		int saved = start
		start = end
		end = saved
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_string_slice_value(rt, text, start, end)
	js_text_free(text)
	return result


void js_install_string_substring(js_runtime* rt):
	js_string_define_method(rt, rt.string_prototype, c"substring", js_string_substring, 0, 2)
