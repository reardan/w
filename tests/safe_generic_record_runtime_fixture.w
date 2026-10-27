import lib.memory_debug
import tests.safe_generic_record_import_fixture


struct Box[T]:
	own T* value
	int tag


struct View[T]:
	ref[a] T* item
	int extra


own Box[T]* wrap[T](own T* value, int tag):
	return new Box[T](value, tag)


int peek[T](ref Box[T]* box):
	ref T* value = box.value
	return *value + box.tag


# An early failure return still destroys the box and its owned value.
int consume(own Box[int]* box, int fail):
	if fail: return -1
	return peek(box)


ref[x] T* item_of[T](ref[x] View[T] view):
	return view.item


int exercise():
	int total = 0
	for i in range(30):
		own int* value = new int
		*value = i
		own Box[int]* box = wrap(value, 1)
		total += peek[int](box)
		own int* next = new int
		*next = 2
		box = new Box[int](next, 0)
		total += consume(box, 0)
		own int* failing = new int
		if consume(new Box[int](failing, 0), 1) != -1: return -1
		own int* inner = new int
		*inner = 1
		own Box[Box[int]]* nested = new Box[Box[int]](new Box[int](inner, 0), 0)
		ref Box[int]* opened = nested.value
		total += peek(opened)
		own int* shared_value = new int
		*shared_value = 3
		own Shared[int]* shared = shared_of(shared_value, 0)
		total += shared_read(shared)
		int n = 1
		ref View[int] view = View[int](&n, 0)
		ref int* item = item_of(view)
		total += *item
	return total


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	if exercise() != 675: return 1
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
