# wbuild: x64
# wbuild: deps=tests/safe_generic_record_import_fixture.w
# Generic record applications in checked code (#696): 'new Name[T](...)',
# 'Name[T](...)' values and inference through borrowed generic records keep
# the instance's qualifiers, layout, lifetime groups and owner transfers.
# Every contract is checked and compiled with and without --safe; rejections
# must leave no executable.
import lib.testing
import lib.process
import lib.file


int generic_record_case_number


void generic_record_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_record_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	generic_record_case_number = generic_record_case_number + 1
	char* number = itoa(generic_record_case_number)
	char* prefix = c"bin/generic_record_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_record_case64_"
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
		generic_record_result(checked, diagnostic, 1, full)
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
		generic_record_result(compiled, diagnostic, 0, full)
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


void test_generic_record_0():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town int* value = new int\n\t*value = 7\n\town Box[int]* box = new Box[int](value, 1)\n\tref int* result = box.value\n\treturn *result + box.tag - 8\n", 0)


void test_generic_record_1():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nown Box[T]* wrap[T](own T* value, int tag):\n\treturn new Box[T](value, tag)\n\nint main():\n\town int* value = new int\n\t*value = 4\n\town Box[int]* box = wrap[int](value, 3)\n\tref int* result = box.value\n\treturn *result + box.tag - 7\n", 0)


void test_generic_record_2():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nown Box[T]* wrap[T](own T* value):\n\treturn new Box[T](value, 0)\n\nint peek[T](ref Box[T]* box):\n\tref T* value = box.value\n\treturn *value\n\nint main():\n\town int* value = new int\n\t*value = 5\n\town Box[int]* box = wrap(value)\n\treturn peek(box) + peek[int](box) - 10\n", 0)


void test_generic_record_3():
	generic_record_case(c"struct View[T]:\n\tref[a] T* item\n\tint extra\n\nint main():\n\tint n = 3\n\tref View[int] view = View[int](&n, 4)\n\tref int* item = view.item\n\treturn *item + view.extra - 7\n", 0)


void test_generic_record_4():
	generic_record_case(c"struct View[T]:\n\tref[a] T* item\n\tint extra\n\nref[x] T* item_of[T](ref[x] View[T] view):\n\treturn view.item\n\nint main():\n\tint n = 3\n\tref View[int] view = View[int](&n, 0)\n\tref int* a = item_of(view)\n\tref int* b = item_of[int](view)\n\treturn *a + *b - 6\n", 0)


void test_generic_record_5():
	generic_record_case(c"struct Pair[A, B]:\n\tA first\n\tB second\n\nint main():\n\town Pair[int, char]* pair = new Pair[int, char]\n\tpair.first = 5\n\tpair.second = 'a'\n\town Pair[int, char]* built = new Pair[int, char](2, 'b')\n\treturn pair.first + built.first + built.second - pair.second - 8\n", 0)


void test_generic_record_6():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint consume[T](own Box[T]* box):\n\treturn box.tag\n\nint main():\n\town char* letter = new char\n\treturn consume(new Box[char](letter, 9)) - 9\n", 0)


void test_generic_record_7():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town int* first = new int\n\t*first = 1\n\town Box[int]* box = new Box[int](first, 0)\n\town int* second = new int\n\t*second = 6\n\tbox = new Box[int](second, 0)\n\tref int* result = box.value\n\treturn *result - 6\n", 0)


void test_generic_record_8():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint get[T](ref Box[T]* self):\n\tref T* value = self.value\n\treturn *value\n\nint main():\n\town int* value = new int\n\t*value = 4\n\town Box[int]* box = new Box[int](value, 0)\n\treturn box.get() + box.get[int]() - 8\n", 0)


void test_generic_record_9():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint depth(ref Box[Box[int]]* outer):\n\tref Box[int]* inner = outer.value\n\tref int* value = inner.value\n\treturn *value\n\nint main():\n\town int* value = new int\n\t*value = 5\n\town Box[Box[int]]* nested = new Box[Box[int]](new Box[int](value, 1), 2)\n\treturn depth(nested) - 5\n", 0)


void test_generic_record_10():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\ntype IntBox = Box[int]\n\nint main():\n\town int* value = new int\n\t*value = 2\n\town IntBox* box = new IntBox(value, 1)\n\tref int* result = box.value\n\treturn *result + box.tag - 3\n", 0)


