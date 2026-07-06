# Compile-error fixture: 'defer' is only meaningful inside a function.
import lib.lib

defer println(c"never")


int main():
	return 0
