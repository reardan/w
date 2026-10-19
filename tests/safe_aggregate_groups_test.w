# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int aggregate_groups_case_number


void aggregate_groups_result(process_result* result, char* diagnostic, int checking, char* path):
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


void aggregate_groups_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	aggregate_groups_case_number = aggregate_groups_case_number + 1
	char* number = itoa(aggregate_groups_case_number)
	char* prefix = c"bin/aggregate_groups_case32_"
	if (__word_size__ == 8): prefix = c"bin/aggregate_groups_case64_"
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
		aggregate_groups_result(checked, diagnostic, 1, full)
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
		aggregate_groups_result(compiled, diagnostic, 0, full)
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


void test_independent_groups_0():
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\tref int* p = pair.first\n\ty = 9\n\treturn *p + y - 12\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\tref int* p = pair.first\n\tx = 9\n\treturn *p\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\trefmut[left] int* first\n\trefmut[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\trefmut[a,b] Pair pair = Pair(&x, &y)\n\trefmut int* p = pair.first\n\trefmut int* q = pair.second\n\t*p = 5\n\t*q = 6\n\treturn x + y - 11\n", 0)
	aggregate_groups_case(c"struct Pair:\n\trefmut[left] int* first\n\trefmut[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\trefmut[a,b] Pair pair = Pair(&x, &y)\n\tref int* p = pair.first\n\tref int* q = pair.first\n\treturn *p + *q - 6\n", 0)
	aggregate_groups_case(c"struct Pair:\n\trefmut[left] int* first\n\trefmut[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\trefmut[a,b] Pair pair = Pair(&x, &y)\n\trefmut int* p = pair.first\n\trefmut int* q = pair.first\n\treturn *p + *q\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair make(ref[a] int* x, ref[b] int* y):\n\treturn Pair(x, y)\nref[a] int* first(ref[a,b] Pair pair):\n\treturn pair.first\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = make(&x, &y)\n\tref int* p = first(pair)\n\ty = 9\n\treturn *p + y - 12\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a] int* first(ref[a,b] Pair pair):\n\treturn pair.second\nint main():\n\treturn 0\n", c"must borrow from")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair make(ref[a] int* x, ref[b] int* y):\n\treturn Pair(y, x)\nint main():\n\treturn 0\n", c"must borrow from")


void test_independent_groups_1():
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair bad(ref[a] int* x, ref[b] int* y):\n\tint local = 0\n\treturn Pair(x, &local)\nint main():\n\treturn 0\n", c"must borrow from")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair make(ref[a] int* x, ref[b] int* y):\n\treturn Pair(x, y)\nref[a] int* first(ref[a,b] Pair pair):\n\treturn pair.first\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* p = first(make(&x, &y))\n\ty = 9\n\treturn *p + y - 12\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair make(ref[a] int* x, ref[b] int* y):\n\treturn Pair(x, y)\nref[a] int* get(ref[a,b] Pair pair) where b > a:\n\treturn pair.second\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* p = get(make(&x, &y))\n\tx = 7\n\treturn *p\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair make(ref[a] int* x, ref[b] int* y):\n\treturn Pair(x, y)\nref[b] int* get(ref[a,b] Pair pair):\n\treturn pair.second\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* p = get(make(&x, &y))\n\tx = 7\n\treturn *p + x - 11\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nstruct Outer:\n\tref[right,left] Pair pair\n\tref[left] int* extra\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\tref[a,b] Outer outer = Outer(Pair(&x, &y), &z)\n\tref int* p = outer.pair.first\n\ty = 7\n\tz = 8\n\treturn *p + y + z - 18\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nstruct Outer:\n\tref[right,left] Pair pair\n\tref[left] int* extra\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\tref[a,b] Outer outer = Outer(Pair(&x, &y), &z)\n\tref int* p = outer.pair.second\n\tz = 8\n\treturn *p\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nstruct Outer:\n\tref[both,both] Pair pair\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a] Outer outer = Outer(Pair(&x, &y))\n\tref int* p = outer.pair.first\n\ty = 9\n\treturn *p\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a] Pair pair = Pair(&x, &y)\n\treturn 0\n", c"lifetime arity")


