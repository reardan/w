# Compile-error fixture: a deferred statement cannot declare a variable
# (v1: it must be a simple expression statement, typically a call).
import lib.lib


int main():
	defer int x = 1
	return 0
