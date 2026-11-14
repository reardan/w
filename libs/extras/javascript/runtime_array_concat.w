# Bounded concat preserves holes and live inherited Get/Has behaviour. Each
# item is spread when its @@isConcatSpreadable (else IsArray) says so, and the
# result is created through ArraySpeciesCreate.
# https://tc39.es/ecma262/#sec-array.prototype.concat
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_array_like
import libs.extras.javascript.runtime_array


int js_ap_spreadable(js_runtime* rt, js_value* value):
	if (js_runtime_object(value) == 0): return 0
	js_text* key = js_symbol_key(JS_SYMBOL_IS_CONCAT_SPREADABLE)
	js_value* flag = js_runtime_member_read(rt, value, key)
	js_text_free(key)
	if (rt.completion.status != 0): return 0
	if (flag.kind != 0): return js_runtime_truth(flag)
	return value.kind == 6


js_value* js_ap_concat(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_ap_arguments(rt, args) == 0): return rt.undefined_value
	js_value* object = js_ap_object(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* result = js_ap_species_create(rt, object, 0)
	if (rt.completion.status != 0): return rt.undefined_value
	int position = 0
	for i in range(args.length + 1):
		if (js_runtime_compat_step(rt) == 0): break
		js_value* item = object
		if (i > 0): item = args[i - 1]
		int spread = js_ap_spreadable(rt, item)
		if (rt.completion.status != 0): break
		if (spread == 0):
			if (position >= rt.max_properties):
				js_runtime_fail(rt, 5, c"concat output length limit")
				break
			if (js_ap_create(rt, result, position, item) == 0): break
			position = position + 1
		else:
			int length = js_ap_length(rt, item)
			if (rt.completion.status != 0): break
			if (length > rt.max_properties - position):
				js_runtime_fail(rt, 5, c"concat output length limit")
				break
			for j in range(length):
				if (js_runtime_compat_step(rt) == 0): break
				int present = js_ap_has(rt, item, j)
				if (rt.completion.status != 0): break
				if (present):
					js_value* value = js_ap_get(rt, item, j)
					if (rt.completion.status == 0): js_ap_create(rt, result, position, value)
				if (rt.completion.status != 0): break
				position = position + 1
		if (rt.completion.status != 0): break
	if (rt.completion.status == 0): js_ap_set_length(rt, result, position)
	if (rt.completion.status != 0): return rt.undefined_value
	return result
