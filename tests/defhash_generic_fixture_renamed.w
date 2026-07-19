# Renamed twin of defhash_generic_fixture.w for defhash_test:
# defhash_generic_fixture_max is renamed to defhash_generic_fixture_maxval
# (definition and use site), otherwise identical to the baseline.
# build.base.json's defhash_test entry asserts the recorded NAME SET
# differs from the baseline's (the old name absent, the new name
# present) even though the untouched definitions' hashes are unchanged --
# a rename is exactly the case a name-set comparison must catch that a
# pure per-name hash comparison alone would miss.
import lib.lib

struct defhash_generic_fixture_point:
	int x
	int y

T defhash_generic_fixture_maxval[T](T a, T b):
	if (a > b):
		return a
	return b

struct defhash_generic_fixture_pair[T]:
	T first
	T second

defhash_generic_fixture_point operator+(defhash_generic_fixture_point a, defhash_generic_fixture_point b):
	return defhash_generic_fixture_point(a.x + b.x, a.y + b.y)

int defhash_generic_fixture_use_max():
	return defhash_generic_fixture_maxval(3, 5)

int main():
	defhash_generic_fixture_point a = defhash_generic_fixture_point(1, 2)
	defhash_generic_fixture_point b = defhash_generic_fixture_point(3, 4)
	defhash_generic_fixture_point c = a + b
	defhash_generic_fixture_pair[int] p
	p.first = c.x
	p.second = c.y
	return p.first + p.second + defhash_generic_fixture_use_max()
