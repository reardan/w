# Error intrinsics: the native Error constructors with ordered message/cause
# installation, AggregateError, Error.isError and a bounded
# Error.prototype.toString. Instances created by an Error constructor carry
# the immutable host brand intrinsic_error_name (like engine-issued errors), so
# Error.isError and Object.prototype.toString never depend on mutable
# JavaScript properties. The constructors handle new.target themselves
# (host_construct == 2), so the prototype is read before the message and cause.
# https://tc39.es/ecma262/#sec-error-objects
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_object

# Index 7 is AggregateError; 0..6 follow js_error_name.
char* js_error_label(int index):
	if (index == 7): return c"AggregateError"
	return js_error_name(index)

# Values of another runtime are rejected before any property access.
int js_error_foreign(js_runtime* rt, js_value* receiver, list[js_value*] args):
	int foreign = receiver != 0 && receiver.owner != rt
	for i in range(args.length):
		if (args[i] == 0 || args[i].owner != rt): foreign = 1
	if (foreign): js_runtime_fail(rt, 2, c"foreign Error argument")
	return foreign

# The [[Prototype]] for a fresh error: new.target.prototype when it is an
# object, otherwise the realm intrinsic.
js_value* js_error_proto_for(js_runtime* rt, int index, js_value* new_target):
	if (new_target != 0):
		js_text* key = js_runtime_key(c"prototype")
		js_value* prototype = js_runtime_member_read(rt, new_target, key)
		js_text_free(key)
		if (rt.completion.status != 0): return 0
		if (js_runtime_object(prototype)): return prototype
	return rt.error_prototypes[index]

void js_error_define(js_runtime* rt, js_value* error, char* name, js_value* value):
	js_object_define_named(rt, error, name, value, 1, 1)

# InstallErrorCause: only an object options argument with a "cause" property.
void js_error_install_cause(js_runtime* rt, js_value* error, js_value* options):
	if (js_runtime_object(options) == 0): return
	js_text* key = js_runtime_key(c"cause")
	int present = js_runtime_has_property(rt, options, key)
	if (rt.completion.status == 0 && present):
		js_value* cause = js_runtime_member_read(rt, options, key)
		if (rt.completion.status == 0): js_runtime_define_data(rt, error, key, cause, 1, 0, 1)
	js_text_free(key)

# One IteratorStep: appends the value to errors, or marks the record finished
# (this_value cleared) when the iterator is done or abrupt.
void js_runtime_iterator_step_into(js_runtime* rt, js_value* record, js_value* errors):
	js_value* value = js_runtime_iterator_step(rt, record)
	if (rt.completion.status != 0): return
	if (value == 0):
		record.this_value = 0
		return
	js_runtime_array_append(rt, errors, value)

