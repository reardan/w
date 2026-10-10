# wbuild: binary=wllvm_test tag=tests dep=wllvm data=tests/wllvm_scalar_fixture.w
# wbuild: step="bin/wllvm_test"
# LLVM is deliberately optional: structural/rejection checks always run,
# and the same fixture is executed through W and clang at O0/O2 when
# clang is available on PATH. No shell or external tool is needed to
# emit the IR itself.
import lib.testing
import lib.process
import lib.file
import lib.utf8
import lib.stat


int wllvm_test_serial


char* wllvm_test_path(char* suffix):
	wllvm_test_serial = wllvm_test_serial + 1
	return cstr(f"bin/wllvm_test_{getpid()}_{wllvm_test_serial}{suffix}")


process_result* wllvm_test_run(list[char*] args):
	char** vector = strv_new(args.length)
	for i in range(args.length): strv_set(vector, i, args[i])
	process_result* result = process_run(args[0], vector, 0, 0, 60000)
	free(cast(void*, vector))
	assert1(result != 0)
	return result


void wllvm_test_success(process_result* result):
	if result.status:
		print2(result.stdout_text)
		print2(result.stderr_text)
	assert_equal(0, result.status)
	process_result_free(result)


void wllvm_test_emit(char* source, char* output):
	wllvm_test_success(wllvm_test_run(list[char*]{c"bin/wllvm", source, c"-o", output}))


void test_wllvm_deterministic_ir():
	char* first = wllvm_test_path(c".ll")
	char* second = wllvm_test_path(c".ll")
	wllvm_test_emit(c"tests/wllvm_scalar_fixture.w", first)
	wllvm_test_emit(c"tests/wllvm_scalar_fixture.w", second)
	char* a = file_read_text(first)
	char* b = file_read_text(second)
	assert1(a != 0 && b != 0)
	assert_strings_equal(a, b)
	assert_contains(a, c"define i32 @main(")
	assert_contains(a, c"i64")
	assert_contains(a, c"sdiv i64")
	assert_contains(a, c"srem i64")
	assert_contains(a, c"icmp slt i64")
	assert_contains(a, c"br i1")
	unlink(first)
	unlink(second)
	free(a)
	free(b)
	free(first)
	free(second)


# A rejected program must not replace a previously usable output file.
# These are valid production W programs; rejection belongs to the bounded
# LLVM subset, and must identify the source instead of silently dropping
# declarations or generating native instructions in the IR.
void wllvm_test_reject(char* source):
	char* input = wllvm_test_path(c".w")
	char* output = wllvm_test_path(c".ll")
	assert1(file_write_text(input, source))
	assert1(file_write_text(output, c"preserve existing output\n"))
	process_result* result = wllvm_test_run(list[char*]{c"bin/wllvm", input, c"-o", output})
	if result.status == 0:
		println2(source)
	assert1(result.status != 0)
	assert_contains(result.stderr_text, input)
	char* text = file_read_text(output)
	assert_strings_equal(c"preserve existing output\n", text)
	free(text)
	process_result_free(result)
	unlink(input)
	unlink(output)
	free(input)
	free(output)


void test_wllvm_rejects_unsupported_programs():
	wllvm_test_reject(c"int global_value\nint main():\n\treturn global_value\n")
	wllvm_test_reject(c"int main():\n\tint* p = 0\n\treturn p == 0\n")
	wllvm_test_reject(c"float value(float x):\n\treturn x + 1.0\nint main():\n\treturn 0\n")
	wllvm_test_reject(c"int main():\n\tint n = 0\n\tfor i in range(4): n = n + i\n\treturn n\n")
	wllvm_test_reject(c"struct Point:\n\tint x\nint main():\n\treturn 0\n")
	wllvm_test_reject(c"import lib.str\nint main():\n\treturn 0\n")
	wllvm_test_reject(c"int main():\n\treturn missing_name\n")
	wllvm_test_reject(c"int main():\n\treturn 0\n\tint* p = 0\n")
	wllvm_test_reject(c"int main():\n\tdefer main()\n\treturn 0\n")
	wllvm_test_reject(c"int main():\n\tint n\n\treturn n\n")
	wllvm_test_reject(c"int main():\n\tpass\n")


void test_wllvm_cli_errors():
	process_result* result = wllvm_test_run(list[char*]{c"bin/wllvm", c"--help"})
	assert_equal(0, result.status)
	assert_contains(result.stdout_text, c"wllvm")
	process_result_free(result)
	result = wllvm_test_run(list[char*]{c"bin/wllvm"})
	assert1(result.status != 0)
	process_result_free(result)
	result = wllvm_test_run(list[char*]{c"bin/wllvm", c"tests/wllvm_scalar_fixture.w"})
	assert1(result.status != 0)
	process_result_free(result)
	result = wllvm_test_run(list[char*]{c"bin/wllvm", c"--unknown"})
	assert1(result.status != 0)
	process_result_free(result)


