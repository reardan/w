# Typed object arenas own individually allocated objects. Slot growth never
# relocates an object. Insertion, destruction, reset and release need an
# exclusive borrow; typed_arena_alloc_shared allocates under a shared borrow,
# so it can run while views into the arena are live. Budget arenas charge each
# object's bytes to a separately owned WArenaBudget that they borrow
# exclusively while they live.
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


# Allocation with live views. Objects never move and no reference into the
# slot array escapes, so growing the slots under a shared borrow cannot
# invalidate a view; destroying objects still needs an exclusive borrow. The
# result is a shared view of a plain T. Arenas are never shared across
# threads, because this mutates through a shared borrow.
ref[a] T* typed_arena_alloc_shared[T](ref[a] WTypedArena[T]* value, T initial):
	WTypedArena[T]* arena = cast(WTypedArena[T]*, value)
	if __w_owned_buffer_room(cast(__WOwnedBufferHeader*, arena)) == 0:
		__w_trap(c"typed arena allocation failed")
	T* object = cast(T*, __w_new_object(sizeof(T)))
	*object = initial
	arena.items[arena.length] = object
	arena.length += 1
	arena.live += 1
	return cast(ref[a] T*, object)


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


# A byte budget: limit and the bytes its arena currently holds. A budget
# arena borrows it exclusively, so between arenas the owner can read it and
# hand it to the next arena with every charge refunded.
struct WArenaBudget:
	int limit
	int used


own WArenaBudget* arena_budget_new(int limit):
	if limit < 0: __w_trap(c"invalid arena budget")
	WArenaBudget* budget = cast(WArenaBudget*, __w_new_object(sizeof(WArenaBudget)))
	budget.limit = limit
	budget.used = 0
	return cast(own WArenaBudget*, budget)


int arena_budget_limit(ref WArenaBudget* value):
	WArenaBudget* budget = cast(WArenaBudget*, value)
	return budget.limit


int arena_budget_used(ref WArenaBudget* value):
	WArenaBudget* budget = cast(WArenaBudget*, value)
	return budget.used


int arena_budget_remaining(ref WArenaBudget* value):
	WArenaBudget* budget = cast(WArenaBudget*, value)
	return budget.limit - budget.used


# A typed arena whose live objects are charged sizeof(T) bytes each to the
# budget it borrows: own[b] WBudgetArena[T]* cannot outlive the budget b,
# and its destruction, which refunds the budget, counts as a use of b.
# Destroy, reset, release and drop refund exactly what was charged, so used
# always equals size times the arena's live objects. Only the object itself
# is charged, not slot storage or storage its fields own.
struct WBudgetArena[T]:
	int capacity
	int length
	int maximum
	T** items
	__WOwnedBufferDrop* drop
	int live
	int size
	refmut[budget] WArenaBudget* budget


struct __WBudgetArenaHeader:
	int capacity
	int length
	int maximum
	void** items
	__WOwnedBufferDrop* drop
	int live
	int size
	WArenaBudget* budget


int __w_budget_arena_fits(__WBudgetArenaHeader* arena):
	return arena.budget.limit - arena.budget.used >= arena.size


# Room for one more object: budget first (no effects), then slots. The
# caller charges the budget only after both succeed.
int __w_budget_arena_room(__WBudgetArenaHeader* arena):
	if __w_budget_arena_fits(arena) == 0: return 0
	return __w_owned_buffer_room(cast(__WOwnedBufferHeader*, arena))


void __w_budget_arena_reset(__WBudgetArenaHeader* arena):
	arena.budget.used -= arena.live * arena.size
	arena.live = 0
	__w_owned_buffer_clear(cast(__WOwnedBufferHeader*, arena))


void __w_budget_arena_drop(void* value):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	__w_budget_arena_reset(arena)
	free(cast(void*, arena.items))
	free(arena)


