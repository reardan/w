# Harness-facing standard builtins use normal coercion and property hooks.
# https://tc39.es/ecma262/#sec-string.fromcharcode
# https://tc39.es/ecma262/#sec-array.prototype.indexof
import libs.extras.javascript.runtime

js_value* js_string_from_char_code(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_text* text = js_text_new()
	for i in range(args.length):
		if (js_runtime_compat_step(rt) == 0): break
		float64 number = js_array_like_number(rt, args[i])
		if (rt.completion.status != 0): break
		int unit = 0
		if (js_builtin_finite(number)):
			float64 reduced = js_number_remainder(rt, js_builtin_trunc(number), 65536.0)
			if (rt.completion.status != 0): break
			unit = cast(int, reduced) & 65535
		text.units.push(unit)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, text)
	js_text_free(text)
	return result

js_value* js_array_index_of(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_boxed_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_function_array_length(rt, js_runtime_get(rt, object, c"length"))
	if (rt.completion.status != 0): return rt.undefined_value
	int start = 0
	if (length > 0 && args.length > 1): start = js_array_like_index(rt, args[1], length)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* search = js_object_argument(rt, args, 0)
	int result = -1
	for i in range(start, length):
		if (js_runtime_compat_step(rt) == 0): break
		int present = js_array_like_has(rt, object, i)
		if (rt.completion.status != 0): break
		if (present == 0): continue
		js_value* value = js_runtime_index_get(rt, object, i)
		if (rt.completion.status != 0): break
		if (js_runtime_equal(search, value)):
			result = i
			break
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_number(rt, cast(float64, result))

void js_runtime_install_harness_search(js_runtime* rt):
	js_object_method(rt, js_runtime_get(rt, rt.global, c"String"), c"fromCharCode", js_string_from_char_code, 0, 1)
	js_object_method(rt, rt.array_prototype, c"indexOf", js_array_index_of, 0, 1)
