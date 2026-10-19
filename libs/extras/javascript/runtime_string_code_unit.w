# charCodeAt observes ToString before ToIntegerOrInfinity and returns one UTF-16
# code unit, including unpaired surrogates. Out-of-range positions yield NaN.
import libs.extras.javascript.runtime

js_value* js_string_code_unit(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	if (receiver.kind == 0 || receiver.kind == 1):
		js_runtime_fail(rt, 2, c"charCodeAt requires a coercible receiver")
		return rt.undefined_value
	js_text* text = js_runtime_string_text(rt, receiver)
	if (text == 0): return rt.undefined_value
	float64 position = js_array_like_number(rt, js_object_argument(rt, args, 0))
	if (f64is_nan(position)): position = 0.0
	else: position = js_builtin_trunc(position)
	float64 result = js_builtin_nan()
	if (rt.completion.status == 0 && position >= 0.0 && position < cast(float64, text.units.length)):
		result = cast(float64, text.units[cast(int, position)])
	js_text_free(text)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_number(rt, result)

void js_runtime_install_string_code_unit(js_runtime* rt):
	js_object_method(rt, rt.string_prototype, c"charCodeAt", js_string_code_unit, 0, 1)
