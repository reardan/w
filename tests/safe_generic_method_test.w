# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int generic_method_case_number


void generic_method_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_method_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	generic_method_case_number = generic_method_case_number + 1
	char* number = itoa(generic_method_case_number)
	char* prefix = c"bin/generic_method_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_method_case64_"
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
		generic_method_result(checked, diagnostic, 1, full)
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
		generic_method_result(compiled, diagnostic, 0, full)
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

void test_generic_method_0():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[inside] T identity[T](ref[inside] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).identity[Borrowed]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_1():
	generic_method_case(c"struct Pair:\n\tref[first] int* left\n\tref[second] int* right\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[a,b] Pair value = Pair(&a, &b)\n\tref[c,d] Pair result = (value).identity[Pair]()\n\tref int* left = result.left\n\tref int* right = result.right\n\treturn *left + *right - 7\n", 0)

void test_generic_method_2():
	generic_method_case(c"ref[inside] T[] identity[T](ref[inside] T[] values):\n\treturn values\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tref[outside] int[] view = (values).identity[int]()\n\treturn view[0] - 7\n", 0)

void test_generic_method_3():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).echo[ref[z] Borrowed]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_4():
	generic_method_case(c"T echo[T](T value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[b] int[] result = (values).echo[ref[z] int[]]()\n\treturn result[0] - 7\n", 0)

void test_generic_method_5():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\ntype Alias = Borrowed\nref[z] T echo[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Alias value = Alias(&n)\n\tref[b] Alias result = (value).echo[Alias]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_6():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T bad[T](ref[z] T value):\n\tint local = 7\n\treturn Borrowed(&local)\n\nint main():\n\tint n = 1\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = bad[Borrowed](value)\n\treturn 0\n", c"must borrow from")

void test_generic_method_7():
	generic_method_case(c"ref[z] T[] bad[T](ref[z] T[] value):\n\tT[2] local\n\treturn local\n\nint main():\n\tint[2] values\n\tref[a] int[] result = bad[int](values)\n\treturn 0\n", c"must borrow from")

void test_generic_method_8():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).identity[Borrowed]()\n\tn = 9\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_generic_method_9():
	generic_method_case(c"struct Pair:\n\tref[first] int* left\n\tref[second] int* right\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[a,b] Pair value = Pair(&a, &b)\n\tref[c,d] Pair result = (value).identity[Pair]()\n\tref int* right = result.right\n\ta = 5\n\treturn *right - 4\n", 0)

void test_generic_method_10():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nstruct Nested:\n\tref[nested] Borrowed child\n\tref[other] int[] data\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tint[2] values\n\tvalues[0] = 4\n\tref[a] Borrowed child = Borrowed(&n)\n\tref[b,c] Nested input = Nested(child, values)\n\tref[d,e] Nested output = (input).identity[Nested]()\n\tref int* view = output.child.value\n\tref int[] data = output.data\n\treturn *view + data[0] - 11\n", 0)

void test_generic_method_11():
	generic_method_case(c"struct Mutable:\n\trefmut[data] int* value\n\nrefmut[z] T identity[T](refmut[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\trefmut[a] Mutable value = Mutable(&n)\n\trefmut[b] Mutable result = (value).identity[Mutable]()\n\trefmut int* view = result.value\n\t*view = 9\n\treturn n - 9\n", 0)

void test_generic_method_12():
	generic_method_case(c"struct Mutable:\n\trefmut[data] int* value\n\nrefmut[z] T identity[T](refmut[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\trefmut[a] Mutable value = Mutable(&n)\n\trefmut[b] Mutable result = (value).identity[Mutable]()\n\trefmut int* first = value.value\n\t*first = 8\n\trefmut int* second = result.value\n\treturn *second\n", c"borrow")

void test_generic_method_13():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[b] T shorten[T](ref[a] T value) where a > b:\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).shorten[Borrowed]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_14():
	generic_method_case(c"ref[b] T[] shorten[T](ref[a] T[] value) where a > b:\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = (values).shorten[int]()\n\treturn result[0] - 7\n", 0)

