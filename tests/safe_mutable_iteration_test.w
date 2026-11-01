# wbuild: x64
# wbuild: deps=lib/safe_vector.w
# wbuild: deps=lib/safe_owned_vector.w
# wbuild: deps=tests/safe_mutable_iteration_module.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int mutable_iteration_case_number


void mutable_iteration_result(process_result* result, char* diagnostic, int checking, char* path):
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


void mutable_iteration_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	mutable_iteration_case_number = mutable_iteration_case_number + 1
	char* number = itoa(mutable_iteration_case_number)
	char* prefix = c"bin/mutable_iteration_case32_"
	if (__word_size__ == 8): prefix = c"bin/mutable_iteration_case64_"
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
		mutable_iteration_result(checked, diagnostic, 1, full)
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
		mutable_iteration_result(compiled, diagnostic, 0, full)
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

void test_mutable_iteration_0():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values): *item *= 2\n\treturn buffer_get[int](values, 2) - 6\n", 0)

void test_mutable_iteration_1():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tint total = 0\n\tfor item in buffer_view_mut[int](values): total += item\n\treturn total - 6\n", 0)

void test_mutable_iteration_2():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tint total = 0\n\tfor ref int* item in buffer_view_mut[int](values): total += *item\n\treturn total - 6\n", 0)

void test_mutable_iteration_3():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view[int](values): *item = 7\n\treturn 0\n", c"shared reference variable")

void test_mutable_iteration_4():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\trefmut int[] view = buffer_view_mut[int](values)\n\tfor refmut int* item in view[1:]: *item += 2\n\treturn buffer_get[int](values, 0) + buffer_get[int](values, 2) - 6\n", 0)

void test_mutable_iteration_5():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor item in buffer_view_mut[Pair](values): item.x += item.y\n\tPair result = buffer_get[Pair](values, 1)\n\treturn result.x - 12\n", 0)

void test_mutable_iteration_6():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor refmut Pair* item in buffer_view_mut[Pair](values):\n\t\trefmut int* field = &item.x\n\t\t*field += 1\n\tPair result = buffer_get[Pair](values, 1)\n\treturn result.x - 6\n", 0)

void test_mutable_iteration_7():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tint total = 0\n\tfor ref Pair* item in buffer_view_mut[Pair](values): total += item.x\n\treturn total - 7\n", 0)

void test_mutable_iteration_8():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WBuffer[Pair]* values = buffer_new[Pair]()\n\tbuffer_push[Pair](values, Pair(2, 3))\n\tbuffer_push[Pair](values, Pair(5, 7))\n\tfor refmut int* item in buffer_view_mut[Pair](values): pass\n\treturn 0\n", c"incompatible record slice")

void test_mutable_iteration_9():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tbuffer_push[int](values, 8)\n\treturn 0\n", c"borrow")

void test_mutable_iteration_10():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tbuffer_clear[int](values)\n\t\treturn *item\n\treturn 0\n", c"borrow")

void test_mutable_iteration_11():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\t*item += 1\n\t\tbuffer_clear[int](values)\n\t\tbreak\n\treturn buffer_length[int](values)\n", 0)

void test_mutable_iteration_12():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tbuffer_clear[int](values)\n\t\tcontinue\n\treturn 0\n", c"borrow")

void test_mutable_iteration_13():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\t*item += 1\n\t\tif *item == 2: continue\n\t\tbreak\n\treturn buffer_get[int](values, 1) - 3\n", 0)

void test_mutable_iteration_14():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\toptrefmut int* saved = 0\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tsaved = item\n\t\tbreak\n\tif saved: *saved = 19\n\treturn buffer_get[int](values, 0) - 19\n", 0)

void test_mutable_iteration_15():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\toptrefmut int* saved = 0\n\tfor refmut int* item in buffer_view_mut[int](values): saved = item\n\tif saved: return *saved\n\treturn 0\n", c"borrow")

void test_mutable_iteration_16():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tref int* alias = item\n\t\t*item = 8\n\t\tif *alias == 1: return 1\n\treturn 0\n", c"borrow")

void test_mutable_iteration_17():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tref int* alias = item\n\t\tint copy = *alias\n\t\t*item = copy + 1\n\treturn buffer_get[int](values, 0) - 2\n", 0)

void test_mutable_iteration_18():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tfor refmut int* other in buffer_view_mut[int](values): *other += *item\n\treturn 0\n", c"borrow")

void test_mutable_iteration_19():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\town WBuffer[int]* other = buffer_new[int]()\n\tbuffer_push[int](other, 4)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tfor refmut int* nested in buffer_view_mut[int](other): *item += *nested\n\treturn buffer_get[int](values, 0) - 5\n", 0)

void test_mutable_iteration_20():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values): pass\n\treturn *item\n", c"uninitialized")

