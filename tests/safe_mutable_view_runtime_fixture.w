import lib.memory_debug
import tests.safe_mutable_view_import_fixture


type MutableViewIncrement = fn[a](refmut[a] MutableViewOuter*) -> void


int mutable_view_exercise():
	int value = 3
	int[3] text
	text[1] = 8
	own[a,b] MutableViewOuter* owner = new MutableViewOuter(new MutableViewLeaf(new int, &value, text, 7))
	MutableViewIncrement* increment = mutable_view_increment
	for i in range(100):
		refmut MutableViewOuter* view = mutable_view_identity[MutableViewOuter](owner)
		increment(view)
	ref int[] first = mutable_view_text(owner)
	ref int[] second = mutable_view_text(owner)
	int text_sum = first[1] + second[1]
	refmut int* data = mutable_view_data(owner)
	*data += text_sum
	int tag = owner.child.tag
	return value + tag


int mutable_view_nested_child():
	int value = 7
	int[2] text
	own[a,b] MutableViewOuter* owner = new MutableViewOuter(new MutableViewLeaf(new int, &value, text, 3))
	refmut MutableViewLeaf* child = owner.child
	refmut int* stored = child.stored
	*stored = 8
	int result = *stored
	refmut int* data = child.data
	*data += result
	return value


int mutable_view_deferred():
	int value = 7
	int[2] text
	own[a,b] MutableViewOuter* owner = new MutableViewOuter(new MutableViewLeaf(new int, &value, text, 3))
	refmut MutableViewOuter* view = owner
	defer (mutable_view_increment(view))
	return 0


int main():
	unsafe:
		malloc_force_debug_mode()
	int before = debug_alloc_report_leaks()
	if mutable_view_exercise() != 226: return 1
	if mutable_view_nested_child() != 15: return 2
	if mutable_view_deferred() != 0: return 3
	return debug_alloc_report_leaks() - before
