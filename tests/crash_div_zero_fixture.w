/*
Crash-report fixture (lib/crash.w, issue #378): an integer division by
zero (SIGFPE). The divisor comes from argc so the division cannot be
folded away at compile time. The hand-written crash_trace_test target
in build.base.json runs the binary with expect_fail and asserts the
stderr report names crash_divide and main.
*/
import lib.lib
import lib.crash


int crash_divide(int n):
	return 100 / n


int main(int argc, int argv):
	crash_handler_install()
	return crash_divide(argc - 1)
