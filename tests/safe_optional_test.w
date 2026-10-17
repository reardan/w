# wbuild: x64
# wbuild: deps=tests/safe_optional_import_fixture.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int optional_case_number


void optional_result(process_result* result, char* diagnostic, int checking, char* path):
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


void optional_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1):
	optional_case_number = optional_case_number + 1
	char* number = itoa(optional_case_number)
	char* prefix = c"bin/optional_case32_"
	if (__word_size__ == 8): prefix = c"bin/optional_case64_"
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
		strv_set(checking, 3, c"--ast-required")
		strv_set(checking, 4, c"--strict")
		if (relaxed): strv_set(checking, 4, c"--quiet")
		strv_set(checking, 5, c"--quiet")
		if (__word_size__ == 8): strv_set(checking, 5, c"x64")
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		optional_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--ast-required")
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
		optional_result(compiled, diagnostic, 0, full)
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


void test_optional_presence():
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\tif r: return *r - 7\n\treturn 1\n", 0)
	optional_case(c"int main():\n\toptref int* r = 0\n\tif r: return *r\n\treturn 0\n", 0)
	optional_case(c"int get_value(optref int* r):\n\tif r == 0: return 0\n\treturn *r\nint main():\n\tint x = 7\n\treturn get_value(&x) + get_value(0) - 7\n", 0)
	optional_case(c"int get_value(optref int* r):\n\tif r != 0: return *r\n\treturn 0\nint main():\n\tint x = 7\n\treturn get_value(&x) - 7\n", 0)
	optional_case(c"int get_value(optref int* r):\n\tif !r: return 0\n\treturn *r\nint main():\n\tint x = 7\n\treturn get_value(&x) - 7\n", 0)
	optional_case(c"int get_value(optref int* r):\n\treturn *r\nint main():\n\treturn 0\n", c"presence check")
	optional_case(c"int main():\n\toptref int* r = 0\n\treturn *r\n", c"presence check")
	optional_case(c"int main():\n\tref int* r = 0\n\treturn *r\n", c"safe:")
	optional_case(c"int get_value(optref int* r):\n\tif r && *r == 7: return 0\n\treturn 1\nint main():\n\tint x = 7\n\treturn get_value(&x)\n", 0)
	optional_case(c"int get_value(optref int* r):\n\tif !r || *r == 7: return 0\n\treturn 1\nint main():\n\tint x = 7\n\treturn get_value(&x) + get_value(0)\n", 0)
	optional_case(c"int get_value(optref int* r):\n\tif r & *r: return 0\n\treturn 1\nint main():\n\treturn 0\n", c"safe:")


void test_optional_contracts():
	optional_case(c"optref int* maybe(ref int* r, int yes):\n\tif yes: return r\n\treturn 0\nint main():\n\tint x = 7\n\toptref int* r = maybe(&x, 1)\n\tif r: return *r - 7\n\treturn 1\n", 0)
	optional_case(c"optref[a] int* maybe(ref[a] int* r, ref[a] int* s, int yes):\n\tif yes: return r\n\treturn s\nint main():\n\tint x = 7\n\tint y = 8\n\toptref int* r = maybe(&x, &y, 1)\n\ty = 9\n\tif r: return *r - 7\n\treturn 1\n", c"conflicting")
	optional_case(c"ref int* unwrap(optref int* r):\n\tif r: return r\n\texit(1)\n\treturn r\nint main():\n\treturn 0\n", c"presence check")
	optional_case(c"int get_value(ref int* r):\n\treturn *r\nint maybe(optref int* r):\n\tif r: return get_value(r)\n\treturn 0\nint main():\n\tint x = 7\n\treturn maybe(&x) - 7\n", 0)
	optional_case(c"int get_value(ref int* r):\n\treturn *r\nint maybe(optref int* r):\n\treturn get_value(r)\nint main():\n\treturn 0\n", c"presence check")
	optional_case(c"int change(optrefmut int* r):\n\tif r: *r = 9\n\treturn 0\nint main():\n\tint x = 7\n\tchange(&x)\n\treturn x - 9\n", 0)
	optional_case(c"int main():\n\tint x = 7\n\tref int* shared = &x\n\toptrefmut int* r = shared\n\tif r: *r = 9\n\treturn 0\n", c"mutable borrow from a shared")
	optional_case(c"optref int* bad(ref int* p):\n\tint x = 7\n\treturn &x\nint main():\n\treturn 0\n", c"returned reference")
	optional_case(c"type Maybe = optref[a] int*\nMaybe identity(Maybe r):\n\treturn r\nint main():\n\tint x = 7\n\tMaybe r = identity(&x)\n\tif r: return *r - 7\n\treturn 1\n", 0)
	optional_case(c"int get_value(optref int* r):\n\treturn cast(int, r)\nint main():\n\treturn 0\n", c"casts require scalar")


