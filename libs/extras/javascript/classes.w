# Class constructors and ordinary prototype inheritance. Execution remains
# synchronous; environments own the derived-this binding and trace new.target.
import libs.extras.javascript.runtime


void js_class_define(js_runtime* rt, js_value* object, char* name, js_value* value, int writable, int configurable):
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, object, key, value, writable, 0, configurable)
	js_text_free(key)


js_value* js_class_string(js_runtime* rt, char* text):
	js_text* units = js_runtime_key(text)
	js_value* value = js_runtime_string(rt, units)
	js_text_free(units)
	return value


void js_class_reference_error(js_runtime* rt):
	js_bigint_error(rt, c"ReferenceError", c"derived constructor this is uninitialized or already initialized")
	if (rt.completion.value != rt.undefined_value): rt.completion.value.prototype = rt.reference_error_prototype


void js_class_declare(js_runtime* rt, js_node* node, js_value* env, int mode):
	js_node* name = js_identifier(node.text)
	js_runtime_pattern_declare(rt, name, env, mode, 0)
	js_node_free(name)


int js_class_is_constructor(js_value* value):
	return value.class_kind != 0 || value.error_constructor


js_value* js_class_evaluate(js_runtime* rt, js_node* node, js_value* env):
	js_value* scope = js_runtime_environment(rt, env)
	if (rt.completion.status != 0): return rt.undefined_value
	scope.strict = 1
	if (strlen(node.text) > 0): js_class_declare(rt, node, scope, 1)
	if (rt.completion.status != 0): return rt.undefined_value
	int derived = js_kind(node.children[0], c"empty") == 0
	js_value* base = 0
	js_value* parent_prototype = 0
	if (derived):
		base = js_runtime_eval_node(rt, node.children[0], scope)
		if (rt.completion.status != 0): return rt.undefined_value
		if (base.kind == 1): base = 0
		else:
			if (js_class_is_constructor(base) == 0):
				if (base.kind == 7 || base.kind == 9): js_runtime_fail(rt, 6, c"class heritage constructor is outside the runtime subset")
				else: js_runtime_fail(rt, 2, c"class heritage is not a constructor")
				return rt.undefined_value
			parent_prototype = js_runtime_get(rt, base, c"prototype")
			if (rt.completion.status != 0): return rt.undefined_value
			if (parent_prototype.kind == 1): parent_prototype = 0
			else if (js_runtime_object(parent_prototype) == 0):
				js_runtime_fail(rt, 2, c"class heritage prototype is not an object or null")
				return rt.undefined_value
	js_value* prototype = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	prototype.prototype = parent_prototype
	js_value* constructor = js_runtime_alloc(rt, 7)
	if (rt.completion.status != 0): return rt.undefined_value
	constructor.parent = scope
	constructor.prototype = base
	constructor.strict = 1
	constructor.class_kind = 1 + derived
	for i in range(1, node.children.length):
		js_node* method = node.children[i]
		if (js_kind(method, c"method") && strcmp(method.text, c"constructor") == 0): constructor.code = method
	int length = 0
	if (constructor.code != 0):
		js_node* parameters = constructor.code.children[0]
		while (length < parameters.children.length):
			if (js_kind(parameters.children[length], c"default_pattern") || js_kind(parameters.children[length], c"rest")): break
			length = length + 1
	js_class_define(rt, constructor, c"name", js_class_string(rt, node.text), 0, 1)
	js_class_define(rt, constructor, c"length", js_runtime_number(rt, cast(float64, length)), 0, 1)
	js_class_define(rt, constructor, c"prototype", prototype, 0, 0)
	js_class_define(rt, prototype, c"constructor", constructor, 1, 1)
	if (rt.completion.status != 0): return rt.undefined_value
	if (strlen(node.text) > 0):
		js_value* binding = js_runtime_binding(scope, node.text)
		binding.value = constructor
		binding.initialized = 1
		binding.immutable = 1
	for i in range(1, node.children.length):
		if (rt.completion.status != 0): break
		js_node* method = node.children[i]
		if (js_kind(method, c"method") && strcmp(method.text, c"constructor") == 0): continue
		js_value* target = prototype
		if (js_kind(method, c"static_method")): target = constructor
		js_value* callable = js_runtime_function(rt, method, scope)
		callable.strict = 1
		js_class_define(rt, target, method.text, callable, 1, 1)
	return constructor


js_value* js_class_construct(js_runtime* rt, js_value* callable, list[js_value*] args, js_value* new_target):
	if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
	if (rt.depth >= rt.max_depth):
		js_runtime_fail(rt, 5, c"JavaScript constructor depth limit")
		return rt.undefined_value
	if (callable == 0 || js_class_is_constructor(callable) == 0):
		js_runtime_fail(rt, 2, c"super constructor is not a constructor")
		return rt.undefined_value
	rt.depth = rt.depth + 1
	js_value* result = rt.undefined_value
	if (callable.error_constructor):
		result = js_runtime_call_receiver(rt, callable, rt.undefined_value, args)
		if (rt.completion.status == 0):
			js_value* prototype = js_runtime_get(rt, new_target, c"prototype")
			if (js_runtime_object(prototype)): result.prototype = prototype
	else if (callable.code == 0 && callable.class_kind == 2):
		result = js_class_construct(rt, callable.prototype, args, new_target)
	else:
		js_value* receiver = rt.undefined_value
		if (callable.class_kind == 1):
			receiver = js_runtime_alloc(rt, 5)
			js_value* prototype = js_runtime_get(rt, new_target, c"prototype")
			if (js_runtime_object(prototype)): receiver.prototype = prototype
		if (rt.completion.status == 0):
			if (callable.code == 0): result = receiver
			else: result = js_runtime_call_body(rt, callable, receiver, args, new_target)
	rt.depth = rt.depth - 1
	return result


