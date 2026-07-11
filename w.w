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
	if (argc >= 3):
		# 'w x64 check f.w': the target selector may precede the
		# subcommand word. Record it for link_impl and dispatch on the
		# word that follows (compiler/compiler.w, target_pending).
		char** selector_arg = argv + __word_size__
		if (target_is_selector(*selector_arg)):
			char** subcommand_arg = argv + 2 * __word_size__
			int shifted = 0
			if (strcmp(*subcommand_arg, c"check") == 0):
				shifted = 1
			if (strcmp(*subcommand_arg, c"deps") == 0):
				shifted = 1
			if (strcmp(*subcommand_arg, c"symbols") == 0):
				shifted = 1
			if (shifted):
				target_pending = *selector_arg
				argv = argv + __word_size__
				argc = argc - 1
	if (argc >= 2):
		char** first_arg = argv + __word_size__
		if (strcmp(*first_arg, c"--debug") == 0):
			return wdbg_main(argc, argv)
		if (strcmp(*first_arg, c"check") == 0):
			return check_main(argc, argv)
		if (strcmp(*first_arg, c"deps") == 0):
			return deps_main(argc, argv)
		if (strcmp(*first_arg, c"symbols") == 0):
			return symbols_main(argc, argv)
		if (strcmp(*first_arg, c"--version") == 0):
			# Keep in sync with package.wmeta; release.yml fails a tag
			# that disagrees with either.
			println(c"w 0.1.0")
			return 0
	link(argc, argv)
	return 0