void test_optional_reassignment():
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = 0\n\tr = &x\n\tif r: return *r - 7\n\treturn 1\n", 0)
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\tif r:\n\t\tr = 0\n\t\treturn *r\n\treturn 0\n", c"presence check")
	optional_case(c"int main():\n\tint x = 7\n\tint y = 9\n\toptref int* r = &x\n\tr = &y\n\tif r: return *r - 9\n\treturn 1\n", 0)
	optional_case(c"int maybe(int yes):\n\tint x = 7\n\toptref int* r = 0\n\tif yes: r = &x\n\treturn *r\nint main():\n\treturn 0\n", c"presence check")
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\tint n = 0\n\twhile r:\n\t\tn = *r\n\t\tr = 0\n\treturn n - 7\n", 0)
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\tint n = 0\n\twhile n < 2:\n\t\tn = *r\n\t\tr = 0\n\treturn 0\n", c"presence check")


void test_optional_surface_boundaries():
	optional_case(c"int main():\n\treturn sizeof(optref int*) - __word_size__\n", 0)
	optional_case(c"int main():\n\toptref int* r = cast(optref int*, 0)\n\tif r: return *r\n\treturn 0\n", c"safe:")
	optional_case(c"int main():\n\toptref int* r = 1\n\treturn 0\n", c"safe:")
	optional_case(c"int main():\n\toptref int[] r\n\treturn 0\n", c"checked slices require")
	optional_case(c"int main():\n\toptref int* r\n\treturn 0\n", c"references require initialization")
	optional_case(c"int main():\n\tint optref = 3\n\tint optrefmut = 4\n\treturn optref + optrefmut - 7\n", 0)
	optional_case(c"optref int* identity(optref int* p);\nref int* identity(optref int* p):\n\tif p: return p\n\treturn p\nint main():\n\treturn 0\n", c"safe:")
	optional_case(c"struct Holder:\n\toptref[a] int* item\nint main():\n\tint x = 3\n\tref[a] Holder h = Holder(&x)\n\treturn 0\n", 0)


void test_optional_ancestry():
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\tr = r\n\treturn 0\n", c"reborrow cycle")
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\toptref int* s = r\n\tr = s\n\tif r: return *r\n\treturn 0\n", c"reborrow cycle")
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\toptref int* s = r\n\tr = 0\n\tif s: return *s - 7\n\treturn 1\n", 0)
	optional_case(c"int main():\n\tint x = 7\n\toptrefmut int* r = &x\n\toptref int* s = r\n\tr = 0\n\tx = 9\n\tif s: return *s - 7\n\treturn 1\n", c"conflicting")
	optional_case(c"int main():\n\tint x = 7\n\toptrefmut int* r = &x\n\toptref int* s = r\n\tr = 0\n\tint value = x\n\tif s: return *s - value\n\treturn 1\n", 0)
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = &x\n\tif r && ((r = 0) == 0): return *r\n\treturn 0\n", c"presence check")
	optional_case(c"int maybe(optref int* r):\n\treturn r != 0 ? *r : 0\nint main():\n\tint x = 7\n\treturn maybe(&x) + maybe(0) - 7\n", 0)
	optional_case(c"int maybe(optref int* r):\n\tif 0 == r: return 0\n\treturn *r\nint main():\n\tint x = 7\n\treturn maybe(&x) - 7\n", 0)


