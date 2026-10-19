# Reflect.construct validates constructability before touching argumentsList;
# list Get operations precede prototype lookup and constructor execution.
# https://tc39.es/ecma262/#sec-reflect.construct
import libs.extras.javascript.runtime

js_value* js_reflect_construct(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* target = js_object_argument(rt, args, 0)
	js_value* new_target = target
	if (args.length > 2): new_target = args[2]
	if (target.owner != rt || new_target.owner != rt || js_function_constructable(rt, target) == 0 || js_function_constructable(rt, new_target) == 0):
		js_runtime_fail(rt, 2, c"Reflect.construct requires constructor target and newTarget")
		return rt.undefined_value
	js_value* object = js_object_argument(rt, args, 1)
	if (object.owner != rt || js_runtime_object(object) == 0):
		js_runtime_fail(rt, 2, c"Reflect.construct argumentsList must be an object")
		return rt.undefined_value
	if (js_function_enter(rt) == 0): return rt.undefined_value
	list[js_value*] forwarded = new list[js_value*]
	js_value* length_value = js_runtime_get(rt, object, c"length")
	int length = 0
	if (rt.completion.status == 0): length = js_function_array_length(rt, length_value)
	for i in range(length):
		if (js_runtime_compat_step(rt) == 0): break
		js_value* value = js_runtime_index_get(rt, object, i)
		if (rt.completion.status != 0): break
		forwarded.push(value)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_construct(rt, target, forwarded, new_target)
	__w_list_free(cast(__w_list*, forwarded))
	rt.depth = rt.depth - 1
	return result

void js_runtime_install_reflect_construct(js_runtime* rt):
	js_object_method(rt, js_runtime_get(rt, rt.global, c"Reflect"), c"construct", js_reflect_construct, 0, 2)
