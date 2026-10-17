import lib.memory_debug
import tests.safe_generic_shape_import_fixture


type GenericShapeCallback = fn[a,b](ref[a,b] GenericBorrowed) -> ref[a,b] GenericBorrowed


int generic_shape_runtime():
	int total = 0
	for i in range(30):
		own int* scalar = new int
		*scalar = i
		int[3] values
		values[0] = 4
		values[1] = 5
		values[2] = 6
		ref[a,b] GenericBorrowed value = GenericBorrowed(scalar, values)
		ref[c,d] GenericNested nested = GenericNested(value, 2)
		ref[e,f] GenericNested result = generic_shape_identity[GenericNested](nested)
		ref int* number = result.child.scalar
		ref int[] view = result.child.values
		ref int[] tail = generic_shape_slice[int](view, 1)
		total += *number + tail[0] + tail[1] + result.tag
		GenericShapeCallback* callback = generic_shape_callback
		ref[g,h] GenericBorrowed called = callback(value)
		ref int* called_number = called.scalar
		total += *called_number
	return total


int generic_shape_write():
	int number = 7
	refmut[a] GenericMutable value = GenericMutable(&number)
	refmut[b] GenericMutable result = generic_shape_mutable[GenericMutable](value)
	refmut int* write_view = result.value
	*write_view = 11
	return number


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	if generic_shape_runtime() != 1260: return 1
	if generic_shape_write() != 11: return 2
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
