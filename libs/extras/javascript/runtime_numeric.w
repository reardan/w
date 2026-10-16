# ToNumeric for bounded bitwise operations; ordinary conversion is observable.
# https://tc39.es/ecma262/#sec-tonumeric
import libs.extras.javascript.runtime

js_value* js_numeric_value(js_runtime* rt, js_value* value):
	if (js_runtime_compat_step(rt) == 0): return rt.undefined_value
	if (js_runtime_object(value)): value = js_equality_primitive(rt, value)
	if (rt.completion.status != 0): return rt.undefined_value
	if (value.kind == 3 || value.kind == 10): return value
	float64 number = 0.0
	if (value.kind == 0): number = float64_from_bits((0x7ff << 52) | 1)
	if (value.kind == 2): number = value.number
	if (value.kind == 4): number = js_equality_number(rt, value.text)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_number(rt, number)

js_value* js_numeric_bitwise(js_runtime* rt, char* operation, js_value* left, js_value* right):
	left = js_numeric_value(rt, left)
	if (rt.completion.status != 0): return rt.undefined_value
	right = js_numeric_value(rt, right)
	if (rt.completion.status != 0): return rt.undefined_value
	if (left.kind == 10 || right.kind == 10):
		if (left.kind != right.kind):
			js_runtime_fail(rt, 2, c"bitwise operands require matching numeric types")
			return rt.undefined_value
		if (strcmp(operation, c">>>") == 0):
			js_runtime_fail(rt, 2, c"BigInt does not support unsigned right shift")
			return rt.undefined_value
		return js_bigint_binary(rt, operation, left, right)
	return js_runtime_bit_binary(rt, operation, left.number, right.number)

js_value* js_numeric_not(js_runtime* rt, js_value* value):
	value = js_numeric_value(rt, value)
	if (rt.completion.status != 0): return rt.undefined_value
	if (value.kind == 10):
		js_runtime_fail(rt, 6, c"BigInt bitwise operations are outside the runtime subset")
		return rt.undefined_value
	return js_runtime_number(rt, cast(float64, ~js_runtime_int32(value.number)))
