# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int scoped_defer_case_number


void scoped_defer_result(process_result* result, char* diagnostic, int checking, char* path):
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


void scoped_defer_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	scoped_defer_case_number = scoped_defer_case_number + 1
	char* number = itoa(scoped_defer_case_number)
	char* prefix = c"bin/scoped_defer_case32_"
	if (__word_size__ == 8): prefix = c"bin/scoped_defer_case64_"
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
		scoped_defer_result(checked, diagnostic, 1, full)
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
		scoped_defer_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)

void test_scoped_defer_0():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tif (1):\n\t\tdefer: add(&value, 2)\n\t\tvalue = 3\n\tif (0):\n\t\tdefer: add(&value, 100)\n\treturn value - 5\n", 0)

void test_scoped_defer_1():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tfor i in range(5):\n\t\tdefer: add(&value, 1)\n\t\tif (i == 1): continue\n\t\tif (i == 3): break\n\treturn value - 4\n", 0)

void test_scoped_defer_2():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tint i = 0\n\twhile (i < 4):\n\t\ti = i + 1\n\t\tdefer: add(&value, 1)\n\t\tif (i == 2): continue\n\t\tif (i == 3): break\n\treturn value - 3\n", 0)

void test_scoped_defer_3():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint run(refmut int* value):\n\tdefer: add(value, 1)\n\tif (1):\n\t\tdefer: add(value, 2)\n\t\treturn *value\n\treturn -1\n\nint main():\n\tint value = 4\n\tint before = run(&value)\n\treturn before + value - 11\n", 0)

void test_scoped_defer_4():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tif (1):\n\t\tdefer: add(&value, 1)\n\t\tif (1):\n\t\t\tdefer: add(&value, 2)\n\t\tif (value != 2): return 1\n\treturn value - 3\n", 0)

void test_scoped_defer_5():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tfor i in range(3):\n\t\tdefer: add(&value, 1)\n\t\tswitch (i):\n\t\t\tcase 1:\n\t\t\t\tdefer: add(&value, 2)\n\t\t\t\tcontinue\n\t\t\tdefault:\n\t\t\t\tdefer: add(&value, 3)\n\t\t\t\tbreak\n\treturn value - 11\n", 0)

void test_scoped_defer_6():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tif (1):\n\t\tint amount = 1\n\t\tdefer: add(&value, amount)\n\t\tamount = 7\n\treturn value - 7\n", 0)

void test_scoped_defer_7():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tif (1):\n\t\tdefer: add(&value, later)\n\t\tint later = 5\n\treturn value - 5\n", 0)

void test_scoped_defer_8():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tif (1):\n\t\tdefer: add(&value, later)\n\t\tif (value): return 1\n\t\tint later = 5\n\treturn 0\n", c"Cannot find symbol")

void test_scoped_defer_9():
	scoped_defer_case(c"void consume(own int* value):\n\t*value = 1\n\nint main():\n\tif (1):\n\t\town int* value = new int\n\t\tdefer: consume(value)\n\treturn 0\n", 0)

void test_scoped_defer_10():
	scoped_defer_case(c"void consume(own int* value):\n\t*value = 1\n\nint main():\n\tif (1):\n\t\town int* value = new int\n\t\tdefer: consume(value)\n\t\tconsume(value)\n\treturn 0\n", c"moved")

void test_scoped_defer_11():
	scoped_defer_case(c"void consume(own int* value):\n\t*value = 1\n\nint main():\n\tif (1):\n\t\town int* value = new int\n\t\tdefer: consume(value)\n\t\tdefer: consume(value)\n\treturn 0\n", c"moved")

void test_scoped_defer_12():
	scoped_defer_case(c"void consume(own int* value):\n\t*value = 1\n\nint main():\n\town int* value = new int\n\tfor i in range(2):\n\t\tdefer: consume(value)\n\treturn 0\n", c"moved")

void test_scoped_defer_13():
	scoped_defer_case(c"void consume(own int* value):\n\t*value = 1\n\nint main():\n\town int* value = new int\n\twhile (1):\n\t\tdefer: consume(value)\n\t\tbreak\n\treturn 0\n", 0)

void test_scoped_defer_14():
	scoped_defer_case(c"int observe(ref int* value):\n\treturn *value\n\nint main():\n\tint value = 0\n\tif (1):\n\t\tref int* view = &value\n\t\tdefer: observe(view)\n\t\tvalue = 2\n\treturn 0\n", c"borrow")

void test_scoped_defer_15():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nref int* run(refmut int* value):\n\tdefer: add(value, 1)\n\treturn value\n\nint main():\n\tint value = 0\n\treturn *run(&value)\n", c"conflicting access")

void test_scoped_defer_16():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tdefer:\n\t\tadd(&value, 1)\n\treturn 0\n", c"a statement must follow")

