import lib.memory_debug


type MutableTail = fn[a](refmut[a] int[]) -> refmut[a] int[]


refmut[a] T[] mutable_identity[T](refmut[a] T[] value):
	return value


refmut[a] int[] mutable_tail(refmut[a] int[] values):
	return values[1:]


int exercise():
	int total = 0
	for i in range(30):
		own int* amount = new int
		*amount = i
		int[4] values
		values[0] = 3
		values[1] = 4
		values[2] = 5
		values[3] = 6
		MutableTail* callback = mutable_tail
		refmut int[] view = values.mutable_identity[int]().mutable_identity()
		refmut int[] tail = callback(view)
		tail[0] += *amount
		ref int[] shared = tail
		total += shared[0] + shared[1]
		tail[1] = 11
		total += values[2]
	return total


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	if exercise() != 1035: return 1
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
