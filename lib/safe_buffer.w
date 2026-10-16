# Audited concrete storage for checked code. This module is not auto-imported.
# Public signatures describe every ownership/borrow effect. The compiler pins
# this exact implementation and exposes only the public operations below;
# callers cannot access metadata, construct these records or call raw helpers.
import structures.w_list

struct WIntBuffer:
	int capacity
	int length
	int* items

struct WByteString:
	int capacity
	int length
	byte* items

struct __w_safe_int_descriptor:
	int* data
	int length

struct __w_safe_byte_descriptor:
	byte* data
	int length


# No live view may coexist with an exclusive operation. Growth initializes
# only the prefix counted by length; every read checks that prefix.
void __w_int_buffer_ensure(WIntBuffer* buffer, int extra):
	int needed = __w_size_add(buffer.length, extra)
	if (needed <= buffer.capacity): return
	int capacity = __w_grow_capacity(buffer.capacity, needed)
	if (capacity < 8): capacity = 8
	int old_size = __w_size_mul(buffer.capacity, __word_size__)
	int new_size = __w_size_mul(capacity, __word_size__)
	buffer.items = cast(int*, __w_realloc(buffer.items, old_size, new_size))
	buffer.capacity = capacity


void __w_byte_string_ensure(WByteString* value, int extra):
	int needed = __w_size_add(value.length, extra)
	if (needed <= value.capacity): return
	int capacity = __w_grow_capacity(value.capacity, needed)
	if (capacity < 8): capacity = 8
	value.items = cast(byte*, __w_realloc(value.items, value.capacity, capacity))
	value.capacity = capacity


# Compiler-emitted destructors are the only checked entry to these helpers.
void __w_int_buffer_drop(WIntBuffer* buffer):
	free(buffer.items)
	free(buffer)


void __w_byte_string_drop(WByteString* value):
	free(value.items)
	free(value)


own WIntBuffer* int_buffer_new():
	WIntBuffer* buffer = new WIntBuffer
	buffer.capacity = 0
	buffer.length = 0
	buffer.items = 0
	return cast(own WIntBuffer*, buffer)


int int_buffer_length(ref WIntBuffer* value):
	WIntBuffer* buffer = cast(WIntBuffer*, value)
	return buffer.length


void int_buffer_push(refmut WIntBuffer* value, int element):
	WIntBuffer* buffer = cast(WIntBuffer*, value)
	__w_int_buffer_ensure(buffer, 1)
	buffer.items[buffer.length] = element
	buffer.length = buffer.length + 1


int int_buffer_get(ref WIntBuffer* value, int index):
	WIntBuffer* buffer = cast(WIntBuffer*, value)
	if ((index < 0) || (index >= buffer.length)):
		__w_list_index_trap(c"buffer index out of range", index, buffer.length)
	return buffer.items[index]


void int_buffer_set(refmut WIntBuffer* value, int index, int element):
	WIntBuffer* buffer = cast(WIntBuffer*, value)
	if ((index < 0) || (index >= buffer.length)):
		__w_list_index_trap(c"buffer index out of range", index, buffer.length)
	buffer.items[index] = element


int int_buffer_pop(refmut WIntBuffer* value):
	WIntBuffer* buffer = cast(WIntBuffer*, value)
	if (buffer.length == 0): __w_trap(c"pop from empty checked buffer")
	buffer.length = buffer.length - 1
	return buffer.items[buffer.length]


void int_buffer_clear(refmut WIntBuffer* value):
	WIntBuffer* buffer = cast(WIntBuffer*, value)
	buffer.length = 0


ref[a] int[] int_buffer_view(ref[a] WIntBuffer* value):
	WIntBuffer* buffer = cast(WIntBuffer*, value)
	__w_safe_int_descriptor descriptor
	descriptor.data = buffer.items
	descriptor.length = buffer.length
	int[] view = cast(int[], &descriptor)
	return view


own WByteString* byte_string_new():
	WByteString* value = new WByteString
	value.capacity = 0
	value.length = 0
	value.items = 0
	return cast(own WByteString*, value)


int byte_string_length(ref WByteString* borrowed):
	WByteString* value = cast(WByteString*, borrowed)
	return value.length


void byte_string_push(refmut WByteString* borrowed, byte element):
	WByteString* value = cast(WByteString*, borrowed)
	__w_byte_string_ensure(value, 1)
	value.items[value.length] = element
	value.length = value.length + 1


byte byte_string_get(ref WByteString* borrowed, int index):
	WByteString* value = cast(WByteString*, borrowed)
	if ((index < 0) || (index >= value.length)):
		__w_list_index_trap(c"byte string index out of range", index, value.length)
	return value.items[index]


void byte_string_set(refmut WByteString* borrowed, int index, byte element):
	WByteString* value = cast(WByteString*, borrowed)
	if ((index < 0) || (index >= value.length)):
		__w_list_index_trap(c"byte string index out of range", index, value.length)
	value.items[index] = element


byte byte_string_pop(refmut WByteString* borrowed):
	WByteString* value = cast(WByteString*, borrowed)
	if (value.length == 0): __w_trap(c"pop from empty checked byte string")
	value.length = value.length - 1
	return value.items[value.length]


void byte_string_clear(refmut WByteString* borrowed):
	WByteString* value = cast(WByteString*, borrowed)
	value.length = 0


ref[a] byte[] byte_string_view(ref[a] WByteString* borrowed):
	WByteString* value = cast(WByteString*, borrowed)
	__w_safe_byte_descriptor descriptor
	descriptor.data = value.items
	descriptor.length = value.length
	byte[] view = cast(byte[], &descriptor)
	return view


# Byte strings have explicit lengths, no terminator and no UTF-8 invariant.
# Embedded NULs are data. The exclusive/shared signature rejects self-append.
void byte_string_append(refmut WByteString* borrowed, ref byte[] view):
	WByteString* value = cast(WByteString*, borrowed)
	__w_byte_string_ensure(value, view.length)
	int i = 0
	while (i < view.length):
		value.items[value.length + i] = view[i]
		i = i + 1
	value.length = value.length + view.length


own WByteString* byte_string_from(ref byte[] view):
	WByteString* value = new WByteString
	value.capacity = 0
	value.length = 0
	value.items = 0
	__w_byte_string_ensure(value, view.length)
	int i = 0
	while (i < view.length):
		value.items[i] = view[i]
		i = i + 1
	value.length = view.length
	return cast(own WByteString*, value)
