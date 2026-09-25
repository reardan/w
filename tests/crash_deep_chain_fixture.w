/*
Crash-report fixture for frame-pointer unwinding (lib/crash.w, issue
#378): a null-pointer read at the bottom of a six-level call chain,
with a live local holding a genuine return address (into decoy_caller)
in the faulting frame. The crash_trace_test targets assert every level
appears, and that neither the decoy nor the heuristic-scan note does.
*/
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


int crash_level6(int x):
	int decoy = decoy_return
	int* p = cast(int*, 0)
	return p[0] + x + decoy


int crash_level5(int x):
	return crash_level6(x + 1)


int crash_level4(int x):
	return crash_level5(x + 1)


int crash_level3(int x):
	return crash_level4(x + 1)


int crash_level2(int x):
	return crash_level3(x + 1)


int crash_level1(int x):
	return crash_level2(x + 1)


int main(int argc, int argv):
	crash_handler_install()
	decoy_caller()
	return crash_level1(0)
