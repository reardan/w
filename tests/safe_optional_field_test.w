# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int optional_field_case_number


void optional_field_result(process_result* result, char* diagnostic, int checking, char* path):
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


void optional_field_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	optional_field_case_number = optional_field_case_number + 1
	char* number = itoa(optional_field_case_number)
	char* prefix = c"bin/optional_field_case32_"
	if (__word_size__ == 8): prefix = c"bin/optional_field_case64_"
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
		optional_field_result(checked, diagnostic, 1, full)
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
		optional_field_result(compiled, diagnostic, 0, full)
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









void test_optional_field_0():
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nint main():\n\tref[a] Maybe record = Maybe(0, 3)\n\toptref int* value = record.value\n\tif (value): return 1\n\treturn record.tag - 3\n", 0)
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Maybe record = Maybe(&x, 3)\n\toptref int* value = record.value\n\tif (value): return *value - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Maybe record = Maybe(&x, 3)\n\tref int* value = record.value\n\treturn *value\n", c"presence check")
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nref[a] Maybe make(optref[a] int* value):\n\treturn Maybe(value, 3)\nint main():\n\tint x = 7\n\tref[a] Maybe record = Maybe(&x, 3)\n\tref[a] Maybe other = make(0)\n\toptref int* value = other.value\n\tif (value): return 1\n\treturn 0\n", 0)
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nref[a] Maybe bad(optref[a] int* value):\n\tint local = 8\n\treturn Maybe(&local, 3)\nint main():\n\treturn 0\n", c"must borrow from")
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\tref[a] Maybe record = Maybe(&x, 3)\n\toptref int* value = record.value\n\tx = 8\n\tif (value): return *value\n\treturn 0\n", c"conflicting")
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nint main():\n\tref[a] Maybe record = Maybe(0)\n\treturn record.tag\n", c"constructor expects")
	optional_field_case(c"struct Maybe:\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Maybe record = Maybe(&x, 3)\n\toptrefmut int* value = record.value\n\tif (value): *value = 8\n\treturn x - 8\n", 0)

void test_optional_field_1():
	optional_field_case(c"struct Maybe:\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\trefmut[a] Maybe record = Maybe(0, 3)\n\toptrefmut int* value = record.value\n\tif (value): return 1\n\treturn 0\n", 0)
	optional_field_case(c"struct Maybe:\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Maybe record = Maybe(&x, 3)\n\toptref int* value = record.value\n\tif (value): return *value - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Maybe:\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\trefmut[a] Maybe record = Maybe(&x, 3)\n\toptrefmut int* first = record.value\n\toptrefmut int* second = record.value\n\tif (first): *first = 8\n\tif (second): return *second\n\treturn 0\n", c"conflicting")
	optional_field_case(c"struct Maybe:\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 3\n\tref[a] Maybe record = Maybe(&x, 3)\n\treturn record.tag\n", c"shared-reference groups")
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\toptref int* value = owner.value\n\tif (value): return *value - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\towner.value = 0\n\toptref int* value = owner.value\n\tif (value): return 1\n\treturn 0\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\tint y = 8\n\towner.value = &y\n\toptref int* value = owner.value\n\tif (value): return *value - 8\n\treturn 1\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\tref int* value = owner.value\n\treturn *value\n", c"presence check")

void test_optional_field_2():
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\tref Owner* view = owner\n\toptref int* value = view.value\n\towner.value = 0\n\tif (value): return *value\n\treturn 0\n", c"conflicting")
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\toptref int* value = owner.value\n\towner.value = 0\n\tif (value): return *value - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nown[a] Owner* bad(optref[a] int* value):\n\tint local = 8\n\treturn new Owner(new int, &local, 3)\nint main():\n\treturn 0\n", c"must borrow from")
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nint main():\n\town[a] Owner* owner = new Owner\n\treturn owner.tag\n", c"pointer-free")
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\towner.value = 0\n\towner.value = &x\n\toptrefmut int* value = owner.value\n\tif (value): *value = 8\n\treturn x - 8\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\trefmut Owner* view = owner\n\toptrefmut int* value = view.value\n\tif (value): *value = 8\n\treturn x - 8\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\tref Owner* view = owner\n\toptrefmut int* value = view.value\n\treturn 0\n", c"shared reference")
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptrefmut[data] int* value\n\tint tag\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\toptrefmut int* value = owner.value\n\towner.value = value\n\treturn 0\n", c"reborrow cycle")

void test_optional_field_3():
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nstruct Outer:\n\town[group] Owner* child\nint main():\n\tint x = 7\n\town[a] Outer* outer = new Outer(new Owner(new int, &x, 3))\n\touter.child.value = 0\n\toptref int* value = outer.child.value\n\tif (value): return 1\n\treturn 0\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\nstruct Outer:\n\town[group] Owner* child\nint main():\n\tint x = 7\n\town[a] Outer* outer = new Outer(new Owner(new int, &x, 3))\n\town[a] Owner* child = outer.child\n\toptref int* value = child.value\n\tif (value): return *value - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nstruct Pair:\n\tref[left] Maybe first\n\tref[right] Maybe second\nint main():\n\tint x = 7\n\tref[a,b] Pair pair = Pair(Maybe(0, 3), Maybe(&x, 4))\n\toptref int* first = pair.first.value\n\toptref int* second = pair.second.value\n\tif (first): return 1\n\tif (second): return *second - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\noptref[a] int* take(own[a] Owner* owner):\n\treturn owner.value\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\toptref int* value = take(owner)\n\tif (value): return *value - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Owner:\n\town int* stored\n\toptref[data] int* value\n\tint tag\noptref[a] int* get(ref[a] Owner* view):\n\treturn view.value\nint main():\n\tint x = 7\n\town[a] Owner* owner = new Owner(new int, &x, 3)\n\toptref int* value = get(owner)\n\towner = new Owner(new int, &x, 8)\n\tif (value): return *value\n\treturn 0\n", c"conflicting")
	optional_field_case(c"struct Maybe:\n\toptref[data] int* value\n\tint tag\nref[a] Maybe make(optref[a] int* value):\n\treturn Maybe(value, 3)\ntype Make = fn[a](optref[a] int*) -> ref[a] Maybe\nint main():\n\tint x = 7\n\tMake* factory = make\n\tref[a] Maybe record = factory(&x)\n\toptref int* value = record.value\n\tif (value): return *value - 7\n\treturn 1\n", 0)
	optional_field_case(c"struct Maybe:\n\toptrefmut[data] int* value\n\tint tag\nint change(refmut int* value):\n\t*value = 8\n\treturn 3\nint main():\n\tint x = 7\n\trefmut[a] Maybe record = Maybe(&x, change(&x))\n\treturn record.tag\n", c"conflicting")
	optional_field_case(c"struct Maybe:\n\toptrefmut[data] int* value\n\tint tag\nint change(refmut int* value):\n\t*value = 8\n\treturn 3\nint main():\n\tint x = 7\n\trefmut[a] Maybe record = Maybe(0, change(&x))\n\toptrefmut int* value = record.value\n\tif (value): return 1\n\treturn x - 8\n", 0)
