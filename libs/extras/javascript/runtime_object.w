# Ordinary object reflection: Object statics, Object.prototype and Reflect.
# Symbols are supported through their negative-unit property keys. Native
# exotic own-key/descriptor hooks (host getters/setters, binary views) remain
# explicit unsupported operations, never guessed from getters. Every builtin
# charges its arguments and each traversed key to the active evaluation budget.
import libs.extras.javascript.runtime

# fields: 1 enumerable, 2 configurable, 4 value, 8 writable, 16 get, 32 set.
struct js_property_descriptor:
	int fields
	js_value* value
	js_value* getter
	js_value* setter
	int writable
	int enumerable
	int configurable

int js_array_length_descriptor(js_runtime* rt, js_value* array, js_property_descriptor* desc);
int js_object_has(js_runtime* rt, js_value* object, js_text* key);

int js_object_ordinary(js_runtime* rt, js_value* object):
	if (js_runtime_object(object) == 0 || object.owner != rt):
		js_runtime_fail(rt, 2, c"reflection requires an object")
		return 0
	if (object.host_get != 0 || object.host_set != 0 || object.binary_kind != 0):
		js_runtime_fail(rt, 6, c"native exotic descriptor reflection requires host hooks")
		return 0
	return 1

js_value* js_object_argument(js_runtime* rt, list[js_value*] args, int index):
	if (index < args.length): return args[index]
	return rt.undefined_value

void js_object_define_named(js_runtime* rt, js_value* object, char* name, js_value* value, int writable, int configurable):
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, object, key, value, writable, 0, configurable)
	js_text_free(key)

# The Symbol value whose property key is key. Symbols are interned only by
# their key text, so a collected symbol is recreated without a description.
js_value* js_object_key_value(js_runtime* rt, js_text* key):
	if (js_runtime_symbol_key(key) == 0): return js_runtime_string(rt, key)
	for js_value* candidate in rt.heap:
		if (candidate.kind == 11 && candidate.text != 0 && js_text_equal(candidate.text, key)): return candidate
	js_value* symbol = js_runtime_alloc(rt, 11)
	if (symbol != rt.undefined_value): symbol.text = js_text_clone(key)
	return symbol

js_value* js_object_unit_value(js_runtime* rt, js_value* object, int index):
	js_text* unit = js_text_new()
	unit.units.push(object.text.units[index])
	js_value* value = js_runtime_string(rt, unit)
	js_text_free(unit)
	return value

# [[GetOwnProperty]] including virtual String indices, Array length and live
# module namespace bindings. Returns 0 when absent or after an abrupt completion.
int js_object_own_descriptor(js_runtime* rt, js_value* object, js_text* key, js_property_descriptor* out):
	out.fields = 0
	out.value = rt.undefined_value
	out.getter = 0
	out.setter = 0
	out.writable = 0
	out.enumerable = 0
	out.configurable = 0
	if (object.kind == 7): js_runtime_function_prototype(rt, object, key)
	int units = js_runtime_string_units(object)
	int index = js_runtime_array_index(key)
	if (units >= 0 && index >= 0 && index < units):
		out.fields = 15
		out.value = js_object_unit_value(rt, object, index)
		out.enumerable = 1
		return rt.completion.status == 0
	if (object.kind == 6 && js_runtime_key_is(key, c"length")):
		out.fields = 15
		out.value = js_runtime_number(rt, cast(float64, object.array_length))
		out.writable = object.length_readonly == 0
		return rt.completion.status == 0
	js_value* property = js_runtime_property(object, key)
	if (property == 0): return 0
	out.enumerable = property.enumerable
	out.configurable = property.configurable
	out.fields = 3
	if (property.accessor == 2):
		out.fields = 15
		out.value = js_runtime_binding_value(rt, property)
		out.writable = 1
	else if (property.accessor):
		out.fields = 51
		out.getter = property.getter
		out.setter = property.setter
	else:
		out.fields = 15
		out.value = property.value
		out.writable = property.writable
	return rt.completion.status == 0

