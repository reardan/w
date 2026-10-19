import lib.lib

struct plain:
	int item

int plain_iter_begin(plain* c):
	return 0

int plain_iter_done(plain* c, float cursor):
	return 1

int plain_iter_next(plain* c, int cursor):
	return c.item

int plain_iter_value(plain* c, int cursor):
	return c.item

int main():
	plain* p = cast(plain*, malloc(4))
	for x in p:
		pass
	return 0
