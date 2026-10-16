# wbuild: x64
# wbuild: deps=tests/safe_callable_import_fixture.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int callable_case_number


void callable_result(process_result* result, char* diagnostic, int checking, char* path):
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


void callable_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	callable_case_number = callable_case_number + 1
	char* number = itoa(callable_case_number)
	char* prefix = c"bin/callable_case32_"
	if (__word_size__ == 8): prefix = c"bin/callable_case64_"
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
		callable_result(checked, diagnostic, 1, full)
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
		callable_result(compiled, diagnostic, 0, full)
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


void test_quantified_callable_contracts():
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = view\n\tint x = 3\n\tref int* r = f(&x)\n\treturn *r - 3\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = view\n\tint x = 3\n\tref int* r = f(&x)\n\tx = 4\n\treturn *r\n", c"conflicting")
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = view\n\tint x = 3\n\tref int* r = f(&x)\n\tint a = *r\n\tx = 4\n\tref int* s = f(&x)\n\treturn a + *s - 7\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nref[z] int* apply(View* f, ref[z] int* p):\n\treturn f(p)\nint main():\n\tint x = 3\n\tref int* r = apply(view, &x)\n\treturn *r - 3\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nref[z] int* bad(View* f, ref[z] int* p):\n\tint local = 3\n\treturn f(&local)\nint main():\n\treturn 0\n", c"must borrow from")
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = 0\n\treturn 0\n", c"matching quantified contract")
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f\n\tint x = 3\n\tref int* r = f(&x)\n\treturn *r\n", c"uninitialized")
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = view\n\tint raw = cast(int, f)\n\treturn raw\n", c"casts require scalar")
	callable_case(c"type Bad = fn[a](ref[b] int*) -> ref[b] int*\nint main():\n\treturn 0\n", c"must be quantified")
	callable_case(c"type Bad = fn[a, a](ref[a] int*) -> ref[a] int*\nint main():\n\treturn 0\n", c"duplicate quantified")
	callable_case(c"type Bad = fn[a, b](ref[a] int*) -> ref[a] int*\nint main():\n\treturn 0\n", c"names no borrowed")
	callable_case(c"type View = fn[a, b](ref[a] int*) -> ref[b] int* where a > b\nref[y] int* shorten(ref[x] int* p) where x > y:\n\treturn p\nint main():\n\tView* f = shorten\n\tint x = 3\n\tref int* r = f(&x)\n\treturn *r - 3\n", 0)
	callable_case(c"type Edit = fn[a](refmut[a] int*) -> refmut[a] int*\nrefmut[x] int* edit(refmut[x] int* p):\n\treturn p\nint main():\n\tEdit* f = edit\n\tint x = 3\n\trefmut int* r = f(&x)\n\t*r = 8\n\treturn x - 8\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nrefmut[x] int* edit(refmut[x] int* p):\n\treturn p\nint main():\n\tView* f = edit\n\treturn 0\n", c"disagrees with its quantified contract")
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\ntype Other = fn[z](ref[z] int*) -> ref[z] int*\nint main():\n\tView* f = view\n\tOther* g = f\n\tint x = 3\n\tref int* r = g(&x)\n\treturn *r - 3\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nView* factory():\n\treturn view\nint main():\n\tint x = 3\n\tref int* r = factory()(&x)\n\treturn *r - 3\n", 0)
	callable_case(c"type Pure = fn[](int) -> int\nint plus(int x):\n\treturn x + 1\nint main():\n\tPure* f = plus\n\treturn f(2) - 3\n", 0)
	callable_case(c"type Pure = fn[]() -> int\nint global = 3\nint read_global():\n\treturn global\nint main():\n\tPure* f = read_global\n\treturn 0\n", c"safe: global")


