# Ordinary object reflection. Symbols and native exotic own-key/descriptor
# hooks remain explicit unsupported operations, never guessed from getters.
import libs.extras.javascript.runtime

struct js_object_descriptor:
	int fields
	js_value* value
	js_value* getter
	js_value* setter
	int writable
	int enumerable
	int configurable

int js_array_length_descriptor(js_runtime* rt, js_value* array, js_object_descriptor* desc);

int js_object_ordinary(js_runtime* rt, js_value* object):
	if (js_runtime_object(object) == 0 || object.owner != rt):
		js_runtime_fail(rt, 2, c"reflection requires an object")
		return 0
	if (object.host_get != 0 || object.host_set != 0 || object.host_has != 0 || object.binary_kind != 0):
		js_runtime_fail(rt, 6, c"native exotic descriptor reflection requires host hooks")
		return 0
	return 1

js_value* js_object_argument(js_runtime* rt, list[js_value*] args, int index):
	if (index < args.length): return args[index]
	return rt.undefined_value

# ToPropertyDescriptor reads inherited fields, in the normative observable
# order. Presence is separate from Get, and absent attributes remain absent.
int js_object_descriptor_read(js_runtime* rt, js_value* source, js_object_descriptor* out):
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
			if (value.kind != 0 && js_function_callable(value) == 0):
				js_runtime_fail(rt, 2, c"descriptor accessor must be callable or undefined")
				return 0
			if (value.kind != 0):
				if (i == 4): out.getter = value
				else: out.setter = value
	if ((out.fields & 48) != 0 && (out.fields & 12) != 0):
		js_runtime_fail(rt, 2, c"descriptor cannot mix accessors and data")
		return 0
	return 1

int js_object_descriptor_apply(js_runtime* rt, js_value* object, js_text* key, js_object_descriptor* desc):
	if (js_object_ordinary(rt, object) == 0): return 0
	if (object.kind == 6 && js_runtime_key_is(key, c"length")): return js_array_length_descriptor(rt, object, desc)
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
			if ((desc.fields & 4) == 0):
				value = old.value
				if (old.mapped_binding != 0): value = old.mapped_binding.value
			if ((desc.fields & 8) == 0): writable = old.writable
			if ((desc.fields & 16) == 0): getter = old.getter
			if ((desc.fields & 32) == 0): setter = old.setter
	return js_runtime_define(rt, object, key, value, getter, setter, accessor, writable, enumerable, configurable)

js_value* js_object_descriptor_value(js_runtime* rt, js_value* object, js_text* key):
	if (js_object_ordinary(rt, object) == 0): return rt.undefined_value
	js_value* prop = js_runtime_property(object, key)
	int length = object.kind == 6 && js_runtime_key_is(key, c"length")
	if (prop == 0 && length == 0): return rt.undefined_value
	js_value* result = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	if (length):
		js_runtime_set(rt, result, c"value", js_runtime_number(rt, cast(float64, object.array_length)))
		js_runtime_set(rt, result, c"writable", js_runtime_boolean(rt, object.array_length_writable))
	else if (prop.accessor):
		js_value* getter = rt.undefined_value
		js_value* setter = rt.undefined_value
		if (prop.getter != 0): getter = prop.getter
		if (prop.setter != 0): setter = prop.setter
		js_runtime_set(rt, result, c"get", getter)
		js_runtime_set(rt, result, c"set", setter)
	else:
		js_value* value = prop.value
		if (prop.mapped_binding != 0): value = prop.mapped_binding.value
		js_runtime_set(rt, result, c"value", value)
		js_runtime_set(rt, result, c"writable", js_runtime_boolean(rt, prop.writable))
	int enumerable = 0
	int configurable = 0
	if (length == 0):
		enumerable = prop.enumerable
		configurable = prop.configurable
	js_runtime_set(rt, result, c"enumerable", js_runtime_boolean(rt, enumerable))
	js_runtime_set(rt, result, c"configurable", js_runtime_boolean(rt, configurable))
	return result

list[js_text*] js_object_keys(js_runtime* rt, js_value* object):
	list[js_text*] keys = new list[js_text*]
	if (js_object_ordinary(rt, object) == 0): return keys
	if (object.kind == 6 && rt.completion.status == 0):
		js_text* key = js_runtime_key(c"length")
		js_for_in_key(rt, keys, key)
		js_text_free(key)
	for i in range(object.properties.length):
		if (rt.completion.status != 0): break
		js_for_in_key(rt, keys, object.properties[i].key)
	return keys

