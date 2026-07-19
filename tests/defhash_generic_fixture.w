# defhash generic/operator coverage fixture (wave plan C task 4f):
# a generic function, a generic struct and an operator overload,
# alongside an ordinary function referencing the generic function by
# name so 'refs' resolution is exercised across the generic/operator
# boundary too (previously that ref would have been invisible: the
# generic definition was never in defhash's known-names set at all).
# See defhash_generic_fixture_reformatted.w (comment/whitespace-only
# twin, same hashes), defhash_generic_fixture_edited.w (the generic
# function and the operator's bodies edited, the generic struct left
# untouched) and defhash_generic_fixture_renamed.w (the generic
# function renamed, so the recorded NAME SET differs even though every
# untouched definition's hash stays the same).
import lib.lib

struct defhash_generic_fixture_point:
	int x
	int y

T defhash_generic_fixture_max[T](T a, T b):
	if (a > b):
		return a
	return b

struct defhash_generic_fixture_pair[T]:
	T first
	T second

defhash_generic_fixture_point operator+(defhash_generic_fixture_point a, defhash_generic_fixture_point b):
	return defhash_generic_fixture_point(a.x + b.x, a.y + b.y)

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
