import libs.extras.javascript.runtime

void js_runtime_array_copy(js_runtime* rt, js_value* from, int start, int end, js_value* target);

# Bounded Array/String methods used by the unchanged browser host modules.
# Prototype methods are shared, non-enumerable and receiver checked.
void js_runtime_collection_method(js_runtime* rt, js_value* prototype, char* name, int operation, js_host_receiver_function* callback):
	js_value* method = js_runtime_host_callable(rt, cast(void*, operation), callback)
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, prototype, key, method, 1, 0, 1)
	js_text_free(key)

int js_runtime_relative_index(js_value* value, int length, int fallback):
	if (value == 0 || value.kind == 0): return fallback
	if (value.kind != 3 || f64is_nan(value.number)): return 0
	if (value.number >= cast(float64, length)): return length
	if (value.number <= -cast(float64, length)): return 0
	int index = cast(int, value.number)
	if (index < 0): index = length + index
	return index

js_value* js_runtime_index_get(js_runtime* rt, js_value* object, int index):
	char* raw = itoa(index)
	js_text* key = js_runtime_key(raw)
	free(raw)
	js_value* value = js_runtime_member_read(rt, object, key)
	js_text_free(key)
	return value

int js_runtime_array_resize(js_runtime* rt, js_value* object, js_value* value):
	if (value.kind != 3 || f64is_nan(value.number) || value.number < 0.0 || value.number > cast(float64, rt.max_properties)):
		js_runtime_fail(rt, 2, c"invalid or excessive array length")
		return 0
	int length = cast(int, value.number)
	if (cast(float64, length) != value.number):
		js_runtime_fail(rt, 2, c"invalid array length")
		return 0
	int i = object.properties.length - 1
	while (i >= 0):
		js_value* property = object.properties[i]
		int index = js_runtime_array_index(property.key)
		if (index >= length):
			if (js_runtime_delete(rt, object, property.key) == 0):
				object.array_length = index + 1
				return 0
		i = i - 1
	object.array_length = length
	return 1

js_value* js_runtime_array_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	if (receiver.kind != 6):
		js_runtime_fail(rt, 2, c"array method requires array receiver")
		return rt.undefined_value
	int length = receiver.array_length
	if (operation == 1):
		if (length > rt.max_properties - args.length):
			js_runtime_fail(rt, 5, c"array length limit")
			return rt.undefined_value
		for i in range(args.length):
			if (js_runtime_compat_step(rt) == 0): break
			js_runtime_array_append(rt, receiver, args[i])
		return js_runtime_number(rt, cast(float64, receiver.array_length))
	int start = 0
	if (args.length > 0): start = js_runtime_relative_index(args[0], length, 0)
	if (operation == 5):
		js_value* needle = rt.undefined_value
		if (args.length > 0): needle = args[0]
		start = 0
		if (args.length > 1): start = js_runtime_relative_index(args[1], length, 0)
		for i in range(start, length):
			if (js_runtime_compat_step(rt) == 0): break
			js_value* item = js_runtime_index_get(rt, receiver, i)
			if (js_runtime_equal(item, needle) || (item.kind == 3 && needle.kind == 3 && f64is_nan(item.number) && f64is_nan(needle.number))): return js_runtime_boolean(rt, 1)
		return js_runtime_boolean(rt, 0)
	int end = length
	if (operation == 3):
		if (args.length > 1): end = js_runtime_relative_index(args[1], length, length)
		js_value* result = js_runtime_alloc(rt, 6)
		js_runtime_array_copy(rt, receiver, start, end, result)
		return result
	# shift and splice remove an interval; splice supports inserted arguments.
	int removed = length - start
	int inserted = 0
	if (operation == 2):
		start = 0
		removed = 1
		if (length == 0): return rt.undefined_value
	else:
		if (args.length == 0): removed = 0
		if (args.length > 1):
			removed = 0
			if (args[1].kind == 3 && args[1].number > 0):
				removed = length - start
				if (args[1].number < cast(float64, removed)): removed = cast(int, args[1].number)
		if (args.length > 2): inserted = args.length - 2
	if (length - removed > rt.max_properties - inserted):
		js_runtime_fail(rt, 5, c"array splice length limit")
		return rt.undefined_value
	js_value* result = js_runtime_alloc(rt, 6)
	js_runtime_array_copy(rt, receiver, start, start + removed, result)
	js_value* tail = js_runtime_alloc(rt, 6)
	js_runtime_array_copy(rt, receiver, start + removed, length, tail)
	if (rt.completion.status == 0): js_runtime_array_resize(rt, receiver, js_runtime_number(rt, cast(float64, start)))
	for i in range(inserted):
		if (js_runtime_compat_step(rt) == 0): break
		js_runtime_array_append(rt, receiver, args[i + 2])
	js_runtime_array_copy(rt, tail, 0, tail.array_length, receiver)
	if (operation == 2): return js_runtime_index_get(rt, result, 0)
	return result

