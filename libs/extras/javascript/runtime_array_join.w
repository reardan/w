# Generic Array.prototype.join and toString. Length is snapshotted before
# separator conversion; every position is Get, even holes, and all temporary
# UTF-16 buffers unwind on exceptions, cancellation and execution limits.
import libs.extras.javascript.runtime

int js_join_append(js_runtime* rt, js_text* output, js_text* text):
	if (text.units.length > rt.max_properties - output.units.length):
		js_runtime_fail(rt, 5, c"JavaScript join string length limit")
		return 0
	if (js_equality_charge(rt, text.units.length) == 0): return 0
	for i in range(text.units.length): output.units.push(text.units[i])
	return 1

js_value* js_array_join(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_boxed_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_function_array_length(rt, js_runtime_get(rt, object, c"length"))
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* separator = 0
	js_value* argument = js_object_argument(rt, args, 0)
	if (argument.kind == 0): separator = js_runtime_key(c",")
	else: separator = js_runtime_string_text(rt, argument)
	if (separator == 0): return rt.undefined_value
	js_text* output = js_text_new()
	int active = object.join_active
	object.join_active = 1
	if (active == 0):
		for i in range(length):
			if (js_runtime_compat_step(rt) == 0): break
			if (i > 0 && js_join_append(rt, output, separator) == 0): break
			js_value* value = js_runtime_index_get(rt, object, i)
			if (rt.completion.status != 0): break
			if (value.kind == 0 || value.kind == 1): continue
			js_text* item = js_runtime_string_text(rt, value)
			if (item == 0): break
			js_join_append(rt, output, item)
			js_text_free(item)
	object.join_active = active
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, output)
	js_text_free(output)
	js_text_free(separator)
	return result

js_value* js_array_to_string(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_boxed_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* join = js_runtime_get(rt, object, c"join")
	if (rt.completion.status != 0): return rt.undefined_value
	list[js_value*] empty = new list[js_value*]
	js_value* result = rt.undefined_value
	if (js_function_callable(join)): result = js_runtime_call_receiver(rt, join, object, empty)
	else: result = js_object_prototype_method(rt, cast(void*, 2), object, empty)
	__w_list_free(cast(__w_list*, empty))
	return result

void js_runtime_install_array_join(js_runtime* rt):
	rt.array_prototype.prototype = rt.object_prototype
	js_object_method(rt, rt.array_prototype, c"join", js_array_join, 0, 1)
	js_object_method(rt, rt.array_prototype, c"toString", js_array_to_string, 0, 0)
