/*
Ordinary constructors, error intrinsics, instanceof, switch and String for
the bounded interpreter. These are the pieces the upstream Test262 harness
(sta.js/assert.js) needs: `function F() {}` gains a lazily created
`F.prototype`, `new F()` allocates an object inheriting from it, and engine
errors inherit from the Error/TypeError/... prototypes so `e.constructor`
identifies them. Error objects created by JavaScript code carry no host
intrinsic brand: only engine-issued errors do.
*/
import libs.extras.javascript.runtime


char* js_error_name(int index):
	if (index == 0): return c"Error"
	if (index == 1): return c"TypeError"
	if (index == 2): return c"ReferenceError"
	if (index == 3): return c"SyntaxError"
	if (index == 4): return c"RangeError"
	if (index == 5): return c"EvalError"
	if (index == 6): return c"URIError"
	return 0


js_value* js_runtime_error_prototype(js_runtime* rt, char* name):
	for i in range(rt.error_prototypes.length):
		if (strcmp(js_error_name(i), name) == 0): return rt.error_prototypes[i]
	return 0


# Only ordinary (non-arrow) function code is constructible here; methods
# lowered as function expressions remain constructible as in the facade.
int js_runtime_constructible(js_value* callable):
	if (callable.kind != 7 || callable.code == 0): return 0
	return js_kind(callable.code, c"function") || js_kind(callable.code, c"function_expression")


# Creates F.prototype on first observation, as if it had been created with the
# function: writable, non-enumerable, non-configurable, with a constructor link.
void js_runtime_function_prototype(js_runtime* rt, js_value* callable, js_text* key):
	if (js_runtime_constructible(callable) == 0 || js_runtime_key_is(key, c"prototype") == 0): return
	if (js_runtime_property(callable, key) != 0): return
	js_value* prototype = js_runtime_alloc(rt, 5)
	if (prototype == rt.undefined_value): return
	js_text* name = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, prototype, name, callable, 1, 0, 1)
	js_text_free(name)
	js_runtime_define_data(rt, callable, key, prototype, 1, 0, 0)


js_value* js_runtime_prototype_of(js_runtime* rt, js_value* callable):
	js_text* key = js_runtime_key(c"prototype")
	js_value* prototype = js_runtime_member_read(rt, callable, key)
	js_text_free(key)
	return prototype


js_value* js_runtime_construct_ordinary(js_runtime* rt, js_value* callable, list[js_value*] arguments):
	js_value* prototype = js_runtime_prototype_of(rt, callable)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* object = js_runtime_alloc(rt, 5)
	if (object == rt.undefined_value): return object
	if (prototype.kind >= 5 && prototype.kind != 8): object.prototype = prototype
	js_value* result = js_runtime_call_receiver(rt, callable, object, arguments)
	if (rt.completion.status != 0): return rt.undefined_value
	if (result.kind >= 5 && result.kind != 8 && result.kind != 10): return result
	return object


