# wbuild: binary=elf_pie_test tag=tests dep=wcore
# wbuild: step="bin/wv2 x64 --pie tests/elf_pie_fixture.w -o bin/elf_pie_static"
# wbuild: step="bin/wv2 x64 tests/elf_pie_fixture.w tests/elf_pie_imports.w --pie -o bin/elf_pie_dynamic"
# wbuild: step="bin/wv2 x64 --pie tests/elf_relro_test.w -o bin/elf_pie_relro"
# wbuild: step="bin/elf_pie_relro" expect_stdout="All tests passed!"
# wbuild: step="bin/wv2 x64 --pie tests/stack_trace_test.w -o bin/elf_pie_trace"
# wbuild: step="bin/elf_pie_trace" expect_stdout="stack_trace_test passed"
# wbuild: step="bin/wv2 x64 --pie tests/thread_local_test.w -o bin/elf_pie_tls"
# wbuild: step="bin/elf_pie_tls" expect_stdout="All tests passed!"
# wbuild: step="bin/wv2 x64 --pie tests/crash_null_deref_fixture.w -o bin/elf_pie_crash"
# wbuild: step="bin/wv2 x64 --pie --profile-generate tests/profile_generate_fixture.w -o bin/elf_pie_profile"
# wbuild: step="bin/elf_pie_profile"
# wbuild: step="bin/wv2 --pie tests/elf_pie_fixture.w -o bin/elf_pie_invalid" expect_fail expect_stderr="--pie requires an x64 or arm64 ELF target"
# wbuild: step="bin/wv2 x64 --pie --strict w.w -o bin/elf_pie_wv2"
# wbuild: step="bin/elf_pie_wv2 x64 --pie --strict w.w -o bin/elf_pie_wv3"
# wbuild: step="cmp bin/elf_pie_wv2 bin/elf_pie_wv3"
# wbuild: step="bin/wv2 x64 --pie tests/json_codec_test.w -o bin/elf_pie_json_codec_test"
# wbuild: step="bin/elf_pie_json_codec_test"
# wbuild: step="bin/wv2 x64 --pie tests/json_codec_test.w tests/elf_pie_imports.w -o bin/elf_pie_json_codec_test_dynamic"
# wbuild: step="bin/elf_pie_json_codec_test_dynamic"
# wbuild: step="bin/wv2 x64 --pie tests/protobuf_message_test.w -o bin/elf_pie_protobuf_message_test"
# wbuild: step="bin/elf_pie_protobuf_message_test"
# wbuild: step="bin/wv2 x64 --pie tests/protobuf_message_test.w tests/elf_pie_imports.w -o bin/elf_pie_protobuf_message_test_dynamic"
# wbuild: step="bin/elf_pie_protobuf_message_test_dynamic"
# wbuild: step="bin/wv2 x64 --pie tests/protobuf_message_x64_test.w -o bin/elf_pie_protobuf_message_x64_test"
# wbuild: step="bin/elf_pie_protobuf_message_x64_test"
# wbuild: step="bin/wv2 x64 --pie tests/protobuf_message_x64_test.w tests/elf_pie_imports.w -o bin/elf_pie_protobuf_message_x64_test_dynamic"
# wbuild: step="bin/elf_pie_protobuf_message_x64_test_dynamic"
# wbuild: step="bin/wv2 x64 --pie repl.w -o bin/elf_pie_repl"
# wbuild: step="bin/elf_pie_repl" stdin="int triple(int x): return x * 3\ntriple(7)\n:quit\n" expect_stdout="21"
# wbuild: step="bin/elf_pie_test"
import lib.testing
import lib.file
import lib.process
import lib.env

# File addresses fit on the 32-bit test host. Runtime addresses remain
# strings here; wcore itself is built for x64 and reads full-width PCs.
int pie_word(char* p):
	return load_int(p)

char* pie_phdr(char* image, int type):
	int phoff = pie_word(image + 32)
	for i in range(load_i(image + 56, 2)):
		char* p = image + phoff + i * 56
		if (pie_word(p) == type): return p
	return 0

