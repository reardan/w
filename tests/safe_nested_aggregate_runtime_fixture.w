import lib.memory_debug
import tests.safe_nested_aggregate_import_fixture


type NestedCopy = fn[a](ref[a] NestedView) -> ref[a] NestedView


int nested_clobber(int value):
	int[64] scratch
	scratch[0] = value
	return scratch[0]


int nested_exercise():
	NestedCopy* copy = nested_view_copy
	own int* value = new int
	int[2] data
	data[0] = 5
	int total = 0
	for i in range(100):
		*value = 3
		ref[a] NestedView view = copy(nested_view_make(value, data))
		int pressure = nested_clobber(1)
		ref int* p = view.cell.value
		ref int[] slice = view.data
		total += *p + view.cell.tag + view.tag + slice[0] + slice.length + pressure
		value = new int
	return total


struct NestedExclusiveCell:
	refmut[item] int* value
	int tag


struct NestedExclusiveView:
	refmut[group] NestedExclusiveCell cell
	int tag


void nested_bump(refmut NestedExclusiveView view):
	refmut int* p = view.cell.value
	*p += 1


int nested_exclusive():
	own int* value = new int
	*value = 7
	refmut[a] NestedExclusiveView view = NestedExclusiveView(NestedExclusiveCell(value, 3), 5)
	for i in range(4): nested_bump(view)
	ref int* p = view.cell.value
	return *p + view.cell.tag + view.tag


int main():
	int before = debug_alloc_report_leaks()
	if nested_exercise() != 1900: return 1
	if nested_exclusive() != 19: return 2
	return debug_alloc_report_leaks() - before