js_value* js_runtime_instanceof(js_runtime* rt, js_value* value, js_value* target):
	if (target.kind != 7 && target.kind != 9):
		js_runtime_fail(rt, 2, c"instanceof target is not callable")
		return rt.undefined_value
	if (value.kind < 5 || value.kind == 8 || value.kind == 10): return js_runtime_boolean(rt, 0)
	js_value* prototype = js_runtime_prototype_of(rt, target)
	if (rt.completion.status != 0): return rt.undefined_value
	if (prototype.kind < 5 || prototype.kind == 8 || prototype.kind == 10):
		js_runtime_fail(rt, 2, c"instanceof target has no prototype object")
		return rt.undefined_value
	js_value* current = value.prototype
	int depth = 0
	while (current != 0):
		depth = depth + 1
		if (depth > rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
			return rt.undefined_value
		if (current == prototype): return js_runtime_boolean(rt, 1)
		current = current.prototype
	return js_runtime_boolean(rt, 0)


# switch = discriminant, case(test, statements...)/default(statements...).
# Clauses share one lexical scope; matching uses strict equality, and the
# default clause runs only when no case (before or after it) matches.
js_value* js_runtime_switch(js_runtime* rt, js_node* node, js_value* env):
	js_value* discriminant = js_runtime_eval_node(rt, node.children[0], env)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* scope = js_runtime_environment(rt, env)
	# One CaseBlock scope: declare every clause's statements in a single pass
	# so sloppy duplicate functions across clauses (B.3.3.5) are not
	# mistaken for redeclarations. A temporary borrowed wrapper holds them.
	js_node* wrapper = js_node_new(c"block", c"")
	for i in range(1, node.children.length):
		for js_node* statement in node.children[i].children: js_node_add(wrapper, statement)
	js_runtime_declare(rt, wrapper, scope)
	while (wrapper.children.length > 0): wrapper.children.pop()
	js_node_free(wrapper)
	int start = -1
	int fallback = -1
	for i in range(1, node.children.length):
		if (rt.completion.status != 0 || start >= 0): break
		js_node* clause = node.children[i]
		if (js_kind(clause, c"default")):
			fallback = i
			continue
		js_value* test = js_runtime_eval_node(rt, clause.children[0], scope)
		if (rt.completion.status == 0 && js_runtime_equal(discriminant, test)): start = i
	if (start < 0): start = fallback
	js_value* result = rt.undefined_value
	int empty = 1
	if (start > 0):
		for i in range(start, node.children.length):
			if (rt.completion.status != 0): break
			js_node* clause = node.children[i]
			int first = 0
			if (js_kind(clause, c"case")): first = 1
			for j in range(first, clause.children.length):
				if (rt.completion.status != 0): break
				js_value* value = js_runtime_eval_node(rt, clause.children[j], scope)
				if (rt.empty == 0):
					result = value
					empty = 0
	if (rt.completion.status == 3 && rt.jump_target == 0): rt.completion.status = 0
	rt.empty = empty
	return result


js_value* js_runtime_error_construct(void* runtime, void* context, js_value* receiver, list[js_value*] arguments):
	js_runtime* rt = cast(js_runtime*, runtime)
	char* name = cast(char*, context)
	js_value* error = js_runtime_alloc(rt, 5)
	if (error == rt.undefined_value): return error
	error.prototype = js_runtime_error_prototype(rt, name)
	if (arguments.length > 0 && arguments[0].kind != 0):
		js_text* message = js_runtime_primitive_text(rt, arguments[0])
		if (message == 0): return rt.undefined_value
		js_value* text = js_runtime_string(rt, message)
		js_text_free(message)
		js_text* key = js_runtime_key(c"message")
		js_runtime_define_data(rt, error, key, text, 1, 0, 1)
		js_text_free(key)
	return error


js_value* js_runtime_error_text(void* runtime, void* context, js_value* receiver, list[js_value*] arguments):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.kind < 5 || receiver.kind == 8 || receiver.kind == 10):
		js_runtime_fail(rt, 2, c"Error.prototype.toString receiver is not an object")
		return rt.undefined_value
	js_text* key = js_runtime_key(c"name")
	js_value* name = js_runtime_member_read(rt, receiver, key)
	js_text_free(key)
	key = js_runtime_key(c"message")
	js_value* message = js_runtime_member_read(rt, receiver, key)
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* result = js_text_new()
	if (name.kind == 0):
		js_text_free(result)
		result = js_runtime_key(c"Error")
	else:
		js_text_free(result)
		result = js_runtime_primitive_text(rt, name)
	if (result == 0): return rt.undefined_value
	js_text* detail = js_text_new()
	if (message.kind != 0):
		js_text_free(detail)
		detail = js_runtime_primitive_text(rt, message)
		if (detail == 0):
			js_text_free(result)
			return rt.undefined_value
	if (result.units.length > 0 && detail.units.length > 0):
		result.units.push(':')
		result.units.push(' ')
	for i in range(detail.units.length): result.units.push(detail.units[i])
	js_text_free(detail)
	js_value* value = js_runtime_string(rt, result)
	js_text_free(result)
	return value


# String(value) for primitives; object conversion stays outside the subset.
js_value* js_runtime_string_function(void* runtime, void* context, js_value* receiver, list[js_value*] arguments):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (arguments.length == 0):
		js_text* empty = js_text_new()
		js_value* value = js_runtime_string(rt, empty)
		js_text_free(empty)
		return value
	js_text* text = js_runtime_primitive_text(rt, arguments[0])
	if (text == 0): return rt.undefined_value
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value


void js_runtime_install_constructors(js_runtime* rt):
	js_value* base = 0
	for index in range(7):
		char* name = js_error_name(index)
		js_value* constructor = js_runtime_host_callable(rt, name, js_runtime_error_construct)
		if (constructor == rt.undefined_value): return
		constructor.host_construct = 1
		js_value* prototype = js_runtime_alloc(rt, 5)
		if (prototype == rt.undefined_value): return
		if (base != 0): prototype.prototype = base
		rt.error_prototypes.push(prototype)
		js_text* key = js_runtime_key(c"prototype")
		js_runtime_define_data(rt, constructor, key, prototype, 0, 0, 0)
		js_text_free(key)
		key = js_runtime_key(name)
		js_value* label = js_runtime_string(rt, key)
		js_text_free(key)
		key = js_runtime_key(c"name")
		js_runtime_define_data(rt, constructor, key, label, 0, 0, 1)
		js_runtime_define_data(rt, prototype, key, label, 1, 0, 1)
		js_text_free(key)
		key = js_runtime_key(c"message")
		js_text* empty = js_text_new()
		js_runtime_define_data(rt, prototype, key, js_runtime_string(rt, empty), 1, 0, 1)
		js_text_free(empty)
		js_text_free(key)
		key = js_runtime_key(c"constructor")
		js_runtime_define_data(rt, prototype, key, constructor, 1, 0, 1)
		js_text_free(key)
		if (base == 0):
			base = prototype
			key = js_runtime_key(c"toString")
			js_runtime_define_data(rt, prototype, key, js_runtime_host_callable(rt, 0, js_runtime_error_text), 1, 0, 1)
			js_text_free(key)
		js_runtime_set(rt, rt.global, name, constructor)
	js_runtime_set(rt, rt.global, c"String", js_runtime_host_callable(rt, 0, js_runtime_string_function))
