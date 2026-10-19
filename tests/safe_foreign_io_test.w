# wbuild: x64
# wbuild: deps=lib/safe_foreign.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int foreign_io_case_number


void foreign_io_result(process_result* result, char* diagnostic, int checking, char* path):
	assert1(result != 0)
	char* message = result.stderr_text
	if (checking): message = result.stdout_text
	if (diagnostic == 0):
		if (result.status):
			print(path)
			print(message)
		assert_equal(0, result.status)
	else:
		if ((result.status != 1) || (assert_has(message, diagnostic) == 0)):
			print(path)
			print(message)
		assert_equal(1, result.status)
		assert_contains(message, diagnostic)


void foreign_io_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	foreign_io_case_number = foreign_io_case_number + 1
	char* number = itoa(foreign_io_case_number)
	char* prefix = c"bin/foreign_io_case32_"
	if (__word_size__ == 8): prefix = c"bin/foreign_io_case64_"
	char* path = strjoin(prefix, number)
	free(number)
	if (seed >= 0):
		char* seed_number = itoa(seed)
		char* tagged = strjoin(path, c"_seed_")
		free(path)
		path = strjoin(tagged, seed_number)
		free(tagged)
		free(seed_number)
	char* full = strjoin(path, c".w")
	free(path)
	char* output = strjoin(full, c".out")
	assert1(file_write_text(full, source))
	for mode in range(2):
		if (mode && explicit_safe_diagnostic): diagnostic = explicit_safe_diagnostic
		unlink(output)
		char** checking = strv_new(7 + mode)
		strv_set(checking, 0, c"bin/wv2")
		strv_set(checking, 1, c"check")
		strv_set(checking, 2, c"--json")
		strv_set(checking, 3, c"--quiet")
		strv_set(checking, 4, c"--strict")
		if (relaxed): strv_set(checking, 4, c"--quiet")
		strv_set(checking, 5, c"--quiet")
		if (__word_size__ == 8): strv_set(checking, 5, c"x64")
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		foreign_io_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--quiet")
		strv_set(compiling, 2, c"--strict")
		if (relaxed): strv_set(compiling, 2, c"--quiet")
		strv_set(compiling, 3, c"--quiet")
		if (__word_size__ == 8): strv_set(compiling, 3, c"x64")
		strv_set(compiling, 4, c"--inline")
		strv_set(compiling, 5, full)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		process_result* compiled = process_run(compiling[0], compiling, 0, 0, 30000)
		foreign_io_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			if (runtime_diagnostic):
				assert_equal(1, executed.status)
				assert_contains(executed.stderr_text, runtime_diagnostic)
			else: assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)

void test_foreign_io_0():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tif foreign_write(-1, data) >= 0: return 1\n\tif foreign_read(-1, data) >= 0: return 2\n\treturn cast(int, data[0]) - 65\n", 0)

void test_foreign_io_1():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\trefmut byte[] view = data\n\trefmut byte[] empty = view[0:0]\n\tif foreign_read(-1, empty) != 0: return 1\n\treturn foreign_write(-1, empty)\n", 0)

void test_foreign_io_2():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tref byte[] shared = data\n\treturn foreign_read(-1, shared)\n", c"mutable borrow from a shared")

void test_foreign_io_3():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tref byte[] shared = data\n\tint result = foreign_read(-1, data)\n\treturn result + cast(int, shared[0])\n", c"borrow")

void test_foreign_io_4():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tref byte[] shared = data\n\tint result = foreign_write(-1, data)\n\treturn cast(int, shared[0]) - 65\n", 0)

void test_foreign_io_5():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\trefmut byte[] exclusive = data\n\tint result = foreign_write(-1, data)\n\texclusive[0] = cast(byte, 67)\n\treturn 0\n", c"borrow")

void test_foreign_io_6():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\trefmut byte[] exclusive = data\n\tint result = foreign_read(-1, exclusive)\n\texclusive[0] = cast(byte, 67)\n\treturn cast(int, data[0]) - 67\n", 0)

void test_foreign_io_7():
	foreign_io_case(c"import lib.safe_foreign\n\ntype Read = fn[](int, refmut byte[]) -> int\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tRead* callback = foreign_read\n\tif callback(-1, data) >= 0: return 1\n\treturn 0\n", 0)

void test_foreign_io_8():
	foreign_io_case(c"import lib.safe_foreign\n\ntype Wrong = fn[](int, ref byte[]) -> int\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tWrong* callback = foreign_read\n\treturn 0\n", c"disagrees with its quantified contract")

void test_foreign_io_9():
	foreign_io_case(c"int foreign_read(int descriptor, ref byte[] source);\nimport lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\treturn 0\n", c"disagrees")

void test_foreign_io_10():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tref byte[] checked = data\n\treturn read(-1, 0, 0)\n", c"runtime call has no audited")

