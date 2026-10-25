# wbuild: binary=wllvm_test tag=tests dep=wllvm data=tests/wllvm_scalar_fixture.w data=tests/wllvm_memory_fixture.w data=tests/wllvm_control_fixture.w
# wbuild: step="bin/wllvm_test"
# LLVM is deliberately optional: structural/rejection checks always run,
# and the fixtures are executed through W and through wllvm's clang build
# at O0/O2 when clang is available on PATH. No shell or external tool is
# needed to emit the IR itself.
import lib.testing
import lib.process
import lib.file
import lib.utf8
import lib.stat
import lib.path


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
	assert_contains(a, c"define void @__wllvm_start(")
	assert_contains(a, c"module asm \"_start:\"")
	assert_contains(a, c"sdiv i64")
	assert_contains(a, c"srem i64")
	assert_contains(a, c"icmp slt i64")
	assert_contains(a, c"br i1")
	unlink(first)
	unlink(second)
	free(a)
	free(b)
	# Memory, globals and the library runtime it prints through.
	wllvm_test_emit(c"tests/wllvm_memory_fixture.w", first)
	a = file_read_text(first)
	assert1(a != 0)
	assert_contains(a, c"internal global")
	assert_contains(a, c"getelementptr i8, ptr")
	assert_contains(a, c"call void @llvm.memcpy.p0.p0.i64(")
	assert_contains(a, c"asm sideeffect \"syscall\"")
	assert_contains(a, c"private unnamed_addr constant [11 x i8] c\"globals ok\\00\"")
	assert_contains(a, c"call i32 @llvm.fshl.i32(")
	unlink(first)
	free(a)
	# Records by value: hidden result buffers, parameter copies, headers.
	wllvm_test_emit(c"tests/wllvm_control_fixture.w", first)
	a = file_read_text(first)
	assert1(a != 0)
	assert_contains(a, c"(i64 %ret")
	assert_contains(a, c"ret i64 %ret")
	assert_contains(a, c" = alloca [48 x i8], align 8")
	unlink(first)
	free(a)
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
	wllvm_test_reject(c"float value(float x):\n\treturn x + 1.0\nint main():\n\treturn 0\n")
	wllvm_test_reject(c"int main():\n\tlist[int] values = new list[int]\n\treturn 0\n")
	wllvm_test_reject(c"import lib.generator\ngenerator int values():\n\tyield 1\nint main():\n\treturn 0\n")
	# the native backend leaves the element headers of this array zeroed
	wllvm_test_reject(c"struct holder:\n\tint[2] items\nint main():\n\tholder[2] all\n\treturn 0\n")
	wllvm_test_reject(c"int main():\n\treturn missing_name\n")
	wllvm_test_reject(c"int main():\n\treturn 0\n\tfloat f = 1.0\n")
	wllvm_test_reject(c"int main():\n\tint[2] values\n\tint[2] other\n\treturn get_context(0)\n")
	wllvm_test_reject(c"int helper():\n\treturn 1\n")
	# checked owners free themselves at scope exit, which the tree leaves implicit
	wllvm_test_reject(c"int main():\n\town int* value = new int\n\t*value = 3\n\treturn *value - 3\n")


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
	result = wllvm_test_run(list[char*]{c"bin/wllvm", c"tests/wllvm_scalar_fixture.w", c"-o", c"bin/wllvm_unused.ll", c"--cc"})
	assert1(result.status != 0)
	process_result_free(result)
	result = wllvm_test_run(list[char*]{c"bin/wllvm", c"tests/wllvm_scalar_fixture.w", c"-o", c"bin/wllvm_unused", c"-O9"})
	assert1(result.status != 0)
	process_result_free(result)
	# A compiler that does not exist fails the build after emission.
	char* output = wllvm_test_path(c"")
	result = wllvm_test_run(list[char*]{c"bin/wllvm", c"tests/wllvm_scalar_fixture.w", c"-o", output, c"--cc", c"bin/wllvm_no_such_clang"})
	assert1(result.status != 0)
	assert_contains(result.stderr_text, c"clang not found")
	assert1(path_exists(output) == 0)
	process_result_free(result)
	free(output)


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


