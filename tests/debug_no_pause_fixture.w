# Debuggee with no 'debugger' statement, for testing wdbg/w-debug-mcp's
# --break_start default: without it, breakpoints queued before the first
# trap would race the debuggee (see debugger/wdbg.w's wdbg_main).
import lib.lib

int helper(int a):
	return a + 1

int main():
	int x = helper(3)
	println2(itoa(x))
	return 0
