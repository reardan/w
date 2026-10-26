# Generic records with checked fields, imported by
# tests/safe_generic_record_test.w and its runtime fixture.
struct Shared[T]:
	own T* value
	int tag


struct Lens[T]:
	ref[seen] T* item


own Shared[T]* shared_of[T](own T* value, int tag):
	return new Shared[T](value, tag)


int shared_read[T](ref Shared[T]* shared):
	ref T* value = shared.value
	return *value + shared.tag
