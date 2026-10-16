# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int control_flow_case_number


void control_flow_result(process_result* result, char* diagnostic, int checking, char* path):
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


void control_flow_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	control_flow_case_number = control_flow_case_number + 1
	char* number = itoa(control_flow_case_number)
	char* prefix = c"bin/control_flow_case32_"
	if (__word_size__ == 8): prefix = c"bin/control_flow_case64_"
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
		strv_set(checking, 3, c"--quiet")
		strv_set(checking, 4, c"--strict")
		if (relaxed): strv_set(checking, 4, c"--quiet")
		strv_set(checking, 5, c"--quiet")
		if (__word_size__ == 8): strv_set(checking, 5, c"x64")
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		control_flow_result(checked, diagnostic, 1, full)
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
		control_flow_result(compiled, diagnostic, 0, full)
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


void test_checked_control_flow():
	# range basic
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint total = 0\n\tfor i in range(4):\n\t\ttotal += i\n\treturn total - 6\n", 0)
	# range step
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint total = 0\n\tfor i in range(2, 9, 2):\n\t\ttotal += i\n\treturn total - 20\n", 0)
	# range header
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint bump(refmut int* x):\n\t*x += 1\n\treturn *x\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint n = 0\n\tint total = 0\n\tfor i in range(bump(&n), bump(&n), bump(&n)):\n\t\ttotal += i\n\treturn n + total - 4\n", 0)
	# range exits
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint total = 0\n\tfor i in range(8):\n\t\town int* owner = new int\n\t\tif i == 2: continue\n\t\tif i == 5: break\n\t\t*owner = i\n\t\ttotal += *owner\n\treturn total - 8\n", 0)
	# switch
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint n = 0\n\tfor i in range(4):\n\t\tswitch i:\n\t\t\tcase 0, 1: n += 1\n\t\t\tcase 2:\n\t\t\t\tn += 5\n\t\t\t\tbreak\n\t\t\tdefault: continue\n\t\tn += 1\n\treturn n - 10\n", 0)
	# switch returns
	control_flow_case(c"void checked(ref int* p):\n\tpass\nown int* pick(int n):\n\tswitch n:\n\t\tcase 0, 2: return new int\n\t\tdefault: return new int\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\town int* p = pick(2)\n\treturn *p\n", 0)
	# switch labels
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint bump(refmut int* x):\n\t*x += 1\n\treturn *x\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint n = 0\n\tint result = 0\n\tswitch 2:\n\t\tcase bump(&n), bump(&n), bump(&n): result = 7\n\t\tdefault: result = 11\n\treturn n + result - 9\n", 0)
	# implicit index write
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tfor i in range(2):\n\t\tref int* p = &i\n\t\tint n = *p\n\treturn 0\n", 0)
	# non-int range
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tfor char i in range(2):\n\t\tpass\n\treturn 0\n", c"range variable must")
	# empty switch
	control_flow_case(c"void checked(ref int* p):\n\tpass\nint main():\n\tint anchor = 0\n\tref int* checked_anchor = &anchor\n\tint x = 4\n\tswitch x:\n\treturn x - 4\n", 0)
