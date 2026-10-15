/*
Small numeric browser intrinsics. Native work is bounded by the argument limit
and charged to the active evaluation budget. Math accepts primitive numeric,
boolean/null/undefined inputs; object/string coercion remains outside the
runtime subset. Number predicates never coerce. Date is a namespace with now,
not a Date constructor; now reports UTC epoch milliseconds.
*/
import libs.extras.javascript.runtime


float64 js_builtin_nan():
	return float64_from_bits((0x7ff << 52) | 1)


int js_builtin_finite(float64 number):
	return ((float64_bits(number) >> 52) & 2047) != 2047


# Bit truncation handles the whole finite range and preserves negative zero.
# Avoid ffloor64's float-to-word conversion, which overflows for large inputs.
float64 js_builtin_trunc(float64 number):
	int bits = float64_bits(number)
	int exponent = ((bits >> 52) & 2047) - 1023
	if (exponent >= 52): return number
	if (exponent < 0): return float64_from_bits(bits & (1 << 63))
	return float64_from_bits(bits & (0 - (1 << (52 - exponent))))


float64 js_builtin_floor(float64 number):
	float64 whole = js_builtin_trunc(number)
	if (f64is_nan(number) == 0 && number < whole): return whole - 1.0
	return whole


float64 js_builtin_ceil(float64 number):
	float64 whole = js_builtin_trunc(number)
	if (f64is_nan(number) == 0 && number > whole): return whole + 1.0
	return whole


float64 js_builtin_round(float64 number):
	if (js_builtin_finite(number) == 0 || number == 0.0 || fabs64(number) >= 4503599627370496.0): return number
	# Ties go toward +infinity, including -0.5 -> -0. Avoid x+0.5,
	# which rounds prematurely just below 0.5 and at large half-integers.
	if (number < 0.0 && number >= -0.5): return float64_from_bits(1 << 63)
	float64 lower = js_builtin_floor(number)
	if (number - lower >= 0.5): return lower + 1.0
	return lower


int js_builtin_arguments(js_runtime* rt, list[js_value*] args):
	if (args.length > rt.max_properties || (rt.running && args.length > rt.remaining)):
		js_runtime_fail(rt, 5, c"JavaScript builtin argument limit")
		return 0
	if (rt.running):
		rt.remaining = rt.remaining - args.length
		rt.completion.steps = rt.completion.steps + args.length
	return 1


float64 js_builtin_argument(js_runtime* rt, list[js_value*] args, int index):
	if (index >= args.length): return js_builtin_nan()
	return js_binary_number(rt, args[index])


# fsqrt64 is normalized-input only. Scale subnormals before calling it.
float64 js_builtin_sqrt(float64 number):
	if (f64is_nan(number) || number == 0.0): return number
	if (number < 0.0): return js_builtin_nan()
	if (js_builtin_finite(number) == 0): return number
	if (((float64_bits(number) >> 52) & 2047) == 0): return fsqrt64(number * 18014398509481984.0) / 134217728.0
	return fsqrt64(number)


# max/min preserve the specified sign of zero, independently of arg order.
float64 js_builtin_extreme(js_runtime* rt, list[js_value*] args, int maximum):
	float64 result = float64_from_bits(0x7ff << 52)
	if (maximum): result = 0.0 - result
	int nan = 0
	for i in range(args.length):
		float64 number = js_builtin_argument(rt, args, i)
		if (rt.completion.status != 0): return js_builtin_nan()
		if (f64is_nan(number)): nan = 1
		else if ((maximum && number > result) || (maximum == 0 && number < result)): result = number
		else if (number == 0.0 && result == 0.0):
			if (maximum && float64_bits(number) == 0): result = number
			if (maximum == 0 && float64_bits(number) < 0): result = number
	if (nan): return js_builtin_nan()
	return result


# Online scaled sum-of-squares avoids intermediate overflow/underflow.
float64 js_builtin_hypot(js_runtime* rt, list[js_value*] args):
	float64 scale = 0.0
	float64 sum = 0.0
	int infinite = 0
	int nan = 0
	for i in range(args.length):
		float64 number = fabs64(js_builtin_argument(rt, args, i))
		if (rt.completion.status != 0): return js_builtin_nan()
		if (f64is_nan(number)): nan = 1
		else if (js_builtin_finite(number) == 0): infinite = 1
		else if (number > 0.0):
			if (number > scale):
				float64 ratio = scale / number
				sum = 1.0 + sum * ratio * ratio
				scale = number
			else:
				float64 ratio = number / scale
				sum = sum + ratio * ratio
	if (infinite): return float64_from_bits(0x7ff << 52)
	if (nan): return js_builtin_nan()
	if (scale == 0.0): return 0.0
	return scale * js_builtin_sqrt(sum)


