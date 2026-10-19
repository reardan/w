# The unchecked harness observes allocation/free order around checked code.
# Queue sequence numbers distinguish field destruction from parent destruction.
import lib.memory_debug


struct RuntimeOwnerPair:
	own int* first
	own int* second
	int tag


struct RuntimeOwnerOuter:
	own RuntimeOwnerPair* inner
	int tag


own RuntimeOwnerPair* owned_runtime_make(int tag):
	own int* first = new int
	own int* second = new int
	*first = 7
	*second = 9
	return new RuntimeOwnerPair(first, second, tag)


own RuntimeOwnerPair* owned_runtime_relay(own RuntimeOwnerPair* value):
	return value


int owned_runtime_consume(own RuntimeOwnerPair* value):
	return value.tag


int owned_runtime_order():
	own RuntimeOwnerPair* value = owned_runtime_make(3)
	ref int* first = value.first
	return *first + value.tag - 10


int owned_runtime_paths(int n):
	own RuntimeOwnerPair* value = owned_runtime_relay(owned_runtime_make(4))
	if n == 0: return owned_runtime_consume(value)
	int total = 0
	while n > 0:
		own RuntimeOwnerPair* local = owned_runtime_make(n)
		n = n - 1
		if n == 3: continue
		if n == 1: break
		total = total + owned_runtime_consume(local)
	value = owned_runtime_make(total)
	return owned_runtime_consume(value)


int owned_runtime_nested():
	own RuntimeOwnerOuter* outer = new RuntimeOwnerOuter(owned_runtime_make(3), 5)
	ref RuntimeOwnerPair* inner = outer.inner
	ref int* first = inner.first
	return *first + inner.tag + outer.tag - 15


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	int previous_tail = debug_quarantine_tail
	int sequence = debug_alloc_sequence
	if owned_runtime_order() != 0: return 1
	if debug_alloc_sequence != sequence + 3: return 2
	int link = debug_quarantine_head
	if previous_tail: link = debug_tbl_next[previous_tail - 1]
	if link == 0: return 3
	if debug_tbl_sequence[link - 1] != sequence + 2: return 4
	link = debug_tbl_next[link - 1]
	if link == 0: return 5
	if debug_tbl_sequence[link - 1] != sequence + 1: return 6
	link = debug_tbl_next[link - 1]
	if link == 0: return 7
	if debug_tbl_sequence[link - 1] != sequence + 3: return 8
	if debug_tbl_next[link - 1] != 0: return 9
	if owned_runtime_paths(0) != 4: return 10
	if owned_runtime_paths(1) != 1: return 11
	if owned_runtime_paths(5) != 8: return 12
	if owned_runtime_nested() != 0: return 13
	return debug_alloc_report_leaks() - before
