# Iterator protocol functions must return a word-sized value.
import lib.lib


struct bad_iter_return:
	int value


void bad_iter_return_iter_begin(bad_iter_return* b):
	pass


int bad_iter_return_iter_done(bad_iter_return* b, int cursor):
	return 1


int bad_iter_return_iter_next(bad_iter_return* b, int cursor):
	return cursor + 1


int bad_iter_return_iter_value(bad_iter_return* b, int cursor):
	return cursor


int main():
	bad_iter_return* b = malloc(4)
	for int value in b:
		print_int("value: ", value)
	return 0