# ToPropertyDescriptor reads inherited fields, in the normative observable
# order. Presence is separate from Get, and absent attributes remain absent.
int js_object_descriptor_read(js_runtime* rt, js_value* source, js_property_descriptor* out):
	out.fields = 0
	out.value = rt.undefined_value
	out.getter = 0
	out.setter = 0
	out.writable = 0
	out.enumerable = 0
	out.configurable = 0
	if (js_runtime_object(source) == 0):
		js_runtime_fail(rt, 2, c"property descriptor must be an object")
		return 0
	for i in range(6):
		char* name = c"enumerable"
		if (i == 1): name = c"configurable"
		if (i == 2): name = c"value"
		if (i == 3): name = c"writable"
		if (i == 4): name = c"get"
		if (i == 5): name = c"set"
		js_text* key = js_runtime_key(name)
		int present = js_runtime_has_property(rt, source, key)
		js_value* value = rt.undefined_value
		if (present && rt.completion.status == 0): value = js_runtime_member_read(rt, source, key)
		js_text_free(key)
		if (rt.completion.status != 0): return 0
		if (present == 0): continue
		out.fields = out.fields | (1 << i)
		if (i == 0): out.enumerable = js_runtime_truth(value)
		if (i == 1): out.configurable = js_runtime_truth(value)
		if (i == 2): out.value = value
		if (i == 3): out.writable = js_runtime_truth(value)
		if (i >= 4):
			if (value.kind != 0 && js_runtime_callable(value) == 0):
				js_runtime_fail(rt, 2, c"descriptor accessor must be callable or undefined")
				return 0
			if (value.kind != 0):
				if (i == 4): out.getter = value
				else: out.setter = value
	if ((out.fields & 48) != 0 && (out.fields & 12) != 0):
		js_runtime_fail(rt, 2, c"descriptor cannot mix accessors and data")
		return 0
	return 1

# A String wrapper's index properties are virtual, non-writable and
# non-configurable: only a descriptor that changes nothing is accepted.
int js_object_virtual_compatible(js_runtime* rt, js_value* object, int index, js_property_descriptor* desc):
	if ((desc.fields & 48) != 0): return 0
	if ((desc.fields & 2) != 0 && desc.configurable): return 0
	if ((desc.fields & 1) != 0 && desc.enumerable == 0): return 0
	if ((desc.fields & 8) != 0 && desc.writable): return 0
	if ((desc.fields & 4) != 0):
		js_value* current = js_object_unit_value(rt, object, index)
		if (rt.completion.status != 0 || js_runtime_same_value(current, desc.value) == 0): return 0
	return 1

int js_object_descriptor_apply(js_runtime* rt, js_value* object, js_text* key, js_property_descriptor* desc):
	if (js_object_ordinary(rt, object) == 0): return 0
	if (object.kind == 6 && js_runtime_key_is(key, c"length")): return js_array_length_descriptor(rt, object, desc)
	int index = js_runtime_array_index(key)
	int units = js_runtime_string_units(object)
	if (units >= 0 && index >= 0 && index < units): return js_object_virtual_compatible(rt, object, index, desc)
	if (object.kind == 6 && index >= 0):
		if (index >= object.array_length && object.length_readonly): return 0
		if (index >= rt.max_properties):
			js_runtime_fail(rt, 5, c"Array index exceeds runtime limit")
			return 0
	if (object.kind == 7): js_runtime_function_prototype(rt, object, key)
	js_value* old = js_runtime_property(object, key)
	int accessor = (desc.fields & 48) != 0
	int data = (desc.fields & 12) != 0
	int writable = desc.writable
	int enumerable = desc.enumerable
	int configurable = desc.configurable
	js_value* value = desc.value
	js_value* getter = desc.getter
	js_value* setter = desc.setter
	if (old != 0):
		if (accessor == 0 && data == 0): accessor = old.accessor
		if ((desc.fields & 1) == 0): enumerable = old.enumerable
		if ((desc.fields & 2) == 0): configurable = old.configurable
		if (accessor == old.accessor):
			if ((desc.fields & 4) == 0): value = old.value
			if ((desc.fields & 8) == 0): writable = old.writable
			if ((desc.fields & 16) == 0): getter = old.getter
			if ((desc.fields & 32) == 0): setter = old.setter
	int ok = js_runtime_define(rt, object, key, value, getter, setter, accessor, writable, enumerable, configurable)
	if (ok && object.kind == 6 && index >= object.array_length): object.array_length = index + 1
	return ok