# The production x64 backend and wllvm's clang build must agree on the
# exit status and both output streams.
void wllvm_test_differential(char* clang, char* fixture, int expected):
	char* native = wllvm_test_path(c".native")
	char* reference = wllvm_test_path(c".reference")
	wllvm_test_success(wllvm_test_run(list[char*]{c"bin/wv2", c"x64", fixture, c"-o", reference}))
	process_result* baseline = wllvm_test_run(list[char*]{reference})
	assert_equal(expected, baseline.status)
	list[char*] options = list[char*]{c"-O0", c"-O2"}
	for optimization in options:
		wllvm_test_success(wllvm_test_run(list[char*]{c"bin/wllvm", optimization, c"--cc", clang, fixture, c"-o", native}))
		process_result* result = wllvm_test_run(list[char*]{native})
		assert_equal(baseline.status, result.status)
		assert_strings_equal(baseline.stdout_text, result.stdout_text)
		assert_strings_equal(baseline.stderr_text, result.stderr_text)
		process_result_free(result)
	options.free()
	process_result_free(baseline)
	unlink(native)
	unlink(reference)
	free(native)
	free(reference)


void test_wllvm_native_differential():
	char* clang = process_which(c"clang")
	if clang == 0:
		println(c"wllvm: clang unavailable; optional native comparison skipped")
		return
	wllvm_test_differential(clang, c"tests/wllvm_scalar_fixture.w", 73)
	wllvm_test_differential(clang, c"tests/wllvm_memory_fixture.w", 12)
	wllvm_test_differential(clang, c"tests/wllvm_control_fixture.w", 23)
	free(clang)


# IR text builds by hand with the documented freestanding flags.
void test_wllvm_ir_builds_with_clang():
	char* clang = process_which(c"clang")
	if clang == 0: return
	char* ir = wllvm_test_path(c".ll")
	char* native = wllvm_test_path(c".native")
	wllvm_test_success(wllvm_test_run(list[char*]{c"bin/wllvm", c"--emit-llvm", c"tests/wllvm_scalar_fixture.w", c"-o", ir}))
	wllvm_test_success(wllvm_test_run(list[char*]{clang, c"-O2", c"-static", c"-nostdlib", ir, c"-o", native}))
	process_result* result = wllvm_test_run(list[char*]{native})
	assert_equal(73, result.status)
	process_result_free(result)
	unlink(ir)
	unlink(native)
	free(ir)
	free(native)
	free(clang)


void test_wllvm_native_division_traps():
	char* clang = process_which(c"clang")
	if clang == 0: return
	list[char*] sources = list[char*]{
		c"int quotient(int a, int b):\n\treturn a / b\nint main():\n\treturn quotient(17, 0)\n",
		c"int remainder(int a, int b):\n\treturn a % b\nint main():\n\tint n = 1\n\tn = n << 63\n\treturn remainder(n, -1)\n",
		c"int main():\n\tint[2] values\n\tint i = 2\n\treturn values[i]\n",
	}
	for source in sources:
		char* input = wllvm_test_path(c".w")
		char* native = wllvm_test_path(c".native")
		assert1(file_write_text(input, source))
		wllvm_test_success(wllvm_test_run(list[char*]{c"bin/wllvm", c"-O2", c"--cc", clang, input, c"-o", native}))
		process_result* result = wllvm_test_run(list[char*]{native})
		assert1(result.status != 0)
		process_result_free(result)
		unlink(input)
		unlink(native)
		free(input)
		free(native)
	free(clang)


# A library function outside the subset becomes a trap with a note; the
# rest of the program still builds and runs.
void test_wllvm_library_trap_stub():
	char* clang = process_which(c"clang")
	if clang == 0: return
	char* input = wllvm_test_path(c".w")
	char* native = wllvm_test_path(c".native")
	assert1(file_write_text(input, c"import lib.stack_trace\nint main(int argc, int argv):\n\tif (argc > 1): print_stack_trace()\n\treturn 5\n"))
	process_result* built = wllvm_test_run(list[char*]{c"bin/wllvm", c"--cc", clang, input, c"-o", native})
	assert_equal(0, built.status)
	assert_contains(built.stderr_text, c"wllvm: note: print_stack_trace traps if called")
	process_result_free(built)
	process_result* result = wllvm_test_run(list[char*]{native})
	assert_equal(5, result.status)
	process_result_free(result)
	result = wllvm_test_run(list[char*]{native, c"trace"})
	assert1((result.status != 0) && (result.status != 5))
	process_result_free(result)
	unlink(input)
	unlink(native)
	free(input)
	free(native)
	free(clang)
