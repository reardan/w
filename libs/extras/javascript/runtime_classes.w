/*
Classes for the bounded interpreter (reardan/w#905): ClassDefinitionEvaluation,
[[Construct]] for ordinary functions and base/derived class constructors,
super(...) and super.x through a method's [[HomeObject]], new.target and the
derived-constructor this TDZ. Class fields, private names and static blocks
are outside the subset (preflight rejects them); generator and async methods
run as coroutines (runtime_coroutines.w).
The realm has no %Object.prototype% intrinsic, so a class without heritage
has a null-prototype prototype object; constructors inherit %Function.prototype%
(also for extends null).
*/
import libs.extras.javascript.runtime


int js_runtime_class_reference_error(char* message):
	return strcmp(message, c"this is not initialized before super()") == 0 || strcmp(message, c"super() called twice") == 0 || strcmp(message, c"derived constructor did not initialize this") == 0


# Class members: method/static_method(method|get|set) = property_key or
# computed_key, function_expression. Method bodies may use super.
int js_runtime_class_supported(js_node* node):
	if (js_runtime_supported(node.children[0]) == 0): return 0
	for i in range(1, node.children.length):
		js_node* member = node.children[i]
		if (js_kind(member, c"method") == 0 && js_kind(member, c"static_method") == 0): return 0
		if (strcmp(member.text, c"method") != 0 && strcmp(member.text, c"get") != 0 && strcmp(member.text, c"set") != 0): return 0
		if (member.children.length != 2): return 0
		js_node* key = member.children[0]
		if (js_kind(key, c"computed_key")):
			if (key.children.length != 1 || js_runtime_supported(key.children[0]) == 0): return 0
		else if (js_kind(key, c"property_key") == 0): return 0
		js_node* routine = member.children[1]
		if (routine.children.length != 2): return 0
		# Generator and async methods (runtime_coroutines.w).
		if (js_kind(routine, c"function_expression") == 0 && (strcmp(member.text, c"method") != 0 || js_coroutine_kind_of(routine) == 0 || js_coroutine_supported(routine) == 0)): return 0
		int saved = js_runtime_super_allowed
		int saved_context = js_runtime_coroutine_context
		js_runtime_super_allowed = 1
		js_runtime_coroutine_context = js_coroutine_kind_of(routine)
		int supported = js_runtime_supported(routine.children[0]) && js_runtime_supported(routine.children[1])
		js_runtime_super_allowed = saved
		js_runtime_coroutine_context = saved_context
		if (supported == 0): return 0
	return 1


int js_runtime_is_object(js_value* value):
	return js_runtime_object(value)


# The nearest environment with a this binding: arrows have none.
js_value* js_runtime_this_scope(js_value* env):
	while (env != 0 && env.this_scope == 0): env = env.parent
	return env


js_value* js_runtime_new_target(js_runtime* rt, js_value* env):
	js_value* scope = js_runtime_this_scope(env)
	if (scope == 0 || scope.new_target == 0): return rt.undefined_value
	return scope.new_target


# GetSuperBase (0 for a null prototype) with the this value as receiver. this
# is resolved first: a derived constructor's super.x before super() throws.
js_value* js_runtime_super_base(js_runtime* rt, js_value* env, js_value** receiver):
	js_value* scope = js_runtime_this_scope(env)
	if (scope == 0 || scope.function_object == 0 || scope.function_object.home_object == 0):
		js_runtime_fail(rt, 6, c"super outside a class method")
		return rt.undefined_value
	if (scope.this_value == 0):
		js_runtime_fail(rt, 2, c"this is not initialized before super()")
		return rt.undefined_value
	*receiver = scope.this_value
	return scope.function_object.home_object.prototype