js_value* js_object_descriptor_value(js_runtime* rt, js_value* object, js_text* key):
	if (js_object_ordinary(rt, object) == 0): return rt.undefined_value
	js_property_descriptor desc
	if (js_object_own_descriptor(rt, object, key, &desc) == 0): return rt.undefined_value
	js_value* result = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	if (desc.fields & 48):
		js_value* getter = rt.undefined_value
		js_value* setter = rt.undefined_value
		if (desc.getter != 0): getter = desc.getter
		if (desc.setter != 0): setter = desc.setter
		js_runtime_set(rt, result, c"get", getter)
		js_runtime_set(rt, result, c"set", setter)
	else:
		js_runtime_set(rt, result, c"value", desc.value)
		js_runtime_set(rt, result, c"writable", js_runtime_boolean(rt, desc.writable))
	js_runtime_set(rt, result, c"enumerable", js_runtime_boolean(rt, desc.enumerable))
	js_runtime_set(rt, result, c"configurable", js_runtime_boolean(rt, desc.configurable))
	return result

# OrdinaryOwnPropertyKeys with Array length after the index keys. Owned keys;
# symbols are included only on request. Charges one step per key.
list[js_text*] js_object_keys(js_runtime* rt, js_value* object, int symbols):
	list[js_text*] keys = new list[js_text*]
	if (js_object_ordinary(rt, object) == 0): return keys
	if (object.kind == 7):
		js_text* prototype = js_runtime_key(c"prototype")
		js_runtime_function_prototype(rt, object, prototype)
		js_text_free(prototype)
	list[js_text*] own = js_runtime_own_keys(object, symbols)
	int placed = object.kind != 6
	for i in range(own.length):
		if (js_runtime_compat_step(rt) == 0): break
		if (placed == 0 && js_runtime_array_index(own[i]) < 0):
			keys.push(js_runtime_key(c"length"))
			placed = 1
		keys.push(js_text_clone(own[i]))
	if (placed == 0 && rt.completion.status == 0): keys.push(js_runtime_key(c"length"))
	js_runtime_free_keys(own)
	return keys

int js_object_define_properties(js_runtime* rt, js_value* object, js_value* properties):
	properties = js_runtime_to_object(rt, properties)
	if (rt.completion.status != 0 || js_object_ordinary(rt, properties) == 0): return 0
	list[js_text*] keys = js_object_keys(rt, properties, 1)
	list[js_property_descriptor*] descriptors = new list[js_property_descriptor*]
	# Conversion is completed for every enumerable descriptor before mutation.
	for i in range(keys.length):
		js_property_descriptor* descriptor = 0
		if (rt.completion.status == 0):
			js_property_descriptor own
			if (js_object_own_descriptor(rt, properties, keys[i], &own) && own.enumerable):
				descriptor = new js_property_descriptor()
				js_value* source = js_runtime_member_read(rt, properties, keys[i])
				if (rt.completion.status == 0): js_object_descriptor_read(rt, source, descriptor)
		descriptors.push(descriptor)
	for i in range(keys.length):
		js_property_descriptor* descriptor = descriptors[i]
		if (rt.completion.status == 0 && descriptor != 0):
			if (js_object_descriptor_apply(rt, object, keys[i], descriptor) == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"property definition rejected")
		if (descriptor != 0): free(descriptor)
	__w_list_free(cast(__w_list*, descriptors))
	js_runtime_free_keys(keys)
	return rt.completion.status == 0

