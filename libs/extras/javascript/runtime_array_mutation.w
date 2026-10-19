# Generic bounded Array end mutations. Every write is Set(..., true), every
# removal DeletePropertyOrThrow; movement observes inherited and sparse keys.
# https://tc39.es/ecma262/#sec-array.prototype.push
import libs.extras.javascript.runtime

int js_array_mutation_set(js_runtime* rt, js_value* object, int index, js_value* value):
	if (rt.completion.status != 0): return 0
	char* key = itoa(index)
	int success = js_runtime_set(rt, object, key, value)
	free(key)
	if (success == 0): js_runtime_fail(rt, 2, c"array mutation element write rejected")
	return rt.completion.status == 0

int js_array_mutation_delete(js_runtime* rt, js_value* object, int index):
	if (rt.completion.status != 0): return 0
	# Native hosts expose Get/Has/Set but have no Delete internal-method hook.
	if (js_object_ordinary(rt, object) == 0): return 0
	char* raw = itoa(index)
	js_text* key = js_runtime_key(raw)
	free(raw)
	int success = js_runtime_delete(rt, object, key)
	js_text_free(key)
	if (success == 0): js_runtime_fail(rt, 2, c"array mutation element deletion rejected")
	return rt.completion.status == 0

int js_array_mutation_length(js_runtime* rt, js_value* object, int length):
	if (rt.completion.status != 0): return 0
	js_value* value = js_runtime_number(rt, cast(float64, length))
	if (rt.completion.status != 0): return 0
	if (js_runtime_set(rt, object, c"length", value) == 0): js_runtime_fail(rt, 2, c"array mutation length write rejected")
	return rt.completion.status == 0

int js_array_mutation_move(js_runtime* rt, js_value* object, int from, int to):
	int present = js_array_like_has(rt, object, from)
	if (rt.completion.status != 0): return 0
	if (present): return js_array_mutation_set(rt, object, to, js_runtime_index_get(rt, object, from))
	return js_array_mutation_delete(rt, object, to)

js_value* js_array_mutation(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_boxed_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_function_array_length(rt, js_runtime_get(rt, object, c"length"))
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
				if (js_array_mutation_move(rt, object, from, from + args.length) == 0): break
		for i in range(args.length):
			if (js_runtime_compat_step(rt) == 0): break
			int index = i
			if (operation == 1): index = length + i
			if (js_array_mutation_set(rt, object, index, args[i]) == 0): break
		int next_length = length + args.length
		if (js_array_mutation_length(rt, object, next_length) == 0): return rt.undefined_value
		return js_runtime_number(rt, cast(float64, next_length))
	if (length == 0):
		js_array_mutation_length(rt, object, 0)
		return rt.undefined_value
	if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
	int index = 0
	if (operation == 2): index = length - 1
	js_value* result = js_runtime_index_get(rt, object, index)
	if (rt.completion.status != 0): return rt.undefined_value
	if (operation == 3):
		for from in range(1, length):
			if (js_runtime_compat_step(rt) == 0): break
			if (js_array_mutation_move(rt, object, from, from - 1) == 0): break
	if (js_array_mutation_delete(rt, object, length - 1) == 0): return rt.undefined_value
	if (js_array_mutation_length(rt, object, length - 1) == 0): return rt.undefined_value
	return result

void js_runtime_install_array_mutation(js_runtime* rt):
	js_object_method(rt, rt.array_prototype, c"push", js_array_mutation, 1, 1)
	js_object_method(rt, rt.array_prototype, c"pop", js_array_mutation, 2, 0)
	js_object_method(rt, rt.array_prototype, c"shift", js_array_mutation, 3, 0)
	js_object_method(rt, rt.array_prototype, c"unshift", js_array_mutation, 4, 1)
