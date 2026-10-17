# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int partial_move_case_number


void partial_move_result(process_result* result, char* diagnostic, int checking, char* path):
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


void partial_move_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	partial_move_case_number = partial_move_case_number + 1
	char* number = itoa(partial_move_case_number)
	char* prefix = c"bin/partial_move_case32_"
	if (__word_size__ == 8): prefix = c"bin/partial_move_case64_"
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
		partial_move_result(checked, diagnostic, 1, full)
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
		partial_move_result(compiled, diagnostic, 0, full)
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




void test_partial_move_0():
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\t*first = 7\n\trefmut int* second = pair.second\n\t*second = 8\n\treturn *first + *second - 15\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\town int* second = pair.second\n\t*first = 7\n\t*second = 8\n\treturn *first + *second - 15\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\town int* again = pair.first\n\treturn 0\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\tref int* p = pair.first\n\treturn *p\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\town Pair* moved = pair\n\treturn 0\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\tref Pair* whole = pair\n\treturn whole.tag\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\tpair.first = new int\n\town Pair* moved = pair\n\treturn moved.tag - 3\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\tpair = new Pair(new int, new int, 4)\n\treturn pair.tag - 4\n", 0)

void test_partial_move_1():
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref int* p = pair.first\n\town int* first = pair.first\n\treturn *p\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\trefmut int* p = pair.second\n\town int* first = pair.first\n\t*first = 7\n\t*p = 8\n\treturn *first + *p - 15\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref Pair* whole = pair\n\town int* first = pair.first\n\treturn whole.tag\n", c"conflicting")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* take(own Pair* pair):\n\treturn pair.first\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = take(pair)\n\t*first = 8\n\treturn *first - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* bad(refmut Pair* pair):\n\treturn pair.first\nint main():\n\treturn 0\n", c"unique owner")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* bad(ref Pair* pair):\n\treturn pair.first\nint main():\n\treturn 0\n", c"unique owner")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tif (pair.tag):\n\t\town int* first = pair.first\n\tref int* p = pair.first\n\treturn *p\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tif (pair.tag):\n\t\town int* first = pair.first\n\tpair.first = new int\n\trefmut int* p = pair.first\n\t*p = 8\n\treturn *p - 8\n", 0)

void test_partial_move_2():
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tfor i in range(3):\n\t\town int* first = pair.first\n\treturn 0\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tfor i in range(3):\n\t\town int* first = pair.first\n\t\t*first = i\n\t\tpair.first = first\n\tref int* p = pair.first\n\treturn *p - 2\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = pair.first\n\trefmut int* p = pair.first\n\t*p = 8\n\treturn *p - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = pair.second\n\trefmut int* p = pair.first\n\t*p = 8\n\treturn *p - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = pair.second\n\tref int* p = pair.second\n\treturn *p\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint sum(own int* first, own int* second):\n\t*first = 7\n\t*second = 8\n\treturn *first + *second\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\treturn sum(pair.first, pair.second) - 15\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint sum(own int* first, own int* second):\n\treturn 0\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\treturn sum(pair.first, pair.first)\n", c"conflicting")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint bad(own int* first, own Pair* pair):\n\treturn 0\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\treturn bad(pair.first, pair)\n", c"conflicting")

void test_partial_move_3():
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town Pair* moved = new Pair(pair.first, pair.second, 4)\n\treturn moved.tag - 4\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Pair* child\nint main():\n\town Outer* outer = new Outer(new Pair(new int, new int, 4))\n\town Pair* child = outer.child\n\town int* first = child.first\n\t*first = 8\n\treturn *first - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Pair* child\nint main():\n\town Outer* outer = new Outer(new Pair(new int, new int, 4))\n\town int* first = outer.child.first\n\t*first = 8\n\treturn *first - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown T* identity[T](own T* item):\n\treturn item\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = identity[int](pair.first)\n\t*first = 8\n\treturn *first - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* identity(own int* item):\n\treturn item\ntype Identity = fn[](own int*) -> own int*\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tIdentity* call = identity\n\town int* first = call(pair.first)\n\t*first = 8\n\treturn *first - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nvoid inspect(ref int* item):\n\tint value = *item\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref int* p = pair.first\n\tdefer inspect(p)\n\town int* first = pair.first\n\treturn 0\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nvoid inspect(ref int* item):\n\tint value = *item\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref int* p = pair.second\n\tdefer inspect(p)\n\town int* first = pair.first\n\treturn 0\n", 0)
	partial_move_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Child(new int, &x), 7)\n\town[a] Child* child = outer.child\n\tref int* p = child.data\n\treturn *p - 3\n", 0)

void test_partial_move_4():
	partial_move_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Child(new int, &x), 7)\n\town[a] Child* child = outer.child\n\tref int* p = outer.child.data\n\treturn *p\n", c"moved")
	partial_move_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* extract(own[a] Outer* outer):\n\treturn outer.child\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Child(new int, &x), 7)\n\town[a] Child* child = extract(outer)\n\tref int* p = child.data\n\treturn *p - 3\n", 0)
	partial_move_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Child(new int, &x), 7)\n\town[a] Child* child = outer.child\n\trefmut int* p = child.data\n\t*p = 8\n\treturn x - 8\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\treturn pair.tag - 3\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown Pair* bad(own Pair* pair):\n\town int* first = pair.first\n\treturn pair\nint main():\n\treturn 0\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\tif (pair.tag): pair.first = new int\n\town Pair* whole = pair\n\treturn whole.tag\n", c"moved")
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* first = pair.first\n\tif (pair.tag): pair.first = new int\n\telse: pair.first = first\n\town Pair* whole = pair\n\treturn whole.tag - 3\n", 0)
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* consume(own Pair* pair):\n\treturn pair.first\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = consume(pair)\n\treturn 0\n", c"conflicting")

void test_partial_move_5():
	partial_move_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* pass(own int* value):\n\treturn value\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = pass(pair.first)\n\trefmut int* p = pair.first\n\t*p = 9\n\treturn *p - 9\n", 0)
	partial_move_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nstruct Deep:\n\town[group] Outer* outer\nint main():\n\tint x = 3\n\town[a] Deep* deep = new Deep(new Outer(new Child(new int, &x), 7))\n\tref int* p = deep.outer.child.data\n\treturn *p - 3\n", 0)
	partial_move_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nstruct Deep:\n\town[group] Outer* outer\nint main():\n\tint x = 3\n\town[a] Deep* deep = new Deep(new Outer(new Child(new int, &x), 7))\n\town[a] Outer* moved = deep.outer\n\tref int* p = deep.outer.child.data\n\treturn *p\n", c"moved")
