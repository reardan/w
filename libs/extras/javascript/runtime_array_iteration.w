# Generic bounded array iteration. HasProperty precedes Get except for find*,
# which visit holes. Every method snapshots length before invoking callbacks.
# https://tc39.es/ecma262/#sec-array.prototype.map
# https://tc39.es/ecma262/#sec-array.prototype.reduce
import libs.extras.javascript.runtime

const int JS_ARRAY_EVERY = 0
const int JS_ARRAY_FOREACH = 1
const int JS_ARRAY_MAP = 2
const int JS_ARRAY_FILTER = 3
const int JS_ARRAY_FIND = 4
const int JS_ARRAY_FIND_INDEX = 5
const int JS_ARRAY_FIND_LAST = 6
const int JS_ARRAY_FIND_LAST_INDEX = 7
const int JS_ARRAY_REDUCE = 8
const int JS_ARRAY_REDUCE_RIGHT = 9

void js_array_iteration_store(js_runtime* rt, js_value* array, int index, js_value* value):
	char* raw = itoa(index)
	js_text* key = js_runtime_key(raw)
	free(raw)
	js_runtime_define_data(rt, array, key, value, 1, 1, 1)
	js_text_free(key)
	if (rt.completion.status == 0 && index >= array.array_length): array.array_length = index + 1

js_value* js_array_iteration_body(js_runtime* rt, int operation, js_value* receiver, list[js_value*] args):
	js_value* object = js_array_like_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_function_array_length(rt, js_runtime_get(rt, object, c"length"))
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* callback = rt.undefined_value
	if (args.length > 0): callback = args[0]
	if (js_function_callable(callback) == 0):
		js_runtime_fail(rt, 2, c"array iteration callback is not callable")
		return rt.undefined_value
	int reduce = operation >= JS_ARRAY_REDUCE
	int find = operation >= JS_ARRAY_FIND && operation <= JS_ARRAY_FIND_LAST_INDEX
	int backward = operation == JS_ARRAY_REDUCE_RIGHT || operation == JS_ARRAY_FIND_LAST || operation == JS_ARRAY_FIND_LAST_INDEX
	js_value* result = rt.undefined_value
	js_value* this_value = rt.undefined_value
	if (args.length > 1):
		if (reduce): result = args[1]
		else: this_value = args[1]
	int accumulated = reduce && args.length > 1
	if (operation == JS_ARRAY_EVERY): result = js_runtime_boolean(rt, 1)
	if (operation == JS_ARRAY_FIND_INDEX || operation == JS_ARRAY_FIND_LAST_INDEX): result = js_runtime_number(rt, -1.0)
	if (operation == JS_ARRAY_MAP || operation == JS_ARRAY_FILTER):
		# Symbols/species are outside the runtime profile. Preserve the
		# constructor Get and primitive-constructor error, as slice does.
		if (object.kind == 6):
			js_value* constructor = js_runtime_get(rt, object, c"constructor")
			if (rt.completion.status == 0 && constructor.kind != 0 && js_runtime_object(constructor) == 0): js_runtime_fail(rt, 2, c"array species constructor is not an object")
		if (rt.completion.status != 0): return rt.undefined_value
		result = js_runtime_alloc(rt, 6)
		if (rt.completion.status != 0): return rt.undefined_value
		if (operation == JS_ARRAY_MAP): result.array_length = length
	list[js_value*] values = new list[js_value*]
	values.push(rt.undefined_value)
	values.push(rt.undefined_value)
	values.push(object)
	if (reduce): values.push(object)
	for offset in range(length):
		if (js_runtime_compat_step(rt) == 0): break
		int index = offset
		if (backward): index = length - offset - 1
		int present = 1
		if (find == 0): present = js_array_like_has(rt, object, index)
		if (rt.completion.status != 0): break
		if (present == 0): continue
		js_value* value = js_runtime_index_get(rt, object, index)
		if (rt.completion.status != 0): break
		if (reduce && accumulated == 0):
			result = value
			accumulated = 1
			continue
		if (values.length > rt.max_properties):
			js_runtime_fail(rt, 5, c"array callback argument limit")
			break
		if (reduce):
			values[0] = result
			values[1] = value
			values[2] = js_runtime_number(rt, cast(float64, index))
		else:
			values[0] = value
			values[1] = js_runtime_number(rt, cast(float64, index))
		if (rt.completion.status != 0): break
		js_value* selected = js_runtime_call_receiver(rt, callback, this_value, values)
		if (rt.completion.status != 0): break
		if (reduce): result = selected
		else if (operation == JS_ARRAY_EVERY && js_runtime_truth(selected) == 0):
			result = js_runtime_boolean(rt, 0)
			break
		else if (find && js_runtime_truth(selected)):
			result = value
			if (operation == JS_ARRAY_FIND_INDEX || operation == JS_ARRAY_FIND_LAST_INDEX): result = values[1]
			break
		else if (operation == JS_ARRAY_MAP): js_array_iteration_store(rt, result, index, selected)
		else if (operation == JS_ARRAY_FILTER && js_runtime_truth(selected)): js_array_iteration_store(rt, result, result.array_length, value)
	__w_list_free(cast(__w_list*, values))
	if (rt.completion.status == 0 && reduce && accumulated == 0): js_runtime_fail(rt, 2, c"reduce of empty array without initial value")
	if (rt.completion.status != 0): return rt.undefined_value
	return result

js_value* js_array_iteration(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_function_enter(rt) == 0): return rt.undefined_value
	js_value* result = js_array_iteration_body(rt, cast(int, context), receiver, args)
	rt.depth = rt.depth - 1
	return result

void js_array_iteration_install(js_runtime* rt, char* name, int operation):
	js_value* method = js_runtime_host_callable(rt, cast(void*, operation), js_array_iteration)
	js_class_define(rt, method, c"name", js_class_string(rt, name), 0, 1)
	js_class_define(rt, method, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, rt.array_prototype, name, method, 1, 1)

void js_runtime_install_array_iteration(js_runtime* rt):
	js_array_iteration_install(rt, c"every", JS_ARRAY_EVERY)
	js_array_iteration_install(rt, c"forEach", JS_ARRAY_FOREACH)
	js_array_iteration_install(rt, c"map", JS_ARRAY_MAP)
	js_array_iteration_install(rt, c"filter", JS_ARRAY_FILTER)
	js_array_iteration_install(rt, c"find", JS_ARRAY_FIND)
	js_array_iteration_install(rt, c"findIndex", JS_ARRAY_FIND_INDEX)
	js_array_iteration_install(rt, c"findLast", JS_ARRAY_FIND_LAST)
	js_array_iteration_install(rt, c"findLastIndex", JS_ARRAY_FIND_LAST_INDEX)
	js_array_iteration_install(rt, c"reduce", JS_ARRAY_REDUCE)
	js_array_iteration_install(rt, c"reduceRight", JS_ARRAY_REDUCE_RIGHT)
