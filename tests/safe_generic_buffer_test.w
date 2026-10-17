# wbuild: x64
# wbuild: deps=lib/safe_vector.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int generic_buffer_case_number


void generic_buffer_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_buffer_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	generic_buffer_case_number = generic_buffer_case_number + 1
	char* number = itoa(generic_buffer_case_number)
	char* prefix = c"bin/generic_buffer_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_buffer_case64_"
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
		generic_buffer_result(checked, diagnostic, 1, full)
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
		generic_buffer_result(compiled, diagnostic, 0, full)
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

void test_generic_buffer_0():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\treturn buffer_length[int](buffer)\n", 0)

void test_generic_buffer_1():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\treturn buffer_get[int](buffer, 0) + buffer_pop[int](buffer) - 15\n", 0)

void test_generic_buffer_2():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tbuffer_set[int](buffer, 1, 11)\n\treturn buffer_get[int](buffer, 1) - 11\n", 0)

void test_generic_buffer_3():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tfor i in range(100): buffer_push[int](buffer, i)\n\tint total = 0\n\tfor i in range(100): total += buffer_pop[int](buffer)\n\treturn total - 4950\n", 0)

void test_generic_buffer_4():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tbuffer_clear[int](buffer)\n\tbuffer_push[int](buffer, 11)\n\treturn buffer_length[int](buffer) + buffer_get[int](buffer, 0) - 12\n", 0)

void test_generic_buffer_5():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\treturn view[0] + view[1] + view.length - 17\n", 0)

void test_generic_buffer_6():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\trefmut int[] view = buffer_view_mut[int](buffer)\n\tview[0] += 4\n\treturn buffer_get[int](buffer, 0) - 11\n", 0)

void test_generic_buffer_7():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\tbuffer_push[int](buffer, 9)\n\treturn view[0]\n", c"borrow")

void test_generic_buffer_8():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\tbuffer_set[int](buffer, 0, 9)\n\treturn view[0]\n", c"borrow")

void test_generic_buffer_9():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\tbuffer_clear[int](buffer)\n\treturn view[0]\n", c"borrow")

void test_generic_buffer_10():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\tint result = buffer_pop[int](buffer)\n\treturn view[0] + result\n", c"borrow")

void test_generic_buffer_11():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\tint previous = view[0]\n\tbuffer_push[int](buffer, 9)\n\treturn previous + buffer_length[int](buffer) - 10\n", 0)

void test_generic_buffer_12():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\trefmut int[] view = buffer_view_mut[int](buffer)\n\tint previous = buffer_get[int](buffer, 0)\n\tview[0] = 11\n\treturn previous\n", c"borrow")

void test_generic_buffer_13():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\town WBuffer[int]* moved = buffer\n\treturn buffer_length[int](buffer)\n", c"moved")

void test_generic_buffer_14():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\treturn buffer.length\n", c"opaque")

void test_generic_buffer_15():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer.capacity = 100\n\treturn 0\n", c"opaque")

void test_generic_buffer_16():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = new WBuffer[int]\n\treturn 0\n", c"unknown type after new")

void test_generic_buffer_17():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int*]* buffer = buffer_new[int*]()\n\treturn 0\n", c"unsupported")

void test_generic_buffer_18():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[own int*]* buffer = buffer_new[own int*]()\n\treturn 0\n", c"unsupported")

void test_generic_buffer_19():
	generic_buffer_case(c"import lib.safe_vector\nstruct Embedded:\n\tint[2] values\nint main():\n\town WBuffer[Embedded]* buffer = buffer_new[Embedded]()\n\treturn 0\n", c"unsupported")

void test_generic_buffer_20():
	generic_buffer_case(c"import lib.safe_vector\ntype Number = int\nint main():\n\town WBuffer[Number]* buffer = buffer_new[int]()\n\tbuffer_push[Number](buffer, 7)\n\treturn buffer_get[int](buffer, 0) - 7\n", 0)

