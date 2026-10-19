# String-separator split operates on UTF-16 units, including lone surrogates.
# RegExp/@@split dispatch remains explicit unsupported until Symbol methods.
# https://tc39.es/ecma262/#sec-string.prototype.split
import libs.extras.javascript.runtime

void js_string_split_piece(js_runtime* rt, js_value* array, js_text* source, int start, int end):
	js_text* piece = js_text_new()
	for i in range(start, end):
		if (js_runtime_compat_step(rt) == 0): break
		piece.units.push(source.units[i])
	if (rt.completion.status == 0):
		js_value* value = js_runtime_string(rt, piece)
		if (rt.completion.status == 0): js_array_iteration_store(rt, array, array.array_length, value)
	js_text_free(piece)

js_value* js_string_split(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	if (receiver.kind == 0 || receiver.kind == 1):
		js_runtime_fail(rt, 2, c"split requires a coercible receiver")
		return rt.undefined_value
	js_value* separator = js_object_argument(rt, args, 0)
	if (separator.regexp != 0):
		js_runtime_fail(rt, 6, c"RegExp split requires Symbol.split dispatch")
		return rt.undefined_value
	js_text* source = js_runtime_string_text(rt, receiver)
	if (source == 0): return rt.undefined_value
	int limit = (1 << 32) - 1
	js_value* limit_value = js_object_argument(rt, args, 1)
	if (limit_value.kind != 0):
		float64 number = js_array_like_number(rt, limit_value)
		limit = 0
		if (rt.completion.status == 0 && js_builtin_finite(number)):
			float64 reduced = js_number_remainder(rt, js_builtin_trunc(number), 4294967296.0)
			if (rt.completion.status == 0): limit = cast(int, reduced) & ((1 << 32) - 1)
	js_text* delimiter = 0
	if (rt.completion.status == 0): delimiter = js_runtime_string_text(rt, separator)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_alloc(rt, 6)
	if (rt.completion.status == 0 && limit > 0):
		if (separator.kind == 0): js_string_split_piece(rt, result, source, 0, source.units.length)
		else if (delimiter.units.length == 0):
			for i in range(source.units.length):
				if (rt.completion.status != 0 || result.array_length >= limit): break
				js_string_split_piece(rt, result, source, i, i + 1)
		else:
			int start = 0
			int at = 0
			while (at <= source.units.length - delimiter.units.length && rt.completion.status == 0 && result.array_length < limit):
				int matched = 1
				for j in range(delimiter.units.length):
					if (js_runtime_compat_step(rt) == 0): break
					if (source.units[at + j] != delimiter.units[j]):
						matched = 0
						break
				if (rt.completion.status != 0): break
				if (matched):
					js_string_split_piece(rt, result, source, start, at)
					at = at + delimiter.units.length
					start = at
				else: at = at + 1
			if (rt.completion.status == 0 && result.array_length < limit): js_string_split_piece(rt, result, source, start, source.units.length)
	js_text_free(source)
	js_text_free(delimiter)
	if (rt.completion.status != 0): return rt.undefined_value
	return result

void js_runtime_install_string_split(js_runtime* rt):
	js_object_method(rt, rt.string_prototype, c"split", js_string_split, 0, 2)
