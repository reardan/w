/*
Bounded binary storage for the 64-bit JS runtime. kind: 1 ArrayBuffer,
2 Uint8Array, 3 Float32Array, 4 DataView. All lengths stored in bytes.
Views trace their buffer, never own storage. Host wraps borrow storage: detach
before replacing/freeing it. Returned pointers are borrowed until detach/free;
root the buffer or view across collection. No implicit collection occurs.
*/
import libs.extras.javascript.runtime


int js_runtime_binary_byte_length(js_runtime* rt, js_value* value):
	if (value == 0 || value.owner != rt || value.binary_kind == 0): return 0
	if (value.binary_kind == 1):
		if (value.binary_detached): return 0
	else if (value.binary_buffer.binary_detached): return 0
	return value.binary_length


byte* js_runtime_binary_data(js_runtime* rt, js_value* value):
	if (value == 0 || value.owner != rt || value.binary_kind == 0): return 0
	if (value.binary_kind == 1):
		if (value.binary_detached): return 0
		return value.binary_bytes
	if (value.binary_buffer.binary_detached): return 0
	return value.binary_buffer.binary_bytes + value.binary_offset


void js_binary_range(js_runtime* rt):
	js_runtime_fail(rt, 2, c"binary range out of bounds")
	if (rt.completion.value != rt.undefined_value):
		rt.completion.value.intrinsic_error_name = c"RangeError"
		js_text* name = js_runtime_key(c"RangeError")
		js_value* label = js_runtime_string(rt, name)
		js_text_free(name)
		name = js_runtime_key(c"name")
		js_runtime_put(rt, rt.completion.value, name, label)
		js_text_free(name)


int js_runtime_array_buffer_detach(js_runtime* rt, js_value* buffer):
	if (buffer == 0 || buffer.owner != rt || buffer.binary_kind != 1): return 0
	if (buffer.binary_owned):
		rt.binary_bytes_used = rt.binary_bytes_used - buffer.binary_length
		free(buffer.binary_bytes)
	buffer.binary_bytes = 0
	buffer.binary_length = 0
	buffer.binary_owned = 0
	buffer.binary_detached = 1
	return 1


js_value* js_binary_get(void* runtime, void* context, js_value* receiver, js_text* key);
int js_binary_set(void* runtime, void* context, js_value* receiver, js_text* key, js_value* value);
void js_binary_methods(js_runtime* rt, js_value* value);


js_value* js_runtime_array_buffer_wrap(js_runtime* rt, byte* data, int length):
	if (length < 0 || (data == 0 && length != 0)):
		js_binary_range(rt)
		return rt.undefined_value
	js_value* value = js_runtime_alloc(rt, 5)
	if (value == rt.undefined_value): return value
	value.binary_kind = 1
	value.binary_bytes = data
	value.binary_length = length
	js_runtime_set_host_hooks(rt, value, 0, js_binary_get, js_binary_set)
	return value


js_value* js_runtime_array_buffer(js_runtime* rt, int length):
	if (length < 0):
		js_binary_range(rt)
		return rt.undefined_value
	if (length > rt.max_binary_bytes - rt.binary_bytes_used):
		js_runtime_fail(rt, 5, c"JavaScript binary byte limit")
		return rt.undefined_value
	js_value* value = js_runtime_array_buffer_wrap(rt, 0, 0)
	if (value == rt.undefined_value): return value
	int allocation = length
	if (allocation == 0): allocation = 1
	value.binary_bytes = cast(byte*, malloc(allocation))
	if (value.binary_bytes == 0):
		js_runtime_fail(rt, 5, c"JavaScript binary allocation failed")
		return rt.undefined_value
	for i in range(allocation): value.binary_bytes[i] = 0
	value.binary_length = length
	value.binary_owned = 1
	rt.binary_bytes_used = rt.binary_bytes_used + length
	return value


js_value* js_runtime_array_buffer_copy(js_runtime* rt, byte* data, int length):
	if (data == 0 && length != 0):
		js_binary_range(rt)
		return rt.undefined_value
	js_value* value = js_runtime_array_buffer(rt, length)
	if (value != rt.undefined_value):
		for i in range(length): value.binary_bytes[i] = data[i]
	return value


