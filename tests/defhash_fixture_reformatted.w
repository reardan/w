# Reformatted twin of defhash_fixture.w for defhash_test: every
# definition's token stream is byte-for-byte the same as the baseline's,
# only comments and blank-line layout differ. defhash_test.w's
# build.base.json entry asserts every recorded hash matches the
# baseline file's.
import lib.lib

type defhash_fixture_size = uint
# a 2D point
struct defhash_fixture_point:
	int x
	int y


int defhash_fixture_counter
# running total, updated elsewhere

int defhash_fixture_add(int a, int b):
	# sum two ints
	return a + b


int defhash_fixture_helper():
	return defhash_fixture_add(defhash_fixture_counter, 1) # calls add

enum defhash_fixture_color:
	defhash_fixture_red
	defhash_fixture_green

# entry point
int main():
	return defhash_fixture_helper()
