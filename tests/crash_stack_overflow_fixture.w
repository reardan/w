# wbuild: target=crash_stack_overflow_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/crash_stack_overflow_fixture.w -o bin/crash_stack_overflow_fixture"
# wbuild: step="bin/crash_stack_overflow_fixture" expect_fail expect_stderr="fatal signal: SIGSEGV (invalid memory reference)" expect_stderr="note: the faulting address is next to the stack pointer: likely a stack overflow" expect_stderr="stack trace (most recent call first):" expect_stderr="at crash_recurse (" expect_stderr="crash_stack_overflow_fixture.w:" expect_stderr="terminating with the default action for signal 11"
# wbuild: target=crash_stack_overflow_x64_test tag=tests_x64 dep=wv2
# wbuild: step="bin/wv2 x64 tests/crash_stack_overflow_fixture.w -o bin/crash_stack_overflow_fixture64"
# wbuild: step="bin/crash_stack_overflow_fixture64" expect_fail expect_stderr="fatal signal: SIGSEGV (invalid memory reference)" expect_stderr="note: the faulting address is next to the stack pointer: likely a stack overflow" expect_stderr="stack trace (most recent call first):" expect_stderr="at crash_recurse (" expect_stderr="crash_stack_overflow_fixture.w:" expect_stderr="terminating with the default action for signal 11"
/*
Crash-report fixture for stack overflow (lib/crash.w, issue #526):
unbounded recursion on the main thread exhausts the stack. The crash
handler runs on its sigaltstack, so the process still prints the
symbolized report (with the stack-overflow note) before dying of
SIGSEGV, instead of the kernel killing it silently because no handler
frame fits on the exhausted stack. The targets above assert the report.
*/
import lib.lib
import lib.crash


int crash_depth


int crash_recurse(int n):
	crash_depth = n
	return crash_recurse(n + 1) + 1


int main(int argc, int argv):
	crash_handler_install()
	return crash_recurse(0)
