# Debuggee with a small counting loop for wdbg's conditional breakpoint,
# hit count and logpoint tests (debug_fixture.w/debug_fixture2.w are
# straight-line, so neither has a repeated statement to target).
import lib.lib


int main(int argc, int argv):
	int i = 0
	int sum = 0
	debugger
	while (i < 5):
		sum = sum + i
		i = i + 1
	println(c"loop done")
	return sum
