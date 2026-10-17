# wbuild: x64
# wbuild: deps=tests/safe_nested_aggregate_import_fixture.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int nested_aggregate_case_number


void nested_aggregate_result(process_result* result, char* diagnostic, int checking, char* path):
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


void nested_aggregate_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	nested_aggregate_case_number = nested_aggregate_case_number + 1
	char* number = itoa(nested_aggregate_case_number)
	char* prefix = c"bin/nested_aggregate_case32_"
	if (__word_size__ == 8): prefix = c"bin/nested_aggregate_case64_"
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
		nested_aggregate_result(checked, diagnostic, 1, full)
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
		nested_aggregate_result(compiled, diagnostic, 0, full)
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


void test_nested_borrowed_records():
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x, 3), 5)\n\tref[b] Inner inner = outer.inner\n\tref int* p = inner.item\n\treturn *p + inner.tag + outer.tag - 15\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x, 3), 5)\n\treturn outer.inner.tag + outer.tag - 8\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nref[a] Outer make(ref[a] int* p):\n\treturn Outer(Inner(p, 3), 5)\nref[a] int* get(ref[a] Outer value):\n\treturn value.inner.item\nint main():\n\tint x = 7\n\tref[a] Outer outer = make(&x)\n\tref int* p = get(outer)\n\treturn *p - 7\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x, 3), 5)\n\tref int* p = outer.inner.item\n\tx = 8\n\treturn *p\n", c"conflicting")
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nref[a] int* bad(ref[a] Outer outer):\n\treturn &outer.inner.tag\nint main():\n\treturn 0\n", c"descriptor fields cannot be borrowed")
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x), 5)\n\treturn 0\n", c"constructor expects 2 arguments")
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nref[a] Outer bad(ref[a] int* p):\n\tint local = 3\n\treturn Outer(Inner(&local, 3), 5)\nint main():\n\treturn 0\n", c"must borrow from")


void test_nested_record_origins():
	nested_aggregate_case(c"struct Inner:\n\trefmut[cell] int* item\n\tint tag\nstruct Outer:\n\trefmut[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Outer outer = Outer(Inner(&x, 3), 5)\n\trefmut int* p = outer.inner.item\n\t*p = 11\n\treturn x - 11\n", 0)
	nested_aggregate_case(c"struct Inner:\n\trefmut[cell] int* item\n\tint tag\nstruct Outer:\n\trefmut[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\trefmut int* parent = &x\n\trefmut[a] Outer outer = Outer(Inner(parent, 3), 5)\n\trefmut int* p = outer.inner.item\n\t*parent = 9\n\treturn *p\n", c"conflicting")
	nested_aggregate_case(c"struct Inner:\n\trefmut[cell] int* item\n\tint tag\nstruct Outer:\n\trefmut[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x, 3), 5)\n\treturn 0\n", c"named shared-reference group")
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tref[group] int* sibling\n\tint tag\nint main():\n\tint x = 7\n\tint y = 9\n\tref[a] Outer outer = Outer(Inner(&x, 3), &y, 5)\n\tref int* p = outer.inner.item\n\ty = 4\n\treturn *p\n", c"conflicting")
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x, 3), 5)\n\tref int* p = outer.inner.item\n\tint old = *p\n\tx = 11\n\treturn old + x - 18\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nref[a] Outer copy(ref[a] Outer value):\n\treturn value\nint main():\n\tint x = 7\n\tref[a] Outer outer = copy(Outer(Inner(&x, 3), 5))\n\tref int* p = outer.inner.item\n\treturn *p + outer.inner.tag + outer.tag - 15\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint mutate(refmut int* p):\n\t*p = 9\n\treturn 5\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x, 3), mutate(&x))\n\treturn outer.tag\n", c"conflicting")
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tOuter raw = Outer(Inner(&x, 3), 5)\n\treturn 0\n", c"unsupported type")
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\ntype Copy = fn[a](ref[a] Outer) -> ref[a] Outer\nref[b] Outer copy(ref[b] Outer value):\n\treturn value\nint main():\n\tCopy* f = copy\n\tint x = 7\n\tref[a] Outer outer = f(Outer(Inner(&x, 3), 5))\n\tref int* p = outer.inner.item\n\treturn *p + outer.inner.tag + outer.tag - 15\n", 0)


