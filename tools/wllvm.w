# wbuild: binary=wllvm arch=x64
/*
Opt-in LLVM backend over the production compiler's retained forest (#337).
The front end still emits native code to the null device while binding the
trees: this is not an independent semantic-analysis pass. The tool writes
LLVM IR text, and for any output not named *.ll hands it to clang to build
a freestanding x86-64 (default) or AArch64 (--target arm64) Linux
executable: static with no C library, or dynamically linked against the
libraries a program's C imports name. LLVM is needed only for that last
step.
*/
import compiler.compiler
import tools.wllvm_emit
import lib.stat
import lib.process
import lib.env


int wllvm_error(char* message):
	print_error(c"wllvm: ")
	print_error(message)
	print_error(c"\n")
	return 1


void wllvm_usage():
	println(c"usage: wllvm [x64|arm64] input.w -o output [-O0|-O1|-O2|-O3|-Os] [--emit-llvm] [--cc clang] [--target x64|arm64]")
	println(c"Compile a W program through LLVM: production retained AST, x64 semantics.")
	println(c"An output named *.ll (or --emit-llvm) is LLVM IR text and needs no LLVM.")
	println(c"Any other output is a freestanding x86-64 (or, with arm64, AArch64) Linux")
	println(c"executable built by clang (--cc, else $WLLVM_CC, else clang on PATH) at -O2")
	println(c"unless another level is given; AArch64 links with ld.lld.")
	println(c"Subset: integer, bool, char, pointer, enum, string-handle and record types;")
	println(c"locals, globals, fixed arrays, calls (direct, indirect, syscall), if, while,")
	println(c"for-range, break, continue and return, across every module the entry reaches;")
	println(c"generics, floats, containers, checked pointers, setjmp, threads, stack")
	println(c"traces, and extern/c_import calls (linked dynamically, keeping W's _start).")
	println(c"Records by value and other constructs fail. The front end currently also")
	println(c"emits native code to the null device. To build IR by hand: clang -O2 -static -nostdlib output.ll -o program")
	println(c"  (with C imports, the IR names its link: clang -nostartfiles -l:libc.so.6 ...)")
	println(c"  (AArch64: add --target=aarch64-linux-gnu -fuse-ld=lld)")


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


# lib/stack_trace.w (print_stack_trace, the lib/crash.w reporter) reads
# .symtab and .debug_line from the running image at base + file offset, as
# native W executables map them. When every PT_LOAD shares one
# vaddr - offset, the first maps the ELF header and the last has no .bss
# (the emitter keeps globals in .data), the last one is extended to the end
# of the file. Other layouts are left as they are: traces then print
# nothing, like a native binary without symbols. Returns 0, or 1 when the
# file cannot be rewritten.
int wllvm_map_image(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0): return wllvm_error(c"cannot read the linked executable")
	string_builder* image = string_new()
	io_result r
	int status = stream_read_all_checked(in, image, &r)
	stream_close(in)
	char* data = image.data
	int length = image.length
	int patched = 0
	if ((status == IO_OK) && (length >= 64) && (data[0] == 127) && (data[1] == 'E') && (data[2] == 'L') && (data[3] == 'F') && (data[4] == 2)):
		int phoff = load_i(data + 32, 8)
		int phentsize = load_i(data + 54, 2)
		int phnum = load_i(data + 56, 2)
		char* last = 0
		int delta = -1
		int consistent = (phentsize == 56) && (phoff + phnum * 56 <= length)
		int first_offset = -1
		for k in range(phnum):
			if (consistent == 0): break
			char* header = data + phoff + k * 56
			if (load_i(header, 4) != 1): continue
			int offset = load_i(header + 8, 8)
			int here = load_i(header + 16, 8) - offset
			if ((delta != -1) && (here != delta)): consistent = 0
			delta = here
			if (first_offset == -1): first_offset = offset
			if ((last == 0) || (offset > load_i(last + 8, 8))): last = header
		if (consistent && (last != 0) && (first_offset == 0) && ((delta & 4095) == 0)):
			int offset = load_i(last + 8, 8)
			if ((load_i(last + 32, 8) == load_i(last + 40, 8)) && (offset < length)):
				save_i(last + 32, length - offset, 8)
				save_i(last + 40, length - offset, 8)
				patched = 1
	int failed = 0
	if (patched):
		io_result written
		if (file_write_text_checked(path, data, length, &written) != IO_OK): failed = wllvm_error(c"cannot rewrite the linked executable")
	string_free(image)
	return failed