js_value* js_class_super(js_runtime* rt, js_node* node, js_value* env):
	js_value* scope = env
	while (scope != 0 && scope.constructor_callable == 0): scope = scope.parent
	if (scope == 0):
		js_runtime_fail(rt, 6, c"super call requires a derived constructor")
		return rt.undefined_value
	list[js_value*] args = new list[js_value*]
	js_runtime_arguments(rt, node, env, args)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_class_construct(rt, scope.constructor_callable.prototype, args, scope.new_target)
	__w_list_free(cast(__w_list*, args))
	if (rt.completion.status == 0):
		if (scope.this_uninitialized == 0): js_class_reference_error(rt)
		else:
			scope.this_value = result
			scope.this_uninitialized = 0
	return result


js_value* js_class_instanceof(js_runtime* rt, js_value* object, js_value* callable):
	if (callable.kind != 7 && callable.kind != 9):
		js_runtime_fail(rt, 2, c"instanceof requires a callable right operand")
		return rt.undefined_value
	if (js_runtime_object(object) == 0): return js_runtime_boolean(rt, 0)
	js_value* prototype = js_runtime_get(rt, callable, c"prototype")
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_object(prototype) == 0):
		js_runtime_fail(rt, 2, c"instanceof requires an object prototype")
		return rt.undefined_value
	js_value* current = object.prototype
	int depth = 0
	while (current != 0):
		if (current == prototype): return js_runtime_boolean(rt, 1)
		if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
		depth = depth + 1
		if (depth >= rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
			return rt.undefined_value
		current = current.prototype
	return js_runtime_boolean(rt, 0)


js_value* js_class_error(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* error = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	error.prototype = cast(js_value*, context)
	error.intrinsic_error_name = error.prototype.intrinsic_error_name
	if (args.length > 0 && args[0].kind != 0):
		js_text* text = js_runtime_string_text(rt, args[0])
		if (text == 0):
			js_runtime_fail(rt, 6, c"Error message object coercion is outside the runtime subset")
			return rt.undefined_value
		js_class_define(rt, error, c"message", js_runtime_string(rt, text), 1, 1)
		js_text_free(text)
	return error


# Generic Error.prototype.toString: observable Get/ToString of name precedes
# Get/ToString of message; defaults and empty strings avoid extra punctuation.
js_value* js_class_error_to_string(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_runtime_object(receiver) == 0):
		js_runtime_fail(rt, 2, c"Error.toString requires an object receiver")
		return rt.undefined_value
	if (rt.depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
		js_runtime_fail(rt, 5, c"JavaScript error string depth limit")
		return rt.undefined_value
	rt.depth = rt.depth + 1
	js_text* name = 0
	js_text* message = 0
	js_value* value = js_runtime_get(rt, receiver, c"name")
	if (rt.completion.status == 0):
		if (value.kind == 0): name = js_runtime_key(c"Error")
		else: name = js_runtime_string_text(rt, value)
	if (name != 0 && rt.completion.status == 0):
		value = js_runtime_get(rt, receiver, c"message")
		if (rt.completion.status == 0):
			if (value.kind == 0): message = js_text_new()
			else: message = js_runtime_string_text(rt, value)
	js_value* result = rt.undefined_value
	if (name != 0 && message != 0 && rt.completion.status == 0):
		int separator = name.units.length > 0 && message.units.length > 0
		int count = message.units.length + separator * 2
		if (count > rt.max_properties - name.units.length): js_runtime_fail(rt, 5, c"Error string length limit")
		else:
			if (separator):
				name.units.push(':')
				name.units.push(' ')
			for i in range(message.units.length):
				if (js_runtime_compat_step(rt) == 0): break
				name.units.push(message.units[i])
			if (rt.completion.status == 0): result = js_runtime_string(rt, name)
	js_text_free(name)
	js_text_free(message)
	rt.depth = rt.depth - 1
	return result


void js_class_install_error(js_runtime* rt, char* name, js_value* prototype):
	prototype.intrinsic_error_name = name
	js_value* constructor = js_runtime_host_callable(rt, cast(void*, prototype), js_class_error)
	constructor.this_value = prototype
	constructor.error_constructor = 1
	constructor.host_construct = 1
	js_class_define(rt, constructor, c"prototype", prototype, 0, 0)
	js_class_define(rt, constructor, c"name", js_class_string(rt, name), 0, 1)
	js_class_define(rt, constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, prototype, c"constructor", constructor, 1, 1)
	js_class_define(rt, prototype, c"name", js_class_string(rt, name), 1, 1)
	js_class_define(rt, prototype, c"message", js_class_string(rt, c""), 1, 1)
	js_runtime_set(rt, rt.global, name, constructor)


void js_runtime_install_classes(js_runtime* rt):
	rt.error_prototype = js_runtime_alloc(rt, 5)
	js_class_install_error(rt, c"Error", rt.error_prototype)
	js_builtin_method(rt, rt.error_prototype, c"toString", js_class_error_to_string, 0)
	rt.reference_error_prototype = js_runtime_alloc(rt, 5)
	rt.reference_error_prototype.prototype = rt.error_prototype
	js_class_install_error(rt, c"ReferenceError", rt.reference_error_prototype)
	js_runtime_get(rt, rt.global, c"ReferenceError").prototype = js_runtime_get(rt, rt.global, c"Error")
