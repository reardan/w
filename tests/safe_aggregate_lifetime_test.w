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
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint aggregate_read(int first, ref[a] Holder h, int last):\n\tref int* r = h.item\n\treturn first + *r + h.tag + last\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\treturn aggregate_read(2, h, 5) - 17\n", 0)
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


void test_shared_aggregate_constructor_boundaries():
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tHolder h = Holder(&x, 3)\n\treturn h.tag\n", c"safe:")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\ntype View = ref[a] Holder\nint main():\n\tint x = 7\n\tView h = View(&x, 3)\n\tref int* r = h.item\n\treturn *r + h.tag - 10\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(tag: 3, item: &x)\n\tref int* r = h.item\n\treturn *r + h.tag - 10\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(item: &x)\n\treturn h.tag\n", c"every field")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(item: &x, item: &x)\n\treturn h.tag\n", c"initialized twice")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint main():\n\tref[a] Holder h = Holder()\n\treturn h.tag\n", c"every field")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint change(refmut int* p):\n\t*p = 9\n\treturn 3\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, change(&x))\n\treturn h.tag\n", c"conflicting")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nint change(refmut int* p):\n\t*p = 9\n\treturn 3\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(tag: change(&x), item: &x)\n\tref int* r = h.item\n\treturn *r + h.tag - 12\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nown int* make_owner():\n\town int* p = new int\n\treturn p\nint main():\n\tref[a] Holder h = Holder(make_owner(), 3)\n\treturn h.tag\n", c"borrowed return contract")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* p):\n\treturn Holder(p, 3)\nint main():\n\tint x = 7\n\tref int* r = make(&x).item\n\treturn *r - 7\n", 0)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* p):\n\treturn Holder(p, 3)\nint main():\n\tint x = 7\n\tref int* r = make(&x).item\n\tx = 9\n\treturn *r\n", c"conflicting")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* p):\n\treturn Holder(p, 3)\nint main():\n\tint x = 7\n\trefmut int* r = make(&x).item\n\treturn *r\n", c"mutable borrow from a shared")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* p):\n\treturn Holder(p, 3)\nref[a] int* bad(ref[a] int* p):\n\treturn &make(p).tag\nint main():\n\treturn 0\n", c"safe:")
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] Holder make(ref[a] int* p):\n\treturn Holder(p, 3)\nref[a] int* bad(ref[a] int* p):\n\treturn &make(p).item\nint main():\n\treturn 0\n", c"safe:", 1)
	aggregate_lifetime_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\nref[a] int* bad(ref[a] Holder h):\n\treturn &h.item\nint main():\n\treturn 0\n", c"descriptor fields", 1)


