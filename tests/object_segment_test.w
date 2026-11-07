# wbuild: deps=tests/object_segment/
# wbuild: deps=code_generator/x86.w
# Segment address spaces (__seg_gs / __seg_fs, docs/projects/
# object_files.md "Segment-relative accesses"): a --emit=obj
# --freestanding --c-abi object whose per-CPU style accesses go through
# %gs and %fs, linked with a C driver that points the segment bases at a
# copy of the data with arch_prctl and cross-checks with gcc's own
# __seg_gs; the instruction encodings; the 32-bit target; and the
# qualifier's diagnostics.
import lib.testing
import tests.tool_e2e
import lib.file
import lib.str


char* segment_dir


char* segment_path(char* name):
	return path_join(segment_dir, name)


process_result* segment_wv2(char*[] args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	return tool_spawn(0, 60000, argv)


void segment_compile(char*... args):
	process_result* r = segment_wv2(args)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


# A host tool through the shell; returns its stdout, requiring status 0.
char* segment_shell(char* command):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/sh")
	strv_set(argv, 1, c"-c")
	strv_set(argv, 2, command)
	process_result* r = process_run(c"/bin/sh", argv, 0, 0, 60000)
	assert1(r != 0)
	if (r.status != 0):
		println2(command)
		println2(r.stdout_text)
		println2(r.stderr_text)
	assert_equal(0, r.status)
	char* out = strclone(r.stdout_text)
	process_result_free(r)
	free(cast(void*, argv))
	return out


# 'wv2 x64 check' of source fails naming diagnostic.
void segment_reject(char* target, char* source, char* diagnostic):
	char* path = segment_path(c"rejected.w")
	assert_equal(1, file_write_text(path, source))
	char*[3] args
	args[0] = target
	args[1] = c"check"
	args[2] = path
	process_result* r = segment_wv2(args)
	assert_equal(1, r.status)
	assert_contains(r.stderr_text, diagnostic)
	process_result_free(r)
	free(path)


void test_segment_setup():
	segment_dir = tool_scratch(c"object_segment_")
	assert_equal(0, mkdir(segment_dir, 493))


# The object linked as a PIE, a non-PIE and a static executable, built by
# both front ends and without register promotion.
void test_segment_link_and_run():
	char*[3] flags
	flags[0] = c"--c-abi"
	flags[1] = c"--streaming"
	flags[2] = c"--no-regs"
	char*[3] modes
	modes[0] = c""
	modes[1] = c"-no-pie"
	modes[2] = c"-static"
	for f in range(3):
		char* object = segment_path(strjoin(c"library", strjoin(itoa(f), c".o")))
		segment_compile(c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", flags[f], c"tests/object_segment/library.w", c"-o", object)
		for i in range(3):
			char* exe = segment_path(strjoin(c"host", itoa(f * 3 + i)))
			string_builder* cmd = string_new()
			string_append(cmd, c"cc -fno-stack-protector ")
			string_append(cmd, modes[i])
			string_append(cmd, c" -o ")
			string_append(cmd, exe)
			string_append(cmd, c" tests/object_segment/main.c ")
			string_append(cmd, object)
			free(segment_shell(cmd.data))
			char* out = segment_shell(exe)
			assert_contains(out, c"object segment OK")
			free(out)
			free(exe)
		free(object)


# The override prefix leads each access, ahead of REX.
void test_segment_encoding():
	char* object = segment_path(c"encoding.o")
	segment_compile(c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/object_segment/library.w", c"-o", object)
	char* listing = segment_shell(strjoin(c"objdump -d ", object))
	assert_contains(listing, c"65 48 8b 00          \tmov    %gs:(%rax),%rax")
	assert_contains(listing, c"%gs:")
	assert_contains(listing, c"%fs:")
	free(listing)
	free(object)


# The 32-bit target takes the same qualifier (its %fs/%gs prefixes have
# no REX to precede).
void test_segment_x86():
	char* source = segment_path(c"x86.w")
	assert_equal(1, file_write_text(source, c"__seg_fs int cell\n\n\nint seg_read(__seg_gs int* p):\n\tcell = 4\n\treturn p[1] + cell\n\n\nint main():\n\treturn 0\n"))
	char* exe = segment_path(c"x86")
	segment_compile(source, c"-o", exe)
	char* status = segment_shell(strjoin(exe, c"; echo status=$?"))
	assert_contains(status, c"status=0")
	free(status)
	free(exe)
	free(source)


void test_segment_diagnostics():
	segment_reject(c"x64", c"void f():\n\t__seg_gs int x = 1\n", c"a local variable cannot live in a segment address space")
	segment_reject(c"x64", c"int f(__seg_gs int x):\n\treturn x\n", c"a parameter cannot live in a segment address space")
	segment_reject(c"x64", c"struct s:\n\t__seg_fs int a\n", c"a struct field cannot live in a segment address space")
	segment_reject(c"x64", c"union u:\n\t__seg_fs int a\n", c"a union field cannot live in a segment address space")
	segment_reject(c"x64", c"__seg_gs int[4] a\n", c"a segment address space holds scalars, pointers and structs")
	segment_reject(c"x64", c"__seg_gs(char[]) a\n", c"a segment address space holds scalars, pointers and structs")
	segment_reject(c"x64", c"struct p:\n\tint a\n\n\n__seg_gs p g\np h\n\n\nvoid f():\n\tg = h\n", c"struct copies to or from a segment address space are not supported")
	segment_reject(c"x64", c"__seg_gs const int g\n\n\nvoid f():\n\tg = 2\n", c"assignment to const")
	segment_reject(c"x64", c"__seg_gs nothing* p\n", c"unknown type name: 'nothing'")
	segment_reject(c"arm64", c"__seg_gs int g\n", c"segment address spaces (__seg_gs, __seg_fs) need the x86 or x64 target")


# The qualifier spellings stay ordinary identifiers where they name one.
void test_segment_contextual():
	char* source = segment_path(c"names.w")
	assert_equal(1, file_write_text(source, c"int __seg_gs = 3\n\n\nint main():\n\tconst __seg_fs int* p = cast(const __seg_fs int*, 0)\n\tif (p != 0): return 1\n\treturn __seg_gs\n"))
	char* exe = segment_path(c"names")
	segment_compile(c"x64", source, c"-o", exe)
	char* status = segment_shell(strjoin(exe, c"; echo status=$?"))
	assert_contains(status, c"status=3")
	free(status)
	free(exe)
	free(source)


void test_segment_cleanup():
	dir_remove_all(segment_dir)
	free(segment_dir)