js_value* js_runtime_binary_view(js_runtime* rt, int kind, js_value* buffer, int offset, int length):
	if (buffer == 0 || buffer.owner != rt || buffer.binary_kind != 1 || buffer.binary_detached || kind < 2 || kind > 4):
		js_runtime_fail(rt, 2, c"invalid binary buffer")
		return rt.undefined_value
	int width = 1
	if (kind == 3): width = 4
	if (offset < 0 || offset > buffer.binary_length || offset % width != 0 || length < -1):
		js_binary_range(rt)
		return rt.undefined_value
	int available = buffer.binary_length - offset
	if (length == -1):
		if (available % width != 0):
			js_binary_range(rt)
			return rt.undefined_value
		length = available / width
	if (length > available / width):
		js_binary_range(rt)
		return rt.undefined_value
	js_value* view = js_runtime_alloc(rt, 5)
	if (view == rt.undefined_value): return view
	view.binary_kind = kind
	view.binary_buffer = buffer
	view.binary_offset = offset
	view.binary_length = length * width
	js_binary_methods(rt, view)
	js_runtime_set_host_hooks(rt, view, 0, js_binary_get, js_binary_set)
	if (rt.completion.status != 0): return rt.undefined_value
	return view


# Bounded primitive conversion. User-defined ToPrimitive is outside the subset.
float64 js_binary_number(js_runtime* rt, js_value* value):
	if (value.kind == 3 || value.kind == 2): return value.number
	if (value.kind == 1): return 0.0
	if (value.kind == 0): return float64_from_bits((0x7ff << 52) | 1)
	js_runtime_fail(rt, 6, c"binary numeric coercion outside runtime subset")
	return 0.0


int js_binary_index(js_runtime* rt, list[js_value*] args, int index, int fallback):
	if (index >= args.length || args[index].kind == 0): return fallback
	float64 number = js_binary_number(rt, args[index])
	if (f64is_nan(number)): return 0
	if (number < 0.0 || number > 2147483647.0):
		js_binary_range(rt)
		return 0
	return cast(int, number)


int js_binary_uint(float64 number, int bits):
	int raw = float64_bits(number)
	int exponent = ((raw >> 52) & 2047) - 1023
	if (exponent < 0 || exponent == 1024): return 0
	int mantissa = (raw & ((1 << 52) - 1)) | (1 << 52)
	int shift = exponent - 52
	if (shift >= bits): return 0
	int result = 0
	if (shift >= 0): result = mantissa << shift
	else: result = mantissa >> (0 - shift)
	if (raw < 0): result = 0 - result
	return result & ((1 << bits) - 1)


int js_binary_load(byte* data, int width, int little):
	int bits = 0
	for i in range(width):
		int shift = i * 8
		if (little == 0): shift = (width - i - 1) * 8
		bits = bits | ((cast(int, data[i]) & 255) << shift)
	return bits


void js_binary_store(byte* data, int width, int little, int bits):
	for i in range(width):
		int shift = i * 8
		if (little == 0): shift = (width - i - 1) * 8
		data[i] = cast(byte, (bits >> shift) & 255)


float64 js_binary_element(js_runtime* rt, js_value* view, int index):
	byte* data = js_runtime_binary_data(rt, view)
	if (view.binary_kind == 2): return cast(float64, cast(int, data[index]) & 255)
	int32 bits = cast(int32, js_binary_load(data + index * 4, 4, 1))
	return cast(float64, *cast(float*, &bits))


void js_binary_element_set(js_runtime* rt, js_value* view, int index, float64 number):
	byte* data = js_runtime_binary_data(rt, view)
	if (view.binary_kind == 2): data[index] = cast(byte, js_binary_uint(number, 8))
	else:
		float rounded = cast(float, number)
		js_binary_store(data + index * 4, 4, 1, cast(int, *cast(int32*, &rounded)))


# Negative integer names are canonical numeric keys, never ordinary properties.
int js_binary_negative_index(js_text* key):
	if (key.units.length < 2 || key.units[0] != '-'): return 0
	if (key.units.length > 2 && key.units[1] == '0'): return 0
	for i in range(1, key.units.length):
		if (key.units[i] < '0' || key.units[i] > '9'): return 0
	return 1


