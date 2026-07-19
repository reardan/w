# Reformatted twin of defhash_generic_fixture.w for defhash_test: every
# definition's token stream is byte-for-byte the same as the baseline's,
# only comments and blank-line layout differ. build.base.json's
# defhash_test entry asserts every recorded hash matches the baseline
# file's, including the generic function, the generic struct and the
# operator overload.
import lib.lib

struct defhash_generic_fixture_point:
	int x
	int y


# the larger of two values, for any comparable T
T defhash_generic_fixture_max[T](T a, T b):
	if (a > b):
		return a
	return b


struct defhash_generic_fixture_pair[T]:
	T first
	T second

# component-wise addition
defhash_generic_fixture_point operator+(defhash_generic_fixture_point a, defhash_generic_fixture_point b):
	return defhash_generic_fixture_point(a.x + b.x, a.y + b.y)


int defhash_generic_fixture_use_max():
	return defhash_generic_fixture_max(3, 5)

# entry point
int main():
	defhash_generic_fixture_point a = defhash_generic_fixture_point(1, 2)
	defhash_generic_fixture_point b = defhash_generic_fixture_point(3, 4)
	defhash_generic_fixture_point c = a + b
	defhash_generic_fixture_pair[int] p
	p.first = c.x
	p.second = c.y
	return p.first + p.second + defhash_generic_fixture_use_max()
