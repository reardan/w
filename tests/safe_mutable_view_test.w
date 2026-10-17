# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int mutable_view_case_number


void mutable_view_result(process_result* result, char* diagnostic, int checking, char* path):
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


void mutable_view_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	mutable_view_case_number = mutable_view_case_number + 1
	char* number = itoa(mutable_view_case_number)
	char* prefix = c"bin/mutable_view_case32_"
	if (__word_size__ == 8): prefix = c"bin/mutable_view_case64_"
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
		mutable_view_result(checked, diagnostic, 1, full)
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
		mutable_view_result(compiled, diagnostic, 0, full)
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







void test_mutable_view_0():
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\tview.tag = 9\n\trefmut int* data = view.data\n\t*data = 8\n\treturn x - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nvoid change(refmut View* view):\n\tview.tag = 9\n\trefmut int* data = view.data\n\t*data = 8\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tchange(owner)\n\tint tag = owner.tag\n\treturn x + tag - 17\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] int* data(refmut[a] View* view):\n\treturn view.data\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut int* value = data(owner)\n\t*value = 8\n\treturn x - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\trefmut int* value = view.stored\n\t*value = 8\n\treturn *value - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\town[a] View* moved = owner\n\treturn view.tag\n", c"moved")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\towner.tag = 8\n\treturn view.tag\n", c"conflicting")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\tint value = x\n\treturn view.tag + value\n", c"conflicting")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\trefmut int* first = view.data\n\trefmut int* second = view.data\n\t*first = 8\n\treturn *second\n", c"conflicting")

void test_mutable_view_1():
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\tref int* first = view.data\n\tref int* second = view.data\n\treturn *first + *second - 6\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tref View* shared = owner\n\trefmut View* mutable = shared\n\treturn mutable.tag\n", c"shared reference")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tref View* shared = owner\n\trefmut int* data = shared.data\n\treturn *data\n", c"shared reference")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] View* bad(refmut[a] int* data):\n\town[a] View* owner = new View(new int, data, 7)\n\treturn owner\nint main():\n\treturn 0\n", c"must borrow from")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] View* pass(refmut[a] View* view):\n\treturn view\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = pass(owner)\n\tview.tag = 8\n\treturn owner.tag - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] int* bad(ref[a] View* view):\n\treturn view.data\nint main():\n\treturn 0\n", c"mutable borrowed parameter")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] T* pass[T](refmut[a] T* value):\n\treturn value\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = pass[View](owner)\n\tview.tag = 8\n\treturn owner.tag - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] int* data(refmut[a] View* view):\n\treturn view.data\ntype Get = fn[a](refmut[a] View*) -> refmut[a] int*\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tGet* get = data\n\trefmut int* value = get(owner)\n\t*value = 8\n\treturn x - 8\n", 0)

void test_mutable_view_2():
	mutable_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\tview.tag = 9\n\tref int* data = view.data\n\treturn *data + view.tag - 12\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\trefmut int* data = view.data\n\treturn *data\n", c"shared reference")
	mutable_view_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tref int* other = &x\n\trefmut View* view = owner\n\treturn *other + view.tag\n", c"conflicting")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\tview.data = &x\n\treturn view.tag\n", c"stable unique owner path")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\town int* value = view.stored\n\treturn *value\n", c"unique owner path")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(new View(new int, &x, 7), 4)\n\trefmut Outer* view = owner\n\trefmut View* child = view.child\n\trefmut int* data = child.data\n\t*data = 8\n\treturn x - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(new View(new int, &x, 7), 4)\n\trefmut View* child = owner.child\n\trefmut int* data = child.data\n\t*data = 8\n\treturn x - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(new View(new int, &x, 7), 4)\n\tref Outer* view = owner\n\trefmut View* child = view.child\n\treturn child.tag\n", c"shared reference")

void test_mutable_view_3():
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(new View(new int, &x, 7), 4)\n\trefmut Outer* view = owner\n\trefmut View* child = view.child\n\towner.child = new View(new int, &x, 8)\n\treturn child.tag\n", c"conflicting")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tfor i in range(3):\n\t\trefmut View* view = owner\n\t\trefmut int* data = view.data\n\t\t*data += 1\n\treturn x - 6\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint inspect(ref View* view):\n\treturn view.tag\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\trefmut View* view = owner\n\tdefer (inspect(view))\n\towner.tag = 8\n\treturn 0\n", c"conflicting")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\n\tint tag\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(new View(new int, &x, 7), 4)\n\trefmut Outer* view = owner\n\tref int* first = view.child.data\n\tref int* second = view.child.data\n\treturn *first + *second - 6\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\n\tint tag\nrefmut[a] int* get(refmut[a] Outer* view):\n\treturn view.child.data\nint main():\n\tint x = 3\n\town[a] Outer* owner = new Outer(new View(new int, &x, 7), 4)\n\trefmut int* data = get(owner)\n\t*data = 8\n\treturn x - 8\n", 0)
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] int* bad(refmut[a] View* first, refmut[b] View* second):\n\treturn second.data\nint main():\n\treturn 0\n", c"must borrow from")
	mutable_view_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nrefmut[a] int* choose(refmut[a] View* first, refmut[a] View* second, int flag):\n\tif (flag): return first.data\n\treturn second.data\nint main():\n\tint x = 3\n\town[a] View* owner = new View(new int, &x, 7)\n\tint y = 4\n\town[a] View* other = new View(new int, &y, 8)\n\trefmut int* selected = choose(owner, other, 1)\n\ty = 8\n\treturn *selected\n", c"conflicting")
