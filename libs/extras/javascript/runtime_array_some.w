# Generic Some: snapshot length, presence before Get, and early truthy exit.
# https://tc39.es/ecma262/#sec-array.prototype.some
import libs.extras.javascript.runtime

js_value* js_array_some_body(js_runtime* rt, js_value* receiver, list[js_value*] args):
	js_value* object = js_array_like_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_function_array_length(rt, js_runtime_get(rt, object, c"length"))
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* callback = rt.undefined_value
	if (args.length > 0): callback = args[0]
	if (js_function_callable(callback) == 0):
		js_runtime_fail(rt, 2, c"some callback is not callable")
		return rt.undefined_value
	js_value* this_value = rt.undefined_value
	if (args.length > 1): this_value = args[1]
	list[js_value*] values = new list[js_value*]
	values.push(rt.undefined_value)
	values.push(rt.undefined_value)
	values.push(object)
	int found = 0
	for i in range(length):
		if (js_runtime_compat_step(rt) == 0): break
		if (js_array_like_has(rt, object, i)):
			if (rt.max_properties < 3):
				js_runtime_fail(rt, 5, c"some callback argument limit")
				break
			values[0] = js_runtime_index_get(rt, object, i)
			values[1] = js_runtime_number(rt, cast(float64, i))
			if (rt.completion.status != 0): break
			js_value* result = js_runtime_call_receiver(rt, callback, this_value, values)
			if (rt.completion.status != 0): break
			if (js_runtime_truth(result)):
				found = 1
				break
	__w_list_free(cast(__w_list*, values))
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_boolean(rt, found)

js_value* js_array_some(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_function_enter(rt) == 0): return rt.undefined_value
	js_value* result = js_array_some_body(rt, receiver, args)
	rt.depth = rt.depth - 1
	return result

void js_runtime_install_some(js_runtime* rt):
	js_value* method = js_runtime_host_callable(rt, 0, js_array_some)
	js_class_define(rt, method, c"name", js_class_string(rt, c"some"), 0, 1)
	js_class_define(rt, method, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, rt.array_prototype, c"some", method, 1, 1)
