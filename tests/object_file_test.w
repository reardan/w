# wbuild: deps=tests/object_file/
# wbuild: deps=code_generator/elf_object.w
# --emit=obj end to end (docs/projects/object_files.md): W objects
# linked into C programs by the system C compiler, the object's ELF
# structure, readelf's view of it, and the diagnostics of the object and
# freestanding modes. Scratch artifacts stay private to this test.
import lib.testing
import tests.tool_e2e
import lib.file


char* object_dir


char* object_path(char* name):
	return path_join(object_dir, name)


void object_write(char* name, char* source):
	char* path = object_path(name)
	assert_equal(1, file_write_text(path, source))
	free(path)


void object_compile(char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 60000, argv)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


# The compile fails with a controlled diagnostic naming the problem.
void object_reject(char* diagnostic, char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 60000, argv)
	assert_equal(1, r.status)
	assert_contains(r.stderr_text, diagnostic)
	process_result_free(r)


# A host tool (cc, readelf) through the shell's PATH search; returns
# its stdout and requires exit status 0.
char* object_shell(char* command):
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


char* object_read(char* path, int* size_out):
	int fd = open(path, 0, 0)
	assert1(fd >= 0)
	int size = file_size(fd)
	char* bytes = cast(char*, malloc(size + 1))
	int have = 0
	while (have < size):
		int n = read(fd, bytes + have, size - have)
		assert1(n > 0)
		have = have + n
	close(fd)
	*size_out = size
	return bytes


void test_object_setup():
	object_dir = tool_scratch(c"object_file_")
	assert_equal(0, mkdir(object_dir, 493))


# Link the freestanding library with C as a PIE, a non-PIE and a fully
# static executable; each checks every W <-> C crossing itself.
void test_object_links_with_c():
	char* object = object_path(c"library.o")
	object_compile(c"x64", c"--emit=obj", c"--freestanding", c"tests/object_file/library.w", c"-o", object)
	char*[3] modes
	modes[0] = c""
	modes[1] = c"-no-pie"
	modes[2] = c"-static"
	for i in range(3):
		char* exe = object_path(strjoin(c"host", itoa(i)))
		string_builder* cmd = string_new()
		string_append(cmd, c"cc ")
		string_append(cmd, modes[i])
		string_append(cmd, c" -o ")
		string_append(cmd, exe)
		string_append(cmd, c" tests/object_file/main.c ")
		string_append(cmd, object)
		free(object_shell(cmd.data))
		char* out = object_shell(exe)
		assert_contains(out, c"object file OK")
		free(out)
	free(object)


# The runtime-retaining mode: sets, lists and maps inside the object,
# with an allocator of its own beside libc's.
void test_object_keeps_private_runtime():
	char* object = object_path(c"runtime.o")
	object_compile(c"x64", c"--emit=obj", c"tests/object_file/runtime_library.w", c"-o", object)
	char* exe = object_path(c"runtime_host")
	free(object_shell(strjoin(strjoin(strjoin(c"cc -o ", exe), c" tests/object_file/runtime_main.c "), object)))
	char* out = object_shell(exe)
	assert_contains(out, c"object runtime OK")
	free(out)
	free(exe)
	free(object)


int object_u16(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8)


# Section header i of the image (64 bytes each, at e_shoff).
char* object_section(char* image, int i):
	return image + load_int32(image + 40) + i * 64


char* object_section_name(char* image, int i):
	char* names = object_section(image, object_u16(image + 62))
	return image + load_int32(names + 24) + load_int32(object_section(image, i))


# Binding/type/section of the named symbol: binding * 256 + type, and
# the section index through shndx_out; -1 when absent.
int object_symbol(char* image, char* name, int* shndx_out):
	char* symtab = object_section(image, 4)
	char* strtab = object_section(image, load_int32(symtab + 40))
	int count = load_int32(symtab + 32) / 24
	for i in range(count):
		char* sym = image + load_int32(symtab + 24) + i * 24
		if (strcmp(image + load_int32(strtab + 24) + load_int32(sym), name) == 0):
			*shndx_out = object_u16(sym + 6)
			return ((sym[4] & 255) >> 4) * 256 + (sym[4] & 15)
	return -1


