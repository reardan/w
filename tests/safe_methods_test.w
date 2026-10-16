# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int methods_case_number


void methods_result(process_result* result, char* diagnostic, int checking, char* path):
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


void methods_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	methods_case_number = methods_case_number + 1
	char* number = itoa(methods_case_number)
	char* prefix = c"bin/methods_case32_"
	if (__word_size__ == 8): prefix = c"bin/methods_case64_"
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
		methods_result(checked, diagnostic, 1, full)
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
		methods_result(compiled, diagnostic, 0, full)
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


void test_checked_methods():
	# record ref method
	methods_case(c"struct Point:\n\tint x\nint Point_value(ref Point* self):\n\treturn self.x\nint main():\n\town Point* p = new Point(7)\n\treturn p.value() - 7\n", 0)
	# record mutable method
	methods_case(c"struct Point:\n\tint x\nvoid Point_set(refmut Point* self, int n):\n\tself.x = n\nint main():\n\town Point* p = new Point(7)\n\tp.set(4)\n\treturn p.x - 4\n", 0)
	# owner receiver
	methods_case(c"struct Point:\n\tint x\nint Point_take(own Point* self):\n\treturn self.x\nint main():\n\town Point* p = new Point(7)\n\treturn p.take() - 7\n", 0)
	# owner receiver moved
	methods_case(c"struct Point:\n\tint x\nint Point_take(own Point* self):\n\treturn self.x\nint main():\n\town Point* p = new Point(7)\n\tint old = p.take()\n\treturn p.x\n", c"moved value")
	# ref result
	methods_case(c"struct Point:\n\tint x\nref int* Point_view(ref Point* self):\n\treturn &self.x\nint main():\n\town Point* p = new Point(7)\n\tref int* r = p.view()\n\treturn *r - 7\n", 0)
	# ref result conflict
	methods_case(c"struct Point:\n\tint x\nref int* Point_view(ref Point* self):\n\treturn &self.x\nint main():\n\town Point* p = new Point(7)\n\tref int* r = p.view()\n\tp = new Point(4)\n\treturn *r\n", c"conflicting")
	# receiver argument conflict
	methods_case(c"struct Point:\n\tint x\nint Point_sum(ref Point* self, int n):\n\treturn self.x + n\nint change(refmut Point* p):\n\tp.x = 4\n\treturn 0\nint main():\n\town Point* p = new Point(7)\n\treturn p.sum(change(p))\n", c"conflicting")
	# shared receiver write
	methods_case(c"struct Point:\n\tint x\nvoid Point_set(refmut Point* self, int n):\n\tself.x = n\nint main():\n\town Point* p = new Point(7)\n\tref Point* r = p\n\tr.set(4)\n\treturn 0\n", c"mutable borrow from a shared")
	# UFCS ref receiver
	methods_case(c"int value(ref int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\t*p = 7\n\treturn p.value() - 7\n", 0)


void test_checked_value_receiver():
	methods_case(c"struct Point:\n\tint x\nint Point_value(ref Point* self):\n\treturn self.x\nint inspect(Point p):\n\treturn p.value()\nint main():\n\town Point* p = new Point(7)\n\treturn inspect(*p) - 7\n", 0)