void pie_headers(char* path, int dynamic):
	char* image = file_read_text(path)
	assert1(image != 0)
	assert_equal(3, load_i(image + 16, 2))
	char* text = pie_phdr(image, 1)
	assert_equal(5, pie_word(text + 4))
	int base = pie_word(text + 16)
	char* phdr = pie_phdr(image, 6)
	assert1(phdr != 0 && phdr < text)
	assert_equal(base + 64, pie_word(phdr + 16))
	assert_equal(6, pie_word(pie_phdr(image, 1685382481) + 4))
	if (dynamic):
		assert1(pie_phdr(image, 3) < text)
		char* relro = pie_phdr(image, 1685382482)
		assert1(relro != 0)
		int low = pie_word(relro + 16)
		int high = low + pie_word(relro + 40)
		assert_equal(0, high & 4095)
		char* dyn = pie_phdr(image, 2)
		assert_equal(4, pie_word(dyn + 4))
		int rel = 0
		int size = 0
		int flags = 0
		int off = pie_word(dyn + 8)
		while (pie_word(image + off) != 0):
			int tag = pie_word(image + off)
			int val = pie_word(image + off + 8)
			if (tag == 7): rel = val - base
			if (tag == 8): size = val
			if (tag == 1879048187): flags = val
			asserts(c"no text relocations", tag != 22)
			off = off + 16
		assert1((flags & 134217728) != 0)
		int relative = 0
		int got = 0
		for r in range(0, size, 24):
			int addr = pie_word(image + rel + r)
			int kind = pie_word(image + rel + r + 8)
			if (kind == 8):
				relative = relative + 1
				assert1(addr >= high)
			else:
				assert_equal(6, kind)
				assert1(addr >= low && addr < high)
				got = got + 1
		assert1(relative >= 3 && got > 0)
	else:
		assert_equal(0, cast(int, pie_phdr(image, 3)))
		assert_equal(0, cast(int, pie_phdr(image, 2)))
	free(image)

void test_pie_headers_and_exec_randomization():
	for i in range(2):
		char* path = c"bin/elf_pie_static"
		if (i): path = c"bin/elf_pie_dynamic"
		pie_headers(path, i)
		char** av = strv_new(1)
		strv_set(av, 0, path)
		char* first = 0
		int different = 0
		for run in range(4):
			process_result* r = process_run(path, av, 0, 0, 30000)
			assert1(r != 0)
			if (r.status != 0): println2(r.stderr_text)
			assert_equal(0, r.status)
			if (first == 0): first = strjoin(c"", r.stdout_text)
			if (strcmp(first, r.stdout_text) != 0): different = 1
			process_result_free(r)
		asserts(c"execs receive different ASLR addresses", different)
		free(first)

void test_pie_crash_dump_symbolization():
	char* dump = c"bin/elf_pie.core"
	unlink(dump)
	spawn_options* opts = spawn_options_new()
	opts.env = env_copy_with(env_current(), c"W_CRASH_DUMP", dump)
	char** av = strv_new(1)
	strv_set(av, 0, c"bin/elf_pie_crash")
	process_result* r = process_run(av[0], av, opts, 0, 30000)
	assert1(r != 0 && r.status != 0)
	assert_contains(r.stderr_text, c"at crash_deep (")
	assert_contains(r.stderr_text, c"build-id: ")
	process_result_free(r)
	char** cv = strv_new(3)
	strv_set(cv, 0, c"bin/wcore")
	strv_set(cv, 1, dump)
	strv_set(cv, 2, c"bin/elf_pie_crash")
	r = process_run(cv[0], cv, 0, 0, 30000)
	assert1(r != 0)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	assert_contains(r.stdout_text, c"crash_deep")
	assert_contains(r.stdout_text, c"crash_mid")
	assert_contains(r.stdout_text, c"main")
	process_result_free(r)
	strv_set(cv, 2, c"bin/wcore")
	r = process_run(cv[0], cv, 0, 0, 30000)
	assert1(r != 0 && r.status != 0)
	assert_contains(r.stderr_text, c"build-id mismatch")
	process_result_free(r)
	# Model coredump_filter omitting ELF headers: remove dumped ELF
	# magic while retaining AUXV and the stack. Bias must still resolve.
	char* core = file_read_text(dump)
	int fd = open(dump, 2, 0)
	assert1(fd >= 0)
	int phoff = pie_word(core + 32)
	for i in range(load_i(core + 56, 2)):
		char* ph = core + phoff + i * 56
		if ((pie_word(ph) == 1) && (pie_word(ph + 32) >= 64)):
			int off = pie_word(ph + 8)
			if (pie_word(core + off) == 0x464c457f):
				assert_equal(off, seek(fd, off, 0))
				assert_equal(1, write(fd, c"\0", 1))
	close(fd)
	free(core)
	strv_set(cv, 2, c"bin/elf_pie_crash")
	r = process_run(cv[0], cv, 0, 0, 30000)
	assert1(r != 0 && r.status == 0)
	assert_contains(r.stderr_text, c"the core records no build-id")
	assert_contains(r.stdout_text, c"crash_mid")
	process_result_free(r)
	unlink(dump)

void test_pie_profile_pointer_relocation():
	char* path = c"bin/elf_pie.wprofraw"
	unlink(path)
	spawn_options* opts = spawn_options_new()
	opts.env = env_copy_with(env_current(), c"W_PROFILE_OUT", path)
	char** av = strv_new(1)
	strv_set(av, 0, c"bin/elf_pie_profile")
	process_result* r = process_run(av[0], av, opts, 0, 30000)
	assert1(r != 0)
	assert_equal(0, r.status)
	char* counts = file_read_text(path)
	assert1(counts != 0 && strlen(counts) > 20)
	free(counts)
	process_result_free(r)
	unlink(path)
