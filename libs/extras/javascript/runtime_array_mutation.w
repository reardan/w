# Generic bounded Array end mutations (push, pop, shift, unshift). Every write
# is Set(..., true) and every removal DeletePropertyOrThrow; element movement
# observes inherited and sparse keys, and each moved element is charged.
# https://tc39.es/ecma262/#sec-array.prototype.push
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_array_like


int js_ap_move(js_runtime* rt, js_value* object, int from, int to):
	int present = js_ap_has(rt, object, from)
	if (rt.completion.status != 0): return 0
	if (present):
		js_value* value = js_ap_get(rt, object, from)
		if (rt.completion.status != 0): return 0
		return js_ap_set(rt, object, to, value)
	return js_ap_delete(rt, object, to)


# Context: 1 push, 2 pop, 3 shift, 4 unshift.
js_value* js_ap_mutation(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_ap_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_ap_length(rt, object)
	if (rt.completion.status != 0): return rt.undefined_value
	int operation = cast(int, context)
	if (operation == 1 || operation == 4):
		if (length > rt.max_properties - args.length):
			js_runtime_fail(rt, 5, c"array mutation length limit")
			return rt.undefined_value
		if (operation == 4 && args.length > 0):
			for offset in range(length):
				if (js_runtime_compat_step(rt) == 0): break
				int from = length - offset - 1
				if (js_ap_move(rt, object, from, from + args.length) == 0): break
		for i in range(args.length):
			if (js_runtime_compat_step(rt) == 0): break
			int index = i
			if (operation == 1): index = length + i
			if (js_ap_set(rt, object, index, args[i]) == 0): break
		int next_length = length + args.length
		if (js_ap_set_length(rt, object, next_length) == 0): return rt.undefined_value
		return js_runtime_number(rt, cast(float64, next_length))
	if (length == 0):
		js_ap_set_length(rt, object, 0)
		return rt.undefined_value
	if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
	int index = 0
	if (operation == 2): index = length - 1
	js_value* result = js_ap_get(rt, object, index)
	if (rt.completion.status != 0): return rt.undefined_value
	if (operation == 3):
		for from in range(1, length):
			if (js_runtime_compat_step(rt) == 0): break
			if (js_ap_move(rt, object, from, from - 1) == 0): break
	if (js_ap_delete(rt, object, length - 1) == 0): return rt.undefined_value
	if (js_ap_set_length(rt, object, length - 1) == 0): return rt.undefined_value
	return result
