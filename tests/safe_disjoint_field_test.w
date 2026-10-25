# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int disjoint_field_case_number


void disjoint_field_result(process_result* result, char* diagnostic, int checking, char* path):
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


void disjoint_field_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	disjoint_field_case_number = disjoint_field_case_number + 1
	char* number = itoa(disjoint_field_case_number)
	char* prefix = c"bin/disjoint_field_case32_"
	if (__word_size__ == 8): prefix = c"bin/disjoint_field_case64_"
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
		disjoint_field_result(checked, diagnostic, 1, full)
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
		disjoint_field_result(compiled, diagnostic, 0, full)
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


void test_disjoint_field_0():
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\trefmut int* q = pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\trefmut int* q = pair.first\n\t*p = 7\n\treturn *q\n", c"conflicting")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref Pair* whole = pair\n\trefmut int* p = pair.first\n\t*p = 7\n\treturn whole.tag\n", c"conflicting")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tref Pair* whole = pair\n\t*p = 7\n\treturn whole.tag\n", c"conflicting")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\town Pair* moved = pair\n\treturn *p\n", c"moved")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tpair = new Pair(new int, new int, 4)\n\treturn *p\n", c"conflicting")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tpair.second = new int\n\t*p = 8\n\treturn *p - 8\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tpair.first = new int\n\treturn *p\n", c"conflicting")

void test_disjoint_field_1():
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint change(refmut Pair* pair):\n\trefmut int* p = pair.first\n\trefmut int* q = pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\treturn change(pair) - 15\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut Pair* whole = pair\n\trefmut int* p = whole.first\n\trefmut int* q = whole.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref Pair* whole = pair\n\trefmut int* p = whole.first\n\t*p = 7\n\treturn 0\n", c"shared")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nref[a] int* first(ref[a] Pair* pair):\n\treturn pair.first\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref int* p = first(pair)\n\treturn 0\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nrefmut[a] int* first(refmut[a] Pair* pair):\n\treturn pair.first\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = first(pair)\n\t*p = 9\n\treturn *p - 9\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nref[a] int* bad(own Pair* pair, ref[a] int* external):\n\treturn pair.first\nint main():\n\treturn 0\n", c"must borrow from")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nref[a] int* bad(ref[a] int* external):\n\town Pair* pair = new Pair(new int, new int, 3)\n\treturn pair.first\nint main():\n\treturn 0\n", c"must borrow from")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tfor i in range(3):\n\t\town Pair* inner = new Pair(new int, new int, i)\n\t\trefmut int* p = inner.first\n\t\trefmut int* q = inner.second\n\t\t*p = i\n\t\t*q = i + 1\n\t\tif (*p == 0): continue\n\t\tif (*q == 2): break\n\treturn 0\n", 0)

void test_disjoint_field_2():
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tref int* shared = p\n\trefmut int* q = pair.second\n\t*q = 8\n\treturn *q - 8\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tref int* shared = p\n\trefmut int* q = pair.first\n\t*q = 8\n\treturn *shared\n", c"conflicting")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tif (pair.tag):\n\t\trefmut int* q = pair.second\n\t\t*q = 7\n\t*p = 8\n\treturn *p - 8\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nvoid inspect_value(ref int* p):\n\tint value = *p\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\tdefer inspect_value(p)\n\trefmut int* q = pair.second\n\t*q = 8\n\treturn *q - 8\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nvoid consume(own Pair* pair):\n\treturn\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref int* p = pair.first\n\tconsume(pair)\n\treturn *p\n", c"moved")
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Pair* left\n\town Pair* right\nint main():\n\town Outer* outer = new Outer(new Pair(new int, new int, 1), new Pair(new int, new int, 2))\n\trefmut Pair* left = outer.left\n\trefmut Pair* right = outer.right\n\trefmut int* p = left.first\n\trefmut int* q = right.first\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\ntype Alias = Pair\nint main():\n\town Alias* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.first\n\trefmut int* q = pair.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nrefmut[a] Pair* pass(refmut[a] Pair* pair):\n\treturn pair\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut Pair* whole = pass(pair)\n\trefmut int* p = whole.first\n\trefmut int* q = whole.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)

void test_disjoint_field_3():
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nrefmut[a] Pair* choose(refmut[a] Pair* first, refmut[a] Pair* second, int flag):\n\tif (flag): return first\n\treturn second\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town Pair* other = new Pair(new int, new int, 4)\n\trefmut Pair* whole = choose(pair, other, 1)\n\trefmut int* p = whole.first\n\trefmut int* q = whole.second\n\t*p = 7\n\t*q = 8\n\treturn *p + *q - 15\n", 0)
	disjoint_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* moved = pair.first\n\t*moved = 8\n\treturn *moved - 8\n", 0)
