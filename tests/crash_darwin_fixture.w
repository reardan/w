/*
Crash-report fixture for arm64_darwin (lib/crash.w, issue #378), built
twice by the crash_darwin target and run natively on a Mac by
tools/mac/run_darwin_tests.sh:

- bin/crash_darwin_fixture (plain arm64): print_stack_trace() from the
  bottom of a three-level chain, then a null-pointer read at the bottom
  of the same chain. The faulting frame holds a live decoy: a genuine
  return address into the decoy functions, which the old return-address scan
  reported as a frame. The runner expects both traces to name every
  level with its file:line (so line numbers below are asserted: keep
  them stable or update tools/mac/run_darwin_tests.sh), no decoy frame
  and no heuristic note (the walk follows the frame chain), the
  report's register and uuid lines, and death by SIGSEGV.
- bin/crash_darwin_pac_fixture (--pac=full, arm64e): the same program.
  print_stack_trace() must still name every level with file:line
  (stacked return addresses are signed and must be stripped), and no
  fatal-signal report may appear: the handler is not installed on arm64e images
  (see crash_install_darwin).
*/
# wbuild: target=crash_darwin tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_darwin tests/crash_darwin_fixture.w -o bin/crash_darwin_fixture"
# wbuild: step="bin/wv2 arm64_darwin --pac=full tests/crash_darwin_fixture.w -o bin/crash_darwin_pac_fixture"
import lib.lib
import lib.crash
import lib.stack_trace


int decoy_return


void decoy_leaf():
	char* buf = malloc(4 * __word_size__)
	stack_trace_collect(buf, 4)
	decoy_return = load_word(buf) + 1


void decoy_caller():
	decoy_leaf()


int crash_bottom(int* p, int report):
	if (report):
		print_stack_trace()
		return 0
	int decoy = decoy_return
	return p[0] + decoy


int crash_middle(int* p, int report):
	return crash_bottom(p, report) + 1


int crash_top(int* p, int report):
	return crash_middle(p, report) + 1


int main(int argc, int argv):
	crash_handler_install()
	decoy_caller()
	crash_top(cast(int*, 16), 1)
	println(c"traced")
	return crash_top(cast(int*, 16), 0)