void test_mutable_iteration_21():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\town WBuffer[int]* moved = values\n\treturn 0\n", c"safe:")

void test_mutable_iteration_22():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WOwnedBuffer[Pair]* values = owned_buffer_new[Pair](-1)\n\towned_buffer_push[Pair](values, new Pair(2, 3))\n\towned_buffer_push[Pair](values, new Pair(5, 7))\n\tfor refmut Pair* item in values: item.x += item.y\n\tref Pair* result = owned_buffer_get[Pair](values, 1)\n\treturn result.x - 12\n", 0)

void test_mutable_iteration_23():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WOwnedBuffer[Pair]* values = owned_buffer_new[Pair](-1)\n\towned_buffer_push[Pair](values, new Pair(2, 3))\n\towned_buffer_push[Pair](values, new Pair(5, 7))\n\tref WOwnedBuffer[Pair]* shared = values\n\tfor refmut Pair* item in shared: item.x = 0\n\treturn 0\n", c"shared reference variable")

void test_mutable_iteration_24():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WOwnedBuffer[Pair]* values = owned_buffer_new[Pair](-1)\n\towned_buffer_push[Pair](values, new Pair(2, 3))\n\towned_buffer_push[Pair](values, new Pair(5, 7))\n\trefmut WOwnedBuffer[Pair]* exclusive = values\n\tfor refmut Pair* item in exclusive: item.x = 0\n\tref Pair* result = owned_buffer_get[Pair](values, 1)\n\treturn result.x\n", 0)

void test_mutable_iteration_25():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WOwnedBuffer[Pair]* values = owned_buffer_new[Pair](-1)\n\towned_buffer_push[Pair](values, new Pair(2, 3))\n\towned_buffer_push[Pair](values, new Pair(5, 7))\n\tfor refmut Pair* item in values: owned_buffer_clear[Pair](values)\n\treturn 0\n", c"borrow")

void test_mutable_iteration_26():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WOwnedBuffer[Pair]* values = owned_buffer_new[Pair](-1)\n\towned_buffer_push[Pair](values, new Pair(2, 3))\n\towned_buffer_push[Pair](values, new Pair(5, 7))\n\toptrefmut Pair* saved = 0\n\tfor refmut Pair* item in values:\n\t\tsaved = item\n\t\tbreak\n\tif saved: saved.x = 42\n\tref Pair* result = owned_buffer_get[Pair](values, 0)\n\treturn result.x - 42\n", 0)

void test_mutable_iteration_27():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nstruct Pair:\n\tint x\n\tint y\nint main():\n\town WOwnedBuffer[Pair]* values = owned_buffer_new[Pair](-1)\n\towned_buffer_push[Pair](values, new Pair(2, 3))\n\towned_buffer_push[Pair](values, new Pair(5, 7))\n\tfor refmut Pair* item in values:\n\t\tref Pair* same = item\n\t\tint amount = same.y\n\t\titem.x += amount\n\tref Pair* result = owned_buffer_get[Pair](values, 1)\n\treturn result.x - 12\n", 0)

void test_mutable_iteration_28():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nrefmut[a] int* first(refmut[a] int[] view):\n\tfor refmut int* item in view: return item\n\treturn &view[0]\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\trefmut int* selected = first(buffer_view_mut[int](values))\n\t*selected += 1\n\treturn buffer_get[int](values, 0) - 2\n", 0)

void test_mutable_iteration_29():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nrefmut[a] int[] counted(refmut[a] WBuffer[int]* values, refmut int* calls):\n\t*calls += 1\n\treturn buffer_view_mut[int](values)\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tint calls = 0\n\tfor refmut int* item in counted(values, &calls): *item += 1\n\treturn calls - 1\n", 0)

void test_mutable_iteration_30():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tdefer: *item += 1\n\t\tif *item == 1: continue\n\t\tbreak\n\treturn buffer_get[int](values, 0) + buffer_get[int](values, 1) - 5\n", 0)

void test_mutable_iteration_31():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nimport tests.safe_mutable_iteration_module as mutable_alias\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\tfor refmut int* item in mutable_alias.tail(buffer_view_mut[int](values)): *item += 5\n\treturn buffer_get[int](values, 2) - 8\n", 0)

void test_mutable_iteration_32():
	mutable_iteration_case(c"import lib.safe_vector\nimport lib.safe_owned_vector\nint main():\n\town WBuffer[int]* values = buffer_new[int]()\n\tfor i in range(3): buffer_push[int](values, i + 1)\n\toptref int* saved = 0\n\tfor refmut int* item in buffer_view_mut[int](values):\n\t\tsaved = item\n\t\tbreak\n\tbuffer_clear[int](values)\n\tif saved: return *saved\n\treturn 0\n", c"borrow")
