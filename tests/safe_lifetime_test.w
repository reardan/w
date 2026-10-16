# wbuild: x64
# wbuild: deps=tests/safe_lifetime_import_fixture.w
# wbuild: deps=tests/safe_outlives_import_fixture.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int lifetime_case_number


void lifetime_result(process_result* result, char* diagnostic, int checking, char* path):
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


void lifetime_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	lifetime_case_number = lifetime_case_number + 1
	char* number = itoa(lifetime_case_number)
	char* prefix = c"bin/lifetime_case32_"
	if (__word_size__ == 8): prefix = c"bin/lifetime_case64_"
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
		lifetime_result(checked, diagnostic, 1, full)
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
		lifetime_result(compiled, diagnostic, 0, full)
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


void test_named_lifetime_basics():
	lifetime_case(c"ref[a] int* view(ref[a] int* p):\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = view(&x)\n\treturn *r - 7\n", 0)
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* a = choose(&x, &y, 1)\n\tref int* b = choose(&x, &y, 0)\n\treturn *a + *b - 12\n", 0)
	lifetime_case(c"ref[a] int* first(ref[a] int* left, ref[b] int* right):\n\treturn left\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* a = first(&x, &y)\n\ty = 9\n\treturn *a + y - 13\n", 0)
	lifetime_case(c"ref[a] int* first(ref[a] int* left, ref int* right):\n\treturn left\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* a = first(&x, &y)\n\ty = 9\n\treturn *a + y - 13\n", 0)
	lifetime_case(c"type View = ref[a] int*\nView choose(View left, View right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tView a = choose(&x, &y, 0)\n\treturn *a - 8\n", 0)
	lifetime_case(c"type Scalar = int\nref[a] Scalar* view(ref[a] int* p, int offset):\n\treturn p\nint main():\n\tScalar n = 4\n\tref int* r = view(&n, 0)\n\treturn *r - 4\n", 0)
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tref int* a = choose(&x, &x, 0)\n\treturn *a - 4\n", 0)
	lifetime_case(c"ref int* inferred(ref[a] int* p):\n\treturn p\nint main():\n\tint x = 4\n\tref int* a = inferred(&x)\n\treturn *a - 4\n", 0)


void test_named_lifetime_body_contracts():
	lifetime_case(c"ref[a] int* bad(ref[b] int* p):\n\treturn p\nint main():\n\treturn 0\n", c"returned lifetime")
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, ref[b] int* q):\n\treturn q\nint main():\n\treturn 0\n", c"must borrow from")
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, ref[a] int* q):\n\tint local = 3\n\treturn &local\nint main():\n\treturn 0\n", c"must borrow from")
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, own int* q):\n\treturn q\nint main():\n\treturn 0\n", c"must borrow from")
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, ref[a] int* q, int first):\n\tif first: return p\n\tint local = 3\n\treturn &local\nint main():\n\treturn 0\n", c"must borrow from")
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, ref[a] int* q, int first):\n\tif first: return p\nint main():\n\treturn 0\n", c"without returning a value")
	lifetime_case(c"refmut[a] int* bad(refmut[a] int* p, ref[a] int* q):\n\treturn p\nint main():\n\treturn 0\n", c"mutable reference return requires")
	lifetime_case(c"ref[a] int* bad():\n\tint local = 0\n\treturn &local\nint main():\n\treturn 0\n", c"returned lifetime")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nref[a] int* bad(ref[a] int* p, ref[b] int* q):\n\treturn choose(p, q, 1)\nint main():\n\treturn 0\n", c"must borrow from")
	lifetime_case(c"ref int* ambiguous(ref[a] int* p, ref[b] int* q):\n\treturn p\nint main():\n\treturn 0\n", c"exactly one borrowed parameter")


