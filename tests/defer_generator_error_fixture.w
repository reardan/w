# Compile-error fixture: defer is not supported in generator bodies.
import lib.lib
import lib.generator


generator int counter(int n):
	defer println(c"never")
	int i = 0
	while (i < n):
		yield i
		i = i + 1


int main():
	return 0