# Relocation types in section i: PC32 count * 1000 + R_X86_64_64 count;
# any other type fails.
int object_relocation_kinds(char* image, int i):
	char* rela = object_section(image, i)
	int count = load_int32(rela + 32) / 24
	int pc32 = 0
	int abs64 = 0
	for r in range(count):
		int kind = load_int32(image + load_int32(rela + 24) + r * 24 + 8)
		if (kind == 2): pc32 = pc32 + 1
		else:
			assert_equal(1, kind)
			abs64 = abs64 + 1
	return pc32 * 1000 + abs64


void test_object_elf_structure():
	char* object = object_path(c"structure.o")
	object_compile(c"x64", c"--emit=obj", c"--freestanding", c"tests/object_file/library.w", c"-o", object)
	int size = 0
	char* image = object_read(object, &size)
	assert1(size > 64)
	assert_equal(2, image[4])               # ELFCLASS64
	assert_equal(1, object_u16(image + 16)) # ET_REL
	assert_equal(62, object_u16(image + 18))
	assert_equal(9, object_u16(image + 60))
	assert_strings_equal(c".text", object_section_name(image, 1))
	assert_strings_equal(c".data", object_section_name(image, 2))
	assert_strings_equal(c".note.GNU-stack", object_section_name(image, 3))
	assert_strings_equal(c".rela.text", object_section_name(image, 6))
	assert_strings_equal(c".rela.data", object_section_name(image, 7))
	int shndx = 0
	# exported functions: GLOBAL FUNC in .text
	assert_equal(256 + 2, object_symbol(image, c"w_add", &shndx))
	assert_equal(1, shndx)
	# root globals: GLOBAL OBJECT in .data
	assert_equal(256 + 1, object_symbol(image, c"w_counter", &shndx))
	assert_equal(2, shndx)
	# extern functions and data: GLOBAL undefined
	assert_equal(256, object_symbol(image, c"c_scale", &shndx))
	assert_equal(0, shndx)
	assert_equal(256, object_symbol(image, c"c_value", &shndx))
	assert_equal(0, shndx)
	# unexported W functions stay local
	assert_equal(2, object_symbol(image, c"w_double", &shndx))
	assert_equal(1, shndx)
	# no entry stub and no runtime: nothing like main or malloc
	assert_equal(-1, object_symbol(image, c"main", &shndx))
	assert_equal(-1, object_symbol(image, c"malloc", &shndx))
	int text_kinds = object_relocation_kinds(image, 6)
	assert1(text_kinds >= 1000)
	assert_equal(0, text_kinds % 1000)
	int data_kinds = object_relocation_kinds(image, 7)
	assert_equal(0, data_kinds / 1000)
	assert1(data_kinds >= 8)
	free(image)
	char* listing = object_shell(strjoin(c"readelf -a -W ", object))
	assert_contains(listing, c"REL (Relocatable file)")
	assert_contains(listing, c"R_X86_64_PC32")
	assert_contains(listing, c"R_X86_64_64")
	assert_contains(listing, c"UND c_record")
	assert_contains(listing, c"GLOBAL DEFAULT    1 w_apply")
	free(listing)
	free(object)


void test_object_mode_rejections():
	char* out = object_path(c"rejected.o")
	object_write(c"plain.w", c"export int plain(int a):\n\treturn a\n")
	char* plain = object_path(c"plain.w")
	object_reject(c"--emit=obj requires the x64 Linux target", c"--emit=obj", plain, c"-o", out)
	object_reject(c"--emit=obj requires the x64 Linux target", c"arm64", c"--emit=obj", plain, c"-o", out)
	object_reject(c"--emit=obj and --static are mutually exclusive", c"x64", c"--emit=obj", c"--static", plain, c"-o", out)
	object_reject(c"--emit=obj and --shared are mutually exclusive", c"x64", c"--emit=obj", c"--shared", plain, c"-o", out)
	object_reject(c"--emit=obj does not support profiling", c"x64", c"--emit=obj", c"--profile-generate", plain, c"-o", out)
	object_reject(c"--freestanding requires --emit=obj", c"x64", c"--freestanding", plain, c"-o", out)
	object_write(c"tls.w", c"thread_local int slot\nexport int get():\n\treturn slot\n")
	object_reject(c"--emit=obj does not support thread_local", c"x64", c"--emit=obj", object_path(c"tls.w"), c"-o", out)
	free(plain)
	free(out)