void test_named_lifetime_all_origins():
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = choose(&x, &y, 1)\n\tx = 3\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\town int* x = new int\n\town int* y = new int\n\tref int* r = choose(x, y, 1)\n\tx = new int\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\town int* x = new int\n\town int* y = new int\n\tref int* r = choose(x, y, 1)\n\town int* moved = x\n\treturn *r\n", c"moved value")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = choose(&x, &y, 1)\n\ty = 3\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\town int* x = new int\n\town int* y = new int\n\tref int* r = choose(x, y, 1)\n\ty = new int\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\town int* x = new int\n\town int* y = new int\n\tref int* r = choose(x, y, 1)\n\town int* moved = y\n\treturn *r\n", c"moved value")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = choose(&x, &y, 1)\n\tint old = *r\n\tx = 3\n\ty = 5\n\treturn old + x + y - 12\n", 0)
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tint z = 12\n\tref int* r = choose(choose(&x, &y, 1), &z, 0)\n\ty = 3\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tint z = 12\n\tref int* r = choose(&x, choose(&y, &z, 1), 0)\n\tz = 3\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = choose(&x, &y, 0)\n\tref int* s = r\n\ty = 3\n\treturn *s\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = choose(&x, &y, 0)\n\tint n = 2\n\twhile n > 0:\n\t\tn = n - 1\n\t\tint value = *r\n\t\ty = value\n\treturn 0\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tint n = 2\n\twhile n > 0:\n\t\tref int* r = choose(&x, &y, n)\n\t\tn = n - 1\n\t\tif *r: break\n\tx = 2\n\ty = 3\n\treturn x + y - 5\n", 0)


void test_named_lifetime_mutable_ancestry():
	lifetime_case(c"refmut[a] int* choose_mut(refmut[a] int* left, refmut[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\trefmut int* r = choose_mut(&x, &y, 0)\n\t*r = 9\n\treturn x + y - 13\n", 0)
	lifetime_case(c"refmut[a] int* choose_mut(refmut[a] int* left, refmut[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\trefmut int* r = choose_mut(&x, &y, 1)\n\tint value = x\n\t*r = value\n\treturn 0\n", c"conflicting")
	lifetime_case(c"refmut[a] int* choose_mut(refmut[a] int* left, refmut[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\trefmut int* r = choose_mut(&x, &y, 1)\n\tint value = y\n\t*r = value\n\treturn 0\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\trefmut int* a = &x\n\trefmut int* b = &y\n\tref int* r = choose(a, b, 1)\n\t*a = 2\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\trefmut int* a = &x\n\trefmut int* b = &y\n\tref int* r = choose(a, b, 1)\n\t*b = 2\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\trefmut int* a = &x\n\trefmut int* b = &y\n\tref int* r = choose(a, b, 0)\n\tint old = *r\n\t*a = old\n\t*b = old\n\treturn x + y - 16\n", 0)
	lifetime_case(c"refmut[a] int* choose_mut(refmut[a] int* left, refmut[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\trefmut int* r = choose_mut(&x, &x, 1)\n\treturn *r\n", c"conflicting")
	lifetime_case(c"refmut[a] int* choose_mut(refmut[a] int* left, refmut[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* a = &x\n\trefmut int* r = choose_mut(a, &y, 1)\n\treturn *r\n", c"mutable borrow from a shared")
	lifetime_case(c"refmut[a] int* choose_mut(refmut[a] int* left, refmut[a] int* right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 4\n\tint y = 8\n\tint z = 12\n\trefmut int* r = choose_mut(choose_mut(&x, &y, 1), &z, 1)\n\t*r = 5\n\treturn x + y + z - 25\n", 0)


void test_named_lifetime_calls_and_identity():
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nref[z] int* recurse(ref[z] int* a, ref[z] int* b, int n):\n\tif n == 0: return choose(a, b, 0)\n\treturn recurse(a, b, n - 1)\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = recurse(&x, &y, 3)\n\treturn *r - 8\n", 0)
	lifetime_case(c"ref[a] int* later(ref[a] int* left, ref[b] int* right);\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = later(&x, &y)\n\ty = 9\n\treturn *r + y - 13\nref[z] int* later(ref[z] int* p, ref[y] int* q):\n\treturn p\n", 0)
	lifetime_case(c"ref[a] int* later(ref[a] int* left, ref[a] int* right, int n);\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = later(&x, &y, 0)\n\treturn *r - 8\nref[z] int* later(ref[z] int* p, ref[z] int* q, int n):\n\tif n: return p\n\treturn q\n", 0)
	lifetime_case(c"ref[a] int* later(ref[a] int* left, ref[b] int* right);\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = later(&x, &y)\n\treturn *r\nref[z] int* later(ref[y] int* p, ref[z] int* q):\n\treturn q\n", c"forward declaration")
	lifetime_case(c"ref[a] int* later(ref[a] int* left, ref[a] int* right);\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = later(&x, &y)\n\treturn *r\nref[z] int* later(ref[z] int* p, ref[y] int* q):\n\treturn p\n", c"forward declaration")
	lifetime_case(c"import tests.safe_lifetime_import_fixture\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = lifetime_import_choose(&x, &y, 0)\n\treturn *r - 8\n", 0)
	lifetime_case(c"import tests.safe_lifetime_import_fixture\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = lifetime_import_choose(&x, &y, 1)\n\ty = 9\n\treturn *r\n", c"conflicting")
	lifetime_case(c"import tests.safe_lifetime_import_fixture\nint main():\n\tint x = 4\n\tint y = 8\n\trefmut int* r = lifetime_import_first(&x, &y)\n\ty = 9\n\t*r = 5\n\treturn x + y - 14\n", 0)
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint change(refmut int* p):\n\t*p = 1\n\treturn 0\nint sum(ref int* p, int n):\n\treturn *p + n\nint main():\n\tint x = 4\n\tint y = 8\n\treturn sum(choose(&x, &y, 1), change(&y))\n", c"conflicting")
	lifetime_case(c"ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):\n\tif first: return left\n\treturn right\nint change(refmut int* p, ref int* q):\n\t*p = 1\n\treturn *q\nint main():\n\tint x = 4\n\tint y = 8\n\treturn change(&y, choose(&x, &y, 1))\n", c"conflicting")


