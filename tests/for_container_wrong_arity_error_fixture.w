# Iterator protocol functions must have the exact expected arity.
import lib.lib


struct bad_iter_arity:
	int value


int bad_iter_arity_iter_begin(bad_iter_arity* b, int extra):
	return 0


int bad_iter_arity_iter_done(bad_iter_arity* b, int cursor):
	return 1


int bad_iter_arity_iter_next(bad_iter_arity* b, int cursor):
	return cursor + 1


int bad_iter_arity_iter_value(bad_iter_arity* b, int cursor):
	return cursor


int main():
	bad_iter_arity* b = malloc(4)
	for int value in b:
		print_int("value: ", value)
	return 0
