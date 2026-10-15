import libs.extras.javascript.runtime

# Browser-host language operations. Imported by runtime.w after its core.
# Binding patterns visit only binding positions, never initializer expressions.
void js_runtime_pattern_names(js_node* pattern, list[js_node*] names):
	if (js_kind(pattern, c"identifier")):
		names.push(pattern)
		return
	if (js_kind(pattern, c"default_pattern") || js_kind(pattern, c"rest") || js_kind(pattern, c"pattern_property")):
		js_runtime_pattern_names(pattern.children[0], names)
		return
	for i in range(pattern.children.length): js_runtime_pattern_names(pattern.children[i], names)

# mode 0 checks lexicals, 1 installs TDZ lexicals, 2 checks vars,
# 3 installs vars, 4 installs parameters (all before defaults are evaluated).
void js_runtime_pattern_declare(js_runtime* rt, js_node* pattern, js_value* env, int mode, int immutable):
	list[js_node*] names = new list[js_node*]
	js_runtime_pattern_names(pattern, names)
	for i in range(names.length):
		if (rt.completion.status != 0): break
		js_text* key = js_runtime_key(names[i].text)
		js_value* binding = js_runtime_property(env, key)
		if ((mode == 0 && binding != 0) || (mode == 2 && binding != 0 && binding.lexical_binding)): js_runtime_fail(rt, 2, c"duplicate lexical binding")
		else if (mode == 1 || mode == 4 || (mode == 3 && binding == 0)):
			js_runtime_put(rt, env, key, rt.undefined_value)
			binding = js_runtime_property(env, key)
			if (binding != 0):
				binding.initialized = mode == 3
				binding.lexical_binding = mode == 1
				binding.immutable = immutable
		js_text_free(key)
	__w_list_free(cast(__w_list*, names))

int js_runtime_compat_step(js_runtime* rt):
	if (rt.completion.status != 0): return 0
	if (rt.remaining <= 0):
		js_runtime_fail(rt, 5, c"JavaScript iteration limit")
		return 0
	rt.remaining = rt.remaining - 1
	rt.completion.steps = rt.completion.steps + 1
	return 1

# Supported iterables share the for-of array/string contract. Strings yield
# code points, while indexed string property reads still yield UTF-16 units.
js_value* js_runtime_iter_next(js_runtime* rt, js_value* value, int* index):
	if (value.kind == 6):
		if (*index >= value.array_length): return 0
		char* key = itoa(*index)
		js_text* text = js_runtime_key(key)
		free(key)
		js_value* item = js_runtime_member_read(rt, value, text)
		js_text_free(text)
		*index = *index + 1
		return item
	if (value.kind == 4):
		if (*index >= value.text.units.length): return 0
		js_text* text = js_text_new()
		int unit = value.text.units[*index]
		text.units.push(unit)
		*index = *index + 1
		if (unit >= 55296 && unit <= 56319 && *index < value.text.units.length):
			int low = value.text.units[*index]
			if (low >= 56320 && low <= 57343):
				text.units.push(low)
				*index = *index + 1
		js_value* item = js_runtime_string(rt, text)
		js_text_free(text)
		return item
	js_runtime_fail(rt, 6, c"iteration requires array or string")
	return 0

void js_runtime_array_append(js_runtime* rt, js_value* array, js_value* value):
	char* index = itoa(array.array_length)
	js_text* key = js_runtime_key(index)
	free(index)
	js_runtime_member_write(rt, array, key, value)
	js_text_free(key)