void test_scoped_defer_17():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tdefer: return 1\n\treturn 0\n", c"not allowed")

void test_scoped_defer_18():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tdefer: defer add(0, 1)\n\treturn 0\n", c"cannot be nested")

void test_scoped_defer_19():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tdefer: int value = 1\n\treturn 0\n", c"cannot declare")

void test_scoped_defer_20():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tdefer: add(&value, 1)\n\tgoto done\n\tdone:\n\treturn 0\n", c"unsupported statement")

void test_scoped_defer_21():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tdefer: add(&value, 1)\n\tif (1):\n\t\tdefer add(&value, 2)\n\treturn 0\n", c"outer lexical block")

void test_scoped_defer_22():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tunsafe:\n\t\tdefer: add(0, 1)\n\treturn 0\n", c"unsafe blocks cannot")

void test_scoped_defer_23():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tif (1) {\n\t\tdefer: add(&value, 5)\n\t}\n\treturn value - 5\n", 0)

void test_scoped_defer_24():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tfor i in range(3):\n\t\tdefer: add(&value, 1)\n\t\tfor j in range(3):\n\t\t\tdefer: add(&value, 2)\n\t\t\tbreak\n\treturn value - 9\n", 0)

void test_scoped_defer_25():
	scoped_defer_case(c"void digit(refmut int* value, int amount):\n\t*value = *value * 10 + amount\n\nvoid run(refmut int* value):\n\tdefer digit(value, 1)\n\tdefer: digit(value, 2)\n\tif (1):\n\t\tdefer: digit(value, 3)\n\t\tdefer: digit(value, 4)\n\t\treturn\n\nint main():\n\tint value = 0\n\trun(&value)\n\treturn value - 4321\n", 0)

void test_scoped_defer_26():
	scoped_defer_case(c"void digit(refmut int* value, int amount):\n\t*value = *value * 10 + amount\n\nvoid run(refmut int* value):\n\tdefer digit(value, 1)\n\tdefer: digit(value, 2)\n\tif (1):\n\t\tdefer: digit(value, 3)\n\t\tdefer: digit(value, 4)\n\nint main():\n\tint value = 0\n\trun(&value)\n\treturn value - 4321\n", 0)

void test_scoped_defer_27():
	scoped_defer_case(c"void delayed[T](refmut T* value, T next):\n\tif (1):\n\t\tdefer: *value = next\n\nint main():\n\tint value = 0\n\tdelayed[int](&value, 7)\n\treturn value - 7\n", 0)

void test_scoped_defer_28():
	scoped_defer_case(c"int main():\n\tint value = 1\n\tif (1):\n\t\tdefer: value = value + 2\n\treturn value - 3\n", 0)

void test_scoped_defer_29():
	scoped_defer_case(c"int early(refmut int* value):\n\tif (*value): return 2\n\tdefer: *value = 9\n\treturn 3\n\nint main():\n\tint value = 1\n\tint result = early(&value)\n\treturn result + value - 3\n", 0)

void test_scoped_defer_30():
	scoped_defer_case(c"void consume(own int* value):\n\t*value = 1\n\nown int* returned():\n\town int* value = new int\n\tdefer: consume(value)\n\treturn value\n\nint main():\n\town int* value = returned()\n\treturn 0\n", c"moved")

void test_scoped_defer_31():
	scoped_defer_case(c"struct Pair:\n\tint first\n\tint second\n\nPair snapshot():\n\tPair value = Pair(3, 4)\n\tdefer: value.first = 9\n\treturn value\n\nint main():\n\tPair value = snapshot()\n\treturn value.first + value.second - 7\n", 0)

void test_scoped_defer_32():
	scoped_defer_case(c"int main():\n\tint value = 0\n\tdefer: absent(value)\n\treturn 0\n", c"Cannot find symbol")

void test_scoped_defer_33():
	scoped_defer_case(c"void add(refmut int* value, int amount):\n\t*value = *value + amount\n\nint main():\n\tint value = 0\n\tif (1):\n\t\tint amount = 3\n\t\tdefer: add(&value, amount)\n\t\tif (1):\n\t\t\tint amount = 7\n\t\t\tdefer: add(&value, amount)\n\treturn value - 10\n", 0)

void test_scoped_defer_34():
	scoped_defer_case(c"int observe(ref int* value):\n\treturn *value\n\nint main():\n\tint value = 0\n\twhile (1):\n\t\tref int* view = &value\n\t\tdefer: observe(view)\n\t\tvalue = 2\n\t\tbreak\n\treturn 0\n", c"borrow")

void test_scoped_defer_35():
	scoped_defer_case(c"int observe(ref int* value):\n\treturn *value\n\nint main():\n\tint value = 0\n\tfor i in range(2):\n\t\tref int* view = &value\n\t\tdefer: observe(view)\n\t\tvalue = i\n\t\tcontinue\n\treturn 0\n", c"borrow")