void test_named_lifetime_fail_closed():
	lifetime_case(c"ref[a] int* bad(ref[a] int* p):\n\treturn 0\nint main():\n\treturn 0\n", c"incompatible checked pointer", 1)
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, int[] s):\n\treturn s\nint main():\n\treturn 0\n", c"pointer/slice representation mismatch", 1)
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, int[] s):\n\treturn s[0:1]\nint main():\n\treturn 0\n", c"pointer/slice representation mismatch", 1)
	lifetime_case(c"ref[a] int* bad(ref[a] int* p, int[] s):\n\treturn &s.length\nint main():\n\treturn 0\n", c"buffer metadata cannot be borrowed", 1)
	lifetime_case(c"ref[a] char* bad(ref[a] int* p):\n\treturn p\nint main():\n\treturn 0\n", c"incompatible checked pointer", 1)
	lifetime_case(c"ref[a] int* bad(ref[a] int* p):\n\treturn cast(ref[a] int*, 1)\nint main():\n\treturn 0\n", c"safe:", 1)
	lifetime_case(c"ref[a] int* bad(ref[a] int* p):\n\tunsafe:\n\t\treturn p\nint main():\n\treturn 0\n", c"cannot transfer control", 1)


void test_named_lifetime_unused_declarations():
	lifetime_case(c"ref[a] int* unused(ref[a] int* left, ref[b] int* right);\nref[z] int* unused(ref[z] int* p, ref[y] int* q):\n\treturn p\nint main():\n\treturn 0\n", 0)
	lifetime_case(c"ref[a] int* unused(ref[a] int* left, ref[b] int* right);\nref[z] int* unused(ref[y] int* p, ref[z] int* q):\n\treturn q\nint main():\n\treturn 0\n", c"forward declaration")
	lifetime_case(c"ref[a] int* unused(ref[a] int* left, ref[a] int* right);\nref[z] int* unused(ref[z] int* p, ref[y] int* q):\n\treturn p\nint main():\n\treturn 0\n", c"forward declaration")
	lifetime_case(c"ref[missing] int* unused(ref[a] int* p);\nint main():\n\treturn 0\n", c"returned lifetime")


void lifetime_source_append(char** source, char* text):
	char* before = *source
	*source = strjoin(before, text)
	free(before)


