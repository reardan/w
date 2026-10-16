# The descriptor belongs to the caller's stack, independently of its data.
# The unchecked harness only observes heap accounting around checked functions.
import lib.memory_debug


ref[a] int[] slice_runtime_copy(ref[a] int[] values):
	ref int[] local = values
	return local


ref[a] int* slice_runtime_element(ref[a] int[] values):
	return &values[0]


ref[a] int[] slice_runtime_choose(ref[a] int[] left, ref[a] int[] right, int first):
	if first: return left
	return right


int slice_runtime_stack_clobber(int n):
	int[64] values
	values[0] = n
	return values[0]


int slice_runtime_exercise():
	int[3] a
	int[2] b
	a[0] = 7
	b[0] = 9
	int remaining = 10000
	int total = 0
	while remaining > 0:
		ref int[] full = a
		ref int[] local = slice_runtime_copy(slice_runtime_copy(full)[0:1])
		ref int[] empty = local[0:0]
		if empty.length != 0: return 2
		ref int* element = slice_runtime_element(local)
		total = total + *element
		remaining = remaining - 1
	ref int[] selected = slice_runtime_choose(a, b, 0)
	int saved = slice_runtime_stack_clobber(5)
	return total + selected[0] + selected.length + saved


int main():
	int before = debug_alloc_report_leaks()
	if slice_runtime_exercise() != 70016: return 1
	return debug_alloc_report_leaks() - before