void test_generic_buffer_21():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[byte]* buffer = buffer_new[byte]()\n\tbuffer_push[byte](buffer, cast(byte, 255))\n\trefmut byte[] view = buffer_view_mut[byte](buffer)\n\tview[0] = cast(byte, 7)\n\treturn cast(int, buffer_pop[byte](buffer)) - 7\n", 0)

void test_generic_buffer_22():
	generic_buffer_case(c"import lib.safe_vector\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WBuffer[Pair]* buffer = buffer_new[Pair]()\n\tbuffer_push[Pair](buffer, Pair(3, 4))\n\tPair value = buffer_get[Pair](buffer, 0)\n\trefmut Pair[] view = buffer_view_mut[Pair](buffer)\n\tview[0].left = 7\n\tPair popped = buffer_pop[Pair](buffer)\n\treturn value.left + value.right + popped.left + popped.right - 18\n", 0)

void test_generic_buffer_23():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\treturn buffer_get[int](buffer, 0)\n", 0, 0, -1, 0, c"generic buffer index out of range")

void test_generic_buffer_24():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\treturn buffer_get[int](buffer, -1)\n", 0, 0, -1, 0, c"generic buffer index out of range")

void test_generic_buffer_25():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tbuffer_set[int](buffer, 2, 9)\n\treturn 0\n", 0, 0, -1, 0, c"generic buffer index out of range")

void test_generic_buffer_26():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\treturn buffer_pop[int](buffer)\n", 0, 0, -1, 0, c"pop from empty generic buffer")

void test_generic_buffer_27():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tref int[] view = buffer_view[int](buffer)\n\treturn view.length\n", 0)

void test_generic_buffer_28():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\treturn view[2]\n", 0, 0, -1, 0, c"index out of range")

void test_generic_buffer_29():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = buffer_view[int](buffer)\n\tview[0] = 11\n\treturn 0\n", c"shared")

void test_generic_buffer_30():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\trefmut int[] first = buffer_view_mut[int](buffer)\n\trefmut int[] second = buffer_view_mut[int](buffer)\n\tfirst[0] = 11\n\treturn second[0]\n", c"borrow")

void test_generic_buffer_31():
	generic_buffer_case(c"import lib.safe_vector\ntype Buffer = WBuffer[int]\nint main():\n\town Buffer* buffer = new Buffer\n\treturn 0\n", c"opaque")

void test_generic_buffer_32():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tWBuffer[int] copied = *buffer\n\treturn 0\n", c"unsupported")

void test_generic_buffer_33():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\t__w_buffer_drop(cast(void*, buffer))\n\treturn 0\n", c"runtime call has no audited")

void test_generic_buffer_34():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[float32]* buffer = buffer_new[float32]()\n\tbuffer_push[float32](buffer, cast(float32, 1.5))\n\tfloat32 result = buffer_pop[float32](buffer)\n\treturn result != cast(float32, 1.5)\n", 0)

void test_generic_buffer_35():
	generic_buffer_case(c"import lib.safe_vector\nenum Color:\n\tred\n\tblue\nint main():\n\town WBuffer[Color]* buffer = buffer_new[Color]()\n\tbuffer_push[Color](buffer, cast(Color, 1))\n\treturn buffer_get[Color](buffer, 0) != cast(Color, 1)\n", 0)

void test_generic_buffer_36():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tif buffer_length[int](buffer) == 0:\n\t\tbuffer_push[int](buffer, 7)\n\treturn buffer_pop[int](buffer) - 7\n", 0)

void test_generic_buffer_37():
	generic_buffer_case(c"import lib.safe_vector\nref[a] int[] keep(ref[a] WBuffer[int]* buffer):\n\treturn buffer_view[int](buffer)\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\tbuffer_push[int](buffer, 8)\n\tref int[] view = keep(buffer)\n\tbuffer_clear[int](buffer)\n\treturn view[0]\n", c"borrow")

void test_generic_buffer_38():
	generic_buffer_case(c"import lib.safe_vector\nref int[] bad():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer_push[int](buffer, 7)\n\treturn buffer_view[int](buffer)\nint main():\n\treturn 0\n", c"borrow")

