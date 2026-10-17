import lib.safe_vector
import lib.memory_debug

struct IterationPair:
	int left
	int right

ref[a] IterationPair[] record_iteration_counted(ref[a] WBuffer[IterationPair]* values, refmut int* calls):
	*calls += 1
	return buffer_view[IterationPair](values)

ref[a] T[] record_iteration_tail[T](ref[a] T[] values):
	return values[1:]

int record_iteration_stack(int value):
	int[64] scratch
	scratch[0] = value
	return scratch[0]

int record_iteration_first(ref IterationPair[] values):
	for item in values:
		own int* local = new int
		*local = item.left
		defer: *local = 99
		return *local
	return -1

int record_iteration_exercise():
	for repetition in range(30):
		own WBuffer[IterationPair]* values = buffer_new[IterationPair]()
		for i in range(16): buffer_push[IterationPair](values, IterationPair(i, i * 2))
		own int* calls = new int
		int total = 0
		for item in record_iteration_counted(values, calls): total += record_iteration_stack(item.left + item.right)
		if total != 360: return 1
		if *calls != 1: return 2
		ref IterationPair[] view = buffer_view[IterationPair](values)
		total = 0
		for ref IterationPair* item in record_iteration_tail[IterationPair](view[:4]):
			for other in view[:4]: total += item.left * other.left
		if total != 36: return 3
		optref IterationPair* saved = 0
		for item in view:
			saved = item
			if item.left == 3: break
		if saved:
			if saved.right != 6: return 4
		else: return 5
		total = 0
		for item in view:
			defer: total += item.right
			if item.left < 3: continue
			break
		if total != 12: return 6
		if record_iteration_first(view) != 0: return 7
		buffer_clear[IterationPair](values)
	return 0

int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = record_iteration_exercise()
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	if result: return result
	return after - before