int js_object_define_properties(js_runtime* rt, js_value* object, js_value* properties):
	properties = js_boxed_object(rt, properties)
	if (rt.completion.status != 0 || js_object_ordinary(rt, properties) == 0): return 0
	list[js_text*] keys = js_object_keys(rt, properties)
	list[js_object_descriptor*] descriptors = new list[js_object_descriptor*]
	# Conversion is completed for every enumerable descriptor before mutation.
	for i in range(keys.length):
		js_object_descriptor* descriptor = 0
		if (rt.completion.status == 0):
			js_value* own = js_runtime_property(properties, keys[i])
			if (own != 0 && own.enumerable):
				descriptor = new js_object_descriptor()
				js_value* source = js_runtime_member_read(rt, properties, keys[i])
				if (rt.completion.status == 0): js_object_descriptor_read(rt, source, descriptor)
		descriptors.push(descriptor)
	for i in range(keys.length):
		js_object_descriptor* descriptor = descriptors[i]
		if (rt.completion.status == 0 && descriptor != 0):
			if (js_object_descriptor_apply(rt, object, keys[i], descriptor) == 0): js_runtime_fail(rt, 2, c"property definition rejected")
		if (descriptor != 0): free(descriptor)
	__w_list_free(cast(__w_list*, descriptors))
	js_for_in_keys_free(keys)
	return rt.completion.status == 0

