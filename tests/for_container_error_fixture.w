# Compile-error fixture: iterating a struct type without the cursor
# protocol's _iter_ functions must fail with a "not iterable" error.
import lib.lib

struct point:
	int x
	int y

int main():
	point* p = malloc(8)
	for int v in p:
		print_int("v: ", v)
	return 0
