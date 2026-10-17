# wbuild: x64
# wbuild: deps=lib/safe_hash.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int generic_hash_case_number


void generic_hash_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_hash_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	generic_hash_case_number = generic_hash_case_number + 1
	char* number = itoa(generic_hash_case_number)
	char* prefix = c"bin/generic_hash_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_hash_case64_"
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
		generic_hash_result(checked, diagnostic, 1, full)
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
		generic_hash_result(compiled, diagnostic, 0, full)
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

void test_generic_hash_0():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\treturn map_length[int, int](values)\n", 0)

void test_generic_hash_1():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\treturn map_get[int, int](values, 1) - 7\n", 0)

void test_generic_hash_2():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\tmap_set[int, int](values, 1, 11)\n\treturn map_length[int, int](values) + map_get[int, int](values, 1) - 12\n", 0)

void test_generic_hash_3():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\treturn map_contains[int, int](values, 1) + map_contains[int, int](values, 2) - 1\n", 0)

void test_generic_hash_4():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\treturn map_get_or[int, int](values, 1, 9) + map_get_or[int, int](values, 2, 9) - 16\n", 0)

void test_generic_hash_5():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\tint removed = map_remove[int, int](values, 1)\n\treturn removed + map_remove[int, int](values, 1) + map_length[int, int](values) - 1\n", 0)

void test_generic_hash_6():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\tmap_clear[int, int](values)\n\tmap_set[int, int](values, 2, 11)\n\treturn map_get[int, int](values, 2) + map_length[int, int](values) - 12\n", 0)

void test_generic_hash_7():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\tif found: return *found - 7\n\treturn 1\n", 0)

void test_generic_hash_8():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\toptref int* absent = map_find[int, int](values, 1)\n\tif absent: return 1\n\treturn 0\n", 0)

void test_generic_hash_9():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\treturn *found\n", c"presence")

void test_generic_hash_10():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\tmap_set[int, int](values, 2, 11)\n\tif found: return *found\n\treturn 0\n", c"borrow")

void test_generic_hash_11():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\tmap_remove[int, int](values, 1)\n\tif found: return *found\n\treturn 0\n", c"borrow")

void test_generic_hash_12():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\tmap_clear[int, int](values)\n\tif found: return *found\n\treturn 0\n", c"borrow")

void test_generic_hash_13():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\tint previous = 0\n\tif found: previous = *found\n\tmap_clear[int, int](values)\n\treturn previous - 7\n", 0)

void test_generic_hash_14():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\tif found: *found = 9\n\treturn 0\n", c"assignment to const")

void test_generic_hash_15():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\treturn values.entries.length\n", c"opaque")

void test_generic_hash_16():
	generic_hash_case(c"import lib.safe_hash\ntype Values = WMap[int, int]\nint main():\n\town Values* values = new Values\n\treturn 0\n", c"opaque")

void test_generic_hash_17():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\town WMap[int, int]* moved = values\n\treturn map_length[int, int](values)\n", c"moved")

void test_generic_hash_18():
	generic_hash_case(c"import lib.safe_hash\nown WBuffer[int]* snapshot():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 3, 7)\n\treturn map_keys[int, int](values)\nint main():\n\town WBuffer[int]* keys = snapshot()\n\treturn buffer_pop[int](keys) - 3\n", 0)

void test_generic_hash_19():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\town WBuffer[int]* entries = map_values[int, int](values)\n\tmap_clear[int, int](values)\n\treturn buffer_pop[int](entries) - 7\n", 0)

void test_generic_hash_20():
	generic_hash_case(c"import lib.safe_hash\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WMap[int, Pair]* values = map_new[int, Pair]()\n\tmap_set[int, Pair](values, 1, Pair(3, 4))\n\tPair value = map_get[int, Pair](values, 1)\n\tPair fallback = map_get_or[int, Pair](values, 2, Pair(5, 6))\n\toptref Pair* view = map_find[int, Pair](values, 1)\n\tif view: return value.left + fallback.right + view.right - 13\n\treturn 1\n", 0)

void test_generic_hash_21():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[byte, byte]* values = map_new[byte, byte]()\n\tmap_set[byte, byte](values, cast(byte, 255), cast(byte, 9))\n\toptref byte* view = map_find[byte, byte](values, cast(byte, 255))\n\tif view: return cast(int, *view) - 9\n\treturn 1\n", 0)

void test_generic_hash_22():
	generic_hash_case(c"import lib.safe_hash\ntype Number = int\nint main():\n\town WMap[Number, Number]* values = map_new[int, int]()\n\tvalues.map_set[Number, Number](1, 7)\n\treturn values.map_get[int, int](1) - 7\n", 0)

void test_generic_hash_23():
	generic_hash_case(c"import lib.safe_hash as hash\nint main():\n\town WMap[int, int]* values = hash.map_new[int, int]()\n\thash.map_set[int, int](values, 1, 7)\n\treturn hash.map_get[int, int](values, 1) - 7\n", 0)

void test_generic_hash_24():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\treturn map_get[int, int](values, 1)\n", 0, 0, -1, 0, c"map key not found")

