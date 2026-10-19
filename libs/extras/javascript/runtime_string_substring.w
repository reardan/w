# Generic UTF-16 substring, with ordered start/end conversion and clamped bounds.
# https://tc39.es/ecma262/#sec-string.prototype.substring
import libs.extras.javascript.runtime

int js_substring_index(js_runtime* rt, js_value* value, int length):
	float64 number = js_array_like_number(rt, value)
	if (rt.completion.status != 0 || f64is_nan(number) || number <= 0.0): return 0
	if (number >= cast(float64, length)): return length
	return cast(int, js_builtin_trunc(number))

js_value* js_string_substring(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	if (receiver.kind == 0 || receiver.kind == 1):
		js_runtime_fail(rt, 2, c"substring requires a coercible receiver")
		return rt.undefined_value
	js_text* text = js_runtime_string_text(rt, receiver)
	if (text == 0): return rt.undefined_value
	int start = js_substring_index(rt, js_object_argument(rt, args, 0), text.units.length)
	int end = text.units.length
	js_value* end_value = js_object_argument(rt, args, 1)
	if (rt.completion.status == 0 && end_value.kind != 0): end = js_substring_index(rt, end_value, text.units.length)
	if (start > end):
		int saved = start
		start = end
		end = saved
	js_value* result = rt.undefined_value
	js_text* output = js_text_new()
	if (rt.completion.status == 0 && js_equality_charge(rt, end - start)):
		for i in range(start, end): output.units.push(text.units[i])
		result = js_runtime_string(rt, output)
	js_text_free(output)
	js_text_free(text)
	return result

void js_runtime_install_string_substring(js_runtime* rt):
	js_object_method(rt, rt.string_prototype, c"substring", js_string_substring, 0, 2)
