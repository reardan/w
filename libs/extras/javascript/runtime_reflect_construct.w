# Reflect.construct validates constructability before touching argumentsList;
# list Get operations precede prototype lookup and constructor execution.
# Reflect.apply shares the bounded CreateListFromArrayLike.
# https://tc39.es/ecma262/#sec-reflect.construct
import libs.extras.javascript.runtime_object

# CreateListFromArrayLike: the length is capped by max_properties and every
# element read charges one evaluation step. Returns an owned list, or 0.
list[js_value*] js_reflect_list(js_runtime* rt, js_value* object):
	if (object.owner != rt || js_runtime_object(object) == 0):
		js_runtime_fail(rt, 2, c"argumentsList must be an object")
		return 0
	if (rt.depth >= rt.max_depth):
		js_runtime_fail(rt, 5, c"JavaScript call depth limit")
		return 0
	js_value* length_value = js_runtime_get(rt, object, c"length")
	if (rt.completion.status != 0): return 0
	int length = js_runtime_to_length(rt, length_value)
	if (rt.completion.status != 0): return 0
	if (length > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript argument list limit")
		return 0
	list[js_value*] forwarded = new list[js_value*]
	for i in range(length):
		if (js_runtime_compat_step(rt) == 0): break
		js_value* value = js_runtime_index_get(rt, object, i)
		if (rt.completion.status != 0): break
		forwarded.push(value)
	if (rt.completion.status != 0):
		__w_list_free(cast(__w_list*, forwarded))
		return 0
	return forwarded

# Code 0 construct, 1 apply.
js_value* js_reflect_construct(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* target = js_object_argument(rt, args, 0)
	if (cast(int, context) == 1):
		if (target.owner != rt || js_runtime_callable(target) == 0):
			js_runtime_fail(rt, 2, c"Reflect.apply target is not callable")
			return rt.undefined_value
		list[js_value*] applied = js_reflect_list(rt, js_object_argument(rt, args, 2))
		if (applied == 0): return rt.undefined_value
		js_value* outcome = js_runtime_call_receiver(rt, target, js_object_argument(rt, args, 1), applied)
		__w_list_free(cast(__w_list*, applied))
		return outcome
	js_value* new_target = target
	if (args.length > 2): new_target = args[2]
	if (target.owner != rt || new_target.owner != rt || js_runtime_is_constructor(rt, target) == 0 || js_runtime_is_constructor(rt, new_target) == 0):
		js_runtime_fail(rt, 2, c"Reflect.construct requires constructor target and newTarget")
		return rt.undefined_value
	list[js_value*] forwarded = js_reflect_list(rt, js_object_argument(rt, args, 1))
	if (forwarded == 0): return rt.undefined_value
	rt.depth = rt.depth + 1
	js_value* result = js_runtime_construct(rt, target, forwarded, new_target)
	rt.depth = rt.depth - 1
	__w_list_free(cast(__w_list*, forwarded))
	return result

void js_object_install_reflect_construct(js_runtime* rt):
	js_value* reflect = js_runtime_get(rt, rt.global_object, c"Reflect")
	js_object_method(rt, reflect, c"construct", js_reflect_construct, 0, 2)
	js_object_method(rt, reflect, c"apply", js_reflect_construct, 1, 3)
