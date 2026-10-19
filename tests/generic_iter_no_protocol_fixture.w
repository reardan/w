import lib.lib

struct box3[T]:
	T item

int main():
	box3[int]* b = cast(box3[int]*, malloc(4))
	for x in b:
		pass
	return 0
