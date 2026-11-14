# Generic bounded array iteration: every, some, forEach, map, filter, find,
# findIndex, findLast, findLastIndex, reduce and reduceRight. Length is
# snapshotted before the callback is validated; HasProperty precedes Get except
# for the find family, which visits holes. map and filter build their result
# through ArraySpeciesCreate. Each visited position is charged to the budget and
# every callback runs under a depth slot, so exhaustion and recursion are
# reported as limit failures with the depth restored.
# https://tc39.es/ecma262/#sec-array.prototype.map
# https://tc39.es/ecma262/#sec-array.prototype.reduce
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_array_like
import libs.extras.javascript.runtime_array


const int JS_AP_EVERY = 0
const int JS_AP_FOREACH = 1
const int JS_AP_MAP = 2
const int JS_AP_FILTER = 3
const int JS_AP_FIND = 4
const int JS_AP_FIND_INDEX = 5
const int JS_AP_FIND_LAST = 6
const int JS_AP_FIND_LAST_INDEX = 7
const int JS_AP_REDUCE = 8
const int JS_AP_REDUCE_RIGHT = 9
const int JS_AP_SOME = 10


js_value* js_ap_iteration_body(js_runtime* rt, int operation, js_value* receiver, list[js_value*] args):
	js_value* object = js_ap_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_ap_length(rt, object)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* callback = rt.undefined_value
	if (args.length > 0): callback = args[0]
	if (js_runtime_callable(callback) == 0):
		js_runtime_fail(rt, 2, c"array iteration callback is not callable")
		return rt.undefined_value
	int reduce = operation == JS_AP_REDUCE || operation == JS_AP_REDUCE_RIGHT
	int find = operation >= JS_AP_FIND && operation <= JS_AP_FIND_LAST_INDEX
	int backward = operation == JS_AP_REDUCE_RIGHT || operation == JS_AP_FIND_LAST || operation == JS_AP_FIND_LAST_INDEX
	js_value* result = rt.undefined_value
	js_value* this_value = rt.undefined_value
	if (args.length > 1):
		if (reduce): result = args[1]
		else: this_value = args[1]
	int accumulated = reduce && args.length > 1
	if (operation == JS_AP_EVERY): result = js_runtime_boolean(rt, 1)
	if (operation == JS_AP_SOME): result = js_runtime_boolean(rt, 0)
	if (operation == JS_AP_FIND_INDEX || operation == JS_AP_FIND_LAST_INDEX): result = js_runtime_number(rt, -1.0)
	if (operation == JS_AP_MAP || operation == JS_AP_FILTER):
		int size = 0
		if (operation == JS_AP_MAP): size = length
		result = js_ap_species_create(rt, object, size)
		if (rt.completion.status != 0): return rt.undefined_value
	list[js_value*] values = new list[js_value*]
	values.push(rt.undefined_value)
	values.push(rt.undefined_value)
	values.push(object)
	if (reduce): values.push(object)
	int to = 0
	for offset in range(length):
		if (js_runtime_compat_step(rt) == 0): break
		int index = offset
		if (backward): index = length - offset - 1
		int present = 1
		if (find == 0): present = js_ap_has(rt, object, index)
		if (rt.completion.status != 0): break
		if (present == 0): continue
		js_value* value = js_ap_get(rt, object, index)
		if (rt.completion.status != 0): break
		if (reduce && accumulated == 0):
			result = value
			accumulated = 1
			continue
		js_value* position = js_runtime_number(rt, cast(float64, index))
		if (rt.completion.status != 0): break
		if (reduce):
			values[0] = result
			values[1] = value
			values[2] = position
		else:
			values[0] = value
			values[1] = position
		js_value* selected = js_runtime_call_receiver(rt, callback, this_value, values)
		if (rt.completion.status != 0): break
		if (reduce): result = selected
		else if (operation == JS_AP_EVERY && js_runtime_truth(selected) == 0):
			result = js_runtime_boolean(rt, 0)
			break
		else if (operation == JS_AP_SOME && js_runtime_truth(selected)):
			result = js_runtime_boolean(rt, 1)
			break
		else if (find && js_runtime_truth(selected)):
			result = value
			if (operation == JS_AP_FIND_INDEX || operation == JS_AP_FIND_LAST_INDEX): result = position
			break
		else if (operation == JS_AP_MAP): js_ap_create(rt, result, index, selected)
		else if (operation == JS_AP_FILTER && js_runtime_truth(selected)):
			js_ap_create(rt, result, to, value)
			to = to + 1
	__w_list_free(cast(__w_list*, values))
	if (rt.completion.status == 0 && reduce && accumulated == 0): js_runtime_fail(rt, 2, c"reduce of empty array without initial value")
	if (rt.completion.status != 0): return rt.undefined_value
	return result


js_value* js_ap_iteration(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0 || js_ap_enter(rt) == 0): return rt.undefined_value
	js_value* result = js_ap_iteration_body(rt, cast(int, context), receiver, args)
	js_ap_leave(rt)
	return result
