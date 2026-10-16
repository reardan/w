# wbuild: x64
# wbuild: deps=tests/safe_aggregate_import_fixture.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int aggregate_lifetime_case_number


void aggregate_lifetime_result(process_result* result, char* diagnostic, int checking, char* path):
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


void aggregate_lifetime_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	aggregate_lifetime_case_number = aggregate_lifetime_case_number + 1
	char* number = itoa(aggregate_lifetime_case_number)
	char* prefix = c"bin/aggregate_lifetime_case32_"
	if (__word_size__ == 8): prefix = c"bin/aggregate_lifetime_case64_"
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
		aggregate_lifetime_result(checked, diagnostic, 1, full)
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
		aggregate_lifetime_result(compiled, diagnostic, 0, full)
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


void test_shared_aggregate_values():
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\tref int* r = h.item\n\treturn *r + h.tag - 10\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* value, int tag):\n\treturn Holder(value, tag)\nint main():\n\tint x = 7\n\tref[a] Holder h = make(&x, 3)\n\tref int* r = h.item\n\treturn *r + h.tag - 10\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* value, int tag):\n\treturn Holder(value, tag)\nref[a] Holder copy(ref[a] Holder h):\n\treturn h\nint main():\n\tint x = 7\n\tref[a] Holder h = copy(copy(make(&x, 3)))\n\tref int* r = h.item\n\treturn *r + h.tag - 10\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint read(int first, ref[a] Holder h, int last):\n\tref int* r = h.item\n\treturn first + *r + h.tag + last\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\treturn read(2, h, 5) - 17\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\town int* x = new int\n\t*x = 7\n\tref[a] Holder h = Holder(x, 3)\n\tref[a] Holder copied = h\n\tref int* r = copied.item\n\treturn *r + copied.tag - 10\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] int* get(ref[a] Holder h):\n\treturn h.item\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\tref int* r = get(h)\n\treturn *r - 7\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* value, int tag):\n\treturn Holder(value, tag)\nint clobber(int n):\n\tint[64] values\n\tvalues[0] = n\n\treturn values[0]\nint main():\n\tint x = 7\n\tref[a] Holder h = make(&x, 3)\n\tint saved = clobber(5)\n\tref int* r = h.item\n\treturn *r + h.tag + saved - 15\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\ntype View = ref[a] Holder\nView make(ref[a] int* p):\n\treturn Holder(p, 3)\nint main():\n\tint x = 7\n\tView h = make(&x)\n\tref int* r = h.item\n\treturn *r + h.tag - 10\n", 0)


void test_shared_aggregate_origins():
	aggregate_lifetime_case(c"struct Pair:\n\tref[field] int* first\n\tref[field] int* second\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\tref[a] Pair p = Pair(&x, &y, 3)\n\tref int* first = p.first\n\tref int* second = p.second\n\treturn *first + *second + p.tag - 19\n", 0)
	aggregate_lifetime_case(c"struct Pair:\n\tref[field] int* first\n\tref[field] int* second\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\tref[a] Pair p = Pair(&x, &y, 3)\n\tx = 4\n\tref int* first = p.first\n\treturn *first\n", c"conflicting")
	aggregate_lifetime_case(c"struct Pair:\n\tref[field] int* first\n\tref[field] int* second\n\tint tag\nint main():\n\town int* x = new int\n\town int* y = new int\n\tref[a] Pair p = Pair(x, y, 3)\n\town int* moved = x\n\tref int* first = p.first\n\treturn *first\n", c"moved value")
	aggregate_lifetime_case(c"struct Pair:\n\tref[field] int* first\n\tref[field] int* second\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\tref[a] Pair p = Pair(&x, &y, 3)\n\ty = 4\n\tref int* first = p.first\n\treturn *first\n", c"conflicting")
	aggregate_lifetime_case(c"struct Pair:\n\tref[field] int* first\n\tref[field] int* second\n\tint tag\nint main():\n\town int* x = new int\n\town int* y = new int\n\tref[a] Pair p = Pair(x, y, 3)\n\town int* moved = y\n\tref int* first = p.first\n\treturn *first\n", c"moved value")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\tref int* r = h.item\n\tx = 8\n\treturn *r\n", c"conflicting")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\tref int* r = h.item\n\tint old = *r\n\tx = 8\n\treturn old + x - 15\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder bad(ref[a] int* p):\n\tint local = 7\n\treturn Holder(&local, 3)\nint main():\n\treturn 0\n", c"must borrow from")
	aggregate_lifetime_case(c"struct Pair:\n\tref[field] int* first\n\tref[field] int* second\n\tint tag\nref[a] Pair bad(ref[a] int* p, ref[b] int* q):\n\treturn Pair(p, q, 3)\nint main():\n\treturn 0\n", c"must borrow from")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] int* bad(ref[a] Holder h):\n\treturn &h.tag\nint main():\n\treturn 0\n", c"safe:")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut int* parent = &x\n\tref[a] Holder h = Holder(parent, 3)\n\t*parent = 9\n\tref int* r = h.item\n\treturn *r\n", c"conflicting")


void test_shared_aggregate_declarations():
	aggregate_lifetime_case(c"import tests.safe_aggregate_import_fixture\nint main():\n\tint x = 7\n\tref[a] ImportedView h = aggregate_import_make(&x, 3)\n\tref int* r = aggregate_import_get(h)\n\treturn *r + h.tag - 10\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder later(ref[a] int* value);\nint main():\n\tint x = 7\n\tref[a] Holder h = later(&x)\n\tref int* r = h.item\n\treturn *r + h.tag - 10\nref[b] Holder later(ref[b] int* p):\n\treturn Holder(p, 3)\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder later(ref[a] int* x, ref[b] int* y);\nref[z] Holder later(ref[y] int* p, ref[z] int* q):\n\treturn Holder(q, 3)\nint main():\n\treturn 0\n", c"forward declaration")


void test_shared_aggregate_fail_closed():
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tref[a] Holder h\n\treturn 0\n", c"initialization")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\town Holder* h = new Holder\n\treturn 0\n", c"safe:")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x)\n\treturn h.tag\n", c"", 1)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tref[a] Holder h = Holder(0, 3)\n\treturn h.tag\n", c"safe:", 1)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\tref[a] Holder h = Holder(&x, 3)\n\th.item = &y\n\treturn h.tag\n", c"safe:")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\th.tag = 5\n\treturn h.tag\n", c"safe:")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\trefmut int* r = h.item\n\treturn *r\n", c"mutable borrow from a shared")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\tref[a] Holder other = h\n\th = other\n\treturn h.tag\n", c"cannot be reassigned")
	aggregate_lifetime_case(c"struct Bad:\n\tref[x] int* first\n\tref[y] int* second\nint main():\n\tint x = 0\n\tint y = 0\n\tref[a] Bad b = Bad(&x, &y)\n\treturn 0\n", c"safe:")
	aggregate_lifetime_case(c"struct Bad:\n\tref int* item\nint main():\n\tint x = 0\n\tref[a] Bad b = Bad(&x)\n\treturn 0\n", c"safe:")
	aggregate_lifetime_case(c"struct Bad:\n\town int* item\nint main():\n\town int* x = new int\n\tref[a] Bad b = Bad(x)\n\treturn 0\n", c"safe:")
	aggregate_lifetime_case(c"struct Bad:\n\trefmut[x] int* item\nint main():\n\tint x = 0\n\tref[a] Bad b = Bad(&x)\n\treturn 0\n", c"safe:")
