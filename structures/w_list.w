/*
Runtime for the built-in typed list[T] container.

The compiler lowers list syntax (new list[T], list[T]{...} literals,
l[index], l.push(v), l.pop(), l.length and for x in l) to these helpers.
Storage is byte-addressed: every element occupies element_size bytes, so
list[char] stays compact and wider element types keep their natural width.
Word-sized elements travel through the helpers as plain words; the
compiler loads and stores elements through __w_list_addr with the element
type's own width, so language semantics match slices and arrays.
*/
import lib.memory
import lib.stack_trace


struct __w_list:
	int capacity
	int length
	int element_size
	char* items


# Runtime trap output (issue #188): container misuse dies with a one-line
# diagnostic on stderr instead of a silent exit(1). write() is the syscall
# wrapper already reachable through lib.memory's import graph.
void __w_trap_cstr(char* s):
	int length = 0
	while (s[length]):
		length = length + 1
	write(2, s, length)


void __w_trap_int(int value):
	char* buf = malloc(24)
	int end = 24
	int i = end
	# Work with non-positive magnitudes so the minimum word needs no negation
	int v = value
	if (v > 0):
		v = 0 - v
	while (1):
		i = i - 1
		int q = v / 10
		buf[i] = '0' - (v - q * 10)
		v = q
		if (v == 0):
			break
	if (value < 0):
		i = i - 1
		buf[i] = '-'
	write(2, buf + i, end - i)
	free(buf)


void __w_trap(char* message):
	__w_trap_cstr(message)
	__w_trap_cstr(c"\n")
	print_stack_trace()
	exit(1)


void __w_list_index_trap(char* what, int index, int length):
	__w_trap_cstr(what)
	__w_trap_cstr(c": index ")
	__w_trap_int(index)
	__w_trap_cstr(c", length ")
	__w_trap_int(length)
	__w_trap_cstr(c"\n")
	print_stack_trace()
	exit(1)


# Compiler-emitted bounds checks (issue #228): array/slice/string indexing
# and slicing call this when a check fails (grammar/postfix_expr.w lowers
# the failing branch to a call here), so the failure prints what trapped
# instead of dying on a bare int3/brk #0. For a range check the reported
# pair is the offending bound and the limit it violated (for start > end
# that is the end bound, not the buffer length). Never returns.
void __w_bounds_trap(int index, int length):
	__w_list_index_trap(c"index out of range", index, length)


# new type[count] with a negative or implausibly large element count
# (grammar/unary_expression.w). Never returns.
void __w_alloc_trap(int length, int limit):
	__w_trap_cstr(c"array length out of range: length ")
	__w_trap_int(length)
	__w_trap_cstr(c", limit ")
	__w_trap_int(limit)
	__w_trap_cstr(c"\n")
	print_stack_trace()
	exit(1)


__w_list* __w_list_new(int element_size):
	if (element_size <= 0):
		__w_trap(c"list element size must be positive")
	int capacity = 8
	__w_list* list = malloc(4 * __word_size__)
	list.capacity = capacity
	list.length = 0
	list.element_size = element_size
	list.items = malloc(capacity * element_size)
	return list


void __w_list_ensure(__w_list* list, int extra):
	int needed = list.length + extra
	if (needed > list.capacity):
		int new_capacity = list.capacity * 2
		if (new_capacity < needed):
			new_capacity = needed
		# oldlen is the allocation size (capacity * element_size), not
		# the populated prefix — see structures/string.w string_reserve.
		list.items = realloc(list.items, list.capacity * list.element_size, new_capacity * list.element_size)
		list.capacity = new_capacity


# Address of element index; the compiler reads and writes elements through
# this so l[i] is a normal lvalue of the element type.
char* __w_list_addr(__w_list* list, int index):
	if (index < 0):
		__w_list_index_trap(c"list index out of range", index, list.length)
	if (index >= list.length):
		__w_list_index_trap(c"list index out of range", index, list.length)
	return list.items + index * list.element_size


void __w_list_store_word(char* addr, int element_size, int value):
	if (element_size == 1):
		addr[0] = value
	else if (element_size == 2):
		int16* addr16 = cast(int16*, addr)
		addr16[0] = value
	else if (element_size == 4):
		int32* addr32 = cast(int32*, addr)
		addr32[0] = value
	else:
		int* addr_word = cast(int*, addr)
		addr_word[0] = value


int __w_list_load_word(char* addr, int element_size):
	if (element_size == 1):
		return addr[0]
	if (element_size == 2):
		int16* addr16 = cast(int16*, addr)
		return addr16[0]
	if (element_size == 4):
		int32* addr32 = cast(int32*, addr)
		return addr32[0]
	int* addr_word = cast(int*, addr)
	return addr_word[0]


void __w_list_push(__w_list* list, int value):
	__w_list_ensure(list, 1)
	__w_list_store_word(list.items + list.length * list.element_size, list.element_size, value)
	list.length = list.length + 1


