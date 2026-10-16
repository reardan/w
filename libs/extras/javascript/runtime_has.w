# ECMA-262 HasProperty for the current descriptor/prototype model.
# https://tc39.es/ecma262/#sec-ordinaryhasproperty
import libs.extras.javascript.runtime

# The callback shares the object's existing host_context. Positive means a
# native own property exists; zero delegates to ordinary properties/prototype;
# negative means unsupported. It must not invoke the property's getter.
int js_runtime_set_host_has(js_runtime* rt, js_value* object, js_host_has* callback):
	if (js_runtime_object(object) == 0 || object.owner != rt): return 0
	object.host_has = cast(int, callback)
	return 1

# Caller owns the normal runtime execution budget. Like ordinary property reads,
# native reflection callbacks enter the bounded/reentrancy-protected host scope.
int js_runtime_has_property_impl(js_runtime* rt, js_value* object, js_text* key):
	if (js_runtime_object(object) == 0 || object.owner != rt || key == 0):
		js_runtime_fail(rt, 2, c"property presence requires an object and key")
		return 0
	if (js_equality_charge(rt, key.units.length) == 0): return 0
	js_value* current = object
	int depth = 0
	while (current != 0):
		if (depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
			js_runtime_fail(rt, 5, c"JavaScript property presence depth limit")
			return 0
		depth = depth + 1
		if (current.host_has != 0):
			if (js_runtime_property_enter(rt) == 0): return 0
			js_host_has* callback = cast(js_host_has*, current.host_has)
			int result = callback(rt, current.host_context, object, key)
			js_runtime_property_leave(rt)
			if (rt.completion.status != 0): return 0
			if (result > 0): return 1
			if (result < 0):
				js_runtime_fail(rt, 6, c"native property presence is unsupported")
				return 0
		else if (current.host_get != 0 || current.host_set != 0 || current.binary_kind != 0):
			js_runtime_fail(rt, 6, c"native property presence requires a reflection hook")
			return 0
		if (current.kind == 6 && js_runtime_key_is(key, c"length")): return 1
		for i in range(current.properties.length):
			if (js_runtime_compat_step(rt) == 0): return 0
			js_text* candidate = current.properties[i].key
			if (candidate.units.length == key.units.length):
				if (js_equality_charge(rt, key.units.length) == 0): return 0
				if (js_text_equal(candidate, key)): return 1
		current = current.prototype
	return 0

# Host entry preserves an explicitly supplied budget instead of letting the
# generic property-enter helper substitute its default outside evaluation.
int js_runtime_has_property(js_runtime* rt, js_value* object, js_text* key):
	int running = rt.running
	rt.running = rt.running + 1
	int result = js_runtime_has_property_impl(rt, object, key)
	rt.running = running
	return result

js_value* js_runtime_in(js_runtime* rt, js_value* key_value, js_value* object):
	# The RHS check precedes observable ToPropertyKey conversion of the LHS.
	if (js_runtime_object(object) == 0):
		js_runtime_fail(rt, 2, c"right operand of in must be an object")
		return rt.undefined_value
	js_text* key = js_runtime_string_text(rt, key_value)
	if (key == 0): return rt.undefined_value
	int result = js_runtime_has_property(rt, object, key)
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_boolean(rt, result)