void test_generic_hash_25():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[char*, int]* values = map_new[char*, int]()\n\treturn 0\n", c"unsupported")

void test_generic_hash_26():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int*]* values = map_new[int, int*]()\n\treturn 0\n", c"unsupported")

void test_generic_hash_27():
	generic_hash_case(c"import lib.safe_hash\nstruct Data:\n\tint[2] values\nint main():\n\town WMap[int, Data]* values = map_new[int, Data]()\n\treturn 0\n", c"array")

void test_generic_hash_28():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[float32, int]* values = map_new[float32, int]()\n\treturn 0\n", c"unsupported")

void test_generic_hash_29():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* values = set_new[int]()\n\tset_add[int](values, 7)\n\tset_add[int](values, 7)\n\treturn set_contains[int](values, 7) + set_length[int](values) - 2\n", 0)

void test_generic_hash_30():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* values = set_new[int]()\n\tset_add[int](values, 7)\n\tint removed = set_remove[int](values, 7)\n\treturn removed + set_remove[int](values, 7) + set_length[int](values) - 1\n", 0)

void test_generic_hash_31():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* values = set_new[int]()\n\tset_add[int](values, 7)\n\town WBuffer[int]* keys = set_values[int](values)\n\tset_clear[int](values)\n\treturn buffer_pop[int](keys) + set_length[int](values) - 7\n", 0)

void test_generic_hash_32():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WSet[char*]* values = set_new[char*]()\n\treturn 0\n", c"unsupported")

void test_generic_hash_33():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* values = set_new[int]()\n\treturn values.entries.length\n", c"opaque")

void test_generic_hash_34():
	generic_hash_case(c"import lib.safe_hash\ntype Values = WSet[int]\nint main():\n\town Values* values = new Values\n\treturn 0\n", c"opaque")

void test_generic_hash_35():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* values = set_new[int]()\n\town WSet[int]* moved = values\n\treturn set_length[int](values)\n", c"moved")

void test_generic_hash_36():
	generic_hash_case(c"import lib.safe_hash\nenum Key:\n\tfirst\n\tsecond\nint main():\n\town WSet[Key]* values = set_new[Key]()\n\tset_add[Key](values, cast(Key, 1))\n\treturn set_contains[Key](values, cast(Key, 1)) - 1\n", 0)

void test_generic_hash_37():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, float32]* values = map_new[int, float32]()\n\tmap_set[int, float32](values, 1, cast(float32, 1.5))\n\treturn map_get[int, float32](values, 1) != cast(float32, 1.5)\n", 0)

void test_generic_hash_38():
	generic_hash_case(c"import lib.safe_hash\noptref int* bad():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\treturn map_find[int, int](values, 1)\nint main():\n\treturn 0\n", c"borrow")

void test_generic_hash_39():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\tmap_set[int, int](values, 1, 7)\n\toptref int* found = map_find[int, int](values, 1)\n\tfor i in range(2): map_set[int, int](values, i, i)\n\tif found: return *found\n\treturn 0\n", c"borrow")

void test_generic_hash_40():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* values = map_new[int, int]()\n\t__w_checked_hash_drop(cast(void*, values))\n\treturn 0\n", c"runtime call has no audited")

void test_generic_hash_41():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[uint, int]* values = map_new[uint, int]()\n\tmap_set[uint, int](values, cast(uint, 4294967295), 7)\n\toptref int* found = map_find[uint, int](values, cast(uint, 4294967295))\n\tif found: return *found - 7\n\treturn 1\n", 0)

void test_generic_hash_42():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[char, int]* values = map_new[char, int]()\n\tmap_set[char, int](values, 'x', 7)\n\toptref int* found = map_find[char, int](values, 'x')\n\tif found: return *found - 7\n\treturn 1\n", 0)

void test_generic_hash_43():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WMap[bool, int]* values = map_new[bool, int]()\n\tmap_set[bool, int](values, true, 7)\n\toptref int* found = map_find[bool, int](values, true)\n\tif found: return *found - 7\n\treturn 1\n", 0)

void test_generic_hash_44():
	generic_hash_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* values = set_new[int]()\n\tset_add[int](values, -1)\n\tset_add[int](values, 0)\n\treturn set_contains[int](values, -1) + set_contains[int](values, 0) - 2\n", 0)

void test_generic_hash_runtime_pin():
	char* root = c"bin/safe_hash_pin32"
	if (__word_size__ == 8): root = c"bin/safe_hash_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/lib")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/safe_hash.w")
	char* source = strjoin(root, c".w")
	char* output = strjoin(root, c".out")
	char* original = file_read_text(c"lib/safe_hash.w")
	assert1(original != 0)
	char* changed = strjoin(original, c"\n# changed implementation cannot inherit checked contracts\n")
	assert1(file_write_text(path, changed))
	assert1(file_write_text(source, c"import lib.safe_hash\nint main():\n\town WMap[int, int]* buffer = map_new[int, int]()\n\treturn map_length[int, int](buffer)\n"))
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
			generic_hash_result(result, c"runtime implementation differs", checking, source)
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