void test_independent_groups_2():
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref Pair pair = Pair(&x, &y)\n\treturn 0\n", c"lifetime arity")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b,c] Pair pair = Pair(&x, &y)\n\treturn 0\n", c"lifetime arity")
	aggregate_groups_case(c"int main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] int* p = &x\n\treturn *p\n", c"multiple lifetime labels")
	aggregate_groups_case(c"int main():\n\tint[2] xs\n\tref[a,b] int[] view = xs\n\treturn view.length\n", c"multiple lifetime labels")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\ntype Select = fn[a,b](ref[a,b] Pair) -> ref[a] int*\nref[a] int* first(ref[a,b] Pair pair):\n\treturn pair.first\nint main():\n\tint x = 3\n\tint y = 4\n\tSelect* select = first\n\tref[a,b] Pair pair = Pair(&x, &y)\n\tref int* p = select(pair)\n\ty = 9\n\treturn *p + y - 12\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\ntype Select = fn[a,b](ref[a,b] Pair) -> ref[b] int*\nref[a] int* first(ref[a,b] Pair pair):\n\treturn pair.first\nint main():\n\tint x = 3\n\tint y = 4\n\tSelect* select = first\n\treturn 0\n", c"contract")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\ntype Select = fn[a](ref[a,b] Pair) -> ref[a] int*\nint main():\n\treturn 0\n", c"quantified")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a] int* first(ref[a,b] Pair pair);\nref[x] int* first(ref[x,y] Pair pair):\n\treturn pair.first\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\tref int* p = first(pair)\n\treturn *p - 3\n", 0)


void test_independent_groups_3():
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a] int* first(ref[a,b] Pair pair);\nref[y] int* first(ref[x,y] Pair pair):\n\treturn pair.second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\tref int* p = first(pair)\n\treturn *p - 3\n", c"disagrees")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\noptref[a] int* maybe(ref[a,b] Pair pair, int take):\n\tif (take): return pair.first\n\treturn 0\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\toptref int* p = maybe(pair, 1)\n\ty = 9\n\tif (p): return *p + y - 12\n\treturn 1\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\noptref[a] int* maybe(ref[a,b] Pair pair):\n\treturn pair.second\nint main():\n\treturn 0\n", c"must borrow from")


void test_group_flow_0():
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a] int* select(ref[a,b] Pair pair, int choose):\n\tif (choose): return pair.first\n\treturn pair.second\nint main():\n\treturn 0\n", c"must borrow from")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair select(ref[a,b] Pair one, ref[a,b] Pair two, int choose):\n\tif (choose): return one\n\treturn two\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\tint w = 6\n\tref[a,b] Pair pair = select(Pair(&x, &y), Pair(&z, &w), 1)\n\tref int* p = pair.first\n\ty = 7\n\tw = 8\n\treturn *p + y + w - 18\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nref[a,b] Pair select(ref[a,b] Pair one, ref[a,b] Pair two, int choose):\n\tif (choose): return one\n\treturn two\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\tint w = 6\n\tref[a,b] Pair pair = select(Pair(&x, &y), Pair(&z, &w), 1)\n\tref int* p = pair.first\n\tz = 9\n\treturn *p\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\trefmut[left] int* first\n\trefmut[right] int* second\nstruct Outer:\n\trefmut[x,y] Pair pair\nint main():\n\tint x = 3\n\tint y = 4\n\trefmut[a,b] Outer outer = Outer(Pair(&x, &y))\n\trefmut int* p = outer.pair.first\n\trefmut int* q = outer.pair.second\n\t*p = 5\n\t*q = 7\n\treturn x + y - 12\n", 0)
	aggregate_groups_case(c"struct Pair:\n\trefmut[left] int* first\n\trefmut[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\trefmut int* parent = &x\n\trefmut[a,b] Pair pair = Pair(parent, &y)\n\trefmut int* p = pair.first\n\t*parent = 7\n\treturn *p\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\trefmut[left] int* first\n\trefmut[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\trefmut[a,b] Pair pair = Pair(&x, &x)\n\treturn 0\n", c"conflicting")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\trefmut int* p = pair.first\n\treturn 0\n", c"mutable borrow from a shared")
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\tref int* address = &pair.first\n\treturn 0\n", c"descriptor fields")


