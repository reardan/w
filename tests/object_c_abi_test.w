# wbuild: deps=tests/object_file/
# wbuild: deps=code_generator/c_abi.w
# --emit=obj --freestanding --c-abi end to end
# (docs/projects/object_files.md, "The C ABI mode"): a W object whose
# functions and function pointers are System V ones, linked with a C
# driver that calls W by name and through tables, and hands W C
# callbacks; the symbol bindings ('static' functions and globals stay
# local) and the mode's diagnostics.
import lib.testing
import tests.tool_e2e
import lib.file


char* abi_dir


char* abi_path(char* name):
	return path_join(abi_dir, name)


void abi_write(char* name, char* source):
	char* path = abi_path(name)
	assert_equal(1, file_write_text(path, source))
	free(path)


void abi_compile(char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 60000, argv)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


# The compile fails with a controlled diagnostic naming the problem.
void abi_reject(char* diagnostic, char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 60000, argv)
	assert_equal(1, r.status)
	assert_contains(r.stderr_text, diagnostic)
	process_result_free(r)


# A host tool (cc, readelf) through the shell; returns its stdout and
# requires exit status 0.
char* abi_shell(char* command):
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


void test_c_abi_setup():
	abi_dir = tool_scratch(c"object_c_abi_")
	assert_equal(0, mkdir(abi_dir, 493))


