# W-native static archives are compiled code, usable without source or
# the archive at runtime. Keep scratch artifacts private to this test.
import lib.testing
import tests.tool_e2e
import lib.file


char* static_test_dir


char* static_path(char* name):
	return path_join(static_test_dir, name)


void static_write(char* name, char* source):
	char* path = static_path(name)
	assert_equal(1, file_write_text(path, source))
	free(path)


void static_compile(char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 30000, argv)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


void static_reject(char* diagnostic, char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* arg in args: argv.push(arg)
	process_result* r = tool_spawn(0, 30000, argv)
	# A controlled diagnostic, rather than a crash on malformed input.
	assert_equal(1, r.status)
	assert_contains(r.stderr_text, diagnostic)
	process_result_free(r)


void static_run(char* name, int expected):
	char* path = static_path(name)
	char** argv = strv_new(1)
	strv_set(argv, 0, path)
	process_result* r = process_run(path, argv, 0, 0, 10000)
	assert1(r != 0)
	if (r.status != expected): println2(r.stderr_text)
	assert_equal(expected, r.status)
	process_result_free(r)
	free(cast(void*, argv))
	free(path)


void test_static_setup():
	static_test_dir = tool_scratch(c"library_static_")
	assert_equal(0, mkdir(static_test_dir, 493))
	static_write(c"leaf.w", c"int value = 39\nexport int leaf():\n\tvalue += 1\n\treturn value\n")
	static_write(c"app.w", c"extern int leaf()\nint main():\n\treturn leaf() + leaf() - 39\n")


void test_static_archive_and_pie_are_standalone():
	char* archive = static_path(c"libleaf.wa")
	static_compile(c"x64", c"--static", static_path(c"leaf.w"), c"-o", archive)
	char* link = strjoin(c"--link=", archive)
	static_compile(c"x64", link, static_path(c"app.w"), c"-o", static_path(c"app"))
	static_compile(c"x64", c"--pie", link, static_path(c"app.w"), c"-o", static_path(c"app_pie"))
	assert_equal(0, unlink(archive))
	assert_equal(0, unlink(static_path(c"leaf.w")))
	static_run(c"app", 42)
	static_run(c"app_pie", 42)
	free(link)
	free(archive)


void test_static_nested_archives_and_shared_mix():
	static_write(c"leaf.w", c"export int leaf():\n\treturn 40\n")
	static_write(c"middle.w", c"extern int leaf()\nexport int middle():\n\treturn leaf() + 2\n")
	static_write(c"nested.w", c"extern int middle()\nint main():\n\treturn middle()\n")
	static_compile(c"x64", c"--static", static_path(c"leaf.w"), c"-o", static_path(c"libleaf.wa"))
	char* leaf_link = strjoin(c"--link=", static_path(c"libleaf.wa"))
	static_compile(c"x64", c"--static", leaf_link, static_path(c"middle.w"), c"-o", static_path(c"libmiddle.wa"))
	char* middle_link = strjoin(c"--link=", static_path(c"libmiddle.wa"))
	static_compile(c"x64", middle_link, static_path(c"nested.w"), c"-o", static_path(c"nested"))
	static_write(c"dynamic.w", c"export int dynamic_value():\n\treturn 3\n")
	static_write(c"mixed.w", c"extern int middle()\nextern int dynamic_value()\nint main():\n\treturn middle() + dynamic_value()\n")
	static_compile(c"x64", c"--shared", static_path(c"dynamic.w"), c"-o", static_path(c"libdynamic.so"))
	char* dynamic_link = strjoin(c"--link=", static_path(c"libdynamic.so"))
	static_compile(c"x64", middle_link, dynamic_link, static_path(c"mixed.w"), c"-o", static_path(c"mixed"))
	assert_equal(0, unlink(static_path(c"libleaf.wa")))
	assert_equal(0, unlink(static_path(c"libmiddle.wa")))
	static_run(c"nested", 42)
	static_run(c"mixed", 45)
	free(leaf_link)
	free(middle_link)
	free(dynamic_link)


void test_static_rejects_invalid_inputs():
	static_write(c"bad.wa", c"not an archive")
	char* bad_link = strjoin(c"--link=", static_path(c"bad.wa"))
	char* out = static_path(c"bad_out")
	static_reject(c"invalid static library", c"x64", bad_link, static_path(c"app.w"), c"-o", out)
	static_write(c"bad.wa", c"W")
	static_reject(c"invalid static library", c"x64", bad_link, static_path(c"app.w"), c"-o", out)
	static_reject(c"--link requires a library path", c"x64", c"--link=", static_path(c"app.w"), c"-o", out)
	static_reject(c"--static requires the x64 Linux target", c"--static", static_path(c"leaf.w"), c"-o", out)
	static_reject(c"mutually exclusive", c"x64", c"--static", c"--shared", static_path(c"leaf.w"), c"-o", out)
	static_reject(c"--static does not support profiling", c"x64", c"--static", c"--profile-generate", static_path(c"leaf.w"), c"-o", out)
	static_reject(c"--static does not support thread_local", c"x64", c"--static", c"tests/library_shared_tls_input.w", c"-o", out)
	static_write(c"import.w", c"c_lib \"libc.so.6\"\nextern int libc_pid() = \"getpid\"\nexport int imported():\n\treturn libc_pid()\n")
	static_reject(c"--static does not support dynamic imports", c"x64", c"--static", static_path(c"import.w"), c"-o", out)
	static_compile(c"x64", c"--static", static_path(c"leaf.w"), c"-o", static_path(c"one.wa"))
	static_compile(c"x64", c"--static", static_path(c"leaf.w"), c"-o", static_path(c"two.wa"))
	char* first_link = strjoin(c"--link=", static_path(c"one.wa"))
	char* second_link = strjoin(c"--link=", static_path(c"two.wa"))
	static_reject(c"duplicate static library export", c"x64", first_link, second_link, static_path(c"app.w"), c"-o", out)
	static_reject(c"static libraries require the x64 Linux syscall target", c"x64", c"--syscall-abi=vmcall", first_link, static_path(c"app.w"), c"-o", out)
	free(first_link)
	free(second_link)
	free(bad_link)
	free(out)


void static_bad_records(char* bytes, int length):
	char* path = static_path(c"records.wa")
	int fd = open(path, 577, 420)
	assert1(fd >= 0)
	assert_equal(length, write(fd, bytes, length))
	close(fd)
	char* link = strjoin(c"--link=", path)
	static_reject(c"invalid static library", c"x64", link, static_path(c"app.w"), c"-o", static_path(c"bad_records"))
	free(link)
	free(path)


void test_static_rejects_malformed_records():
	char* bytes = cast(char*, malloc(80))
	char* magic = c"WLIB64\x00\x01"
	# A minimal header plus four code bytes and eight data bytes. Each
	# mutation reaches a separate bounded-reader validation path.
	for case_id in range(18):
		for i in range(80): bytes[i] = 0
		for i in range(8): bytes[i] = magic[i]
		save_int32(bytes + 8, 4)
		save_int32(bytes + 12, 8)
		int length = 48
		if (case_id == 0): length = 8
		if (case_id == 1): save_int32(bytes + 8, -1)
		if (case_id == 2): save_int32(bytes + 8, 1000)
		if (case_id == 3): save_int32(bytes + 12, 1000)
		if (case_id == 4): save_int32(bytes + 16, 1)
		if (case_id == 5): save_int32(bytes + 20, 1)
		if (case_id == 6): save_int32(bytes + 24, 1)
		if (case_id == 7): length = 49
		if ((case_id == 8) || (case_id == 9)):
			save_int32(bytes + 16, 1)
			length = 56
			if (case_id == 8): save_int32(bytes + 48, 1)
			if (case_id == 9): save_int32(bytes + 52, 9)
		if ((case_id >= 10) && (case_id <= 13)):
			save_int32(bytes + 20, 1)
			length = 60
			if (case_id == 10): save_int32(bytes + 48, 1)
			if (case_id == 11): save_int32(bytes + 52, 2)
			if (case_id == 12): save_int32(bytes + 56, 5)
			if (case_id == 13):
				save_int32(bytes + 52, 1)
				save_int32(bytes + 56, 9)
		if (case_id >= 14):
			save_int32(bytes + 24, 1)
			length = 57
			save_int32(bytes + 48, 1)
			bytes[52] = 'a'
			if (case_id == 14): save_int32(bytes + 53, 4)
			if (case_id == 15): bytes[52] = 0
			if (case_id == 16): save_int32(bytes + 48, 0)
			if (case_id == 17): save_int32(bytes + 48, 1000)
		static_bad_records(bytes, length)
	free(bytes)
	static_reject(c"cannot open static library", c"x64", strjoin(c"--link=", static_path(c"missing.wa")), static_path(c"app.w"), c"-o", static_path(c"bad_missing"))


void test_static_allocator_isolation():
	static_write(c"memory.w", c"import lib.lib\nexport char* module_alloc(int n):\n\treturn cast(char*, malloc(n))\nexport char* module_resize(char* p, int n):\n\treturn cast(char*, realloc(p, 32, n))\nexport void module_free(char* p):\n\tfree(p)\n")
	static_write(c"memory_app.w", c"import lib.lib\nimport lib.assert\nextern char* module_alloc(int n)\nextern char* module_resize(char* p, int n)\nextern void module_free(char* p)\nint main():\n\tfor round in range(100):\n\t\tchar* own = cast(char*, malloc(32))\n\t\tchar* other = module_alloc(32)\n\t\tfor i in range(32): own[i] = 65\n\t\tfor i in range(32): other[i] = 66\n\t\town = cast(char*, realloc(own, 32, 4096))\n\t\tother = module_resize(other, 8192)\n\t\tfor i in range(32):\n\t\t\tassert_equal(65, own[i])\n\t\t\tassert_equal(66, other[i])\n\t\tfor i in range(4096): own[i] = 65\n\t\tfor i in range(8192): other[i] = 66\n\t\tfor i in range(4096): assert_equal(65, own[i])\n\t\tfor i in range(8192): assert_equal(66, other[i])\n\t\tmodule_free(other)\n\t\tfree(own)\n\treturn 0\n")
	static_compile(c"x64", c"--static", static_path(c"memory.w"), c"-o", static_path(c"memory.wa"))
	char* link = strjoin(c"--link=", static_path(c"memory.wa"))
	static_compile(c"x64", link, static_path(c"memory_app.w"), c"-o", static_path(c"memory_app"))
	static_run(c"memory_app", 0)
	free(link)


void test_native_exports_reject_unsupported_signatures():
	char* out = static_path(c"bad.so")
	static_write(c"variadic.w", c"export int variadic(int... values):\n\treturn 0\n")
	static_reject(c"cannot export a variadic function", c"x64", c"--shared", static_path(c"variadic.w"), c"-o", out)
	static_write(c"aggregate.w", c"struct pair:\n\tint a\n\tint b\nexport int aggregate(pair value):\n\treturn value.a\n")
	static_reject(c"exported function parameters must be single words", c"x64", c"--shared", static_path(c"aggregate.w"), c"-o", out)
	static_write(c"one_field.w", c"struct single:\n\tint value\nexport int one_field(single item):\n\treturn item.value\n")
	static_reject(c"exported function parameters must be single words", c"x64", c"--shared", static_path(c"one_field.w"), c"-o", out)
	static_write(c"aggregate_return.w", c"struct pair:\n\tint a\n\tint b\nexport pair aggregate_return():\n\tpair p\n\treturn p\n")
	static_reject(c"cannot export a function returning a struct", c"x64", c"--shared", static_path(c"aggregate_return.w"), c"-o", out)
	free(out)


void test_static_cleanup():
	dir_remove_all(static_test_dir)
	free(static_test_dir)
