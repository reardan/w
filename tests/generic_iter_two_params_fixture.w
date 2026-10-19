import lib.lib

struct box3[T]:
	T item

A box3_iter_begin[A, B](box3[A]* c, B extra):
	return 0

int box3_iter_done[T](box3[T]* c, int cursor):
	return 1

T box3_iter_next[T](box3[T]* c, int cursor):
	return c.item

T box3_iter_value[T](box3[T]* c, int cursor):
	return c.item

int main():
	box3[int]* b = cast(box3[int]*, malloc(4))
	for x in b:
		pass
	return 0
