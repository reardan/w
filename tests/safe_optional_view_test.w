# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int optional_view_case_number


void optional_view_result(process_result* result, char* diagnostic, int checking, char* path):
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


void optional_view_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	optional_view_case_number = optional_view_case_number + 1
	char* number = itoa(optional_view_case_number)
	char* prefix = c"bin/optional_view_case32_"
	if (__word_size__ == 8): prefix = c"bin/optional_view_case64_"
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
		optional_view_result(checked, diagnostic, 1, full)
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
		optional_view_result(compiled, diagnostic, 0, full)
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








void test_optional_view_0():
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\toptref View* view = 0\n\tif (view): return 1\n\treturn 0\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = owner\n\tif (view):\n\t\tref int* data = view.data\n\t\treturn *data - 3\n\treturn 1\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint inspect(optref View* view):\n\tif (view): return view.tag\n\treturn 0\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\treturn inspect(owner) + inspect(0) - 7\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint bad(optref View* view):\n\tref int* data = view.data\n\treturn *data\nint main():\n\treturn 0\n", c"presence check")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint bad(optref View* view):\n\treturn view.tag\nint main():\n\treturn 0\n", c"presence check")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint bad(optref View* view):\n\tref int* data = view.stored\n\treturn *data\nint main():\n\treturn 0\n", c"presence check")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = owner\n\tview = 0\n\towner = new View(new int, &x, 8)\n\tif (view): return 1\n\treturn owner.tag - 8\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\noptref[a] View* pass(optref[a] View* value):\n\treturn value\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = pass(owner)\n\tif (view): return view.tag - 7\n\treturn 1\n", 0)

void test_optional_view_1():
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\noptref[a] View* bad(ref[a] int* data):\n\town[a] View* owner = new View(new int, data, 7)\n\treturn owner\nint main():\n\treturn 0\n", c"must borrow from")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint bad(optref View* view):\n\tif (view):\n\t\tview = 0\n\t\tref int* data = view.data\n\t\treturn *data\n\treturn 0\nint main():\n\treturn 0\n", c"presence check")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = owner\n\tif (view):\n\t\tref int* data = view.data\n\t\towner = new View(new int, &x, 8)\n\t\treturn *data\n\treturn 0\n", c"conflicting")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = owner\n\tif (view):\n\t\tref int* data = view.data\n\t\tx = 8\n\t\treturn *data\n\treturn 0\n", c"conflicting")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = 0\n\tif (x):\n\t\town[a] View* local = new View(new int, &x, 8)\n\t\tview = local\n\tif (view): return view.tag\n\treturn 0\n", c"moved")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint inspect(ref View* view):\n\treturn view.tag\nint bad(optref View* view):\n\treturn inspect(view)\nint main():\n\treturn 0\n", c"presence check")
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint inspect(ref View* view):\n\treturn view.tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = owner\n\tif (view): return inspect(view) - 7\n\treturn 1\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptrefmut View* view = owner\n\tif (view):\n\t\tview.tag = 8\n\t\trefmut int* data = view.data\n\t\t*data = 9\n\treturn x - 9\n", 0)

void test_optional_view_2():
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint change(optrefmut View* view):\n\tif (view):\n\t\trefmut int* data = view.data\n\t\t*data = 8\n\t\treturn *data\n\treturn 0\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\treturn change(owner) + change(0) - 8\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* shared = owner\n\tif (shared):\n\t\toptrefmut View* view = shared\n\t\tif (view): return view.tag\n\treturn 0\n", c"shared reference")
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptrefmut View* view = owner\n\tif (view):\n\t\tref int* first = view.data\n\t\tref int* second = view.data\n\t\treturn *first + *second - 6\n\treturn 1\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptrefmut View* view = owner\n\tif (view):\n\t\trefmut int* first = view.data\n\t\trefmut int* second = view.data\n\t\t*first = 8\n\t\treturn *second\n\treturn 0\n", c"conflicting")
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptrefmut View* view = owner\n\tview = 0\n\trefmut int* data = owner.data\n\t*data = 8\n\tif (view): return 1\n\treturn x - 8\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptrefmut View* view = owner\n\tif (view): view = view\n\treturn 0\n", c"reborrow cycle")
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\noptrefmut[a] View* pass(optrefmut[a] View* view):\n\treturn view\ntype Pass = fn[a](optrefmut[a] View*) -> optrefmut[a] View*\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tPass* identity = pass\n\toptrefmut View* view = identity(owner)\n\tif (view):\n\t\trefmut int* data = view.data\n\t\t*data = 8\n\treturn x - 8\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(new View(new int, &x, 7))\n\toptref Outer* view = owner\n\tif (view):\n\t\tref int* data = view.child.data\n\t\treturn *data - 3\n\treturn 1\n", 0)

void test_optional_view_3():
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\nint bad(optref Outer* view):\n\tref int* data = view.child.data\n\treturn *data\nint main():\n\treturn 0\n", c"presence check")
	optional_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptrefmut View* view = 0\n\tfor i in range(3):\n\t\tview = owner\n\t\tif (view):\n\t\t\trefmut int* data = view.data\n\t\t\t*data += 1\n\t\tview = 0\n\treturn x - 6\n", 0)
	optional_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\toptref View* view = owner\n\tif (view):\n\t\tref int* data = view.data\n\t\tview = 0\n\t\towner = new View(new int, &x, 8)\n\t\treturn *data\n\treturn 0\n", c"conflicting")
