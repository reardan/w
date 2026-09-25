/*
Standalone wdbg binary: all of the debugger lives in debugger/wdbg.w
(and the modules it imports); this wrapper only provides main() so
'make wdbg' produces bin/wdbg. The compiler driver reuses the same
wdbg_main() for 'w --debug file.w'.
*/
import debugger.wdbg


int main(int argc, int argv):
	return wdbg_main(argc, argv)
# wbuild: target=wdbg dep=wv2 input=debugger/ output=bin/wdbg
# wbuild: step="bin/wv2 debugger/debugger.w -o bin/wdbg"
# wbuild: target=wdbg_x64 dep=wv2 input=debugger/ output=bin/wdbg64
# wbuild: step="bin/wv2 x64 debugger/debugger.w -o bin/wdbg64"
