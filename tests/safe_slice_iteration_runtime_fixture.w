import lib.safe_hash
import lib.memory_debug


ref[a] int[] iteration_counted(ref[a] WBuffer[int]* values, refmut int* count):
	*count += 1
	return buffer_view[int](values)


ref[a] T[] iteration_copy[T](ref[a] T[] values):
	return values


int iteration_stack_use(int value):
	int[64] storage
	storage[0] = value
	return storage[0]


int iteration_return(ref int[] values):
	for item in values:
		own int* local = new int
		*local = item
		defer: *local = 99
		return *local
	return -1


int iteration_exercise():
	int total = 0
	for repetition in range(30):
		own WBuffer[int]* values = buffer_new[int]()
		for i in range(32): buffer_push[int](values, i)
		own int* calls = new int
		for item in iteration_counted(values, calls): total += iteration_stack_use(item)
		total += *calls
		ref int[] shared = buffer_view[int](values)
		for item in iteration_copy[int](iteration_copy[int](shared[:3])):
			for nested in shared[:3]: total += item * nested
		for item in shared:
			if item == 2: continue
			if item == 5: break
			total += item
		for item in shared:
			own int* local = new int
			*local = item
			defer: total += *local
			if item % 2 == 0: continue
		if iteration_return(shared) != 0: return -1
		buffer_clear[int](values)
		own WMap[int, int]* map = map_new[int, int]()
		for i in range(8): map_set[int, int](map, i, i * 2)
		own WBuffer[int]* keys = map_keys[int, int](map)
		map_clear[int, int](map)
		for key in buffer_view[int](keys): total += key
	return total


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	if iteration_exercise() != 31140: return 1
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
