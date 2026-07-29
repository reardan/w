/*
Crash-report fixture (lib/crash.w, issue #378): a null-pointer read
three calls deep. The hand-written crash_trace_test target in
build.base.json runs the binary with expect_fail and asserts the
stderr report names crash_deep, crash_mid and main.
*/
import lib.lib
import lib.crash


int crash_deep(int depth):
	int* p = cast(int*, 0)
	return p[0] + depth


int crash_mid():
	return crash_deep(3)


int main(int argc, int argv):
	crash_handler_install()
	return crash_mid()
