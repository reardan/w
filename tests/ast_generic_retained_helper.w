# Imported by tests/ast_generic_retained_fixture.w: generics defined in
# another file, so a retained window serves a source other than the root.

struct wrap[T]:
	T inner
	wrap[T]* outer


T unwrap[T](wrap[T]* w):
	defer helper_note()
	return w.inner


int helper_notes


void helper_note():
	helper_notes = helper_notes + 1


int helper_wrap_total(int a, int b):
	wrap[int] first
	wrap[int] second
	first.inner = a
	second.inner = b
	first.outer = &second
	return unwrap[int](&first) + unwrap[int](first.outer)
