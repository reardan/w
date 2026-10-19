# Bounded concat preserves holes and inherited live Get/Has behavior. Symbols,
# Symbol.species and Symbol.isConcatSpreadable remain a separate mandatory gap.
# https://tc39.es/ecma262/#sec-array.prototype.concat
import libs.extras.javascript.runtime

js_value* js_array_concat(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_boxed_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	if (object.kind == 6):
		js_value* constructor = js_runtime_get(rt, object, c"constructor")
		if (rt.completion.status != 0): return rt.undefined_value
		if (constructor.kind != 0 && js_runtime_object(constructor) == 0):
			js_runtime_fail(rt, 2, c"array species constructor is not an object")
			return rt.undefined_value
		if (constructor.host_get != 0 || constructor.host_has != 0):
			js_runtime_fail(rt, 6, c"host array species lookup requires Symbol hooks")
			return rt.undefined_value
	js_value* result = js_runtime_alloc(rt, 6)
	if (rt.completion.status != 0): return rt.undefined_value
	int position = 0
	for i in range(args.length + 1):
		if (js_runtime_compat_step(rt) == 0): break
		js_value* item = object
		if (i > 0): item = args[i - 1]
		if (item.kind != 6):
			if (position >= rt.max_properties):
				js_runtime_fail(rt, 5, c"concat output length limit")
				break
			js_array_iteration_store(rt, result, position, item)
			position = position + 1
		else:
			int length = js_function_array_length(rt, js_runtime_get(rt, item, c"length"))
			if (rt.completion.status != 0): break
			if (length > rt.max_properties - position):
				js_runtime_fail(rt, 5, c"concat output length limit")
				break
			for j in range(length):
				if (js_runtime_compat_step(rt) == 0): break
				int present = js_array_like_has(rt, item, j)
				if (rt.completion.status != 0): break
				if (present):
					js_value* value = js_runtime_index_get(rt, item, j)
					if (rt.completion.status == 0): js_array_iteration_store(rt, result, position, value)
				if (rt.completion.status != 0): break
				position = position + 1
		if (rt.completion.status != 0): break
	if (rt.completion.status != 0): return rt.undefined_value
	result.array_length = position
	return result

void js_runtime_install_array_concat(js_runtime* rt):
	js_object_method(rt, rt.array_prototype, c"concat", js_array_concat, 0, 1)
