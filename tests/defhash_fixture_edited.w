# Body-edited twin of defhash_fixture.w for defhash_test: only
# defhash_fixture_add's body differs (operand order swapped) from the
# baseline file. defhash_test.w's build.base.json entry asserts that
# defhash_fixture_add's hash differs from the baseline's while every
# other definition's hash stays the same.
import lib.lib

type defhash_fixture_size = uint

struct defhash_fixture_point:
	int x
	int y

int defhash_fixture_counter

int defhash_fixture_add(int a, int b):
	return b + a

int defhash_fixture_helper():
	return defhash_fixture_add(defhash_fixture_counter, 1)

enum defhash_fixture_color:
	defhash_fixture_red
	defhash_fixture_green

int main():
	return defhash_fixture_helper()
