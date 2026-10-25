import lib.memory_debug
import tests.safe_aggregate_groups_import_fixture


type SplitCopy = fn[a, b](ref[a, b] SplitView) -> ref[a, b] SplitView
type SplitFirst = fn[a, b](ref[a, b] SplitView) -> ref[a] int*


int groups_clobber(int value):
	int[64] scratch
	scratch[0] = value
	return scratch[0]


int groups_exercise():
	SplitCopy* copy = split_copy
	SplitFirst* first = split_first
	own int* value = new int
	int[2] data
	int total = 0
	for i in range(100):
		*value = 3
		data[0] = 5
		ref[a, b] SplitView view = copy(split_view(value, data))
		int pressure = groups_clobber(1)
		ref int* p = first(view)
		data[0] = 9
		total += *p + data[0] + pressure
		value = new int
	return total


struct SplitExclusive:
	refmut[left] int* first
	refmut[right] int* second


struct SplitOuter:
	refmut[right, left] SplitExclusive pair
	int tag


refmut[a, b] SplitOuter groups_pair(refmut[a] int* x, refmut[b] int* y):
	return SplitOuter(SplitExclusive(x, y), 3)


int groups_exclusive():
	own int* first = new int
	own int* second = new int
	*first = 3
	*second = 5
	refmut[a, b] SplitOuter outer = groups_pair(first, second)
	for i in range(4):
		refmut int* p = outer.pair.first
		refmut int* q = outer.pair.second
		*p += 1
		*q += 2
	ref int* p = outer.pair.first
	ref int* q = outer.pair.second
	return *p + *q


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if groups_exercise() != 1300: return 1
	if groups_exclusive() != 20: return 2
	return debug_alloc_report_leaks() - before
