# Raw pointers are not containers, even if matching int_iter_* symbols exist.
import lib.lib


int int_iter_begin(int* values):
	return 0


int int_iter_done(int* values, int cursor):
	return 1


int int_iter_next(int* values, int cursor):
	return cursor + 1


int int_iter_value(int* values, int cursor):
	return values[cursor]


int main():
	int* values = malloc(4)
	for int value in values:
		print_int("value: ", value)
	return 0