void test_generic_method_15():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T repeat[T](ref[z] T value, int count):\n\tif (count): return repeat[T](value, count - 1)\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).repeat[Borrowed](4)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_16():
	generic_method_case(c"ref[z] T[] repeat[T](ref[z] T[] value, int count):\n\tif (count): return repeat[T](value, count - 1)\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = (values).repeat[int](4)\n\treturn result[0] - 7\n", 0)

void test_generic_method_17():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T echo[T](ref[z] T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = (value).echo[Borrowed](owner)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_18():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T echo[T](ref[z] T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = (value).echo[Borrowed](owner)\n\treturn *owner\n", c"moved")

void test_generic_method_19():
	generic_method_case(c"ref T[] plain_slice[T](ref T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] result = (values).plain_slice[int]()\n\treturn result[0] - 7\n", 0)

void test_generic_method_20():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref T plain_record[T](ref T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref Borrowed value = Borrowed(&n)\n\tref Borrowed result = (value).plain_record[Borrowed]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_21():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref[z] int[] result = (values).identity[int]()\n\treturn result[3]\n", 0, 0, -1, 0, c"index out of range: index 3, length 2")

void test_generic_method_22():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref[z] int[] result = (values).identity[int]()\n\tint index = -1\n\treturn result[index]\n", 0, 0, -1, 0, c"index out of range: index -1, length 2")

void test_generic_method_23():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[1] = 7\n\tref int[] input = values\n\tref[z] int[] result = (input[1:3]).identity[int]()\n\treturn result[0] - 7\n", 0)

void test_generic_method_24():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\town int* owner = new int\n\t*owner = 7\n\tref[a] Borrowed value = Borrowed(owner)\n\tref[b] Borrowed result = (value).identity[Borrowed]()\n\towner = new int\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_generic_method_25():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = ((value).identity[Borrowed]()).identity[Borrowed]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_26():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = ((values).identity[int]()).identity[int]()\n\treturn result[0] - 7\n", 0)

void test_generic_method_27():
	generic_method_case(c"import tests.safe_generic_shape_import_fixture\n\nint main():\n\tint n = 7\n\tint[2] values\n\tvalues[0] = 4\n\tref[a,b] GenericBorrowed value = GenericBorrowed(&n, values)\n\tref[c,d] GenericBorrowed result = (value).generic_shape_identity[GenericBorrowed]()\n\tref int* view = result.scalar\n\treturn *view - 7\n", 0)

void test_generic_method_28():
	generic_method_case(c"int record_only[T](ref[a] T value):\n\treturn 0\n\nint main():\n\treturn 0\n", 0)

void test_generic_method_29():
	generic_method_case(c"struct OptionalRecord:\n\toptref[data] int* value\n\nref[a] T identity[T](ref[a] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[b] OptionalRecord value = OptionalRecord(&n)\n\tref[c] OptionalRecord result = (value).identity[OptionalRecord]()\n\toptref int* view = result.value\n\tif (view): return *view - 7\n\treturn 1\n", 0)

void test_generic_method_30():
	generic_method_case(c"int add[T](T value, int extra):\n\treturn value + extra\n\nint main():\n\treturn (7).add[int](3) - 10\n", 0)

void test_generic_method_31():
	generic_method_case(c"own T* take[T](own T* value):\n\treturn value\n\nint main():\n\town int* owner = new int\n\t*owner = 7\n\town int* result = owner.take[int]()\n\treturn *result - 7\n", 0)

void test_generic_method_32():
	generic_method_case(c"own T* take[T](own T* value):\n\treturn value\n\nint main():\n\town int* owner = new int\n\town int* result = owner.take[int]()\n\treturn *owner\n", c"moved")

void test_generic_method_33():
	generic_method_case(c"struct Point:\n\tint x\n\tint y\n\nint Point_sum[T](ref Point* self, T extra):\n\treturn self.x + self.y + extra\n\nint main():\n\tPoint point = Point(3, 4)\n\treturn point.sum[int](5) - 12\n", 0)

void test_generic_method_34():
	generic_method_case(c"struct R:\n\tref[a] int* value\n\nref[a] T R_echo[T](ref[a] T value):\n\treturn value\n\nint echo[T](T value):\n\treturn 1\n\nint main():\n\tint n = 7\n\tref[a] R value = R(&n)\n\tref[b] R result = value.echo[R]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_35():
	generic_method_case(c"struct Point:\n\tint x\n\tint y\n\nint Point_sum(ref Point* self, int extra):\n\treturn self.x + self.y + extra\n\nint sum[T](ref Point* self, T extra):\n\treturn 99\n\nint main():\n\tPoint point = Point(3, 4)\n\treturn point.sum(5) - 12\n", 0)

void test_generic_method_36():
	generic_method_case(c"struct Point:\n\tint x\n\tint y\n\nint Point_sum[T](ref Point* self, T extra):\n\treturn self.x + self.y + extra\n\nint sum(ref Point* self, int extra):\n\treturn 99\n\nint main():\n\tPoint point = Point(3, 4)\n\treturn point.sum[int](5) - 12\n", 0)

void test_generic_method_37():
	generic_method_case(c"struct R:\n\tref[a] int* value\n\nref[a] R mark(ref[a] R value, refmut int* trace):\n\t*trace = *trace + 1\n\treturn value\n\nint read_marked[T](ref[a] T value, refmut int* trace):\n\t*trace = *trace * 10 + 2\n\tref int* view = value.value\n\treturn *view\n\nint main():\n\tint n = 7\n\tint trace = 0\n\tref[a] R value = R(&n)\n\tint result = mark(value, &trace).read_marked[R](&trace)\n\treturn result + trace - 19\n", 0)

void test_generic_method_38():
	generic_method_case(c"own int* make():\n\town int* value = new int\n\t*value = 7\n\treturn value\n\nown T* take[T](own T* value):\n\treturn value\n\nint main():\n\town int* result = make().take[int]()\n\treturn *result - 7\n", 0)

void test_generic_method_39():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[inside] T identity[T](ref[inside] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).identity()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_40():
	generic_method_case(c"struct Pair:\n\tref[first] int* left\n\tref[second] int* right\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[a,b] Pair value = Pair(&a, &b)\n\tref[c,d] Pair result = (value).identity()\n\tref int* left = result.left\n\tref int* right = result.right\n\treturn *left + *right - 7\n", 0)

void test_generic_method_41():
	generic_method_case(c"ref[inside] T[] identity[T](ref[inside] T[] values):\n\treturn values\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tref[outside] int[] view = (values).identity()\n\treturn view[0] - 7\n", 0)

void test_generic_method_42():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nT echo[T](T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).echo()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_43():
	generic_method_case(c"T echo[T](T value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] input = values\n\tref[b] int[] result = (input).echo()\n\treturn result[0] - 7\n", 0)

void test_generic_method_44():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\ntype Alias = Borrowed\nref[z] T echo[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Alias value = Alias(&n)\n\tref[b] Alias result = (value).echo()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_45():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T bad[T](ref[z] T value):\n\tint local = 7\n\treturn Borrowed(&local)\n\nint main():\n\tint n = 1\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = bad[Borrowed](value)\n\treturn 0\n", c"must borrow from")

void test_generic_method_46():
	generic_method_case(c"ref[z] T[] bad[T](ref[z] T[] value):\n\tT[2] local\n\treturn local\n\nint main():\n\tint[2] values\n\tref[a] int[] result = bad[int](values)\n\treturn 0\n", c"must borrow from")

void test_generic_method_47():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).identity()\n\tn = 9\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_generic_method_48():
	generic_method_case(c"struct Pair:\n\tref[first] int* left\n\tref[second] int* right\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint a = 3\n\tint b = 4\n\tref[a,b] Pair value = Pair(&a, &b)\n\tref[c,d] Pair result = (value).identity()\n\tref int* right = result.right\n\ta = 5\n\treturn *right - 4\n", 0)

void test_generic_method_49():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nstruct Nested:\n\tref[nested] Borrowed child\n\tref[other] int[] data\n\nref[x,y] T identity[T](ref[x,y] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tint[2] values\n\tvalues[0] = 4\n\tref[a] Borrowed child = Borrowed(&n)\n\tref[b,c] Nested input = Nested(child, values)\n\tref[d,e] Nested output = (input).identity()\n\tref int* view = output.child.value\n\tref int[] data = output.data\n\treturn *view + data[0] - 11\n", 0)

void test_generic_method_50():
	generic_method_case(c"struct Mutable:\n\trefmut[data] int* value\n\nrefmut[z] T identity[T](refmut[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\trefmut[a] Mutable value = Mutable(&n)\n\trefmut[b] Mutable result = (value).identity()\n\trefmut int* view = result.value\n\t*view = 9\n\treturn n - 9\n", 0)

void test_generic_method_51():
	generic_method_case(c"struct Mutable:\n\trefmut[data] int* value\n\nrefmut[z] T identity[T](refmut[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\trefmut[a] Mutable value = Mutable(&n)\n\trefmut[b] Mutable result = (value).identity()\n\trefmut int* first = value.value\n\t*first = 8\n\trefmut int* second = result.value\n\treturn *second\n", c"borrow")

void test_generic_method_52():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[b] T shorten[T](ref[a] T value) where a > b:\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).shorten()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_53():
	generic_method_case(c"ref[b] T[] shorten[T](ref[a] T[] value) where a > b:\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = (values).shorten()\n\treturn result[0] - 7\n", 0)

void test_generic_method_54():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T repeat[T](ref[z] T value, int count):\n\tif (count): return repeat[T](value, count - 1)\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = (value).repeat(4)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_55():
	generic_method_case(c"ref[z] T[] repeat[T](ref[z] T[] value, int count):\n\tif (count): return repeat[T](value, count - 1)\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = (values).repeat(4)\n\treturn result[0] - 7\n", 0)

void test_generic_method_56():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T echo[T](ref[z] T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = (value).echo(owner)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_57():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T echo[T](ref[z] T value, own int* owner):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\town int* owner = new int\n\tref[b] Borrowed result = (value).echo(owner)\n\treturn *owner\n", c"moved")

void test_generic_method_58():
	generic_method_case(c"ref T[] plain_slice[T](ref T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] result = (values).plain_slice()\n\treturn result[0] - 7\n", 0)

void test_generic_method_59():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref T plain_record[T](ref T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref Borrowed value = Borrowed(&n)\n\tref Borrowed result = (value).plain_record()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_60():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref[z] int[] result = (values).identity()\n\treturn result[3]\n", 0, 0, -1, 0, c"index out of range: index 3, length 2")

void test_generic_method_61():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tref[z] int[] result = (values).identity()\n\tint index = -1\n\treturn result[index]\n", 0, 0, -1, 0, c"index out of range: index -1, length 2")

void test_generic_method_62():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[1] = 7\n\tref int[] input = values\n\tref[z] int[] result = (input[1:3]).identity()\n\treturn result[0] - 7\n", 0)

void test_generic_method_63():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\town int* owner = new int\n\t*owner = 7\n\tref[a] Borrowed value = Borrowed(owner)\n\tref[b] Borrowed result = (value).identity()\n\towner = new int\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_generic_method_64():
	generic_method_case(c"struct Borrowed:\n\tref[data] int* value\n\nref[z] T identity[T](ref[z] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[a] Borrowed value = Borrowed(&n)\n\tref[b] Borrowed result = ((value).identity()).identity()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_65():
	generic_method_case(c"ref[z] T[] identity[T](ref[z] T[] value):\n\treturn value\n\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref[z] int[] result = ((values).identity()).identity()\n\treturn result[0] - 7\n", 0)

void test_generic_method_66():
	generic_method_case(c"import tests.safe_generic_shape_import_fixture\n\nint main():\n\tint n = 7\n\tint[2] values\n\tvalues[0] = 4\n\tref[a,b] GenericBorrowed value = GenericBorrowed(&n, values)\n\tref[c,d] GenericBorrowed result = (value).generic_shape_identity()\n\tref int* view = result.scalar\n\treturn *view - 7\n", 0)

void test_generic_method_67():
	generic_method_case(c"int record_only[T](ref[a] T value):\n\treturn 0\n\nint main():\n\treturn 0\n", 0)

void test_generic_method_68():
	generic_method_case(c"struct OptionalRecord:\n\toptref[data] int* value\n\nref[a] T identity[T](ref[a] T value):\n\treturn value\n\nint main():\n\tint n = 7\n\tref[b] OptionalRecord value = OptionalRecord(&n)\n\tref[c] OptionalRecord result = (value).identity()\n\toptref int* view = result.value\n\tif (view): return *view - 7\n\treturn 1\n", 0)

void test_generic_method_69():
	generic_method_case(c"int add[T](T value, int extra):\n\treturn value + extra\n\nint main():\n\treturn (7).add(3) - 10\n", 0)

void test_generic_method_70():
	generic_method_case(c"own T* take[T](own T* value):\n\treturn value\n\nint main():\n\town int* owner = new int\n\t*owner = 7\n\town int* result = owner.take()\n\treturn *result - 7\n", 0)

void test_generic_method_71():
	generic_method_case(c"own T* take[T](own T* value):\n\treturn value\n\nint main():\n\town int* owner = new int\n\town int* result = owner.take()\n\treturn *owner\n", c"moved")

void test_generic_method_72():
	generic_method_case(c"struct Point:\n\tint x\n\tint y\n\nint Point_sum[T](ref Point* self, T extra):\n\treturn self.x + self.y + extra\n\nint main():\n\tPoint point = Point(3, 4)\n\treturn point.sum(5) - 12\n", 0)

void test_generic_method_73():
	generic_method_case(c"struct R:\n\tref[a] int* value\n\nref[a] T R_echo[T](ref[a] T value):\n\treturn value\n\nint echo[T](T value):\n\treturn 1\n\nint main():\n\tint n = 7\n\tref[a] R value = R(&n)\n\tref[b] R result = value.echo()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_generic_method_74():
	generic_method_case(c"struct Point:\n\tint x\n\tint y\n\nint Point_sum(ref Point* self, int extra):\n\treturn self.x + self.y + extra\n\nint sum[T](ref Point* self, T extra):\n\treturn 99\n\nint main():\n\tPoint point = Point(3, 4)\n\treturn point.sum(5) - 12\n", 0)

void test_generic_method_75():
	generic_method_case(c"struct Point:\n\tint x\n\tint y\n\nint Point_sum[T](ref Point* self, T extra):\n\treturn self.x + self.y + extra\n\nint sum(ref Point* self, int extra):\n\treturn 99\n\nint main():\n\tPoint point = Point(3, 4)\n\treturn point.sum(5) - 12\n", 0)

void test_generic_method_76():
	generic_method_case(c"struct R:\n\tref[a] int* value\n\nref[a] R mark(ref[a] R value, refmut int* trace):\n\t*trace = *trace + 1\n\treturn value\n\nint read_marked[T](ref[a] T value, refmut int* trace):\n\t*trace = *trace * 10 + 2\n\tref int* view = value.value\n\treturn *view\n\nint main():\n\tint n = 7\n\tint trace = 0\n\tref[a] R value = R(&n)\n\tint result = mark(value, &trace).read_marked(&trace)\n\treturn result + trace - 19\n", 0)

void test_generic_method_77():
	generic_method_case(c"own int* make():\n\town int* value = new int\n\t*value = 7\n\treturn value\n\nown T* take[T](own T* value):\n\treturn value\n\nint main():\n\town int* result = make().take()\n\treturn *result - 7\n", 0)
