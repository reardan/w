# Generic bounded array-like operations. Native objects participate through
# their existing Get/Has hooks; presence tests never invoke a value getter.
# https://tc39.es/ecma262/#sec-array.prototype.slice
import libs.extras.javascript.runtime

js_value* js_array_like_object(js_runtime* rt, js_value* value):
	if (js_runtime_object(value)): return value
	if (value.kind == 0 || value.kind == 1):
		js_runtime_fail(rt, 2, c"array-like operation requires a coercible receiver")
		return rt.undefined_value
	js_value* object = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	if (value.kind == 4):
		object.prototype = rt.string_prototype
		js_class_define(rt, object, c"length", js_runtime_number(rt, cast(float64, value.text.units.length)), 0, 0)
		for i in range(value.text.units.length):
			if (js_runtime_compat_step(rt) == 0): break
			char* raw = itoa(i)
			js_text* key = js_runtime_key(raw)
			free(raw)
			js_value* unit = js_runtime_index_get(rt, value, i)
			js_runtime_define_data(rt, object, key, unit, 0, 1, 0)
			js_text_free(key)
	return object

float64 js_array_like_number(js_runtime* rt, js_value* value):
	if (js_runtime_object(value)): value = js_equality_primitive(rt, value)
	if (rt.completion.status != 0): return 0.0
	if (value.kind == 2 || value.kind == 3): return value.number
	if (value.kind == 4): return js_equality_number(rt, value.text)
	if (value.kind == 10): js_runtime_fail(rt, 2, c"BigInt cannot be converted to Number")
	if (value.kind == 0): return float64_from_bits((0x7ff << 52) | 1)
	return 0.0

int js_array_like_index(js_runtime* rt, js_value* value, int length):
	float64 number = js_array_like_number(rt, value)
	if (rt.completion.status != 0 || f64is_nan(number)): return 0
	if (number >= cast(float64, length)): return length
	if (number <= -cast(float64, length)): return 0
	int index = cast(int, number)
	if (index < 0): index = length + index
	return index

int js_array_like_has(js_runtime* rt, js_value* object, int index):
	char* raw = itoa(index)
	js_text* key = js_runtime_key(raw)
	free(raw)
	int present = js_runtime_has_property(rt, object, key)
	js_text_free(key)
	return present

js_value* js_array_like_slice(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* object = js_array_like_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_function_array_length(rt, js_runtime_get(rt, object, c"length"))
	int start = 0
	int end = length
	if (rt.completion.status == 0 && args.length > 0): start = js_array_like_index(rt, args[0], length)
	if (rt.completion.status == 0 && args.length > 1 && args[1].kind != 0): end = js_array_like_index(rt, args[1], length)
	# Symbols/species are outside this runtime profile, but the observable
	# constructor Get and primitive-constructor error still apply to arrays.
	if (rt.completion.status == 0 && object.kind == 6):
		js_value* constructor = js_runtime_get(rt, object, c"constructor")
		if (constructor.kind != 0 && js_runtime_object(constructor) == 0): js_runtime_fail(rt, 2, c"array species constructor is not an object")
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* result = js_runtime_alloc(rt, 6)
	if (rt.completion.status != 0): return rt.undefined_value
	if (end > start): result.array_length = end - start
	for i in range(start, end):
		if (js_runtime_compat_step(rt) == 0): break
		if (js_array_like_has(rt, object, i)):
			js_value* item = js_runtime_index_get(rt, object, i)
			if (rt.completion.status != 0): break
			char* raw = itoa(i - start)
			js_text* key = js_runtime_key(raw)
			free(raw)
			js_runtime_define_data(rt, result, key, item, 1, 1, 1)
			js_text_free(key)
	return result
