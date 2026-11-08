# The global object, identifier references, `delete`, `in`, for-in and
# destructuring assignment for the embedded interpreter (reardan/w#907;
# ECMA-262 2020 sec-global-object, sec-putvalue, sec-delete-operator,
# sec-relational-operators, sec-for-in-and-for-of-statements and
# sec-destructuring-assignment). Imported by runtime.w after its core.
#
# Built-ins and global var/function declarations are properties of
# rt.global_object. rt.global is the global declarative record for let,
# const and class; its parent is the global object, so identifier
# resolution reaches global properties after global lexicals, and its this
# value is the global object. A global property record whose
# variable_scope is 1 was declared by var or function (HasVarDeclaration);
# an environment binding whose variable_scope is 2 was created by eval code
# and is deletable.
import libs.extras.javascript.runtime


void js_runtime_global_constant(js_runtime* rt, char* name, js_value* value):
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, rt.global_object, key, value, 0, 0, 0)
	js_text_free(key)


void js_runtime_install_global(js_runtime* rt):
	js_runtime_global_constant(rt, c"undefined", rt.undefined_value)
	js_runtime_global_constant(rt, c"NaN", js_runtime_number(rt, float64_from_bits((0x7ff << 52) | 1)))
	js_runtime_global_constant(rt, c"Infinity", js_runtime_number(rt, float64_from_bits(0x7ff << 52)))
	js_text* key = js_runtime_key(c"globalThis")
	js_runtime_define_data(rt, rt.global_object, key, rt.global_object, 1, 0, 1)
	js_text_free(key)


int js_runtime_global_lexical_conflict(js_runtime* rt, js_text* key):
	return js_runtime_property(rt.global, key) != 0


# CreateGlobalVarBinding (value 0) and CreateGlobalFunctionBinding. Bindings
# made by eval code are configurable. Returns 0 after a TypeError.
int js_runtime_global_declare(js_runtime* rt, js_text* key, js_value* value, int function):
	js_value* object = rt.global_object
	js_value* existing = js_runtime_property(object, key)
	int deletable = rt.eval_code != 0
	if (function):
		if (existing == 0 || existing.configurable):
			if (existing != 0 && existing.configurable): deletable = existing.configurable && rt.eval_code != 0
			if (js_runtime_define_data(rt, object, key, value, 1, 1, deletable) == 0): return 0
		else if (existing.accessor || existing.writable == 0 || existing.enumerable == 0):
			js_runtime_fail(rt, 2, c"global function cannot be declared")
			return 0
		else: existing.value = value
	else if (existing == 0):
		if (js_runtime_define_data(rt, object, key, rt.undefined_value, 1, 1, deletable) == 0): return 0
	existing = js_runtime_property(object, key)
	if (existing != 0): existing.variable_scope = 1
	return 1


# PutValue for an identifier reference: declarative bindings, global object
# properties (accessors and read-only data included) and, outside strict
# code, unresolvable references, which create a global object property.
void js_runtime_identifier_put(js_runtime* rt, js_value* env, char* name, js_value* value):
	if (rt.completion.status != 0): return
	js_value* binding = js_runtime_binding(env, name)
	if (rt.completion.status != 0): return
	if (binding == 0):
		if (env.strict):
			js_runtime_fail(rt, 2, c"uninitialized or missing binding")
			return
		js_text* key = js_runtime_key(name)
		js_runtime_member_write(rt, rt.global_object, key, value)
		js_text_free(key)
		return
	if (binding.initialized == 0):
		js_runtime_fail(rt, 2, c"uninitialized or missing binding")
		return
	if (binding.immutable || binding.accessor == 2):
		if (binding.silent_immutable == 0 || env.strict): js_runtime_fail(rt, 2, c"assignment to constant binding")
		return
	if (binding.accessor == 1):
		if (binding.setter == 0):
			if (env.strict): js_runtime_fail(rt, 2, c"property write rejected")
			return
		list[js_value*] arguments = new list[js_value*]
		arguments.push(value)
		js_runtime_call_receiver(rt, binding.setter, rt.global_object, arguments)
		__w_list_free(cast(__w_list*, arguments))
		return
	if (binding.writable == 0):
		if (env.strict): js_runtime_fail(rt, 2, c"property write rejected")
		return
	binding.value = value


