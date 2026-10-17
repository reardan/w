# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int mutable_slice_case_number


void mutable_slice_result(process_result* result, char* diagnostic, int checking, char* path):
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


void mutable_slice_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	mutable_slice_case_number = mutable_slice_case_number + 1
	char* number = itoa(mutable_slice_case_number)
	char* prefix = c"bin/mutable_slice_case32_"
	if (__word_size__ == 8): prefix = c"bin/mutable_slice_case64_"
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
		mutable_slice_result(checked, diagnostic, 1, full)
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
		mutable_slice_result(compiled, diagnostic, 0, full)
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

void test_mutable_slice_0():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tview[0] = 11\n\treturn view[0] - 11\n", 0)

void test_mutable_slice_1():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tview[0] = 11\n\treturn values[0] - 11\n", 0)

void test_mutable_slice_2():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tref int[] shared = view\n\treturn shared[0] - 7\n", 0)

void test_mutable_slice_3():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\tref int[] shared = values\n\trefmut int[] view = shared\n\tview[0] = 11\n\treturn 0\n", c"mutable borrow from a shared")

void test_mutable_slice_4():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] first = values\n\trefmut int[] second = values\n\tfirst[0] = 1\n\tsecond[0] = 2\n\treturn 0\n", c"borrow")

void test_mutable_slice_5():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tint old = values[0]\n\tview[0] = 11\n\treturn old\n", c"borrow")

void test_mutable_slice_6():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tview.length = 1\n\treturn 0\n", c"read-only buffer field")

void test_mutable_slice_7():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tview.data = 0\n\treturn 0\n", c"read-only buffer field")

void test_mutable_slice_8():
	mutable_slice_case(c"refmut[a] int[] tail(refmut[a] int[] values):\n\treturn values[1:]\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = tail(values)\n\tview[0] = 11\n\treturn values[1] - 11\n", 0)

void test_mutable_slice_9():
	mutable_slice_case(c"refmut[a] int[] tail(refmut[a] int[] values):\n\treturn values[1:]\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = tail(values)\n\tvalues[0] = 11\n\treturn view[0]\n", c"borrow")

void test_mutable_slice_10():
	mutable_slice_case(c"refmut[a] int[] bad(refmut[a] int[] input):\n\tint[2] local\n\treturn local\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = bad(values)\n\treturn 0\n", c"borrow")

void test_mutable_slice_11():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\trefmut int* element = &view[1]\n\t*element = 11\n\treturn values[1] - 11\n", 0)

void test_mutable_slice_12():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tref int[] shared = view\n\tview[0] = 11\n\treturn shared[0]\n", c"borrow")

void test_mutable_slice_13():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tref int[] shared = view\n\tint previous = shared[0]\n\tview[0] = 11\n\treturn previous + view[0] - 18\n", 0)

void test_mutable_slice_14():
	mutable_slice_case(c"type Mut = refmut[a] int[]\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\tMut view = values\n\tview[0] = 11\n\treturn view[0] - 11\n", 0)

void test_mutable_slice_15():
	mutable_slice_case(c"refmut[a] T[] identity[T](refmut[a] T[] value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = identity[int](values)\n\tview[0] = 11\n\treturn values[0] - 11\n", 0)

void test_mutable_slice_16():
	mutable_slice_case(c"refmut[a] T[] identity[T](refmut[a] T[] value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = identity(values)\n\tview[0] = 11\n\treturn values[0] - 11\n", 0)

void test_mutable_slice_17():
	mutable_slice_case(c"refmut[a] T[] identity[T](refmut[a] T[] value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values.identity[int]().identity()\n\tview[0] = 11\n\treturn values[0] - 11\n", 0)

void test_mutable_slice_18():
	mutable_slice_case(c"refmut[a] T[] identity[T](refmut[a] T[] value):\n\treturn value\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\tref int[] shared = values\n\trefmut int[] view = identity(shared)\n\treturn view[0]\n", c"mutable borrow from a shared")

