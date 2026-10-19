import lib.lib

struct box3[T]:
	T item
	int mark

int box3_iter_begin[T](box3[T]* c):
	return 0

int box3_iter_done[T](box3[T]* c, int cursor):
	return 1

T box3_iter_next[T](box3[T]* c, int cursor):
	return c.item

box3[T] box3_iter_value[T](box3[T]* c, int cursor):
	return c[0]

int main():
	box3[int]* b = cast(box3[int]*, malloc(8))
	for x in b:
		pass
	return 0