# [[Get]] with an explicit receiver, covering virtual Array length and
# String wrapper indices.
js_value* js_object_get(js_runtime* rt, js_value* object, js_text* key, js_value* receiver):
	if (receiver == object): return js_runtime_member_read(rt, object, key)
	if (object.kind == 6 && js_runtime_key_is(key, c"length")): return js_runtime_number(rt, cast(float64, object.array_length))
	return js_runtime_read_receiver(rt, object, key, receiver)

int js_object_set(js_runtime* rt, js_value* object, js_text* key, js_value* value, js_value* receiver):
	if (receiver == object): return js_runtime_member_write(rt, object, key, value)
	if (js_runtime_object(receiver) == 0 || receiver.owner != rt): return 0
	if (receiver.kind == 6 && js_runtime_key_is(key, c"length")):
		# The setter chain is consulted first; only an Array receiver resizes.
		if (object.kind == 6 && object.length_readonly): return 0
		return js_runtime_member_write(rt, receiver, key, value)
	int index = js_runtime_array_index(key)
	if (receiver.kind == 6 && index >= receiver.array_length && receiver.length_readonly): return 0
	int ok = js_runtime_write_receiver(rt, object, key, value, receiver)
	if (ok && receiver.kind == 6 && index >= receiver.array_length): receiver.array_length = index + 1
	return ok

js_value* js_object_constructor_value(js_runtime* rt, js_value* value):
	if (value.kind == 0 || value.kind == 1): return js_runtime_alloc(rt, 5)
	return js_runtime_to_object(rt, value)