void test_generic_record_11():
	generic_record_case(c"struct View[T]:\n\tref[a] T* item\n\tint extra\n\nref[x] View[int] view_of(ref[x] int* item):\n\treturn View[int](item, 1)\n\nint main():\n\tint n = 6\n\tref View[int] view = view_of(&n)\n\tref int* result = view.item\n\treturn *result + view.extra - 7\n", 0)


void test_generic_record_12():
	generic_record_case(c"import tests.safe_generic_record_import_fixture\n\nint main():\n\town int* value = new int\n\t*value = 3\n\town Shared[int]* shared = shared_of(value, 2)\n\town int* other = new int\n\t*other = 1\n\town Shared[int]* direct = new Shared[int](other, 0)\n\treturn shared_read(shared) + shared_read[int](direct) - 6\n", 0)


void test_generic_record_13():
	generic_record_case(c"import tests.safe_generic_record_import_fixture\n\nint main():\n\tint n = 8\n\tref Lens[int] lens = Lens[int](&n)\n\tref int* item = lens.item\n\treturn *item - 8\n", 0)


void test_generic_record_14():
	generic_record_case(c"struct Pair[A, B]:\n\tA first\n\tB second\n\nint main():\n\tPair[int, int][3] many\n\tmany[1].second = 4\n\tPair[int, int] pair = Pair[int, int](1, 2)\n\treturn many[1].second + pair.first + pair.second - 7\n", 0)


void test_generic_record_15():
	generic_record_case(c"struct View[T]:\n\tref[a] T* item\n\tint extra\n\nint read[T](refmut View[T] view):\n\treturn view.extra\n\nint main():\n\tint n = 1\n\trefmut View[int] view = View[int](&n, 2)\n\treturn read(view) - 2\n", 0)


void test_generic_record_16():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town int* value = new int\n\town Box[int]* box = new Box[int](value, 1)\n\treturn *value\n", c"moved")


void test_generic_record_17():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town Box[int]* box = new Box[int]\n\treturn 0\n", c"pointer-free sized value")


void test_generic_record_18():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town int* value = new int\n\town Box[int]* box = new Box[int](value)\n\treturn 0\n", c"arguments")


void test_generic_record_19():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town char* value = new char\n\town Box[int]* box = new Box[int](value, 0)\n\treturn 0\n", c"mismatch")


void test_generic_record_20():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town int* value = new int\n\town Box[int]* box = new Box[int, int](value, 0)\n\treturn 0\n", c"type arguments")


void test_generic_record_21():
	generic_record_case(c"struct View[T]:\n\tref[a] T* item\n\tint extra\n\nref[x] View[int] escape():\n\tint n = 3\n\treturn View[int](&n, 0)\n\nint main():\n\treturn 0\n", c"returned lifetime")


void test_generic_record_22():
	generic_record_case(c"struct View[T]:\n\tref[a] T* item\n\tint extra\n\nint main():\n\town int* owner = new int\n\tref View[int] view = View[int](owner, 0)\n\town int* moved = owner\n\tref int* item = view.item\n\treturn *item\n", c"moved")


void test_generic_record_23():
	generic_record_case(c"struct Exclusive[T]:\n\trefmut[a] T* item\n\nint main():\n\tint n = 1\n\trefmut Exclusive[int] first = Exclusive[int](&n)\n\trefmut Exclusive[int] second = Exclusive[int](&n)\n\trefmut int* item = first.item\n\t*item = 2\n\treturn n\n", c"conflicting access")


void test_generic_record_24():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint main():\n\town int* value = new int\n\town Box[int]* box = new Box[int](value, 0)\n\town Box[int]* moved = box\n\tref int* result = box.value\n\treturn *result\n", c"moved")


void test_generic_record_25():
	generic_record_case(c"struct Box[T]:\n\town T* value\n\tint tag\n\nint peek[T](ref Box[T]* box):\n\tref T* value = box.value\n\treturn *value\n\nint main():\n\town char* value = new char\n\town Box[char]* box = new Box[char](value, 0)\n\treturn peek[int](box)\n", c"mismatch")


void test_generic_record_26():
	generic_record_case(c"import tests.safe_generic_record_import_fixture\n\nint main():\n\town int* value = new int\n\town Shared[int]* shared = shared_of(value, 0)\n\tfree(cast(void*, shared))\n\treturn 0\n", c"safe:")
