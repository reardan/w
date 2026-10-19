# Shared bounded Function.prototype call/apply/bind and bound function records.
# https://tc39.es/ecma262/#sec-function.prototype.bind
import libs.extras.javascript.runtime

int js_function_callable(js_value* value):
	return value != 0 && (value.kind == 7 || value.kind == 9)

int js_function_constructable(js_runtime* rt, js_value* value):
	if (js_function_callable(value) == 0): return 0
	return js_class_is_constructor(value) || value == rt.promise_constructor || value.binary_constructor != 0 || value.host_construct != 0

int js_function_enter(js_runtime* rt):
	if (rt.depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
		js_runtime_fail(rt, 5, c"JavaScript callable forwarding depth limit")
		return 0
	rt.depth = rt.depth + 1
	return 1

int js_function_append(js_runtime* rt, list[js_value*] target, list[js_value*] source, int start):
	if (source.length - start > rt.max_properties - target.length):
		js_runtime_fail(rt, 5, c"JavaScript forwarded argument limit")
		return 0
	for i in range(start, source.length):
		if (js_runtime_compat_step(rt) == 0): return 0
		target.push(source[i])
	return 1

# Shared construction dispatch lets bound functions forward native constructors
# while preserving the ordinary/class new-target receiver path.
js_value* js_runtime_construct(js_runtime* rt, js_value* callable, list[js_value*] args, js_value* new_target):
	if (callable == 0 || new_target == 0 || callable.owner != rt || new_target.owner != rt || js_function_constructable(rt, callable) == 0 || js_function_constructable(rt, new_target) == 0):
		js_runtime_fail(rt, 2, c"construction requires owned constructors")
		return rt.undefined_value
	if (args.length > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript constructor argument limit")
		return rt.undefined_value
	for i in range(args.length):
		if (args[i] == 0 || args[i].owner != rt):
			js_runtime_fail(rt, 2, c"foreign constructor argument")
			return rt.undefined_value
	if (callable.bound_target != 0): return js_function_bound(rt, callable, args, new_target)
	if (js_class_is_constructor(callable)): return js_class_construct(rt, callable, args, new_target)
	if (new_target != callable):
		js_runtime_fail(rt, 6, c"native subclass construction is outside the runtime subset")
		return rt.undefined_value
	if (callable == rt.promise_constructor): return js_runtime_promise_construct(rt, args)
	if (callable.binary_constructor != 0): return js_runtime_binary_construct(rt, callable.binary_constructor, args)
	if (callable.boxed_constructor): return js_boxed_construct(rt, callable.boxed_constructor, args)
	if (callable.host_construct): return js_runtime_call_native(rt, callable, rt.undefined_value, args)
	if (js_function_callable(callable) == 0 || (callable.code != 0 && (callable.code.async_function || js_kind(callable.code, c"method") || js_kind(callable.code, c"static_method") || js_kind(callable.code, c"arrow")))):
		js_runtime_fail(rt, 2, c"value is not a constructor")
	else: js_runtime_fail(rt, 6, c"unsupported native constructor")
	return rt.undefined_value

js_value* js_function_bound(js_runtime* rt, js_value* callable, list[js_value*] args, js_value* new_target):
	if (new_target != 0 && callable.host_construct == 0):
		js_runtime_fail(rt, 2, c"bound target is not a constructor")
		return rt.undefined_value
	if (js_function_enter(rt) == 0): return rt.undefined_value
	list[js_value*] forwarded = new list[js_value*]
	js_function_append(rt, forwarded, callable.bound_arguments, 0)
	if (rt.completion.status == 0): js_function_append(rt, forwarded, args, 0)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0):
		if (new_target == 0): result = js_runtime_call_receiver(rt, callable.bound_target, callable.bound_receiver, forwarded)
		else:
			if (new_target == callable): new_target = callable.bound_target
			result = js_runtime_construct(rt, callable.bound_target, forwarded, new_target)
	__w_list_free(cast(__w_list*, forwarded))
	rt.depth = rt.depth - 1
	return result

# ToLength for supported array-like inputs. Objects use ordinary number-hint
# conversion; strings use the complete numeric grammar, not parseFloat.
int js_function_array_length(js_runtime* rt, js_value* value):
	if (js_runtime_object(value)):
		value = js_equality_primitive(rt, value)
		if (rt.completion.status != 0): return 0
	float64 length = 0.0
	if (value.kind == 2 || value.kind == 3): length = value.number
	else if (value.kind == 4): length = js_equality_number(rt, value.text)
	else if (value.kind == 10):
		js_runtime_fail(rt, 2, c"BigInt cannot be an array-like length")
		return 0
	if (f64is_nan(length) || length <= 0.0): return 0
	length = js_builtin_trunc(length)
	if (length > cast(float64, rt.max_properties)):
		js_runtime_fail(rt, 5, c"JavaScript array-like argument limit")
		return 0
	return cast(int, length)

js_value* js_function_bind(js_runtime* rt, js_value* target, list[js_value*] args):
	if (target.host_get != 0 || target.host_set != 0):
		js_runtime_fail(rt, 6, c"native callable descriptor reflection is unsupported")
		return rt.undefined_value
	js_value* bound = js_runtime_alloc(rt, 7)
	if (rt.completion.status != 0): return rt.undefined_value
	bound.prototype = target.prototype
	bound.bound_target = target
	bound.bound_receiver = rt.undefined_value
	if (args.length > 0): bound.bound_receiver = args[0]
	bound.bound_arguments = new list[js_value*]
	int start = 0
	if (args.length > 0): start = 1
	js_function_append(rt, bound.bound_arguments, args, start)
	bound.host_construct = js_function_constructable(rt, target)
	float64 length = 0.0
	js_text* key = js_runtime_key(c"length")
	int own_length = js_runtime_property(target, key) != 0
	js_text_free(key)
	if (rt.completion.status == 0 && own_length):
		js_value* value = js_runtime_get(rt, target, c"length")
		if (value.kind == 3 && f64is_nan(value.number) == 0):
			length = js_builtin_trunc(value.number) - cast(float64, bound.bound_arguments.length)
			if (length < 0.0): length = 0.0
	if (rt.completion.status != 0): return rt.undefined_value
	js_class_define(rt, bound, c"length", js_runtime_number(rt, length), 0, 1)
	js_value* name = js_runtime_get(rt, target, c"name")
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* text = js_runtime_key(c"bound ")
	if (name.kind == 4):
		if (name.text.units.length > rt.max_properties - 6 || js_equality_charge(rt, name.text.units.length) == 0):
			js_runtime_fail(rt, 5, c"bound function name length limit")
		else:
			for i in range(name.text.units.length): text.units.push(name.text.units[i])
	if (rt.completion.status == 0): js_class_define(rt, bound, c"name", js_runtime_string(rt, text), 0, 1)
	js_text_free(text)
	if (rt.completion.status != 0): return rt.undefined_value
	return bound

# operation: 1 call, 2 apply, 3 bind. Each wrapper shares a depth/fuel budget,
# including a native wrapper forwarding to itself without entering an AST.
js_value* js_function_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_function_callable(receiver) == 0):
		js_runtime_fail(rt, 2, c"Function method receiver is not callable")
		return rt.undefined_value
	if (js_builtin_arguments(rt, args) == 0 || js_function_enter(rt) == 0): return rt.undefined_value
	int operation = cast(int, context)
	if (operation == 3):
		js_value* bound = js_function_bind(rt, receiver, args)
		rt.depth = rt.depth - 1
		return bound
	js_value* this_value = rt.undefined_value
	if (args.length > 0): this_value = args[0]
	list[js_value*] forwarded = new list[js_value*]
	if (operation == 1):
		int start = 0
		if (args.length > 0): start = 1
		js_function_append(rt, forwarded, args, start)
	else if (args.length > 1 && args[1].kind > 1):
		js_value* object = args[1]
		if (js_runtime_object(object) == 0): js_runtime_fail(rt, 2, c"apply arguments must be array-like object")
		else:
			js_value* length_value = js_runtime_get(rt, object, c"length")
			int length = 0
			if (rt.completion.status == 0): length = js_function_array_length(rt, length_value)
			for i in range(length):
				if (js_runtime_compat_step(rt) == 0): break
				js_value* value = js_runtime_index_get(rt, object, i)
				if (rt.completion.status != 0): break
				forwarded.push(value)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_call_receiver(rt, receiver, this_value, forwarded)
	__w_list_free(cast(__w_list*, forwarded))
	rt.depth = rt.depth - 1
	return result

