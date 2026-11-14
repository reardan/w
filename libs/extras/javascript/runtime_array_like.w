# Generic bounded array-like operations shared by the Array.prototype methods.
# Every element access is an ordinary Get/Has/Set/Delete through the runtime's
# property hooks, so inherited and native-hook values behave as for any object.
# Native work is charged to the active evaluation budget.
# https://tc39.es/ecma262/#sec-lengthofarraylike
import libs.extras.javascript.runtime


js_text* js_ap_index_key(int index):
	char* raw = itoa(index)
	js_text* key = js_runtime_key(raw)
	free(raw)
	return key


# Charges native text/element work beyond the per-iteration step.
int js_ap_charge(js_runtime* rt, int units):
	if (rt.completion.status != 0): return 0
	if (units > rt.max_properties || units > rt.remaining):
		js_runtime_fail(rt, 5, c"JavaScript array operation work limit")
		return 0
	rt.remaining = rt.remaining - units
	rt.completion.steps = rt.completion.steps + units
	return 1


# Host-to-host recursion (a callback that is itself a native method) has no
# evaluator frame, so native entry points that call back take a depth slot.
int js_ap_enter(js_runtime* rt):
	if (rt.depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
		js_runtime_fail(rt, 5, c"JavaScript array method depth limit")
		return 0
	rt.depth = rt.depth + 1
	return 1


void js_ap_leave(js_runtime* rt):
	rt.depth = rt.depth - 1


void js_ap_define(js_runtime* rt, js_value* object, char* name, js_value* value, int writable, int configurable):
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, object, key, value, writable, 0, configurable)
	js_text_free(key)


# A shared, non-enumerable native method with its name and length properties.
void js_ap_method(js_runtime* rt, js_value* target, char* name, js_host_receiver_function* callback, int code, int length):
	js_value* method = js_runtime_host_callable(rt, cast(void*, code), callback)
	if (rt.completion.status != 0): return
	js_ap_define(rt, method, c"name", js_runtime_string_value(rt, name), 0, 1)
	js_ap_define(rt, method, c"length", js_runtime_number(rt, cast(float64, length)), 0, 1)
	js_ap_define(rt, target, name, method, 1, 1)


# Argument-count charge plus an ownership check: values of another runtime
# must never be stored into this heap.
int js_ap_arguments(js_runtime* rt, list[js_value*] args):
	if (js_builtin_arguments(rt, args) == 0): return 0
	for i in range(args.length):
		if (args[i] == 0 || args[i].owner != rt):
			js_runtime_fail(rt, 2, c"array method argument belongs to another runtime")
			return 0
	return 1


# ToObject(this); a receiver from another runtime is rejected.
js_value* js_ap_object(js_runtime* rt, js_value* receiver):
	if (receiver == 0 || receiver.owner != rt):
		js_runtime_fail(rt, 2, c"array method receiver belongs to another runtime")
		return rt.undefined_value
	return js_runtime_to_object(rt, receiver)


js_value* js_ap_array_new(js_runtime* rt, int length):
	js_value* array = js_runtime_alloc(rt, 6)
	if (rt.completion.status != 0): return rt.undefined_value
	array.array_length = length
	return array


# LengthOfArrayLike, bounded by the runtime's property limit.
int js_ap_length(js_runtime* rt, js_value* object):
	js_value* value = js_runtime_get(rt, object, c"length")
	if (rt.completion.status != 0): return 0
	int length = js_runtime_to_length(rt, value)
	if (rt.completion.status != 0): return 0
	if (length > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript array-like length limit")
		return 0
	return length


# HasProperty(O, ToString(index)); a getter is never invoked. String wrapper
# indices are virtual, so they are reported present here.
int js_ap_has(js_runtime* rt, js_value* object, int index):
	if (object.builtin_state == 1 && index < object.text.units.length): return 1
	js_text* key = js_ap_index_key(index)
	int present = js_runtime_has_property(rt, object, key)
	js_text_free(key)
	return present


js_value* js_ap_get(js_runtime* rt, js_value* object, int index):
	return js_runtime_index_get(rt, object, index)


# Set(O, index, value, true).
int js_ap_set(js_runtime* rt, js_value* object, int index, js_value* value):
	if (rt.completion.status != 0): return 0
	js_text* key = js_ap_index_key(index)
	int ok = js_runtime_member_write(rt, object, key, value)
	js_text_free(key)
	if (ok == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"array element write rejected")
	return rt.completion.status == 0


# DeletePropertyOrThrow(O, index).
int js_ap_delete(js_runtime* rt, js_value* object, int index):
	if (rt.completion.status != 0): return 0
	js_text* key = js_ap_index_key(index)
	int ok = js_runtime_delete(rt, object, key)
	js_text_free(key)
	if (ok == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"array element deletion rejected")
	return rt.completion.status == 0


# Set(O, "length", length, true). Growing an array only moves its live length.
int js_ap_set_length(js_runtime* rt, js_value* object, int length):
	if (rt.completion.status != 0): return 0
	if (object.kind == 6 && length >= object.array_length):
		object.array_length = length
		return 1
	js_value* value = js_runtime_number(rt, cast(float64, length))
	if (rt.completion.status != 0): return 0
	if (js_runtime_set(rt, object, c"length", value) == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"array length write rejected")
	return rt.completion.status == 0


# CreateDataPropertyOrThrow(O, index, value): never reaches an inherited setter.
int js_ap_create(js_runtime* rt, js_value* object, int index, js_value* value):
	if (rt.completion.status != 0): return 0
	if (object.kind == 6 && index >= rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript array length limit")
		return 0
	js_text* key = js_ap_index_key(index)
	int ok = js_runtime_define_data(rt, object, key, value, 1, 1, 1)
	js_text_free(key)
	if (ok == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"array element definition rejected")
	if (ok && object.kind == 6 && index >= object.array_length): object.array_length = index + 1
	return rt.completion.status == 0


# ToIntegerOrInfinity relative to length, clamped into [0, length].
int js_ap_relative(js_runtime* rt, js_value* value, int length):
	float64 number = js_runtime_to_integer(rt, value)
	if (rt.completion.status != 0): return 0
	float64 size = cast(float64, length)
	if (number < 0.0):
		number = size + number
		if (number < 0.0): return 0
		return cast(int, number)
	if (number > size): return length
	return cast(int, number)


# Generic slice over any array-like receiver; the result is built through
# ArraySpeciesCreate (runtime_array.w).
js_value* js_ap_species_create(js_runtime* rt, js_value* original, int length);

js_value* js_ap_slice(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_ap_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	int length = js_ap_length(rt, object)
	if (rt.completion.status != 0): return rt.undefined_value
	int start = 0
	int end = length
	if (args.length > 0): start = js_ap_relative(rt, args[0], length)
	if (rt.completion.status == 0 && args.length > 1 && args[1].kind != 0): end = js_ap_relative(rt, args[1], length)
	if (rt.completion.status != 0): return rt.undefined_value
	int count = 0
	if (end > start): count = end - start
	js_value* result = js_ap_species_create(rt, object, count)
	if (rt.completion.status != 0): return rt.undefined_value
	int position = 0
	for i in range(start, end):
		if (js_runtime_compat_step(rt) == 0): break
		int present = js_ap_has(rt, object, i)
		if (rt.completion.status != 0): break
		if (present):
			js_value* item = js_ap_get(rt, object, i)
			if (rt.completion.status != 0): break
			if (js_ap_create(rt, result, position, item) == 0): break
		position = position + 1
	if (rt.completion.status == 0): js_ap_set_length(rt, result, position)
	if (rt.completion.status != 0): return rt.undefined_value
	return result
