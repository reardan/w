# Bounded Array constructor and IsArray brand check.
# https://tc39.es/ecma262/#sec-array-constructor
import libs.extras.javascript.runtime

js_value* js_array_construct(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int length = args.length
	int holes = args.length == 1 && args[0].kind == 3
	if (holes):
		float64 number = args[0].number
		if (js_builtin_finite(number) == 0 || number < 0.0 || number > 4294967295.0 || js_builtin_trunc(number) != number):
			js_bigint_error(rt, c"RangeError", c"invalid Array length")
			return rt.undefined_value
		if (number > cast(float64, rt.max_properties)):
			js_runtime_fail(rt, 5, c"Array length exceeds runtime limit")
			return rt.undefined_value
		length = cast(int, number)
	js_value* array = js_runtime_alloc(rt, 6)
	if (rt.completion.status != 0): return rt.undefined_value
	array.array_length = length
	if (holes == 0):
		for i in range(args.length):
			if (js_runtime_compat_step(rt) == 0): break
			char* raw = itoa(i)
			js_text* key = js_runtime_key(raw)
			free(raw)
			# CreateDataProperty, so an inherited index setter cannot intercept.
			js_runtime_define_data(rt, array, key, args[i], 1, 1, 1)
			js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	return array

js_value* js_array_is_array(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	return js_runtime_boolean(rt, args.length > 0 && args[0].kind == 6)

void js_runtime_install_array(js_runtime* rt):
	js_value* constructor = js_runtime_host_callable(rt, 0, js_array_construct)
	constructor.host_construct = 1
	js_class_define(rt, constructor, c"name", js_class_string(rt, c"Array"), 0, 1)
	js_class_define(rt, constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, constructor, c"prototype", rt.array_prototype, 0, 0)
	js_class_define(rt, rt.array_prototype, c"constructor", constructor, 1, 1)
	js_value* is_array = js_runtime_host_callable(rt, 0, js_array_is_array)
	js_class_define(rt, is_array, c"name", js_class_string(rt, c"isArray"), 0, 1)
	js_class_define(rt, is_array, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, constructor, c"isArray", is_array, 1, 1)
	js_runtime_set(rt, rt.global, c"Array", constructor)
	js_class_define(rt, rt.global, c"Array", constructor, 1, 1)