# Codes: round/floor/ceil/trunc/abs/sign/sqrt/fround, max/min/hypot.
js_value* js_builtin_math(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int code = cast(int, context)
	float64 result = 0.0
	if (code == 9): result = js_builtin_extreme(rt, args, 1)
	else if (code == 10): result = js_builtin_extreme(rt, args, 0)
	else if (code == 11): result = js_builtin_hypot(rt, args)
	else:
		float64 number = js_builtin_argument(rt, args, 0)
		if (rt.completion.status != 0): return rt.undefined_value
		if (code == 1): result = js_builtin_round(number)
		else if (code == 2): result = js_builtin_floor(number)
		else if (code == 3): result = js_builtin_ceil(number)
		else if (code == 4): result = js_builtin_trunc(number)
		else if (code == 5): result = fabs64(number)
		else if (code == 6):
			result = number
			if (f64is_nan(number) == 0 && number != 0.0):
				result = 1.0
				if (number < 0.0): result = -1.0
		else if (code == 7): result = js_builtin_sqrt(number)
		else if (code == 8): result = cast(float64, cast(float, number))
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_number(rt, result)


# Number.isFinite/isInteger/isNaN/isSafeInteger are noncoercing predicates.
js_value* js_builtin_number(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	int result = 0
	if (args.length > 0 && args[0].kind == 3):
		float64 number = args[0].number
		int code = cast(int, context)
		if (code == 3): result = f64is_nan(number)
		else:
			result = js_builtin_finite(number)
			if (result && code != 1): result = number == js_builtin_trunc(number)
			if (result && code == 4): result = fabs64(number) <= 9007199254740991.0
	return js_runtime_boolean(rt, result)


struct js_builtin_timespec:
	int seconds
	int nanoseconds


js_value* js_builtin_date_now(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_builtin_timespec stamp
	# clock id 0 is CLOCK_REALTIME; Date.now is not a monotonic timestamp.
	if (sys_clock_gettime(0, cast(int, &stamp)) < 0):
		js_runtime_fail(rt, 2, c"Date.now clock unavailable")
		return rt.undefined_value
	return js_runtime_number(rt, cast(float64, stamp.seconds) * 1000.0 + cast(float64, stamp.nanoseconds / 1000000))


void js_builtin_constant(js_runtime* rt, js_value* object, char* name, float64 number):
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, object, key, js_runtime_number(rt, number), 0, 0, 0)
	js_text_free(key)


void js_builtin_method(js_runtime* rt, js_value* object, char* name, js_host_receiver_function* callback, int code):
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, object, key, js_runtime_host_callable(rt, cast(void*, code), callback), 1, 0, 1)
	js_text_free(key)


void js_runtime_install_builtins(js_runtime* rt):
	js_value* math = js_runtime_alloc(rt, 5)
	js_builtin_method(rt, math, c"round", js_builtin_math, 1)
	js_builtin_method(rt, math, c"floor", js_builtin_math, 2)
	js_builtin_method(rt, math, c"ceil", js_builtin_math, 3)
	js_builtin_method(rt, math, c"trunc", js_builtin_math, 4)
	js_builtin_method(rt, math, c"abs", js_builtin_math, 5)
	js_builtin_method(rt, math, c"sign", js_builtin_math, 6)
	js_builtin_method(rt, math, c"sqrt", js_builtin_math, 7)
	js_builtin_method(rt, math, c"fround", js_builtin_math, 8)
	js_builtin_method(rt, math, c"max", js_builtin_math, 9)
	js_builtin_method(rt, math, c"min", js_builtin_math, 10)
	js_builtin_method(rt, math, c"hypot", js_builtin_math, 11)
	js_builtin_constant(rt, math, c"PI", 3.141592653589793)
	js_builtin_constant(rt, math, c"E", 2.718281828459045)
	js_builtin_constant(rt, math, c"SQRT2", 1.4142135623730951)
	js_runtime_set(rt, rt.global, c"Math", math)
	js_value* number = js_runtime_alloc(rt, 5)
	js_builtin_method(rt, number, c"isFinite", js_builtin_number, 1)
	js_builtin_method(rt, number, c"isInteger", js_builtin_number, 2)
	js_builtin_method(rt, number, c"isNaN", js_builtin_number, 3)
	js_builtin_method(rt, number, c"isSafeInteger", js_builtin_number, 4)
	js_builtin_constant(rt, number, c"MAX_SAFE_INTEGER", 9007199254740991.0)
	js_builtin_constant(rt, number, c"MIN_SAFE_INTEGER", -9007199254740991.0)
	js_builtin_constant(rt, number, c"EPSILON", 2.220446049250313e-16)
	js_builtin_constant(rt, number, c"NaN", js_builtin_nan())
	js_builtin_constant(rt, number, c"POSITIVE_INFINITY", float64_from_bits(0x7ff << 52))
	js_builtin_constant(rt, number, c"NEGATIVE_INFINITY", float64_from_bits((1 << 63) | (0x7ff << 52)))
	js_runtime_set(rt, rt.global, c"Number", number)
	js_value* date = js_runtime_alloc(rt, 5)
	js_builtin_method(rt, date, c"now", js_builtin_date_now, 0)
	js_runtime_set(rt, rt.global, c"Date", date)