js_value* js_runtime_string_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	if (receiver.kind != 4):
		js_runtime_fail(rt, 2, c"string method requires string receiver")
		return rt.undefined_value
	int length = receiver.text.units.length
	int start = 0
	if (args.length > 0): start = js_runtime_relative_index(args[0], length, 0)
	if (operation == 1):
		int end = length
		if (args.length > 1): end = js_runtime_relative_index(args[1], length, length)
		js_text* text = js_text_new()
		for i in range(start, end):
			if (js_runtime_compat_step(rt) == 0): break
			text.units.push(receiver.text.units[i])
		js_value* result = js_runtime_string(rt, text)
		js_text_free(text)
		return result
	if (operation == 2):
		if (args.length > 0 && args[0].kind == 3 && args[0].number < 0.0): return rt.undefined_value
		if (start >= length): return rt.undefined_value
		int unit = receiver.text.units[start]
		if (unit >= 55296 && unit <= 56319 && start + 1 < length):
			int low = receiver.text.units[start + 1]
			if (low >= 56320 && low <= 57343): unit = 65536 + ((unit - 55296) << 10) + low - 56320
		return js_runtime_number(rt, cast(float64, unit))
	if (args.length == 0 || args[0].kind != 4):
		js_runtime_fail(rt, 6, c"string search requires string argument")
		return rt.undefined_value
	js_text* needle = args[0].text
	start = 0
	if (args.length > 1 && args[1].kind == 3 && args[1].number > 0): start = js_runtime_relative_index(args[1], length, 0)
	for i in range(start, length + 1):
		if (js_runtime_compat_step(rt) == 0): break
		int equal = needle.units.length <= length - i
		if (equal):
			for j in range(needle.units.length):
				if (js_runtime_compat_step(rt) == 0 || needle.units[j] != receiver.text.units[i + j]):
					equal = 0
					break
		if (equal):
			if (operation == 3): return js_runtime_boolean(rt, 1)
			return js_runtime_number(rt, cast(float64, i))
		if (operation == 3): break
	if (operation == 3): return js_runtime_boolean(rt, 0)
	return js_runtime_number(rt, -1.0)

void js_runtime_install_collections(js_runtime* rt):
	rt.array_prototype = js_runtime_alloc(rt, 5)
	rt.string_prototype = js_runtime_alloc(rt, 5)
	js_runtime_collection_method(rt, rt.array_prototype, c"push", 1, js_runtime_array_method)
	js_runtime_collection_method(rt, rt.array_prototype, c"shift", 2, js_runtime_array_method)
	js_runtime_collection_method(rt, rt.array_prototype, c"slice", 3, js_runtime_array_method)
	js_runtime_collection_method(rt, rt.array_prototype, c"splice", 4, js_runtime_array_method)
	js_runtime_collection_method(rt, rt.array_prototype, c"includes", 5, js_runtime_array_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"slice", 1, js_runtime_string_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"codePointAt", 2, js_runtime_string_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"startsWith", 3, js_runtime_string_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"indexOf", 4, js_runtime_string_method)

int js_runtime_index_present(js_runtime* rt, js_value* object, int index):
	char* raw = itoa(index)
	js_text* key = js_runtime_key(raw)
	free(raw)
	int present = 0
	int depth = 0
	while (object != 0):
		if (depth >= rt.max_depth):
			js_runtime_fail(rt, 5, c"array prototype depth limit")
			break
		depth = depth + 1
		if (js_runtime_property(object, key) != 0):
			present = 1
			break
		object = object.prototype
	js_text_free(key)
	return present

void js_runtime_array_copy(js_runtime* rt, js_value* from, int start, int end, js_value* target):
	for i in range(start, end):
		if (js_runtime_compat_step(rt) == 0): break
		if (js_runtime_index_present(rt, from, i)): js_runtime_array_append(rt, target, js_runtime_index_get(rt, from, i))
		else: target.array_length = target.array_length + 1
