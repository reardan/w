# Compile-only fixture: struct elements are stored by byte copy, and fixed
# arrays carry descriptors that point into the enclosing object, so structs
# containing fixed-array fields cannot be list elements.
struct list_fixture_grid:
	int[4] cells

int main():
	list[list_fixture_grid] rows = new list[list_fixture_grid]
	return 0
