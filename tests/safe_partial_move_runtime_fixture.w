import lib.memory_debug
import tests.safe_partial_move_import_fixture


type PartialTake = fn[](own PartialPair*) -> own int*


int partial_exercise():
	own PartialPair* pair = partial_pair()
	for i in range(100):
		own int* first = pair.first
		*first = i
		pair.first = first
		pair.second = pair.second
	pair.first = partial_identity[int](pair.second)
	pair.second = new int
	own PartialPair* moved = new PartialPair(pair.first, pair.second)
	refmut int* value = moved.first
	*value = 17
	PartialTake* take = partial_take
	own int* result = take(moved)
	return *result


int partial_buffer():
	own PartialBuffer* holder = new PartialBuffer(int_buffer_new(), new int)
	int_buffer_push(holder.buffer, 23)
	own WIntBuffer* buffer = holder.buffer
	return int_buffer_get(buffer, 0)


int partial_external():
	int[3] data
	data[1] = 7
	own[a] PartialOuter* outer = new PartialOuter(new PartialView(new int, data))
	own[a] PartialView* child = partial_extract(outer)
	ref int[] view = child.data
	return view[1] + view.length


int partial_exits(int early):
	for i in range(3):
		own PartialPair* pair = partial_pair()
		own int* first = pair.first
		*first = i
		if (early): return *first
		if (i == 0): continue
		break
	return 1


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if partial_exercise() != 17: return 1
	if partial_buffer() != 23: return 2
	if partial_external() != 10: return 3
	if partial_exits(1) != 0: return 4
	if partial_exits(0) != 1: return 5
	return debug_alloc_report_leaks() - before
