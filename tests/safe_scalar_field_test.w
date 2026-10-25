# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int scalar_field_case_number


void scalar_field_result(process_result* result, char* diagnostic, int checking, char* path):
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


void scalar_field_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	scalar_field_case_number = scalar_field_case_number + 1
	char* number = itoa(scalar_field_case_number)
	char* prefix = c"bin/scalar_field_case32_"
	if (__word_size__ == 8): prefix = c"bin/scalar_field_case64_"
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
		scalar_field_result(checked, diagnostic, 1, full)
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
		scalar_field_result(compiled, diagnostic, 0, full)
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


void test_scalar_field_0():
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\trefmut int* p = &pair.first\n\trefmut int* q = &pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\trefmut int* p = &pair.first\n\tpair.second = 9\n\t*p = 7\n\treturn *p + pair.second - 16\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\trefmut int* p = &pair.first\n\tint other = pair.second\n\t*p = 7\n\treturn *p + other - 11\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\tref int* p = &pair.first\n\tpair.first = 9\n\treturn *p\n", c"conflicting")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\trefmut int* p = &pair.first\n\trefmut int* q = &pair.first\n\t*p = 7\n\treturn *q\n", c"conflicting")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\trefmut int* p = &pair.first\n\tref Pair* whole = pair\n\t*p = 7\n\treturn whole.second\n", c"conflicting")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\tref Pair* whole = pair\n\trefmut int* p = &whole.first\n\t*p = 7\n\treturn 0\n", c"shared")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\tref int* p = &pair.first\n\tpair = new Pair(5, 6)\n\treturn *p\n", c"conflicting")

void test_scalar_field_1():
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\tref int* p = &pair.first\n\town Pair* moved = pair\n\treturn *p\n", c"moved")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint change(refmut Pair* pair):\n\trefmut int* p = &pair.first\n\trefmut int* q = &pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q\nint main():\n\town Pair* pair = new Pair(3, 4)\n\treturn change(pair) - 15\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nref[a] int* first(ref[a] Pair* pair):\n\treturn &pair.first\nint main():\n\town Pair* pair = new Pair(3, 4)\n\tref int* p = first(pair)\n\treturn *p - 3\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nref[a] int* bad(own Pair* pair, ref[a] int* input):\n\treturn &pair.first\nint main():\n\treturn 0\n", c"must borrow from")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\tPair pair = Pair(3, 4)\n\trefmut int* p = &pair.first\n\trefmut int* q = &pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nstruct Outer:\n\tPair pair\n\town int* value\nint main():\n\town Outer* outer = new Outer(Pair(3, 4), new int)\n\trefmut int* p = &outer.pair.first\n\trefmut int* q = &outer.pair.second\n\trefmut int* r = outer.value\n\t*p = 7\n\t*q = 8\n\t*r = 9\n\treturn *p + *q + *r - 24\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nstruct Outer:\n\town Pair* pair\n\tint tag\nint main():\n\town Outer* outer = new Outer(new Pair(3, 4), 5)\n\town Pair* pair = outer.pair\n\trefmut int* tag = &outer.tag\n\t*tag = 7\n\treturn pair.first + *tag - 10\n", 0)
	scalar_field_case(c"struct Arrays:\n\tint[2] first\n\tint[2] second\nint main():\n\town Arrays* arrays = new Arrays\n\trefmut int* p = &arrays.first[0]\n\trefmut int* q = &arrays.second[0]\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)

void test_scalar_field_2():
	scalar_field_case(c"struct Arrays:\n\tint[2] first\n\tint[2] second\nint main():\n\town Arrays* arrays = new Arrays\n\trefmut int* p = &arrays.first[0]\n\trefmut int* q = &arrays.first[1]\n\t*p = 7\n\treturn *q\n", c"conflicting")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\ntype Alias = Pair\nint main():\n\town Alias* pair = new Pair(3, 4)\n\trefmut int* p = &pair.first\n\trefmut int* q = &pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\town Pair* pair = new Pair(3, 4)\n\tfor i in range(3):\n\t\trefmut int* p = &pair.first\n\t\trefmut int* q = &pair.second\n\t\t*p = i\n\t\t*q = i + 1\n\treturn pair.first + pair.second - 5\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nrefmut[a] Pair* choose(refmut[a] Pair* a, refmut[a] Pair* b, int flag):\n\tif (flag): return a\n\treturn b\nint main():\n\town Pair* pair = new Pair(3, 4)\n\town Pair* other = new Pair(5, 6)\n\trefmut Pair* chosen = choose(pair, other, 1)\n\trefmut int* p = &chosen.first\n\trefmut int* q = &chosen.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nref[a] int* first(ref[a] Pair* pair):\n\treturn &pair.first\nint main():\n\town Pair* pair = new Pair(3, 4)\n\tref int* p = first(pair)\n\tpair.second = 9\n\treturn *p\n", c"conflicting")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nref[a] int* bad(ref[a] int* external):\n\tPair pair = Pair(3, 4)\n\treturn &pair.first\nint main():\n\treturn 0\n", c"must borrow from")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nPair make(int value):\n\treturn Pair(value, value + 1)\nint main():\n\tPair pair = make(3)\n\trefmut int* p = &pair.first\n\trefmut int* q = &pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint tick(refmut int* count):\n\t*count += 1\n\treturn *count\nint main():\n\tint count = 0\n\tPair pair = Pair(second: tick(&count), first: tick(&count))\n\treturn pair.first * 10 + pair.second - 21\n", 0)

void test_scalar_field_3():
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\tPair pair = Pair(3)\n\treturn 0\n", c"constructor")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nstruct Other:\n\tint first\n\tint second\nint main():\n\tPair pair = Other(3, 4)\n\tref int* checked = &pair.first\n\treturn 0\n", c"type")
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nint main():\n\tPair pair = Pair(first: 3, first: 4)\n\tref int* checked = &pair.first\n\treturn 0\n", c"initialized twice")

void test_scalar_field_relaxed_nominal():
	scalar_field_case(c"struct Pair:\n\tint first\n\tint second\nstruct Other:\n\tint first\n\tint second\nint main():\n\tPair pair = Other(3, 4)\n\tref int* checked = &pair.first\n\treturn 0\n", c"incompatible plain aggregate", 1)