# Codes 1 create, 2 defineProperty, 3 defineProperties, 4 descriptor,
# 5 keys, 6 names, 7 getPrototypeOf, 8 setPrototypeOf, 9 is, 10 hasOwn,
# 11 preventExtensions, 12 isExtensible, 13 get, 14 set, 15 delete, 16 has.
# Reflect shares the algorithms with codes +20; unlike Object, unsuccessful
# internal writes return false. Code 26 is Reflect.ownKeys (symbols included).
js_value* js_object_static(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int code = cast(int, context)
	int reflect = code >= 20
	if (reflect): code = code - 20
	js_value* object = js_object_argument(rt, args, 0)
	js_value* second = js_object_argument(rt, args, 1)
	js_value* third = js_object_argument(rt, args, 2)
	if (code == 9): return js_runtime_boolean(rt, js_runtime_same_value(object, second))
	if (code == 1):
		if (object.kind != 1 && js_runtime_object(object) == 0):
			js_runtime_fail(rt, 2, c"Object.create prototype must be an object or null")
			return rt.undefined_value
		js_value* result = js_runtime_alloc(rt, 5)
		if (rt.completion.status != 0): return rt.undefined_value
		result.prototype = 0
		if (object.kind != 1): result.prototype = object
		if (second.kind != 0): js_object_define_properties(rt, result, second)
		return result
	if (reflect == 0 && code == 7):
		if (object.kind == 0 || object.kind == 1):
			js_runtime_fail(rt, 2, c"Object.getPrototypeOf called on null or undefined")
			return rt.undefined_value
		js_value* prototype = js_runtime_lookup_prototype(rt, object)
		if (prototype == 0 && object.kind == 10):
			js_runtime_fail(rt, 6, c"BigInt prototype is outside the runtime subset")
			return rt.undefined_value
		if (prototype != 0): return prototype
		return js_runtime_alloc(rt, 1)
	if (reflect == 0 && (code == 4 || code == 5 || code == 6 || code == 10)):
		object = js_runtime_to_object(rt, object)
		if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_object(object) == 0):
		if (reflect == 0 && code == 8 && object.kind != 0 && object.kind != 1):
			if (second.kind != 1 && js_runtime_object(second) == 0): js_runtime_fail(rt, 2, c"prototype must be an object or null")
			return object
		if (reflect == 0 && code == 12): return js_runtime_boolean(rt, 0)
		if (reflect == 0 && code == 11): return object
		js_runtime_fail(rt, 2, c"reflection requires an object")
		return rt.undefined_value
	if (code == 7):
		if (object.prototype != 0): return object.prototype
		return js_runtime_alloc(rt, 1)
	if (code == 8):
		if (second.kind != 1 && js_runtime_object(second) == 0):
			js_runtime_fail(rt, 2, c"prototype must be an object or null")
			return rt.undefined_value
		js_value* prototype = 0
		if (second.kind != 1): prototype = second
		int success = js_runtime_set_prototype(rt, object, prototype)
		if (rt.completion.status != 0): return rt.undefined_value
		if (reflect): return js_runtime_boolean(rt, success)
		if (success == 0): js_runtime_fail(rt, 2, c"prototype change rejected")
		return object
	if (code == 11 || code == 12):
		if (js_object_ordinary(rt, object) == 0): return rt.undefined_value
		if (code == 12): return js_runtime_boolean(rt, object.non_extensible == 0)
		object.non_extensible = 1
		if (reflect): return js_runtime_boolean(rt, 1)
		return object
	if (code == 3):
		js_object_define_properties(rt, object, second)
		return object
	if (code == 5 || code == 6):
		int symbols = reflect != 0 && code == 6
		list[js_text*] keys = js_object_keys(rt, object, symbols)
		js_value* result = js_runtime_alloc(rt, 6)
		for i in range(keys.length):
			if (rt.completion.status != 0): break
			js_property_descriptor own
			if (code == 6 || (js_object_own_descriptor(rt, object, keys[i], &own) && own.enumerable)): js_runtime_array_append(rt, result, js_object_key_value(rt, keys[i]))
		js_runtime_free_keys(keys)
		if (rt.completion.status != 0): return rt.undefined_value
		return result
	js_text* key = js_runtime_property_key(rt, second)
	if (key == 0): return rt.undefined_value
	js_value* result = rt.undefined_value
	if (code == 2):
		js_property_descriptor descriptor
		if (js_object_descriptor_read(rt, third, &descriptor)):
			int success = js_object_descriptor_apply(rt, object, key, &descriptor)
			if (reflect): result = js_runtime_boolean(rt, success)
			else:
				if (success == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"property definition rejected")
				result = object
	else if (code == 4): result = js_object_descriptor_value(rt, object, key)
	else if (code == 10):
		if (js_object_ordinary(rt, object)):
			js_property_descriptor own
			result = js_runtime_boolean(rt, js_object_own_descriptor(rt, object, key, &own))
	else if (code == 13):
		js_value* target = object
		if (args.length > 2): target = third
		result = js_object_get(rt, object, key, target)
	else if (code == 14):
		js_value* target = object
		if (args.length > 3): target = args[3]
		result = js_runtime_boolean(rt, js_object_set(rt, object, key, third, target))
	else if (code == 15):
		if (js_object_ordinary(rt, object)): result = js_runtime_boolean(rt, js_runtime_delete_property(rt, object, key))
	else if (code == 16): result = js_runtime_boolean(rt, js_object_has(rt, object, key))
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	return result