void test_wllvm_cli_file_errors():
	char* input = wllvm_test_path(c".w")
	char* output = wllvm_test_path(c".ll")
	char* source = c"int main():\n\treturn 0\n"
	assert1(file_write_text(input, source))
	list[list[char*]] invalid = list[list[char*]]{
		list[char*]{c"bin/wllvm", input, c"-o"},
		list[char*]{c"bin/wllvm", input, c"-o", output, c"-o", output},
		list[char*]{c"bin/wllvm", input, input, c"-o", output},
		list[char*]{c"bin/wllvm", output, c"-o", c"bin/wllvm_missing_input.ll"},
		list[char*]{c"bin/wllvm", input, c"-o", c"bin"},
		list[char*]{c"bin/wllvm", input, c"-o", input},
		list[char*]{c"bin/wllvm", input, c"-o", strjoin(c"./", input)},
	}
	for args in invalid:
		process_result* result = wllvm_test_run(args)
		assert1(result.status != 0)
		process_result_free(result)
	char* preserved = file_read_text(input)
	assert_strings_equal(source, preserved)
	free(preserved)
	# Both aliases point to the same input inode. The symlink target is
	# relative to bin/, while ln receives ordinary cwd-relative paths.
	char* target = strjoin(c"../", input)
	assert_equal(0, file_symlink(target, output))
	process_result* result = wllvm_test_run(list[char*]{c"bin/wllvm", input, c"-o", output})
	assert1(result.status != 0)
	process_result_free(result)
	preserved = file_read_text(input)
	assert_strings_equal(source, preserved)
	free(preserved)
	unlink(output)
	char* ln = process_which(c"ln")
	assert1(ln != 0)
	wllvm_test_success(wllvm_test_run(list[char*]{ln, input, output}))
	result = wllvm_test_run(list[char*]{c"bin/wllvm", input, c"-o", output})
	assert1(result.status != 0)
	process_result_free(result)
	preserved = file_read_text(input)
	assert_strings_equal(source, preserved)
	free(preserved)
	unlink(output)
	unlink(input)
	free(ln)
	free(target)
	free(input)
	free(output)


void test_wllvm_native_differential():
	char* clang = process_which(c"clang")
	if clang == 0:
		println(c"wllvm: clang unavailable; optional native comparison skipped")
		return
	char* ir = wllvm_test_path(c".ll")
	char* native = wllvm_test_path(c".native")
	char* reference = wllvm_test_path(c".reference")
	wllvm_test_emit(c"tests/wllvm_scalar_fixture.w", ir)
	wllvm_test_success(wllvm_test_run(list[char*]{c"bin/wv2", c"x64", c"tests/wllvm_scalar_fixture.w", c"-o", reference}))
	process_result* baseline = wllvm_test_run(list[char*]{reference})
	assert_equal(73, baseline.status)
	list[char*] options = list[char*]{c"-O0", c"-O2"}
	for optimization in options:
		wllvm_test_success(wllvm_test_run(list[char*]{clang, optimization, ir, c"-o", native}))
		process_result* result = wllvm_test_run(list[char*]{native})
		assert_equal(baseline.status, result.status)
		assert_strings_equal(baseline.stdout_text, result.stdout_text)
		assert_strings_equal(baseline.stderr_text, result.stderr_text)
		process_result_free(result)
	process_result_free(baseline)
	unlink(ir)
	unlink(native)
	unlink(reference)
	free(clang)
	free(ir)
	free(native)
	free(reference)


void test_wllvm_native_division_traps():
	char* clang = process_which(c"clang")
	if clang == 0: return
	list[char*] sources = list[char*]{
		c"int quotient(int a, int b):\n\treturn a / b\nint main():\n\treturn quotient(17, 0)\n",
		c"int remainder(int a, int b):\n\treturn a % b\nint main():\n\tint n = 1\n\tn = n << 63\n\treturn remainder(n, -1)\n",
	}
	for source in sources:
		char* input = wllvm_test_path(c".w")
		char* ir = wllvm_test_path(c".ll")
		char* native = wllvm_test_path(c".native")
		assert1(file_write_text(input, source))
		wllvm_test_emit(input, ir)
		wllvm_test_success(wllvm_test_run(list[char*]{clang, c"-O2", ir, c"-o", native}))
		process_result* result = wllvm_test_run(list[char*]{native})
		assert1(result.status != 0)
		process_result_free(result)
		unlink(input)
		unlink(ir)
		unlink(native)
		free(input)
		free(ir)
		free(native)
	free(clang)
