# Bounded Array exotic property definitions. Length remains a virtual own data
# property; its writable state (length_readonly) is independent of
# extensibility and index attributes.
import libs.extras.javascript.runtime_object

int js_array_length_descriptor(js_runtime* rt, js_value* array, js_property_descriptor* desc):
	if (array == 0 || array.owner != rt || array.kind != 6): return 0
	int length = array.array_length
	if (desc.fields & 4):
		if (desc.value == 0 || desc.value.owner != rt): return 0
		# ArraySetLength deliberately performs ToNumber twice. User coercion may
		# alter the array; the old length descriptor is read only afterwards.
		float64 first = js_runtime_to_number(rt, desc.value)
		if (rt.completion.status != 0): return 0
		int unsigned_length = js_runtime_int32(first) & ((1 << 32) - 1)
		float64 second = js_runtime_to_number(rt, desc.value)
		if (rt.completion.status != 0): return 0
		if (f64is_nan(second) || second != cast(float64, unsigned_length)):
			js_object_range_error(rt, c"invalid Array length")
			return 0
		length = unsigned_length
	if ((desc.fields & 48) != 0 || ((desc.fields & 1) != 0 && desc.enumerable) || ((desc.fields & 2) != 0 && desc.configurable)): return 0
	int writable = array.length_readonly == 0
	if (desc.fields & 8): writable = desc.writable
	if (array.length_readonly && (writable || length != array.array_length)): return 0
	if (length > rt.max_properties):
		js_runtime_fail(rt, 5, c"Array length exceeds runtime limit")
		return 0
	if (length >= array.array_length):
		array.array_length = length
		array.length_readonly = writable == 0
		return 1
	# Ordinary array deletion has no callbacks. Find the highest undeletable
	# index first, then compact exactly the higher configurable properties. This
	# is equivalent to descending deletion and avoids quadratic sparse scans.
	int final_length = length
	int count = array.properties.length
	if (count > rt.remaining / 2):
		js_runtime_fail(rt, 5, c"Array length mutation execution limit")
		return 0
	rt.remaining = rt.remaining - count * 2
	rt.completion.steps = rt.completion.steps + count * 2
	for i in range(count):
		js_value* property = array.properties[i]
		int index = js_runtime_array_index(property.key)
		if (index >= length && property.configurable == 0 && index >= final_length): final_length = index + 1
	int retained = 0
	for i in range(count):
		js_value* property = array.properties[i]
		int index = js_runtime_array_index(property.key)
		if (index >= final_length):
			js_text_free(property.key)
			free(property)
		else:
			array.properties[retained] = property
			retained = retained + 1
	while (array.properties.length > retained): array.properties.pop()
	array.array_length = final_length
	array.length_readonly = writable == 0
	return final_length == length

# [[Set]] of "length" on an Array: refuses a read-only length before any value
# coercion, then runs ArraySetLength as a data-only descriptor update.
int js_array_set_length(js_runtime* rt, js_value* object, js_value* value):
	if (object == 0 || object.owner != rt || object.kind != 6 || value == 0 || value.owner != rt): return 0
	if (object.length_readonly): return 0
	js_property_descriptor desc
	desc.fields = 4
	desc.value = value
	desc.getter = 0
	desc.setter = 0
	desc.writable = 0
	desc.enumerable = 0
	desc.configurable = 0
	return js_array_length_descriptor(rt, object, &desc)