void test_generic_buffer_39():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\tbuffer.buffer_push[int](7)\n\treturn buffer.buffer_pop[int]() - 7\n", 0)

void test_generic_buffer_40():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\toptown WBuffer[int]* buffer = buffer_new[int]()\n\tif buffer: buffer_push[int](buffer, 7)\n\tif buffer: return buffer_pop[int](buffer) - 7\n\treturn 1\n", 0)

void test_generic_buffer_41():
	generic_buffer_case(c"import lib.safe_vector as vector\nint main():\n\town WBuffer[int]* buffer = vector.buffer_new[int]()\n\tvector.buffer_push[int](buffer, 7)\n\treturn vector.buffer_get[int](buffer, 0) - 7\n", 0)

void test_generic_buffer_42():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[void]* buffer = buffer_new[void]()\n\treturn 0\n", c"unsupported")

void test_generic_buffer_43():
	generic_buffer_case(c"import tests.safe_generic_buffer_import_fixture as helper\nint main():\n\treturn helper.vector_identity[int](7) + helper.vector_identity(8) - 15\n", 0)

void test_generic_buffer_44():
	generic_buffer_case(c"import tests.safe_generic_buffer_import_fixture as helper\nint main():\n\tint value = 7\n\tref int* input = &value\n\tref int* view = helper.vector_borrow(input)\n\treturn *view - 7\n", 0)

void test_generic_buffer_45():
	generic_buffer_case(c"import tests.safe_generic_buffer_import_fixture as helper\nint main():\n\tint value = 7\n\tref int* view = helper.vector_borrow[int](&value)\n\tvalue = 11\n\treturn *view\n", c"borrow")

void test_generic_buffer_46():
	generic_buffer_case(c"import tests.safe_generic_buffer_import_fixture as helper\nimport lib.safe_vector as vector\nint main():\n\treturn vector.vector_identity[int](7)\n", c"not defined in module")


void test_generic_buffer_runtime_pin():
	char* root = c"bin/safe_vector_pin32"
	if (__word_size__ == 8): root = c"bin/safe_vector_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/lib")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/safe_vector.w")
	char* source = strjoin(root, c".w")
	char* output = strjoin(root, c".out")
	char* original = file_read_text(c"lib/safe_vector.w")
	assert1(original != 0)
	char* changed = strjoin(original, c"\n# changed implementation cannot inherit checked contracts\n")
	assert1(file_write_text(path, changed))
	assert1(file_write_text(source, c"import lib.safe_vector\nint main():\n\town WBuffer[int]* buffer = buffer_new[int]()\n\treturn buffer_length[int](buffer)\n"))
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
			generic_buffer_result(result, c"runtime implementation differs", checking, source)
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


void test_generic_buffer_47():
	generic_buffer_case(c"import lib.safe_vector\nstruct Box:\n\town WBuffer[int]* values\nint main():\n\town Box* box = new Box(buffer_new[int]())\n\tbuffer_push[int](box.values, 7)\n\town WBuffer[int]* moved = box.values\n\tbox.values = buffer_new[int]()\n\treturn buffer_pop[int](moved) - 7\n", 0)


void test_generic_buffer_48():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tbuffer_push[int](values, 7)\n\tref int[] view = buffer_view[int](values)\n\tif buffer_length[int](values): buffer_clear[int](values)\n\treturn view[0]\n", c"borrow")


void test_generic_buffer_49():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tbuffer_push[int](values, 7)\n\tref int[] view = buffer_view[int](values)\n\tfor i in range(2): buffer_push[int](values, i)\n\treturn view[0]\n", c"borrow")


void test_generic_buffer_50():
	generic_buffer_case(c"import lib.safe_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tbuffer_push[int](values, 7)\n\trefmut int[] outer = buffer_view_mut[int](values)\n\tref int[] inner = outer\n\touter[0] = 11\n\treturn inner[0]\n", c"borrow")