# Aggregate elements (structs) are copied by address: push copies
# element_size bytes from src into the new slot.
void __w_list_push_bytes(__w_list* list, char* src):
	__w_list_ensure(list, 1)
	char* dst = list.items + list.length * list.element_size
	int i = 0
	while (i < list.element_size):
		dst[i] = src[i]
		i = i + 1
	list.length = list.length + 1


int __w_list_pop(__w_list* list):
	if (list.length == 0):
		__w_trap(c"pop on empty list")
	list.length = list.length - 1
	return __w_list_load_word(list.items + list.length * list.element_size, list.element_size)


# Aggregate pop: returns the address of the removed element's bytes. The
# storage stays valid until the next push reuses the slot, so callers must
# copy before mutating the list.
char* __w_list_pop_addr(__w_list* list):
	if (list.length == 0):
		__w_trap(c"pop on empty list")
	list.length = list.length - 1
	return list.items + list.length * list.element_size


int __w_list_length(__w_list* list):
	return list.length


void __w_list_clear(__w_list* list):
	list.length = 0


# Removes the element at index, shifting the tail left.
void __w_list_remove(__w_list* list, int index):
	if (index < 0):
		__w_list_index_trap(c"list remove index out of range", index, list.length)
	if (index >= list.length):
		__w_list_index_trap(c"list remove index out of range", index, list.length)
	char* dst = list.items + index * list.element_size
	int tail_bytes = (list.length - index - 1) * list.element_size
	int i = 0
	while (i < tail_bytes):
		dst[i] = dst[i + list.element_size]
		i = i + 1
	list.length = list.length - 1


# Opens a hole at index (0..length inclusive) and returns its address.
char* __w_list_insert_slot(__w_list* list, int index):
	if (index < 0):
		__w_list_index_trap(c"list insert index out of range", index, list.length)
	if (index > list.length):
		__w_list_index_trap(c"list insert index out of range", index, list.length)
	__w_list_ensure(list, 1)
	char* base = list.items + index * list.element_size
	int i = (list.length - index) * list.element_size
	while (i > 0):
		i = i - 1
		base[i + list.element_size] = base[i]
	list.length = list.length + 1
	return base


void __w_list_insert(__w_list* list, int index, int value):
	char* slot = __w_list_insert_slot(list, index)
	__w_list_store_word(slot, list.element_size, value)


# Aggregate insert: copies element_size bytes from src into the new slot.
void __w_list_insert_bytes(__w_list* list, int index, char* src):
	char* slot = __w_list_insert_slot(list, index)
	int i = 0
	while (i < list.element_size):
		slot[i] = src[i]
		i = i + 1


# Word-compared membership scan for scalar elements.
int __w_list_contains(__w_list* list, int value):
	int i = 0
	while (i < list.length):
		if (__w_list_load_word(list.items + i * list.element_size, list.element_size) == value):
			return 1
		i = i + 1
	return 0


# Content-compared membership for char* elements, matching how map and
# set keys compare C strings by contents.
int __w_list_contains_cstr(__w_list* list, int value):
	char* wanted = cast(char*, value)
	int i = 0
	while (i < list.length):
		char* element = cast(char*, __w_list_load_word(list.items + i * list.element_size, list.element_size))
		int j = 0
		while ((element[j] != 0) && (element[j] == wanted[j])):
			j = j + 1
		if (element[j] == wanted[j]):
			return 1
		i = i + 1
	return 0


int __w_list_iter_begin(__w_list* list):
	return 0


# Do not mutate the list while iterating.
int __w_list_iter_done(__w_list* list, int cursor):
	return cursor >= list.length


int __w_list_iter_next(__w_list* list, int cursor):
	return cursor + 1


int __w_list_iter_value(__w_list* list, int cursor):
	if (cursor >= list.length):
		__w_list_index_trap(c"list iterator out of range", cursor, list.length)
	return __w_list_load_word(list.items + cursor * list.element_size, list.element_size)


# Copy n bytes; staging for aggregate sort_by and reverse.
void __w_list_copy_bytes(char* dst, char* src, int n):
	int i = 0
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# Scalar ordering for sort/count/index: kind 1 compares words (signed),
# kind 2 compares char* contents like map and set keys. Negative, zero
# or positive like strcmp.
int __w_list_compare_values(int a, int b, int kind):
	if (kind == 2):
		char* sa = cast(char*, a)
		char* sb = cast(char*, b)
		int j = 0
		while ((sa[j] != 0) && (sa[j] == sb[j])):
			j = j + 1
		return sa[j] - sb[j]
	if (a < b):
		return 0 - 1
	if (a > b):
		return 1
	return 0


