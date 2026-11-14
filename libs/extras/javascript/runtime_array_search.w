# Array.prototype.indexOf / lastIndexOf: strict equality over present elements.
# Length is read first; fromIndex is coerced only for a nonempty receiver, and
# each position tests presence before Get.
# https://tc39.es/ecma262/#sec-array.prototype.indexof
# https://tc39.es/ecma262/#sec-array.prototype.lastindexof
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_array_like


# Context 0 indexOf, 1 lastIndexOf.
js_value* js_ap_index_of(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_ap_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_ap_length(rt, object)
	if (rt.completion.status != 0): return rt.undefined_value
	int reverse = cast(int, context)
	if (length == 0): return js_runtime_number(rt, -1.0)
	int start = 0
	if (reverse): start = length - 1
	if (args.length > 1):
		float64 number = js_runtime_to_integer(rt, args[1])
		if (rt.completion.status != 0): return rt.undefined_value
		float64 size = cast(float64, length)
		if (reverse):
			if (number >= 0.0):
				if (number < size - 1.0): start = cast(int, number)
			else:
				number = size + number
				if (number < 0.0): start = -1
				else: start = cast(int, number)
		else:
			if (number >= size): start = length
			else if (number >= 0.0): start = cast(int, number)
			else:
				number = size + number
				if (number > 0.0): start = cast(int, number)
	js_value* search = rt.undefined_value
	if (args.length > 0): search = args[0]
	int result = -1
	int count = length - start
	if (reverse): count = start + 1
	for offset in range(count):
		int i = start + offset
		if (reverse): i = start - offset
		if (js_runtime_compat_step(rt) == 0): break
		int present = js_ap_has(rt, object, i)
		if (rt.completion.status != 0): break
		if (present == 0): continue
		js_value* value = js_ap_get(rt, object, i)
		if (rt.completion.status != 0): break
		if (js_runtime_equal(search, value)):
			result = i
			break
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_number(rt, cast(float64, result))