js_value* js_binary_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.binary_kind == 0): return 0
	int length = js_runtime_binary_byte_length(rt, receiver)
	if (js_runtime_key_is(key, c"buffer") && receiver.binary_kind > 1): return receiver.binary_buffer
	if (js_runtime_key_is(key, c"byteLength")): return js_runtime_number(rt, cast(float64, length))
	if (js_runtime_key_is(key, c"byteOffset") && receiver.binary_kind > 1):
		int offset = receiver.binary_offset
		if (receiver.binary_buffer.binary_detached): offset = 0
		return js_runtime_number(rt, cast(float64, offset))
	if (receiver.binary_kind == 2 || receiver.binary_kind == 3):
		int width = 1
		if (receiver.binary_kind == 3): width = 4
		if (js_runtime_key_is(key, c"length")): return js_runtime_number(rt, cast(float64, length / width))
		int index = js_runtime_array_index(key)
		if (index >= 0):
			if (index >= length / width): return rt.undefined_value
			return js_runtime_number(rt, js_binary_element(rt, receiver, index))
		if (js_binary_negative_index(key) || js_runtime_key_is(key, c"NaN") || js_runtime_key_is(key, c"Infinity") || js_runtime_key_is(key, c"-Infinity")): return rt.undefined_value
	return 0


int js_binary_set(void* runtime, void* context, js_value* receiver, js_text* key, js_value* value):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_runtime_key_is(key, c"byteLength") || js_runtime_key_is(key, c"byteOffset") || js_runtime_key_is(key, c"buffer") || js_runtime_key_is(key, c"length")): return 1
	if (receiver.binary_kind == 2 || receiver.binary_kind == 3):
		int index = js_runtime_array_index(key)
		if (index >= 0):
			int width = 1
			if (receiver.binary_kind == 3): width = 4
			if (index < js_runtime_binary_byte_length(rt, receiver) / width):
				float64 number = js_binary_number(rt, value)
				if (rt.completion.status == 0): js_binary_element_set(rt, receiver, index, number)
			return 1
		if (js_binary_negative_index(key) || js_runtime_key_is(key, c"NaN") || js_runtime_key_is(key, c"Infinity") || js_runtime_key_is(key, c"-Infinity")): return 1
	return 0


