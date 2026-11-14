# Function.prototype call/apply/bind/toString, bound function records and the
# callable Function.prototype. Every wrapper shares one depth/step budget with
# the evaluator, including a native wrapper forwarding to itself without ever
# entering an AST, and every forwarded argument list is bounded by
# max_properties. A bound function is a host callable (kind 9) whose context is
# itself: function_object holds [[BoundTargetFunction]], this_value the
# [[BoundThis]] and reactions the [[BoundArguments]], all traced by the
# collector. js_runtime_construct and js_runtime_instanceof call back into
# js_function_bound_construct / js_function_is_bound.
# https://tc39.es/ecma262/#sec-function.prototype.bind
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_object
import libs.extras.javascript.runtime_reflect_construct

js_value* js_function_bound_call(void* runtime, void* context, js_value* receiver, list[js_value*] args);

int js_function_callable(js_value* value):
	return value != 0 && (value.kind == 7 || value.kind == 9)

int js_function_is_bound(js_value* value):
	return value != 0 && value.kind == 9 && value.host == cast(int, js_function_bound_call)

# Enters one forwarding level: depth and one step.
int js_function_enter(js_runtime* rt):
	if (rt.depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
		if (rt.completion.status == 0): js_runtime_fail(rt, 5, c"JavaScript callable forwarding depth limit")
		return 0
	rt.depth = rt.depth + 1
	return 1

# Charges count units to the active evaluation budget (a no-op outside one).
int js_function_charge(js_runtime* rt, int count):
	if (rt.running == 0): return 1
	if (count > rt.remaining):
		js_runtime_fail(rt, 5, c"JavaScript evaluation limit")
		return 0
	rt.remaining = rt.remaining - count
	rt.completion.steps = rt.completion.steps + count
	return 1

int js_function_append(js_runtime* rt, list[js_value*] target, list[js_value*] source, int start):
	if (source.length - start > rt.max_properties - target.length):
		js_runtime_fail(rt, 5, c"JavaScript forwarded argument limit")
		return 0
	if (js_function_charge(rt, source.length - start) == 0): return 0
	for i in range(start, source.length): target.push(source[i])
	return 1

# [[Construct]] of a bound function: the bound arguments precede the call
# arguments, and a new.target equal to the bound function becomes the target.
js_value* js_function_bound_construct(js_runtime* rt, js_value* bound, list[js_value*] args, js_value* new_target):
	if (bound.host_construct == 0):
		js_runtime_fail(rt, 2, c"bound target is not a constructor")
		return rt.undefined_value
	if (js_function_enter(rt) == 0): return rt.undefined_value
	list[js_value*] forwarded = new list[js_value*]
	js_function_append(rt, forwarded, bound.reactions, 0)
	if (rt.completion.status == 0): js_function_append(rt, forwarded, args, 0)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0):
		if (new_target == bound): new_target = bound.function_object
		result = js_runtime_construct(rt, bound.function_object, forwarded, new_target)
	__w_list_free(cast(__w_list*, forwarded))
	rt.depth = rt.depth - 1
	return result

