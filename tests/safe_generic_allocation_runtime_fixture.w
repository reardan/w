import lib.memory_debug
import tests.safe_generic_allocation_import_fixture


struct Child:
	own int* value


own T* generic_construct[T](own int* value):
	return new T(value)


int consume(own Child* child, int fail):
	if fail: return -1
	ref int* value = child.value
	return *value


int exercise():
	int total = 0
	for i in range(30):
		own int* value = generic_allocate[int]()
		*value = i
		own Child* child = generic_construct[Child](value)
		total += consume(child, 0)
		if consume(generic_construct[Child](generic_allocate[int]()), 1) != -1: return -1
		own int* replaced = generic_allocate[int]()
		replaced = generic_allocate[int]()
		total += *replaced
	return total


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	if exercise() != 435: return 1
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