void object_freestanding_reject(char* body, char* diagnostic):
	object_write(c"needs_runtime.w", strjoin(strjoin(c"export int f(int a):\n\t", body), c"\n\treturn a\n"))
	object_reject(diagnostic, c"x64", c"--emit=obj", c"--freestanding", object_path(c"needs_runtime.w"), c"-o", object_path(c"needs_runtime.o"))


void test_object_freestanding_rejects_runtime_features():
	object_freestanding_reject(c"map[int, int] m", c"'map' types need the W container runtime, which --freestanding excludes")
	object_freestanding_reject(c"set[int] s", c"'set' types need the W container runtime")
	object_freestanding_reject(c"list[int] l", c"'list' types need the W container runtime")
	object_freestanding_reject(c"int* p = new int", c"'new' needs the W runtime allocator, which --freestanding excludes")
	object_freestanding_reject(c"print(a)", c"this needs the W runtime module 'structures.prelude', which --freestanding excludes")
	object_freestanding_reject(c"char* s = f\"{a}\"", c"this needs the W runtime module 'structures.string'")


# A failed bounds check has no runtime diagnostic helper: it stops on
# ud2 (SIGILL) instead of linking against a missing symbol.
void test_object_freestanding_bounds_trap():
	object_write(c"bounds.w", c"int[2] cells\nexport int poke(int i):\n\tcells[i] = 1\n\treturn i\n")
	char* object = object_path(c"bounds.o")
	object_compile(c"x64", c"--emit=obj", c"--freestanding", object_path(c"bounds.w"), c"-o", object)
	object_write(c"bounds.c", c"long poke(long);\nint main(int argc, char** argv) { return poke(argc) == 1 && poke(argc + 5) == 6; }\n")
	char* exe = object_path(c"bounds_host")
	free(object_shell(strjoin(strjoin(strjoin(strjoin(c"cc -o ", exe), c" "), object_path(c"bounds.c")), strjoin(c" ", object))))
	char* status = object_shell(strjoin(exe, c"; echo status=$?"))
	assert_contains(status, c"status=132")
	free(status)
	free(exe)
	free(object)


# Address initializers (grammar/program.w) name a global variable, a
# function or a c"..." literal and need a word to hold the address.
void test_global_address_initializer_rejections():
	char* out = object_path(c"address_init")
	object_write(c"narrow.w", c"int base = 1\nint32 narrow = &base\nint main():\n\treturn 0\n")
	object_reject(c"global 'narrow' holds an address and needs a pointer or word-sized type", c"x64", object_path(c"narrow.w"), c"-o", out)
	object_write(c"local.w", c"int* p = &missing\nint main():\n\treturn 0\n")
	object_reject(c"'&' in a global initializer needs a global variable, got 'missing'", object_path(c"local.w"), c"-o", out)
	object_write(c"undefined.w", c"int f(int x);\nint g = f\nint main():\n\treturn 0\n")
	object_reject(c"function 'f' used in a global initializer is never defined", object_path(c"undefined.w"), c"-o", out)
	object_write(c"wasm.w", c"int base = 1\nint* p = &base\nint main():\n\treturn 0\n")
	object_reject(c"address initializers for globals are not supported on the wasm target", c"wasm", object_path(c"wasm.w"), c"-o", out)
	free(out)


void test_object_cleanup():
	dir_remove_all(object_dir)
	free(object_dir)