# Build output from ir with clang; clang's diagnostics pass through. Shrink
# wrapping stays off so every prologue starts its function, where the
# trace reader looks for the frame-pointer push. A
# program with C imports links dynamically against their libraries but
# keeps W's own _start (-nostartfiles): the dynamic loader initializes the
# C library before it runs, and the program exits with exit_group, without
# C atexit handlers or a stdio flush, as the native backends do.
int wllvm_link(char* path, char* level, char* ir, char* output):
	list[char*] args = list[char*]{path, level, c"-Wno-override-module", c"-mllvm", c"-enable-shrink-wrap=false", c"-o", output, ir}
	if (llvm_dynamic):
		args.push(c"-nostartfiles")
		for soname in llvm_link_libraries: args.push(strjoin(c"-l:", soname))
	else:
		args.push(c"-static")
		args.push(c"-nostdlib")
	if (llvm_arm64):
		args.push(c"--target=aarch64-linux-gnu")
		args.push(c"-fuse-ld=lld")
		# 4KB segments at page-aligned file offsets, as the native arm64
		# image has: ld.lld's 64KB default leaves an unmapped gap between
		# the header and text segments, which lib/stack_trace.w's walk down
		# to the ELF header cannot cross, and separate-loadable-segments
		# gives every PT_LOAD the one vaddr - offset wllvm_map_image needs.
		args.push(c"-Wl,-z,max-page-size=4096")
		args.push(c"-Wl,-z,separate-loadable-segments")
	char** vector = strv_new(args.length)
	for i in range(args.length): strv_set(vector, i, args[i])
	process_result* result = process_run(path, vector, 0, 0, 600000)
	free(cast(void*, vector))
	args.free()
	if (result == 0): return wllvm_error(c"could not run clang")
	print_error(result.stdout_text)
	print_error(result.stderr_text)
	int status = result.status
	process_result_free(result)
	if (status != 0): return wllvm_error(c"clang failed")
	return wllvm_map_image(output)


int main(int argc, int argv):
	if (__word_size__ != 8): return wllvm_error(c"build wllvm for a 64-bit host (./wbuild wllvm)")
	char* input = 0
	char* output = 0
	char* level = c"-O2"
	char* cc = env_get(c"WLLVM_CC")
	if ((cc == 0) || (cc[0] == 0)): cc = c"clang"
	int emit_llvm = 0
	char* arch = c"x64"
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
		else if (strcmp(*arg, c"--cc") == 0):
			i = i + 1
			if (i >= argc): return wllvm_error(c"--cc requires a compiler")
			arg = argv + i * __word_size__
			cc = *arg
		else if (strcmp(*arg, c"--emit-llvm") == 0): emit_llvm = 1
		else if (strcmp(*arg, c"--target") == 0):
			i = i + 1
			if (i >= argc): return wllvm_error(c"--target requires x64 or arm64")
			arg = argv + i * __word_size__
			if ((strcmp(*arg, c"x64") != 0) && (strcmp(*arg, c"arm64") != 0)): return wllvm_error(c"--target requires x64 or arm64")
			arch = *arg
		# The arch selector W's other tools take before the input.
		else if ((input == 0) && ((strcmp(*arg, c"x64") == 0) || (strcmp(*arg, c"arm64") == 0))): arch = *arg
		else if ((strcmp(*arg, c"-O0") == 0) || (strcmp(*arg, c"-O1") == 0) || (strcmp(*arg, c"-O2") == 0) || (strcmp(*arg, c"-O3") == 0) || (strcmp(*arg, c"-Os") == 0)): level = *arg
		else if (starts_with(*arg, c"-")): return wllvm_error(c"unsupported option (run --help)")
		else:
			if (input != 0): return wllvm_error(c"expected exactly one input file")
			input = *arg
	if ((input == 0) || (output == 0)):
		wllvm_usage()
		return wllvm_error(c"an input file and -o output are required")
	if (ends_with(output, c".ll")): emit_llvm = 1
	input = wllvm_absolute(input)
	output = wllvm_absolute(output)
	if (wllvm_same_file(input, output)): return wllvm_error(c"input and output must be different files")
	# An executable is linked from IR next to it, removed afterwards.
	char* ir = output
	if (emit_llvm == 0):
		cc = process_which(cc)
		if ((cc == 0) || (path_exists(cc) == 0)): return wllvm_error(c"clang not found (install clang, set WLLVM_CC or pass --cc)")
		ir = strjoin(output, c".wllvm.ll")
		if (wllvm_same_file(input, ir)): return wllvm_error(c"input and output must be different files")
	char** program = cast(char**, argv)
	compiler_argv0 = *program
	verbosity = -1
	quiet_mode = 1
	retained_query_mode = 1
	# Use the production analysis path and preserve its diagnostics. No LLVM
	# output is opened until both semantic analysis and subset validation pass.
	# Functions with asm blocks compile their portable W bodies (--no-asm),
	# which grammar/asm_function.w requires to be equivalent.
	char* args = cast(char*, malloc(6 * __word_size__))
	save_ptr(args, cast(int, compiler_argv0))
	llvm_arm64 = strcmp(arch, c"arm64") == 0
	save_ptr(args + __word_size__, cast(int, arch))
	save_ptr(args + 2 * __word_size__, cast(int, c"--quiet"))
	save_ptr(args + 3 * __word_size__, cast(int, c"--ast-required"))
	save_ptr(args + 4 * __word_size__, cast(int, c"--no-asm"))
	save_ptr(args + 5 * __word_size__, cast(int, input))
	int status = link_impl(6, cast(int, args), 1, 1)
	free(args)
	if (status == 0):
		if (llvm_emit(input, ir) == 0): status = 1
	retained_clear()
	if ((status == 0) && (emit_llvm == 0)):
		status = wllvm_link(cc, level, ir, output)
		unlink(ir)
	free(input)
	free(output)
	return status
