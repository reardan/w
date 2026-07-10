# expect_fail
# expect_stderr: assignment to const
import lib.lib


void const_assignment_error():
	const int fixed = 1
	fixed = 2


int main():
	return 0