void js_runtime_pattern_bind(js_runtime* rt, js_node* pattern, js_value* value, js_value* env):
	if (js_runtime_compat_step(rt) == 0): return
	if (js_kind(pattern, c"empty")): return
	if (js_kind(pattern, c"identifier")):
		js_value* binding = js_runtime_binding(env, pattern.text)
		if (binding == 0): js_runtime_fail(rt, 6, c"binding pattern requires a declaration")
		else:
			binding.value = value
			binding.initialized = 1
		return
	if (js_kind(pattern, c"default_pattern")):
		if (value.kind == 0): value = js_runtime_eval_node(rt, pattern.children[1], env)
		if (rt.completion.status == 0): js_runtime_pattern_bind(rt, pattern.children[0], value, env)
		return
	if (js_kind(pattern, c"rest")):
		js_runtime_pattern_bind(rt, pattern.children[0], value, env)
		return
	if (js_kind(pattern, c"array_pattern")):
		if (value.kind != 6 && value.kind != 4):
			js_runtime_fail(rt, 2, c"array binding requires iterable")
			return
		int index = 0
		for i in range(pattern.children.length):
			if (rt.completion.status != 0): break
			js_node* child = pattern.children[i]
			js_value* item = 0
			if (js_kind(child, c"rest")):
				item = js_runtime_alloc(rt, 6)
				while (js_runtime_compat_step(rt)):
					js_value* next = js_runtime_iter_next(rt, value, &index)
					if (next == 0): break
					js_runtime_array_append(rt, item, next)
			else: item = js_runtime_iter_next(rt, value, &index)
			if (item == 0): item = rt.undefined_value
			js_runtime_pattern_bind(rt, child, item, env)
		return
	if (js_kind(pattern, c"object_pattern")):
		if (value.kind == 0 || value.kind == 1):
			js_runtime_fail(rt, 2, c"cannot destructure null or undefined")
			return
		for i in range(pattern.children.length):
			if (rt.completion.status != 0): break
			js_node* child = pattern.children[i]
			if (js_kind(child, c"rest")):
				js_value* rest = js_runtime_alloc(rt, 5)
				for j in range(value.properties.length):
					js_value* property = value.properties[j]
					int excluded = property.enumerable == 0
					for k in range(i):
						if (js_runtime_key_is(property.key, pattern.children[k].text)): excluded = 1
					if (excluded || js_runtime_compat_step(rt) == 0): continue
					js_value* item = js_runtime_member_read(rt, value, property.key)
					if (rt.completion.status == 0): js_runtime_member_write(rt, rest, property.key, item)
				js_runtime_pattern_bind(rt, child.children[0], rest, env)
			else:
				js_text* key = js_runtime_key(child.text)
				js_value* item = js_runtime_member_read(rt, value, key)
				js_text_free(key)
				if (rt.completion.status == 0): js_runtime_pattern_bind(rt, child.children[0], item, env)

void js_runtime_arguments(js_runtime* rt, js_node* node, js_value* env, list[js_value*] arguments):
	for i in range(1, node.children.length):
		if (rt.completion.status != 0): break
		js_node* child = node.children[i]
		if (js_kind(child, c"spread")):
			js_value* value = js_runtime_eval_node(rt, child.children[0], env)
			int index = 0
			while (js_runtime_compat_step(rt)):
				js_value* next = js_runtime_iter_next(rt, value, &index)
				if (next == 0): break
				arguments.push(next)
		else: arguments.push(js_runtime_eval_node(rt, child, env))

# The chain wrapper bounds short-circuit propagation. Parentheses create a
# separate wrapper, so (null?.a).b still throws and skipped keys never run.
js_value* js_runtime_chain(js_runtime* rt, js_node* node, js_value* env, int* skipped, js_value** receiver):
	if (*skipped || rt.completion.status != 0): return rt.undefined_value
	int member = js_kind(node, c"member") || js_kind(node, c"computed_member") || js_kind(node, c"optional_member") || js_kind(node, c"optional_computed_member")
	int call = js_kind(node, c"call") || js_kind(node, c"optional_call")
	if (member || call):
		if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
		js_value* base_receiver = rt.undefined_value
		js_value* base = js_runtime_chain(rt, node.children[0], env, skipped, &base_receiver)
		if (*skipped || rt.completion.status != 0): return rt.undefined_value
		if (starts_with(node.kind, c"optional_") && (base.kind == 0 || base.kind == 1)):
			*skipped = 1
			return rt.undefined_value
		if (member):
			js_text* key = 0
			if (js_kind(node, c"member") || js_kind(node, c"optional_member")): key = js_runtime_key(node.children[1].text)
			else: key = js_runtime_member_key(rt, node, env)
			js_value* value = rt.undefined_value
			if (rt.completion.status == 0): value = js_runtime_member_read(rt, base, key)
			js_text_free(key)
			*receiver = base
			return value
		list[js_value*] args = new list[js_value*]
		js_runtime_arguments(rt, node, env, args)
		js_value* value = rt.undefined_value
		if (rt.completion.status == 0): value = js_runtime_call_receiver(rt, base, base_receiver, args)
		__w_list_free(cast(__w_list*, args))
		*receiver = rt.undefined_value
		return value
	*receiver = rt.undefined_value
	return js_runtime_eval_node(rt, node, env)