int js_runtime_symbol_key(js_text* key):
	return key.units.length == 1 && key.units[0] < 0


js_text* js_runtime_index_key(int index):
	char* text = itoa(index)
	js_text* key = js_runtime_key(text)
	free(text)
	return key


# String values and String wrapper objects expose their code units as
# virtual own properties.
int js_runtime_string_units(js_value* object):
	if (object.kind == 4 || object.builtin_state == 1): return object.text.units.length
	return -1


# OrdinaryOwnPropertyKeys: integer indices ascending, then string keys and
# (when symbols is set) symbol keys in creation order. Returns owned keys.
list[js_text*] js_runtime_own_keys(js_value* object, int symbols):
	list[js_text*] keys = new list[js_text*]
	int units = js_runtime_string_units(object)
	for i in range(units): keys.push(js_runtime_index_key(i))
	if (object.kind == 4): return keys
	# Insertion sort scanning from the end: ascending creation is linear.
	list[js_value*] indexed = new list[js_value*]
	list[int] order = new list[int]
	for js_value* property in object.properties:
		int index = js_runtime_array_index(property.key)
		if (index < 0 || index < units): continue
		indexed.push(property)
		order.push(index)
		int j = order.length - 1
		while (j > 0 && order[j - 1] > index):
			order[j] = order[j - 1]
			indexed[j] = indexed[j - 1]
			j = j - 1
		order[j] = index
		indexed[j] = property
	for js_value* property in indexed: keys.push(js_text_clone(property.key))
	for js_value* property in object.properties:
		if (js_runtime_array_index(property.key) < 0 && js_runtime_symbol_key(property.key) == 0): keys.push(js_text_clone(property.key))
	if (symbols):
		for js_value* property in object.properties:
			if (js_runtime_symbol_key(property.key)): keys.push(js_text_clone(property.key))
	__w_list_free(cast(__w_list*, indexed))
	__w_list_free(cast(__w_list*, order))
	return keys


void js_runtime_free_keys(list[js_text*] keys):
	for js_text* key in keys: js_text_free(key)
	__w_list_free(cast(__w_list*, keys))


# Whether key is an own property of object; enumerable receives its flag.
int js_runtime_own_property(js_value* object, js_text* key, int* enumerable):
	*enumerable = 0
	int units = js_runtime_string_units(object)
	int index = js_runtime_array_index(key)
	if (index >= 0 && index < units):
		*enumerable = 1
		return 1
	if (object.kind == 4): return js_runtime_key_is(key, c"length")
	if (object.kind == 6 && js_runtime_key_is(key, c"length")): return 1
	js_value* property = js_runtime_property(object, key)
	if (property == 0): return 0
	*enumerable = property.enumerable
	return 1


# The prototype a primitive's property lookups start from.
js_value* js_runtime_lookup_prototype(js_runtime* rt, js_value* value):
	if (value.kind == 4): return rt.string_prototype
	if (value.kind == 3): return rt.number_prototype
	if (value.kind == 2): return rt.boolean_prototype
	if (value.kind == 11): return rt.symbol_prototype
	if (js_runtime_object(value)): return value.prototype
	return 0


