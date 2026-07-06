# Compile-error fixture: a generator body cannot return a value; the
# only way to hand values to the consumer is yield.
import lib.generator


generator int counter(int n):
	yield 1
	return 2


int main():
	return 0
