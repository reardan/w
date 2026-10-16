# Borrowed records copy only stack descriptors; owners retain their data.
import lib.memory_debug


struct RuntimePairView:
	ref[field] int* first
	ref[field] int* second
	int tag


ref[a] RuntimePairView aggregate_runtime_make(ref[a] int* first, ref[a] int* second, int tag):
	return RuntimePairView(first, second, tag)


ref[a] RuntimePairView aggregate_runtime_copy(ref[a] RuntimePairView view):
	ref RuntimePairView local = view
	return local


ref[a] int* aggregate_runtime_first(ref[a] RuntimePairView view):
	return view.first


int aggregate_runtime_exercise():
	own int* first = new int
	own int* second = new int
	*first = 7
	*second = 9
	int remaining = 100000
	int total = 0
	while remaining > 0:
		ref RuntimePairView view = aggregate_runtime_copy(aggregate_runtime_make(first, second, 3))
		ref int* element = aggregate_runtime_first(view)
		total = total + *element + view.tag
		remaining = remaining - 1
	first = new int
	return total + *second


int main():
	int before = debug_alloc_report_leaks()
	if aggregate_runtime_exercise() != 1000009: return 1
	return debug_alloc_report_leaks() - before
