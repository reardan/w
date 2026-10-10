# Compiler command dispatch shared by the ordinary and library launchers.
# This is a process entry API: call once with the original argc/argv.
import compiler.compiler
import compiler.coverage_exec
import debugger.wdbg
import lib.crash


# The analysis subcommand word: 1 check, 2 deps, 3 symbols, 4 defhash, 5 tree,
# else 0.
int subcommand_of(char* word):
	if (strcmp(word, c"check") == 0): return 1
	if (strcmp(word, c"deps") == 0): return 2
	if (strcmp(word, c"symbols") == 0): return 3
	if (strcmp(word, c"defhash") == 0): return 4
	if (strcmp(word, c"tree") == 0): return 5
	return 0


export int compiler_main(int argc, int argv):
	# A library call bypasses lib.lib._main, so capture its environment here.
	environ_ptr = argv + (argc + 1) * __word_size__
	verbosity = -1
	# Record the raw argv[0] before any argument shifting below:
	# compile_relative_path's last-resort search derives the compiler
	# binary's own directory from it (compiler/compiler.w,
	# compiler_argv0), so runs from outside the checkout still resolve
	# the auto-imported runtime.
	char** argv0_arg = cast(char**, argv)
	compiler_argv0 = *argv0_arg
	# $W_COVERAGE_COMPILER: re-execute as an instrumented build of this
	# compiler (compiler/coverage_exec.w; returns when unset).
	coverage_exec_redirect(c"W_COVERAGE_COMPILER", c"compiler", argv)
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
		if (subcommand == 5): return retained_query_main(argc, argv)
		if (strcmp(*first_arg, c"--version") == 0):
			# Keep in sync with package.wmeta; release.yml fails a tag
			# that disagrees with either.
			println(c"w 0.3.0")
			return 0
	return link(argc, argv)

# wbuild: library=wcompiler kind=shared arch=x64
# wbuild: library=wcompiler_static kind=static arch=x64
