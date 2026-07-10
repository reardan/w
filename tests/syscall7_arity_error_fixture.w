# expect_fail
# expect_stderr: function 'syscall7' expects 7 arguments, got 8
# The syscall7 stub loads exactly nr + 6 fixed stack slots; an extra
# argument shifts every slot, so the call must be rejected outright.
int main(int argc, int argv):
	return syscall7(1, 2, 3, 4, 5, 6, 7, 8)