void test_nested_record_boundaries():
	nested_aggregate_case(c"import tests.safe_nested_aggregate_import_fixture\nint main():\n\tint x = 7\n\tint[2] values\n\tvalues[0] = 9\n\tref[a] NestedView view = nested_view_copy(nested_view_make(&x, values))\n\tref int* p = view.cell.value\n\tref int[] data = view.data\n\treturn *p + view.cell.tag + view.tag + data[0] + data.length - 26\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nref[a] Outer make(ref[a] int* p):\n\treturn Outer(Inner(p, 3), 5)\nint main():\n\tint x = 7\n\treturn make(&x).inner.tag - 3\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nref[a] Outer later(ref[a] int* p);\nint main():\n\tint x = 7\n\tref[a] Outer outer = later(&x)\n\tref int* p = outer.inner.item\n\treturn *p - 7\nref[z] Outer later(ref[z] int* p):\n\treturn Outer(Inner(p, 3), 5)\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\ntype InnerAlias = ref[inner] Inner\nstruct AliasOuter:\n\tInnerAlias inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] AliasOuter outer = AliasOuter(Inner(&x, 3), 5)\n\tref int* p = outer.inner.item\n\treturn *p - 7\n", 0)
	nested_aggregate_case(c"struct Inner:\n\trefmut[cell] int* item\n\tint tag\nstruct Outer:\n\trefmut[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Outer outer = Outer(Inner(&x, 3), 5)\n\touter.inner.tag = 9\n\treturn outer.inner.tag - 9\n", 0)
	nested_aggregate_case(c"struct Inner:\n\tref[cell] int* item\n\tint tag\nstruct Outer:\n\tref[group] Inner inner\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Outer outer = Outer(Inner(&x, 3), 5)\n\trefmut int* p = outer.inner.item\n\treturn 0\n", c"mutable borrow from a shared")
	nested_aggregate_case(c"struct Deep0:\n\tref[field] int* p\nstruct Deep1:\n\tref[field] Deep0 child\nstruct Deep2:\n\tref[field] Deep1 child\nstruct Deep3:\n\tref[field] Deep2 child\nstruct Deep4:\n\tref[field] Deep3 child\nstruct Deep5:\n\tref[field] Deep4 child\nstruct Deep6:\n\tref[field] Deep5 child\nstruct Deep7:\n\tref[field] Deep6 child\nstruct Deep8:\n\tref[field] Deep7 child\nstruct Deep9:\n\tref[field] Deep8 child\nstruct Deep10:\n\tref[field] Deep9 child\nstruct Deep11:\n\tref[field] Deep10 child\nstruct Deep12:\n\tref[field] Deep11 child\nstruct Deep13:\n\tref[field] Deep12 child\nstruct Deep14:\n\tref[field] Deep13 child\nstruct Deep15:\n\tref[field] Deep14 child\nstruct Deep16:\n\tref[field] Deep15 child\nstruct Deep17:\n\tref[field] Deep16 child\nstruct Deep18:\n\tref[field] Deep17 child\nstruct Deep19:\n\tref[field] Deep18 child\nstruct Deep20:\n\tref[field] Deep19 child\nstruct Deep21:\n\tref[field] Deep20 child\nstruct Deep22:\n\tref[field] Deep21 child\nstruct Deep23:\n\tref[field] Deep22 child\nstruct Deep24:\n\tref[field] Deep23 child\nstruct Deep25:\n\tref[field] Deep24 child\nstruct Deep26:\n\tref[field] Deep25 child\nstruct Deep27:\n\tref[field] Deep26 child\nstruct Deep28:\n\tref[field] Deep27 child\nstruct Deep29:\n\tref[field] Deep28 child\nstruct Deep30:\n\tref[field] Deep29 child\nstruct Deep31:\n\tref[field] Deep30 child\nstruct Deep32:\n\tref[field] Deep31 child\nstruct Deep33:\n\tref[field] Deep32 child\nstruct Deep34:\n\tref[field] Deep33 child\nint inspect(ref[a] Deep34 value):\n\treturn 0\nint main():\n\treturn 0\n", c"named shared-reference group")
	nested_aggregate_case(c"struct Wide0:\n\tref[field] int* p\nstruct Wide1:\n\tref[field] Wide0 first\n\tref[field] Wide0 second\nstruct Wide2:\n\tref[field] Wide1 first\n\tref[field] Wide1 second\nstruct Wide3:\n\tref[field] Wide2 first\n\tref[field] Wide2 second\nstruct Wide4:\n\tref[field] Wide3 first\n\tref[field] Wide3 second\nstruct Wide5:\n\tref[field] Wide4 first\n\tref[field] Wide4 second\nstruct Wide6:\n\tref[field] Wide5 first\n\tref[field] Wide5 second\nstruct Wide7:\n\tref[field] Wide6 first\n\tref[field] Wide6 second\nstruct Wide8:\n\tref[field] Wide7 first\n\tref[field] Wide7 second\nstruct Wide9:\n\tref[field] Wide8 first\n\tref[field] Wide8 second\nint inspect(ref[a] Wide9 value):\n\treturn 0\nint main():\n\treturn 0\n", c"named shared-reference group")


void test_nested_record_branch_origins():
	nested_aggregate_case(c"struct Cell:\n\tref[item] int* value\nstruct Pair:\n\tref[group] Cell cell\nref[a] Pair choose(ref[a] Pair left, ref[a] Pair right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 3\n\tint y = 7\n\tref[a] Pair pair = choose(Pair(Cell(&x)), Pair(Cell(&y)), 0)\n\tref int* p = pair.cell.value\n\treturn *p - 7\n", 0)
	nested_aggregate_case(c"struct Cell:\n\tref[item] int* value\nstruct Pair:\n\tref[group] Cell cell\nref[a] Pair choose(ref[a] Pair left, ref[a] Pair right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 3\n\tint y = 7\n\tref[a] Pair pair = choose(Pair(Cell(&x)), Pair(Cell(&y)), 0)\n\tref int* p = pair.cell.value\n\tx = 11\n\treturn *p\n", c"conflicting")
	nested_aggregate_case(c"struct Cell:\n\tref[item] int* value\nstruct Pair:\n\tref[group] Cell cell\nref[a] Pair choose(ref[a] Pair left, ref[a] Pair right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint x = 3\n\tint y = 7\n\tref[a] Pair pair = choose(Pair(Cell(&x)), Pair(Cell(&y)), 0)\n\tref int* p = pair.cell.value\n\ty = 11\n\treturn *p\n", c"conflicting")
