# wbuild: binary=wgrind
# Run a rebuilt W executable with heap checking; arguments after the
# executable are passed verbatim. exec preserves signals and exit status.
import lib.process


int main(int argc, char** argv):
	int first = 1
	int native = 0
	if ((argc > 1) && (strcmp(argv[1], c"--native") == 0)):
		native = 1
		first = 2
	if ((argc <= first) || (strcmp(argv[first], c"--help") == 0)):
		println2(c"usage: wgrind [--native] <executable> [arguments...]")
		println2(c"default: Valgrind Memcheck, origins, leaks, error exit 99 (Linux x86/x64)")
		println2(c"--native: guard pages and canaries, no Valgrind dependency")
		if (argc > first): return 0
		return 2
	char* program = process_which(argv[first])
	if (program == 0):
		println2(c"wgrind: executable not found")
		return 127
	char** envp = env_copy_with(env_current(), c"W_DEBUG_ALLOC", c"1")
	if (native):
		execve(program, argv + first * __word_size__, envp)
	else:
		char* runner = process_which(c"valgrind")
		if (runner == 0):
			println2(c"wgrind: valgrind not found; install it or use --native")
			return 127
		char** args = strv_new(argc - first + 8)
		strv_set(args, 0, runner)
		strv_set(args, 1, c"--tool=memcheck")
		strv_set(args, 2, c"--track-origins=yes")
		strv_set(args, 3, c"--leak-check=full")
		strv_set(args, 4, c"--show-leak-kinds=all")
		strv_set(args, 5, c"--errors-for-leak-kinds=all")
		strv_set(args, 6, c"--error-exitcode=99")
		strv_set(args, 7, c"--")
		strv_set(args, 8, program)
		for i in range(first + 1, argc): strv_set(args, 8 + i - first, argv[i])
		envp = env_copy_with(envp, c"W_DEBUG_ALLOC", c"valgrind")
		execve(runner, args, envp)
	println2(c"wgrind: cannot execute program")
	return 126
