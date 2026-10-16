# wbuild: target=wgrind_compiler_test tag=tests dep=wv2 dep=wgrind_native input=tests/wgrind_compiler_fixture.w input=tests/wgrind_compiler_math_fixture.w
# wbuild: step="bin/wv2 x64 --wgrind tests/wgrind_compiler_fixture.w -o bin/wgrind_compiler_fixture"
# wbuild: step="bin/wv2 x64 --wgrind tests/wgrind_compiler_math_fixture.w -o bin/wgrind_compiler_math_fixture"
# wbuild: step="bin/wv2 tests/wgrind_compiler_test.w -o bin/wgrind_compiler_test"
# wbuild: step="bin/wgrind_compiler_test inspect" expect_stdout="wgrind_compiler_test: OK"
# wbuild: step="bin/wgrind_compiler_test execute" expect_stdout="wgrind_compiler_test: OK" timeout=120000
# wbuild: step="bin/wgrind_native bin/wgrind_compiler_fixture h" expect_status=100 expect_stderr="incomplete" reject_stdout="unchecked callback"
# wbuild: step="bin/wgrind_native bin/wgrind_compiler_fixture H" expect_status=100 expect_stderr="incomplete" reject_stdout="unchecked callback"
# wbuild: step="bin/wgrind_native bin/wgrind_compiler_math_fixture c"
# wbuild: step="bin/wgrind_native bin/wgrind_compiler_math_fixture u" expect_status=99 expect_stderr="undefined-value"
# wbuild: step="bin/wgrind_native bin/wgrind_compiler_math_fixture s" expect_status=99 expect_stderr="undefined-value"
# wbuild: step="bin/wv2 --wgrind tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_arch" expect_status=1 expect_stderr="requires the x64 Linux target"
# wbuild: step="bin/wv2 arm64 --wgrind tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_arch" expect_status=1 expect_stderr="requires the x64 Linux target"
# wbuild: step="bin/wv2 x64 --wgrind --pie tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_pie" expect_status=1 expect_stderr="requires a native non-PIE executable"
# wbuild: step="bin/wv2 x64 --wgrind --streaming tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_stream" expect_status=1 expect_stderr="--streaming"
# wbuild: step="bin/wv2 x64 --wgrind --regs tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_regs" expect_status=1 expect_stderr="cannot be combined with --regs"
# wbuild: step="bin/wv2 x64 --regs --wgrind tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_regs" expect_status=1 expect_stderr="cannot be combined with --regs"
# wbuild: step="bin/wv2 x64 --wgrind --expr-regs tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_regs" expect_status=1 expect_stderr="cannot be combined with --expr-regs"
# wbuild: step="bin/wv2 x64 --expr-regs --wgrind tests/wgrind_compiler_fixture.w -o bin/wgrind_bad_regs" expect_status=1 expect_stderr="cannot be combined with --expr-regs"
# wbuild: step="bin/wv2 x64 --wgrind --inline tests/wgrind_compiler_fixture.w -o bin/wgrind_compiler_inline"
# wbuild: step="cmp bin/wgrind_compiler_fixture bin/wgrind_compiler_inline"
import lib.assert
import lib.file
import lib.process


void inspect_compiler_requests():
	int fd = open(c"bin/wgrind_compiler_fixture", 0, 0)
	assert1(fd >= 0)
	int size = file_size(fd)
	assert1(size > 512)
	char* image = cast(char*, malloc(size))
	assert_equal(size, read(fd, image, size))
	close(fd)
	# ET_EXEC ELF entry is the first executable request, before argc/argv
	# startup. Translate the virtual entry through the first PT_LOAD.
	int phdr = load_int32(image + 32)
	assert_equal(1, load_int32(image + phdr))
	int entry = load_int32(image + 24) - load_int32(image + phdr + 16) + load_int32(image + phdr + 8)
	assert1((entry >= 64) && (entry < size - 24))
	assert_equal(15, image[entry])
	assert_equal(11, image[entry + 1])
	assert_equal(1, image[entry + 6])
	assert_equal(0, image[entry + 7])
	assert_equal(8, load_int32(image + entry + 8))
	int[8] events
	for at in range(size - 24):
		if ((image[at] == 15) && (image[at + 1] == 11) && (image[at + 2] == 'W') && (image[at + 3] == 'G') && (image[at + 4] == 'R') && (image[at + 5] == 'D')):
			assert_equal(1, image[at + 6])
			int kind = image[at + 7]
			assert1((kind >= 0) && (kind <= 7))
			events[kind] = events[kind] + 1
			if ((kind >= 1) && (kind <= 3)): assert1(load_int32(image + at + 8) != 0)
			if (kind == 4): assert1((image[at + 8] >= 1) && (image[at + 8] <= 3))
			if (kind == 5): assert1(load_int32(image + at + 16) > 0)
			if (kind == 6): assert1(load_int32(image + at + 8) > 0)
	assert_equal(1, events[0])
	for event in range(1, 8): assert1(events[event] > 0)
	free(image)
	# The UD2 handshake must reject direct execution. This proves the flag
	# cannot silently ship a binary that appears checked but ran unchecked.
	char** args = strv_new(2)
	strv_set(args, 0, c"bin/wgrind_compiler_fixture")
	strv_set(args, 1, c"c")
	process_result* r = process_run(args[0], args, 0, 0, 30000)
	assert_equal(132, r.status)
	process_result_free(r)
	free(cast(void*, args))


void compiler_native_case(char* mode, int status, char* kind):
	char** args = strv_new(3)
	strv_set(args, 0, c"bin/wgrind_native")
	strv_set(args, 1, c"bin/wgrind_compiler_fixture")
	strv_set(args, 2, mode)
	process_result* r = process_run(args[0], args, 0, 0, 30000)
	if (r.status != status):
		println2(mode)
		println2(r.stderr_text)
		assert_equal(status, r.status)
	if (kind != 0): assert_contains(r.stderr_text, kind)
	if (strcmp(mode, c"u") == 0):
		assert_contains(r.stderr_text, c"\"kind\":\"source-location\"")
		assert_contains(r.stderr_text, c"wgrind_compiler_fixture.w\",\"line\":22")
		assert_contains(r.stderr_text, c"wgrind_compiler_fixture.w\",\"line\":17")
	process_result_free(r)
	free(cast(void*, args))


void execute_compiler_cases():
	compiler_native_case(c"c", 0, 0)
	compiler_native_case(c"u", 99, c"undefined-value")
	compiler_native_case(c"s", 99, c"undefined-value")
	compiler_native_case(c"o", 99, c"invalid-write")
	compiler_native_case(c"b", 99, c"invalid-write")
	compiler_native_case(c"f", 99, c"invalid-write")
	compiler_native_case(c"d", 99, c"double-free")
	compiler_native_case(c"m", 0, 0)
	compiler_native_case(c"p", 0, 0)
	compiler_native_case(c"r", 99, c"undefined-value")
	compiler_native_case(c"g", 0, 0)
	compiler_native_case(c"h", 100, c"incomplete")
	compiler_native_case(c"H", 100, c"incomplete")
	compiler_native_case(c"z", 0, 0)
	compiler_native_case(c"j", 99, c"undefined-value")
	compiler_native_case(c"k", 0, 0)


int main(int argc, char** argv):
	if ((argc > 1) && (strcmp(argv[1], c"inspect") == 0)): inspect_compiler_requests()
	if ((argc > 1) && (strcmp(argv[1], c"execute") == 0)): execute_compiler_cases()
	println(c"wgrind_compiler_test: OK")
	return 0