void test_generated_lifetime_interactions():
	# Twelve deterministic seeds cross each backing root, either nested-call
	# position, both branch results and reversed owner construction order.
	# Each seed permits a shared read but rejects a later move or parent write.
	# Failed fixture paths include the seed and leave the source for replay.
	for seed in range(12):
		char* source = strclone(c"ref[a] int* choose(ref[a] int* x, ref[a] int* y, int first):\n\tif first: return x\n\treturn y\nint main():\n")
		if (seed % 2):
			lifetime_source_append(&source, c"\town int* z = new int\n\town int* y = new int\n\town int* x = new int\n")
		else:
			lifetime_source_append(&source, c"\town int* x = new int\n\town int* y = new int\n\town int* z = new int\n")
		lifetime_source_append(&source, c"\t*x = 2\n\t*y = 3\n\t*z = 5\n\trefmut int* rx = x\n\trefmut int* ry = y\n\trefmut int* rz = z\n")
		int first = (seed / 3) % 2
		int expected = 2
		if (seed < 6):
			if (first): lifetime_source_append(&source, c"\tref int* r = choose(choose(rx, ry, 1), rz, 1)\n")
			else:
				lifetime_source_append(&source, c"\tref int* r = choose(choose(rx, ry, 0), rz, 1)\n")
				expected = 3
		else:
			if (first):
				lifetime_source_append(&source, c"\tref int* r = choose(rx, choose(ry, rz, 1), 0)\n")
				expected = 3
			else:
				lifetime_source_append(&source, c"\tref int* r = choose(rx, choose(ry, rz, 0), 0)\n")
				expected = 5
		char* root = c"x"
		char* parent = c"rx"
		int observed = 2
		if (seed % 3 == 1):
			root = c"y"
			parent = c"ry"
			observed = 3
		elif (seed % 3 == 2):
			root = c"z"
			parent = c"rz"
			observed = 5
		char* accepted = strjoin(source, c"\tint observed = *")
		lifetime_source_append(&accepted, parent)
		lifetime_source_append(&accepted, c"\n\treturn *r + observed - ")
		char* total = itoa(expected + observed)
		lifetime_source_append(&accepted, total)
		free(total)
		lifetime_source_append(&accepted, c"\n")
		lifetime_case(accepted, 0, 0, seed)
		free(accepted)
		char* diagnostic = c"conflicting"
		if (seed % 2):
			lifetime_source_append(&source, c"\t*")
			lifetime_source_append(&source, parent)
			lifetime_source_append(&source, c" = 9\n")
		else:
			lifetime_source_append(&source, c"\town int* moved = ")
			lifetime_source_append(&source, root)
			lifetime_source_append(&source, c"\n")
			diagnostic = c"moved value"
		lifetime_source_append(&source, c"\treturn *r\n")
		lifetime_case(source, diagnostic, 0, seed)
		free(source)


void test_outlives_basics():
	lifetime_case(c"ref[b] int* shorten(ref[a] int* p) where a > b:\n\treturn p\nint main():\n\tint x = 7\n\tref int* r = shorten(&x)\n\treturn *r - 7\n", 0)
	lifetime_case(c"ref[b] int* choose_long(ref[a] int* p, ref[b] int* q, int first) where a > b:\n\tif first: return p\n\treturn q\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* a = choose_long(&x, &y, 1)\n\tref int* b = choose_long(&x, &y, 0)\n\treturn *a + *b - 12\n", 0)
	lifetime_case(c"ref[c] int* chain(ref[a] int* p, ref[b] int* q, ref[c] int* r) where a > b, b > c:\n\treturn p\nint main():\n\tint x = 4\n\tint y = 8\n\tint z = 12\n\tref int* r = chain(&x, &y, &z)\n\treturn *r - 4\n", 0)
	lifetime_case(c"type View = ref[a] int*\nref[b] int* alias(View p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* result = alias(&x)\n\treturn *result - 3\n", 0)
	lifetime_case(c"ref[b] int[] view(ref[a] int[] p) where a > b:\n\treturn p\nint main():\n\tint[2] xs\n\txs[0] = 3\n\tref int[] r = view(xs)\n\treturn r[0] - 3\n", 0)
	lifetime_case(c"optref[b] int* maybe(ref[a] int* p, int yes) where a > b:\n\tif yes: return p\n\treturn 0\nint main():\n\tint x = 3\n\toptref int* r = maybe(&x, 1)\n\tif r: return *r - 3\n\treturn 1\n", 0)
	lifetime_case(c"refmut[b] int* edit(refmut[a] int* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\trefmut int* r = edit(&x)\n\t*r = 7\n\treturn x - 7\n", 0)
	lifetime_case(c"ref[b] int* recursive(ref[a] int* p, int n) where a > b:\n\tif n: return recursive(p, n - 1)\n\treturn p\nint main():\n\tint x = 3\n\tref int* result = recursive(&x, 3)\n\treturn *result - 3\n", 0)
	lifetime_case(c"int where(int x):\n\treturn x\nint main():\n\treturn where(3) - 3\n", 0)


