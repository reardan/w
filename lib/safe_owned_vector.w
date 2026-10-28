# Audited unique-pointer storage. Every specialization records its generated
# element destructor; raw slots are private and never duplicate ownership.
import structures.w_list


type __WOwnedBufferDrop = fn(void*) -> void


struct WOwnedBuffer[T]:
	int capacity
	int length
	int maximum
	T** items
	__WOwnedBufferDrop* drop


struct __WOwnedBufferHeader:
	int capacity
	int length
	int maximum
	void** items
	__WOwnedBufferDrop* drop


void __w_owned_buffer_drop_element[T](void* value):
	own T* owned = cast(own T*, value)


void __w_owned_buffer_clear(__WOwnedBufferHeader* buffer):
	while buffer.length > 0:
		buffer.length -= 1
		void* element = buffer.items[buffer.length]
		buffer.items[buffer.length] = 0
		buffer.drop(element)


void __w_owned_buffer_drop(void* value):
	__WOwnedBufferHeader* buffer = cast(__WOwnedBufferHeader*, value)
	__w_owned_buffer_clear(buffer)
	free(cast(void*, buffer.items))
	free(buffer)


# A failed growth leaves all descriptor fields and old storage untouched.
# maximum bounds insertion independently of spare capacity. Size overflow
# and allocator failure have the same recoverable result.
int __w_owned_buffer_room(__WOwnedBufferHeader* buffer):
	if ((buffer.maximum >= 0) && (buffer.length >= buffer.maximum)): return 0
	int max_slots = __w_word_max() / __word_size__
	if buffer.length >= max_slots: return 0
	int needed = buffer.length + 1
	if needed <= buffer.capacity: return 1
	int capacity = __w_grow_capacity(buffer.capacity, needed)
	if capacity < 8: capacity = 8
	if capacity > max_slots: capacity = max_slots
	if ((buffer.maximum >= 0) && (capacity > buffer.maximum)): capacity = buffer.maximum
	void** items = cast(void**, malloc(capacity * __word_size__))
	if items == 0: return 0
	for i in range(buffer.length): items[i] = buffer.items[i]
	free(cast(void*, buffer.items))
	buffer.items = items
	buffer.capacity = capacity
	return 1


own WOwnedBuffer[T]* owned_buffer_new[T](int maximum):
	if maximum < -1: __w_trap(c"invalid owned buffer maximum")
	WOwnedBuffer[T]* buffer = cast(WOwnedBuffer[T]*, __w_new_object(sizeof(WOwnedBuffer[T])))
	buffer.capacity = 0
	buffer.length = 0
	buffer.maximum = maximum
	buffer.items = 0
	buffer.drop = cast(__WOwnedBufferDrop*, __w_owned_buffer_drop_element[T])
	return cast(own WOwnedBuffer[T]*, buffer)


int owned_buffer_length[T](ref WOwnedBuffer[T]* value):
	WOwnedBuffer[T]* buffer = cast(WOwnedBuffer[T]*, value)
	return buffer.length


optown T* owned_buffer_try_push[T](refmut WOwnedBuffer[T]* value, own T* element):
	WOwnedBuffer[T]* buffer = cast(WOwnedBuffer[T]*, value)
	if __w_owned_buffer_room(cast(__WOwnedBufferHeader*, buffer)) == 0:
		# Return the allocation without leaving a second cleanup owner.
		T* rejected = cast(T*, element)
		T** returned = cast(T**, &element)
		*returned = cast(T*, 0)
		return cast(optown T*, rejected)
	buffer.items[buffer.length] = cast(T*, element)
	buffer.length += 1
	T** transferred = cast(T**, &element)
	*transferred = cast(T*, 0)
	return 0


void owned_buffer_push[T](refmut WOwnedBuffer[T]* value, own T* element):
	WOwnedBuffer[T]* buffer = cast(WOwnedBuffer[T]*, value)
	if __w_owned_buffer_room(cast(__WOwnedBufferHeader*, buffer)) == 0:
		__w_trap(c"owned buffer insertion failed")
	buffer.items[buffer.length] = cast(T*, element)
	buffer.length += 1
	T** transferred = cast(T**, &element)
	*transferred = cast(T*, 0)


ref[a] T* owned_buffer_get[T](ref[a] WOwnedBuffer[T]* value, int index):
	WOwnedBuffer[T]* buffer = cast(WOwnedBuffer[T]*, value)
	if (index < 0) || (index >= buffer.length):
		__w_list_index_trap(c"owned generic buffer index out of range", index, buffer.length)
	return cast(ref[a] T*, buffer.items[index])


void owned_buffer_set[T](refmut WOwnedBuffer[T]* value, int index, own T* element):
	WOwnedBuffer[T]* buffer = cast(WOwnedBuffer[T]*, value)
	if (index < 0) || (index >= buffer.length):
		__w_list_index_trap(c"owned generic buffer index out of range", index, buffer.length)
	T* previous = buffer.items[index]
	buffer.items[index] = cast(T*, element)
	T** transferred = cast(T**, &element)
	*transferred = cast(T*, 0)
	buffer.drop(previous)


own T* owned_buffer_pop[T](refmut WOwnedBuffer[T]* value):
	WOwnedBuffer[T]* buffer = cast(WOwnedBuffer[T]*, value)
	if buffer.length == 0: __w_trap(c"pop from empty owned generic buffer")
	buffer.length -= 1
	T* element = buffer.items[buffer.length]
	buffer.items[buffer.length] = cast(T*, 0)
	return cast(own T*, element)


void owned_buffer_clear[T](refmut WOwnedBuffer[T]* value):
	__w_owned_buffer_clear(cast(__WOwnedBufferHeader*, value))
