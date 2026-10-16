# Bounded ECMA-262 IsLooselyEqual and its primitive conversions.
# https://tc39.es/ecma262/#sec-islooselyequal
import libs.extras.javascript.runtime

int js_equality_charge(js_runtime* rt, int length):
	if (rt.completion.status != 0): return 0
	if (length > rt.max_properties || length > rt.remaining):
		js_runtime_fail(rt, 5, c"JavaScript equality conversion limit")
		return 0
	rt.remaining = rt.remaining - length
	rt.completion.steps = rt.completion.steps + length
	return 1

int js_equality_digit(int unit):
	if (unit >= '0' && unit <= '9'): return unit - '0'
	if (unit >= 'a' && unit <= 'f'): return unit - 'a' + 10
	if (unit >= 'A' && unit <= 'F'): return unit - 'A' + 10
	return -1

# Powers-of-two radices are rounded once, using 53 retained significant bits,
# the following guard bit and all remaining bits as sticky. Repeated floating
# multiply/add would incorrectly round some long integer strings twice.
float64 js_equality_radix(js_text* text, int start, int end, int width):
	int significant = 0
	int bits = 0
	int guard = 0
	int sticky = 0
	int base = 1 << width
	for i in range(start, end):
		int digit = js_equality_digit(text.units[i])
		if (digit < 0 || digit >= base): return js_builtin_nan()
		for j in range(width):
			int bit = (digit >> (width - j - 1)) & 1
			if (significant == 0 && bit == 0): continue
			significant = significant + 1
			if (significant <= 53): bits = (bits << 1) | bit
			else if (significant == 54): guard = bit
			else: sticky = sticky | bit
	if (guard && (sticky || (bits & 1))): bits = bits + 1
	float64 result = cast(float64, bits)
	if (significant > 1024): return float64_from_bits(0x7ff << 52)
	for i in range(53, significant): result = result * 2.0
	return result

# StringNumericLiteral, not parseFloat's longest-prefix grammar. UTF-16 NUL,
# non-ASCII digits, separators, signed radix prefixes and trailing junk reject.
float64 js_equality_number(js_runtime* rt, js_text* text):
	if (js_equality_charge(rt, text.units.length) == 0): return 0.0
	int start = 0
	int end = text.units.length
	while (start < end && js_number_space(text.units[start])): start = start + 1
	while (end > start && js_number_space(text.units[end - 1])): end = end - 1
	if (start == end): return 0.0
	if (end - start > 2 && text.units[start] == '0'):
		int prefix = text.units[start + 1]
		if (prefix == 'x' || prefix == 'X'): return js_equality_radix(text, start + 2, end, 4)
		if (prefix == 'o' || prefix == 'O'): return js_equality_radix(text, start + 2, end, 3)
		if (prefix == 'b' || prefix == 'B'): return js_equality_radix(text, start + 2, end, 1)
	int cursor = start
	if (text.units[cursor] == '+' || text.units[cursor] == '-'): cursor = cursor + 1
	if (end - cursor == 8):
		char* infinity = c"Infinity"
		int matches = 1
		for i in range(8):
			if (text.units[cursor + i] != infinity[i]): matches = 0
		if (matches):
			int bits = 0x7ff << 52
			if (text.units[start] == '-'): bits = bits | (1 << 63)
			return float64_from_bits(bits)
	int digits = 0
	while (cursor < end && text.units[cursor] >= '0' && text.units[cursor] <= '9'):
		cursor = cursor + 1
		digits = digits + 1
	if (cursor < end && text.units[cursor] == '.'):
		cursor = cursor + 1
		while (cursor < end && text.units[cursor] >= '0' && text.units[cursor] <= '9'):
			cursor = cursor + 1
			digits = digits + 1
	if (digits == 0): return js_builtin_nan()
	if (cursor < end && (text.units[cursor] == 'e' || text.units[cursor] == 'E')):
		cursor = cursor + 1
		if (cursor < end && (text.units[cursor] == '+' || text.units[cursor] == '-')): cursor = cursor + 1
		int first = cursor
		while (cursor < end && text.units[cursor] >= '0' && text.units[cursor] <= '9'): cursor = cursor + 1
		if (first == cursor): return js_builtin_nan()
	if (cursor != end): return js_builtin_nan()
	string_builder* decimal = string_new()
	for i in range(start, end): string_append_char(decimal, text.units[i])
	int consumed = 0
	float64 result = parse_float64(decimal.data, &consumed)
	string_free(decimal)
	return result

# Compare directly to the bounded BigInt. Valid strings outside its range are
# unequal, not RangeErrors; invalid strings are unequal, not SyntaxErrors.
int js_equality_bigint_string(js_runtime* rt, js_value* value, js_text* text):
	if (js_equality_charge(rt, text.units.length) == 0): return 0
	int start = 0
	int end = text.units.length
	while (start < end && js_bigint_space(text.units[start])): start = start + 1
	while (end > start && js_bigint_space(text.units[end - 1])): end = end - 1
	if (start == end): return value.bigint_bits == 0
	int negative = 0
	int sign = 0
	if (text.units[start] == '+' || text.units[start] == '-'):
		sign = 1
		negative = text.units[start] == '-'
		start = start + 1
	int base = 10
	if (end - start > 1 && text.units[start] == '0'):
		int prefix = text.units[start + 1]
		if (prefix == 'x' || prefix == 'X'): base = 16
		if (prefix == 'o' || prefix == 'O'): base = 8
		if (prefix == 'b' || prefix == 'B'): base = 2
		if (base != 10):
			if (sign): return 0
			start = start + 2
	if (start == end): return 0
	int bits = 0
	int overflow = 0
	int mask = (1 << 32) - 1
	for i in range(start, end):
		int digit = js_equality_digit(text.units[i])
		if (digit < 0 || digit >= base): return 0
		if (overflow): continue
		int low = (bits & mask) * base + digit
		int high = ((bits >> 32) & mask) * base + (low >> 32)
		if (high > mask): overflow = 1
		bits = (high << 32) | (low & mask)
	if (overflow): return 0
	if (bits == 0): negative = 0
	return bits == js_bigint_magnitude(value) && negative == js_bigint_negative(value)