# The library under each front end, linked as a PIE, a non-PIE and a
# fully static executable; the C driver checks every crossing.
void test_c_abi_links_with_c():
	char*[3] fronts
	fronts[0] = c"--ast-required"
	fronts[1] = c"--streaming"
	fronts[2] = c"-O0"
	char*[3] modes
	modes[0] = c""
	modes[1] = c"-no-pie"
	modes[2] = c"-static"
	for f in range(3):
		char* object = abi_path(strjoin(c"library", strjoin(itoa(f), c".o")))
		abi_compile(c"x64", fronts[f], c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/object_file/c_abi_library.w", c"-o", object)
		for i in range(3):
			if ((f > 0) && (i > 0)): continue
			char* exe = abi_path(strjoin(c"host", strjoin(itoa(f), itoa(i))))
			string_builder* cmd = string_new()
			string_append(cmd, c"cc ")
			string_append(cmd, modes[i])
			string_append(cmd, c" -o ")
			string_append(cmd, exe)
			string_append(cmd, c" tests/object_file/c_abi_main.c ")
			string_append(cmd, object)
			free(abi_shell(cmd.data))
			char* out = abi_shell(exe)
			assert_contains(out, c"c abi object OK")
			free(out)
		free(object)


# Root functions are GLOBAL FUNC, 'static' ones and imported ones LOCAL;
# a 'static' global is LOCAL too.
void test_c_abi_symbols():
	char* object = abi_path(c"symbols.o")
	abi_compile(c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/object_file/c_abi_library.w", c"-o", object)
	char* listing = abi_shell(strjoin(c"readelf -s -W ", object))
	assert_contains(listing, c"FUNC    GLOBAL DEFAULT    1 w_add")
	assert_contains(listing, c"FUNC    GLOBAL DEFAULT    1 w_pick")
	assert_contains(listing, c"FUNC    LOCAL  DEFAULT    1 w_hidden")
	assert_contains(listing, c"OBJECT  GLOBAL DEFAULT    2 w_table_add")
	assert_contains(listing, c"OBJECT  LOCAL  DEFAULT    2 w_private_total")
	assert_contains(listing, c"NOTYPE  GLOBAL DEFAULT  UND c_weigh8")
	free(listing)
	char* relocations = abi_shell(strjoin(c"readelf -r -W ", object))
	# the static table cell holding c_sub's address is relocated to it
	assert_contains(relocations, c"R_X86_64_64            0000000000000000 c_sub + 0")
	free(relocations)
	free(object)


# Without --c-abi, 'static' still makes a root global or function local
# in an object; executables accept and ignore it.
void test_static_without_c_abi():
	abi_write(c"plain_static.w", c"static int hidden_value = 4\nint shown_value = 5\nstatic int helper(int a):\n\treturn a + hidden_value\n\nexport int shown(int a):\n\treturn helper(a) + shown_value\n\nint main():\n\treturn shown(1) - 10\n")
	char* object = abi_path(c"plain_static.o")
	abi_compile(c"x64", c"--emit=obj", c"--freestanding", abi_path(c"plain_static.w"), c"-o", object)
	char* listing = abi_shell(strjoin(c"readelf -s -W ", object))
	assert_contains(listing, c"OBJECT  LOCAL  DEFAULT    2 hidden_value")
	assert_contains(listing, c"OBJECT  GLOBAL DEFAULT    2 shown_value")
	assert_contains(listing, c"FUNC    LOCAL  DEFAULT    1 helper")
	assert_contains(listing, c"FUNC    GLOBAL DEFAULT    1 shown")
	free(listing)
	free(object)
	char* exe = abi_path(c"plain_static")
	abi_compile(c"x64", abi_path(c"plain_static.w"), c"-o", exe)
	char* status = abi_shell(strjoin(exe, c"; echo status=$?"))
	assert_contains(status, c"status=0")
	free(status)
	free(exe)


# 'export' makes an imported module's function global too; an imported
# function whose signature has no System V form is fine as long as
# nothing takes its address (its entry stub traps).
void test_c_abi_imported_module():
	abi_write(c"abi_helper.w", c"struct pair:\n\tint a\n\tint b\n\nint pair_first(pair p):\n\treturn p.a\n\nint helper_twice(int a):\n\treturn a * 2\n\nexport int helper_exported(int a):\n\treturn a + 1\n")
	abi_write(c"abi_root.w", c"import abi_helper\n\nint root_value(int a):\n\tpair p\n\tp.a = a\n\treturn pair_first(p) + helper_twice(a) + helper_exported(a)\n")
	char* object = abi_path(c"abi_root.o")
	abi_compile(c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", c"--import-root", abi_dir, abi_path(c"abi_root.w"), c"-o", object)
	char* listing = abi_shell(strjoin(c"readelf -s -W ", object))
	assert_contains(listing, c"FUNC    GLOBAL DEFAULT    1 root_value")
	assert_contains(listing, c"FUNC    GLOBAL DEFAULT    1 helper_exported")
	assert_contains(listing, c"FUNC    LOCAL  DEFAULT    1 helper_twice")
	free(listing)
	abi_write(c"abi_root.c", c"long root_value(long);\nlong helper_exported(long);\nint main(void) { return !(root_value(5) == 21 && helper_exported(1) == 2); }\n")
	char* exe = abi_path(c"abi_root")
	free(abi_shell(strjoin(strjoin(strjoin(strjoin(c"cc -o ", exe), c" "), abi_path(c"abi_root.c")), strjoin(c" ", object))))
	free(abi_shell(exe))
	free(exe)
	free(object)


void abi_reject_source(char* source, char* diagnostic):
	abi_write(c"rejected.w", source)
	abi_reject(diagnostic, c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", abi_path(c"rejected.w"), c"-o", abi_path(c"rejected.o"))


void test_c_abi_rejections():
	char* out = abi_path(c"rejected.o")
	abi_write(c"plain.w", c"int plain(int a):\n\treturn a\n")
	char* plain = abi_path(c"plain.w")
	abi_reject(c"--c-abi requires --emit=obj --freestanding", c"x64", c"--emit=obj", c"--c-abi", plain, c"-o", out)
	abi_reject(c"--c-abi requires --emit=obj --freestanding", c"x64", c"--c-abi", plain, c"-o", out)
	abi_reject(c"--c-abi cannot be combined with --no-direct-calls", c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", c"--no-direct-calls", plain, c"-o", out)
	free(plain)
	free(out)
	char* pair = c"struct pair:\n\tint a\n\tint b\n\n"
	abi_reject_source(strjoin(pair, c"int first(pair p):\n\treturn p.a\n"), c"function 'first' takes a struct by value, which --c-abi does not support yet")
	abi_reject_source(strjoin(pair, c"pair make(int a):\n\tpair p\n\tp.a = a\n\treturn p\n"), c"function 'make' returns a struct by value, which --c-abi does not support yet")
	abi_reject_source(c"int total(int... xs):\n\treturn xs.length\n", c"function 'total' is variadic, which --c-abi does not support yet")
	# a static function is no symbol, but its address still needs an entry
	abi_reject_source(strjoin(pair, c"static int first(pair p):\n\treturn p.a\n\nint* take():\n\treturn cast(int*, first)\n"), c"function 'first' takes a struct by value, which --c-abi does not support yet")
	abi_reject_source(strjoin(pair, c"type maker = fn(int) -> pair\n\nint call(maker* f):\n\tpair p = f(1)\n\treturn p.a\n"), c"--c-abi does not support calls through function pointers that return a struct by value yet")
	abi_reject_source(strjoin(pair, c"type taker = fn(pair) -> int\n\nint call(taker* f, pair* p):\n\treturn f(*p)\n"), c"--c-abi does not support passing a struct by value through a function pointer yet")
	# the compiler's asm runtime stubs have no System V entry
	abi_reject_source(c"int* take():\n\treturn cast(int*, syscall)\n", c"--c-abi cannot take the address of 'syscall': it has no System V entry")
	abi_reject_source(c"static export int f(int a):\n\treturn a\n", c"'static' must be followed by a function or global definition")
	abi_reject_source(c"static T pick[T](T a):\n\treturn a\n", c"'static' must be followed by a function or global definition")


void test_c_abi_cleanup():
	dir_remove_all(abi_dir)
	free(abi_dir)
