# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int owned_field_case_number


void owned_field_result(process_result* result, char* diagnostic, int checking, char* path):
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


void owned_field_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	owned_field_case_number = owned_field_case_number + 1
	char* number = itoa(owned_field_case_number)
	char* prefix = c"bin/owned_field_case32_"
	if (__word_size__ == 8): prefix = c"bin/owned_field_case64_"
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
		owned_field_result(checked, diagnostic, 1, full)
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
		owned_field_result(compiled, diagnostic, 0, full)
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



void test_owned_field_0():
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* value = new int\n\t*value = 9\n\tpair.first = value\n\tref int* p = pair.first\n\treturn *p - 9\n", 0)
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = new int\n\trefmut int* p = pair.first\n\t*p = 7\n\treturn *p - 7\n", 0)
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* make_value(int value):\n\town int* result = new int\n\t*result = value\n\treturn result\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tfor i in range(4): pair.first = make_value(i)\n\tref int* p = pair.first\n\treturn *p - 3\n", 0)
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref int* old = pair.first\n\tpair.first = new int\n\treturn *old\n", c"conflicting")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tref int* sibling = pair.second\n\tpair.first = new int\n\treturn *sibling\n", c"conflicting")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* consume(own Pair* pair):\n\treturn new int\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = consume(pair)\n\treturn 0\n", c"conflicting")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nvoid bad(refmut Pair* pair):\n\tpair.first = new int\nint main():\n\treturn 0\n", c"named unique owner")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nvoid bad(ref Pair* pair):\n\tpair.first = new int\nint main():\n\treturn 0\n", c"named unique owner")

void test_owned_field_1():
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* value = new int\n\tpair.first = value\n\treturn *value\n", c"moved")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\town int* value = pair.first\n\treturn 0\n", c"safe:")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = 0\n\treturn 0\n", c"safe:")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown Pair* change(own Pair* pair):\n\tpair.first = new int\n\trefmut int* p = pair.first\n\t*p = 8\n\treturn pair\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair = change(pair)\n\tref int* p = pair.first\n\treturn *p - 8\n", 0)
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown int* make_value(int value):\n\town int* result = new int\n\t*result = value\n\treturn result\ntype Make = fn[](int) -> own int*\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tMake* make = make_value\n\tpair.first = make(9)\n\tref int* p = pair.first\n\treturn *p - 9\n", 0)
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nown T* pass_value[T](own T* value):\n\treturn value\nint main():\n\town Pair* pair = new Pair(new int, new int, 3)\n\tpair.first = pass_value[int](new int)\n\trefmut int* p = pair.first\n\t*p = 5\n\treturn *p - 5\n", 0)
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\touter.child = make_child(&y)\n\tref int* p = outer.child.data\n\treturn *p - 4\n", 0)
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\touter.child = make_child(&y)\n\tx = 9\n\tref int* p = outer.child.data\n\treturn *p\n", c"conflicting")

void test_owned_field_2():
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nown[a] Outer* bad(own[a] Outer* outer, ref[b] int* data):\n\touter.child = make_child(data)\n\treturn outer\nint main():\n\treturn 0\n", c"must borrow from")
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nown[a] Outer* change(own[a] Outer* outer, ref[b] int* data) where b > a:\n\touter.child = make_child(data)\n\treturn outer\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\touter = change(outer, &y)\n\tref int* p = outer.child.data\n\treturn *p - 4\n", 0)
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\touter.child = make_child(&outer.tag)\n\treturn 0\n", c"containing owner")
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nown[a] Outer* bad(own[a] Outer* outer):\n\tint local = 8\n\touter.child = make_child(&local)\n\treturn outer\nint main():\n\treturn 0\n", c"must borrow from")
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\tif (1):\n\t\tint local = 8\n\t\touter.child = make_child(&local)\n\tref int* p = outer.child.data\n\treturn *p\n", c"moved")
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\touter.child = make_child(&y)\n\trefmut int* p = outer.child.data\n\t*p = 9\n\treturn y - 9\n", 0)
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\touter.child = make_child(&y)\n\tint old = x\n\trefmut int* p = outer.child.data\n\treturn old + *p\n", c"conflicting")
	owned_field_case(c"struct Pair:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Pair* child\nint main():\n\town Outer* outer = new Outer(new Pair(new int, new int, 3))\n\touter.child.first = new int\n\treturn 0\n", c"safe:")

void test_owned_field_3():
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[left] Child* child\n\tref[right] int* other\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\town[a,b] Outer* outer = new Outer(make_child(&x), &z)\n\touter.child = make_child(&y)\n\tint shared = z\n\trefmut int* p = outer.child.data\n\t*p = 9\n\treturn y + shared - 14\n", 0)
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[left] Child* child\n\tref[right] int* other\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\town[a,b] Outer* outer = new Outer(make_child(&x), &z)\n\touter.child = make_child(&z)\n\trefmut int* p = outer.child.data\n\treturn *p\n", c"conflicting")
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[group] Child* child\n\town[group] Child* sibling\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\town[a] Outer* outer = new Outer(make_child(&x), make_child(&z))\n\touter.child = make_child(&y)\n\trefmut int* p = outer.sibling.data\n\treturn *p\n", c"conflicting")
	owned_field_case(c"struct Child:\n\town int* stored\n\tref[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(ref[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\tref int* old = outer.child.data\n\touter.child = make_child(&y)\n\treturn *old - 3\n", 0)
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\trefmut int* p = outer.child.data\n\touter.child = make_child(p)\n\t*p = 9\n\trefmut int* q = outer.child.data\n\treturn *q - 9\n", c"reborrow cycle")
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\touter.child = make_child(outer.child.data)\n\treturn 0\n", c"reborrow cycle")
	owned_field_case(c"struct Child:\n\town int* stored\n\trefmut[data] int* data\nstruct Outer:\n\town[group] Child* child\n\tint tag\nown[a] Child* make_child(refmut[a] int* data):\n\treturn new Child(new int, data)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make_child(&x), 7)\n\tfor i in range(3):\n\t\touter.child = make_child(&x)\n\t\trefmut int* p = outer.child.data\n\t\t*p += 1\n\treturn x - 6\n", 0)
