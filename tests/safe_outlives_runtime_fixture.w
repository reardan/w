# Outlives contracts preserve descriptor provenance and ordinary cleanup.
import lib.memory_debug


struct OutlivesView:
	ref[field] int* value


ref[b] OutlivesView outlives_record(ref[a] int* value) where a > b:
	return OutlivesView(value)


ref[c] int* outlives_field(ref[a] OutlivesView view, ref[b] int* fallback, int first) where a > b, b > c:
	if first: return view.value
	return fallback


ref[b] int[] outlives_slice(ref[a] int[] values) where a > b:
	return values[0:2]


int outlives_exercise():
	own int* first = new int
	own int* second = new int
	*first = 7
	*second = 9
	int[2] values
	values[0] = 3
	values[1] = 5
	int total = 0
	for i in range(100):
		ref OutlivesView view = outlives_record(first)
		ref int* value = outlives_field(view, second, i % 2)
		ref int[] slice = outlives_slice(values)
		total = total + *value + slice[0] + slice[1]
	first = new int
	return total


int main():
	int before = debug_alloc_report_leaks()
	if outlives_exercise() != 1600: return 1
	return debug_alloc_report_leaks() - before
