# Debuggee that dereferences a null pointer, for the wdbg fatal-signal
# handler test.
import lib.lib

int main(int argc, int argv):
	int* p = 0
	p[0] = 42
	return 0
