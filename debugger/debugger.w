/*
Standalone wdbg binary: all of the debugger lives in debugger/wdbg.w
(and the modules it imports); this wrapper only provides main() so
'make wdbg' produces bin/wdbg. The compiler driver reuses the same
wdbg_main() for 'w --debug file.w'.
*/
import debugger.wdbg


int main(int argc, int argv):
	return wdbg_main(argc, argv)
