# wbuild: deps=tests/object_layout/
# wbuild: deps=code_generator/elf_object.w
# --emit=obj --freestanding --c-abi data layout and extern calls
# (docs/projects/object_files.md): a static whose record type completes
# later keeps its full size and the extern slots after it out of .bss,
# an empty-record static stays out of the next global's section, an
# array nothing in the object reaches has no header relocation into its
# section, and extern calls are direct PLT32 calls. The object links
# with C directly and after 'ld -r', which drops relocations against
# NOBITS sections.
import lib.testing
import tests.tool_e2e
import lib.file
import lib.str


char* layout_dir


char* layout_path(char* name):
	return path_join(layout_dir, name)


void layout_compile(char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 60000, argv)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


# A host tool through the shell; returns its stdout, requiring status 0.
char* layout_shell(char* command):
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


# The listing line that mentions name, or "".
char* layout_line(char* listing, char* name):
	int n = strlen(listing)
	int start = 0
	for i in range(n + 1):
		if ((i == n) || (listing[i] == 10)):
			char* line = str_copy_range(listing, start, i)
			if (contains(line, name)): return line
			free(line)
			start = i + 1
	return c""


void test_layout_setup():
	layout_dir = tool_scratch(c"object_layout_")
	assert_equal(0, mkdir(layout_dir, 493))


void test_layout_readelf():
	char*[2] fronts
	fronts[0] = c"--strict"
	fronts[1] = c"--streaming"
	for f in range(2):
		char* object = layout_path(strjoin(c"layout", strjoin(itoa(f), c".o")))
		layout_compile(c"x64", fronts[f], c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/object_layout/layout_library.w", c"-o", object)
		char* listing = layout_shell(strjoin(c"readelf -S -s -r -W ", object))
		# nothing relocated lives in .bss
		assert1(contains(listing, c".rela.bss") == 0)
		# the late-completed record has its full size; the empty-record
		# lock is a 0-byte symbol of its own in .bss
		assert_contains(layout_line(listing, c" rootfs"), c"    24 OBJECT  LOCAL  DEFAULT    3 rootfs")
		assert_contains(layout_line(listing, c" once_lock"), c"     0 OBJECT  LOCAL  DEFAULT    3 once_lock")
		assert_contains(layout_line(listing, c" discard_keep"), c"OBJECT  LOCAL  DEFAULT    4 discard_keep")
		# the unreached array's W header references no section
		assert1(contains(listing, c".layout_info + 0") == 0)
		# direct calls; only the function value keeps a slot
		assert_contains(listing, c"R_X86_64_PLT32         0000000000000000 c_record - 4")
		assert_contains(listing, c"R_X86_64_PLT32         0000000000000000 c_twice - 4")
		assert1(contains(listing, c"R_X86_64_64            0000000000000000 c_record") == 0)
		assert_contains(listing, c"R_X86_64_64            0000000000000000 c_twice + 0")
		free(listing)
		char* code = layout_shell(strjoin(c"objdump -d ", object))
		assert_contains(code, c"addr32 call")
		free(code)
		free(object)


# Linked directly and through 'ld -r', as PIE and static executables.
void test_layout_links_with_c():
	char* object = layout_path(c"linked.o")
	char* relocatable = layout_path(c"linked_r.o")
	layout_compile(c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/object_layout/layout_library.w", c"-o", object)
	free(layout_shell(strjoin(strjoin(strjoin(c"ld -r -o ", relocatable), c" "), object)))
	char*[2] inputs
	inputs[0] = object
	inputs[1] = relocatable
	char*[2] modes
	modes[0] = c""
	modes[1] = c"-static"
	for i in range(2):
		for m in range(2):
			char* exe = layout_path(strjoin(c"host", strjoin(itoa(i), itoa(m))))
			string_builder* cmd = string_new()
			string_append(cmd, c"cc ")
			string_append(cmd, modes[m])
			string_append(cmd, c" -o ")
			string_append(cmd, exe)
			string_append(cmd, c" tests/object_layout/layout_main.c ")
			string_append(cmd, inputs[i])
			free(layout_shell(cmd.data))
			char* out = layout_shell(exe)
			assert_contains(out, c"object layout OK")
			free(out)
			free(exe)
	free(object)
	free(relocatable)


void test_layout_cleanup():
	dir_remove_all(layout_dir)
	free(layout_dir)
