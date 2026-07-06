# Compile-error fixture: yield is only legal inside a generator body.
import lib.generator


int main():
	yield 1
	return 0
