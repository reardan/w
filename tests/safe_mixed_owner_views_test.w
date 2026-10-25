# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int mixed_view_case_number


void mixed_view_result(process_result* result, char* diagnostic, int checking, char* path):
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


void mixed_view_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	mixed_view_case_number = mixed_view_case_number + 1
	char* number = itoa(mixed_view_case_number)
	char* prefix = c"bin/mixed_view_case32_"
	if (__word_size__ == 8): prefix = c"bin/mixed_view_case64_"
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
		mixed_view_result(checked, diagnostic, 1, full)
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
		mixed_view_result(compiled, diagnostic, 0, full)
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


void test_mixed_views_0():
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* get(ref[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* p = get(holder)\n\treturn *p - 3\n", 0)
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\tref int* p = view.view\n\tref int* child = view.stored\n\treturn *p - 3\n", 0)
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\tholder = make(&y)\n\tref int* p = view.view\n\treturn *p\n", c"conflicting")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\tx = 9\n\tref int* p = view.view\n\treturn *p\n", c"conflicting")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* get(ref[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* p = get(holder)\n\tholder = make(&y)\n\treturn *p\n", c"conflicting")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\trefmut int* child = view.stored\n\treturn 0\n", c"shared")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\trefmut int* p = view.view\n\treturn 0\n", c"shared")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\trefmut Mixed* view = holder\n\treturn 0\n", 0)

void test_mixed_views_1():
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\toptref Mixed* view = holder\n\treturn 0\n", 0)
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] Mixed* bad(ref[a] int* input):\n\town[a] Mixed* holder = make(input)\n\treturn holder\nint main():\n\treturn 0\n", c"must borrow from")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] Mixed* bad(own[a] Mixed* holder):\n\treturn holder\nint main():\n\treturn 0\n", c"must borrow from")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* child(ref[a] Mixed* holder):\n\treturn holder.stored\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* p = child(holder)\n\tholder = make(&x)\n\treturn *p\n", c"conflicting")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* get(ref[a] Mixed* holder):\n\treturn holder.view\nref[a] Mixed* pass(ref[a] Mixed* value):\n\treturn value\ntype Pass = fn[a](ref[a] Mixed*) -> ref[a] Mixed*\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tPass* identity = pass\n\tref Mixed* view = identity(holder)\n\tref int* p = get(view)\n\treturn *p - 3\n", 0)
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* get(ref[a] Mixed* holder):\n\treturn holder.view\nref[a] T* pass[T](ref[a] T* value):\n\treturn value\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = pass[Mixed](holder)\n\tref int* p = get(view)\n\treturn *p - 3\n", 0)
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[data] Mixed* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(make(&x), 7)\n\tref Outer* view = owner\n\tref int* p = view.child.view\n\treturn *p - 3\n", 0)
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[data] Mixed* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(make(&x), 7)\n\tref Mixed* child = owner.child\n\tref int* p = child.view\n\treturn *p - 3\n", 0)

void test_mixed_views_2():
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[data] Mixed* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(make(&x), 7)\n\tref Outer* view = owner\n\tref Mixed* child = view.child\n\tref int* p = child.view\n\treturn *p - 3\n", 0)
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[data] Mixed* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(make(&x), 7)\n\tref Outer* view = owner\n\tref int* p = view.child.view\n\towner = new Outer(make(&x), 8)\n\treturn *p\n", c"conflicting")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[data] Mixed* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(make(&x), 7)\n\tref Outer* view = owner\n\tref int* p = view.child.view\n\tx = 4\n\treturn *p\n", c"conflicting")
	mixed_view_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* get(ref[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref Mixed* view = holder\n\tint value = 0\n\tfor i in range(3):\n\t\tref int* p = get(view)\n\t\tvalue += *p\n\tholder = make(&y)\n\treturn value - 9\n", 0)
	mixed_view_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nstruct Holder:\n\town int* stored\n\tref[left,right] Pair pair\nref[a,b] Pair get(ref[a] Holder* holder, ref[b] int* unused):\n\treturn holder.pair\nint main():\n\treturn 0\n", c"must borrow from")
	mixed_view_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nstruct Holder:\n\town int* stored\n\tref[left,right] Pair pair\nref[a,a] Pair get(ref[a] Holder* holder):\n\treturn holder.pair\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Holder* holder = new Holder(new int, Pair(&x, &y))\n\tref[a,a] Pair pair = get(holder)\n\tref int* p = pair.first\n\treturn *p - 3\n", 0)
	mixed_view_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nstruct Holder:\n\town int* stored\n\tref[left,right] Pair pair\nref[a,a] Pair get(ref[a] Holder* holder):\n\treturn holder.pair\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Holder* holder = new Holder(new int, Pair(&x, &y))\n\tref[a,a] Pair pair = get(holder)\n\tref int* p = pair.first\n\ty = 9\n\treturn *p\n", c"conflicting")
