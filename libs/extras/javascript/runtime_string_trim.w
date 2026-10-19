# Generic TrimString over the ECMAScript WhiteSpace and LineTerminator set.
# https://tc39.es/ecma262/#sec-trimstring
import libs.extras.javascript.runtime

js_value* js_string_trim(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	if (receiver.kind == 0 || receiver.kind == 1):
		js_runtime_fail(rt, 2, c"trim requires a coercible receiver")
		return rt.undefined_value
	js_text* text = js_runtime_string_text(rt, receiver)
	if (text == 0): return rt.undefined_value
	js_value* result = rt.undefined_value
	# Charge the bounded source scan before visiting any units, then the copy.
	if (js_equality_charge(rt, text.units.length)):
		int operation = cast(int, context)
		int start = 0
		int end = text.units.length
		if (operation != 2):
			while (start < end && js_number_space(text.units[start])): start = start + 1
		if (operation != 1):
			while (end > start && js_number_space(text.units[end - 1])): end = end - 1
		if (js_equality_charge(rt, end - start)):
			js_text* output = js_text_new()
			for i in range(start, end): output.units.push(text.units[i])
			result = js_runtime_string(rt, output)
			js_text_free(output)
	js_text_free(text)
	return result

void js_runtime_install_string_trim(js_runtime* rt):
	js_object_method(rt, rt.string_prototype, c"trim", js_string_trim, 0, 0)
	js_object_method(rt, rt.string_prototype, c"trimStart", js_string_trim, 1, 0)
	js_object_method(rt, rt.string_prototype, c"trimEnd", js_string_trim, 2, 0)
	# Web-legacy aliases share function identity and the canonical method name.
	js_class_define(rt, rt.string_prototype, c"trimLeft", js_runtime_get(rt, rt.string_prototype, c"trimStart"), 1, 1)
	js_class_define(rt, rt.string_prototype, c"trimRight", js_runtime_get(rt, rt.string_prototype, c"trimEnd"), 1, 1)
