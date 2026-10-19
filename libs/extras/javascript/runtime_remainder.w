# Number::remainder uses exact significand division, avoiding overflow in
# x/y and cancellation in x-trunc(x/y)*y, including subnormal operands.
import libs.extras.javascript.runtime

float64 js_number_remainder(js_runtime* rt, float64 left, float64 right):
	if (f64is_nan(left) || f64is_nan(right) || js_builtin_finite(left) == 0 || right == 0.0): return js_builtin_nan()
	if (js_builtin_finite(right) == 0 || left == 0.0): return left
	int sign = float64_bits(left) & (1 << 63)
	int x = float64_bits(left) & ~(1 << 63)
	int y = float64_bits(right) & ~(1 << 63)
	if (x < y): return left
	if (x == y): return float64_from_bits(sign)
	int ex = x >> 52
	int ey = y >> 52
	int hidden = 1 << 52
	x = x & (hidden - 1)
	y = y & (hidden - 1)
	if (ex == 0):
		ex = 1
		while (x < hidden):
			x = x << 1
			ex = ex - 1
	else: x = x | hidden
	if (ey == 0):
		ey = 1
		while (y < hidden):
			y = y << 1
			ey = ey - 1
	else: y = y | hidden
	while (ex > ey):
		if (js_runtime_compat_step(rt) == 0): return js_builtin_nan()
		if (x >= y): x = x - y
		if (x == 0): return float64_from_bits(sign)
		x = x << 1
		ex = ex - 1
	if (x >= y): x = x - y
	if (x == 0): return float64_from_bits(sign)
	while (x < hidden):
		x = x << 1
		ex = ex - 1
	if (ex > 0): x = (x - hidden) | (ex << 52)
	else: x = x >> (1 - ex)
	return float64_from_bits(x | sign)

js_value* js_runtime_remainder(js_runtime* rt, js_value* left, js_value* right):
	left = js_numeric_value(rt, left)
	if (rt.completion.status != 0): return rt.undefined_value
	right = js_numeric_value(rt, right)
	if (rt.completion.status != 0): return rt.undefined_value
	if (left.kind == 10 || right.kind == 10): return js_bigint_binary(rt, c"%", left, right)
	return js_runtime_number(rt, js_number_remainder(rt, left.number, right.number))