void test_foreign_io_11():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tint[3] data\n\treturn foreign_read(-1, data)\n", c"incompatible")

void test_foreign_io_12():
	foreign_io_case(c"import lib.safe_foreign\n\nint forward[T](refmut T[] data):\n\treturn foreign_read(-1, data)\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tif forward(data) >= 0: return 1\n\treturn 0\n", 0)

void test_foreign_io_13():
	foreign_io_case(c"import lib.safe_foreign\n\nint foreign_write_fake(int descriptor, ref byte[] data):\n\treturn write(descriptor, cast(char*, &data[0]), data.length)\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\treturn foreign_write_fake(-1, data)\n", c"runtime call has no audited")

void test_foreign_io_14():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tbyte[3] data\n\tdata[0] = cast(byte, 65)\n\tdata[1] = cast(byte, 0)\n\tdata[2] = cast(byte, 66)\n\tint descriptor = -1\n\tunsafe:\n\t\tif __word_size__ == 8: descriptor = create_file(c\"bin/foreign_io_data64\", 384)\n\t\telse: descriptor = create_file(c\"bin/foreign_io_data32\", 384)\n\tif descriptor < 0: return 10\n\tint written = foreign_write(descriptor, data)\n\tunsafe:\n\t\tclose(descriptor)\n\t\tif __word_size__ == 8: descriptor = open(c\"bin/foreign_io_data64\", 0, 0)\n\t\telse: descriptor = open(c\"bin/foreign_io_data32\", 0, 0)\n\tif descriptor < 0: return 11\n\tbyte[5] destination\n\tint count = foreign_read(descriptor, destination)\n\tint eof = foreign_read(descriptor, destination)\n\tunsafe:\n\t\tclose(descriptor)\n\t\tif __word_size__ == 8: unlink(c\"bin/foreign_io_data64\")\n\t\telse: unlink(c\"bin/foreign_io_data32\")\n\tif written != 3 || count != 3 || eof != 0: return 1\n\tif destination[0] != cast(byte, 65) || destination[1] != cast(byte, 0) || destination[2] != cast(byte, 66): return 2\n\treturn 0\n", 0)

void test_foreign_io_15():
	foreign_io_case(c"import lib.safe_foreign\n\nint main():\n\tint[3] data\n\treturn foreign_read(-1, data)\n", c"incompatible", 1)

void test_foreign_io_runtime_pin():
	char* root = c"bin/safe_foreign_pin32"
	if (__word_size__ == 8): root = c"bin/safe_foreign_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/lib")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/safe_foreign.w")
	char* source = strjoin(root, c".w")
	char* output = strjoin(root, c".out")
	char* original = file_read_text(c"lib/safe_foreign.w")
	assert1(original != 0)
	char* changed = strjoin(original, c"\n# changed implementation cannot inherit checked contracts\n")
	assert1(file_write_text(path, changed))
	assert1(file_write_text(source, c"import lib.safe_foreign\nint main():\n\tbyte[1] data\n\treturn foreign_read(-1, data)\n"))
	for mode in range(2):
		for checking in range(2):
			unlink(output)
			char** args = strv_new(9)
			strv_set(args, 0, c"bin/wv2")
			strv_set(args, 1, c"--quiet")
			strv_set(args, 2, c"--quiet")
			if (checking):
				strv_set(args, 1, c"check")
				strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--quiet")
			if (mode): strv_set(args, 3, c"--safe")
			strv_set(args, 4, c"--quiet")
			if (__word_size__ == 8): strv_set(args, 4, c"x64")
			strv_set(args, 5, c"--import-root")
			strv_set(args, 6, root)
			strv_set(args, 7, source)
			strv_set(args, 8, c"--quiet")
			if (checking == 0):
				free(cast(void*, args))
				args = strv_new(10)
				strv_set(args, 0, c"bin/wv2")
				strv_set(args, 1, c"--quiet")
				if (mode): strv_set(args, 1, c"--safe")
				strv_set(args, 2, c"--quiet")
				if (__word_size__ == 8): strv_set(args, 2, c"x64")
				strv_set(args, 3, c"--import-root")
				strv_set(args, 4, root)
				strv_set(args, 5, source)
				strv_set(args, 6, c"-o")
				strv_set(args, 7, output)
				strv_set(args, 8, c"--quiet")
				strv_set(args, 9, c"--strict")
			process_result* result = process_run(args[0], args, 0, 0, 30000)
			foreign_io_result(result, c"runtime implementation differs", checking, source)
			assert1(open(output, 0, 0) < 0)
			process_result_free(result)
			free(cast(void*, args))
	unlink(path)
	unlink(source)
	free(original)
	free(changed)
	free(path)
	free(directory)
	free(source)
	free(output)
