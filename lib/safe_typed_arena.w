# Typed object arenas own individually allocated objects. Slot growth never
# relocates an object; the checked API initially requires exclusive borrowing
# for every insertion, allocation, destruction, reset and release.
import lib.safe_owned_vector


struct WTypedArena[T]:
	int capacity
	int length
	int maximum
	T** items
	__WOwnedBufferDrop* drop
	int live


struct __WTypedArenaHeader:
	int capacity
	int length
	int maximum
	void** items
	__WOwnedBufferDrop* drop
	int live


void __w_typed_arena_reset(__WTypedArenaHeader* arena):
	__w_owned_buffer_clear(cast(__WOwnedBufferHeader*, arena))
	arena.live = 0


void __w_typed_arena_drop(void* value):
	__WTypedArenaHeader* arena = cast(__WTypedArenaHeader*, value)
	__w_typed_arena_reset(arena)
	free(cast(void*, arena.items))
	free(arena)


own WTypedArena[T]* typed_arena_new[T](int maximum):
	if maximum < -1: __w_trap(c"invalid typed arena maximum")
	WTypedArena[T]* arena = cast(WTypedArena[T]*, __w_new_object(sizeof(WTypedArena[T])))
	arena.capacity = 0
	arena.length = 0
	arena.maximum = maximum
	arena.items = 0
	arena.drop = cast(__WOwnedBufferDrop*, __w_owned_buffer_drop_element[T])
	arena.live = 0
	return cast(own WTypedArena[T]*, arena)


int typed_arena_length[T](ref WTypedArena[T]* value):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	return arena.live


# Positions remain stable until reset/release; removed positions are holes.
# This is a position, not an identity token surviving reset or another arena.
int typed_arena_slots[T](ref WTypedArena[T]* value):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	return arena.length


optown T* typed_arena_try_insert[T](refmut WTypedArena[T]* value, own T* element):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	if __w_owned_buffer_room(cast(__WOwnedBufferHeader*, arena)) == 0:
		T* rejected = cast(T*, element)
		T** returned = cast(T**, &element)
		*returned = cast(T*, 0)
		return cast(optown T*, rejected)
	arena.items[arena.length] = cast(T*, element)
	arena.length += 1
	arena.live += 1
	T** transferred = cast(T**, &element)
	*transferred = cast(T*, 0)
	return 0


int typed_arena_insert[T](refmut WTypedArena[T]* value, own T* element):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	if __w_owned_buffer_room(cast(__WOwnedBufferHeader*, arena)) == 0:
		__w_trap(c"typed arena insertion failed")
	int index = arena.length
	arena.items[index] = cast(T*, element)
	arena.length += 1
	arena.live += 1
	T** transferred = cast(T**, &element)
	*transferred = cast(T*, 0)
	return index


# Allocation initializes a plain value before publishing its pointer.
# Owners with recursive cleanup enter through the consuming insert APIs.
refmut[a] T* typed_arena_alloc[T](refmut[a] WTypedArena[T]* value, T initial):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	if __w_owned_buffer_room(cast(__WOwnedBufferHeader*, arena)) == 0:
		__w_trap(c"typed arena allocation failed")
	T* object = cast(T*, __w_new_object(sizeof(T)))
	*object = initial
	arena.items[arena.length] = object
	arena.length += 1
	arena.live += 1
	return cast(refmut[a] T*, object)


optref[a] T* typed_arena_get[T](ref[a] WTypedArena[T]* value, int index):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	if ((index < 0) || (index >= arena.length)): return 0
	return cast(optref[a] T*, arena.items[index])


optrefmut[a] T* typed_arena_get_mut[T](refmut[a] WTypedArena[T]* value, int index):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	if ((index < 0) || (index >= arena.length)): return 0
	return cast(optrefmut[a] T*, arena.items[index])


int typed_arena_destroy[T](refmut WTypedArena[T]* value, int index):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	if ((index < 0) || (index >= arena.length)): return 0
	T* object = arena.items[index]
	if object == 0: return 0
	arena.items[index] = cast(T*, 0)
	arena.live -= 1
	arena.drop(object)
	return 1


void typed_arena_reset[T](refmut WTypedArena[T]* value):
	__w_typed_arena_reset(cast(__WTypedArenaHeader*, value))


void typed_arena_release[T](refmut WTypedArena[T]* value):
	__WTypedArenaHeader* arena = cast(__WTypedArenaHeader*, value)
	__w_typed_arena_reset(arena)
	free(cast(void*, arena.items))
	arena.items = 0
	arena.capacity = 0
