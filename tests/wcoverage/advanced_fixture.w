import lib.lib
import lib.generator

int trace

void mark(int value):
	trace = trace + value

T identity[T](T value):
	return value

int deferred(int flag):
	defer mark(10)
	if (flag): return identity[int](1)
	return 2

generator int values():
	yield 3
	yield 4

int main():
	a:=deferred(1)
	char b = identity[char]('x')
	for int x in values():
		trace = trace + x
	if ((a != 1) || (b != 'x') || (trace != 17)): return 1
	goto done
	done:
	return 0