int js_equality_bigint_number(js_value* value, float64 number):
	if (js_builtin_finite(number) == 0 || js_builtin_trunc(number) != number): return 0
	if (number < -9223372036854775808.0 || number >= 18446744073709551616.0): return 0
	int bits = 0
	int high = number >= 9223372036854775808.0
	if (high): bits = cast(int, number - 9223372036854775808.0) | (1 << 63)
	else: bits = cast(int, number)
	return bits == value.bigint_bits && high == value.bigint_unsigned

# Ordinary default-hint conversion uses valueOf, then toString. No Symbol or
# exotic @@toPrimitive hooks exist in the current value model. Missing shared
# Object/Array/Function intrinsic defaults are explicit unsupported operations.
js_value* js_equality_primitive(js_runtime* rt, js_value* value):
	if (value.binary_kind != 0 || value.regexp != 0 || value.reactions != 0 || value.host_get != 0 || value.host_set != 0 || value.text_codec != 0):
		js_runtime_fail(rt, 6, c"exotic equality coercion is outside the runtime subset")
		return rt.undefined_value
	if (rt.depth >= rt.max_depth):
		js_runtime_fail(rt, 5, c"JavaScript equality conversion depth limit")
		return rt.undefined_value
	rt.depth = rt.depth + 1
	js_value* result = rt.undefined_value
	int converted = 0
	for i in range(2):
		if (js_runtime_compat_step(rt) == 0): break
		char* name = c"valueOf"
		if (i == 1): name = c"toString"
		js_value* method = js_runtime_get(rt, value, name)
		if (rt.completion.status != 0): break
		if (i == 1 && method.kind == 0):
			js_text* key = js_runtime_key(name)
			js_value* current = value
			int present = 0
			int depth = 0
			while (current != 0):
				if (depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
					js_runtime_fail(rt, 5, c"JavaScript equality prototype depth limit")
					break
				if (js_runtime_property(current, key) != 0):
					present = 1
					break
				current = current.prototype
				depth = depth + 1
			js_text_free(key)
			if (present == 0):
				js_runtime_fail(rt, 6, c"implicit prototype equality coercion is outside the runtime subset")
				break
		if (method.kind != 7 && method.kind != 9): continue
		list[js_value*] args = new list[js_value*]
		result = js_runtime_call_receiver(rt, method, value, args)
		__w_list_free(cast(__w_list*, args))
		if (rt.completion.status != 0): break
		if (result.kind <= 4 || result.kind == 10):
			converted = 1
			break
	if (converted == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"object conversion methods returned no primitive")
	rt.depth = rt.depth - 1
	return result

int js_equality_compare(js_runtime* rt, js_value* a, js_value* b):
	# Each conversion decreases the number of non-numeric/non-primitive inputs.
	# Bound the loop independently of user-code recursion (which uses depth).
	for iteration in range(8):
		if (js_runtime_compat_step(rt) == 0): return 0
		if (a.kind == b.kind):
			if (a.kind == 4 && js_equality_charge(rt, a.text.units.length) == 0): return 0
			return js_runtime_equal(a, b)
		if (a.kind <= 1 || b.kind <= 1): return a.kind <= 1 && b.kind <= 1
		if (js_runtime_object(a) && js_runtime_object(b)): return a == b
		if (a.kind == 2):
			a = js_runtime_number(rt, a.number)
			continue
		if (b.kind == 2):
			b = js_runtime_number(rt, b.number)
			continue
		if (js_runtime_object(a)):
			a = js_equality_primitive(rt, a)
			continue
		if (js_runtime_object(b)):
			b = js_equality_primitive(rt, b)
			continue
		if (a.kind == 4 && b.kind == 3):
			float64 number = js_equality_number(rt, a.text)
			return f64is_nan(number) == 0 && f64is_nan(b.number) == 0 && number == b.number
		if (a.kind == 3 && b.kind == 4):
			float64 number = js_equality_number(rt, b.text)
			return f64is_nan(number) == 0 && f64is_nan(a.number) == 0 && a.number == number
		if (a.kind == 10 && b.kind == 4): return js_equality_bigint_string(rt, a, b.text)
		if (a.kind == 4 && b.kind == 10): return js_equality_bigint_string(rt, b, a.text)
		if (a.kind == 10 && b.kind == 3): return js_equality_bigint_number(a, b.number)
		if (a.kind == 3 && b.kind == 10): return js_equality_bigint_number(b, a.number)
		return 0
	js_runtime_fail(rt, 5, c"JavaScript equality conversion limit")
	return 0

js_value* js_runtime_loose_equal(js_runtime* rt, js_value* a, js_value* b, int negate):
	int result = js_equality_compare(rt, a, b)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_boolean(rt, result != negate)
