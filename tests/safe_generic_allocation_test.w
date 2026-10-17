# wbuild: x64
# wbuild: deps=tests/safe_generic_allocation_import_fixture.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int generic_allocation_case_number


void generic_allocation_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_allocation_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	generic_allocation_case_number = generic_allocation_case_number + 1
	char* number = itoa(generic_allocation_case_number)
	char* prefix = c"bin/generic_allocation_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_allocation_case64_"
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
		generic_allocation_result(checked, diagnostic, 1, full)
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
		generic_allocation_result(compiled, diagnostic, 0, full)
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

void test_generic_allocation_0():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\nint main():\n\town int* value = allocate[int]()\n\t*value = 7\n\treturn *value - 7\n", 0)

void test_generic_allocation_1():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\ntype Number = int\nint main():\n\town Number* value = allocate[Number]()\n\treturn *value\n", 0)

void test_generic_allocation_2():
	generic_allocation_case(c"struct Pair:\n\tint first\n\tint second\n\nown T* allocate[T]():\n\treturn new T\n\nint main():\n\town Pair* value = allocate[Pair]()\n\tvalue.first = 3\n\tvalue.second = 4\n\treturn value.first + value.second - 7\n", 0)

void test_generic_allocation_3():
	generic_allocation_case(c"struct Pair:\n\tint first\n\tint second\n\nown T* construct[T](int a, int b):\n\treturn new T(a, b)\n\nint main():\n\town Pair* value = construct[Pair](3, 4)\n\treturn value.first + value.second - 7\n", 0)

void test_generic_allocation_4():
	generic_allocation_case(c"struct Pair:\n\tint first\n\tint second\n\nown T* construct[T](int a, int b):\n\treturn new T(a, b)\n\nint main():\n\town int* value = construct[int](3, 4)\n\treturn 0\n", c"arguments")

void test_generic_allocation_5():
	generic_allocation_case(c"struct T:\n\tint left\n\tint right\n\nown T* allocate[T]():\n\treturn new T\n\nint main():\n\town int* value = allocate[int]()\n\t*value = 7\n\treturn *value - 7\n", 0)

void test_generic_allocation_6():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\nown T* outer[T]():\n\treturn allocate[T]()\n\nint main():\n\town int* value = outer[int]()\n\treturn *value\n", 0)

void test_generic_allocation_7():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\nown T* recursive[T](int depth):\n\tif depth == 0: return new T\n\treturn recursive[T](depth - 1)\n\nint main():\n\town int* value = recursive[int](3)\n\treturn *value\n", 0)

void test_generic_allocation_8():
	generic_allocation_case(c"struct Child:\n\town int* value\n\nown T* allocate[T]():\n\treturn new T\n\nint main():\n\town Child* value = allocate[Child]()\n\treturn 0\n", c"pointer-free sized value")

void test_generic_allocation_9():
	generic_allocation_case(c"struct Child:\n\town int* value\n\nown T* construct[T](own int* value):\n\treturn new T(value)\n\nint main():\n\town int* value = new int\n\t*value = 7\n\town Child* child = construct[Child](value)\n\tref int* result = child.value\n\treturn *result - 7\n", 0)

void test_generic_allocation_10():
	generic_allocation_case(c"struct Child:\n\town int* value\n\nown T* construct[T](own int* value):\n\treturn new T(value)\n\nint main():\n\town int* value = new int\n\town Child* child = construct[Child](value)\n\treturn *value\n", c"moved")

void test_generic_allocation_11():
	generic_allocation_case(c"struct Borrowed:\n\tref[data] int* value\n\nown[a] T* capture[T](ref[a] int* value):\n\treturn new T(value)\n\nint main():\n\tint number = 7\n\town[a] Borrowed* holder = capture[Borrowed](&number)\n\tref int* result = holder.value\n\treturn *result - 7\n", 0)

void test_generic_allocation_12():
	generic_allocation_case(c"struct Borrowed:\n\tref[data] int* value\n\nown[a] T* capture[T](ref[a] int* value):\n\tint local = 7\n\treturn new T(&local)\n\nint main():\n\tint number = 7\n\town[a] Borrowed* holder = capture[Borrowed](&number)\n\treturn 0\n", c"borrow")

void test_generic_allocation_13():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\nint main():\n\town int** value = allocate[int*]()\n\treturn 0\n", c"checked pointers require a single pointer")

void test_generic_allocation_14():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\nint main():\n\town int* value = allocate[int]()\n\tref int* view = value\n\tvalue = allocate[int]()\n\treturn *view\n", c"borrow")

void test_generic_allocation_15():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\nint main():\n\tint total = 0\n\tfor i in range(4):\n\t\town int* value = allocate[int]()\n\t\t*value = i\n\t\ttotal += *value\n\treturn total - 6\n", 0)

void test_generic_allocation_16():
	generic_allocation_case(c"struct Pair:\n\tint left\n\tint right\n\nown T* allocate[T]():\n\treturn new T\n\nint main():\n\town int* scalar = allocate[int]()\n\town Pair* record = allocate[Pair]()\n\t*scalar = 3\n\trecord.left = 4\n\treturn *scalar + record.left - 7\n", 0)

void test_generic_allocation_17():
	generic_allocation_case(c"own T* allocate[T]():\n\treturn new T\n\nint main():\n\town byte* value = allocate[byte]()\n\t*value = cast(byte, 7)\n\treturn cast(int, *value) - 7\n", 0)

void test_generic_allocation_18():
	generic_allocation_case(c"import tests.safe_generic_allocation_import_fixture\n\nint main():\n\town int* value = generic_allocate[int]()\n\t*value = 7\n\treturn *value - 7\n", 0)

void test_generic_allocation_19():
	generic_allocation_case(c"import tests.safe_generic_allocation_import_fixture\n\nint main():\n\town int* value = generic_allocate[int]()\n\town int* moved = value\n\treturn *value\n", c"moved")
