# Generic Array.prototype.join and toString. Length is snapshotted before the
# separator is converted; every position is Get, holes included. A join that
# reaches an array already being joined yields the empty string for it, so
# cyclic structures terminate. Output length and copying are charged to the
# evaluation budget, and every temporary buffer unwinds on any abrupt exit.
# https://tc39.es/ecma262/#sec-array.prototype.join
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_array_like


# Objects currently inside a join, innermost last. Pointers are unique across
# runtimes and every exit pops, so the list is freed when it empties.
list[js_value*] js_ap_joining


int js_ap_join_active(js_value* object):
	if (js_ap_joining == 0): return 0
	for i in range(js_ap_joining.length):
		if (js_ap_joining[i] == object): return 1
	return 0


void js_ap_join_pop():
	js_ap_joining.pop()
	if (js_ap_joining.length == 0):
		__w_list_free(cast(__w_list*, js_ap_joining))
		js_ap_joining = 0


int js_ap_join_append(js_runtime* rt, js_text* output, js_text* text):
	if (text.units.length > rt.max_properties - output.units.length):
		js_runtime_fail(rt, 5, c"JavaScript join string length limit")
		return 0
	if (js_ap_charge(rt, text.units.length) == 0): return 0
	for i in range(text.units.length): output.units.push(text.units[i])
	return 1


js_value* js_ap_join_body(js_runtime* rt, js_value* object, list[js_value*] args):
	int length = js_ap_length(rt, object)
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* separator = 0
	if (args.length == 0 || args[0].kind == 0): separator = js_runtime_key(c",")
	else: separator = js_runtime_to_text(rt, args[0])
	if (separator == 0): return rt.undefined_value
	js_text* output = js_text_new()
	if (js_ap_join_active(object) == 0):
		if (js_ap_joining == 0): js_ap_joining = new list[js_value*]
		js_ap_joining.push(object)
		for i in range(length):
			if (js_runtime_compat_step(rt) == 0): break
			if (i > 0 && js_ap_join_append(rt, output, separator) == 0): break
			js_value* value = js_ap_get(rt, object, i)
			if (rt.completion.status != 0): break
			if (value.kind == 0 || value.kind == 1): continue
			js_text* item = js_runtime_to_text(rt, value)
			if (item == 0): break
			js_ap_join_append(rt, output, item)
			js_text_free(item)
		js_ap_join_pop()
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, output)
	js_text_free(output)
	js_text_free(separator)
	return result


js_value* js_ap_join(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_ap_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_ap_enter(rt) == 0): return rt.undefined_value
	js_value* result = js_ap_join_body(rt, object, args)
	js_ap_leave(rt)
	return result


# toString calls join when it is callable, else the intrinsic object text.
js_value* js_ap_to_string(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_ap_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* join = js_runtime_get(rt, object, c"join")
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_callable(join) == 0): return js_runtime_intrinsic_text(rt, object)
	if (js_ap_enter(rt) == 0): return rt.undefined_value
	list[js_value*] empty = new list[js_value*]
	js_value* result = js_runtime_call_receiver(rt, join, object, empty)
	__w_list_free(cast(__w_list*, empty))
	js_ap_leave(rt)
	return result
