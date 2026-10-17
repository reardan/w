# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int generic_shape_case_number


void generic_shape_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_shape_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	generic_shape_case_number = generic_shape_case_number + 1
	char* number = itoa(generic_shape_case_number)
	char* prefix = c"bin/generic_shape_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_shape_case64_"
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
		generic_shape_result(checked, diagnostic, 1, full)
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
		generic_shape_result(compiled, diagnostic, 0, full)
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

void test_generic_shape_0():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[inside] T identity[T](ref[inside] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = identity[Borrowed](value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_1():
	generic_shape_case(c"struct Pair:\n\tref[first] int* left\n\tref[second] int* right\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[a,b] Pair value = Pair(&a, &b)\n\tref[c,d] Pair result = identity[Pair](value)\n\tref int* left = result.left\n\tref int* right = result.right\n\treturn *left + *right - 7\n", 0)

void test_generic_shape_2():
	generic_shape_case(c"ref[inside] T[] identity[T](ref[inside] T[] values):\n\treturn values\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tref[outside] int[] view = identity[int](values)\n\treturn view[0] - 7\n", 0)

void test_generic_shape_3():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = echo[ref[z] Borrowed](value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_4():
	generic_shape_case(c"T echo[T](T value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[b] int[] result = echo[ref[z] int[]](values)\n\treturn result[0] - 7\n", 0)

void test_generic_shape_5():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\ntype Alias = Borrowed\nref[z] T echo[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Alias value = Alias(&n)\n\tref[b] Alias result = echo[Alias](value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_6():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T bad[T](ref[z] T value):\n\tint local = 7\n\treturn Borrowed(&local)\n\nint main():\n\tint n = 1\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = bad[Borrowed](value)\n\treturn 0\n", c"must borrow from")

void test_generic_shape_7():
	generic_shape_case(c"ref[z] T[] bad[T](ref[z] T[] value):\n\tT[2] local\n\treturn local\n\nint main():\n\tint[2] values\n\tref[a] int[] result = bad[int](values)\n\treturn 0\n", c"must borrow from")

void test_generic_shape_8():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = identity[Borrowed](value)\n\tn = 9\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_generic_shape_9():
	generic_shape_case(c"struct Pair:\n\tref[first] int* left\n\tref[second] int* right\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[a,b] Pair value = Pair(&a, &b)\n\tref[c,d] Pair result = identity[Pair](value)\n\tref int* right = result.right\n\ta = 5\n\treturn *right - 4\n", 0)

void test_generic_shape_10():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nstruct Nested:\n\tref[nested] Borrowed child\n\tref[other] int[] data\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tint[2] values\n\tvalues[0] = 4\n\tref[a] Borrowed child = Borrowed(&n)\n\tref[b,c] Nested input = Nested(child, values)\n\tref[d,e] Nested output = identity[Nested](input)\n\tref int* view = output.child.value\n\tref int[] data = output.data\n\treturn *view + data[0] - 11\n", 0)

void test_generic_shape_11():
	generic_shape_case(c"struct Mutable:\n\trefmut[data] int* value\n\nrefmut[z] T identity[T](refmut[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\trefmut[a] Mutable value = Mutable(&n)\n\trefmut[b] Mutable result = identity[Mutable](value)\n\trefmut int* view = result.value\n\t*view = 9\n\treturn n - 9\n", 0)

void test_generic_shape_12():
	generic_shape_case(c"struct Mutable:\n\trefmut[data] int* value\n\nrefmut[z] T identity[T](refmut[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\trefmut[a] Mutable value = Mutable(&n)\n\trefmut[b] Mutable result = identity[Mutable](value)\n\trefmut int* first = value.value\n\t*first = 8\n\trefmut int* second = result.value\n\treturn *second\n", c"borrow")

void test_generic_shape_13():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[b] T shorten[T](ref[a] T value) where a > b:\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = shorten[Borrowed](value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_14():
	generic_shape_case(c"ref[b] T[] shorten[T](ref[a] T[] value) where a > b:\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = shorten[int](values)\n\treturn result[0] - 7\n", 0)

void test_generic_shape_15():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T repeat[T](ref[z] T value, int count):\n\tif (count): return repeat[T](value, count - 1)\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = repeat[Borrowed](value, 4)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_16():
	generic_shape_case(c"ref[z] T[] repeat[T](ref[z] T[] value, int count):\n\tif (count): return repeat[T](value, count - 1)\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = repeat[int](values, 4)\n\treturn result[0] - 7\n", 0)

void test_generic_shape_17():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T echo[T](ref[z] T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = echo[Borrowed](value, owner)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_18():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T echo[T](ref[z] T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = echo[Borrowed](value, owner)\n\treturn *owner\n", c"moved")

void test_generic_shape_19():
	generic_shape_case(c"struct Pair:\n\tref[first] int* left\n\tref[second] int* right\n\nref[z] T wrong[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[a,b] Pair value = Pair(&a, &b)\n\tref[c,d] Pair result = wrong[Pair](value)\n\treturn 0\n", c"lifetime arity")

void test_generic_shape_20():
	generic_shape_case(c"ref T[] plain_slice[T](ref T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] result = plain_slice[int](values)\n\treturn result[0] - 7\n", 0)

void test_generic_shape_21():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref T plain_record[T](ref T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref Borrowed value = Borrowed(&n)\n\tref Borrowed result = plain_record[Borrowed](value)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_22():
	generic_shape_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref[z] int[] result = identity[int](values)\n\treturn result[3]\n", 0, 0, -1, 0, c"index out of range: index 3, length 2")

void test_generic_shape_23():
	generic_shape_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref[z] int[] result = identity[int](values)\n\tint index = -1\n\treturn result[index]\n", 0, 0, -1, 0, c"index out of range: index -1, length 2")

void test_generic_shape_24():
	generic_shape_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[1] = 7\n\tref int[] input = values\n\tref[z] int[] result = identity[int](input[1:3])\n\treturn result[0] - 7\n", 0)

void test_generic_shape_25():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\town int* owner = new int\n\t*owner = 7\n\tref[a] Borrowed value = Borrowed(owner)\n\tref[b] Borrowed result = identity[Borrowed](value)\n\towner = new int\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_generic_shape_26():
	generic_shape_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = identity[Borrowed](identity[Borrowed](value))\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_shape_27():
	generic_shape_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = identity[int](identity[int](values))\n\treturn result[0] - 7\n", 0)

void test_generic_shape_28():
	generic_shape_case(c"import tests.safe_generic_shape_import_fixture\n\nint main():\n\tint n = 7\n\tint[2] values\n\tvalues[0] = 4\n\tref[a,b] GenericBorrowed value = GenericBorrowed(&n, values)\n\tref[c,d] GenericBorrowed result = generic_shape_identity[GenericBorrowed](value)\n\tref int* view = result.scalar\n\treturn *view - 7\n", 0)

void test_generic_shape_29():
	generic_shape_case(c"int record_only[T](ref[a] T value):\n\treturn 0\n\nint main():\n\treturn 0\n", 0)

void test_generic_shape_30():
	generic_shape_case(c"ref[a] T record_only[T](ref[a] T value):\n\treturn value\n\nint main():\n\tint n = 1\n\treturn record_only[int](n)\n", c"checked pointers require a single pointer")

void test_generic_shape_31():
	generic_shape_case(c"refmut[a] T[] invalid[T](refmut[a] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref int[] view = invalid[int](values)\n\treturn 0\n", 0)

void test_generic_shape_32():
	generic_shape_case(c"struct OptionalRecord:\n\toptref[data] int* value\n\nref[a] T identity[T](ref[a] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[b] OptionalRecord value = OptionalRecord(&n)\n\tref[c] OptionalRecord result = identity[OptionalRecord](value)\n\toptref int* view = result.value\n\tif (view): return *view - 7\n\treturn 1\n", 0)
