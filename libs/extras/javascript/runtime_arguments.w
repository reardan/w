# Lazy mapped and unmapped arguments objects.
# https://tc39.es/ecma262/#sec-createunmappedargumentsobject
# A function whose code can name `arguments` (or call eval) gets a pending
# binding holding a copy of the caller's vector; the first read materializes
# the object. A mapped index keeps its parameter binding in mapped_binding;
# the binding's mapped_object/mapped_index point back, and every write on
# either side copies to the other until a delete or redefinition unmaps it.
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_function
import libs.extras.javascript.runtime_object

# Whether a function's own code (parameters, body and nested arrows, which
# share its `arguments`) mentions the name or contains a direct eval call.
# Nested ordinary functions are skipped. The scan over-approximates.
int js_arguments_scan(js_node* node):
	if (node.text != 0 && strcmp(node.text, c"arguments") == 0): return 1
	if (js_kind(node, c"call") && node.children.length > 0 && js_kind(node.children[0], c"identifier") && strcmp(node.children[0].text, c"eval") == 0): return 1
	for i in range(node.children.length):
		js_node* child = node.children[i]
		if (js_runtime_function_node(child) && js_runtime_arrow_node(child) == 0): continue
		if (js_arguments_scan(child)): return 1
	return 0

int js_arguments_used(js_node* code):
	if (code.arguments_use == 0):
		code.arguments_use = 1
		if (js_arguments_scan(code)): code.arguments_use = 2
	return code.arguments_use == 2

int js_arguments_body_name(js_node* body):
	for i in range(body.children.length):
		js_node* statement = body.children[i]
		if ((js_kind(statement, c"function") || js_kind(statement, c"class")) && strcmp(statement.text, c"arguments") == 0): return 1
		if (js_kind(statement, c"variable") && strcmp(statement.text, c"var") != 0):
			list[js_node*] names = new list[js_node*]
			for j in range(statement.children.length): js_runtime_pattern_names(statement.children[j].children[0], names)
			int found = 0
			for j in range(names.length):
				if (strcmp(names[j].text, c"arguments") == 0): found = 1
			__w_list_free(cast(__w_list*, names))
			if (found): return 1
	return 0

void js_arguments_prepare(js_runtime* rt, js_value* env, list[js_value*] args, js_value* callable):
	if (rt.completion.status != 0 || env == rt.undefined_value || js_runtime_arrow_node(callable.code)): return
	if (js_arguments_used(callable.code) == 0): return
	js_text* key = js_runtime_key(c"arguments")
	if (js_runtime_property(env, key) != 0):
		js_text_free(key)
		return
	int simple = 1
	js_node* parameters = callable.code.children[0]
	for i in range(parameters.children.length):
		if (js_kind(parameters.children[i], c"identifier") == 0): simple = 0
	if (js_arguments_body_name(callable.code.children[1])):
		js_text_free(key)
		if (simple == 0): js_runtime_fail(rt, 6, c"non-simple parameter/body arguments shadowing is unsupported")
		return
	# This internal value is resolved by binding reads before JavaScript can
	# observe it. An assignment replaces it without materializing an object.
	js_value* pending = js_runtime_alloc(rt, 8)
	if (rt.completion.status == 0):
		pending.parent = env
		pending.function_object = callable
		pending.arguments_pending = 1
		pending.strict = env.strict || simple == 0
		pending.reactions = new list[js_value*]
		js_function_append(rt, pending.reactions, args, 0)
	if (rt.completion.status == 0):
		js_runtime_put(rt, env, key, pending)
		js_value* binding = js_runtime_property(env, key)
		if (binding != 0): binding.immutable = env.strict
	js_text_free(key)

js_value* js_arguments_poison(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_runtime_fail(rt, 2, c"unmapped arguments callee access is forbidden")
	return rt.undefined_value

# Copies a binding write into the mapped argument property, if still mapped.
void js_arguments_sync(js_value* binding, js_value* value):
	js_value* object = binding.mapped_object
	if (object == 0): return
	char* raw = itoa(binding.mapped_index)
	js_text* key = js_runtime_key(raw)
	free(raw)
	js_value* property = js_runtime_property(object, key)
	js_text_free(key)
	if (property != 0 && property.mapped_binding == binding && property.accessor == 0): property.value = value

js_value* js_arguments_materialize(js_runtime* rt, js_value* pending):
	js_value* env = pending.parent
	js_value* object = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	object.arguments_object = 1
	js_object_define_named(rt, object, c"length", js_runtime_number(rt, cast(float64, pending.reactions.length)), 1, 1)
	for i in range(pending.reactions.length):
		if (js_runtime_compat_step(rt) == 0): break
		char* raw = itoa(i)
		js_text* key = js_runtime_key(raw)
		free(raw)
		js_runtime_define_data(rt, object, key, pending.reactions[i], 1, 1, 1)
		js_text_free(key)
	if (rt.completion.status == 0):
		js_value* values = js_runtime_get(rt, rt.array_prototype, c"values")
		js_text* iterator_key = js_symbol_key(JS_SYMBOL_ITERATOR)
		if (js_runtime_callable(values)): js_runtime_define_data(rt, object, iterator_key, values, 1, 0, 1)
		js_text_free(iterator_key)
	if (rt.completion.status == 0 && pending.strict == 0):
		js_node* parameters = env.code.children[0]
		for i in range(parameters.children.length):
			if (i >= pending.reactions.length): break
			if (js_runtime_compat_step(rt) == 0): break
			js_node* parameter = parameters.children[i]
			int duplicate = 0
			for j in range(i + 1, parameters.children.length):
				if (js_runtime_compat_step(rt) == 0): break
				if (strcmp(parameter.text, parameters.children[j].text) == 0): duplicate = 1
			if (duplicate || rt.completion.status != 0): continue
			char* raw = itoa(i)
			js_text* key = js_runtime_key(raw)
			free(raw)
			js_value* property = js_runtime_property(object, key)
			js_text_free(key)
			key = js_runtime_key(parameter.text)
			js_value* binding = js_runtime_property(env, key)
			js_text_free(key)
			if (property == 0 || binding == 0): continue
			property.value = binding.value
			property.mapped_binding = binding
			property.mapped_environment = env
			binding.mapped_object = object
			binding.mapped_index = i
		js_object_define_named(rt, object, c"callee", pending.function_object, 1, 1)
	else if (rt.completion.status == 0):
		if (rt.arguments_thrower == 0):
			rt.arguments_thrower = js_runtime_host_callable(rt, 0, js_arguments_poison)
			js_object_define_named(rt, rt.arguments_thrower, c"length", js_runtime_number(rt, 0.0), 0, 1)
			js_object_define_named(rt, rt.arguments_thrower, c"name", js_runtime_string_value(rt, c""), 0, 1)
		js_text* key = js_runtime_key(c"callee")
		js_runtime_define_accessor(rt, object, key, rt.arguments_thrower, rt.arguments_thrower, 0, 0)
		js_text_free(key)
	return object
