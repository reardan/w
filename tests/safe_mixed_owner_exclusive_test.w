# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int mixed_exclusive_case_number


void mixed_exclusive_result(process_result* result, char* diagnostic, int checking, char* path):
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


void mixed_exclusive_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	mixed_exclusive_case_number = mixed_exclusive_case_number + 1
	char* number = itoa(mixed_exclusive_case_number)
	char* prefix = c"bin/mixed_exclusive_case32_"
	if (__word_size__ == 8): prefix = c"bin/mixed_exclusive_case64_"
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
		mixed_exclusive_result(checked, diagnostic, 1, full)
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
		mixed_exclusive_result(compiled, diagnostic, 0, full)
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


void test_exclusive_mixed_0():
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\trefmut int* p = holder.view\n\t*p = 8\n\treturn x - 8\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tint old = x\n\tref int* p = holder.view\n\treturn *p + old\n", c"conflicting")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tx = 8\n\tref int* p = holder.view\n\treturn *p\n", c"conflicting")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nrefmut[a] int* take(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\trefmut int* p = take(holder)\n\t*p = 7\n\treturn x - 7\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nrefmut[a] int* take(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* child = holder.view\n\trefmut int* p = take(holder)\n\treturn *child + *p\n", c"conflicting")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nrefmut[a] int* take(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\trefmut int* child = holder.view\n\town[a] Mixed* moved = holder\n\treturn *child\n", c"conflicting")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nrefmut[a] int* take(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* child = holder.view\n\tint value = *child\n\town[a] Mixed* moved = holder\n\trefmut int* p = take(moved)\n\t*p = value + 2\n\treturn x - 5\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tholder = make(&x)\n\trefmut int* p = holder.view\n\t*p = 8\n\treturn x - 8\n", 0)

void test_exclusive_mixed_1():
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* child = holder.view\n\tholder = make(&x)\n\treturn *child\n", c"conflicting")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tfor i in range(3):\n\t\trefmut int* p = holder.view\n\t\t*p += 1\n\t\tholder = make(&x)\n\treturn x - 6\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\tref int* p = view.view\n\treturn *p - 3\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\trefmut int* p = view.view\n\treturn 0\n", c"shared")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nrefmut[a] int* bad(ref[a] Mixed* holder):\n\treturn holder.view\nint main():\n\treturn 0\n", c"mutable borrowed parameter")
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = make(&x, &y)\n\tint value = y\n\trefmut int* p = holder.first\n\t*p = value + 1\n\treturn x - 5\n", 0)
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nint main():\n\tint x = 3\n\tint y = 4\n\tref int* shared = &y\n\town[a,b] Wide* holder = make(&x, shared)\n\tint value = *shared\n\trefmut int* p = holder.first\n\t*p = value + 1\n\treturn x - 5\n", 0)
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nref[b] int* second(own[a,b] Wide* holder):\n\treturn holder.second\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = make(&x, &y)\n\tref int* p = second(holder)\n\tx = 9\n\treturn *p + x - 13\n", 0)

void test_exclusive_mixed_2():
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nrefmut[b] int* bad(own[a,b] Wide* holder):\n\treturn holder.second\nint main():\n\treturn 0\n", c"mutable borrowed parameter")
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nrefmut[a] int* first(own[a,b] Wide* holder):\n\treturn holder.first\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = make(&x, &y)\n\trefmut int* p = first(holder)\n\ty = 9\n\t*p = 8\n\treturn x + y - 17\n", 0)
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nown[a,b] Wide* bad(ref[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nint main():\n\treturn 0\n", c"mutable borrowed parameter")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nown[a] Mixed* bad(refmut[a] int* input):\n\tint local = 3\n\treturn new Mixed(new int, &local)\nint main():\n\treturn 0\n", c"must borrow from")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint read_value(ref int* p):\n\treturn *p\nown[a] Mixed* bad(refmut[a] int* input):\n\tdefer read_value(input)\n\treturn new Mixed(new int, input)\nint main():\n\treturn 0\n", c"conflicting")
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nint read_value(ref int* p):\n\treturn *p\nown[a,b] Wide* good(refmut[a] int* first, ref[b] int* second):\n\tdefer read_value(second)\n\treturn new Wide(new int, first, second)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = good(&x, &y)\n\trefmut int* p = holder.first\n\t*p = 8\n\treturn x - 8\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint read_value(ref int* p):\n\treturn *p\nint take(own[a] Mixed* holder, int after):\n\tref int* p = holder.view\n\treturn *p + after\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\treturn take(holder, read_value(&x))\n", c"conflicting")
	mixed_exclusive_case(c"struct Wide:\n\town int* stored\n\trefmut[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(refmut[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nint read_value(ref int* p):\n\treturn *p\nint take(own[a,b] Wide* holder, int after):\n\tref int* p = holder.first\n\treturn *p + after\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = make(&x, &y)\n\treturn take(holder, read_value(&y)) - 7\n", 0)

void test_exclusive_mixed_3():
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[data] Mixed* child\n\tint tag\nrefmut[a] int* take(own[a] Outer* outer):\n\treturn outer.child.view\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(make(&x), 1)\n\trefmut int* p = take(outer)\n\t*p = 8\n\treturn x - 8\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[data] Mixed* child\n\tint tag\nint read_value(ref int* p):\n\treturn *p\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\town[a] Outer* outer = new Outer(holder, read_value(&x))\n\treturn 0\n", c"conflicting")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nrefmut[a] int* take(own[a] Mixed* holder):\n\treturn holder.view\ntype Take = fn[a](own[a] Mixed*) -> refmut[a] int*\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tTake* extract = take\n\trefmut int* p = extract(holder)\n\t*p = 8\n\treturn x - 8\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nrefmut[a] int* take(own[a] Mixed* holder):\n\treturn holder.view\nown[a] T* pass[T](own[a] T* owner):\n\treturn owner\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\trefmut int* p = take(pass[Mixed](holder))\n\t*p = 8\n\treturn x - 8\n", 0)
	mixed_exclusive_case(c"struct MutableView:\n\trefmut[data] int* p\nstruct Holder:\n\town int* stored\n\trefmut[data] MutableView view\nrefmut[a] MutableView take(own[a] Holder* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\town[a] Holder* holder = new Holder(new int, MutableView(&x))\n\trefmut[a] MutableView view = take(holder)\n\trefmut int* p = view.p\n\t*p = 8\n\treturn x - 8\n", 0)
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* child = holder.view\n\town[a] Mixed* moved = holder\n\treturn *child\n", c"conflicting")
	mixed_exclusive_case(c"struct Many:\n\town int* stored\n\tref[g0] int* p0\n\tref[g1] int* p1\n\tref[g2] int* p2\n\tref[g3] int* p3\n\tref[g4] int* p4\n\tref[g5] int* p5\n\tref[g6] int* p6\n\tref[g7] int* p7\n\tref[g8] int* p8\n\tref[g9] int* p9\n\tref[g10] int* p10\n\tref[g11] int* p11\n\tref[g12] int* p12\n\tref[g13] int* p13\n\tref[g14] int* p14\n\tref[g15] int* p15\n\tref[g16] int* p16\n\tref[g17] int* p17\n\tref[g18] int* p18\n\tref[g19] int* p19\n\tref[g20] int* p20\n\tref[g21] int* p21\n\tref[g22] int* p22\n\tref[g23] int* p23\n\tref[g24] int* p24\n\tref[g25] int* p25\n\tref[g26] int* p26\n\tref[g27] int* p27\n\tref[g28] int* p28\n\tref[g29] int* p29\n\tref[g30] int* p30\n\trefmut[g31] int* p31\nint main():\n\tint x0 = 0\n\tint x1 = 1\n\tint x2 = 2\n\tint x3 = 3\n\tint x4 = 4\n\tint x5 = 5\n\tint x6 = 6\n\tint x7 = 7\n\tint x8 = 8\n\tint x9 = 9\n\tint x10 = 10\n\tint x11 = 11\n\tint x12 = 12\n\tint x13 = 13\n\tint x14 = 14\n\tint x15 = 15\n\tint x16 = 16\n\tint x17 = 17\n\tint x18 = 18\n\tint x19 = 19\n\tint x20 = 20\n\tint x21 = 21\n\tint x22 = 22\n\tint x23 = 23\n\tint x24 = 24\n\tint x25 = 25\n\tint x26 = 26\n\tint x27 = 27\n\tint x28 = 28\n\tint x29 = 29\n\tint x30 = 30\n\tint x31 = 31\n\town[g0,g1,g2,g3,g4,g5,g6,g7,g8,g9,g10,g11,g12,g13,g14,g15,g16,g17,g18,g19,g20,g21,g22,g23,g24,g25,g26,g27,g28,g29,g30,g31] Many* holder = new Many(new int, &x0, &x1, &x2, &x3, &x4, &x5, &x6, &x7, &x8, &x9, &x10, &x11, &x12, &x13, &x14, &x15, &x16, &x17, &x18, &x19, &x20, &x21, &x22, &x23, &x24, &x25, &x26, &x27, &x28, &x29, &x30, &x31)\n\tint first = x0\n\trefmut int* p = holder.p31\n\t*p = 8\n\treturn x31 + first - 8\n", 0)
	mixed_exclusive_case(c"struct Many:\n\town int* stored\n\tref[g0] int* p0\n\tref[g1] int* p1\n\tref[g2] int* p2\n\tref[g3] int* p3\n\tref[g4] int* p4\n\tref[g5] int* p5\n\tref[g6] int* p6\n\tref[g7] int* p7\n\tref[g8] int* p8\n\tref[g9] int* p9\n\tref[g10] int* p10\n\tref[g11] int* p11\n\tref[g12] int* p12\n\tref[g13] int* p13\n\tref[g14] int* p14\n\tref[g15] int* p15\n\tref[g16] int* p16\n\tref[g17] int* p17\n\tref[g18] int* p18\n\tref[g19] int* p19\n\tref[g20] int* p20\n\tref[g21] int* p21\n\tref[g22] int* p22\n\tref[g23] int* p23\n\tref[g24] int* p24\n\tref[g25] int* p25\n\tref[g26] int* p26\n\tref[g27] int* p27\n\tref[g28] int* p28\n\tref[g29] int* p29\n\tref[g30] int* p30\n\trefmut[g31] int* p31\nint main():\n\tint x0 = 0\n\tint x1 = 1\n\tint x2 = 2\n\tint x3 = 3\n\tint x4 = 4\n\tint x5 = 5\n\tint x6 = 6\n\tint x7 = 7\n\tint x8 = 8\n\tint x9 = 9\n\tint x10 = 10\n\tint x11 = 11\n\tint x12 = 12\n\tint x13 = 13\n\tint x14 = 14\n\tint x15 = 15\n\tint x16 = 16\n\tint x17 = 17\n\tint x18 = 18\n\tint x19 = 19\n\tint x20 = 20\n\tint x21 = 21\n\tint x22 = 22\n\tint x23 = 23\n\tint x24 = 24\n\tint x25 = 25\n\tint x26 = 26\n\tint x27 = 27\n\tint x28 = 28\n\tint x29 = 29\n\tint x30 = 30\n\tint x31 = 31\n\town[g0,g1,g2,g3,g4,g5,g6,g7,g8,g9,g10,g11,g12,g13,g14,g15,g16,g17,g18,g19,g20,g21,g22,g23,g24,g25,g26,g27,g28,g29,g30,g31] Many* holder = new Many(new int, &x0, &x1, &x2, &x3, &x4, &x5, &x6, &x7, &x8, &x9, &x10, &x11, &x12, &x13, &x14, &x15, &x16, &x17, &x18, &x19, &x20, &x21, &x22, &x23, &x24, &x25, &x26, &x27, &x28, &x29, &x30, &x31)\n\tint last = x31\n\trefmut int* p = holder.p31\n\t*p = 8\n\treturn last\n", c"conflicting")

void test_exclusive_mixed_4():
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\trefmut int* p = holder.view\n\tholder = make(p)\n\t*p = 9\n\trefmut int* q = holder.view\n\treturn *q - 9\n", c"reborrow cycle")
	mixed_exclusive_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nown[a] Mixed* make(refmut[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tholder = make(holder.view)\n\trefmut int* q = holder.view\n\treturn *q - 3\n", c"reborrow cycle")
