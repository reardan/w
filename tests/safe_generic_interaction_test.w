# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int generic_interaction_case_number


void generic_interaction_result(process_result* result, char* diagnostic, int checking, char* path):
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


void generic_interaction_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	generic_interaction_case_number = generic_interaction_case_number + 1
	char* number = itoa(generic_interaction_case_number)
	char* prefix = c"bin/generic_interaction_case32_"
	if (__word_size__ == 8): prefix = c"bin/generic_interaction_case64_"
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
		unlink(output)
		char** checking = strv_new(7 + mode)
		strv_set(checking, 0, c"bin/wv2")
		strv_set(checking, 1, c"check")
		strv_set(checking, 2, c"--json")
		strv_set(checking, 3, c"--ast-required")
		strv_set(checking, 4, c"--strict")
		if (relaxed): strv_set(checking, 4, c"--quiet")
		strv_set(checking, 5, c"--quiet")
		if (__word_size__ == 8): strv_set(checking, 5, c"x64")
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		generic_interaction_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--quiet")
		strv_set(compiling, 2, c"--strict")
		if (relaxed): strv_set(compiling, 2, c"--quiet")
		strv_set(compiling, 3, c"--quiet")
		if (__word_size__ == 8): strv_set(compiling, 3, c"x64")
		strv_set(compiling, 4, c"--ast-required")
		strv_set(compiling, 5, full)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		process_result* compiled = process_run(compiling[0], compiling, 0, 0, 30000)
		generic_interaction_result(compiled, diagnostic, 0, full)
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


void test_checked_generic_interactions():
	# owner_alias
	generic_interaction_case(c"T identity[T](T p):\n\treturn p\ntype Owner = own int*\nint main():\n\tOwner p = new int\n\t*p = 7\n\tOwner q = identity[Owner](p)\n\treturn *q - 7\n", 0)
	# owner_two
	generic_interaction_case(c"int sum[T](own T* p, own T* q):\n\treturn *p + *q\nint main():\n\town int* p = new int\n\t*p = 3\n\town int* q = new int\n\t*q = 4\n\treturn sum[int](p, q) - 7\n", 0)
	# owner_twice
	generic_interaction_case(c"int sum[T](own T* p, own T* q):\n\treturn *p + *q\nint main():\n\town int* p = new int\n\treturn sum[int](p, p)\n", c"safe:")
	# moved_later_argument
	generic_interaction_case(c"int take[T](own T* p, int n):\n\treturn n\nint main():\n\town int* p = new int\n\treturn take[int](p, *p)\n", c"safe:")
	# mutable_later_argument
	generic_interaction_case(c"int take[T](refmut T* p, int n):\n\treturn n\nint main():\n\tint x = 0\n\treturn take[int](&x, x)\n", c"safe:")
	# nested_owner
	generic_interaction_case(c"T identity[T](T p):\n\treturn p\nint take[T](own T* p):\n\treturn *p\nint main():\n\treturn take[int](identity[own int*](new int))\n", 0)
	# optional_present
	generic_interaction_case(c"optref[a] T* maybe[T](ref[a] T* p, int yes):\n\tif yes: return p\n\treturn 0\nint main():\n\tint x = 7\n\toptref int* r = maybe[int](&x, 1)\n\tif r: return *r - 7\n\treturn 1\n", 0)
	# optional_absent
	generic_interaction_case(c"optref[a] T* maybe[T](ref[a] T* p, int yes):\n\tif yes: return p\n\treturn 0\nint main():\n\tint x = 7\n\toptref int* r = maybe[int](&x, 0)\n\tif r: return 1\n\treturn 0\n", 0)
	# optional_missing_check
	generic_interaction_case(c"optref[a] T* maybe[T](ref[a] T* p, int yes):\n\tif yes: return p\n\treturn 0\nint main():\n\tint x = 7\n\toptref int* r = maybe[int](&x, 0)\n\treturn *r\n", c"safe:")
	# optional_mutation
	generic_interaction_case(c"optref[a] T* maybe[T](ref[a] T* p, int yes):\n\tif yes: return p\n\treturn 0\nint main():\n\tint x = 7\n\toptref int* r = maybe[int](&x, 1)\n\tx = 3\n\tif r: return *r\n\treturn 0\n", c"safe:")
	# recursive_ref
	generic_interaction_case(c"ref[a] T* view[T](ref[a] T* p, int n):\n\tif n: return view[T](p, n - 1)\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = view[int](&x, 3)\n\treturn *r - 7\n", 0)
	# distinct_groups
	generic_interaction_case(c"ref[a] T* first[T](ref[a] T* p, ref[b] T* q):\n\treturn p\nint main():\n\tint x = 7\n\tint y = 3\n\tref int* r = first[int](&x, &y)\n\ty = 4\n\treturn *r - 7\n", 0)