void test_mutable_slice_19():
	mutable_slice_case(c"type Tail = fn[a](refmut[a] int[]) -> refmut[a] int[]\nrefmut[a] int[] tail(refmut[a] int[] values):\n\treturn values[1:]\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\tTail* code = tail\n\trefmut int[] view = code(values)\n\tview[0] = 11\n\treturn values[1] - 11\n", 0)

void test_mutable_slice_20():
	mutable_slice_case(c"struct Borrowed:\n\trefmut[data] int[] values\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut[a] Borrowed record = Borrowed(values)\n\trefmut int[] view = record.values\n\tview[0] = 11\n\treturn values[0] - 11\n", 0)

void test_mutable_slice_21():
	mutable_slice_case(c"struct Borrowed:\n\trefmut[data] int[] values\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\tref[a] Borrowed record = Borrowed(values)\n\treturn 0\n", c"aggregate")

void test_mutable_slice_22():
	mutable_slice_case(c"int modify(refmut byte[] data):\n\tdata[0] = cast(byte, 7)\n\treturn cast(int, data[0])\n\nint main():\n\tbyte[3] data\n\treturn modify(data) - 7\n", 0)

void test_mutable_slice_23():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\toptrefmut int[] view = values\n\treturn 0\n", c"checked slices require ref or refmut")

void test_mutable_slice_24():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tfor i in range(view.length):\n\t\tview[i] += 1\n\treturn view[0] + view[1] + view[2] - 27\n", 0)

void test_mutable_slice_25():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\trefmut int* length = &view.length\n\t*length = 1\n\treturn 0\n", c"metadata")

void test_mutable_slice_26():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tint* raw = view.data\n\treturn 0\n", c"unsupported type")

void test_mutable_slice_27():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\trefmut int[] empty = view[0:0]\n\treturn empty.length\n", 0)

void test_mutable_slice_28():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\trefmut int[] empty = view[0:0]\n\tempty[0] = 1\n\treturn 0\n", 0, 0, -1, 0, c"index out of range: index 0, length 0")

void test_mutable_slice_29():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tint low = -1\n\trefmut int[] tail = view[low:]\n\treturn tail.length\n", 0, 0, -1, 0, c"index out of range: index -1, length 3")

void test_mutable_slice_30():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tint high = 4\n\trefmut int[] tail = view[:high]\n\treturn tail.length\n", 0, 0, -1, 0, c"index out of range: index 4, length 3")

void test_mutable_slice_31():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\tint low = 2\n\trefmut int[] tail = view[low:1]\n\treturn tail.length\n", 0, 0, -1, 0, c"index out of range: index 2, length 1")

void test_mutable_slice_32():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\treturn view.data == 0\n", c"unsupported type")

void test_mutable_slice_33():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] first = values\n\trefmut int[] second = first\n\tfirst[0] = 11\n\treturn second[0]\n", c"borrow")

void test_mutable_slice_34():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] first = values\n\trefmut int[] second = first\n\tsecond[0] = 11\n\tfirst[0] += 1\n\treturn first[0] - 12\n", 0)

void test_mutable_slice_35():
	mutable_slice_case(c"int main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\trefmut int[] view = values\n\trefmut int[] left = view[0:1]\n\trefmut int[] right = view[1:]\n\tleft[0] = 11\n\tright[0] = 12\n\treturn 0\n", c"borrow")

void test_mutable_slice_36():
	mutable_slice_case(c"struct Pair:\n\trefmut[left] int[] first\n\trefmut[right] int[] second\n\nint main():\n\tint[3] values\n\tvalues[0] = 7\n\tvalues[1] = 8\n\tvalues[2] = 9\n\tint[2] other\n\trefmut[a,b] Pair pair = Pair(values, other)\n\trefmut int[] first = pair.first\n\tother[0] = 9\n\tfirst[0] = 11\n\treturn values[0] + other[0] - 20\n", 0)
