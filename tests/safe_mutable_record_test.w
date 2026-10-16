# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int mutable_record_case_number


void mutable_record_result(process_result* result, char* diagnostic, int checking, char* path):
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


void mutable_record_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	mutable_record_case_number = mutable_record_case_number + 1
	char* number = itoa(mutable_record_case_number)
	char* prefix = c"bin/mutable_record_case32_"
	if (__word_size__ == 8): prefix = c"bin/mutable_record_case64_"
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
		mutable_record_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--ast-required")
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
		mutable_record_result(compiled, diagnostic, 0, full)
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


void test_mutable_record_basics():
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\trefmut int* r = h.item\n\t*r = 9\n\tint tag = h.tag\n\treturn x + tag - 12\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\tref int* r = h.item\n\treturn *r - 7\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(tag: 3, item: &x)\n\th.tag = 9\n\trefmut int* r = h.item\n\t*r = 11\n\tint tag = h.tag\n\treturn tag + x - 20\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\ntype View = refmut[a] Holder\nint main():\n\tint x = 7\n\tView h = View(&x, 3)\n\trefmut int* r = h.item\n\t*r = 9\n\treturn x - 9\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\trefmut[b] Holder child = h\n\trefmut int* r = child.item\n\t*r = 9\n\trefmut int* later = h.item\n\t*later = 11\n\treturn x - 11\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\trefmut[b] Holder child = h\n\trefmut int* first = h.item\n\t*first = 9\n\trefmut int* r = child.item\n\treturn *r\n", c"conflicting")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\trefmut int* r = h.item\n\tint prior = x\n\t*r = prior\n\treturn 0\n", c"conflicting")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\tref int* r = h.item\n\tx = 9\n\treturn *r\n", c"conflicting")


void test_mutable_record_contracts():
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nrefmut[a] Holder make(refmut[a] int* value):\n\treturn Holder(value, 3)\nrefmut[a] int* extract(refmut[a] Holder h):\n\treturn h.item\nint main():\n\tint x = 7\n\trefmut[a] Holder h = make(&x)\n\trefmut int* r = extract(h)\n\t*r = 9\n\treturn x - 9\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nrefmut[a] Holder make(refmut[a] int* value):\n\treturn Holder(value, 3)\nint main():\n\tint x = 7\n\trefmut int* r = make(&x).item\n\t*r = 9\n\treturn x - 9\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nrefmut[a] Holder make(refmut[a] int* value):\n\treturn Holder(value, 3)\nint main():\n\tint x = 7\n\tref int* r = make(&x).item\n\treturn *r - 7\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nrefmut[a] Holder bad(refmut[a] int* value):\n\tint local = 9\n\treturn Holder(&local, 3)\nint main():\n\treturn 0\n", c"returned reference")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nrefmut[a] Holder bad(ref[a] int* value):\n\treturn Holder(value, 3)\nint main():\n\treturn 0\n", c"mutable reference return requires")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nrefmut[a] Holder identity(refmut[a] Holder h):\n\treturn h\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\trefmut[b] Holder second = identity(h)\n\trefmut int* r = second.item\n\t*r = 9\n\treturn x - 9\n", 0)
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nrefmut[a] Holder later(refmut[a] int* x);\nrefmut[b] Holder later(refmut[b] int* x):\n\treturn Holder(x, 3)\nint main():\n\tint x = 7\n\trefmut[a] Holder h = later(&x)\n\trefmut int* r = h.item\n\t*r = 9\n\treturn x - 9\n", 0)


void test_mutable_record_boundaries():
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Holder h = Holder(&x, 3)\n\treturn 0\n", c"safe:")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tref int* parent = &x\n\trefmut[a] Holder h = Holder(parent, 3)\n\treturn 0\n", c"mutable borrow from a shared")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\trefmut[a] Holder h\n\treturn 0\n", c"initialization")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(item: &x)\n\treturn 0\n", c"every field")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\trefmut int* tag = &h.tag\n\treturn *tag\n", c"descriptor fields")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\trefmut[a] Holder h = Holder(&x, 3)\n\th.item = &y\n\treturn 0\n", c"cannot be reassigned")
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x, 3)\n\th = h\n\treturn 0\n", c"cannot be reassigned")
	mutable_record_case(c"struct Pair:\n\trefmut[a] int* first\n\trefmut[a] int* second\nint main():\n\tint x = 7\n\trefmut[a] Pair h = Pair(&x, &x)\n\treturn 0\n", c"conflicting")
	mutable_record_case(c"struct Pair:\n\trefmut[a] int* first\n\trefmut[b] int* second\nint main():\n\tint x = 7\n\tint y = 9\n\trefmut[a] Pair h = Pair(&x, &y)\n\treturn 0\n", c"safe:")
	mutable_record_case(c"struct Mixed:\n\town int* owner\n\trefmut[a] int* view\nint main():\n\treturn 0\n", 0)
	mutable_record_case(c"struct Shared:\n\tref[a] int* item\nint main():\n\tint x = 7\n\trefmut[a] Shared h = Shared(&x)\n\trefmut int* r = h.item\n\treturn *r\n", c"mutable borrow from a shared")