js_value* js_function_bound_call(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* bound = cast(js_value*, context)
	if (js_function_enter(rt) == 0): return rt.undefined_value
	list[js_value*] forwarded = new list[js_value*]
	js_function_append(rt, forwarded, bound.reactions, 0)
	if (rt.completion.status == 0): js_function_append(rt, forwarded, args, 0)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_call_receiver(rt, bound.function_object, bound.this_value, forwarded)
	__w_list_free(cast(__w_list*, forwarded))
	rt.depth = rt.depth - 1
	return result

# Own data/accessor presence without running getters (the target may be a
# host callable without an ordinary property table entry).
int js_function_has_own(js_runtime* rt, js_value* object, js_text* key):
	return js_runtime_property(object, key) != 0

js_value* js_function_bind(js_runtime* rt, js_value* target, list[js_value*] args):
	if (target.host_get != 0 || target.host_set != 0):
		js_runtime_fail(rt, 6, c"native callable descriptor reflection is unsupported")
		return rt.undefined_value
	js_value* bound = js_runtime_host_callable(rt, 0, js_function_bound_call)
	if (rt.completion.status != 0 || bound == rt.undefined_value): return rt.undefined_value
	bound.host_context = bound
	bound.prototype = target.prototype
	bound.function_object = target
	bound.this_value = rt.undefined_value
	if (args.length > 0): bound.this_value = args[0]
	bound.reactions = new list[js_value*]
	int start = 0
	if (args.length > 0): start = 1
	js_function_append(rt, bound.reactions, args, start)
	if (rt.completion.status != 0): return rt.undefined_value
	bound.host_construct = js_runtime_is_constructor(rt, target)
	# HasOwnProperty(target, "length") first, then Get; name is read afterwards.
	float64 length = 0.0
	js_text* key = js_runtime_key(c"length")
	int own_length = js_function_has_own(rt, target, key)
	js_text_free(key)
	if (rt.completion.status == 0 && own_length):
		js_value* value = js_runtime_get(rt, target, c"length")
		if (rt.completion.status == 0 && value.kind == 3 && f64is_nan(value.number) == 0):
			if (value.number == 1.0 / 0.0): length = value.number
			else if (value.number != -1.0 / 0.0):
				length = js_builtin_trunc(value.number) - cast(float64, bound.reactions.length)
				if (length < 0.0): length = 0.0
	if (rt.completion.status != 0): return rt.undefined_value
	js_object_define_named(rt, bound, c"length", js_runtime_number(rt, length), 0, 1)
	js_value* name = js_runtime_get(rt, target, c"name")
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* text = js_runtime_key(c"bound ")
	if (name.kind == 4):
		if (name.text.units.length > rt.max_properties - 6 || js_function_charge(rt, name.text.units.length) == 0):
			if (rt.completion.status == 0): js_runtime_fail(rt, 5, c"bound function name length limit")
		else:
			for int unit in name.text.units: text.units.push(unit)
	if (rt.completion.status == 0): js_object_define_named(rt, bound, c"name", js_runtime_string(rt, text), 0, 1)
	js_text_free(text)
	if (rt.completion.status != 0): return rt.undefined_value
	return bound

int js_function_identifier_text(js_text* text):
	if (text.units.length == 0): return 0
	for i in range(text.units.length):
		int unit = text.units[i]
		int letter = (unit >= 'a' && unit <= 'z') || (unit >= 'A' && unit <= 'Z') || unit == '_' || unit == '$'
		if (letter == 0 && (i == 0 || unit < '0' || unit > '9')): return 0
	return 1

# NativeFunction source text for built-in and bound functions: the name is
# included only when it is a plain own data property holding an identifier.
js_value* js_function_native_text(js_runtime* rt, js_value* function):
	js_text* text = js_runtime_key(c"function ")
	js_text* key = js_runtime_key(c"name")
	js_value* property = js_runtime_property(function, key)
	js_text_free(key)
	if (js_function_is_bound(function) == 0 && property != 0 && property.accessor == 0 && property.value.kind == 4 && js_function_identifier_text(property.value.text)):
		for int unit in property.value.text.units: text.units.push(unit)
	char* tail = c"() { [native code] }"
	for i in range(strlen(tail)): text.units.push(tail[i])
	js_value* result = js_runtime_string(rt, text)
	js_text_free(text)
	return result

# operation: 1 call, 2 apply, 3 bind, 4 toString. User function source text is
# not retained by the AST, so toString on ordinary functions stays an explicit
# unsupported operation instead of manufacturing source.
js_value* js_function_dispatch(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_function_callable(receiver) == 0):
		js_runtime_fail(rt, 2, c"Function method receiver is not callable")
		return rt.undefined_value
	if (js_builtin_arguments(rt, args) == 0 || js_function_enter(rt) == 0): return rt.undefined_value
	int operation = cast(int, context)
	js_value* result = rt.undefined_value
	if (operation == 4):
		if (receiver.kind == 9): result = js_function_native_text(rt, receiver)
		else: js_runtime_fail(rt, 6, c"Function source rendering is outside the runtime subset")
		rt.depth = rt.depth - 1
		return result
	if (operation == 3):
		result = js_function_bind(rt, receiver, args)
		rt.depth = rt.depth - 1
		return result
	js_value* this_value = rt.undefined_value
	if (args.length > 0): this_value = args[0]
	list[js_value*] forwarded = new list[js_value*]
	if (operation == 1):
		int start = 0
		if (args.length > 0): start = 1
		js_function_append(rt, forwarded, args, start)
	else if (args.length > 1 && args[1].kind > 1):
		list[js_value*] listed = js_reflect_list(rt, args[1])
		if (listed != 0):
			js_function_append(rt, forwarded, listed, 0)
			__w_list_free(cast(__w_list*, listed))
	if (rt.completion.status == 0): result = js_runtime_call_receiver(rt, receiver, this_value, forwarded)
	__w_list_free(cast(__w_list*, forwarded))
	rt.depth = rt.depth - 1
	return result

# Function.prototype is itself callable and returns undefined.
js_value* js_function_empty(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_builtin_arguments(rt, args)
	return rt.undefined_value

void js_function_install(js_runtime* rt):
	js_value* prototype = rt.function_prototype
	if (prototype == 0 || prototype == rt.undefined_value): return
	prototype.kind = 9
	prototype.host = cast(int, js_function_empty)
	prototype.host_receiver = 1
	js_object_define_named(rt, prototype, c"name", js_runtime_string_value(rt, c""), 0, 1)
	js_object_define_named(rt, prototype, c"length", js_runtime_number(rt, 0.0), 0, 1)
	js_object_method(rt, prototype, c"call", js_function_dispatch, 1, 1)
	js_object_method(rt, prototype, c"apply", js_function_dispatch, 2, 2)
	js_object_method(rt, prototype, c"bind", js_function_dispatch, 3, 1)
	js_object_method(rt, prototype, c"toString", js_function_dispatch, 4, 0)
	js_value* constructor = js_runtime_get(rt, rt.global_object, c"Function")
	if (js_runtime_object(constructor) == 0): return
	js_object_define_named(rt, constructor, c"name", js_runtime_string_value(rt, c"Function"), 0, 1)
	js_object_define_named(rt, constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
