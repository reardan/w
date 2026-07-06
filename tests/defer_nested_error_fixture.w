# Compile-error fixture: 'defer' cannot be nested in a deferred statement.
import lib.lib


int main():
	defer defer println(c"never")
	return 0