# super.x / super[x]: this, then the key, then a read from the home object's
# prototype with this as receiver. A null prototype is a TypeError.
js_value* js_runtime_super_member(js_runtime* rt, js_node* node, js_value* env, js_value** receiver):
	js_value* base = js_runtime_super_base(rt, env, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* key = js_runtime_member_key(rt, node, env)
	js_value* value = rt.undefined_value
	if (rt.completion.status == 0 && base == 0): js_runtime_fail(rt, 2, c"super base is null")
	if (rt.completion.status == 0): value = js_runtime_read_receiver(rt, base, key, *receiver)
	js_text_free(key)
	return value


js_value* js_runtime_prototype_object(js_runtime* rt, js_value* callable):
	js_text* key = js_runtime_key(c"prototype")
	js_value* prototype = js_runtime_member_read(rt, callable, key)
	js_text_free(key)
	if (rt.completion.status != 0 || js_runtime_is_object(prototype) == 0): return 0
	return prototype


# [[Construct]] for function code. A base constructor allocates this from
# new_target.prototype; a derived one leaves it to super(). A class without
# an explicit constructor keeps its class node as code (default constructor).
js_value* js_runtime_construct_code(js_runtime* rt, js_value* callable, list[js_value*] arguments, js_value* new_target):
	int derived = callable.class_kind == 2
	js_value* object = 0
	if (derived == 0):
		js_value* prototype = js_runtime_prototype_object(rt, new_target)
		if (rt.completion.status != 0): return rt.undefined_value
		object = js_runtime_alloc(rt, 5)
		if (object == rt.undefined_value): return object
		object.prototype = prototype
	if (js_kind(callable.code, c"class") || js_kind(callable.code, c"class_expression")):
		if (derived == 0): return object
		if (js_runtime_is_constructor(rt, callable.prototype) == 0):
			js_runtime_fail(rt, 2, c"super constructor is not a constructor")
			return rt.undefined_value
		return js_runtime_construct(rt, callable.prototype, arguments, new_target)
	js_value* frame = 0
	js_value* result = js_runtime_call_code(rt, callable, object, arguments, new_target, &frame)
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_is_object(result)): return result
	if (derived == 0): return object
	if (result.kind != 0):
		js_runtime_fail(rt, 2, c"derived constructor returned a non-object")
		return rt.undefined_value
	if (frame == 0 || frame.this_value == 0):
		js_runtime_fail(rt, 2, c"derived constructor did not initialize this")
		return rt.undefined_value
	return frame.this_value


js_value* js_runtime_construct(js_runtime* rt, js_value* callable, list[js_value*] arguments, js_value* new_target):
	if (callable.kind == 7):
		if (js_runtime_constructible(callable) == 0):
			js_runtime_fail(rt, 2, c"value is not a constructor")
			return rt.undefined_value
		return js_runtime_construct_code(rt, callable, arguments, new_target)
	js_value* result = rt.undefined_value
	if (callable == rt.promise_constructor): result = js_runtime_promise_construct(rt, arguments)
	else if (callable.kind == 9 && callable.binary_constructor != 0): result = js_runtime_binary_construct(rt, callable.binary_constructor, arguments)
	else if (callable.kind == 9 && callable.host_construct):
		# Host constructors see new_target in rt.new_target (new String(x) vs String(x)).
		js_value* saved = rt.new_target
		rt.new_target = new_target
		result = js_runtime_call_code(rt, callable, rt.undefined_value, arguments, new_target, 0)
		rt.new_target = saved
	else if (js_runtime_object(callable)):
		# Host objects (Number, ...) without constructor behaviour in this subset.
		js_runtime_fail(rt, 6, c"unsupported native constructor")
		return rt.undefined_value
	else:
		js_runtime_fail(rt, 2, c"value is not a constructor")
		return rt.undefined_value
	# Native constructors reached through super() take new_target.prototype.
	if (rt.completion.status == 0 && new_target != callable && js_runtime_is_object(result)):
		js_value* prototype = js_runtime_prototype_object(rt, new_target)
		if (prototype != 0): result.prototype = prototype
	return result