# HasProperty along the prototype chain: depth bounded and charged per step.
int js_object_has(js_runtime* rt, js_value* object, js_text* key):
	js_value* current = object
	int depth = 0
	while (current != 0):
		if (depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
			if (rt.completion.status == 0): js_runtime_fail(rt, 5, c"JavaScript property presence depth limit")
			return 0
		depth = depth + 1
		if (current.host_get != 0 || current.host_set != 0 || current.binary_kind != 0):
			js_runtime_fail(rt, 6, c"native property presence requires a reflection hook")
			return 0
		js_property_descriptor own
		if (js_object_own_descriptor(rt, current, key, &own)): return 1
		if (rt.completion.status != 0): return 0
		current = current.prototype
	return 0

js_value* js_object_prototype_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int code = cast(int, context)
	if (code == 1): return js_runtime_to_object(rt, receiver)
	if (code == 2):
		if (receiver.kind == 0): return js_runtime_string_value(rt, c"[object Undefined]")
		if (receiver.kind == 1): return js_runtime_string_value(rt, c"[object Null]")
		js_value* object = js_runtime_to_object(rt, receiver)
		if (rt.completion.status != 0): return rt.undefined_value
		char* name = c"Object"
		if (object.kind == 6): name = c"Array"
		if (js_runtime_callable(object)): name = c"Function"
		if (object.builtin_state == 1): name = c"String"
		if (object.builtin_state == 3): name = c"Number"
		if (object.builtin_state == 5): name = c"Boolean"
		if (object.regexp != 0): name = c"RegExp"
		if (object.intrinsic_error_name[0] != 0 || (object.prototype != 0 && rt.error_prototypes.length > 0 && object.prototype == rt.error_prototypes[0])): name = c"Error"
		js_text* text = js_runtime_key(c"[object ")
		js_text* tag_key = js_symbol_key(JS_SYMBOL_TO_STRING_TAG)
		js_value* tag = js_runtime_member_read(rt, object, tag_key)
		js_text_free(tag_key)
		if (rt.completion.status != 0):
			js_text_free(text)
			return rt.undefined_value
		if (tag.kind == 4):
			for int unit in tag.text.units: text.units.push(unit)
		else:
			for i in range(strlen(name)): text.units.push(name[i])
		text.units.push(']')
		js_value* result = js_runtime_string(rt, text)
		js_text_free(text)
		return result
	if (code == 5):
		js_value* object = js_object_argument(rt, args, 0)
		if (js_runtime_object(object) == 0): return js_runtime_boolean(rt, 0)
		receiver = js_runtime_to_object(rt, receiver)
		if (rt.completion.status != 0): return rt.undefined_value
		object = object.prototype
		int depth = 0
		while (object != 0):
			if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
			if (object == receiver): return js_runtime_boolean(rt, 1)
			depth = depth + 1
			if (depth >= rt.max_depth):
				js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
				return rt.undefined_value
			object = object.prototype
		return js_runtime_boolean(rt, 0)
	# Both methods perform ToPropertyKey before ToObject(this).
	js_text* key = js_runtime_property_key(rt, js_object_argument(rt, args, 0))
	if (key == 0): return rt.undefined_value
	receiver = js_runtime_to_object(rt, receiver)
	if (rt.completion.status != 0 || js_object_ordinary(rt, receiver) == 0):
		js_text_free(key)
		return rt.undefined_value
	js_property_descriptor own
	int result = js_object_own_descriptor(rt, receiver, key, &own)
	if (code == 4): result = result && own.enumerable
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_boolean(rt, result)

void js_object_method(js_runtime* rt, js_value* object, char* name, js_host_receiver_function* callback, int code, int length):
	js_value* method = js_runtime_host_callable(rt, cast(void*, code), callback)
	js_object_define_named(rt, method, c"name", js_runtime_string_value(rt, name), 0, 1)
	js_object_define_named(rt, method, c"length", js_runtime_number(rt, cast(float64, length)), 0, 1)
	js_object_define_named(rt, object, name, method, 1, 1)

# toString placeholders that keep ToPrimitive results stable now that
# Object.prototype.toString exists: Array.prototype.toString joins, and
# Function.prototype.toString stays unsupported (source text is not retained).
# The Array and Function clusters replace them with their own methods.
js_value* js_object_intrinsic_text(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (cast(int, context) == 1 && receiver.kind == 6):
		js_text* joined = js_runtime_array_join(rt, receiver)
		if (joined == 0): return rt.undefined_value
		js_value* value = js_runtime_string(rt, joined)
		js_text_free(joined)
		return value
	if (cast(int, context) == 2 && js_runtime_callable(receiver)):
		js_runtime_fail(rt, 6, c"function source text conversion is outside the runtime subset")
		return rt.undefined_value
	js_runtime_fail(rt, 2, c"toString called on an incompatible receiver")
	return rt.undefined_value

void js_object_install_intrinsic_text(js_runtime* rt, js_value* holder, int code):
	js_text* key = js_runtime_key(c"toString")
	if (holder != 0 && js_runtime_property(holder, key) == 0): js_object_method(rt, holder, c"toString", js_object_intrinsic_text, code, 0)
	js_text_free(key)

# Object.prototype did not exist before the object cluster: every ordinary
# object allocated earlier (built-in prototypes, namespaces, the global
# object) adopts it now, and runtime.w's allocator uses it from here on.
void js_object_install_prototype(js_runtime* rt):
	js_value* prototype = js_runtime_alloc(rt, 5)
	if (prototype == rt.undefined_value): return
	rt.object_prototype = prototype
	for js_value* candidate in rt.heap:
		if (candidate.kind == 5 && candidate.prototype == 0 && candidate != prototype): candidate.prototype = prototype

void js_object_install(js_runtime* rt):
	js_value* constructor = js_runtime_get(rt, rt.global_object, c"Object")
	if (js_runtime_object(constructor) == 0): return
	js_object_install_prototype(rt)
	js_value* prototype = rt.object_prototype
	if (prototype == 0): return
	constructor.host_construct = 1
	js_object_define_named(rt, constructor, c"name", js_runtime_string_value(rt, c"Object"), 0, 1)
	js_object_define_named(rt, constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_object_define_named(rt, constructor, c"prototype", prototype, 0, 0)
	js_object_define_named(rt, prototype, c"constructor", constructor, 1, 1)
	js_object_method(rt, prototype, c"valueOf", js_object_prototype_method, 1, 0)
	js_object_method(rt, prototype, c"toString", js_object_prototype_method, 2, 0)
	js_object_method(rt, prototype, c"hasOwnProperty", js_object_prototype_method, 3, 1)
	js_object_method(rt, prototype, c"propertyIsEnumerable", js_object_prototype_method, 4, 1)
	js_object_method(rt, prototype, c"isPrototypeOf", js_object_prototype_method, 5, 1)
	js_object_install_intrinsic_text(rt, rt.array_prototype, 1)
	js_object_install_intrinsic_text(rt, rt.function_prototype, 2)
	js_value* reflect = js_runtime_alloc(rt, 5)
	for i in range(1, 17):
		char* name = c"create"
		if (i == 2): name = c"defineProperty"
		if (i == 3): name = c"defineProperties"
		if (i == 4): name = c"getOwnPropertyDescriptor"
		if (i == 5): name = c"keys"
		if (i == 6): name = c"getOwnPropertyNames"
		if (i == 7): name = c"getPrototypeOf"
		if (i == 8): name = c"setPrototypeOf"
		if (i == 9): name = c"is"
		if (i == 10): name = c"hasOwn"
		if (i == 11): name = c"preventExtensions"
		if (i == 12): name = c"isExtensible"
		if (i == 13): name = c"get"
		if (i == 14): name = c"set"
		if (i == 15): name = c"deleteProperty"
		if (i == 16): name = c"has"
		int length = 2
		if (i == 2 || i == 14): length = 3
		if (i == 5 || i == 6 || i == 7 || i == 11 || i == 12): length = 1
		if (i <= 12): js_object_method(rt, constructor, name, js_object_static, i, length)
		if (i == 2 || i == 4 || i == 7 || i == 8 || i >= 11): js_object_method(rt, reflect, name, js_object_static, i + 20, length)
	js_object_method(rt, reflect, c"ownKeys", js_object_static, 26, 1)
	js_runtime_set(rt, rt.global, c"Reflect", reflect)