void test_quantified_callable_boundaries():
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\ntype Higher = fn[a](View*, ref[a] int*) -> ref[a] int*\nref[z] int* apply(View* f, ref[z] int* p):\n\treturn f(p)\nint main():\n\tHigher* g = apply\n\tint x = 3\n\tref int* r = g(view, &x)\n\treturn *r - 3\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\ntype Other = fn[z](ref[z] int*) -> ref[z] int*\ntype Higher = fn[a](View*, ref[a] int*) -> ref[a] int*\ntype Renamed = fn[q](Other*, ref[q] int*) -> ref[q] int*\nref[b] int* apply(View* f, ref[b] int* p):\n\treturn f(p)\nint main():\n\tHigher* original = apply\n\tRenamed* copy = original\n\tint x = 3\n\tref int* r = copy(view, &x)\n\treturn *r - 3\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nView* acquire(refmut int* count):\n\t*count = *count + 1\n\treturn view\nint main():\n\tint count = 0\n\tint x = 3\n\tref int* r = acquire(&count)(&x)\n\treturn *r + count - 4\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f\n\tf = view\n\tView* g = f\n\tint x = 3\n\tref int* r = g(&x)\n\treturn *r - 3\n", 0)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = view\n\tvoid* raw = f\n\treturn 0\n", c"safe:", 1)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = cast(View*, 0)\n\treturn 0\n", c"unsupported checked function value", 1)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nView* bad(ref int* p):\n\treturn cast(View*, p)\nint main():\n\treturn 0\n", c"unsupported checked function value", 1)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tconst View* f = view\n\treturn 0\n", c"safe: unsupported", 1)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nView* global = 0\nint main():\n\treturn 0\n", c"require local storage", 1)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* missing(ref[x] int* p);\nint main():\n\tView* f = missing\n\treturn 0\n", c"no checked implementation")
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* later(ref[x] int* p);\nint main():\n\tView* f = later\n\tint x = 3\n\tref int* r = f(&x)\n\treturn *r - 3\nref[y] int* later(ref[y] int* p):\n\treturn p\n", 0)
	callable_case(c"type Pair = fn[a, b](ref[a] int*, ref[b] int*) -> ref[a] int*\nref[y] int* wrong(ref[x] int* p, ref[y] int* q):\n\treturn q\nint main():\n\tPair* f = wrong\n\treturn 0\n", c"disagrees with its quantified contract")
	callable_case(c"type Shorten = fn[a, b](ref[a] int*, ref[b] int*) -> ref[b] int* where a > b\nref[y] int* wrong(ref[x] int* p, ref[y] int* q):\n\treturn q\nint main():\n\tShorten* f = wrong\n\treturn 0\n", c"disagrees with its quantified contract")
	callable_case(c"type Input = ref[a] int*\ntype View = fn[a](Input) -> Input\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = view\n\tint x = 3\n\tref int* r = f(&x)\n\treturn *r - 3\n", 0)
	callable_case(c"type Maybe = fn[]() -> optref int*\noptref int* absent():\n\treturn 0\nint main():\n\tMaybe* f = absent\n\toptref int* p = f()\n\tif p: return 1\n\treturn 0\n", 0)
	callable_case(c"import tests.safe_callable_import_fixture\ntype Local = fn[a](ref[a] int*) -> ref[a] int*\nint main():\n\tLocal* f = imported_callable_factory()\n\tint x = 3\n\tref int* r = f(&x)\n\treturn *r - 3\n", 0)
	callable_case(c"type SliceFn = fn[](int[]) -> int\nint variadic(int... values):\n\treturn values[0]\nint main():\n\tSliceFn* f = variadic\n\treturn 0\n", c"ordinary W functions", 1)
	callable_case(c"import lib.generator\ntype Pure = fn[]() -> int\ngenerator int values():\n\tpass\nint main():\n\tPure* f = values\n\treturn 0\n", c"safe:", 1)
	callable_case(c"type Deep0 = fn[]() -> int\ntype Deep1 = fn[](Deep0*, Deep0*) -> int\ntype Deep2 = fn[](Deep1*, Deep1*) -> int\ntype Deep3 = fn[](Deep2*, Deep2*) -> int\ntype Deep4 = fn[](Deep3*, Deep3*) -> int\ntype Deep5 = fn[](Deep4*, Deep4*) -> int\ntype Deep6 = fn[](Deep5*, Deep5*) -> int\ntype Deep7 = fn[](Deep6*, Deep6*) -> int\ntype Deep8 = fn[](Deep7*, Deep7*) -> int\ntype Deep9 = fn[](Deep8*, Deep8*) -> int\nint main():\n\tDeep9* f = 0\n\treturn 0\n", c"too deeply nested")


