# Bounded Array constructor, Array.isArray, Array[@@species] and
# ArraySpeciesCreate.
# https://tc39.es/ecma262/#sec-array-constructor
# https://tc39.es/ecma262/#sec-arrayspeciescreate
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_array_like


js_value* js_ap_construct(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	rt.new_target = 0
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	int length = args.length
	int holes = args.length == 1 && args[0].kind == 3
	if (holes):
		float64 number = args[0].number
		if (js_builtin_finite(number) == 0 || number < 0.0 || number > 4294967295.0 || js_builtin_trunc(number) != number):
			js_bigint_error(rt, c"RangeError", c"invalid Array length")
			return rt.undefined_value
		if (number > cast(float64, rt.max_properties)):
			js_runtime_fail(rt, 5, c"Array length exceeds runtime limit")
			return rt.undefined_value
		length = cast(int, number)
	js_value* array = js_ap_array_new(rt, length)
	if (rt.completion.status != 0): return rt.undefined_value
	if (holes == 0):
		for i in range(args.length):
			if (js_runtime_compat_step(rt) == 0): break
			if (js_ap_create(rt, array, i, args[i]) == 0): break
	if (rt.completion.status != 0): return rt.undefined_value
	return array


js_value* js_ap_is_array(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	return js_runtime_boolean(rt, args.length > 0 && args[0].kind == 6)


# get Array[@@species] returns the receiver.
js_value* js_ap_species_getter(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	return receiver


# Non-arrays always create plain arrays. For an array receiver the constructor
# is read, then its @@species; the intrinsic Array constructor is recognised
# and bypassed (it would only build a plain array of the same length).
js_value* js_ap_species_create(js_runtime* rt, js_value* original, int length):
	if (original.kind != 6): return js_ap_array_new(rt, length)
	js_value* constructor = js_runtime_get(rt, original, c"constructor")
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_object(constructor)):
		js_text* key = js_symbol_key(JS_SYMBOL_SPECIES)
		constructor = js_runtime_member_read(rt, constructor, key)
		js_text_free(key)
		if (rt.completion.status != 0): return rt.undefined_value
		if (constructor.kind == 1): constructor = rt.undefined_value
	if (constructor.kind == 0): return js_ap_array_new(rt, length)
	if (js_runtime_is_constructor(rt, constructor) == 0):
		js_runtime_fail(rt, 2, c"array species constructor is not a constructor")
		return rt.undefined_value
	js_host_receiver_function* intrinsic = js_ap_construct
	if (constructor.kind == 9 && constructor.host == cast(int, intrinsic)): return js_ap_array_new(rt, length)
	list[js_value*] arguments = new list[js_value*]
	arguments.push(js_runtime_number(rt, cast(float64, length)))
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_construct(rt, constructor, arguments, constructor)
	__w_list_free(cast(__w_list*, arguments))
	if (rt.completion.status != 0): return rt.undefined_value
	return result


void js_ap_install_constructor(js_runtime* rt):
	js_value* constructor = js_runtime_host_callable(rt, 0, js_ap_construct)
	if (constructor == rt.undefined_value): return
	constructor.host_construct = 1
	js_ap_define(rt, constructor, c"name", js_runtime_string_value(rt, c"Array"), 0, 1)
	js_ap_define(rt, constructor, c"length", js_runtime_number(rt, 1.0), 0, 1)
	js_ap_define(rt, constructor, c"prototype", rt.array_prototype, 0, 0)
	js_ap_define(rt, rt.array_prototype, c"constructor", constructor, 1, 1)
	js_ap_method(rt, constructor, c"isArray", js_ap_is_array, 0, 1)
	js_value* getter = js_runtime_host_callable(rt, 0, js_ap_species_getter)
	js_text* key = js_symbol_key(JS_SYMBOL_SPECIES)
	js_runtime_define_accessor(rt, constructor, key, getter, 0, 0, 1)
	js_text_free(key)
	key = js_runtime_key(c"Array")
	js_runtime_define_data(rt, rt.global_object, key, constructor, 1, 0, 1)
	js_text_free(key)
