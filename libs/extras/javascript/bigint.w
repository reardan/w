/*
Bounded BigInt primitive: mathematical values [-2^63, 2^64-1], distinct from
Number. bigint_bits stores exact two's-complement bits; bigint_unsigned is set
only for positive values >=2^63. No floating-point storage or implicit numeric
coercion. Out-of-range conversions fail; this is not arbitrary-precision JS.
*/
import libs.extras.javascript.runtime


js_value* js_runtime_bigint_i64(js_runtime* rt, int bits):
	js_value* value = js_runtime_alloc(rt, 10)
	if (value != rt.undefined_value): value.bigint_bits = bits
	return value


js_value* js_runtime_bigint_u64(js_runtime* rt, int bits):
	js_value* value = js_runtime_bigint_i64(rt, bits)
	if (value != rt.undefined_value): value.bigint_unsigned = bits < 0
	return value


# Explicit wasm/DataView modulo-2^64 crossing. Never accepts a JS Number.
int js_runtime_bigint_bits(js_runtime* rt, js_value* value, int* out):
	if (value == 0 || value.owner != rt || value.kind != 10 || out == 0):
		js_runtime_fail(rt, 2, c"i64 requires BigInt")
		return 0
	*out = value.bigint_bits
	return 1


void js_bigint_error(js_runtime* rt, char* name, char* message):
	js_runtime_fail(rt, 2, message)
	if (rt.completion.value == rt.undefined_value): return
	rt.completion.value.intrinsic_error_name = name
	js_text* text = js_runtime_key(name)
	js_value* label = js_runtime_string(rt, text)
	js_text_free(text)
	text = js_runtime_key(c"name")
	js_runtime_put(rt, rt.completion.value, text, label)
	js_text_free(text)


int js_bigint_space(int unit):
	return unit == 32 || (unit >= 9 && unit <= 13) || unit == 160 || unit == 5760 || (unit >= 8192 && unit <= 8202) || unit == 8232 || unit == 8233 || unit == 8239 || unit == 8287 || unit == 12288 || unit == 65279


js_value* js_bigint_parse(js_runtime* rt, js_text* text):
	if (text.units.length > rt.max_properties):
		js_runtime_fail(rt, 5, c"BigInt text limit")
		return rt.undefined_value
	int start = 0
	int end = text.units.length
	while (start < end && js_bigint_space(text.units[start])): start = start + 1
	while (end > start && js_bigint_space(text.units[end - 1])): end = end - 1
	if (start == end): return js_runtime_bigint_i64(rt, 0)
	int negative = 0
	int sign = 0
	if (text.units[start] == '-' || text.units[start] == '+'):
		sign = 1
		negative = text.units[start] == '-'
		start = start + 1
	int base = 10
	if (start + 1 < end && text.units[start] == '0'):
		int prefix = text.units[start + 1]
		if (prefix == 'x' || prefix == 'X'): base = 16
		if (prefix == 'o' || prefix == 'O'): base = 8
		if (prefix == 'b' || prefix == 'B'): base = 2
		if (base != 10):
			if (sign):
				js_bigint_error(rt, c"SyntaxError", c"invalid BigInt string")
				return rt.undefined_value
			start = start + 2
	if (start == end):
		js_bigint_error(rt, c"SyntaxError", c"invalid BigInt string")
		return rt.undefined_value
	int bits = 0
	int mask = (1 << 32) - 1
	for i in range(start, end):
		int digit = -1
		if (text.units[i] >= '0' && text.units[i] <= '9'): digit = text.units[i] - '0'
		if (text.units[i] >= 'a' && text.units[i] <= 'f'): digit = text.units[i] - 'a' + 10
		if (text.units[i] >= 'A' && text.units[i] <= 'F'): digit = text.units[i] - 'A' + 10
		if (digit < 0 || digit >= base):
			js_bigint_error(rt, c"SyntaxError", c"invalid BigInt string")
			return rt.undefined_value
		int low = (bits & mask) * base + digit
		int high = ((bits >> 32) & mask) * base + (low >> 32)
		if (high > mask):
			js_bigint_error(rt, c"RangeError", c"BigInt exceeds bounded 64-bit range")
			return rt.undefined_value
		bits = (high << 32) | (low & mask)
	if (negative):
		if (bits < 0 && bits != (1 << 63)):
			js_bigint_error(rt, c"RangeError", c"BigInt exceeds bounded 64-bit range")
			return rt.undefined_value
		return js_runtime_bigint_i64(rt, 0 - bits)
	return js_runtime_bigint_u64(rt, bits)


js_value* js_runtime_bigint_convert(js_runtime* rt, js_value* value, int allow_number):
	if (value == 0 || value.owner != rt):
		js_runtime_fail(rt, 2, c"foreign BigInt conversion value")
		return rt.undefined_value
	if (value.kind == 10): return value
	if (value.kind == 2): return js_runtime_bigint_i64(rt, cast(int, value.number))
	if (value.kind == 4): return js_bigint_parse(rt, value.text)
	if (allow_number && value.kind == 3):
		float64 number = value.number
		if (js_builtin_finite(number) == 0 || js_builtin_trunc(number) != number || number < -9223372036854775808.0 || number >= 18446744073709551616.0):
			js_bigint_error(rt, c"RangeError", c"BigInt requires an integer in bounded 64-bit range")
			return rt.undefined_value
		if (number >= 9223372036854775808.0): return js_runtime_bigint_u64(rt, cast(int, number - 9223372036854775808.0) | (1 << 63))
		return js_runtime_bigint_i64(rt, cast(int, number))
	js_runtime_fail(rt, 2, c"value cannot convert to BigInt")
	return rt.undefined_value


js_value* js_bigint_literal(js_runtime* rt, char* raw):
	js_text* text = js_text_new()
	for i in range(strlen(raw)):
		if (raw[i] != '_'): text.units.push(cast(int, raw[i]))
	js_value* value = js_bigint_parse(rt, text)
	js_text_free(text)
	return value


js_value* js_bigint_negate(js_runtime* rt, js_value* value):
	int bits = value.bigint_bits
	if (value.bigint_unsigned && bits != (1 << 63)):
		js_bigint_error(rt, c"RangeError", c"BigInt exceeds bounded 64-bit range")
		return rt.undefined_value
	if (value.bigint_unsigned || bits >= 0): return js_runtime_bigint_i64(rt, 0 - bits)
	return js_runtime_bigint_u64(rt, 0 - bits)


char* js_bigint_text(js_value* value):
	int bits = value.bigint_bits
	int negative = bits < 0 && value.bigint_unsigned == 0
	if (negative): bits = 0 - bits
	char[32] digits
	int count = 0
	int mask = (1 << 32) - 1
	while (bits != 0 || count == 0):
		int high = (bits >> 32) & mask
		int remainder = ((high % 10) << 32) | (bits & mask)
		digits[count] = cast(char, '0' + remainder % 10)
		count = count + 1
		bits = ((high / 10) << 32) | (remainder / 10)
	char* result = cast(char*, malloc(count + negative + 1))
	if (negative): result[0] = '-'
	for i in range(count): result[i + negative] = digits[count - i - 1]
	result[count + negative] = 0
	return result


js_value* js_bigint_constructor(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	return js_runtime_bigint_convert(rt, value, 1)


void js_runtime_install_bigint(js_runtime* rt):
	js_runtime_set(rt, rt.global, c"BigInt", js_runtime_host_callable(rt, 0, js_bigint_constructor))
