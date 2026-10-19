# Deferred mapped/unmapped arguments. Maps retain the owning environment;
# caller vectors are copied, and descriptor/delete operations sever aliases.
# https://tc39.es/ecma262/#sec-createunmappedargumentsobject
import libs.extras.javascript.runtime

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
	if (rt.completion.status != 0 || js_kind(env.code, c"arrow")): return
	js_text* key = js_runtime_key(c"arguments")
	if (js_runtime_property(env, key) != 0):
		js_text_free(key)
		return
	int simple = 1
	js_node* parameters = env.code.children[0]
	for i in range(parameters.children.length):
		if (js_kind(parameters.children[i], c"identifier") == 0): simple = 0
	if (js_arguments_body_name(env.code.children[1])):
		js_text_free(key)
		if (simple == 0): js_runtime_fail(rt, 6, c"non-simple parameter/body arguments shadowing is unsupported")
		return
	# This internal value is resolved by binding reads before JavaScript can
	# observe it. An assignment replaces it without materializing an object.
	js_value* pending = js_runtime_alloc(rt, 8)
	if (rt.completion.status == 0):
		pending.parent = env
		pending.constructor_callable = callable
		pending.arguments_pending = 1
		pending.strict = env.strict || simple == 0
		pending.call_arguments = new list[js_value*]
		js_function_append(rt, pending.call_arguments, args, 0)
	if (rt.completion.status == 0):
		js_runtime_put(rt, env, key, pending)
		js_value* binding = js_runtime_property(env, key)
		if (binding != 0): binding.immutable = env.strict
	js_text_free(key)

js_value* js_arguments_poison(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_runtime_fail(rt, 2, c"unmapped arguments callee access is forbidden")
	return rt.undefined_value

js_value* js_arguments_materialize(js_runtime* rt, js_value* pending):
	js_value* object = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	object.arguments_object = 1
	js_class_define(rt, object, c"length", js_runtime_number(rt, cast(float64, pending.call_arguments.length)), 1, 1)
	for i in range(pending.call_arguments.length):
		if (js_runtime_compat_step(rt) == 0): break
		char* raw = itoa(i)
		js_text* key = js_runtime_key(raw)
		free(raw)
		js_runtime_define_data(rt, object, key, pending.call_arguments[i], 1, 1, 1)
		js_text_free(key)
	if (rt.completion.status == 0 && pending.strict == 0):
		js_node* parameters = pending.parent.code.children[0]
		for i in range(parameters.children.length):
			if (i >= pending.call_arguments.length): break
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
			js_value* prop = js_runtime_property(object, key)
			js_text_free(key)
			key = js_runtime_key(parameter.text)
			prop.mapped_binding = js_runtime_property(pending.parent, key)
			prop.mapped_environment = pending.parent
			js_text_free(key)
		js_class_define(rt, object, c"callee", pending.constructor_callable, 1, 1)
	else if (rt.completion.status == 0):
		if (rt.arguments_thrower == 0):
			rt.arguments_thrower = js_runtime_host_callable(rt, 0, js_arguments_poison)
			js_class_define(rt, rt.arguments_thrower, c"length", js_runtime_number(rt, 0.0), 0, 1)
			js_class_define(rt, rt.arguments_thrower, c"name", js_class_string(rt, c""), 0, 1)
		js_text* key = js_runtime_key(c"callee")
		js_runtime_define_accessor(rt, object, key, rt.arguments_thrower, rt.arguments_thrower, 0, 0)
		js_text_free(key)
	return object
