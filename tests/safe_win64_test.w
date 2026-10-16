# Cross-compilation/diagnostics run on any host; PE execution belongs to
# tests_win64, where Wine or native Windows is available.
# wbuild: deps=tests/safe_win64_runtime_fixture.w deps=lib/safe_buffer.w
# wbuild: step="bin/wv2 win64 --ast-required --safe --strict tests/safe_win64_runtime_fixture.w -o bin/safe_win64_runtime_fixture.exe"
# wbuild: step="bin/wv2 x64 --ast-required --safe --strict tests/safe_win64_runtime_fixture.w -o bin/safe_win64_runtime_linux"
# wbuild: step="bin/safe_win64_runtime_linux"
# wbuild: target=safe_win64_runtime_test tag=tests_win64 dep=wv2
# wbuild: step="bin/wv2 win64 --ast-required --safe --strict tests/safe_win64_runtime_fixture.w -o bin/safe_win64_runtime.exe"
# wbuild: step="wine bin/safe_win64_runtime.exe"
# wbuild: step="bin/wv2 win64 --ast-required --strict --no-inline --no-regs tests/safe_win64_runtime_fixture.w -o bin/safe_win64_runtime_plain.exe"
# wbuild: step="wine bin/safe_win64_runtime_plain.exe"
# wbuild: step="bin/wv2 win64 --ast-required --safe --strict --inline tests/safe_win64_runtime_fixture.w -o bin/safe_win64_runtime_inline.exe"
# wbuild: step="wine bin/safe_win64_runtime_inline.exe"
import lib.testing
import lib.process
import lib.file

void win_safe_case(char* source, char* diagnostic):
	char* path = c"bin/safe_win64_case.w"
	char* output = c"bin/safe_win64_case.exe"
	assert1(file_write_text(path, source))
	for mode in range(2):
		for checking in range(2):
			unlink(output)
			char** args = strv_new(8)
			strv_set(args, 0, c"bin/wv2")
			strv_set(args, 1, c"win64")
			strv_set(args, 2, c"--ast-required")
			strv_set(args, 3, c"--strict")
			if mode: strv_set(args, 3, c"--safe")
			strv_set(args, 4, c"--quiet")
			strv_set(args, 5, path)
			strv_set(args, 6, c"-o")
			strv_set(args, 7, output)
			if checking:
				strv_set(args, 1, c"check")
				strv_set(args, 2, c"--json")
				strv_set(args, 4, c"--ast-required")
				strv_set(args, 5, c"win64")
				strv_set(args, 6, path)
				strv_set(args, 7, c"--quiet")
			process_result* result = process_run(args[0], args, 0, 0, 30000)
			assert1(result != 0)
			if diagnostic:
				assert_equal(1, result.status)
				if checking: assert_contains(result.stdout_text, diagnostic)
				else: assert_contains(result.stderr_text, diagnostic)
				assert1(open(output, 0, 0) < 0)
			else:
				if result.status:
					print(result.stdout_text)
					print(result.stderr_text)
				assert_equal(0, result.status)
			process_result_free(result)
			free(cast(void*, args))
	unlink(path)
	unlink(output)

void test_win64_checked_contracts():
	win_safe_case(c"int main():\n\town int* p = new int\n\t*p = 7\n\tref int* view = p\n\treturn *view - 7\n", 0)
	win_safe_case(c"int main():\n\town int* p = new int\n\town int* moved = p\n\treturn *p\n", c"moved value")
	win_safe_case(c"int main():\n\town int* p = new int\n\tref int* view = p\n\t*p = 7\n\treturn *view\n", c"conflicting access")
	win_safe_case(c"ref int* escape(ref int* input):\n\tint local = 7\n\treturn &local\nint main():\n\treturn 0\n", c"return")
	win_safe_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* values = int_buffer_new()\n\tint_buffer_push(values, 7)\n\tref int[] view = int_buffer_view(values)\n\treturn view[0] - 7\n", 0)
	win_safe_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* values = int_buffer_new()\n\tint_buffer_push(values, 7)\n\tref int[] view = int_buffer_view(values)\n\tint_buffer_push(values, 9)\n\treturn view[0]\n", c"conflicting")
	win_safe_case(c"int main():\n\town int* p = new int\n\tunsafe:\n\t\t*p = 7\n\treturn 0\n", c"cannot manipulate checked")