void test_group_flow_1():
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(&x, &y)\n\tfor i in range(3):\n\t\tref int* p = pair.first\n\t\tint value = *p\n\t\tif (value != 3): return 1\n\treturn 0\n", 0)
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\ntype Alias = Pair\ntype View = ref[a,b] Alias\nint main():\n\tint x = 3\n\tint y = 4\n\tView pair = Pair(&x, &y)\n\tref int* p = pair.second\n\tx = 8\n\treturn *p + x - 12\n", 0)
	aggregate_groups_case(c"struct Wide:\n\tref[g0] int* p0\n\tref[g1] int* p1\n\tref[g2] int* p2\n\tref[g3] int* p3\n\tref[g4] int* p4\n\tref[g5] int* p5\n\tref[g6] int* p6\n\tref[g7] int* p7\n\tref[g8] int* p8\n\tref[g9] int* p9\n\tref[g10] int* p10\n\tref[g11] int* p11\n\tref[g12] int* p12\n\tref[g13] int* p13\n\tref[g14] int* p14\n\tref[g15] int* p15\n\tref[g16] int* p16\n\tref[g17] int* p17\n\tref[g18] int* p18\n\tref[g19] int* p19\n\tref[g20] int* p20\n\tref[g21] int* p21\n\tref[g22] int* p22\n\tref[g23] int* p23\n\tref[g24] int* p24\n\tref[g25] int* p25\n\tref[g26] int* p26\n\tref[g27] int* p27\n\tref[g28] int* p28\n\tref[g29] int* p29\n\tref[g30] int* p30\nref[g30] int* last(ref[g0,g1,g2,g3,g4,g5,g6,g7,g8,g9,g10,g11,g12,g13,g14,g15,g16,g17,g18,g19,g20,g21,g22,g23,g24,g25,g26,g27,g28,g29,g30] Wide value):\n\treturn value.p30\nint main():\n\treturn 0\n", 0)
	aggregate_groups_case(c"struct Wide:\n\tref[g0] int* p0\n\tref[g1] int* p1\n\tref[g2] int* p2\n\tref[g3] int* p3\n\tref[g4] int* p4\n\tref[g5] int* p5\n\tref[g6] int* p6\n\tref[g7] int* p7\n\tref[g8] int* p8\n\tref[g9] int* p9\n\tref[g10] int* p10\n\tref[g11] int* p11\n\tref[g12] int* p12\n\tref[g13] int* p13\n\tref[g14] int* p14\n\tref[g15] int* p15\n\tref[g16] int* p16\n\tref[g17] int* p17\n\tref[g18] int* p18\n\tref[g19] int* p19\n\tref[g20] int* p20\n\tref[g21] int* p21\n\tref[g22] int* p22\n\tref[g23] int* p23\n\tref[g24] int* p24\n\tref[g25] int* p25\n\tref[g26] int* p26\n\tref[g27] int* p27\n\tref[g28] int* p28\n\tref[g29] int* p29\n\tref[g30] int* p30\n\tref[g31] int* p31\nref[g30] int* last(ref[g0,g1,g2,g3,g4,g5,g6,g7,g8,g9,g10,g11,g12,g13,g14,g15,g16,g17,g18,g19,g20,g21,g22,g23,g24,g25,g26,g27,g28,g29,g30,g31] Wide value):\n\treturn value.p30\nint main():\n\treturn 0\n", c"32 expanded lifetime slots")
	aggregate_groups_case(c"struct Wide:\n\tref[g0] int* p0\n\tref[g1] int* p1\n\tref[g2] int* p2\n\tref[g3] int* p3\n\tref[g4] int* p4\n\tref[g5] int* p5\n\tref[g6] int* p6\n\tref[g7] int* p7\n\tref[g8] int* p8\n\tref[g9] int* p9\n\tref[g10] int* p10\n\tref[g11] int* p11\n\tref[g12] int* p12\n\tref[g13] int* p13\n\tref[g14] int* p14\n\tref[g15] int* p15\n\tref[g16] int* p16\n\tref[g17] int* p17\n\tref[g18] int* p18\n\tref[g19] int* p19\n\tref[g20] int* p20\n\tref[g21] int* p21\n\tref[g22] int* p22\n\tref[g23] int* p23\n\tref[g24] int* p24\n\tref[g25] int* p25\n\tref[g26] int* p26\n\tref[g27] int* p27\n\tref[g28] int* p28\n\tref[g29] int* p29\n\tref[g30] int* p30\n\tref[g31] int* p31\n\tref[g32] int* p32\nref[g30] int* last(ref[g0,g1,g2,g3,g4,g5,g6,g7,g8,g9,g10,g11,g12,g13,g14,g15,g16,g17,g18,g19,g20,g21,g22,g23,g24,g25,g26,g27,g28,g29,g30,g31,g32] Wide value):\n\treturn value.p30\nint main():\n\treturn 0\n", c"32 lifetime groups")




# Coverage-drive addition: duplicate named initialization of a borrowed
# aggregate (compiler/safe.w safe_record_construct).
void test_borrowed_aggregate_duplicate_initializer():
	aggregate_groups_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nvoid checked(ref int* p):\n\tpass\nint main():\n\tint x = 3\n\tint y = 4\n\tref[a,b] Pair pair = Pair(first: &x, first: &y)\n\treturn 0\n", c"safe: borrowed aggregate field initialized twice")
