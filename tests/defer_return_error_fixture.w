# Compile-error fixture: 'return' is not allowed in a deferred statement.
import lib.lib


int main():
	defer return 1
	return 0
