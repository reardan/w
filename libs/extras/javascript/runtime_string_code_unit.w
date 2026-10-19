# charCodeAt/charAt observe ToString before ToIntegerOrInfinity and return one
# UTF-16 code unit, including unpaired surrogates. Out-of-range positions yield
# NaN or the empty string respectively.
import libs.extras.javascript.runtime

js_value* js_string_code_unit(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	if (receiver.kind == 0 || receiver.kind == 1):
		js_runtime_fail(rt, 2, c"String code-unit method requires a coercible receiver")
		return rt.undefined_value
	js_text* text = js_runtime_string_text(rt, receiver)
	if (text == 0): return rt.undefined_value
	float64 position = js_array_like_number(rt, js_object_argument(rt, args, 0))
	if (f64is_nan(position)): position = 0.0
	else: position = js_builtin_trunc(position)
	int unit = -1
	if (rt.completion.status == 0 && position >= 0.0 && position < cast(float64, text.units.length)):
		unit = text.units[cast(int, position)]
	js_text_free(text)
	if (rt.completion.status != 0): return rt.undefined_value
	if (cast(int, context) == 1):
		js_text* character = js_text_new()
		if (unit >= 0): character.units.push(unit)
		js_value* result = js_runtime_string(rt, character)
		js_text_free(character)
		return result
	if (unit < 0): return js_runtime_number(rt, js_builtin_nan())
	return js_runtime_number(rt, cast(float64, unit))

void js_runtime_install_string_code_unit(js_runtime* rt):
	js_object_method(rt, rt.string_prototype, c"charCodeAt", js_string_code_unit, 0, 1)
	js_object_method(rt, rt.string_prototype, c"charAt", js_string_code_unit, 1, 1)
