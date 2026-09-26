/*
Wesley Reardan
A self-compiling compiler for the brand new W Language.

'w --debug file.w' runs the in-process debugger (wdbg) on the file
instead of compiling it to an ELF; see debugger/wdbg.w.
*/
import compiler.compiler
import debugger.wdbg
import lib.crash


# The analysis subcommand word: 1 check, 2 deps, 3 symbols, 4 defhash,
# else 0.
int subcommand_of(char* word):
	if (strcmp(word, c"check") == 0): return 1
	if (strcmp(word, c"deps") == 0): return 2
	if (strcmp(word, c"symbols") == 0): return 3
	if (strcmp(word, c"defhash") == 0): return 4
	return 0


int main(int argc, int argv):
	verbosity = -1
	# Record the raw argv[0] before any argument shifting below:
	# compile_relative_path's last-resort search derives the compiler
	# binary's own directory from it (compiler/compiler.w,
	# compiler_argv0), so runs from outside the checkout still resolve
	# the auto-imported runtime.
	char** argv0_arg = cast(char**, argv)
	compiler_argv0 = *argv0_arg
	# A compiler crash reports a symbolized stack trace (lib/crash.w).
	# wdbg_main later replaces these handlers with its own post-mortem
	# ones for the --debug path.
	crash_handler_install()
	if (argc >= 3):
		# 'w x64 check f.w': the target selector may precede the
		# subcommand word. Record it for link_impl and dispatch on the
		# word that follows (compiler/compiler.w, target_pending).
		char** selector_arg = argv + __word_size__
		if (target_is_selector(*selector_arg)):
			char** subcommand_arg = argv + 2 * __word_size__
			if (subcommand_of(*subcommand_arg)):
				target_pending = *selector_arg
				argv = argv + __word_size__
				argc = argc - 1
	if (argc >= 2):
		char** first_arg = argv + __word_size__
		if (strcmp(*first_arg, c"--debug") == 0): return wdbg_main(argc, argv)
		int subcommand = subcommand_of(*first_arg)
		if (subcommand == 1): return check_main(argc, argv)
		if (subcommand == 2): return deps_main(argc, argv)
		if (subcommand == 3): return symbols_main(argc, argv)
		if (subcommand == 4): return defhash_main(argc, argv)
		if (strcmp(*first_arg, c"--version") == 0):
			# Keep in sync with package.wmeta; release.yml fails a tag
			# that disagrees with either.
			println(c"w 0.3.0")
			return 0
	link(argc, argv)
	return 0