void test_outlives_origins():
	lifetime_case(c"ref[b] int* choose_long(ref[a] int* p, ref[b] int* q, int first) where a > b:\n\tif first: return p\n\treturn q\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = choose_long(&x, &y, 0)\n\tx = 9\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[b] int* choose_long(ref[a] int* p, ref[b] int* q, int first) where a > b:\n\tif first: return p\n\treturn q\nint main():\n\tint x = 4\n\tint y = 8\n\tref int* r = choose_long(&x, &y, 1)\n\ty = 9\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[c] int* chain(ref[a] int* p, ref[b] int* q, ref[c] int* r) where a > b, b > c:\n\treturn p\nint main():\n\tint x = 4\n\tint y = 8\n\tint z = 12\n\tref int* r = chain(&x, &y, &z)\n\tx = 3\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[b] int* shorten(ref[a] int* p) where a > b:\n\treturn p\nint main():\n\town int* x = new int\n\tref int* r = shorten(x)\n\town int* moved = x\n\treturn *r\n", c"moved value")
	lifetime_case(c"ref[b] int* shorten(ref[a] int* p) where a > b:\n\treturn p\nint main():\n\tint x = 4\n\trefmut int* parent = &x\n\tref int* r = shorten(parent)\n\t*parent = 3\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[b] int* shorten(ref[a] int* p) where a > b:\n\treturn p\nint main():\n\tint x = 4\n\trefmut int* parent = &x\n\tref int* r = shorten(parent)\n\tint old = *r\n\t*parent = 3\n\treturn x + old - 7\n", 0)
	lifetime_case(c"ref[b] int* shorten(ref[a] int* p) where a > b:\n\treturn p\nint main():\n\tint x = 4\n\tref int* r = shorten(&x)\n\tint n = 2\n\twhile n:\n\t\tint old = *r\n\t\tx = old\n\t\tn = n - 1\n\treturn 0\n", c"conflicting")
	lifetime_case(c"ref[b] int* shorten(ref[a] int* p) where a > b:\n\treturn p\nref[a] int* bad(ref[a] int* p):\n\tint local = 3\n\treturn shorten(&local)\nint main():\n\treturn 0\n", c"must borrow from")
	lifetime_case(c"ref[b] int* bad(ref[a] int* p, ref[c] int* q) where a > b:\n\treturn q\nint main():\n\treturn 0\n", c"must borrow from")
	lifetime_case(c"ref[a] int* bad(ref[b] int* p) where a > b:\n\treturn p\nint main():\n\treturn 0\n", c"returned lifetime")
	lifetime_case(c"refmut[b] int* bad(ref[a] int* p) where a > b:\n\treturn p\nint main():\n\treturn 0\n", c"mutable reference return requires")


void test_outlives_identity():
	lifetime_case(c"ref[b] int* later(ref[a] int* p) where a > b;\nint main():\n\tint x = 3\n\tref int* result = later(&x)\n\treturn *result - 3\nref[y] int* later(ref[z] int* p) where z > y:\n\treturn p\n", 0)
	lifetime_case(c"ref[c] int* later(ref[a] int* p, ref[b] int* q) where a > b, b > c;\nref[z] int* later(ref[x] int* p, ref[y] int* q) where y > z, x > z, x > y:\n\treturn p\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* result = later(&x, &y)\n\treturn *result - 3\n", 0)
	lifetime_case(c"ref[b] int* later(ref[a] int* p, ref[b] int* q) where a > b;\nref[y] int* later(ref[x] int* p, ref[y] int* q):\n\treturn q\nint main():\n\treturn 0\n", c"forward declaration")
	lifetime_case(c"ref[b] int* later(ref[a] int* p, ref[b] int* q) where a > b:\n\treturn p\nref[y] int* later(ref[x] int* p, ref[y] int* q);\nint main():\n\treturn 0\n", c"forward declaration")
	lifetime_case(c"ref[b] int* later(ref[a] int* p) where a > b:\n\treturn p\nref[y] int* later(ref[x] int* p) where x > y;\nint main():\n\tint x = 3\n\tref int* result = later(&x)\n\treturn *result - 3\n", 0)
	lifetime_case(c"ref[a] int* same(ref[a] int* p) where a > a;\nref[b] int* same(ref[b] int* p):\n\treturn p\nint main():\n\tint x = 3\n\tref int* result = same(&x)\n\treturn *result - 3\n", 0)
	lifetime_case(c"ref[b] int* cycle(ref[a] int* p, ref[b] int* q) where a > b, b > a:\n\treturn p\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* result = cycle(&x, &y)\n\treturn *result - 3\n", 0)
	lifetime_case(c"import tests.safe_outlives_import_fixture\nint main():\n\tint x = 3\n\tref int* result = outlives_import(&x)\n\treturn *result - 3\n", 0)
	lifetime_case(c"import tests.safe_outlives_import_fixture\nint main():\n\tint x = 3\n\tref int* r = outlives_import(&x)\n\tx = 4\n\treturn *r\n", c"conflicting")