js_value* js_binary_requires_new(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_runtime_fail(rt, 2, c"binary constructor requires new")
	return rt.undefined_value


js_value* js_runtime_binary_construct(js_runtime* rt, int kind, list[js_value*] args):
	if (kind == 1):
		int length = js_binary_index(rt, args, 0, 0)
		if (rt.completion.status != 0): return rt.undefined_value
		return js_runtime_array_buffer(rt, length)
	if (args.length > 0 && args[0].binary_kind == 1):
		int offset = js_binary_index(rt, args, 1, 0)
		int length = js_binary_index(rt, args, 2, -1)
		if (rt.completion.status != 0): return rt.undefined_value
		return js_runtime_binary_view(rt, kind, args[0], offset, length)
	if (kind == 4):
		js_runtime_fail(rt, 2, c"DataView requires ArrayBuffer")
		return rt.undefined_value
	int length = 0
	js_value* source = 0
	if (args.length > 0 && (args[0].kind == 6 || args[0].binary_kind == 2 || args[0].binary_kind == 3)):
		source = args[0]
		length = source.array_length
		if (source.binary_kind != 0):
			length = js_runtime_binary_byte_length(rt, source)
			if (source.binary_kind == 3): length = length / 4
	else: length = js_binary_index(rt, args, 0, 0)
	int width = 1
	if (kind == 3): width = 4
	if (rt.completion.status != 0): return rt.undefined_value
	if (length > rt.max_binary_bytes / width):
		js_runtime_fail(rt, 5, c"JavaScript binary byte limit")
		return rt.undefined_value
	js_value* buffer = js_runtime_array_buffer(rt, length * width)
	if (buffer == rt.undefined_value): return buffer
	js_value* view = js_runtime_binary_view(rt, kind, buffer, 0, length)
	if (view == rt.undefined_value): return view
	if (source != 0):
		for i in range(length):
			float64 number = 0.0
			if (source.binary_kind != 0): number = js_binary_element(rt, source, i)
			else:
				char* key = itoa(i)
				number = js_binary_number(rt, js_runtime_get(rt, source, key))
				free(key)
			if (rt.completion.status != 0): return rt.undefined_value
			js_binary_element_set(rt, view, i, number)
	return view


int js_binary_relative(js_runtime* rt, list[js_value*] args, int index, int fallback, int length):
	if (index >= args.length || args[index].kind == 0): return fallback
	float64 number = js_binary_number(rt, args[index])
	if (f64is_nan(number)): return 0
	if (number < 0.0):
		if (number <= cast(float64, 0 - length)): return 0
		return length + cast(int, number)
	if (number >= cast(float64, length)): return length
	return cast(int, number)


js_value* js_binary_subarray(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if ((receiver.binary_kind != 2 && receiver.binary_kind != 3) || receiver.binary_buffer.binary_detached):
		js_runtime_fail(rt, 2, c"invalid typed array receiver")
		return rt.undefined_value
	int width = 1
	if (receiver.binary_kind == 3): width = 4
	int length = receiver.binary_length / width
	int start = js_binary_relative(rt, args, 0, 0, length)
	int end = js_binary_relative(rt, args, 1, length, length)
	if (end < start): end = start
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_binary_view(rt, receiver.binary_kind, receiver.binary_buffer, receiver.binary_offset + start * width, end - start)


js_value* js_binary_typed_set(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if ((receiver.binary_kind != 2 && receiver.binary_kind != 3) || receiver.binary_buffer.binary_detached || args.length == 0):
		js_runtime_fail(rt, 2, c"invalid typed array receiver or source")
		return rt.undefined_value
	js_value* source = args[0]
	if (source.kind != 6 && source.binary_kind != 2 && source.binary_kind != 3):
		js_runtime_fail(rt, 2, c"invalid typed array source")
		return rt.undefined_value
	if (source.binary_kind != 0 && source.binary_buffer.binary_detached):
		js_runtime_fail(rt, 2, c"detached typed array source")
		return rt.undefined_value
	int length = source.array_length
	if (source.binary_kind != 0):
		length = source.binary_length
		if (source.binary_kind == 3): length = length / 4
	int width = 1
	if (receiver.binary_kind == 3): width = 4
	int offset = js_binary_index(rt, args, 1, 0)
	if (rt.completion.status != 0): return rt.undefined_value
	if (offset > receiver.binary_length / width || length > receiver.binary_length / width - offset):
		js_binary_range(rt)
		return rt.undefined_value
	# Snapshot typed sources to preserve overlap; bound temporary storage too.
	if (length > (rt.max_binary_bytes - rt.binary_bytes_used) / 8):
		js_runtime_fail(rt, 5, c"JavaScript binary copy byte limit")
		return rt.undefined_value
	float64* snapshot = cast(float64*, malloc(length * 8 + 1))
	if (snapshot == 0):
		js_runtime_fail(rt, 5, c"JavaScript binary allocation failed")
		return rt.undefined_value
	rt.binary_bytes_used = rt.binary_bytes_used + length * 8
	for i in range(length):
		if (source.binary_kind != 0): snapshot[i] = js_binary_element(rt, source, i)
		else:
			char* key = itoa(i)
			snapshot[i] = js_binary_number(rt, js_runtime_get(rt, source, key))
			free(key)
		if (rt.completion.status != 0): break
	if (rt.completion.status == 0 && receiver.binary_buffer.binary_detached == 0):
		for i in range(length): js_binary_element_set(rt, receiver, offset + i, snapshot[i])
	rt.binary_bytes_used = rt.binary_bytes_used - length * 8
	free(snapshot)
	return rt.undefined_value


# Method code: width in low nibble, signed=16, float=32, write=64, BigInt=128.
js_value* js_binary_dataview(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.binary_kind != 4 || receiver.binary_buffer.binary_detached):
		js_runtime_fail(rt, 2, c"invalid DataView receiver")
		return rt.undefined_value
	int code = cast(int, context)
	int width = code & 15
	int write = code & 64
	int offset = js_binary_index(rt, args, 0, 0)
	if (rt.completion.status != 0): return rt.undefined_value
	if (offset > receiver.binary_length || width > receiver.binary_length - offset):
		js_binary_range(rt)
		return rt.undefined_value
	int endian_arg = 1
	if (write): endian_arg = 2
	int little = 0
	if (args.length > endian_arg): little = js_runtime_truth(args[endian_arg])
	byte* data = js_runtime_binary_data(rt, receiver) + offset
	if (code & 128):
		if (write):
			js_value* source = rt.undefined_value
			if (args.length > 1): source = args[1]
			js_value* value = js_runtime_bigint_convert(rt, source, 0)
			if (rt.completion.status != 0): return rt.undefined_value
			js_binary_store(data, 8, little, value.bigint_bits)
			return rt.undefined_value
		int bits = js_binary_load(data, 8, little)
		if (code & 16): return js_runtime_bigint_i64(rt, bits)
		return js_runtime_bigint_u64(rt, bits)
	if (write):
		js_value* value = rt.undefined_value
		if (args.length > 1): value = args[1]
		float64 number = js_binary_number(rt, value)
		if (rt.completion.status != 0): return rt.undefined_value
		int bits = 0
		if (code & 32):
			if (width == 8): bits = float64_bits(number)
			else:
				float rounded = cast(float, number)
				bits = cast(int, *cast(int32*, &rounded))
		else: bits = js_binary_uint(number, width * 8)
		js_binary_store(data, width, little, bits)
		return rt.undefined_value
	int bits = js_binary_load(data, width, little)
	float64 number = 0.0
	if (code & 32):
		if (width == 8): number = float64_from_bits(bits)
		else:
			int32 word = cast(int32, bits)
			number = cast(float64, *cast(float*, &word))
	else:
		if ((code & 16) && (bits & (1 << (width * 8 - 1)))): bits = bits - (1 << (width * 8))
		number = cast(float64, bits)
	return js_runtime_number(rt, number)


void js_binary_method(js_runtime* rt, js_value* value, char* name, int code):
	js_runtime_set(rt, value, name, js_runtime_host_callable(rt, cast(void*, code), js_binary_dataview))


void js_binary_methods(js_runtime* rt, js_value* value):
	if (value.binary_kind == 2 || value.binary_kind == 3):
		js_runtime_set(rt, value, c"subarray", js_runtime_host_callable(rt, 0, js_binary_subarray))
		js_runtime_set(rt, value, c"set", js_runtime_host_callable(rt, 0, js_binary_typed_set))
		int width = 1
		if (value.binary_kind == 3): width = 4
		js_runtime_set(rt, value, c"BYTES_PER_ELEMENT", js_runtime_number(rt, cast(float64, width)))
	else if (value.binary_kind == 4):
		js_binary_method(rt, value, c"getBigUint64", 136)
		js_binary_method(rt, value, c"getBigInt64", 152)
		js_binary_method(rt, value, c"setBigUint64", 200)
		js_binary_method(rt, value, c"setBigInt64", 216)
		js_binary_method(rt, value, c"getUint8", 1)
		js_binary_method(rt, value, c"getInt8", 17)
		js_binary_method(rt, value, c"getUint16", 2)
		js_binary_method(rt, value, c"getInt16", 18)
		js_binary_method(rt, value, c"getUint32", 4)
		js_binary_method(rt, value, c"getInt32", 20)
		js_binary_method(rt, value, c"getFloat32", 36)
		js_binary_method(rt, value, c"getFloat64", 40)
		js_binary_method(rt, value, c"setUint8", 65)
		js_binary_method(rt, value, c"setInt8", 81)
		js_binary_method(rt, value, c"setUint16", 66)
		js_binary_method(rt, value, c"setInt16", 82)
		js_binary_method(rt, value, c"setUint32", 68)
		js_binary_method(rt, value, c"setInt32", 84)
		js_binary_method(rt, value, c"setFloat32", 100)
		js_binary_method(rt, value, c"setFloat64", 104)


js_value* js_binary_is_view(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	return js_runtime_boolean(rt, args.length > 0 && args[0].binary_kind >= 2 && args[0].binary_kind <= 4)


void js_runtime_install_text_codecs(js_runtime* rt);


void js_runtime_install_binary(js_runtime* rt):
	js_runtime_install_text_codecs(rt)
	for kind in range(1, 5):
		char* name = c"ArrayBuffer"
		if (kind == 2): name = c"Uint8Array"
		if (kind == 3): name = c"Float32Array"
		if (kind == 4): name = c"DataView"
		js_value* constructor = js_runtime_host_callable(rt, 0, js_binary_requires_new)
		if (constructor == rt.undefined_value): return
		constructor.binary_constructor = kind
		if (kind == 1): js_runtime_set(rt, constructor, c"isView", js_runtime_host_callable(rt, 0, js_binary_is_view))
		if (kind == 2 || kind == 3):
			int width = 1
			if (kind == 3): width = 4
			js_runtime_set(rt, constructor, c"BYTES_PER_ELEMENT", js_runtime_number(rt, cast(float64, width)))
		js_runtime_set(rt, rt.global, name, constructor)


import libs.extras.javascript.text_codecs
