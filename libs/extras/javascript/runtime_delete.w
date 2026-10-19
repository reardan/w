# Delete evaluates references without invoking their value getter. Failed
# ordinary deletion is false in sloppy code and TypeError in strict code.
import libs.extras.javascript.runtime

js_value* js_runtime_delete_expression(js_runtime* rt, js_node* operand, js_value* env):
	int result = 1
	js_value* object = 0
	js_text* key = 0
	if (js_kind(operand, c"identifier")):
		js_value* binding = js_runtime_binding(env, operand.text)
		if (binding != 0 && binding.accessor != 3): result = 0
		else if (rt.global_object != 0):
			object = rt.global_object
			key = js_runtime_key(operand.text)
	else if (js_kind(operand, c"member") || js_kind(operand, c"computed_member")):
		object = js_runtime_eval_node(rt, operand.children[0], env)
		if (rt.completion.status == 0): key = js_runtime_member_key(rt, operand, env, object)
	else: js_runtime_eval_node(rt, operand, env)
	if (object != 0 && key != 0 && rt.completion.status == 0):
		if (object.kind == 0 || object.kind == 1): js_runtime_fail(rt, 2, c"cannot delete a null or undefined property")
		else if (object.kind == 4):
			int index = js_runtime_array_index(key)
			result = js_runtime_key_is(key, c"length") == 0 && (index < 0 || index >= object.text.units.length)
		else if (js_runtime_object(object)):
			if (js_object_ordinary(rt, object)): result = js_runtime_delete(rt, object, key)
	js_text_free(key)
	if (result == 0 && env.strict): js_runtime_fail(rt, 2, c"property deletion rejected")
	return js_runtime_boolean(rt, result)