void test_outlives_fail_closed():
	lifetime_case(c"ref[b] int* bad(ref[a] int* p) where missing > b:\n\treturn p\nint main():\n\treturn 0\n", c"outlives clause names no")
	lifetime_case(c"ref[b] int* bad(ref[a] int* p) where a > missing:\n\treturn p\nint main():\n\treturn 0\n", c"outlives clause names no")
	lifetime_case(c"ref[b] int* bad(ref[a] int* p) where 1 > b:\n\treturn p\nint main():\n\treturn 0\n", c"outlives clause requires")
	lifetime_case(c"ref[b] int* bad(ref[a] int* p) where a > b,:\n\treturn p\nint main():\n\treturn 0\n", c"outlives clause requires")
	lifetime_case(c"int bad(int x) where a > b:\n\treturn x\nint main():\n\treturn 0\n", c"outlives clause names no")


void test_generic_outlives():
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* r = shorten[int](&x)\n\treturn *r - 3\n", 0)
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* r = shorten[int](&x)\n\tx = 4\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* input = &x\n\tref int* r = shorten(input)\n\treturn *r - 3\n", 0)
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* input = &x\n\tref int* r = shorten(input)\n\tx = 4\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* r = shorten[int](&x)\n\tint old = *r\n\tx = 4\n\tref int* again = shorten[int](&x)\n\treturn old + *again - 7\n", 0)
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\town int* x = new int\n\tref int* r = shorten[int](x)\n\town int* moved = x\n\treturn *r\n", c"moved value")
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 4\n\trefmut int* parent = &x\n\tref int* r = shorten[int](parent)\n\t*parent = 3\n\treturn *r\n", c"conflicting")
	lifetime_case(c"ref[c] T* chain[T](ref[a] T* p, ref[b] T* q) where a > b, b > c:\n\treturn p\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* r = chain[int](&x, &y)\n\treturn *r - 3\n", 0)
	lifetime_case(c"ref[c] T* chain[T](ref[a] T* p, ref[b] T* q) where a > b, b > c:\n\treturn p\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* input = &x\n\tref int* other = &y\n\tref int* r = chain(input, other)\n\ty = 9\n\treturn *r\n", c"conflicting")
	lifetime_case(c"refmut[b] T* edit[T](refmut[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\trefmut int* r = edit[int](&x)\n\t*r = 7\n\treturn x - 7\n", 0)
	lifetime_case(c"refmut[b] T* edit[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\trefmut int* r = edit[int](&x)\n\treturn *r\n", c"mutable reference return requires")
	lifetime_case(c"ref[b] T* recurse[T](ref[a] T* p, int n) where a > b:\n\tif n: return recurse[T](p, n - 1)\n\treturn p\nint main():\n\tint x = 3\n\tref int* r = recurse[int](&x, 2)\n\treturn *r - 3\n", 0)
	lifetime_case(c"ref[b] T* bad[T](ref[a] T* p) where missing > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* r = bad[int](&x)\n\treturn *r\n", c"outlives clause names no")
	lifetime_case(c"ref[b] T* bad[T](ref[a] T* p) where a > b:\n\tT local = 3\n\treturn &local\nint main():\n\tint x = 3\n\tref int* r = bad[int](&x)\n\treturn *r\n", c"must borrow from")
	lifetime_case(c"type Input = ref[a] int*\nref[b] T* alias[T](Input p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tref int* r = alias[int](&x)\n\treturn *r - 3\n", 0)
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nref[y] T* outer[T](ref[x] T* p) where x > y:\n\treturn shorten[T](p)\nint main():\n\tint x = 3\n\tref int* r = outer[int](&x)\n\treturn *r - 3\n", 0)
	lifetime_case(c"ref[b] T* shorten[T](ref[a] T* p) where a > b:\n\treturn p\nint main():\n\tint x = 3\n\tchar ch = 65\n\tref int* r = shorten[int](&x)\n\tref char* c = shorten[char](&ch)\n\treturn *r + cast(int, *c) - 68\n", 0)
	lifetime_case(c"import tests.safe_outlives_import_fixture\nint main():\n\tint x = 3\n\tref int* r = generic_outlives_import[int](&x)\n\treturn *r - 3\n", 0)
	lifetime_case(c"import tests.safe_outlives_import_fixture\nint main():\n\tint x = 3\n\tref int* input = &x\n\tref int* r = generic_outlives_import(input)\n\tx = 4\n\treturn *r - 3\n", c"conflicting")
