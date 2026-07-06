# Imported by tests/generics_test.w: a generic defined in another file,
# plus a local instantiation of it so cross-file deduplication is
# exercised (both files request box[int]).

struct box[T]:
	T value

T unbox[T](box[T]* b):
	return b.value

int helper_boxed_sum(int a, int b):
	box[int] first
	box[int] second
	first.value = a
	second.value = b
	return unbox[int](&first) + unbox[int](&second)
