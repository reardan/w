# Audited generic pointer-free buffers. Each specialization is a distinct
# checked owner. Its metadata and byte storage are private to this module;
# borrowed API contracts cover all access and every invalidating mutation.
import structures.w_list


struct WBuffer[T]:
	int capacity
	int length
	T* items


# All specializations have this descriptor layout. The compiler only emits
# this helper for a sealed WBuffer specialization with pointer-free elements.
struct __WBufferHeader:
	int capacity
	int length
	void* items


struct __WBufferView:
	void* data
	int length


void __w_buffer_drop(void* value):
	__WBufferHeader* buffer = cast(__WBufferHeader*, value)
	free(buffer.items)
	free(buffer)


void __w_buffer_ensure[T](WBuffer[T]* buffer):
	int needed = __w_size_add(buffer.length, 1)
	if needed <= buffer.capacity: return
	int capacity = __w_grow_capacity(buffer.capacity, needed)
	if capacity < 8: capacity = 8
	int old_size = __w_size_mul(buffer.capacity, sizeof(T))
	int new_size = __w_size_mul(capacity, sizeof(T))
	buffer.items = cast(T*, __w_realloc(cast(void*, buffer.items), old_size, new_size))
	buffer.capacity = capacity


own WBuffer[T]* buffer_new[T]():
	WBuffer[T]* buffer = cast(WBuffer[T]*, __w_new_object(sizeof(WBuffer[T])))
	buffer.capacity = 0
	buffer.length = 0
	buffer.items = 0
	return cast(own WBuffer[T]*, buffer)


int buffer_length[T](ref WBuffer[T]* value):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	return buffer.length


void buffer_push[T](refmut WBuffer[T]* value, T element):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	__w_buffer_ensure[T](buffer)
	buffer.items[buffer.length] = element
	buffer.length += 1


T buffer_get[T](ref WBuffer[T]* value, int index):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	if index < 0 || index >= buffer.length:
		__w_list_index_trap(c"generic buffer index out of range", index, buffer.length)
	return buffer.items[index]


void buffer_set[T](refmut WBuffer[T]* value, int index, T element):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	if index < 0 || index >= buffer.length:
		__w_list_index_trap(c"generic buffer index out of range", index, buffer.length)
	buffer.items[index] = element


T buffer_pop[T](refmut WBuffer[T]* value):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	if buffer.length == 0: __w_trap(c"pop from empty generic buffer")
	buffer.length -= 1
	return buffer.items[buffer.length]


void buffer_clear[T](refmut WBuffer[T]* value):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	buffer.length = 0


ref[a] T[] buffer_view[T](ref[a] WBuffer[T]* value):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	__WBufferView descriptor
	descriptor.data = buffer.items
	descriptor.length = buffer.length
	T[] view = cast(T[], &descriptor)
	return view


refmut[a] T[] buffer_view_mut[T](refmut[a] WBuffer[T]* value):
	WBuffer[T]* buffer = cast(WBuffer[T]*, value)
	__WBufferView descriptor
	descriptor.data = buffer.items
	descriptor.length = buffer.length
	T[] view = cast(T[], &descriptor)
	return view
