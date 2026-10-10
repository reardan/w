/*
Wesley Reardan
A self-compiling compiler for the brand new W Language.

'w --debug file.w' runs the in-process debugger (wdbg) on the file
instead of compiling it to an ELF; see debugger/wdbg.w.
*/
import compiler.cli


int main(int argc, int argv):
	return compiler_main(argc, argv)
