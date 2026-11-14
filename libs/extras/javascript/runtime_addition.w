# Addition's default-hint primitive conversion precedes String/ToNumeric choice.
# https://tc39.es/ecma262/#sec-applystringornumericbinaryoperator
import libs.extras.javascript.runtime

js_value* js_runtime_add(js_runtime* rt, js_value* left, js_value* right):
	if (js_runtime_object(left)): left = js_equality_primitive(rt, left)
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_object(right)): right = js_equality_primitive(rt, right)
	if (rt.completion.status != 0): return rt.undefined_value
	if (left.kind == 4 || right.kind == 4):
		js_text* first = js_runtime_to_text(rt, left)
		js_text* second = js_runtime_to_text(rt, right)
		if (first == 0 || second == 0):
			js_text_free(first)
			js_text_free(second)
			return rt.undefined_value
		if (first.units.length > rt.max_properties - second.units.length): js_runtime_fail(rt, 5, c"JavaScript string length limit")
		js_text* joined = js_text_new()
		for i in range(first.units.length):
			if (js_runtime_compat_step(rt) == 0): break
			joined.units.push(first.units[i])
		for i in range(second.units.length):
			if (js_runtime_compat_step(rt) == 0): break
			joined.units.push(second.units[i])
		js_value* result = rt.undefined_value
		if (rt.completion.status == 0): result = js_runtime_string(rt, joined)
		js_text_free(first)
		js_text_free(second)
		js_text_free(joined)
		return result
	if (left.kind == 11 || right.kind == 11): return js_runtime_type_error(rt, c"cannot convert a Symbol value to a number")
	if (left.kind == 10 || right.kind == 10): return js_bigint_binary(rt, c"+", left, right)
	float64 a = 0.0
	float64 b = 0.0
	if (left.kind == 2 || left.kind == 3): a = left.number
	if (right.kind == 2 || right.kind == 3): b = right.number
	if (left.kind == 0): a = float64_from_bits((0x7ff << 52) | 1)
	if (right.kind == 0): b = float64_from_bits((0x7ff << 52) | 1)
	return js_runtime_number(rt, a + b)
