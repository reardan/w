# Generic TrimString over the ECMAScript WhiteSpace and LineTerminator set,
# shared with StringToNumber (js_runtime_white_space).
# https://tc39.es/ecma262/#sec-trimstring
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_string_support


# context 0: trim, 1: trimStart, 2: trimEnd.
js_value* js_string_trim(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_text* text = js_string_this_text(rt, receiver, args)
	if (text == 0): return rt.undefined_value
	js_value* result = rt.undefined_value
	# Charge the bounded source scan before visiting any units, then the copy.
	if (js_string_charge(rt, text.units.length)):
		int operation = cast(int, context)
		int start = 0
		int end = text.units.length
		if (operation != 2):
			while (start < end && js_runtime_white_space(text.units[start])): start = start + 1
		if (operation != 1):
			while (end > start && js_runtime_white_space(text.units[end - 1])): end = end - 1
		result = js_string_slice_value(rt, text, start, end)
	js_text_free(text)
	return result


void js_install_string_trim(js_runtime* rt):
	js_value* start = js_string_define_method(rt, rt.string_prototype, c"trim", js_string_trim, 0, 0)
	start = js_string_define_method(rt, rt.string_prototype, c"trimStart", js_string_trim, 1, 0)
	js_value* end = js_string_define_method(rt, rt.string_prototype, c"trimEnd", js_string_trim, 2, 0)
	# Web-legacy aliases share function identity (and so the canonical name).
	js_text* key = js_runtime_key(c"trimLeft")
	js_runtime_define_data(rt, rt.string_prototype, key, start, 1, 0, 1)
	js_text_free(key)
	key = js_runtime_key(c"trimRight")
	js_runtime_define_data(rt, rt.string_prototype, key, end, 1, 0, 1)
	js_text_free(key)
