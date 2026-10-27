# Generic record applications outside checked code, compiled by
# tests/safe_generic_record_runtime_test.w with the streaming and the
# AST-required front ends: 'new Name[T]', 'new Name[T](...)',
# 'new Name[T][n]' and 'Name[T](...)' values.
import lib.memory


struct Pair[A, B]:
	A first
	B second


Pair[T, T]* twin[T](T value):
	return new Pair[T, T](value, value)


int sum(Pair[int, int] pair):
	return pair.first + pair.second


int main():
	Pair[int, char]* empty = new Pair[int, char]
	empty.first = 2
	Pair[int, int]* both = twin[int](3)
	Pair[int, int][] many = new Pair[int, int][4]
	many[3].second = 5
	int result = empty.first + both.second + many[3].second + many.length + sum(Pair[int, int](1, 2))
	free(cast(void*, empty))
	free(cast(void*, both))
	return result - 17
