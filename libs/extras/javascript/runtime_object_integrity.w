# Ordinary SetIntegrityLevel/TestIntegrityLevel, including Array length and
# String wrapper virtual indices. Host/binary exotics keep explicit admission
# gaps. Every inspected key charges the active evaluation budget.
import libs.extras.javascript.runtime_object

# Codes 1 seal, 2 freeze, 3 isSealed, 4 isFrozen.
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
	if (testing && object.non_extensible == 0): return js_runtime_boolean(rt, 0)
	# PreventExtensions is observable before OwnPropertyKeys/resource failure.
	if (testing == 0): object.non_extensible = 1
	list[js_text*] keys = js_object_keys(rt, object, 1)
	int intact = 1
	for i in range(keys.length):
		if (rt.completion.status != 0): break
		js_property_descriptor current
		if (js_object_own_descriptor(rt, object, keys[i], &current) == 0): continue
		if (testing):
			if (current.configurable || (frozen && (current.fields & 48) == 0 && current.writable)): intact = 0
			if (intact == 0): break
		else:
			js_property_descriptor desc
			desc.fields = 2
			if (frozen && (current.fields & 48) == 0): desc.fields = 10
			desc.value = rt.undefined_value
			desc.getter = 0
			desc.setter = 0
			desc.writable = 0
			desc.enumerable = 0
			desc.configurable = 0
			if (js_object_descriptor_apply(rt, object, keys[i], &desc) == 0):
				if (rt.completion.status == 0): js_runtime_fail(rt, 2, c"object integrity descriptor update rejected")
				break
	js_runtime_free_keys(keys)
	if (rt.completion.status != 0): return rt.undefined_value
	if (testing): return js_runtime_boolean(rt, intact)
	return object

void js_object_install_integrity(js_runtime* rt):
	js_value* object = js_runtime_get(rt, rt.global_object, c"Object")
	js_object_method(rt, object, c"seal", js_object_integrity, 1, 1)
	js_object_method(rt, object, c"freeze", js_object_integrity, 2, 1)
	js_object_method(rt, object, c"isSealed", js_object_integrity, 3, 1)
	js_object_method(rt, object, c"isFrozen", js_object_integrity, 4, 1)
