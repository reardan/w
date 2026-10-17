# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int reference_field_case_number


void reference_field_result(process_result* result, char* diagnostic, int checking, char* path):
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


void reference_field_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	reference_field_case_number = reference_field_case_number + 1
	char* number = itoa(reference_field_case_number)
	char* prefix = c"bin/reference_field_case32_"
	if (__word_size__ == 8): prefix = c"bin/reference_field_case64_"
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
		reference_field_result(checked, diagnostic, 1, full)
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
		reference_field_result(compiled, diagnostic, 0, full)
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




void test_reference_field_0():
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = &y\n\tref int* p = view.data\n\treturn *p - 4\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = &y\n\trefmut int* p = view.data\n\t*p = 9\n\treturn y - 9\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tref int* p = view.data\n\tview.data = &y\n\treturn *p - 3\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\trefmut int* p = view.data\n\tview.data = &y\n\t*p = 8\n\trefmut int* q = view.data\n\treturn *q\n", c"conflicting")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tref int* p = view.stored\n\tview.data = &y\n\treturn *p\n", c"conflicting")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = &view.tag\n\treturn 0\n", c"containing owner")
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\trefmut int* p = view.data\n\tview.data = p\n\treturn 0\n", c"reborrow cycle")
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = view.data\n\treturn 0\n", c"reborrow cycle")

void test_reference_field_1():
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nvoid bad(ref View* view, ref int* data):\n\tview.data = data\nint main():\n\treturn 0\n", c"named unique owner")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nown[a] View* bad(own[a] View* view, ref[b] int* data):\n\tview.data = data\n\treturn view\nint main():\n\treturn 0\n", c"must borrow from")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nown[a] View* change(own[a] View* view, ref[b] int* data) where b > a:\n\tview.data = data\n\treturn view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview = change(view, &y)\n\tref int* p = view.data\n\treturn *p - 4\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nown[a] View* bad(own[a] View* view):\n\tint local = 8\n\tview.data = &local\n\treturn view\nint main():\n\treturn 0\n", c"must borrow from")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tif (1):\n\t\tint local = 8\n\t\tview.data = &local\n\tref int* p = view.data\n\treturn *p\n", c"moved")
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tfor i in range(3):\n\t\tview.data = &x\n\t\trefmut int* p = view.data\n\t\t*p += 1\n\treturn x - 6\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = &y\n\tx = 9\n\tref int* p = view.data\n\treturn *p\n", c"conflicting")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nref[a] int* consume(own[a] View* view):\n\treturn view.data\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = consume(view)\n\treturn 0\n", c"conflicting")

void test_reference_field_2():
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tref int* shared = &y\n\tview.data = shared\n\treturn 0\n", c"mutable")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = 0\n\treturn 0\n", c"safe:")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data += 1\n\treturn 0\n", c"safe:")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nstruct Outer:\n\town[group] View* child\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(new View(new int, &x, 7))\n\touter.child.data = &y\n\treturn 0\n", c"named checked pointer")
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tref[other] int* other\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\town[a,b] View* view = new View(new int, &x, &z, 7)\n\tview.data = &y\n\trefmut int* p = view.data\n\t*p = 9\n\tref int* q = view.other\n\treturn *q + y - 14\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tref[other] int* other\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\town[a,b] View* view = new View(new int, &x, &z, 7)\n\tview.data = &z\n\trefmut int* p = view.data\n\treturn *p\n", c"conflicting")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int[] data\n\tint tag\nint main():\n\tint[2] x\n\tx[0] = 3\n\tint[3] y\n\ty[1] = 8\n\town[a] View* view = new View(new int, x, 7)\n\tview.data = y\n\tref int[] p = view.data\n\treturn p[1] - 8\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int[] data\n\tint tag\nref[a] int[] change(own[a] View* view, ref[a] int[] data):\n\tview.data = data\n\treturn view.data\nint main():\n\tint[2] x\n\tx[0] = 3\n\tint[3] y\n\ty[1] = 8\n\town[a] View* view = new View(new int, x, 7)\n\tref int[] p = change(view, y)\n\treturn p[1] - 8\n", 0)

void test_reference_field_3():
	reference_field_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\nstruct Holder:\n\town int* stored\n\tref[a,b] Pair pair\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\town[a,b] Holder* holder = new Holder(new int, Pair(&x, &y))\n\tholder.pair = Pair(&y, &z)\n\tref[a,b] Pair pair = holder.pair\n\tref int* p = pair.first\n\tref int* q = pair.second\n\treturn *p + *q - 9\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nref[a] int* pass_ref[T](ref[a] T* p):\n\treturn p\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tview.data = pass_ref[int](&y)\n\tref int* p = view.data\n\treturn *p - 4\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nref[a] int* pass_ref(ref[a] int* p):\n\treturn p\ntype Pass = fn[a](ref[a] int*) -> ref[a] int*\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tPass* pass = pass_ref\n\tview.data = pass(&y)\n\tref int* p = view.data\n\treturn *p - 4\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tif (x): view.data = &y\n\tref int* p = view.data\n\treturn *p - 4\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\tif (x): view.data = &y\n\ty = 8\n\tref int* p = view.data\n\treturn *p\n", c"conflicting")
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\ntype Alias = View\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Alias* view = new View(new int, &x, 7)\n\tview.data = &y\n\tref int* p = view.data\n\treturn *p - 4\n", 0)
	reference_field_case(c"struct View:\n\town int* stored\n\tref[data] int* data\n\tint tag\nvoid touch(refmut int* data):\n\t*data = 9\nref[a] int* bad(own[a] View* view, refmut[a] int* data):\n\tdefer touch(data)\n\tview.data = data\n\treturn view.data\nint main():\n\treturn 0\n", c"conflicting")
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tref[data] int* other\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\town[a] View* view = new View(new int, &x, &z, 7)\n\tview.data = &y\n\tref int* p = view.other\n\treturn *p\n", c"conflicting")

void test_reference_field_4():
	reference_field_case(c"struct View:\n\town int* stored\n\trefmut[data] int* data\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(new int, &x, 7)\n\town int* data = new int\n\tview.data = data\n\town int* moved = data\n\trefmut int* p = view.data\n\treturn *p\n", c"moved")
