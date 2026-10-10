# wbuild: binary=wllvm arch=x64
/*
Opt-in LLVM IR experiment over the production compiler's retained forest.
The front end still emits native code to the null device while binding the
trees: this is not an independent semantic-analysis pass. LLVM tools are
needed only when a user chooses to compile the resulting textual IR.
*/
import compiler.compiler
import tools.wllvm_emit
import lib.stat


int wllvm_error(char* message):
	print_error(c"wllvm: ")
	print_error(message)
	print_error(c"\n")
	return 1


void wllvm_usage():
	println(c"usage: wllvm input.w -o output.ll")
	println(c"Experimental LLVM IR from the production retained AST; 64-bit integer semantics.")
	println(c"Subset: scalar integer/boolean functions, locals, arithmetic, comparisons,")
	println(c"same-file calls, if/elif/else, while, return, break and continue.")
	println(c"The input must define a main function with no parameters.")
	println(c"Imports, globals, pointers, containers and other unsupported syntax fail.")
	println(c"The front end currently also emits native code to the null device.")
	println(c"No LLVM installation is needed to emit IR. To compile it separately:")
	println(c"  clang -O2 output.ll -o program")


char* wllvm_absolute(char* path):
	if (path_is_absolute(path)): return import_root_clean(path)
	char* cwd = cast(char*, malloc(4096))
	if (getcwd(cwd, 4096) < 0):
		wllvm_error(c"could not read the working directory")
		exit(1)
	char* prefix = strjoin(cwd, c"/")
	char* joined = strjoin(prefix, path)
	char* result = import_root_clean(joined)
	free(joined)
	free(prefix)
	free(cwd)
	return result


# Lexical identity works on every host. On Linux, stat also protects aliases
# through symlinks and hardlinks from overwriting the input file.
int wllvm_same_file(char* input, char* output):
	if (strcmp(input, output) == 0): return 1
	file_stat in_stat
	file_stat out_stat
	if (file_stat_path(input, &in_stat) != 0): return 0
	if (file_stat_path(output, &out_stat) != 0): return 0
	return (in_stat.ino == out_stat.ino) && (in_stat.dev == out_stat.dev)


int main(int argc, int argv):
	if (__word_size__ != 8): return wllvm_error(c"build wllvm for a 64-bit host (./wbuild wllvm)")
	char* input = 0
	char* output = 0
	for i in range(1, argc):
		char** arg = argv + i * __word_size__
		if ((strcmp(*arg, c"--help") == 0) || (strcmp(*arg, c"-h") == 0)):
			wllvm_usage()
			return 0
		if (strcmp(*arg, c"-o") == 0):
			if (output != 0): return wllvm_error(c"-o may be specified only once")
			i = i + 1
			if (i >= argc): return wllvm_error(c"-o requires an output path")
			arg = argv + i * __word_size__
			output = *arg
			if (output[0] == 0): return wllvm_error(c"-o requires an output path")
		else if (starts_with(*arg, c"-")): return wllvm_error(c"unsupported option (run --help)")
		else:
			if (input != 0): return wllvm_error(c"expected exactly one input file")
			input = *arg
	if ((input == 0) || (output == 0)):
		wllvm_usage()
		return wllvm_error(c"an input file and -o output.ll are required")
	input = wllvm_absolute(input)
	output = wllvm_absolute(output)
	if (wllvm_same_file(input, output)): return wllvm_error(c"input and output must be different files")
	char** program = cast(char**, argv)
	compiler_argv0 = *program
	verbosity = -1
	quiet_mode = 1
	retained_query_mode = 1
	# Use the production analysis path and preserve its diagnostics. No LLVM
	# output is opened until both semantic analysis and subset validation pass.
	char* args = cast(char*, malloc(5 * __word_size__))
	save_ptr(args, cast(int, compiler_argv0))
	save_ptr(args + __word_size__, cast(int, c"x64"))
	save_ptr(args + 2 * __word_size__, cast(int, c"--quiet"))
	save_ptr(args + 3 * __word_size__, cast(int, c"--ast-required"))
	save_ptr(args + 4 * __word_size__, cast(int, input))
	int status = link_impl(5, cast(int, args), 1, 1)
	free(args)
	if (status == 0):
		if (llvm_emit(input, output) == 0): status = 1
	retained_clear()
	free(input)
	free(output)
	return status
