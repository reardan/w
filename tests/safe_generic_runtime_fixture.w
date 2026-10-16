import lib.memory_debug


T identity[T](T value):
	return value


own T* transfer[T](own T* value):
	return value


ref[a] T* view[T](ref[a] T* value):
	return value


int generic_runtime_run():
	for i in range(100):
		own int* p = new int
		*p = 7
		own int* q = identity[own int*](p)
		own int* r = identity(q)
		own int* s = transfer[int](r)
		ref int* v = view[int](s)
		if *v != 7: return 1
	return 0


int main():
	malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if generic_runtime_run(): return 1
	return debug_alloc_report_leaks() - before
