# Body-edited twin of defhash_generic_fixture.w for defhash_test: only
# defhash_generic_fixture_max's body (branch/operand order swapped,
# still returns the larger value) and operator+'s body (operand order
# swapped, still commutative) differ from the baseline. build.base.json's
# defhash_test entry asserts those two hashes differ from the baseline's
# while defhash_generic_fixture_pair (untouched) and every ordinary
# definition keep the baseline's hash.
import lib.lib

struct defhash_generic_fixture_point:
	int x
	int y

T defhash_generic_fixture_max[T](T a, T b):
	if (b > a):
		return b
	return a

struct defhash_generic_fixture_pair[T]:
	T first
	T second

defhash_generic_fixture_point operator+(defhash_generic_fixture_point a, defhash_generic_fixture_point b):
	return defhash_generic_fixture_point(b.x + a.x, b.y + a.y)

int defhash_generic_fixture_use_max():
	return defhash_generic_fixture_max(3, 5)

int main():
	defhash_generic_fixture_point a = defhash_generic_fixture_point(1, 2)
	defhash_generic_fixture_point b = defhash_generic_fixture_point(3, 4)
	defhash_generic_fixture_point c = a + b
	defhash_generic_fixture_pair[int] p
	p.first = c.x
	p.second = c.y
	return p.first + p.second + defhash_generic_fixture_use_max()