void test_shared_aggregate_slice_fields():
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref[a] SliceRecord h = SliceRecord(values, 3)\n\tref int[] s = h.values\n\treturn s[0] + s[1] + s.length + h.tag - 21\n", 0)
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nref[a] SliceRecord make(ref[a] int[] values, int tag):\n\treturn SliceRecord(values, tag)\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref[a] SliceRecord h = make(values, 3)\n\tref int[] s = h.values\n\treturn s[0] + s[1] + s.length + h.tag - 21\n", 0)
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nref[a] SliceRecord make(ref[a] int[] values, int tag):\n\treturn SliceRecord(values, tag)\nref[a] int[] extract(ref[a] SliceRecord h):\n\treturn h.values\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref int[] s = extract(make(values, 3))\n\treturn s[0] + s[1] + s.length - 18\n", 0)
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nref[a] SliceRecord make(ref[a] int[] values, int tag):\n\treturn SliceRecord(values, tag)\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref int[] s = make(values, 3).values\n\treturn s[0] + s.length - 9\n", 0)
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nref[a] SliceRecord make(ref[a] int[] values, int tag):\n\treturn SliceRecord(values, tag)\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref int[] s = make(values, 3).values[1:]\n\treturn s[0] + s.length - 10\n", 0)
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nref[a] SliceRecord make(ref[a] int[] values, int tag):\n\treturn SliceRecord(values, tag)\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref int[] s = make(values, 3).values\n\tvalues[0] = 5\n\treturn s[0]\n", c"conflicting")
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nref[a] SliceRecord bad(ref[a] int[] input):\n\tint[2] local\n\treturn SliceRecord(local, 3)\nint main():\n\treturn 0\n", c"must borrow from")
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref[a] SliceRecord h = SliceRecord(values, 3)\n\tref int[] s = h.values\n\ts[0] = 5\n\treturn 0\n", c"shared reference")
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref[a] SliceRecord h = SliceRecord(values, 3)\n\th.values = values\n\treturn 0\n", c"safe:")
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\ntype View = ref[a] SliceRecord\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tView h = View(values, 3)\n\tref int[] s = h.values\n\treturn s[0] + s.length - 9\n", 0)
	aggregate_lifetime_case(c"struct MixedView:\n\tref[field] int* item\n\tref[field] int[] values\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tint x = 3\n\tref[a] MixedView h = MixedView(&x, values)\n\tref int[] s = h.values\n\tx = 5\n\treturn s[0]\n", c"conflicting")
	aggregate_lifetime_case(c"struct MixedView:\n\tref[field] int* item\n\tref[field] int[] values\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tint x = 3\n\tref[a] MixedView h = MixedView(&x, values)\n\tref int* r = h.item\n\tvalues[0] = 5\n\treturn *r\n", c"conflicting")
	aggregate_lifetime_case(c"struct SliceRecord:\n\tref[field] int[] values\n\tint tag\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tvalues[1] = 9\n\tref[a] SliceRecord h = SliceRecord(values, 3)\n\treturn h.values[0]\n", c"safe:")


void test_deep_aggregate_types_do_not_hide_checked_fields():
	char* source = strclone(c"struct DeepLeaf:\n\tref[field] int* item\n")
	char* previous = strclone(c"DeepLeaf")
	for depth in range(40):
		char* number = itoa(depth)
		char* name = strjoin(c"DeepLayer", number)
		free(number)
		char* declaration = strjoin(c"struct ", name)
		char* body = strjoin(declaration, c":\n\t")
		free(declaration)
		declaration = strjoin(body, previous)
		free(body)
		body = strjoin(declaration, c" inner\n")
		free(declaration)
		declaration = strjoin(source, body)
		free(body)
		free(source)
		source = declaration
		free(previous)
		previous = name
	char* body = strjoin(c"int main():\n\t", previous)
	free(previous)
	char* ending = strjoin(body, c" value\n\treturn 0\n")
	free(body)
	char* complete = strjoin(source, ending)
	free(source)
	free(ending)
	aggregate_lifetime_case(complete, c"safe:")
	free(complete)


# Repeated raw type references must not consume the distinct-type budget.
void test_borrowed_aggregate_raw_dag_visibility():
	aggregate_lifetime_case(c"struct RawDAG0:\n\tint value\nstruct RawDAG1:\n\tRawDAG0* left\n\tRawDAG0* right\nstruct RawDAG2:\n\tRawDAG1* left\n\tRawDAG1* right\nstruct RawDAG3:\n\tRawDAG2* left\n\tRawDAG2* right\nstruct RawDAG4:\n\tRawDAG3* left\n\tRawDAG3* right\nstruct RawDAG5:\n\tRawDAG4* left\n\tRawDAG4* right\nstruct RawDAG6:\n\tRawDAG5* left\n\tRawDAG5* right\nstruct RawDAG7:\n\tRawDAG6* left\n\tRawDAG6* right\nstruct RawDAG8:\n\tRawDAG7* left\n\tRawDAG7* right\nstruct RawDAG9:\n\tRawDAG8* left\n\tRawDAG8* right\nstruct RawDAG10:\n\tRawDAG9* left\n\tRawDAG9* right\nstruct RawDAG11:\n\tRawDAG10* left\n\tRawDAG10* right\nstruct RawDAG12:\n\tRawDAG11* left\n\tRawDAG11* right\nstruct RawDAG13:\n\tRawDAG12* left\n\tRawDAG12* right\nstruct RawDAG14:\n\tRawDAG13* left\n\tRawDAG13* right\nstruct RawDAG15:\n\tRawDAG14* left\n\tRawDAG14* right\nint checked_trigger():\n\town int* item = new int\n\treturn *item\nint main():\n\treturn 0\n", 0)