js_value* js_runtime_super_call(js_runtime* rt, js_node* node, js_value* env):
	js_value* scope = js_runtime_this_scope(env)
	if (scope == 0 || scope.function_object == 0 || scope.function_object.class_kind != 2):
		js_runtime_fail(rt, 6, c"super() outside a derived constructor")
		return rt.undefined_value
	js_value* constructor = scope.function_object.prototype
	list[js_value*] arguments = new list[js_value*]
	js_runtime_arguments(rt, node, env, arguments)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0):
		if (js_runtime_is_constructor(rt, constructor) == 0): js_runtime_fail(rt, 2, c"super constructor is not a constructor")
		else: result = js_runtime_construct(rt, constructor, arguments, scope.new_target)
	__w_list_free(cast(__w_list*, arguments))
	if (rt.completion.status != 0): return rt.undefined_value
	if (scope.this_value != 0):
		js_runtime_fail(rt, 2, c"super() called twice")
		return rt.undefined_value
	scope.this_value = result
	return result


js_text* js_runtime_class_key(js_runtime* rt, js_node* key, js_value* scope):
	if (js_kind(key, c"property_key")): return js_runtime_key(key.text)
	js_value* value = js_runtime_eval_node(rt, key.children[0], scope)
	if (rt.completion.status != 0): return 0
	return js_runtime_primitive_text(rt, value)


void js_runtime_set_name(js_runtime* rt, js_value* callable, char* prefix, js_text* key):
	js_text* name = js_runtime_key(prefix)
	for i in range(key.units.length): name.units.push(key.units[i])
	js_value* value = js_runtime_string(rt, name)
	js_text_free(name)
	name = js_runtime_key(c"name")
	js_runtime_define_data(rt, callable, name, value, 0, 0, 1)
	js_text_free(name)


# Defines one method or accessor on target (the prototype, or the
# constructor for static members) with target as its [[HomeObject]].
int js_runtime_class_member(js_runtime* rt, js_node* member, js_value* target, js_value* scope):
	js_text* key = js_runtime_class_key(rt, member.children[0], scope)
	if (key == 0): return 0
	js_value* closure = js_runtime_function(rt, member.children[1], scope)
	int ok = rt.completion.status == 0
	if (ok):
		closure.home_object = target
		closure.class_kind = 3
		if (strcmp(member.text, c"method") == 0):
			js_runtime_set_name(rt, closure, c"", key)
			ok = js_runtime_define_data(rt, target, key, closure, 1, 0, 1)
		else:
			js_value* getter = 0
			js_value* setter = 0
			js_value* existing = js_runtime_property(target, key)
			if (existing != 0 && existing.accessor):
				getter = existing.getter
				setter = existing.setter
			if (strcmp(member.text, c"get") == 0):
				js_runtime_set_name(rt, closure, c"get ", key)
				getter = closure
			else:
				js_runtime_set_name(rt, closure, c"set ", key)
				setter = closure
			ok = js_runtime_define_accessor(rt, target, key, getter, setter, 0, 1)
		if (ok == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"class member definition failed")
	js_text_free(key)
	return ok && rt.completion.status == 0


js_node* js_runtime_class_constructor(js_node* node):
	for i in range(1, node.children.length):
		js_node* member = node.children[i]
		if (js_kind(member, c"method") && strcmp(member.text, c"method") == 0 && js_kind(member.children[0], c"property_key") && strcmp(member.children[0].text, c"constructor") == 0): return member
	return 0


