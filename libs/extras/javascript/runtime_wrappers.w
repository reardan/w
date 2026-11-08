# Primitive wrapper objects (reardan/w#907; ECMA-262 2020 sec-toobject,
# sec-number-objects, sec-boolean-objects): ToObject, the Number and Boolean
# constructors and prototypes, Object(value) for every primitive, and the
# global isNaN/isFinite. A Number or Boolean wrapper keeps its primitive in
# number with builtin_state JS_BRAND_NUMBER or JS_BRAND_BOOLEAN; String
# wrappers (JS_BRAND_STRING, runtime_constructors.w) keep their text.
# Number.prototype and Boolean.prototype are themselves wrappers of +0 and
# false. Imported by runtime.w after its core.
import libs.extras.javascript.runtime


void js_runtime_install_eval(js_runtime* rt);


const int JS_BRAND_NUMBER = 3
const int JS_BRAND_BOOLEAN = 5
const int JS_BRAND_SYMBOL = 7


js_value* js_runtime_wrapper(js_runtime* rt, js_value* prototype, int brand, js_value* primitive):
	js_value* wrapper = js_runtime_alloc(rt, 5)
	if (wrapper == rt.undefined_value): return wrapper
	wrapper.prototype = prototype
	wrapper.builtin_state = brand
	wrapper.number = primitive.number
	if (brand == JS_BRAND_SYMBOL): wrapper.this_value = primitive
	return wrapper


# ToObject: a TypeError for undefined and null, objects unchanged and a new
# wrapper for every other primitive.
js_value* js_runtime_to_object(js_runtime* rt, js_value* value):
	if (value.kind == 0 || value.kind == 1):
		js_runtime_fail(rt, 2, c"cannot convert undefined or null to object")
		return rt.undefined_value
	if (js_runtime_object(value)): return value
	if (value.kind == 3): return js_runtime_wrapper(rt, rt.number_prototype, JS_BRAND_NUMBER, value)
	if (value.kind == 2): return js_runtime_wrapper(rt, rt.boolean_prototype, JS_BRAND_BOOLEAN, value)
	if (value.kind == 11): return js_runtime_wrapper(rt, rt.symbol_prototype, JS_BRAND_SYMBOL, value)
	if (value.kind == 4):
		list[js_value*] wrapped = new list[js_value*]
		wrapped.push(value)
		js_value* wrapper = js_runtime_construct(rt, rt.string_constructor, wrapped, rt.string_constructor)
		__w_list_free(cast(__w_list*, wrapped))
		return wrapper
	js_runtime_fail(rt, 6, c"BigInt wrapper objects are outside the runtime subset")
	return rt.undefined_value


