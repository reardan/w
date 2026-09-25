/*
Crash-report fixture for arm64_darwin (lib/crash.w, issue #378), built
twice by the crash_darwin target and run natively on a Mac by
tools/mac/run_darwin_tests.sh:

- bin/crash_darwin_fixture (plain arm64): print_stack_trace() from the
  bottom of a three-level chain, then a null-pointer read at the bottom
  of the same chain. The runner expects both traces to name every
  level, the report's register and uuid lines, and death by SIGSEGV.
- bin/crash_darwin_pac_fixture (--pac=full, arm64e): the same program.
  print_stack_trace() must still name every level (stacked return
  addresses are signed and must be stripped), and no fatal-signal
  report may appear: the handler is not installed on arm64e images
  (see crash_install_darwin).
*/
# wbuild: target=crash_darwin tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_darwin tests/crash_darwin_fixture.w -o bin/crash_darwin_fixture"
# wbuild: step="bin/wv2 arm64_darwin --pac=full tests/crash_darwin_fixture.w -o bin/crash_darwin_pac_fixture"
import lib.lib
import lib.crash
import lib.stack_trace


int crash_bottom(int* p, int report):
	if (report):
		print_stack_trace()
		return 0
	return p[0]


int crash_middle(int* p, int report):
	return crash_bottom(p, report) + 1


int crash_top(int* p, int report):
	return crash_middle(p, report) + 1


int main(int argc, int argv):
	crash_handler_install()
	crash_top(cast(int*, 16), 1)
	println(c"traced")
	return crash_top(cast(int*, 16), 0)
