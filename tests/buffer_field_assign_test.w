# expect_fail
# expect_stderr: cannot assign to read-only buffer field
import lib.lib


void main():
	int[2] values
	values.length = 1000