# In-place stable insertion sort over scalar slots. The lists these
# methods serve are small; no allocation, no recursion.
void __w_list_sort(__w_list* list, int kind):
	int i = 1
	while (i < list.length):
		int value = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		int j = i - 1
		while (j >= 0):
			int other = __w_list_load_word(list.items + j * list.element_size, list.element_size)
			if (__w_list_compare_values(other, value, kind) <= 0):
				break
			__w_list_store_word(list.items + (j + 1) * list.element_size, list.element_size, other)
			j = j - 1
		__w_list_store_word(list.items + (j + 1) * list.element_size, list.element_size, value)
		i = i + 1


# Insertion sort with a caller-provided comparator (negative/zero/
# positive like strcmp). Scalar elements: the comparator receives
# element values.
void __w_list_sort_by(__w_list* list, int comparator):
	int i = 1
	while (i < list.length):
		int value = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		int j = i - 1
		while (j >= 0):
			int other = __w_list_load_word(list.items + j * list.element_size, list.element_size)
			if (comparator(other, value) <= 0):
				break
			__w_list_store_word(list.items + (j + 1) * list.element_size, list.element_size, other)
			j = j - 1
		__w_list_store_word(list.items + (j + 1) * list.element_size, list.element_size, value)
		i = i + 1


# Aggregate variant: the comparator receives element ADDRESSES and the
# moved element is staged in a temp buffer while the tail shifts.
void __w_list_sort_by_addr(__w_list* list, int comparator):
	char* temp = malloc(list.element_size)
	int i = 1
	while (i < list.length):
		__w_list_copy_bytes(temp, list.items + i * list.element_size, list.element_size)
		int j = i - 1
		while (j >= 0):
			char* other = list.items + j * list.element_size
			if (comparator(cast(int, other), cast(int, temp)) <= 0):
				break
			__w_list_copy_bytes(other + list.element_size, other, list.element_size)
			j = j - 1
		__w_list_copy_bytes(list.items + (j + 1) * list.element_size, temp, list.element_size)
		i = i + 1
	free(temp)


# New list of f(x) for every x; the compiler passes the result element
# size because f may map to a different scalar type.
__w_list* __w_list_map(__w_list* list, int f, int result_element_size):
	__w_list* result = __w_list_new(result_element_size)
	int i = 0
	while (i < list.length):
		int value = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		__w_list_push(result, f(value))
		i = i + 1
	return result


# New list of the x where f(x) is true.
__w_list* __w_list_filter(__w_list* list, int f):
	__w_list* result = __w_list_new(list.element_size)
	int i = 0
	while (i < list.length):
		int value = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		if (f(value)):
			__w_list_push(result, value)
		i = i + 1
	return result


# Left fold: f(f(f(init, x0), x1), x2)...
int __w_list_reduce(__w_list* list, int f, int init):
	int acc = init
	int i = 0
	while (i < list.length):
		acc = f(acc, __w_list_load_word(list.items + i * list.element_size, list.element_size))
		i = i + 1
	return acc


int __w_list_sum(__w_list* list):
	int total = 0
	int i = 0
	while (i < list.length):
		total = total + __w_list_load_word(list.items + i * list.element_size, list.element_size)
		i = i + 1
	return total


int __w_list_min(__w_list* list):
	if (list.length == 0):
		__w_trap(c"min on empty list")
	int best = __w_list_load_word(list.items, list.element_size)
	int i = 1
	while (i < list.length):
		int value = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		if (value < best):
			best = value
		i = i + 1
	return best


int __w_list_max(__w_list* list):
	if (list.length == 0):
		__w_trap(c"max on empty list")
	int best = __w_list_load_word(list.items, list.element_size)
	int i = 1
	while (i < list.length):
		int value = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		if (value > best):
			best = value
		i = i + 1
	return best


# In-place reversal, any element size (structs included).
void __w_list_reverse(__w_list* list):
	if (list.length < 2):
		return;
	char* temp = malloc(list.element_size)
	int i = 0
	int j = list.length - 1
	while (i < j):
		char* a = list.items + i * list.element_size
		char* b = list.items + j * list.element_size
		__w_list_copy_bytes(temp, a, list.element_size)
		__w_list_copy_bytes(a, b, list.element_size)
		__w_list_copy_bytes(b, temp, list.element_size)
		i = i + 1
		j = j - 1
	free(temp)


int __w_list_count(__w_list* list, int value, int kind):
	int total = 0
	int i = 0
	while (i < list.length):
		int element = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		if (__w_list_compare_values(element, value, kind) == 0):
			total = total + 1
		i = i + 1
	return total


# First index holding the value, or -1.
int __w_list_index(__w_list* list, int value, int kind):
	int i = 0
	while (i < list.length):
		int element = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		if (__w_list_compare_values(element, value, kind) == 0):
			return i
		i = i + 1
	return 0 - 1


void __w_list_free(__w_list* list):
	free(list.items)
	free(list)
