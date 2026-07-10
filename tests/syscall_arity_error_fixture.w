# expect_fail
# expect_stderr: function 'syscall' expects 4 arguments, got 3
# The syscall stub loads exactly nr + 3 fixed stack slots, so a call
# with any other argument count reads garbage words. This exact call
# (prctl PR_SET_PTRACER with a missing argument) once compiled clean
# and silently invoked a garbage syscall number at runtime; it must be
# rejected at compile time.
int main(int argc, int argv):
	return syscall(172, 0x59616d61, -1)
