# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int generic_inference_case_number


void generic_inference_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_inference_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	generic_inference_case_number = generic_inference_case_number + 1
	char* number = itoa(generic_inference_case_number)
	char* prefix = c"bin/generic_inference_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_inference_case64_"
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
		generic_inference_result(checked, diagnostic, 1, full)
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
		generic_inference_result(compiled, diagnostic, 0, full)
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

void test_generic_inference_0():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = echo(value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_1():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = echo(echo(value))\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_2():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = echo[ref[a] Borrowed](echo(value))\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_3():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = echo(echo[ref[a] Borrowed](value))\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_4():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = echo(value)\n\tn = 9\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_generic_inference_5():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nref[a] Borrowed invalid(ref[a] int* input):\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\treturn echo(value)\n\nint main():\n\treturn 0\n", c"must borrow")

void test_generic_inference_6():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\ntype Alias = ref[a] Borrowed\n\nint main():\n\tint n = 7\n\tAlias value = Borrowed(&n)\n\tAlias result = echo(value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_7():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nT repeat[T](T value, int count):\n\tif count: return repeat(value, count - 1)\n\treturn echo(value)\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = repeat(value, 5)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_8():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint read[T](T value, int extra):\n\tref int* view = value.value\n\treturn *view + extra\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\treturn read(echo(value), 5) - 12\n", 0)

void test_generic_inference_9():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint read[T](int extra, T value):\n\tref int* view = value.value\n\treturn *view + extra\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\treturn read(5, echo(value)) - 12\n", 0)

void test_generic_inference_10():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint read[T](T left, T right):\n\tref int* a = left.value\n\tref int* b = right.value\n\treturn *a + *b\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\treturn read(echo(value), echo(value)) - 14\n", 0)

void test_generic_inference_11():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint add(int a, int b):\n\treturn a + b\n\nint read[T](T value):\n\tref int* view = value.value\n\treturn *view\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\treturn add(read(echo(value)), read(echo(value))) - 14\n", 0)

void test_generic_inference_12():
	generic_inference_case(c"T echo[T](T value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tref[a] int[] view = values\n\tref[b] int[] result = echo(view)\n\treturn result[0] - 7\n", 0)

void test_generic_inference_13():
	generic_inference_case(c"T echo[T](T value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tref[a] int[] view = values\n\tref[b] int[] result = echo(echo(view))\n\treturn result[0] - 7\n", 0)

void test_generic_inference_14():
	generic_inference_case(c"T echo[T](T value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref int[] view = values\n\tref int[] result = echo(view)\n\treturn result[2]\n", 0, 0, -1, 0, c"index out of range: index 2, length 2")

void test_generic_inference_15():
	generic_inference_case(c"struct Pair:\n\tref[a] int* left\n\tref[b] int* right\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[x,y] Pair value = Pair(&a, &b)\n\tref[z,w] Pair result = echo(value)\n\tref int* view = result.right\n\ta = 8\n\treturn *view - 4\n", 0)

void test_generic_inference_16():
	generic_inference_case(c"struct Mutable:\n\trefmut[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\trefmut[a] Mutable value = Mutable(&n)\n\trefmut[b] Mutable result = echo(value)\n\trefmut int* view = result.value\n\t*view = 9\n\treturn n - 9\n", 0)

void test_generic_inference_17():
	generic_inference_case(c"struct Mixed:\n\town int* owned\n\tref[data] int* borrowed\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 4\n\town int* child = new int\n\t*child = 3\n\town[a] Mixed* owner = new Mixed(child, &n)\n\tref[a] Mixed* view = owner\n\tref[b] Mixed* result = echo(view)\n\tref int* a = result.owned\n\tref int* b = result.borrowed\n\treturn *a + *b - 7\n", 0)

void test_generic_inference_18():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nT consume[T](T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = consume(echo(value), owner)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_19():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nT consume[T](T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = consume(value, owner)\n\treturn *owner\n", c"moved")

void test_generic_inference_20():
	generic_inference_case(c"struct Plain:\n\tint a\n\tint b\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tPlain value = Plain(3, 4)\n\tPlain result = echo(echo(value))\n\treturn result.a + result.b - 7\n", 0)

void test_generic_inference_21():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tint total = 0\n\tfor i in range(200):\n\t\tref[b] Borrowed result = echo(echo(value))\n\t\tref int* view = result.value\n\t\ttotal += *view\n\treturn total - 1400\n", 0)

void test_generic_inference_22():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nT consume[T](T value, own int* owner):\n\treturn value\n\nint main():\n\town int* owner = new int\n\tref[a] Borrowed value = Borrowed(owner)\n\tref[b] Borrowed result = consume(value, owner)\n\tref int* view = result.value\n\treturn *view\n", c"conflicting call arguments")

void test_generic_inference_23():
	generic_inference_case(c"import tests.safe_generic_inference_import_fixture\n\nint main():\n\tint n = 7\n\tref[a] InferredBorrowed value = InferredBorrowed(&n)\n\tref[b] InferredBorrowed result = inferred_echo(value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_inference_24():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nT mark[T](T value, refmut int* trace, int digit):\n\t*trace = *trace * 10 + digit\n\treturn value\n\nint read[T](T left, T right):\n\tref int* a = left.value\n\tref int* b = right.value\n\treturn *a + *b\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tint trace = 0\n\tint sum = read(mark(value, &trace, 1), mark(value, &trace, 2))\n\treturn sum + trace - 26\n", 0)

void test_generic_inference_25():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nstruct Nested:\n\tref[inner] Borrowed child\n\tint tag\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Nested nested = Nested(value, 2)\n\tref[c] Nested result = echo(echo(nested))\n\tref int* view = result.child.value\n\treturn *view + result.tag - 9\n", 0)

void test_generic_inference_26():
	generic_inference_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tint total = 0\n\tif n:\n\t\tref[b] Borrowed result = echo(value)\n\t\tref int* view = result.value\n\t\ttotal = *view\n\telse:\n\t\ttotal = 1\n\treturn total - 7\n", 0)