# Number(value) is ToNumber (+0 without an argument); new Number(value)
# wraps it.
js_value* js_number_function(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int constructing = rt.new_target != 0
	rt.new_target = 0
	float64 number = 0.0
	if (args.length > 0):
		if (args[0].kind == 10): number = cast(float64, args[0].bigint_bits)
		else: number = js_runtime_to_number(rt, args[0])
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* primitive = js_runtime_number(rt, number)
	if (constructing): return js_runtime_wrapper(rt, rt.number_prototype, JS_BRAND_NUMBER, primitive)
	return primitive


js_value* js_boolean_function(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int constructing = rt.new_target != 0
	rt.new_target = 0
	int truth = args.length > 0 && js_runtime_truth(args[0])
	js_value* primitive = js_runtime_boolean(rt, truth)
	if (constructing): return js_runtime_wrapper(rt, rt.boolean_prototype, JS_BRAND_BOOLEAN, primitive)
	return primitive


# thisNumberValue / thisBooleanValue: the primitive, or 0 after a TypeError.
js_value* js_runtime_this_primitive(js_runtime* rt, js_value* receiver, int kind, int brand, char* message):
	if (receiver.kind == kind): return receiver
	if (js_runtime_object(receiver) && receiver.builtin_state == brand):
		if (kind == 3): return js_runtime_number(rt, receiver.number)
		return js_runtime_boolean(rt, receiver.number != 0.0)
	js_runtime_fail(rt, 2, message)
	return 0


char js_runtime_radix_digit(int digit):
	if (digit < 10): return cast(char, '0' + digit)
	return cast(char, 'a' + digit - 10)


# Number::toString(x) in a radix other than 10: the integer digits exactly,
# then fraction digits until the remainder vanishes (at most 52 digits).
js_text* js_runtime_radix_text(float64 number, int radix):
	if (f64is_nan(number) || number == 0.0 || fabs64(number) == float64_from_bits(0x7ff << 52)):
		char* text = js_runtime_number_text(number)
		js_text* result = js_runtime_key(text)
		free(text)
		return result
	int negative = number < 0.0
	float64 value = fabs64(number)
	float64 whole = ffloor64(value)
	float64 fraction = value - whole
	float64 base = cast(float64, radix)
	list[int] digits = new list[int]
	if (whole == 0.0): digits.push('0')
	while (whole > 0.0):
		float64 digit = fmod64(whole, base)
		digits.push(js_runtime_radix_digit(cast(int, digit)))
		whole = ffloor64(whole / base)
	js_text* result = js_text_new()
	if (negative): result.units.push('-')
	for i in range(digits.length): result.units.push(digits[digits.length - 1 - i])
	__w_list_free(cast(__w_list*, digits))
	if (fraction > 0.0):
		result.units.push('.')
		int count = 0
		while (fraction > 0.0 && count < 52):
			fraction = fraction * base
			float64 digit = ffloor64(fraction)
			result.units.push(js_runtime_radix_digit(cast(int, digit)))
			fraction = fraction - digit
			count = count + 1
	return result


# Number.prototype methods: 0 valueOf, 1 toString(radix), 2 toLocaleString.
js_value* js_number_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	js_value* primitive = js_runtime_this_primitive(rt, receiver, 3, JS_BRAND_NUMBER, c"Number.prototype method requires a number")
	if (primitive == 0 || operation == 0): return primitive
	int radix = 10
	if (operation == 1 && args.length > 0 && args[0].kind != 0):
		float64 requested = js_runtime_to_integer(rt, args[0])
		if (rt.completion.status != 0): return rt.undefined_value
		if (requested < 2.0 || requested > 36.0):
			js_bigint_error(rt, c"RangeError", c"toString radix must be between 2 and 36")
			if (rt.completion.value != rt.undefined_value): rt.completion.value.prototype = js_runtime_error_prototype(rt, c"RangeError")
			return rt.undefined_value
		radix = cast(int, requested)
	js_text* text = 0
	if (radix == 10):
		char* raw = js_runtime_number_text(primitive.number)
		text = js_runtime_key(raw)
		free(raw)
	else: text = js_runtime_radix_text(primitive.number, radix)
	js_value* result = js_runtime_string(rt, text)
	js_text_free(text)
	return result


# Boolean.prototype methods: 0 valueOf, 1 toString.
js_value* js_boolean_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* primitive = js_runtime_this_primitive(rt, receiver, 2, JS_BRAND_BOOLEAN, c"Boolean.prototype method requires a boolean")
	if (primitive == 0 || cast(int, context) == 0): return primitive
	if (js_runtime_truth(primitive)): return js_runtime_string_value(rt, c"true")
	return js_runtime_string_value(rt, c"false")


# Global isNaN (0) and isFinite (1) apply ToNumber first.
js_value* js_global_number_test(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	float64 number = float64_from_bits((0x7ff << 52) | 1)
	if (args.length > 0): number = js_runtime_to_number(rt, args[0])
	if (rt.completion.status != 0): return rt.undefined_value
	if (cast(int, context) == 0): return js_runtime_boolean(rt, f64is_nan(number))
	return js_runtime_boolean(rt, js_builtin_finite(number))


void js_runtime_constructor_link(js_runtime* rt, js_value* constructor, js_value* prototype, char* name):
	constructor.host_construct = 1
	js_text* key = js_runtime_key(c"prototype")
	js_runtime_define_data(rt, constructor, key, prototype, 0, 0, 0)
	js_text_free(key)
	key = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, prototype, key, constructor, 1, 0, 1)
	js_text_free(key)
	key = js_runtime_key(c"name")
	js_runtime_define_data(rt, constructor, key, js_runtime_string_value(rt, name), 0, 0, 1)
	js_text_free(key)
	key = js_runtime_key(c"length")
	js_runtime_define_data(rt, constructor, key, js_runtime_number(rt, 1.0), 0, 0, 1)
	js_text_free(key)


void js_runtime_install_wrappers(js_runtime* rt):
	js_value* zero = js_runtime_number(rt, 0.0)
	js_value* no = js_runtime_boolean(rt, 0)
	rt.number_prototype = js_runtime_wrapper(rt, 0, JS_BRAND_NUMBER, zero)
	rt.boolean_prototype = js_runtime_wrapper(rt, 0, JS_BRAND_BOOLEAN, no)
	if (rt.completion.status != 0): return
	js_value* number = js_runtime_get(rt, rt.global, c"Number")
	if (number.kind == 9):
		js_runtime_constructor_link(rt, number, rt.number_prototype, c"Number")
		js_builtin_method(rt, rt.number_prototype, c"valueOf", js_number_method, 0)
		js_builtin_method(rt, rt.number_prototype, c"toString", js_number_method, 1)
		js_builtin_method(rt, rt.number_prototype, c"toLocaleString", js_number_method, 2)
		js_builtin_constant(rt, number, c"MAX_VALUE", float64_from_bits((0x7fe << 52) | ((1 << 52) - 1)))
		js_builtin_constant(rt, number, c"MIN_VALUE", float64_from_bits(1))
	js_value* boolean = js_runtime_host_callable(rt, 0, js_boolean_function)
	if (boolean == rt.undefined_value): return
	js_runtime_constructor_link(rt, boolean, rt.boolean_prototype, c"Boolean")
	js_builtin_method(rt, rt.boolean_prototype, c"valueOf", js_boolean_method, 0)
	js_builtin_method(rt, rt.boolean_prototype, c"toString", js_boolean_method, 1)
	js_runtime_set(rt, rt.global, c"Boolean", boolean)
	js_runtime_set(rt, rt.global, c"isNaN", js_runtime_host_callable(rt, 0, js_global_number_test))
	js_runtime_set(rt, rt.global, c"isFinite", js_runtime_host_callable(rt, cast(void*, 1), js_global_number_test))
	# String.prototype is itself a String object whose value is "".
	rt.string_prototype.builtin_state = 1
	js_runtime_install_eval(rt)
	if (rt.string_prototype.text == 0): rt.string_prototype.text = js_text_new()