# HasProperty along the prototype chain (no getters run).
int js_runtime_has_key(js_runtime* rt, js_value* object, js_text* key):
	js_value* current = object
	int depth = 0
	while (current != 0):
		depth = depth + 1
		if (depth > rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
			return 0
		if (current.kind == 7): js_runtime_function_prototype(rt, current, key)
		int enumerable = 0
		if (current.host_get != 0 || js_runtime_own_property(current, key, &enumerable)): return 1
		current = current.prototype
	return 0


js_value* js_runtime_in_operator(js_runtime* rt, js_value* key_value, js_value* object):
	if (js_runtime_object(object) == 0):
		js_runtime_fail(rt, 2, c"right operand of in is not an object")
		return rt.undefined_value
	js_text* key = js_runtime_property_key(rt, key_value)
	if (key == 0): return rt.undefined_value
	int found = js_runtime_has_key(rt, object, key)
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_boolean(rt, found)


# [[Delete]]: 1 when the property is absent or was removed, 0 when it is not
# configurable (array length, String wrapper units, ...).
int js_runtime_delete_property(js_runtime* rt, js_value* object, js_text* key):
	int enumerable = 0
	int units = js_runtime_string_units(object)
	int index = js_runtime_array_index(key)
	if (units >= 0 && ((index >= 0 && index < units) || js_runtime_key_is(key, c"length"))): return 0
	if (js_runtime_object(object) == 0): return 1
	if (object.kind == 6 && js_runtime_key_is(key, c"length")): return 0
	if (object.kind == 7): js_runtime_function_prototype(rt, object, key)
	if (js_runtime_own_property(object, key, &enumerable) == 0): return 1
	return js_runtime_delete(rt, object, key)


void js_runtime_remove_binding(js_value* env, js_text* key):
	for i in range(env.properties.length):
		js_value* property = env.properties[i]
		if (js_text_equal(property.key, key)):
			js_text_free(property.key)
			free(property)
			for j in range(i, env.properties.length - 1): env.properties[j] = env.properties[j + 1]
			env.properties.pop()
			return


js_value* js_runtime_delete_operator(js_runtime* rt, js_node* operand, js_value* env):
	if (js_kind(operand, c"identifier")):
		# Sloppy code only: deleting an identifier is a strict early error.
		js_text* key = js_runtime_key(operand.text)
		int deleted = 1
		js_value* scope = env
		while (scope != 0):
			js_value* binding = js_runtime_property(scope, key)
			if (binding != 0):
				if (scope.kind != 8): deleted = js_runtime_delete_property(rt, scope, key)
				else if (binding.variable_scope == 2): js_runtime_remove_binding(scope, key)
				else: deleted = 0
				break
			scope = scope.parent
		js_text_free(key)
		return js_runtime_boolean(rt, deleted)
	if (js_kind(operand, c"member") == 0 && js_kind(operand, c"computed_member") == 0):
		js_runtime_eval_node(rt, operand, env)
		if (rt.completion.status != 0): return rt.undefined_value
		return js_runtime_boolean(rt, 1)
	if (js_kind(operand.children[0], c"super")):
		js_value* receiver = rt.undefined_value
		js_runtime_super_base(rt, env, &receiver)
		if (rt.completion.status == 0): js_runtime_fail(rt, 2, c"invalid assignment target")
		return rt.undefined_value
	js_value* object = js_runtime_eval_node(rt, operand.children[0], env)
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* key = js_runtime_member_key(rt, operand, env)
	if (rt.completion.status != 0): return rt.undefined_value
	if (object.kind == 0 || object.kind == 1):
		js_text_free(key)
		js_runtime_fail(rt, 2, c"cannot delete a property of null or undefined")
		return rt.undefined_value
	int deleted = js_runtime_delete_property(rt, object, key)
	js_text_free(key)
	if (deleted == 0 && env.strict):
		js_runtime_fail(rt, 2, c"property is not configurable")
		return rt.undefined_value
	return js_runtime_boolean(rt, deleted)


# A reference evaluated before its value is known (destructuring targets
# and for-in/of assignment heads): 1 identifier, 2 property, 3 super property.
struct js_runtime_reference:
	int kind
	char* name
	js_value* object
	js_text* key
	js_value* receiver


int js_runtime_reference_eval(js_runtime* rt, js_node* target, js_value* env, js_runtime_reference* reference):
	reference.kind = 0
	reference.key = 0
	reference.object = 0
	reference.receiver = 0
	if (js_kind(target, c"identifier")):
		reference.kind = 1
		reference.name = target.text
		return 1
	if (js_kind(target, c"call")):
		# Annex B web-compat call target in sloppy code: evaluate the call,
		# then throw a ReferenceError.
		js_runtime_eval_node(rt, target, env)
		if (rt.completion.status == 0): js_runtime_fail(rt, 2, c"invalid assignment target")
		return 0
	if (js_kind(target.children[0], c"super")):
		reference.kind = 3
		reference.object = js_runtime_super_base(rt, env, &reference.receiver)
		if (rt.completion.status != 0): return 0
		reference.key = js_runtime_member_key(rt, target, env)
		if (rt.completion.status == 0 && reference.object == 0): js_runtime_fail(rt, 2, c"super base is null")
		return rt.completion.status == 0
	reference.kind = 2
	reference.object = js_runtime_eval_node(rt, target.children[0], env)
	if (rt.completion.status != 0): return 0
	reference.key = js_runtime_member_key(rt, target, env)
	return rt.completion.status == 0


void js_runtime_reference_put(js_runtime* rt, js_runtime_reference* reference, js_value* value, js_value* env):
	if (rt.completion.status == 0):
		if (reference.kind == 1): js_runtime_identifier_put(rt, env, reference.name, value)
		else if (reference.kind == 3):
			if (js_runtime_write_receiver(rt, reference.object, reference.key, value, reference.receiver) == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"property write rejected")
		else if (reference.kind == 2):
			js_value* object = reference.object
			if (object.kind != 0 && object.kind != 1 && js_runtime_object(object) == 0 && object.kind != 8):
				# Primitive bases: the write has no effect (TypeError in strict code).
				if (env.strict): js_runtime_fail(rt, 2, c"property write rejected")
			else if (js_runtime_member_write(rt, object, reference.key, value) == 0 && env.strict && rt.completion.status == 0): js_runtime_fail(rt, 2, c"property write rejected")
	js_text_free(reference.key)
	reference.key = 0


int js_runtime_assignment_pattern(js_node* node):
	return js_kind(node, c"array") || js_kind(node, c"object")


js_value* js_runtime_destructure_default(js_runtime* rt, js_value* value, js_node* initializer, char* name, js_value* env):
	if (initializer == 0 || value.kind != 0 || rt.completion.status != 0): return value
	if (name != 0): return js_runtime_named_eval(rt, initializer, env, name)
	return js_runtime_eval_node(rt, initializer, env)


# Stores a destructured value: nested patterns recurse, other targets use
# their reference evaluated beforehand.
void js_runtime_destructure_store(js_runtime* rt, js_node* element, js_runtime_reference* reference, js_value* value, js_value* env):
	if (element != 0 && js_runtime_assignment_pattern(element)):
		if (rt.completion.status == 0): js_runtime_destructure(rt, element, value, env)
		return
	js_runtime_reference_put(rt, reference, value, env)


js_value* js_runtime_destructure_step(js_runtime* rt, js_value* value, js_value* iterator, int* index, int* done):
	if (*done || rt.completion.status != 0): return 0
	js_value* next = 0
	if (iterator != 0): next = js_runtime_iterator_step(rt, iterator)
	else: next = js_runtime_iter_next(rt, value, index)
	if (next == 0): *done = 1
	return next


# Splits a destructuring element into its target and initializer.
js_node* js_runtime_destructure_target(js_node* element, js_node** initializer):
	*initializer = 0
	if (js_kind(element, c"assignment") && strcmp(element.text, c"=") == 0):
		*initializer = element.children[1]
		return element.children[0]
	return element


char* js_runtime_target_name(js_node* target):
	if (js_kind(target, c"identifier")): return target.text
	return 0


void js_runtime_destructure_array(js_runtime* rt, js_node* pattern, js_value* value, js_value* env):
	js_value* iterator = 0
	if (value.kind != 6 && value.kind != 4):
		iterator = js_runtime_iterator_open(rt, value)
		if (iterator == 0): return
	int index = 0
	int done = 0
	for js_node* child in pattern.children:
		if (rt.completion.status != 0): break
		if (js_kind(child, c"empty")):
			js_runtime_destructure_step(rt, value, iterator, &index, &done)
			continue
		int rest = js_kind(child, c"spread")
		js_node* initializer = 0
		js_node* target = child
		if (rest): target = child.children[0]
		else: target = js_runtime_destructure_target(child, &initializer)
		js_runtime_reference reference
		reference.key = 0
		reference.kind = 0
		if (js_runtime_assignment_pattern(target) == 0 && js_runtime_reference_eval(rt, target, env, &reference) == 0): break
		js_value* item = rt.undefined_value
		if (rest):
			item = js_runtime_alloc(rt, 6)
			while (done == 0 && js_runtime_compat_step(rt)):
				js_value* next = js_runtime_destructure_step(rt, value, iterator, &index, &done)
				if (next != 0): js_runtime_array_append(rt, item, next)
		else:
			js_value* next = js_runtime_destructure_step(rt, value, iterator, &index, &done)
			if (next != 0): item = next
		if (rt.completion.status != 0):
			js_text_free(reference.key)
			# An abrupt next() leaves the iterator done; nothing to close.
			done = 1
			break
		item = js_runtime_destructure_default(rt, item, initializer, js_runtime_target_name(target), env)
		js_runtime_destructure_store(rt, target, &reference, item, env)
	if (iterator != 0 && done == 0 && rt.completion.status != 5): js_runtime_iterator_close(rt, iterator)


int js_runtime_key_listed(list[js_text*] keys, js_text* key):
	for js_text* item in keys:
		if (js_text_equal(item, key)): return 1
	return 0


void js_runtime_destructure_object(js_runtime* rt, js_node* pattern, js_value* value, js_value* env):
	if (value.kind == 0 || value.kind == 1):
		js_runtime_fail(rt, 2, c"cannot destructure null or undefined")
		return
	list[js_text*] seen = new list[js_text*]
	for js_node* child in pattern.children:
		if (rt.completion.status != 0): break
		js_runtime_reference reference
		reference.key = 0
		reference.kind = 0
		if (js_kind(child, c"spread")):
			js_node* target = child.children[0]
			if (js_runtime_reference_eval(rt, target, env, &reference) == 0): break
			# CopyDataProperties excluding the keys already destructured.
			js_value* rest = js_runtime_alloc(rt, 5)
			list[js_text*] keys = js_runtime_own_keys(value, 1)
			for js_text* key in keys:
				if (rt.completion.status != 0 || js_runtime_compat_step(rt) == 0): break
				int enumerable = 0
				if (js_runtime_key_listed(seen, key) || js_runtime_own_property(value, key, &enumerable) == 0 || enumerable == 0): continue
				js_value* item = js_runtime_member_read(rt, value, key)
				if (rt.completion.status == 0): js_runtime_define_data(rt, rest, key, item, 1, 1, 1)
			js_runtime_free_keys(keys)
			js_runtime_reference_put(rt, &reference, rest, env)
			continue
		js_text* key = 0
		js_node* target = 0
		js_node* initializer = 0
		char* name = 0
		if (js_kind(child, c"property_shorthand")):
			key = js_runtime_key(child.text)
			name = child.text
			reference.kind = 1
			reference.name = child.text
			if (child.children.length > 0): initializer = child.children[0]
		else:
			js_node* element = child.children[0]
			if (js_kind(child, c"computed_property")):
				js_value* name_value = js_runtime_eval_node(rt, child.children[0], env)
				if (rt.completion.status != 0): break
				key = js_runtime_property_key(rt, name_value)
				if (key == 0): break
				element = child.children[1]
			else: key = js_runtime_key(child.text)
			target = js_runtime_destructure_target(element, &initializer)
			name = js_runtime_target_name(target)
			if (js_runtime_assignment_pattern(target) == 0 && js_runtime_reference_eval(rt, target, env, &reference) == 0):
				js_text_free(key)
				break
		seen.push(key)
		js_value* item = rt.undefined_value
		if (value.kind == 3 || value.kind == 2 || value.kind == 4 || value.kind == 10 || value.kind == 11 || js_runtime_object(value)): item = js_runtime_member_read(rt, value, key)
		item = js_runtime_destructure_default(rt, item, initializer, name, env)
		js_runtime_destructure_store(rt, target, &reference, item, env)
	js_runtime_free_keys(seen)


void js_runtime_destructure(js_runtime* rt, js_node* target, js_value* value, js_value* env):
	if (js_runtime_compat_step(rt) == 0): return
	if (js_kind(target, c"array")): js_runtime_destructure_array(rt, target, value, env)
	else: js_runtime_destructure_object(rt, target, value, env)


# Binds a for-in/of iteration value through a var or assignment-target head.
void js_runtime_head_assign(js_runtime* rt, js_node* node, js_value* value, js_value* env):
	js_node* target = node.children[0]
	if (js_kind(target, c"default_pattern")): target = target.children[0]
	if (strcmp(node.text, c"var") == 0):
		js_runtime_pattern_bind(rt, target, value, env)
		return
	if (js_runtime_assignment_pattern(target)):
		js_runtime_destructure(rt, target, value, env)
		return
	js_runtime_reference reference
	reference.key = 0
	if (js_runtime_reference_eval(rt, target, env, &reference)): js_runtime_reference_put(rt, &reference, value, env)
	else: js_text_free(reference.key)


# EnumerateObjectProperties: own keys (integer indices ascending, then
# strings in creation order; never symbols), then each prototype's, skipping
# keys already seen on a nearer object, enumerable or not. Keys are collected
# when the loop starts; a property deleted before it is reached is skipped.
js_value* js_runtime_for_in(js_runtime* rt, js_node* node, js_value* env):
	js_node* pattern = node.children[0]
	int lexical = strcmp(node.text, c"let") == 0 || strcmp(node.text, c"const") == 0
	js_value* initial = env
	if (lexical):
		initial = js_runtime_environment(rt, env)
		js_runtime_pattern_declare(rt, pattern, initial, 1, 0)
	else if (js_kind(pattern, c"default_pattern")):
		# Annex B.3.6: for (var x = init in o) assigns x before evaluating o.
		js_node* name = pattern.children[0]
		js_value* first = js_runtime_named_eval(rt, pattern.children[1], env, name.text)
		if (rt.completion.status == 0): js_runtime_pattern_bind(rt, name, first, env)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* subject = js_runtime_eval_node(rt, node.children[1], initial)
	if (rt.completion.status != 0): return rt.undefined_value
	rt.empty = 0
	if (subject.kind == 0 || subject.kind == 1): return rt.undefined_value
	list[js_text*] keys = new list[js_text*]
	list[js_value*] owners = new list[js_value*]
	list[js_text*] visited = new list[js_text*]
	js_value* current = subject
	int depth = 0
	while (current != 0 && rt.completion.status == 0):
		depth = depth + 1
		if (depth > rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
			break
		list[js_text*] own = js_runtime_own_keys(current, 0)
		for js_text* key in own:
			if (js_runtime_key_listed(visited, key)): continue
			visited.push(js_text_clone(key))
			int enumerable = 0
			js_runtime_own_property(current, key, &enumerable)
			if (enumerable):
				keys.push(js_text_clone(key))
				owners.push(current)
		js_runtime_free_keys(own)
		if (js_runtime_compat_step(rt) == 0): break
		current = js_runtime_lookup_prototype(rt, current)
	js_runtime_free_keys(visited)
	js_value* result = rt.undefined_value
	for i in range(keys.length):
		if (rt.completion.status != 0 || js_runtime_compat_step(rt) == 0): break
		int enumerable = 0
		if (js_runtime_own_property(owners[i], keys[i], &enumerable) == 0): continue
		js_value* value = js_runtime_string(rt, keys[i])
		js_value* scope = env
		if (lexical):
			scope = js_runtime_environment(rt, env)
			js_runtime_pattern_declare(rt, pattern, scope, 1, strcmp(node.text, c"const") == 0)
			js_runtime_pattern_bind(rt, pattern, value, scope)
		else: js_runtime_head_assign(rt, node, value, env)
		if (rt.completion.status != 0): break
		js_value* body_value = js_runtime_eval_node(rt, node.children[2], scope)
		if (rt.empty == 0): result = body_value
		if (rt.completion.status == 3 && rt.jump_target == 0):
			rt.completion.status = 0
			break
		if (rt.completion.status == 4 && (rt.jump_target == 0 || rt.jump_target == node)):
			rt.completion.status = 0
			rt.jump_target = 0
	js_runtime_free_keys(keys)
	__w_list_free(cast(__w_list*, owners))
	rt.empty = 0
	return result