js_value* js_function_empty(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_builtin_arguments(rt, args)
	return rt.undefined_value

js_value* js_function_dynamic(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_runtime_fail(rt, 6, c"dynamic Function construction is outside the runtime subset")
	return rt.undefined_value

void js_function_method_install(js_runtime* rt, char* name, int length, int operation):
	js_value* method = js_runtime_host_callable(rt, cast(void*, operation), js_function_method)
	js_class_define(rt, method, c"name", js_class_string(rt, name), 0, 1)
	js_class_define(rt, method, c"length", js_runtime_number(rt, cast(float64, length)), 0, 1)
	js_class_define(rt, rt.function_prototype, name, method, 1, 1)

void js_runtime_install_function(js_runtime* rt):
	rt.function_prototype = js_runtime_host_callable(rt, 0, js_function_empty)
	js_class_define(rt, rt.function_prototype, c"name", js_class_string(rt, c""), 0, 1)
	js_class_define(rt, rt.function_prototype, c"length", js_runtime_number(rt, 0.0), 0, 1)
	js_value* constructor = js_runtime_host_callable(rt, 0, js_function_dynamic)
	constructor.host_construct = 1
	js_class_define(rt, constructor, c"name", js_class_string(rt, c"Function"), 0, 1)
	js_class_define(rt, constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, constructor, c"prototype", rt.function_prototype, 0, 0)
	js_class_define(rt, rt.function_prototype, c"constructor", constructor, 1, 1)
	js_function_method_install(rt, c"call", 1, 1)
	js_function_method_install(rt, c"apply", 2, 2)
	js_function_method_install(rt, c"bind", 1, 3)
	js_runtime_set(rt, rt.global, c"Function", constructor)
	js_class_define(rt, rt.global, c"Function", constructor, 1, 1)
