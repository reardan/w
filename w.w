/*
Wesley Reardan
A self-compiling compiler for the brand new W Language.

'w --debug file.w' runs the in-process debugger (wdbg) on the file
instead of compiling it to an ELF; see debugger/wdbg.w.
*/
import compiler.compiler
import debugger.wdbg


int main(int argc, int argv):
	verbosity = -1
	if (argc >= 2):
		char** first_arg = argv + __word_size__
		if (strcmp(*first_arg, c"--debug") == 0):
			return wdbg_main(argc, argv)
	link(argc, argv)
	return 0