void test_optional_imports_and_recursion():
	optional_case(c"import tests.safe_optional_import_fixture\nint main():\n\tint x = 7\n\tint y = 9\n\toptref int* r = optional_import_choose(&x, &y, 2)\n\tif r: return *r - 9\n\treturn 1\n", 0)
	optional_case(c"import tests.safe_optional_import_fixture\nint main():\n\tint x = 7\n\tint y = 9\n\toptref int* r = optional_import_choose(&x, &y, 2)\n\tx = 9\n\tif r: return *r - 9\n\treturn 1\n", c"conflicting")
	optional_case(c"import tests.safe_optional_import_fixture\nint main():\n\tint x = 7\n\toptrefmut int* r = optional_import_mutable(&x)\n\tif r: *r = 9\n\treturn x - 9\n", 0)
	optional_case(c"optref[a] int* optional_identity(optref[a] int* value);\noptref[b] int* optional_identity(optref[b] int* value):\n\treturn value\nint main():\n\tint x = 7\n\toptref int* r = optional_identity(&x)\n\tif r: return *r - 7\n\treturn 1\n", 0)
	optional_case(c"optref int* optional_recur(optref int* value, int depth):\n\tif depth == 0: return value\n\treturn optional_recur(value, depth - 1)\nint main():\n\tint x = 7\n\toptref int* r = optional_recur(&x, 3)\n\tif r: return *r - 7\n\treturn 1\n", 0)


void test_optional_replacement_evaluation():
	optional_case(c"int probe(optref int* r):\n\tif r: return *r\n\treturn 0\nint main():\n\town int* owner = new int\n\toptref int* r = owner\n\tr = 0\n\town int* moved = owner\n\treturn probe(r)\n", 0)
	optional_case(c"int change(refmut int* value):\n\t*value = 9\n\treturn 1\noptref int* choose(int ignored, optref int* value):\n\treturn value\nint main():\n\tint x = 7\n\toptref int* r = &x\n\tr = choose(change(&x), r)\n\tif r: return *r - 9\n\treturn 1\n", c"conflicting")
	optional_case(c"int change(refmut int* value):\n\t*value = 9\n\treturn 1\noptref int* choose(int ignored, ref int* value):\n\treturn value\nint main():\n\tint x = 7\n\toptref int* r = &x\n\tr = choose(change(&x), &x)\n\tif r: return *r - 9\n\treturn 1\n", 0)


void test_optional_absence_results():
	optional_case(c"optref int* absent():\n\treturn 0\nint main():\n\toptref int* r = absent()\n\tif r: return 1\n\treturn 0\n", 0)
	optional_case(c"optref int* invalid():\n\tint x = 7\n\treturn &x\nint main():\n\treturn 0\n", c"returned reference")
	optional_case(c"optref[a] int* invalid():\n\treturn 0\nint main():\n\treturn 0\n", c"returned lifetime must name")


void test_optional_assignment_values():
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = 0\n\tint address = (r = &x)\n\treturn address == 0\n", c"cannot escape", 1)
	optional_case(c"int main():\n\tint x = 7\n\toptref int* r = 0\n\treturn (r = &x)\n", c"cannot escape", 1)
	optional_case(c"int scalar(int address):\n\treturn address\nint main():\n\tint x = 7\n\toptref int* r = 0\n\treturn scalar(r = &x)\n", c"cannot escape", 1)


void test_optional_jump_scope_exit():
	optional_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\town int* local = new int\n\t\t\t*local = 7\n\t\t\tsaved = local\n\t\t\tbreak\n\tif saved: return *saved - 7\n\treturn 1\n", c"uninitialized or moved")
	optional_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tint local = 7\n\t\t\tsaved = &local\n\t\t\tbreak\n\tif saved: return *saved - 7\n\treturn 1\n", c"uninitialized or moved")
	optional_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tswitch 2:\n\t\t\t\tdefault:\n\t\t\t\t\town int* local = new int\n\t\t\t\t\tsaved = local\n\t\t\t\t\tbreak\n\t\t\tif saved: return *saved\n\treturn 0\n", c"uninitialized or moved")
	optional_case(c"int main():\n\town int* owner = new int\n\t*owner = 7\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\tsaved = owner\n\t\t\tbreak\n\tif saved: return *saved - 7\n\treturn 1\n", 0)
	optional_case(c"int main():\n\toptref int* saved = 0\n\tswitch 1:\n\t\tdefault:\n\t\t\town int* local = new int\n\t\t\tsaved = local\n\t\t\tsaved = 0\n\t\t\tbreak\n\tif saved: return 1\n\treturn 0\n", 0)
	optional_case(c"int main():\n\toptref int* saved = 0\n\tfor i in range(1):\n\t\tsaved = &i\n\t\tbreak\n\tif saved: return *saved\n\treturn 1\n", 0)
	optional_case(c"int main():\n\toptref int* saved = 0\n\tfor i in range(2):\n\t\town int* local = new int\n\t\tsaved = local\n\t\tswitch i:\n\t\t\tdefault: continue\n\tif saved: return *saved\n\treturn 0\n", c"uninitialized or moved")