own[b] WBudgetArena[T]* budget_arena_new[T](refmut[b] WArenaBudget* budget, int maximum):
	if maximum < -1: __w_trap(c"invalid budget arena maximum")
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, __w_new_object(sizeof(__WBudgetArenaHeader)))
	arena.capacity = 0
	arena.length = 0
	arena.maximum = maximum
	arena.items = 0
	arena.drop = cast(__WOwnedBufferDrop*, __w_owned_buffer_drop_element[T])
	arena.live = 0
	arena.size = sizeof(T)
	arena.budget = cast(WArenaBudget*, budget)
	return cast(own[b] WBudgetArena[T]*, arena)


int budget_arena_length[T](ref WBudgetArena[T]* value):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	return arena.live


int budget_arena_slots[T](ref WBudgetArena[T]* value):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	return arena.length


# The budget's unspent bytes, read through the arena that holds it.
int budget_arena_remaining[T](ref WBudgetArena[T]* value):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	return arena.budget.limit - arena.budget.used


# Consumes element. Absent on success; the original owner when the budget,
# the slot maximum, size arithmetic or allocation refuses it.
optown T* budget_arena_try_insert[T](refmut WBudgetArena[T]* value, own T* element):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	T* raw = cast(T*, element)
	T** home = cast(T**, &element)
	*home = cast(T*, 0)
	if __w_budget_arena_room(arena) == 0: return cast(optown T*, raw)
	arena.budget.used += arena.size
	arena.items[arena.length] = cast(void*, raw)
	arena.length += 1
	arena.live += 1
	return cast(optown T*, 0)


int budget_arena_insert[T](refmut WBudgetArena[T]* value, own T* element):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	if __w_budget_arena_room(arena) == 0: __w_trap(c"budget arena insertion failed")
	T* raw = cast(T*, element)
	T** home = cast(T**, &element)
	*home = cast(T*, 0)
	arena.budget.used += arena.size
	int index = arena.length
	arena.items[index] = cast(void*, raw)
	arena.length += 1
	arena.live += 1
	return index


# Recoverable allocation of a plain T: absent, with nothing charged, when
# the budget or the slots refuse it.
optrefmut[a] T* budget_arena_try_alloc[T](refmut[a] WBudgetArena[T]* value, T initial):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	if __w_budget_arena_room(arena) == 0: return cast(optrefmut[a] T*, 0)
	T* object = cast(T*, malloc(sizeof(T)))
	if object == 0: return cast(optrefmut[a] T*, 0)
	*object = initial
	arena.budget.used += arena.size
	arena.items[arena.length] = cast(void*, object)
	arena.length += 1
	arena.live += 1
	return cast(optrefmut[a] T*, object)


refmut[a] T* budget_arena_alloc[T](refmut[a] WBudgetArena[T]* value, T initial):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	if __w_budget_arena_room(arena) == 0: __w_trap(c"budget arena allocation failed")
	T* object = cast(T*, __w_new_object(sizeof(T)))
	*object = initial
	arena.budget.used += arena.size
	arena.items[arena.length] = cast(void*, object)
	arena.length += 1
	arena.live += 1
	return cast(refmut[a] T*, object)


optref[a] T* budget_arena_get[T](ref[a] WBudgetArena[T]* value, int index):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	if ((index < 0) || (index >= arena.length)): return cast(optref[a] T*, 0)
	return cast(optref[a] T*, arena.items[index])


optrefmut[a] T* budget_arena_get_mut[T](refmut[a] WBudgetArena[T]* value, int index):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	if ((index < 0) || (index >= arena.length)): return cast(optrefmut[a] T*, 0)
	return cast(optrefmut[a] T*, arena.items[index])


int budget_arena_destroy[T](refmut WBudgetArena[T]* value, int index):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	if ((index < 0) || (index >= arena.length)): return 0
	void* object = arena.items[index]
	if object == 0: return 0
	arena.items[index] = 0
	arena.live -= 1
	arena.budget.used -= arena.size
	arena.drop(object)
	return 1


void budget_arena_reset[T](refmut WBudgetArena[T]* value):
	__w_budget_arena_reset(cast(__WBudgetArenaHeader*, value))


void budget_arena_release[T](refmut WBudgetArena[T]* value):
	__WBudgetArenaHeader* arena = cast(__WBudgetArenaHeader*, value)
	__w_budget_arena_reset(arena)
	free(cast(void*, arena.items))
	arena.items = 0
	arena.capacity = 0
