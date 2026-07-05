import lib.lib

type sym_fixture_size = uint

struct sym_fixture_point:
	int x
	int y

int sym_fixture_counter

int sym_fixture_add(int a, int b):
	return a + b

int main():
	return sym_fixture_add(sym_fixture_counter, 1)

enum sym_fixture_color:
	sym_fixture_red
	sym_fixture_green
