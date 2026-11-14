# Math.pow uses W's binary64 implementation after ECMAScript's distinct
# NaN/unit-base rules. Both observable ToNumber conversions precede the result.
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_object
import libs.extras.javascript.runtime_number_parse

js_value* js_math_pow(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_number_arguments(rt, args) == 0): return rt.undefined_value
	float64 base = js_runtime_to_number(rt, js_object_argument(rt, args, 0))
	if (rt.completion.status != 0): return rt.undefined_value
	float64 exponent = js_runtime_to_number(rt, js_object_argument(rt, args, 1))
	if (rt.completion.status != 0): return rt.undefined_value
	float64 result = js_builtin_nan()
	if (f64is_nan(exponent) == 0):
		if (exponent == 0.0): result = 1.0
		else if (f64is_nan(base) == 0):
			if (fabs64(base) != 1.0 || js_builtin_finite(exponent)): result = fpow64(base, exponent)
	return js_runtime_number(rt, result)

void js_runtime_install_harness_math(js_runtime* rt):
	js_value* math = js_runtime_get(rt, rt.global, c"Math")
	if (js_runtime_object(math) == 0): return
	js_object_method(rt, math, c"pow", js_math_pow, 0, 2)