float64 js_runtime_numeric_literal(char* text, int* consumed):
	int radix = 10
	if (text[0] == '0'):
		if (text[1] == 'x' || text[1] == 'X'): radix = 16
		else if (text[1] == 'b' || text[1] == 'B'): radix = 2
		else if (text[1] == 'o' || text[1] == 'O'): radix = 8
	if (radix == 10): return parse_float64(text, consumed)
	float64 result = 0.0
	int at = 2
	while (text[at] != 0):
		int digit = text[at] - '0'
		if (text[at] >= 'a' && text[at] <= 'f'): digit = text[at] - 'a' + 10
		if (text[at] >= 'A' && text[at] <= 'F'): digit = text[at] - 'A' + 10
		if (digit < 0 || digit >= radix): break
		result = result * cast(float64, radix) + cast(float64, digit)
		at = at + 1
	*consumed = at
	return result

# ECMAScript ToInt32 from IEEE-754 bits, including huge finite doubles,
# NaN, infinities and signed zero; no overflowing float-to-int conversion.
int js_runtime_int32(float64 value):
	int bits = float64_bits(value)
	int exponent = ((bits >> 52) & 2047) - 1023
	if (exponent < 0 || exponent >= 84): return 0
	int mantissa = (bits & ((1 << 52) - 1)) | (1 << 52)
	int integer = 0
	if (exponent <= 52): integer = mantissa >> (52 - exponent)
	else: integer = mantissa << (exponent - 52)
	integer = integer & ((1 << 32) - 1)
	if (bits < 0): integer = (-integer) & ((1 << 32) - 1)
	if (integer >= (1 << 31)): integer = integer - (1 << 32)
	return integer

int js_runtime_bit_operator(char* op):
	return strcmp(op, c"&") == 0 || strcmp(op, c"|") == 0 || strcmp(op, c"^") == 0 || strcmp(op, c"<<") == 0 || strcmp(op, c">>") == 0 || strcmp(op, c">>>") == 0

js_value* js_runtime_bit_binary(js_runtime* rt, char* op, float64 left, float64 right):
	int a = js_runtime_int32(left)
	int b = js_runtime_int32(right)
	int value = 0
	if (strcmp(op, c"&") == 0): value = a & b
	else if (strcmp(op, c"|") == 0): value = a | b
	else if (strcmp(op, c"^") == 0): value = a ^ b
	else if (strcmp(op, c"<<") == 0):
		value = (a << (b & 31)) & ((1 << 32) - 1)
		if (value >= (1 << 31)): value = value - (1 << 32)
	else if (strcmp(op, c">>") == 0): value = a >> (b & 31)
	else: value = (a & ((1 << 32) - 1)) >> (b & 31)
	return js_runtime_number(rt, cast(float64, value))

# Imported bindings retain their source environment through getter (a traced
# value) and borrow its stable binding record through host_context. Accessor
# tag 2 is environment-only; object property descriptors use tags 0 and 1.
js_value* js_runtime_binding_value(js_runtime* rt, js_value* binding):
	int depth = 0
	while (binding != 0 && binding.accessor == 2):
		if (depth >= rt.max_depth):
			js_runtime_fail(rt, 5, c"module binding alias depth limit")
			return rt.undefined_value
		depth = depth + 1
		binding = cast(js_value*, binding.host_context)
	if (binding == 0 || binding.initialized == 0):
		js_runtime_fail(rt, 2, c"uninitialized module binding")
		return rt.undefined_value
	return binding.value
