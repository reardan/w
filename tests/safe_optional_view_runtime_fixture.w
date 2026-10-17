import lib.memory_debug
import tests.safe_optional_view_import_fixture


type OptionalViewGet = fn[a](optrefmut[a] MutableViewOuter*) -> optrefmut[a] int*


int optional_view_exercise():
	int value = 3
	int[3] text
	text[1] = 8
	own[a,b] MutableViewOuter* owner = new MutableViewOuter(new MutableViewLeaf(new int, &value, text, 7))
	OptionalViewGet* get = optional_view_data
	optrefmut MutableViewOuter* view = 0
	for i in range(100):
		view = optional_view_identity[MutableViewOuter](owner)
		if (view):
			optrefmut int* data = get(view)
			if (data): *data += 1
		view = 0
	optref MutableViewOuter* shared = optional_view_shared(owner)
	int tag = 0
	if (shared): tag = shared.child.tag
	return value + tag


int optional_view_absent():
	optrefmut MutableViewOuter* view = 0
	optrefmut int* data = optional_view_data(view)
	optional_view_increment(view)
	if (data): return 1
	return 0


int optional_view_deferred():
	int value = 7
	int[2] text
	own[a,b] MutableViewOuter* owner = new MutableViewOuter(new MutableViewLeaf(new int, &value, text, 3))
	optrefmut MutableViewOuter* view = owner
	defer (optional_view_increment(view))
	return 0


int main():
	int before = debug_alloc_report_leaks()
	if optional_view_exercise() != 110: return 1
	if optional_view_absent() != 0: return 2
	if optional_view_deferred() != 0: return 3
	return debug_alloc_report_leaks() - before
