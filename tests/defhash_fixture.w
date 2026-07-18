import lib.lib

type defhash_fixture_size = uint

struct defhash_fixture_point:
	int x
	int y

int defhash_fixture_counter

int defhash_fixture_add(int a, int b):
	return a + b

int defhash_fixture_helper():
	return defhash_fixture_add(defhash_fixture_counter, 1)

enum defhash_fixture_color:
	defhash_fixture_red
	defhash_fixture_green

int main():
	return defhash_fixture_helper()