void test_mutable_record_field_reservations():
	mutable_record_case(c"struct Pair:\n\trefmut[field] int* first\n\trefmut[field] int* second\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\trefmut[a] Pair h = Pair(&x, &y, 3)\n\trefmut int* first = h.first\n\t*first = 11\n\trefmut int* second = h.second\n\t*second = 13\n\treturn x + y - 24\n", 0)
	mutable_record_case(c"struct Pair:\n\trefmut[field] int* first\n\trefmut[field] int* second\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\trefmut[a] Pair h = Pair(&x, &y, 3)\n\trefmut int* first = h.first\n\trefmut int* second = h.second\n\t*first = 11\n\t*second = 13\n\treturn 0\n", c"conflicting")
	mutable_record_case(c"struct Pair:\n\trefmut[field] int* first\n\trefmut[field] int* second\n\tint tag\nint change(refmut int* value):\n\t*value = 9\n\treturn 3\nint main():\n\tint x = 7\n\tint y = 9\n\trefmut[a] Pair h = Pair(&x, &y, change(&x))\n\treturn 0\n", c"conflicting")
	mutable_record_case(c"struct Pair:\n\trefmut[field] int* first\n\trefmut[field] int* second\n\tint tag\nint change(refmut int* value):\n\t*value = 9\n\treturn 3\nint main():\n\tint x = 7\n\tint y = 9\n\trefmut[a] Pair h = Pair(tag: change(&x), first: &x, second: &y)\n\tref int* r = h.first\n\treturn *r - 9\n", 0)
	mutable_record_case(c"struct Mixed:\n\trefmut[field] int* mutable_item\n\tref[field] int* shared_item\nint main():\n\tint x = 7\n\tint y = 9\n\trefmut[a] Mixed h = Mixed(&x, &y)\n\trefmut int* r = h.mutable_item\n\t*r = 11\n\tref int* s = h.shared_item\n\treturn *s - 9\n", 0)
	mutable_record_case(c"struct Mixed:\n\trefmut[field] int* mutable_item\n\tref[field] int* shared_item\nint main():\n\tint x = 7\n\trefmut[a] Mixed h = Mixed(&x, &x)\n\treturn 0\n", c"conflicting")
	mutable_record_case(c"struct Shared:\n\tref[field] int* item\nint main():\n\tint x = 7\n\tref[a] Shared h = Shared(&x)\n\trefmut[a] Shared mutable = h\n\treturn 0\n", c"mutable borrow from a shared")


void test_mutable_record_independent_lifetime_review():
	# copy return positive
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\nrefmut[a] int* extract(refmut[a] Holder h):\n\trefmut[b] Holder child = h\n\treturn child.item\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x)\n\trefmut int* r = extract(h)\n\t*r = 9\n\treturn x - 9\n", 0)
	# copy parent conflict
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x)\n\trefmut[b] Holder child = h\n\trefmut[c] Holder grandchild = child\n\trefmut int* r = h.item\n\t*r = 9\n\trefmut int* later = grandchild.item\n\treturn *later\n", c"conflicting")
	# returned child parent conflict
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\nrefmut[a] int* extract(refmut[a] Holder h):\n\treturn h.item\nint main():\n\tint x = 7\n\trefmut[a] Holder h = Holder(&x)\n\trefmut int* r = extract(h)\n\trefmut int* later = h.item\n\t*later = 9\n\treturn *r\n", c"conflicting")
	# duplicate mut shared
	mutable_record_case(c"struct Pair:\n\trefmut[field] int* a\n\tref[field] int* b\nint main():\n\tint x = 7\n\trefmut[a] Pair h = Pair(&x, &x)\n\treturn 0\n", c"conflicting")
	# duplicate shared mut
	mutable_record_case(c"struct Pair:\n\trefmut[field] int* a\n\tref[field] int* b\nint main():\n\tint x = 7\n\trefmut[a] Pair h = Pair(b: &x, a: &x)\n\treturn 0\n", c"conflicting")
	# local wrapper outer root
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\nint main():\n\tint x = 7\n\toptrefmut int* saved = 0\n\tif 1:\n\t\trefmut[a] Holder h = Holder(&x)\n\t\tsaved = h.item\n\tif saved: *saved = 9\n\treturn x - 9\n", 0)
	# local owner escape
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\nint main():\n\toptrefmut int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\town int* x = new int\n\t\t\trefmut[a] Holder h = Holder(x)\n\t\t\tsaved = h.item\n\t\t\tbreak\n\tif saved: return *saved\n\treturn 0\n", c"moved value")
	# iteration owner escape
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\nint main():\n\toptrefmut int* saved = 0\n\tint n = 0\n\twhile n < 2:\n\t\town int* x = new int\n\t\trefmut[a] Holder h = Holder(x)\n\t\tif saved: return *saved\n\t\tsaved = h.item\n\t\tn++\n\treturn 0\n", c"moved value")
	# shared field mut escalation
	mutable_record_case(c"struct Pair:\n\trefmut[field] int* a\n\tref[field] int* b\nrefmut[a] int* bad(refmut[a] Pair h):\n\treturn h.b\nint main(): return 0\n", c"mutable borrow from a shared")
	# deferred mutable result
	mutable_record_case(c"struct Holder:\n\trefmut[field] int* item\nint mutate(refmut int* x):\n\t*x = 9\n\treturn 0\nrefmut[a] int* bad(refmut[a] Holder h):\n\tdefer mutate(h.item)\n\treturn h.item\nint main(): return 0\n", c"conflicting")
