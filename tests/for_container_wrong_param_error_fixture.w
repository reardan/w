# Iterator protocol functions must accept the iterable type as parameter 1.
import lib.lib


struct bad_iter_param:
	int value


int bad_iter_param_iter_begin(int* values):
	return 0


int bad_iter_param_iter_done(bad_iter_param* b, int cursor):
	return 1


int bad_iter_param_iter_next(bad_iter_param* b, int cursor):
	return cursor + 1


int bad_iter_param_iter_value(bad_iter_param* b, int cursor):
	return cursor


int main():
	bad_iter_param* b = malloc(4)
	for int value in b:
		print_int(c"value: ", value)
	return 0
