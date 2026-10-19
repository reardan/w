# Default RegExp separator split uses a fresh sticky matcher and preserves the
# separator's lastIndex. Symbols/species/custom exec remain explicit gaps.
# https://tc39.es/ecma262/#sec-regexp.prototype-%symbol.split%
import libs.extras.javascript.runtime

int js_string_split_limit(js_runtime* rt, js_value* value):
	if (value.kind == 0): return (1 << 32) - 1
	float64 number = js_array_like_number(rt, value)
	if (rt.completion.status != 0 || js_builtin_finite(number) == 0): return 0
	float64 reduced = js_number_remainder(rt, js_builtin_trunc(number), 4294967296.0)
	if (rt.completion.status != 0): return 0
	return cast(int, reduced) & ((1 << 32) - 1)

js_value* js_regexp_split_clone(js_runtime* rt, js_value* separator):
	js_value* constructor = js_runtime_get(rt, separator, c"constructor")
	if (rt.completion.status != 0): return rt.undefined_value
	if (constructor.kind != 0 && js_runtime_object(constructor) == 0):
		js_runtime_fail(rt, 2, c"RegExp split constructor is not an object")
		return rt.undefined_value
	if (constructor.host_get || constructor.host_has):
		js_runtime_fail(rt, 6, c"RegExp split host species requires Symbol support")
		return rt.undefined_value
	js_value* raw_flags = js_runtime_get(rt, separator, c"flags")
	js_text* flags = 0
	if (rt.completion.status == 0): flags = js_runtime_string_text(rt, raw_flags)
	js_value* clone = rt.undefined_value
	if (flags != 0):
		int sticky = 0
		for i in range(flags.units.length):
			if (js_runtime_compat_step(rt) == 0): break
			if (flags.units[i] == 'y'): sticky = 1
		if (sticky == 0): flags.units.push('y')
		js_regexp* original = cast(js_regexp*, separator.regexp)
		if (rt.completion.status == 0): clone = js_re_create(rt, original.source, flags)
	js_text_free(flags)
	return clone

js_value* js_string_split_regexp(js_runtime* rt, js_value* receiver, js_value* separator, js_value* limit_value):
	js_text* source = js_runtime_string_text(rt, receiver)
	if (source == 0): return rt.undefined_value
	js_value* splitter = js_regexp_split_clone(rt, separator)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_alloc(rt, 6)
	int limit = 0
	if (rt.completion.status == 0): limit = js_string_split_limit(rt, limit_value)
	if (rt.completion.status == 0 && limit > 0):
		if (source.units.length == 0):
			js_re_state* matched = 0
			if (js_re_check_exec(rt, splitter)): matched = js_re_exec(rt, splitter, source)
			if (matched == 0 && rt.completion.status == 0): js_string_split_piece(rt, result, source, 0, 0)
			js_re_state_free(matched)
		else:
			int previous = 0
			int position = 0
			while (position < source.units.length && rt.completion.status == 0 && result.array_length < limit):
				if (js_runtime_compat_step(rt) == 0 || js_re_last_index_set(rt, splitter, position) == 0): break
				if (js_re_check_exec(rt, splitter) == 0): break
				js_re_state* matched = js_re_exec(rt, splitter, source)
				if (rt.completion.status != 0): break
				if (matched == 0): position = position + 1
				else:
					int end = matched.position
					if (end == previous): position = position + 1
					else:
						js_string_split_piece(rt, result, source, previous, position)
						previous = end
						for i in range(2, matched.captures.length, 2):
							if (rt.completion.status != 0 || result.array_length >= limit): break
							js_value* capture = js_re_slice(rt, source, matched.captures[i], matched.captures[i + 1])
							if (rt.completion.status == 0): js_array_iteration_store(rt, result, result.array_length, capture)
						position = previous
					js_re_state_free(matched)
			if (rt.completion.status == 0 && result.array_length < limit): js_string_split_piece(rt, result, source, previous, source.units.length)
	js_text_free(source)
	if (rt.completion.status != 0): return rt.undefined_value
	return result
