/*
Seam for the JS builtins port (string cluster). Called once from js_runtime_new
after every other install step. This file belongs to the string cluster agent.

Already present on origin (not ported): String.prototype slice, codePointAt,
startsWith, indexOf, toString, valueOf, match, matchAll, replace, search, split
(string and RegExp separators/patterns, runtime_collections.w and
regexp_methods.w).
*/
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_string_support
import libs.extras.javascript.runtime_string_code_unit
import libs.extras.javascript.runtime_string_substring
import libs.extras.javascript.runtime_string_trim
import libs.extras.javascript.runtime_string_case


# Origin installs these String.prototype methods without name/length; add the
# standard function properties so they match the ported methods.
void js_install_string_shapes(js_runtime* rt):
	list[char*] names = new list[char*]
	list[int] lengths = new list[int]
	names.push(c"slice")
	lengths.push(2)
	names.push(c"codePointAt")
	lengths.push(1)
	names.push(c"startsWith")
	lengths.push(1)
	names.push(c"indexOf")
	lengths.push(1)
	names.push(c"match")
	lengths.push(1)
	names.push(c"matchAll")
	lengths.push(1)
	names.push(c"replace")
	lengths.push(2)
	names.push(c"search")
	lengths.push(1)
	names.push(c"split")
	lengths.push(2)
	names.push(c"toString")
	lengths.push(0)
	names.push(c"valueOf")
	lengths.push(0)
	for i in range(names.length):
		js_text* key = js_runtime_key(names[i])
		js_value* property = js_runtime_property(rt.string_prototype, key)
		js_text_free(key)
		if (property == 0 || js_runtime_callable(property.value) == 0): continue
		js_value* method = property.value
		key = js_runtime_key(c"name")
		int shaped = js_runtime_property(method, key) != 0
		js_text_free(key)
		if (shaped == 0): js_string_function_shape(rt, method, names[i], lengths[i])
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, lengths))


void js_install_string(js_runtime* rt):
	js_install_string_shapes(rt)
	js_install_string_code_unit(rt)
	js_install_string_substring(rt)
	js_install_string_trim(rt)
	js_install_string_case(rt)
