# Debuggee for the wdbg debug_test Makefile target: hits one breakpoint
# via the 'debugger' statement, then returns 7.
import lib.lib


int main(int argc, int argv):
	int x = 3
	x = x + 4
	debugger
	println("after breakpoint")
	return x
