# Primitive wrappers retain a traced immutable primitive slot. String indices
# are real immutable own descriptors, including unpaired UTF-16 surrogates.
import libs.extras.javascript.runtime

js_value* js_boxed_object(js_runtime* rt, js_value* value):
	if (js_runtime_object(value)): return value
	if (value.kind == 0 || value.kind == 1):
		js_runtime_fail(rt, 2, c"cannot convert null or undefined to object")
		return rt.undefined_value
	js_value* object = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	object.boxed_value = value
	if (value.kind == 2): object.prototype = rt.boolean_prototype
	if (value.kind == 3): object.prototype = rt.number_prototype
	if (value.kind == 10): object.prototype = rt.bigint_prototype
	if (value.kind == 4):
		object.prototype = rt.string_prototype
		for i in range(value.text.units.length):
			if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
			char* name = itoa(i)
			js_text* key = js_runtime_key(name)
			free(name)
			js_text* unit = js_text_new()
			unit.units.push(value.text.units[i])
			js_value* letter = js_runtime_string(rt, unit)
			js_text_free(unit)
			js_runtime_define_data(rt, object, key, letter, 0, 1, 0)
			js_text_free(key)
			if (rt.completion.status != 0): return rt.undefined_value
		js_class_define(rt, object, c"length", js_runtime_number(rt, cast(float64, value.text.units.length)), 0, 0)
	return object

js_value* js_boxed_primitive(js_runtime* rt, int kind, list[js_value*] args):
	js_value* value = js_object_argument(rt, args, 0)
	if (kind == 2): return js_runtime_boolean(rt, js_runtime_truth(value))
	if (kind == 3):
		if (args.length == 0): return js_runtime_number(rt, 0.0)
		value = js_numeric_value(rt, value)
		if (rt.completion.status != 0): return rt.undefined_value
		if (value.kind == 10):
			float64 number = cast(float64, value.bigint_bits)
			if (value.bigint_unsigned): number = cast(float64, value.bigint_bits & ~(1 << 63)) + 9223372036854775808.0
			return js_runtime_number(rt, number)
		return value
	if (kind == 4):
		js_text* text = 0
		if (args.length == 0): text = js_text_new()
		else: text = js_runtime_string_text(rt, value)
		if (text == 0): return rt.undefined_value
		js_value* result = js_runtime_string(rt, text)
		js_text_free(text)
		return result
	js_runtime_fail(rt, 2, c"unknown wrapper constructor")
	return rt.undefined_value

js_value* js_boxed_call(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	return js_boxed_primitive(rt, cast(int, context), args)

js_value* js_boxed_construct(js_runtime* rt, int kind, list[js_value*] args):
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* primitive = js_boxed_primitive(rt, kind, args)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_boxed_object(rt, primitive)

# code low nibble is the primitive brand; bit 16 selects toString.
js_value* js_boxed_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int code = cast(int, context)
	int kind = code & 15
	js_value* value = receiver
	if (value.boxed_value != 0): value = value.boxed_value
	if (value.kind != kind):
		js_runtime_fail(rt, 2, c"incompatible primitive wrapper receiver")
		return rt.undefined_value
	if ((code & 16) == 0): return value
	if ((kind == 3 || kind == 10) && args.length > 0 && args[0].kind != 0):
		js_value* radix = js_numeric_value(rt, args[0])
		if (rt.completion.status != 0): return rt.undefined_value
		if (radix.kind != 3):
			js_runtime_fail(rt, 2, c"radix cannot be BigInt")
			return rt.undefined_value
		float64 number = js_builtin_trunc(radix.number)
		if (f64is_nan(number) || number < 2.0 || number > 36.0):
			js_bigint_error(rt, c"RangeError", c"radix must be from 2 to 36")
			return rt.undefined_value
		if (number != 10.0):
			js_runtime_fail(rt, 6, c"nondecimal wrapper formatting is not implemented")
			return rt.undefined_value
	js_text* text = js_runtime_primitive_text(rt, value)
	if (text == 0): return rt.undefined_value
	js_value* result = js_runtime_string(rt, text)
	js_text_free(text)
	return result

void js_boxed_methods(js_runtime* rt, js_value* prototype, int kind):
	js_object_method(rt, prototype, c"valueOf", js_boxed_method, kind, 0)
	int length = 0
	if (kind == 3 || kind == 10): length = 1
	js_object_method(rt, prototype, c"toString", js_boxed_method, kind | 16, length)

void js_runtime_install_boxed(js_runtime* rt):
	rt.boolean_prototype = js_runtime_alloc(rt, 5)
	rt.boolean_prototype.boxed_value = js_runtime_boolean(rt, 0)
	rt.number_prototype = js_runtime_alloc(rt, 5)
	rt.number_prototype.boxed_value = js_runtime_number(rt, 0.0)
	rt.bigint_prototype = js_runtime_alloc(rt, 5)
	# BigInt.prototype has no BigIntData slot.
	rt.string_prototype.boxed_value = js_class_string(rt, c"")
	js_class_define(rt, rt.string_prototype, c"length", js_runtime_number(rt, 0.0), 0, 0)
	js_boxed_methods(rt, rt.boolean_prototype, 2)
	js_boxed_methods(rt, rt.number_prototype, 3)
	js_boxed_methods(rt, rt.string_prototype, 4)
	js_boxed_methods(rt, rt.bigint_prototype, 10)
	js_value* old_number = js_runtime_get(rt, rt.global, c"Number")
	js_value* number = js_runtime_host_callable(rt, cast(void*, 3), js_boxed_call)
	number.host_construct = 1
	number.boxed_constructor = 3
	for i in range(old_number.properties.length):
		js_value* prop = old_number.properties[i]
		js_runtime_define_data(rt, number, prop.key, prop.value, prop.writable, prop.enumerable, prop.configurable)
	js_class_define(rt, number, c"name", js_class_string(rt, c"Number"), 0, 1)
	js_class_define(rt, number, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, number, c"prototype", rt.number_prototype, 0, 0)
	js_class_define(rt, rt.number_prototype, c"constructor", number, 1, 1)
	js_runtime_set(rt, rt.global, c"Number", number)
	js_value* boolean = js_runtime_host_callable(rt, cast(void*, 2), js_boxed_call)
	boolean.host_construct = 1
	boolean.boxed_constructor = 2
	js_class_define(rt, boolean, c"name", js_class_string(rt, c"Boolean"), 0, 1)
	js_class_define(rt, boolean, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_class_define(rt, boolean, c"prototype", rt.boolean_prototype, 0, 0)
	js_class_define(rt, rt.boolean_prototype, c"constructor", boolean, 1, 1)
	js_runtime_set(rt, rt.global, c"Boolean", boolean)
	js_value* string_constructor = js_runtime_get(rt, rt.global, c"String")
	string_constructor.host_construct = 1
	string_constructor.boxed_constructor = 4
	js_class_define(rt, string_constructor, c"name", js_class_string(rt, c"String"), 0, 1)
	js_class_define(rt, string_constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_value* bigint = js_runtime_get(rt, rt.global, c"BigInt")
	js_class_define(rt, bigint, c"prototype", rt.bigint_prototype, 0, 0)
	js_class_define(rt, rt.bigint_prototype, c"constructor", bigint, 1, 1)
