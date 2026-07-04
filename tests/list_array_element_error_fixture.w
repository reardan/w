# Compile-only fixture: fixed-size arrays carry descriptors that point into
# the enclosing object, so they can never be list elements.
int main():
	list[int[3]] rows = new list[int[3]]
	return 0