void test_quantified_callable_shapes():
	callable_case(c"type Slice = fn[a](int, ref[a] int[], int) -> ref[a] int[]\nref[z] int[] middle(int before, ref[z] int[] values, int after):\n\treturn values[before:after]\nint main():\n\tSlice* f = middle\n\tint[3] values\n\tvalues[1] = 7\n\tref int[] s = f(1, values, 3)\n\treturn s[0] + s.length - 9\n", 0, 1)
	callable_case(c"struct Holder:\n\tref[field] int* item\n\tint tag\ntype Record = fn[a](int, ref[a] Holder, int) -> ref[a] Holder\nref[x] Holder copy(int before, ref[x] Holder h, int after):\n\treturn h\nint main():\n\tRecord* f = copy\n\tint value = 7\n\tref[a] Holder h = Holder(&value, 3)\n\tref[a] Holder result = f(2, h, 5)\n\tref int* p = result.item\n\treturn *p + result.tag - 10\n", 0, 1)
	callable_case(c"type Bad = fn[](int, int, int, int, int, int, int, int, int, int, int) -> int\nint main():\n\treturn 0\n", c"at most 10 parameters", 1)
	callable_case(c"type Bad = fn[3]() -> int\nint main():\n\treturn 0\n", c"requires a lifetime label", 1)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\ntype Other = fn[a](refmut[a] int*) -> refmut[a] int*\ntype Higher = fn[](View*) -> int\ntype Wrong = fn[](Other*) -> int\nint apply(View* f):\n\tint x = 3\n\tref int* r = f(&x)\n\treturn *r\nint main():\n\tHigher* f = apply\n\tWrong* g = f\n\treturn 0\n", c"matching quantified contract", 1)
	callable_case(c"type View = fn[a](ref[a] int*) -> ref[a] int*\nref[x] int* view(ref[x] int* p):\n\treturn p\nint main():\n\tView* f = view\n\tint raw = f\n\treturn raw\n", c"cannot escape into raw", 1)


void test_quantified_callable_effects():
	callable_case(c"type Edit = fn[](refmut int*, int) -> int\nint read_value(refmut int* p, int value):\n\treturn *p + value\nint mutate(refmut int* p):\n\t*p = 9\n\treturn 0\nint main():\n\tEdit* f = read_value\n\tint value = 7\n\treturn f(&value, mutate(&value))\n", c"conflicting")
	callable_case(c"type Consume = fn[](own int*, own int*) -> int\nint consume(own int* a, own int* b):\n\treturn *a + *b\nint main():\n\tConsume* f = consume\n\town int* value = new int\n\treturn f(value, value)\n", c"conflicting call arguments")
	callable_case(c"type Pure = fn[](int) -> int\nint plus(int value):\n\treturn value + 1\nint minus(int value):\n\treturn value - 1\nint choose(int branch):\n\tPure* a = plus\n\tPure* b = minus\n\tPure* f = branch ? a : b\n\treturn f(3)\nint main():\n\treturn choose(1) + choose(0) - 6\n", 0)
	callable_case(c"type Raw = fn(int, int, int, int, int, int, int, int, int, int, int) -> int\nint main():\n\treturn 0\n", 0)
