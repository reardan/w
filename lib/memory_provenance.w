# Exact live allocation provenance, enabled in the data image for programs
# with attested foreign boundaries. The table never reads an untrusted
# pointer. mmap bookkeeping avoids recursion through the allocator.
import lib.linux


void malloc_free_fatal(char* message);


int malloc_provenance_enabled
int malloc_provenance_lock_hook
int malloc_provenance_unlock_hook
int* malloc_provenance_table
int malloc_provenance_capacity
int malloc_provenance_used
int malloc_provenance_live


type __malloc_provenance_lock = fn() -> void


void malloc_provenance_lock():
	if (malloc_provenance_lock_hook): (cast(__malloc_provenance_lock*, malloc_provenance_lock_hook))()


void malloc_provenance_unlock():
	if (malloc_provenance_unlock_hook): (cast(__malloc_provenance_lock*, malloc_provenance_unlock_hook))()


int malloc_provenance_slot(int* slots, int capacity, int pointer, int inserting = 0):
	int slot = ((pointer >> 3) ^ (pointer >> 17)) & (capacity - 1)
	int reusable = -1
	while (slots[slot * 2] && (slots[slot * 2] != pointer)):
		if (inserting && (slots[slot * 2] == 1) && (reusable < 0)): reusable = slot
		slot = (slot + 1) & (capacity - 1)
	# A live duplicate later in the probe chain takes precedence. Otherwise
	# reuse its first tombstone so repeated address reuse remains constant-time.
	if (inserting && (slots[slot * 2] == 0) && (reusable >= 0)): return reusable
	return slot


void malloc_provenance_grow():
	int capacity = malloc_provenance_capacity
	if (capacity == 0): capacity = 1024
	else if (malloc_provenance_live * 4 >= capacity): capacity = capacity * 2
	int bytes = capacity * 2 * __word_size__
	int address = mmap(0, bytes, 3, 34)
	if ((address < 0) && (address > -4096)):
		# The registry lock is held. A stack trace would allocate again,
		# recursively growing this table or deadlocking on the same lock.
		char* message = c"foreign provenance: bookkeeping allocation failed\n"
		int length = 0
		while (message[length] != 0): length += 1
		write(2, message, length)
		exit(1)
	int* slots = cast(int*, address)
	for i in range(malloc_provenance_capacity):
		int pointer = malloc_provenance_table[i * 2]
		if ((pointer != 0) && (pointer != 1)):
			int slot = malloc_provenance_slot(slots, capacity, pointer)
			slots[slot * 2] = pointer
			slots[slot * 2 + 1] = malloc_provenance_table[i * 2 + 1]
	if (malloc_provenance_capacity): munmap(cast(int, malloc_provenance_table), malloc_provenance_capacity * 2 * __word_size__)
	malloc_provenance_table = slots
	malloc_provenance_capacity = capacity
	malloc_provenance_used = malloc_provenance_live


void malloc_provenance_record(void* value, int size):
	if ((malloc_provenance_enabled == 0) || (value == 0)): return
	if (cast(int, value) == 1): malloc_free_fatal(c"foreign provenance: invalid allocation address\n")
	malloc_provenance_lock()
	if ((malloc_provenance_capacity == 0) || (malloc_provenance_used * 2 >= malloc_provenance_capacity)): malloc_provenance_grow()
	int pointer = cast(int, value)
	int slot = malloc_provenance_slot(malloc_provenance_table, malloc_provenance_capacity, pointer, 1)
	int previous = malloc_provenance_table[slot * 2]
	if (previous == 0): malloc_provenance_used += 1
	if ((previous == 0) || (previous == 1)): malloc_provenance_live += 1
	malloc_provenance_table[slot * 2] = pointer
	malloc_provenance_table[slot * 2 + 1] = size
	malloc_provenance_unlock()


void malloc_provenance_forget(void* value):
	if ((malloc_provenance_enabled == 0) || (value == 0) || (cast(int, value) == 1)): return
	malloc_provenance_lock()
	if (malloc_provenance_capacity):
		int slot = malloc_provenance_slot(malloc_provenance_table, malloc_provenance_capacity, cast(int, value))
		if (malloc_provenance_table[slot * 2]):
			malloc_provenance_table[slot * 2] = 1
			malloc_provenance_live -= 1
	malloc_provenance_unlock()


int malloc_provenance_size(void* value):
	int size = -1
	if ((malloc_provenance_enabled == 0) || (value == 0) || (cast(int, value) == 1)): return size
	malloc_provenance_lock()
	if (malloc_provenance_capacity):
		int slot = malloc_provenance_slot(malloc_provenance_table, malloc_provenance_capacity, cast(int, value))
		if (malloc_provenance_table[slot * 2] == cast(int, value)): size = malloc_provenance_table[slot * 2 + 1]
	malloc_provenance_unlock()
	return size


# The check is a no-op for programs without an attested boundary. Non-null
# results must name the beginning of a live W allocation of sufficient size.
# This establishes allocator provenance, not initialization or uniqueness.
void* __w_foreign_owner_check(void* value, int size, int optional):
	if (malloc_provenance_enabled == 0): return value
	if (value == 0):
		if (optional): return value
		malloc_free_fatal(c"foreign owner: non-null result is null\n")
	# Negative sizes denote nominal foreign storage with its own destructor.
	# Its allocator is deliberately opaque, but null/alignment are checkable.
	if (size < 0):
		size = 0 - size
		int alignment = 1
		while ((alignment < __word_size__) && ((size % (alignment * 2)) == 0)): alignment = alignment * 2
		if ((cast(int, value) % alignment) != 0): malloc_free_fatal(c"foreign owner: result is misaligned\n")
		return value
	if (cast(int, value) == 1): malloc_free_fatal(c"foreign owner: result is not a live W allocation of the required size\n")
	int valid = 0
	malloc_provenance_lock()
	if (malloc_provenance_capacity):
		int slot = malloc_provenance_slot(malloc_provenance_table, malloc_provenance_capacity, cast(int, value))
		valid = (malloc_provenance_table[slot * 2] == cast(int, value)) && (malloc_provenance_table[slot * 2 + 1] >= size)
	malloc_provenance_unlock()
	if (valid == 0): malloc_free_fatal(c"foreign owner: result is not a live W allocation of the required size\n")
	return value
