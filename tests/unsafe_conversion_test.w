# Errors must fail ordinary compilation as well as check/--strict, retain
# their JSON codes in each front end, and never create an output image.
# wbuild: x64
import lib.testing
import lib.process
import lib.file
import lib.utf8
import tools.manifest_json


void unsafe_expect_error(char* source, char* code):
	char* path = cstr(f"bin/unsafe_conversion_{getpid()}.w")
	char* output = cstr(f"bin/unsafe_conversion_{getpid()}.out")
	assert1(file_write_text(path, source))
	for mode in range(4):
		for strict in range(2):
			for check in range(2):
				char** args = strv_new(12)
				int n = 0
				args[n] = c"bin/wv2"
				n = n + 1
				if (check):
					args[n] = c"check"
					n = n + 1
				if (check):
					args[n] = c"--json"
					n = n + 1
				args[n] = c"--quiet"
				n = n + 1
				if (__word_size__ == 8):
					args[n] = c"x64"
					n = n + 1
				if (strict):
					args[n] = c"--strict"
					n = n + 1
				if (mode):
					args[n] = c"--ast-expressions"
					if (mode == 2): args[n] = c"--ast-full-expressions"
					if (mode == 3): args[n] = c"--ast-required"
					n = n + 1
				args[n] = path
				n = n + 1
				args[n] = c"-o"
				n = n + 1
				args[n] = output
				unlink(output)
				process_result* result = process_run(args[0], args, 0, 0, 60000)
				assert1(result != 0)
				assert_equal(1, result.status)
				if (check):
					assert_strings_equal(c"", result.stderr_text)
					json_value* diagnostic = json_parse(result.stdout_text)
					assert1(diagnostic != 0)
					assert_strings_equal(c"error", jfield_string(diagnostic, c"severity"))
					assert_strings_equal(code, jfield_string(diagnostic, c"code"))
					json_free(diagnostic)
				else: assert_contains(result.stderr_text, c"error: ")
				assert_equal(-2, open(output, 0, 0))
				process_result_free(result)
				free(cast(void*, args))
	unlink(path)
	free(path)
	free(output)


void test_all_issue_532_errors():
	unsafe_expect_error(c"int main():\n\tchar c = 300\n\treturn 0\n", c"W0400")
	unsafe_expect_error(c"void f(void* raw):\n\tint* p = raw\nint main(): return 0\n", c"W0406")
	unsafe_expect_error(c"struct P:\n\tint x\nint main():\n\tP a\n\tP b\n\treturn a == b\n", c"W0402")
	unsafe_expect_error(c"int f(int x):\n\tif x: return 1\nint main(): return 0\n", c"W0403")
	unsafe_expect_error(c"int main():\n\tswitch 1:\n\t\tcase 1: pass\n\t\tcase 1: pass\n\treturn 0\n", c"W0404")
	unsafe_expect_error(c"void f(): return 5\nint main(): return 0\n", c"W0405")
	unsafe_expect_error(c"int main():\n\tint f = 5\n\treturn f()\n", c"W0407")
	unsafe_expect_error(c"enum color:\n\tred\nint main():\n\tcolor c = 5\n\treturn 0\n", c"W0401")
	unsafe_expect_error(c"int f(int a): return a\nint main(): return f()\n", c"W0005")
	unsafe_expect_error(c"int f(int a): return a\nint main(): return f(1, 2)\n", c"W0005")
	unsafe_expect_error(c"int main():\n\tint n = 4\n\tint* p = n\n\treturn 0\n", c"W0003")


# Explicit conversions, typed callbacks, null pointers, erasure and
# control flow with a return on every path remain usable.
type unsafe_callback = fn(int) -> int


int unsafe_twice(int n):
	return n * 2


void test_explicit_conversions():
	char c = cast(char, 300)
	assert_equal(44, cast(int, c))
	void* raw = malloc(__word_size__)
	int* p = cast(int*, raw)
	p[0] = 21
	unsafe_callback* f = unsafe_twice
	assert_equal(42, f(p[0]))
	void* erased = p
	assert1(erased == raw)
	int* nil = 0
	assert1(nil == 0)
	free(raw)