js_value* js_object_constructor(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* value = js_object_argument(rt, args, 0)
	if (value.kind == 0 || value.kind == 1): return js_runtime_alloc(rt, 5)
	return js_boxed_object(rt, value)

# Codes 1 create, 2 defineProperty, 3 defineProperties, 4 descriptor,
# 5 keys, 6 names, 7 getPrototypeOf, 8 setPrototypeOf, 9 is, 10 hasOwn,
# 11 preventExtensions, 12 isExtensible. Reflect shares the algorithms with
# codes +20; unlike Object, unsuccessful internal writes return false.
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
	if (reflect == 0 && (code == 4 || code == 5 || code == 6 || code == 7 || code == 10)):
		object = js_boxed_object(rt, object)
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
		if (reflect): return js_runtime_boolean(rt, success)
		if (success == 0): js_runtime_fail(rt, 2, c"prototype change rejected")
		return object
	if (code == 11 || code == 12):
		if (js_object_ordinary(rt, object) == 0): return rt.undefined_value
		if (code == 12): return js_runtime_boolean(rt, object.extensible)
		object.extensible = 0
		if (reflect): return js_runtime_boolean(rt, 1)
		return object
	if (code == 3):
		js_object_define_properties(rt, object, second)
		return object
	if (code == 5 || code == 6):
		list[js_text*] keys = js_object_keys(rt, object)
		js_value* result = js_runtime_alloc(rt, 6)
		for i in range(keys.length):
			if (rt.completion.status != 0): break
			js_value* own = js_runtime_property(object, keys[i])
			if (code == 6 || (own != 0 && own.enumerable)): js_runtime_array_create_append(rt, result, js_runtime_string(rt, keys[i]))
		js_for_in_keys_free(keys)
		return result
	js_text* key = js_runtime_string_text(rt, second)
	if (key == 0): return rt.undefined_value
	js_value* result = rt.undefined_value
	if (code == 2):
		js_object_descriptor descriptor
		if (js_object_descriptor_read(rt, third, &descriptor)):
			int success = js_object_descriptor_apply(rt, object, key, &descriptor)
			if (reflect): result = js_runtime_boolean(rt, success)
			else:
				if (success == 0): js_runtime_fail(rt, 2, c"property definition rejected")
				result = object
	else if (code == 4): result = js_object_descriptor_value(rt, object, key)
	else if (code == 10):
		if (js_object_ordinary(rt, object)):
			int present = js_runtime_property(object, key) != 0 || (object.kind == 6 && js_runtime_key_is(key, c"length"))
			result = js_runtime_boolean(rt, present)
	else if (code == 13):
		js_value* target = object
		if (args.length > 2): target = third
		result = js_runtime_read_receiver(rt, object, key, target)
	else if (code == 14):
		js_value* target = object
		if (args.length > 3): target = args[3]
		result = js_runtime_boolean(rt, js_runtime_write_receiver(rt, object, key, third, target))
	else if (code == 15):
		if (js_object_ordinary(rt, object)):
			int success = 0
			if (object.kind != 6 || js_runtime_key_is(key, c"length") == 0): success = js_runtime_delete(rt, object, key)
			result = js_runtime_boolean(rt, success)
	else if (code == 16): result = js_runtime_boolean(rt, js_runtime_has_property(rt, object, key))
	js_text_free(key)
	return result

js_value* js_object_prototype_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int code = cast(int, context)
	if (code == 1):
		return js_boxed_object(rt, receiver)
	if (code == 2):
		char* tag = c"[object Object]"
		if (receiver.kind == 0): tag = c"[object Undefined]"
		if (receiver.kind == 1): tag = c"[object Null]"
		if (receiver.kind == 2): tag = c"[object Boolean]"
		if (receiver.kind == 3): tag = c"[object Number]"
		if (receiver.kind == 4): tag = c"[object String]"
		if (receiver.kind == 6): tag = c"[object Array]"
		if (js_function_callable(receiver)): tag = c"[object Function]"
		if (receiver.kind == 10): tag = c"[object BigInt]"
		if (receiver.boxed_value != 0):
			if (receiver.boxed_value.kind == 2): tag = c"[object Boolean]"
			if (receiver.boxed_value.kind == 3): tag = c"[object Number]"
			if (receiver.boxed_value.kind == 4): tag = c"[object String]"
			if (receiver.boxed_value.kind == 10): tag = c"[object BigInt]"
		if (receiver.arguments_object): tag = c"[object Arguments]"
		if (receiver.regexp != 0): tag = c"[object RegExp]"
		if (receiver.intrinsic_error_name[0] != 0): tag = c"[object Error]"
		if (receiver.binary_kind != 0 || receiver.reactions != 0):
			js_runtime_fail(rt, 6, c"exotic Object tag is not implemented")
			return rt.undefined_value
		return js_class_string(rt, tag)
	if (code == 5):
		js_value* object = js_object_argument(rt, args, 0)
		if (js_runtime_object(object) == 0): return js_runtime_boolean(rt, 0)
		receiver = js_boxed_object(rt, receiver)
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
	js_text* key = js_runtime_string_text(rt, js_object_argument(rt, args, 0))
	if (key == 0): return rt.undefined_value
	receiver = js_boxed_object(rt, receiver)
	if (rt.completion.status != 0 || js_object_ordinary(rt, receiver) == 0):
		js_text_free(key)
		return rt.undefined_value
	js_value* own = js_runtime_property(receiver, key)
	int result = own != 0
	if (code == 4): result = own != 0 && own.enumerable
	else if (receiver.kind == 6 && js_runtime_key_is(key, c"length")): result = 1
	js_text_free(key)
	return js_runtime_boolean(rt, result)

void js_object_method(js_runtime* rt, js_value* object, char* name, js_host_receiver_function* callback, int code, int length):
	js_value* method = js_runtime_host_callable(rt, cast(void*, code), callback)
	js_class_define(rt, method, c"name", js_class_string(rt, name), 0, 1)
	js_class_define(rt, method, c"length", js_runtime_number(rt, cast(float64, length)), 0, 1)
	js_class_define(rt, object, name, method, 1, 1)


void js_runtime_install_object(js_runtime* rt):
	js_value* constructor = js_runtime_host_callable(rt, 0, js_object_constructor)
	constructor.host_construct = 1
	js_class_define(rt, constructor, c"name", js_class_string(rt, c"Object"), 0, 1)
	js_class_define(rt, constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, constructor, c"prototype", rt.object_prototype, 0, 0)
	js_class_define(rt, rt.object_prototype, c"constructor", constructor, 1, 1)
	js_object_method(rt, rt.object_prototype, c"valueOf", js_object_prototype_method, 1, 0)
	js_object_method(rt, rt.object_prototype, c"toString", js_object_prototype_method, 2, 0)
	js_object_method(rt, rt.object_prototype, c"hasOwnProperty", js_object_prototype_method, 3, 1)
	js_object_method(rt, rt.object_prototype, c"propertyIsEnumerable", js_object_prototype_method, 4, 1)
	js_object_method(rt, rt.object_prototype, c"isPrototypeOf", js_object_prototype_method, 5, 1)
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
	js_runtime_set(rt, rt.global, c"Object", constructor)
	js_runtime_set(rt, rt.global, c"Reflect", reflect)