# context is index + 1.
js_value* js_error_construct(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int index = cast(int, context) - 1
	js_value* new_target = rt.new_target
	rt.new_target = 0
	if (js_builtin_arguments(rt, args) == 0 || js_error_foreign(rt, 0, args)): return rt.undefined_value
	js_value* prototype = js_error_proto_for(rt, index, new_target)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* error = js_runtime_alloc(rt, 5)
	if (error == rt.undefined_value): return error
	error.prototype = prototype
	error.intrinsic_error_name = js_error_label(index)
	int message_index = 0
	if (index == 7): message_index = 1
	if (message_index < args.length && args[message_index].kind != 0):
		js_value* text = js_runtime_to_string_value(rt, args[message_index])
		if (rt.completion.status != 0): return rt.undefined_value
		js_error_define(rt, error, c"message", text)
	if (message_index + 1 < args.length): js_error_install_cause(rt, error, args[message_index + 1])
	if (rt.completion.status != 0): return rt.undefined_value
	if (index == 7):
		js_value* list_value = rt.undefined_value
		if (args.length > 0): list_value = args[0]
		js_value* errors = js_runtime_alloc(rt, 6)
		if (errors == rt.undefined_value): return errors
		js_value* record = js_runtime_iterator_open(rt, list_value)
		while (rt.completion.status == 0 && record != 0):
			if (js_runtime_compat_step(rt) == 0): break
			if (errors.array_length >= rt.max_properties):
				js_runtime_fail(rt, 5, c"AggregateError errors limit")
				break
			js_runtime_iterator_step_into(rt, record, errors)
			if (record.this_value == 0): break
		if (rt.completion.status != 0): return rt.undefined_value
		js_error_define(rt, error, c"errors", errors)
	return error

# Error.isError(argument): the brand of the value itself, no property reads.
js_value* js_error_is_error(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0 || js_error_foreign(rt, receiver, args)): return rt.undefined_value
	if (args.length == 0 || js_runtime_object(args[0]) == 0): return js_runtime_boolean(rt, 0)
	return js_runtime_boolean(rt, args[0].intrinsic_error_name[0] != 0)

js_value* js_error_text_body(js_runtime* rt, js_value* receiver);

# Error.prototype.toString (ToString(name) then ToString(message), each
# before the next read, joined by ": "). The nested conversions can recurse
# through native toString calls, so the depth is charged here.
js_value* js_error_text(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	if (js_runtime_object(receiver) == 0):
		js_runtime_fail(rt, 2, c"Error.prototype.toString receiver is not an object")
		return rt.undefined_value
	if (rt.depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
		if (rt.completion.status == 0): js_runtime_fail(rt, 5, c"JavaScript Error.prototype.toString depth limit")
		return rt.undefined_value
	rt.depth = rt.depth + 1
	js_value* result = js_error_text_body(rt, receiver)
	rt.depth = rt.depth - 1
	return result

js_value* js_error_text_body(js_runtime* rt, js_value* receiver):
	js_text* key = js_runtime_key(c"name")
	js_value* name = js_runtime_member_read(rt, receiver, key)
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* head = 0
	if (name.kind == 0): head = js_runtime_key(c"Error")
	else: head = js_runtime_to_text(rt, name)
	if (head == 0): return rt.undefined_value
	key = js_runtime_key(c"message")
	js_value* message = js_runtime_member_read(rt, receiver, key)
	js_text_free(key)
	js_text* tail = 0
	if (rt.completion.status == 0):
		if (message.kind == 0): tail = js_text_new()
		else: tail = js_runtime_to_text(rt, message)
	if (tail == 0):
		js_text_free(head)
		return rt.undefined_value
	if (head.units.length + tail.units.length + 2 > rt.max_properties * 64):
		js_runtime_fail(rt, 5, c"Error.prototype.toString length limit")
		js_text_free(head)
		js_text_free(tail)
		return rt.undefined_value
	if (head.units.length > 0 && tail.units.length > 0):
		head.units.push(':')
		head.units.push(' ')
	for int unit in tail.units: head.units.push(unit)
	js_text_free(tail)
	js_value* value = js_runtime_string(rt, head)
	js_text_free(head)
	return value

# Reconfigures one existing native constructor (or creates AggregateError).
void js_error_install_constructor(js_runtime* rt, int index, js_value* error_constructor):
	char* name = js_error_label(index)
	js_value* constructor = js_runtime_get(rt, rt.global_object, name)
	if (index == 7):
		constructor = js_runtime_host_callable(rt, 0, js_error_construct)
		js_value* prototype = js_runtime_alloc(rt, 5)
		if (constructor == rt.undefined_value || prototype == rt.undefined_value): return
		prototype.prototype = rt.error_prototypes[0]
		rt.error_prototypes.push(prototype)
		js_object_define_named(rt, constructor, c"prototype", prototype, 0, 0)
		js_object_define_named(rt, constructor, c"name", js_runtime_string_value(rt, name), 0, 1)
		js_object_define_named(rt, prototype, c"constructor", constructor, 1, 1)
		js_object_define_named(rt, prototype, c"name", js_runtime_string_value(rt, name), 1, 1)
		js_object_define_named(rt, prototype, c"message", js_runtime_string_value(rt, c""), 1, 1)
		js_runtime_set(rt, rt.global, name, constructor)
	if (js_runtime_object(constructor) == 0): return
	constructor.host = cast(int, js_error_construct)
	constructor.host_receiver = 1
	constructor.host_context = cast(void*, index + 1)
	constructor.host_construct = 2
	float64 length = 1.0
	if (index == 7): length = 2.0
	js_object_define_named(rt, constructor, c"length", js_runtime_number(rt, length), 0, 1)
	if (error_constructor != 0 && index != 0): constructor.prototype = error_constructor

void js_error_install(js_runtime* rt):
	if (rt.error_prototypes.length < 7): return
	js_value* error_constructor = js_runtime_get(rt, rt.global_object, c"Error")
	if (js_runtime_object(error_constructor) == 0): return
	for index in range(8): js_error_install_constructor(rt, index, error_constructor)
	js_object_method(rt, error_constructor, c"isError", js_error_is_error, 0, 1)
	js_object_method(rt, rt.error_prototypes[0], c"toString", js_error_text, 0, 0)
