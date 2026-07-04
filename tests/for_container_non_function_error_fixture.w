# Iterator protocol names must resolve to functions, not globals.
import lib.lib


struct bad_iter_symbol:
	int value


int bad_iter_symbol_iter_begin;


int bad_iter_symbol_iter_done(bad_iter_symbol* b, int cursor):
	return 1


int bad_iter_symbol_iter_next(bad_iter_symbol* b, int cursor):
	return cursor + 1


int bad_iter_symbol_iter_value(bad_iter_symbol* b, int cursor):
	return cursor


int main():
	bad_iter_symbol* b = malloc(4)
	for int value in b:
		print_int(c"value: ", value)
	return 0
