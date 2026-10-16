import lib.memory_debug


struct ExclusiveView:
	refmut[field] int* item
	int amount


refmut[a] ExclusiveView exclusive_make(refmut[a] int* value, int amount):
	return ExclusiveView(value, amount)


refmut[a] int* exclusive_extract(refmut[a] ExclusiveView view):
	return view.item


void exclusive_bump(refmut ExclusiveView view):
	int amount = view.amount
	refmut int* value = view.item
	*value += amount


int exclusive_exercise():
	own int* value = new int
	*value = 7
	refmut[a] ExclusiveView view = exclusive_make(value, 3)
	refmut[b] ExclusiveView child = view
	exclusive_bump(child)
	refmut int* item = exclusive_extract(view)
	*item += 1
	ref int* snapshot = view.item
	int total = *snapshot
	for i in range(4):
		own int* local = new int
		*local = i
		refmut[a] ExclusiveView inner = exclusive_make(local, 2)
		exclusive_bump(inner)
		ref int* result = inner.item
		total += *result
	return total


int main():
	malloc_force_debug_mode()
	int baseline = debug_alloc_report_leaks()
	if exclusive_exercise() != 25: return 1
	return debug_alloc_report_leaks() - baseline
