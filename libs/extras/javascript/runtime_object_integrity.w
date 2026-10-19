# Ordinary SetIntegrityLevel/TestIntegrityLevel, including Array length and
# mapped argument descriptors. Host/binary exotics keep explicit admission gaps.
import libs.extras.javascript.runtime

js_value* js_object_integrity(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_object_argument(rt, args, 0)
	int operation = cast(int, context)
	int testing = operation >= 3
	int frozen = operation == 2 || operation == 4
	if (js_runtime_object(object) == 0):
		if (testing): return js_runtime_boolean(rt, 1)
		return object
	if (js_object_ordinary(rt, object) == 0): return rt.undefined_value
	if (testing && object.extensible): return js_runtime_boolean(rt, 0)
	# PreventExtensions is observable before OwnPropertyKeys/resource failure.
	if (testing == 0): object.extensible = 0
	list[js_text*] keys = js_object_keys(rt, object)
	int intact = 1
	for i in range(keys.length):
		if (js_runtime_compat_step(rt) == 0): break
		js_value* property = js_runtime_property(object, keys[i])
		int length = object.kind == 6 && js_runtime_key_is(keys[i], c"length")
		if (property == 0 && length == 0): continue
		if (testing):
			if (length):
				if (frozen && object.array_length_writable): intact = 0
			else if (property.configurable || (frozen && property.accessor == 0 && property.writable)): intact = 0
			if (intact == 0): break
		else:
			js_object_descriptor desc
			desc.fields = 2
			if (frozen && (length || property.accessor == 0)): desc.fields = 10
			desc.value = rt.undefined_value
			desc.getter = 0
			desc.setter = 0
			desc.writable = 0
			desc.enumerable = 0
			desc.configurable = 0
			# The shared descriptor path captures the live mapped argument value
			# before writable:false disconnects its parameter mapping.
			if (js_object_descriptor_apply(rt, object, keys[i], &desc) == 0):
				js_runtime_fail(rt, 2, c"object integrity descriptor update rejected")
				break
	js_for_in_keys_free(keys)
	if (rt.completion.status != 0): return rt.undefined_value
	if (testing): return js_runtime_boolean(rt, intact)
	return object

void js_runtime_install_object_integrity(js_runtime* rt):
	js_value* object = js_runtime_get(rt, rt.global, c"Object")
	js_object_method(rt, object, c"seal", js_object_integrity, 1, 1)
	js_object_method(rt, object, c"freeze", js_object_integrity, 2, 1)
	js_object_method(rt, object, c"isSealed", js_object_integrity, 3, 1)
	js_object_method(rt, object, c"isFrozen", js_object_integrity, 4, 1)
