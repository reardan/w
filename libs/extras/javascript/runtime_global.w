# Optional global object environment for browser/host realms. Declarative
# bindings retain precedence and TDZ; object bindings use actual Get/Set hooks.
import libs.extras.javascript.runtime

int js_runtime_set_global_object(js_runtime* rt, js_value* object):
	if (rt.running || rt.global_object != 0 || js_runtime_object(object) == 0 || object.owner != rt): return 0
	rt.global_object = object
	rt.global.this_value = object
	for i in range(rt.global.properties.length):
		js_value* binding = rt.global.properties[i]
		if (js_runtime_property(object, binding.key) == 0):
			js_runtime_define_data(rt, object, binding.key, binding.value, binding.immutable == 0, 0, binding.immutable == 0)
		if (binding.lexical_binding == 0):
			binding.accessor = 3
			binding.getter = object
	return rt.completion.status == 0

int js_global_has(js_runtime* rt, char* name):
	if (rt.global_object == 0): return 0
	js_text* key = js_runtime_key(name)
	int present = js_runtime_has_property(rt, rt.global_object, key)
	js_text_free(key)
	return present

js_value* js_global_read(js_runtime* rt, char* name):
	if (js_global_has(rt, name) == 0):
		js_runtime_fail(rt, 2, c"uninitialized or missing binding")
		return rt.undefined_value
	return js_runtime_get(rt, rt.global_object, name)

void js_global_binding_write(js_runtime* rt, js_value* binding, js_value* value, int strict):
	if (binding.accessor == 3):
		if (js_runtime_member_write(rt, binding.getter, binding.key, value) == 0 && strict): js_runtime_fail(rt, 2, c"property write rejected")
	else: binding.value = value

# A var declaration only creates an absent property. A function declaration
# installs its value. Global vars/functions are nonconfigurable new properties.
void js_global_declare(js_runtime* rt, js_value* env, js_value* binding, int function):
	if (env != rt.global || rt.global_object == 0 || binding == 0 || binding.lexical_binding): return
	js_value* existing = js_runtime_property(rt.global_object, binding.key)
	if (existing == 0):
		if (js_runtime_define_data(rt, rt.global_object, binding.key, binding.value, 1, 1, 0) == 0): js_runtime_fail(rt, 2, c"global declaration rejected")
	else if (function):
		if (js_runtime_member_write(rt, rt.global_object, binding.key, binding.value) == 0): js_runtime_fail(rt, 2, c"global function declaration rejected")
	binding.accessor = 3
	binding.getter = rt.global_object
