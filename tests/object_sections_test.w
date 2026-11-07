# wbuild: deps=tests/object_sections/
# wbuild: deps=code_generator/elf_object.w
# Section placement and symbol attributes in --emit=obj objects
# (docs/projects/object_files.md, "Sections and symbol attributes"):
# readelf's view of the sections and symbols, a link with a linker
# script that collects custom sections into tables (initcall style),
# weak definitions overridden from C, and the attribute diagnostics.
import lib.testing
import tests.tool_e2e
import lib.file
import lib.str


char* sections_dir


char* sections_path(char* name):
	return path_join(sections_dir, name)


void sections_write(char* name, char* source):
	char* path = sections_path(name)
	assert_equal(1, file_write_text(path, source))
	free(path)


process_result* sections_wv2(char*[] args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	return tool_spawn(0, 60000, argv)


void sections_compile(char*... args):
	process_result* r = sections_wv2(args)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


# The object compile of source fails naming diagnostic.
void sections_reject(char* source, char* diagnostic):
	sections_write(c"rejected.w", source)
	char*[6] args
	args[0] = c"x64"
	args[1] = c"--emit=obj"
	args[2] = c"--freestanding"
	args[3] = sections_path(c"rejected.w")
	args[4] = c"-o"
	args[5] = sections_path(c"rejected.o")
	process_result* r = sections_wv2(args)
	assert_equal(1, r.status)
	assert_contains(r.stderr_text, diagnostic)
	process_result_free(r)


# A host tool through the shell; returns its stdout, requiring status 0.
char* sections_shell(char* command):
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


# The readelf line that mentions name (a section or symbol), or "".
char* sections_line(char* listing, char* name):
	int n = strlen(listing)
	int start = 0
	for i in range(n + 1):
		if ((i == n) || (listing[i] == 10)):
			char* line = str_copy_range(listing, start, i)
			if (contains(line, name)): return line
			free(line)
			start = i + 1
	return c""


void test_sections_setup():
	sections_dir = tool_scratch(c"object_sections_")
	assert_equal(0, mkdir(sections_dir, 493))


void test_sections_readelf():
	char* object = sections_path(c"library.o")
	sections_compile(c"x64", c"--emit=obj", c"--freestanding", c"tests/object_sections/library.w", c"-o", object)
	char* listing = sections_shell(strjoin(c"readelf -S -s -W ", object))
	# code sections are AX; .init.text takes the 64-byte function alignment
	assert_contains(sections_line(listing, c"] .init.text"), c"AX  0   0 64")
	assert_contains(sections_line(listing, c"] .text"), c"AX")
	# literals in .rodata, read-only; a .rodata* global the same
	assert_contains(sections_line(listing, c"] .rodata "), c" A  0")
	assert_contains(sections_line(listing, c"] .rodata.w_consts"), c" A  0")
	# zero globals in a NOBITS .bss; the zero page table's elements (its
	# symbol) force the .bss alignment, its W header stays in .data
	assert_contains(sections_line(listing, c"] .bss"), c"NOBITS")
	assert_contains(sections_line(listing, c"] .bss"), c"WA  0   0 4096")
	assert_contains(sections_line(listing, c"] .data "), c"WA  0   0 16")
	assert_contains(sections_line(listing, c"DEFAULT    5 w_page_table"), c"  4096 OBJECT  GLOBAL DEFAULT    5 w_page_table")
	assert_contains(sections_line(listing, c"] .w_initcall.1"), c"WA  0   0  8")
	assert_contains(sections_line(listing, c"] .w_table"), c"WA  0   0  8")
	assert_contains(listing, c".rela.init.text")
	assert_contains(sections_line(listing, c" w_zero_counter"), c" 5 w_zero_counter")
	# symbols in their sections; weak definitions and references
	assert_contains(sections_line(listing, c" w_init_first"), c"FUNC    GLOBAL DEFAULT    3 w_init_first")
	assert_contains(sections_line(listing, c" w_init_helper"), c"FUNC    LOCAL  DEFAULT    3 w_init_helper")
	assert_contains(sections_line(listing, c" w_weak_hook"), c"FUNC    WEAK   DEFAULT    1 w_weak_hook")
	assert_contains(sections_line(listing, c" c_optional_value"), c"WEAK   DEFAULT  UND c_optional_value")
	assert_contains(sections_line(listing, c"UND c_optional"), c"WEAK   DEFAULT  UND c_optional")
	assert_contains(sections_line(listing, c" w_answer"), c"OBJECT  GLOBAL DEFAULT    6 w_answer")
	assert_contains(sections_line(listing, c" w_table_b"), c"0000000000000008     8 OBJECT  GLOBAL")
	# the alias is a second global name at its target's address
	char* real = sections_line(listing, c"DEFAULT    1 w_real")
	char* alias = sections_line(listing, c" w_real_alias")
	assert_contains(alias, c"FUNC    GLOBAL DEFAULT    1 w_real_alias")
	int at = index_of(real, c": ") + 2
	int alias_at = index_of(alias, c": ") + 2
	assert_strings_equal(str_copy_range(real, at, at + 16), str_copy_range(alias, alias_at, alias_at + 16))
	free(listing)
	char* literals = sections_shell(strjoin(c"readelf -x .rodata ", object))
	assert_contains(literals, c"read-only litera")
	free(literals)
	free(object)


# A PIE, a non-PIE and a static executable with the linker script, then
# one whose C side overrides the weak W definition.
void test_sections_link_with_script():
	char* object = sections_path(c"linked.o")
	sections_compile(c"x64", c"--emit=obj", c"--freestanding", c"tests/object_sections/library.w", c"-o", object)
	char*[4] modes
	modes[0] = c""
	modes[1] = c"-no-pie"
	modes[2] = c"-static"
	modes[3] = c"-DSTRONG"
	for i in range(4):
		char* exe = sections_path(strjoin(c"host", itoa(i)))
		string_builder* cmd = string_new()
		string_append(cmd, c"cc ")
		string_append(cmd, modes[i])
		string_append(cmd, c" -o ")
		string_append(cmd, exe)
		string_append(cmd, c" tests/object_sections/main.c ")
		string_append(cmd, object)
		string_append(cmd, c" -Wl,-T,tests/object_sections/sections.ld")
		free(sections_shell(cmd.data))
		char* out = sections_shell(exe)
		assert_contains(out, c"object sections OK")
		free(out)
	free(object)


# --c-abi: the global symbols are System V entries in their sections,
# the adapters follow them, and C calls the initcall table directly.
void test_sections_c_abi():
	char* object = sections_path(c"c_abi.o")
	sections_compile(c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/object_sections/c_abi_library.w", c"-o", object)
	char* listing = sections_shell(strjoin(c"readelf -S -s -W ", object))
	assert_contains(sections_line(listing, c"] .init.text"), c"AX  0   0 64")
	assert_contains(sections_line(listing, c" init_level1"), c"FUNC    GLOBAL DEFAULT    3 init_level1")
	assert_contains(sections_line(listing, c" init_level6"), c"FUNC    GLOBAL DEFAULT    3 init_level6")
	assert_contains(sections_line(listing, c" init_helper"), c"FUNC    LOCAL  DEFAULT    3 init_helper")
	assert_contains(sections_line(listing, c" weak_hook"), c"FUNC    WEAK   DEFAULT    1 weak_hook")
	char* real = sections_line(listing, c"DEFAULT    1 real")
	char* alias = sections_line(listing, c" real_alias")
	assert_contains(alias, c"FUNC    GLOBAL DEFAULT    1 real_alias")
	int at = index_of(real, c": ") + 2
	int alias_at = index_of(alias, c": ") + 2
	assert_strings_equal(str_copy_range(real, at, at + 16), str_copy_range(alias, alias_at, alias_at + 16))
	# Brace data: an array's symbol is its elements, placed and aligned
	# by its attributes; all-zero arrays go to .bss.
	assert_contains(sections_line(listing, c"] .w_ops"), c"WA  0   0 32")
	assert_contains(sections_line(listing, c"] .w_vector"), c"WA  0   0 64")
	assert_contains(sections_line(listing, c" w_ops_table"), c"    64 OBJECT  GLOBAL DEFAULT    7 w_ops_table")
	assert_contains(sections_line(listing, c"DEFAULT    8 w_vector"), c"    16 OBJECT  GLOBAL DEFAULT    8 w_vector")
	assert_contains(sections_line(listing, c" w_zero_array"), c"    64 OBJECT  GLOBAL DEFAULT    9 w_zero_array")
	assert_contains(sections_line(listing, c" w_plain_array"), c"    64 OBJECT  GLOBAL DEFAULT    9 w_plain_array")
	assert_contains(sections_line(listing, c"] .bss"), c"NOBITS")
	free(listing)
	char*[4] modes
	modes[0] = c""
	modes[1] = c"-no-pie"
	modes[2] = c"-static"
	modes[3] = c"-DSTRONG"
	for i in range(4):
		char* exe = sections_path(strjoin(c"c_abi_host", itoa(i)))
		string_builder* cmd = string_new()
		string_append(cmd, c"cc ")
		string_append(cmd, modes[i])
		string_append(cmd, c" -o ")
		string_append(cmd, exe)
		string_append(cmd, c" tests/object_sections/c_abi_main.c ")
		string_append(cmd, object)
		string_append(cmd, c" -Wl,-T,tests/object_sections/sections.ld")
		free(sections_shell(cmd.data))
		char* out = sections_shell(exe)
		assert_contains(out, c"object sections c-abi OK")
		free(out)
	# The streaming front end binds weak calls through the symbol too.
	sections_compile(c"x64", c"--streaming", c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/object_sections/c_abi_library.w", c"-o", object)
	char* streaming = sections_path(c"c_abi_host_streaming")
	string_builder* streaming_cmd = string_new()
	string_append(streaming_cmd, c"cc -DSTRONG -o ")
	string_append(streaming_cmd, streaming)
	string_append(streaming_cmd, c" tests/object_sections/c_abi_main.c ")
	string_append(streaming_cmd, object)
	string_append(streaming_cmd, c" -Wl,-T,tests/object_sections/sections.ld")
	free(sections_shell(streaming_cmd.data))
	char* streaming_out = sections_shell(streaming)
	assert_contains(streaming_out, c"object sections c-abi OK")
	free(streaming_out)
	free(object)


# Attributes compile everywhere: an ordinary executable ignores the
# placement and keeps the alias.
void test_sections_native_executable():
	sections_write(c"native.w", c"@section(\".init.text\") @weak @used\nint base(int a):\n\treturn a + 1\n\n\n@alias(\"base\")\nint other(int a);\n\n\n@align(64)\nint cell = 3\n\n\nint main():\n\treturn other(cell) + base(1)\n")
	char* exe = sections_path(c"native")
	sections_compile(c"x64", sections_path(c"native.w"), c"-o", exe)
	char* status = sections_shell(strjoin(exe, c"; echo status=$?"))
	assert_contains(status, c"status=6")
	free(status)
	free(exe)


void test_sections_diagnostics():
	sections_reject(c"@inline\nint f():\n\treturn 1\n", c"unknown attribute '@inline'")
	sections_reject(c"@align(48)\nint g\n", c"'@align' needs a power of two between 1 and 1048576")
	sections_reject(c"@section(7)\nint g\n", c"attribute '@section' expects a \"string\" argument")
	sections_reject(c"@section(\"\")\nint g\n", c"attribute '@section' needs a non-empty name")
	sections_reject(c"@weak\nstruct point:\n\tint x\n", c"attributes must precede a function, global or extern declaration")
	sections_reject(c"@section(\".x\")\nextern int c_f(int a)\n", c"an extern declaration takes no '@section', '@align' or '@alias'")
	sections_reject(c"int f():\n\treturn 1\n\n\n@alias(\"f\")\nint g():\n\treturn 2\n", c"an '@alias' declaration has no body")
	sections_reject(c"int g = 1\n@alias(\"g\")\nint h = 2\n", c"an '@alias' declaration has no initializer")
	sections_reject(c"@alias(\"missing\")\nint h(int a);\n", c"alias target 'missing' is never defined")
	sections_reject(c"@section(\".bss.w\")\nint g = 1\n", c"global in section '.bss.w' must be zero-initialized")
	sections_reject(c"@section(\".mixed\")\nint g = 1\n\n\n@section(\".mixed\")\nint f():\n\treturn 1\n", c"section '.mixed' holds both functions and data")


void test_sections_cleanup():
	dir_remove_all(sections_dir)
	free(sections_dir)