# ClassDefinitionEvaluation. The class scope holds the immutable inner name,
# uninitialized while heritage and computed keys evaluate. A declaration
# also initializes its outer lexical binding and has an empty completion.
js_value* js_runtime_class_named(js_runtime* rt, js_node* node, js_value* env, char* function_name):
	js_value* scope = js_runtime_environment(rt, env)
	if (rt.completion.status != 0): return rt.undefined_value
	scope.strict = 1
	js_text* name = js_runtime_key(node.text)
	js_value* inner = 0
	if (name.units.length > 0):
		js_runtime_put(rt, scope, name, rt.undefined_value)
		inner = js_runtime_property(scope, name)
		if (inner != 0):
			inner.initialized = 0
			inner.immutable = 1
			inner.lexical_binding = 1
	js_value* prototype_parent = 0
	js_value* constructor_parent = rt.function_prototype
	int derived = 0
	if (js_kind(node.children[0], c"empty") == 0):
		derived = 1
		js_value* heritage = js_runtime_eval_node(rt, node.children[0], scope)
		if (rt.completion.status == 0 && heritage.kind != 1):
			if (js_runtime_is_constructor(rt, heritage) == 0): js_runtime_fail(rt, 2, c"class heritage is not a constructor")
			else:
				js_text* key = js_runtime_key(c"prototype")
				js_value* parent = js_runtime_member_read(rt, heritage, key)
				js_text_free(key)
				if (rt.completion.status == 0 && parent.kind != 1):
					if (js_runtime_is_object(parent)): prototype_parent = parent
					else: js_runtime_fail(rt, 2, c"class heritage prototype is not an object or null")
				constructor_parent = heritage
	js_value* prototype = rt.undefined_value
	js_value* constructor = rt.undefined_value
	js_node* definition = js_runtime_class_constructor(node)
	if (rt.completion.status == 0): prototype = js_runtime_alloc(rt, 5)
	if (rt.completion.status == 0):
		prototype.prototype = prototype_parent
		if (definition != 0): constructor = js_runtime_function(rt, definition.children[1], scope)
		else: constructor = js_runtime_alloc(rt, 7)
	if (rt.completion.status == 0):
		int length = 0
		if (definition != 0): length = definition.children[1].children[0].children.length
		else:
			constructor.code = node
			constructor.parent = scope
		constructor.strict = 1
		constructor.class_kind = 1 + derived
		constructor.home_object = prototype
		constructor.prototype = constructor_parent
		js_text* key = js_runtime_key(c"length")
		js_runtime_define_data(rt, constructor, key, js_runtime_number(rt, cast(float64, length)), 0, 0, 1)
		js_text_free(key)
		js_text* label = js_runtime_key(function_name)
		js_runtime_set_name(rt, constructor, c"", label)
		js_text_free(label)
		key = js_runtime_key(c"prototype")
		js_runtime_define_data(rt, constructor, key, prototype, 0, 0, 0)
		js_text_free(key)
		key = js_runtime_key(c"constructor")
		js_runtime_define_data(rt, prototype, key, constructor, 1, 0, 1)
		js_text_free(key)
		for i in range(1, node.children.length):
			js_node* member = node.children[i]
			if (member == definition): continue
			js_value* target = prototype
			if (js_kind(member, c"static_method")): target = constructor
			if (js_runtime_class_member(rt, member, target, scope) == 0): break
	if (rt.completion.status == 0 && inner != 0):
		inner.value = constructor
		inner.initialized = 1
	if (rt.completion.status == 0 && js_kind(node, c"class")):
		js_value* outer = js_runtime_property(env, name)
		if (outer != 0):
			outer.value = constructor
			outer.initialized = 1
		rt.empty = 1
	js_text_free(name)
	if (rt.completion.status != 0): return rt.undefined_value
	return constructor


# NamedEvaluation of an anonymous class expression names the constructor
# before its static members are defined, so the name is handed over here.
char* js_runtime_class_pending_name = 0


js_value* js_runtime_class(js_runtime* rt, js_node* node, js_value* env):
	char* name = node.text
	if (strlen(name) == 0 && js_runtime_class_pending_name != 0): name = js_runtime_class_pending_name
	js_runtime_class_pending_name = 0
	return js_runtime_class_named(rt, node, env, name)


# NamedEvaluation: an anonymous function, arrow or class assigned to an
# identifier (declarator, assignment or binding default) takes its name.
js_value* js_runtime_named_eval(js_runtime* rt, js_node* node, js_value* env, char* name):
	if (js_kind(node, c"class_expression") && strlen(node.text) == 0):
		js_runtime_class_pending_name = name
		js_value* value = js_runtime_eval_node(rt, node, env)
		js_runtime_class_pending_name = 0
		return value
	js_value* value = js_runtime_eval_node(rt, node, env)
	int anonymous = strlen(node.text) == 0 && (js_kind(node, c"function_expression") || js_kind(node, c"generator_function_expression") || js_kind(node, c"async_function_expression") || js_kind(node, c"async_generator_function_expression"))
	if (rt.completion.status == 0 && (js_runtime_arrow_node(node) || anonymous)):
		js_text* label = js_runtime_key(name)
		js_runtime_set_name(rt, value, c"", label)
		js_text_free(label)
	return value
