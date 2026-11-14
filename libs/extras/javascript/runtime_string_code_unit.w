# charCodeAt, charAt and String.fromCharCode. All observe ToString/ToNumber in
# specification order and handle UTF-16 code units, including unpaired
# surrogates. Out-of-range positions give NaN or the empty string.
# https://tc39.es/ecma262/#sec-string.prototype.charcodeat
# https://tc39.es/ecma262/#sec-string.fromcharcode
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_string_support


# context 0: charCodeAt, 1: charAt.
js_value* js_string_code_unit(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_text* text = js_string_this_text(rt, receiver, args)
	if (text == 0): return rt.undefined_value
	float64 position = js_string_integer(rt, args, 0)
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


js_value* js_string_from_char_code(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_text* text = js_text_new()
	for i in range(args.length):
		if (js_runtime_compat_step(rt) == 0): break
		js_value* value = js_string_argument(rt, args, i)
		if (rt.completion.status != 0): break
		float64 number = js_runtime_to_number(rt, value)
		if (rt.completion.status != 0): break
		# ToUint16: truncate, then reduce modulo 2^16 (NaN and infinities give 0).
		int unit = 0
		if (js_builtin_finite(number)):
			float64 whole = js_builtin_trunc(number)
			float64 reduced = whole - js_builtin_floor(whole / 65536.0) * 65536.0
			unit = cast(int, reduced) & 65535
		text.units.push(unit)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, text)
	js_text_free(text)
	return result


void js_install_string_code_unit(js_runtime* rt):
	js_string_define_method(rt, rt.string_prototype, c"charCodeAt", js_string_code_unit, 0, 1)
	js_string_define_method(rt, rt.string_prototype, c"charAt", js_string_code_unit, 1, 1)
	if (rt.string_constructor != 0): js_string_define_method(rt, rt.string_constructor, c"fromCharCode", js_string_from_char_code, 0, 1)