# Exhaustion activates checking conservatively, so a raw field after the
# distinct-type budget cannot hide in an otherwise unannotated function.
void test_borrowed_aggregate_distinct_type_budget():
	aggregate_lifetime_case(c"struct WidePlain0:\n\tint value\nstruct WidePlain1:\n\tint value\nstruct WidePlain2:\n\tint value\nstruct WidePlain3:\n\tint value\nstruct WidePlain4:\n\tint value\nstruct WidePlain5:\n\tint value\nstruct WidePlain6:\n\tint value\nstruct WidePlain7:\n\tint value\nstruct WidePlain8:\n\tint value\nstruct WidePlain9:\n\tint value\nstruct WidePlain10:\n\tint value\nstruct WidePlain11:\n\tint value\nstruct WidePlain12:\n\tint value\nstruct WidePlain13:\n\tint value\nstruct WidePlain14:\n\tint value\nstruct WidePlain15:\n\tint value\nstruct WidePlain16:\n\tint value\nstruct WidePlain17:\n\tint value\nstruct WidePlain18:\n\tint value\nstruct WidePlain19:\n\tint value\nstruct WidePlain20:\n\tint value\nstruct WidePlain21:\n\tint value\nstruct WidePlain22:\n\tint value\nstruct WidePlain23:\n\tint value\nstruct WidePlain24:\n\tint value\nstruct WidePlain25:\n\tint value\nstruct WidePlain26:\n\tint value\nstruct WidePlain27:\n\tint value\nstruct WidePlain28:\n\tint value\nstruct WidePlain29:\n\tint value\nstruct WidePlain30:\n\tint value\nstruct WidePlain31:\n\tint value\nstruct WidePlain32:\n\tint value\nstruct WidePlain33:\n\tint value\nstruct WidePlain34:\n\tint value\nstruct WidePlain35:\n\tint value\nstruct WidePlain36:\n\tint value\nstruct WidePlain37:\n\tint value\nstruct WidePlain38:\n\tint value\nstruct WidePlain39:\n\tint value\nstruct WidePlain40:\n\tint value\nstruct WidePlain41:\n\tint value\nstruct WidePlain42:\n\tint value\nstruct WidePlain43:\n\tint value\nstruct WidePlain44:\n\tint value\nstruct WidePlain45:\n\tint value\nstruct WidePlain46:\n\tint value\nstruct WidePlain47:\n\tint value\nstruct WidePlain48:\n\tint value\nstruct WidePlain49:\n\tint value\nstruct WidePlain50:\n\tint value\nstruct WidePlain51:\n\tint value\nstruct WidePlain52:\n\tint value\nstruct WidePlain53:\n\tint value\nstruct WidePlain54:\n\tint value\nstruct WidePlain55:\n\tint value\nstruct WidePlain56:\n\tint value\nstruct WidePlain57:\n\tint value\nstruct WidePlain58:\n\tint value\nstruct WidePlain59:\n\tint value\nstruct WidePlain60:\n\tint value\nstruct WidePlain61:\n\tint value\nstruct WidePlain62:\n\tint value\nstruct WidePlain63:\n\tint value\nstruct WidePlain64:\n\tint value\nstruct WidePlain65:\n\tint value\nstruct WidePlain66:\n\tint value\nstruct WidePlain67:\n\tint value\nstruct WidePlain68:\n\tint value\nstruct WidePlain69:\n\tint value\nstruct WidePlain70:\n\tint value\nstruct WidePlain71:\n\tint value\nstruct WidePlain72:\n\tint value\nstruct WidePlain73:\n\tint value\nstruct WidePlain74:\n\tint value\nstruct WidePlain75:\n\tint value\nstruct WidePlain76:\n\tint value\nstruct WidePlain77:\n\tint value\nstruct WidePlain78:\n\tint value\nstruct WidePlain79:\n\tint value\nstruct WidePlain80:\n\tint value\nstruct WidePlain81:\n\tint value\nstruct WidePlain82:\n\tint value\nstruct WidePlain83:\n\tint value\nstruct WidePlain84:\n\tint value\nstruct WidePlain85:\n\tint value\nstruct WidePlain86:\n\tint value\nstruct WidePlain87:\n\tint value\nstruct WidePlain88:\n\tint value\nstruct WidePlain89:\n\tint value\nstruct WidePlain90:\n\tint value\nstruct WidePlain91:\n\tint value\nstruct WidePlain92:\n\tint value\nstruct WidePlain93:\n\tint value\nstruct WidePlain94:\n\tint value\nstruct WidePlain95:\n\tint value\nstruct WidePlain96:\n\tint value\nstruct WidePlain97:\n\tint value\nstruct WidePlain98:\n\tint value\nstruct WidePlain99:\n\tint value\nstruct WidePlain100:\n\tint value\nstruct WidePlain101:\n\tint value\nstruct WidePlain102:\n\tint value\nstruct WidePlain103:\n\tint value\nstruct WidePlain104:\n\tint value\nstruct WidePlain105:\n\tint value\nstruct WidePlain106:\n\tint value\nstruct WidePlain107:\n\tint value\nstruct WidePlain108:\n\tint value\nstruct WidePlain109:\n\tint value\nstruct WidePlain110:\n\tint value\nstruct WidePlain111:\n\tint value\nstruct WidePlain112:\n\tint value\nstruct WidePlain113:\n\tint value\nstruct WidePlain114:\n\tint value\nstruct WidePlain115:\n\tint value\nstruct WidePlain116:\n\tint value\nstruct WidePlain117:\n\tint value\nstruct WidePlain118:\n\tint value\nstruct WidePlain119:\n\tint value\nstruct WidePlain120:\n\tint value\nstruct WidePlain121:\n\tint value\nstruct WidePlain122:\n\tint value\nstruct WidePlain123:\n\tint value\nstruct WidePlain124:\n\tint value\nstruct WidePlain125:\n\tint value\nstruct WidePlain126:\n\tint value\nstruct WidePlain127:\n\tint value\nstruct WidePlain128:\n\tint value\nstruct WidePlain129:\n\tint value\nstruct WidePlain130:\n\tint value\nstruct WidePlain131:\n\tint value\nstruct WidePlain132:\n\tint value\nstruct WidePlain133:\n\tint value\nstruct WidePlain134:\n\tint value\nstruct WidePlain135:\n\tint value\nstruct WidePlain136:\n\tint value\nstruct WidePlain137:\n\tint value\nstruct WidePlain138:\n\tint value\nstruct WidePlain139:\n\tint value\nstruct WidePlain140:\n\tint value\nstruct WidePlain141:\n\tint value\nstruct WidePlain142:\n\tint value\nstruct WidePlain143:\n\tint value\nstruct WidePlain144:\n\tint value\nstruct WidePlain145:\n\tint value\nstruct WidePlain146:\n\tint value\nstruct WidePlain147:\n\tint value\nstruct WidePlain148:\n\tint value\nstruct WidePlain149:\n\tint value\nstruct WidePlain150:\n\tint value\nstruct WidePlain151:\n\tint value\nstruct WidePlain152:\n\tint value\nstruct WidePlain153:\n\tint value\nstruct WidePlain154:\n\tint value\nstruct WidePlain155:\n\tint value\nstruct WidePlain156:\n\tint value\nstruct WidePlain157:\n\tint value\nstruct WidePlain158:\n\tint value\nstruct WidePlain159:\n\tint value\nstruct WidePlain160:\n\tint value\nstruct WidePlain161:\n\tint value\nstruct WidePlain162:\n\tint value\nstruct WidePlain163:\n\tint value\nstruct WidePlain164:\n\tint value\nstruct WidePlain165:\n\tint value\nstruct WidePlain166:\n\tint value\nstruct WidePlain167:\n\tint value\nstruct WidePlain168:\n\tint value\nstruct WidePlain169:\n\tint value\nstruct WidePlain170:\n\tint value\nstruct WidePlain171:\n\tint value\nstruct WidePlain172:\n\tint value\nstruct WidePlain173:\n\tint value\nstruct WidePlain174:\n\tint value\nstruct WidePlain175:\n\tint value\nstruct WidePlain176:\n\tint value\nstruct WidePlain177:\n\tint value\nstruct WidePlain178:\n\tint value\nstruct WidePlain179:\n\tint value\nstruct WidePlain180:\n\tint value\nstruct WidePlain181:\n\tint value\nstruct WidePlain182:\n\tint value\nstruct WidePlain183:\n\tint value\nstruct WidePlain184:\n\tint value\nstruct WidePlain185:\n\tint value\nstruct WidePlain186:\n\tint value\nstruct WidePlain187:\n\tint value\nstruct WidePlain188:\n\tint value\nstruct WidePlain189:\n\tint value\nstruct WidePlain190:\n\tint value\nstruct WidePlain191:\n\tint value\nstruct WidePlain192:\n\tint value\nstruct WidePlain193:\n\tint value\nstruct WidePlain194:\n\tint value\nstruct WidePlain195:\n\tint value\nstruct WidePlain196:\n\tint value\nstruct WidePlain197:\n\tint value\nstruct WidePlain198:\n\tint value\nstruct WidePlain199:\n\tint value\nstruct WidePlain200:\n\tint value\nstruct WidePlain201:\n\tint value\nstruct WidePlain202:\n\tint value\nstruct WidePlain203:\n\tint value\nstruct WidePlain204:\n\tint value\nstruct WidePlain205:\n\tint value\nstruct WidePlain206:\n\tint value\nstruct WidePlain207:\n\tint value\nstruct WidePlain208:\n\tint value\nstruct WidePlain209:\n\tint value\nstruct WidePlain210:\n\tint value\nstruct WidePlain211:\n\tint value\nstruct WidePlain212:\n\tint value\nstruct WidePlain213:\n\tint value\nstruct WidePlain214:\n\tint value\nstruct WidePlain215:\n\tint value\nstruct WidePlain216:\n\tint value\nstruct WidePlain217:\n\tint value\nstruct WidePlain218:\n\tint value\nstruct WidePlain219:\n\tint value\nstruct WidePlain220:\n\tint value\nstruct WidePlain221:\n\tint value\nstruct WidePlain222:\n\tint value\nstruct WidePlain223:\n\tint value\nstruct WidePlain224:\n\tint value\nstruct WidePlain225:\n\tint value\nstruct WidePlain226:\n\tint value\nstruct WidePlain227:\n\tint value\nstruct WidePlain228:\n\tint value\nstruct WidePlain229:\n\tint value\nstruct WidePlain230:\n\tint value\nstruct WidePlain231:\n\tint value\nstruct WidePlain232:\n\tint value\nstruct WidePlain233:\n\tint value\nstruct WidePlain234:\n\tint value\nstruct WidePlain235:\n\tint value\nstruct WidePlain236:\n\tint value\nstruct WidePlain237:\n\tint value\nstruct WidePlain238:\n\tint value\nstruct WidePlain239:\n\tint value\nstruct WidePlain240:\n\tint value\nstruct WidePlain241:\n\tint value\nstruct WidePlain242:\n\tint value\nstruct WidePlain243:\n\tint value\nstruct WidePlain244:\n\tint value\nstruct WidePlain245:\n\tint value\nstruct WidePlain246:\n\tint value\nstruct WidePlain247:\n\tint value\nstruct WidePlain248:\n\tint value\nstruct WidePlain249:\n\tint value\nstruct WidePlain250:\n\tint value\nstruct WidePlain251:\n\tint value\nstruct WidePlain252:\n\tint value\nstruct WidePlain253:\n\tint value\nstruct WidePlain254:\n\tint value\nstruct WidePlain255:\n\tint value\nstruct WidePlain256:\n\tint value\nstruct WidePlain257:\n\tint value\nstruct WidePlain258:\n\tint value\nstruct WidePlain259:\n\tint value\nstruct WideRoot:\n\tWidePlain0 value0\n\tWidePlain1 value1\n\tWidePlain2 value2\n\tWidePlain3 value3\n\tWidePlain4 value4\n\tWidePlain5 value5\n\tWidePlain6 value6\n\tWidePlain7 value7\n\tWidePlain8 value8\n\tWidePlain9 value9\n\tWidePlain10 value10\n\tWidePlain11 value11\n\tWidePlain12 value12\n\tWidePlain13 value13\n\tWidePlain14 value14\n\tWidePlain15 value15\n\tWidePlain16 value16\n\tWidePlain17 value17\n\tWidePlain18 value18\n\tWidePlain19 value19\n\tWidePlain20 value20\n\tWidePlain21 value21\n\tWidePlain22 value22\n\tWidePlain23 value23\n\tWidePlain24 value24\n\tWidePlain25 value25\n\tWidePlain26 value26\n\tWidePlain27 value27\n\tWidePlain28 value28\n\tWidePlain29 value29\n\tWidePlain30 value30\n\tWidePlain31 value31\n\tWidePlain32 value32\n\tWidePlain33 value33\n\tWidePlain34 value34\n\tWidePlain35 value35\n\tWidePlain36 value36\n\tWidePlain37 value37\n\tWidePlain38 value38\n\tWidePlain39 value39\n\tWidePlain40 value40\n\tWidePlain41 value41\n\tWidePlain42 value42\n\tWidePlain43 value43\n\tWidePlain44 value44\n\tWidePlain45 value45\n\tWidePlain46 value46\n\tWidePlain47 value47\n\tWidePlain48 value48\n\tWidePlain49 value49\n\tWidePlain50 value50\n\tWidePlain51 value51\n\tWidePlain52 value52\n\tWidePlain53 value53\n\tWidePlain54 value54\n\tWidePlain55 value55\n\tWidePlain56 value56\n\tWidePlain57 value57\n\tWidePlain58 value58\n\tWidePlain59 value59\n\tWidePlain60 value60\n\tWidePlain61 value61\n\tWidePlain62 value62\n\tWidePlain63 value63\n\tWidePlain64 value64\n\tWidePlain65 value65\n\tWidePlain66 value66\n\tWidePlain67 value67\n\tWidePlain68 value68\n\tWidePlain69 value69\n\tWidePlain70 value70\n\tWidePlain71 value71\n\tWidePlain72 value72\n\tWidePlain73 value73\n\tWidePlain74 value74\n\tWidePlain75 value75\n\tWidePlain76 value76\n\tWidePlain77 value77\n\tWidePlain78 value78\n\tWidePlain79 value79\n\tWidePlain80 value80\n\tWidePlain81 value81\n\tWidePlain82 value82\n\tWidePlain83 value83\n\tWidePlain84 value84\n\tWidePlain85 value85\n\tWidePlain86 value86\n\tWidePlain87 value87\n\tWidePlain88 value88\n\tWidePlain89 value89\n\tWidePlain90 value90\n\tWidePlain91 value91\n\tWidePlain92 value92\n\tWidePlain93 value93\n\tWidePlain94 value94\n\tWidePlain95 value95\n\tWidePlain96 value96\n\tWidePlain97 value97\n\tWidePlain98 value98\n\tWidePlain99 value99\n\tWidePlain100 value100\n\tWidePlain101 value101\n\tWidePlain102 value102\n\tWidePlain103 value103\n\tWidePlain104 value104\n\tWidePlain105 value105\n\tWidePlain106 value106\n\tWidePlain107 value107\n\tWidePlain108 value108\n\tWidePlain109 value109\n\tWidePlain110 value110\n\tWidePlain111 value111\n\tWidePlain112 value112\n\tWidePlain113 value113\n\tWidePlain114 value114\n\tWidePlain115 value115\n\tWidePlain116 value116\n\tWidePlain117 value117\n\tWidePlain118 value118\n\tWidePlain119 value119\n\tWidePlain120 value120\n\tWidePlain121 value121\n\tWidePlain122 value122\n\tWidePlain123 value123\n\tWidePlain124 value124\n\tWidePlain125 value125\n\tWidePlain126 value126\n\tWidePlain127 value127\n\tWidePlain128 value128\n\tWidePlain129 value129\n\tWidePlain130 value130\n\tWidePlain131 value131\n\tWidePlain132 value132\n\tWidePlain133 value133\n\tWidePlain134 value134\n\tWidePlain135 value135\n\tWidePlain136 value136\n\tWidePlain137 value137\n\tWidePlain138 value138\n\tWidePlain139 value139\n\tWidePlain140 value140\n\tWidePlain141 value141\n\tWidePlain142 value142\n\tWidePlain143 value143\n\tWidePlain144 value144\n\tWidePlain145 value145\n\tWidePlain146 value146\n\tWidePlain147 value147\n\tWidePlain148 value148\n\tWidePlain149 value149\n\tWidePlain150 value150\n\tWidePlain151 value151\n\tWidePlain152 value152\n\tWidePlain153 value153\n\tWidePlain154 value154\n\tWidePlain155 value155\n\tWidePlain156 value156\n\tWidePlain157 value157\n\tWidePlain158 value158\n\tWidePlain159 value159\n\tWidePlain160 value160\n\tWidePlain161 value161\n\tWidePlain162 value162\n\tWidePlain163 value163\n\tWidePlain164 value164\n\tWidePlain165 value165\n\tWidePlain166 value166\n\tWidePlain167 value167\n\tWidePlain168 value168\n\tWidePlain169 value169\n\tWidePlain170 value170\n\tWidePlain171 value171\n\tWidePlain172 value172\n\tWidePlain173 value173\n\tWidePlain174 value174\n\tWidePlain175 value175\n\tWidePlain176 value176\n\tWidePlain177 value177\n\tWidePlain178 value178\n\tWidePlain179 value179\n\tWidePlain180 value180\n\tWidePlain181 value181\n\tWidePlain182 value182\n\tWidePlain183 value183\n\tWidePlain184 value184\n\tWidePlain185 value185\n\tWidePlain186 value186\n\tWidePlain187 value187\n\tWidePlain188 value188\n\tWidePlain189 value189\n\tWidePlain190 value190\n\tWidePlain191 value191\n\tWidePlain192 value192\n\tWidePlain193 value193\n\tWidePlain194 value194\n\tWidePlain195 value195\n\tWidePlain196 value196\n\tWidePlain197 value197\n\tWidePlain198 value198\n\tWidePlain199 value199\n\tWidePlain200 value200\n\tWidePlain201 value201\n\tWidePlain202 value202\n\tWidePlain203 value203\n\tWidePlain204 value204\n\tWidePlain205 value205\n\tWidePlain206 value206\n\tWidePlain207 value207\n\tWidePlain208 value208\n\tWidePlain209 value209\n\tWidePlain210 value210\n\tWidePlain211 value211\n\tWidePlain212 value212\n\tWidePlain213 value213\n\tWidePlain214 value214\n\tWidePlain215 value215\n\tWidePlain216 value216\n\tWidePlain217 value217\n\tWidePlain218 value218\n\tWidePlain219 value219\n\tWidePlain220 value220\n\tWidePlain221 value221\n\tWidePlain222 value222\n\tWidePlain223 value223\n\tWidePlain224 value224\n\tWidePlain225 value225\n\tWidePlain226 value226\n\tWidePlain227 value227\n\tWidePlain228 value228\n\tWidePlain229 value229\n\tWidePlain230 value230\n\tWidePlain231 value231\n\tWidePlain232 value232\n\tWidePlain233 value233\n\tWidePlain234 value234\n\tWidePlain235 value235\n\tWidePlain236 value236\n\tWidePlain237 value237\n\tWidePlain238 value238\n\tWidePlain239 value239\n\tWidePlain240 value240\n\tWidePlain241 value241\n\tWidePlain242 value242\n\tWidePlain243 value243\n\tWidePlain244 value244\n\tWidePlain245 value245\n\tWidePlain246 value246\n\tWidePlain247 value247\n\tWidePlain248 value248\n\tWidePlain249 value249\n\tWidePlain250 value250\n\tWidePlain251 value251\n\tWidePlain252 value252\n\tWidePlain253 value253\n\tWidePlain254 value254\n\tWidePlain255 value255\n\tWidePlain256 value256\n\tWidePlain257 value257\n\tWidePlain258 value258\n\tWidePlain259 value259\n\tint* hidden_raw\nint checked_trigger():\n\town int* item = new int\n\treturn *item\nint main():\n\tWideRoot root\n\treturn 0\n", c"safe:")
