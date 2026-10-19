import libs.extras.javascript.runtime

# ECMA-262 14.7.5.9 / CreateForInIterator: own-key snapshots per prototype
# level, descriptors checked when processed, names visited even if nonenumerable.
# Native lists own cloned keys and are unwound normally on async cancellation.
int js_for_in_charge(js_runtime* rt, int amount):
	if (rt.completion.status != 0): return 0
	if (amount < 0 || amount > rt.remaining):
		js_runtime_fail(rt, 5, c"JavaScript enumeration execution limit")
		return 0
	rt.remaining = rt.remaining - amount
	rt.completion.steps = rt.completion.steps + amount
	return 1

void js_for_in_keys_free(list[js_text*] keys):
	for i in range(keys.length): js_text_free(keys[i])
	__w_list_free(cast(__w_list*, keys))

void js_for_in_key(js_runtime* rt, list[js_text*] keys, js_text* original):
	if (keys.length >= rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript enumeration key limit")
		return
	if (js_for_in_charge(rt, 1 + original.units.length) == 0): return
	js_text* key = js_text_clone(original)
	int index = js_runtime_array_index(key)
	int position = keys.length
	keys.push(key)
	while (index >= 0 && position > 0):
		if (js_for_in_charge(rt, 1 + keys[position - 1].units.length) == 0): break
		int previous = js_runtime_array_index(keys[position - 1])
		if (previous >= 0 && previous < index): break
		keys[position] = keys[position - 1]
		position = position - 1
	keys[position] = key

js_value* js_for_in_object(js_runtime* rt, js_value* value):
	if (value.kind == 0 || value.kind == 1): return 0
	if (js_runtime_object(value)): return value
	js_value* boxed = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return 0
	if (value.kind != 4): return boxed
	boxed.prototype = rt.string_prototype
	for i in range(value.text.units.length):
		if (js_for_in_charge(rt, 1) == 0): return 0
		char* name = itoa(i)
		js_text* key = js_runtime_key(name)
		free(name)
		js_runtime_define_data(rt, boxed, key, rt.undefined_value, 0, 1, 0)
		js_text_free(key)
		if (rt.completion.status != 0): return 0
	js_text* length = js_runtime_key(c"length")
	js_runtime_define_data(rt, boxed, length, rt.undefined_value, 0, 0, 0)
	js_text_free(length)
	return boxed

# Same existing assignment contract: unresolved names fail, immutable bindings
# reject writes, member targets are evaluated anew for each visited key.
void js_for_in_assign(js_runtime* rt, js_node* target, js_value* env, js_value* value):
	if (rt.completion.status != 0): return
	if (js_kind(target, c"identifier")):
		js_value* binding = js_runtime_binding(env, target.text)
		if (binding == 0 && rt.global_object != 0):
			js_text* global_key = js_runtime_key(target.text)
			if (env.strict && js_global_has(rt, target.text) == 0): js_runtime_fail(rt, 2, c"uninitialized or missing binding")
			if (rt.completion.status == 0 && js_runtime_member_write(rt, rt.global_object, global_key, value) == 0 && env.strict): js_runtime_fail(rt, 2, c"property write rejected")
			js_text_free(global_key)
		else if (binding == 0 || binding.initialized == 0): js_runtime_fail(rt, 2, c"uninitialized or missing binding")
		elif (binding.immutable):
			if (binding.silent_immutable == 0 || env.strict): js_runtime_fail(rt, 2, c"assignment to constant binding")
		else: js_global_binding_write(rt, binding, value, env.strict)
		return
	js_value* object = js_runtime_eval_node(rt, target.children[0], env)
	js_text* key = 0
	if (rt.completion.status == 0): key = js_runtime_member_key(rt, target, env)
	if (rt.completion.status == 0 && js_runtime_member_write(rt, object, key, value) == 0 && env.strict): js_runtime_fail(rt, 2, c"property write rejected")
	js_text_free(key)

js_value* js_runtime_for_in(js_runtime* rt, js_node* node, js_value* env):
	js_node* pattern = node.children[0]
	int lexical = strcmp(node.text, c"let") == 0 || strcmp(node.text, c"const") == 0
	js_value* initial = env
	if (lexical):
		initial = js_runtime_environment(rt, env)
		js_runtime_pattern_declare(rt, pattern, initial, 1, 0)
	js_value* value = rt.undefined_value
	if (rt.completion.status == 0): value = js_runtime_eval_node(rt, node.children[1], initial)
	js_value* object = 0
	if (rt.completion.status == 0): object = js_for_in_object(rt, value)
	list[js_text*] visited = new list[js_text*]
	js_value* result = rt.undefined_value
	int levels = 0
	int stopped = 0
	while (object != 0 && rt.completion.status == 0 && stopped == 0):
		levels = levels + 1
		if (levels > rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript enumeration prototype limit")
			break
		if (object.host_get != 0 || object.host_set != 0 || object.host_has != 0 || object.binary_kind != 0):
			js_runtime_fail(rt, 6, c"native exotic enumeration is unsupported")
			break
		list[js_text*] keys = new list[js_text*]
		for i in range(object.properties.length):
			if (rt.completion.status != 0): break
			js_for_in_key(rt, keys, object.properties[i].key)
		# Array length is a virtual nonenumerable own property in this runtime.
		if (object.kind == 6 && rt.completion.status == 0):
			js_text* length = js_runtime_key(c"length")
			js_for_in_key(rt, keys, length)
			js_text_free(length)
		for i in range(keys.length):
			if (rt.completion.status != 0 || stopped): break
			js_text* key = keys[i]
			int seen = 0
			for j in range(visited.length):
				if (js_for_in_charge(rt, 1 + key.units.length) == 0): break
				if (js_text_equal(key, visited[j])):
					seen = 1
					break
			if (seen || rt.completion.status != 0): continue
			if (js_for_in_charge(rt, 1) == 0): break
			js_value* descriptor = js_runtime_property(object, key)
			int virtual_length = object.kind == 6 && js_runtime_key_is(key, c"length")
			if (descriptor == 0 && virtual_length == 0): continue
			if (visited.length >= rt.max_properties):
				js_runtime_fail(rt, 5, c"JavaScript enumeration visited-key limit")
				break
			visited.push(js_text_clone(key))
			if (virtual_length || descriptor.enumerable == 0): continue
			js_value* name = js_runtime_string(rt, key)
			js_value* scope = env
			if (lexical):
				scope = js_runtime_environment(rt, env)
				js_runtime_pattern_declare(rt, pattern, scope, 1, strcmp(node.text, c"const") == 0)
				js_runtime_pattern_bind(rt, pattern, name, scope)
			else: js_for_in_assign(rt, pattern, env, name)
			if (rt.completion.status != 0): break
			js_value* body = js_runtime_eval_node(rt, node.children[2], scope)
			if (rt.empty == 0): result = body
			if (rt.completion.status == 3 && rt.jump_target == 0):
				rt.completion.status = 0
				stopped = 1
			if (rt.completion.status == 4 && (rt.jump_target == 0 || rt.jump_target == node)):
				rt.completion.status = 0
				rt.jump_target = 0
		js_for_in_keys_free(keys)
		object = object.prototype
	js_for_in_keys_free(visited)
	rt.empty = 0
	return result
