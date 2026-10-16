# wbuild: x64
# wbuild: deps=tests/safe_import_fixture.w deps=lib/safe.w deps=structures/w_list.w deps=tests/safe_cli_fixture.w
# Regression matrix for ownership analysis. Every fixture is checked with
# and without --safe, so qualifiers cannot silently change their semantics.
import lib.testing
import lib.process
import lib.file


int safe_case_number


void safe_compile_case(char* full, int mode, char* diagnostic, int relaxed):
	char* output = strjoin(full, c".out")
	unlink(output)
	char** args = strv_new(7 + mode)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"--quiet")
	strv_set(args, 2, c"--strict")
	if (relaxed): strv_set(args, 2, c"--quiet")
	if (__word_size__ == 8): strv_set(args, 2, c"x64")
	strv_set(args, 3, c"--inline")
	strv_set(args, 4, full)
	strv_set(args, 5, c"-o")
	strv_set(args, 6, output)
	if (mode): strv_set(args, 7, c"--safe")
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	assert1(result != 0)
	if (diagnostic != 0):
		assert_equal(1, result.status)
		assert_contains(result.stderr_text, diagnostic)
		assert1(open(output, 0, 0) < 0)
	else:
		if (result.status): print(result.stderr_text)
		assert_equal(0, result.status)
		char** run = strv_new(1)
		strv_set(run, 0, output)
		process_result* executed = process_run(output, run, 0, 0, 30000)
		assert1(executed != 0)
		assert_equal(0, executed.status)
		process_result_free(executed)
		free(cast(void*, run))
	process_result_free(result)
	free(cast(void*, args))
	unlink(output)
	free(output)


void safe_case(char* source, char* diagnostic, int relaxed = 0):
	safe_case_number = safe_case_number + 1
	char* number = itoa(safe_case_number)
	char* prefix = c"bin/safe_case32_"
	if (__word_size__ == 8): prefix = c"bin/safe_case64_"
	char* path = strjoin(prefix, number)
	free(number)
	char* full = strjoin(path, c".w")
	free(path)
	assert1(file_write_text(full, source))
	for mode in range(2):
		char** args = strv_new(6 + mode)
		strv_set(args, 0, c"bin/wv2")
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"--json")
		strv_set(args, 4, full)
		strv_set(args, 5, c"--strict")
		if (relaxed): strv_set(args, 5, c"--quiet")
		if (__word_size__ == 8):
			strv_set(args, 4, c"x64")
			strv_set(args, 5, full)
		if (mode): strv_set(args, 6, c"--safe")
		process_result* result = process_run(args[0], args, 0, 0, 30000)
		free(cast(void*, args))
		assert1(result != 0)
		if (diagnostic == 0):
			if (result.status): print(result.stdout_text)
			assert_equal(0, result.status)
		else:
			if (result.status == 0): print(full)
			assert_equal(1, result.status)
			if (assert_has(result.stdout_text, diagnostic) == 0): print(result.stdout_text)
			assert1(assert_has(result.stdout_text, diagnostic) != 0)
		process_result_free(result)
		safe_compile_case(full, mode, diagnostic, relaxed)
	unlink(full)
	free(full)


void test_safe_moves_and_borrows():
	safe_case(c"int main():\n\town int* p = new int\n\t*p = 7\n\tref int* r = p\n\tint n = *r\n\town int* q = p\n\treturn *q - n\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\town int* q = p\n\treturn *p\n", c"moved value")
	safe_case(c"int main():\n\town int* p = new int\n\tref int* r = p\n\t*p = 4\n\treturn *r\n", c"conflicting access")
	safe_case(c"int main():\n\town int* p = new int\n\trefmut int* r = p\n\tint n = *p\n\t*r = n\n\treturn 0\n", c"conflicting access")
	safe_case(c"int main():\n\town int* p = new int\n\trefmut int* r = p\n\tref int* s = r\n\tint n = *s\n\t*r = n + 1\n\treturn *p - 1\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\trefmut int* r = p\n\tref int* s = r\n\t*r = 8\n\treturn *s\n", c"conflicting access")
	safe_case(c"int main():\n\town int* p = new int\n\tref int* r = p\n\trefmut int* s = r\n\treturn *s\n", c"mutable borrow from a shared")
	safe_case(c"int main():\n\town int* p = new int\n\tint* q = p\n\treturn *q\n", c"unsupported type")
	safe_case(c"int main():\n\town int* p = 0\n\treturn 0\n", c"incompatible checked pointer")


void test_safe_control_flow():
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 1\n\tif n:\n\t\town int* q = p\n\treturn *p\n", c"moved value")
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 2\n\twhile n > 0:\n\t\town int* q = p\n\t\tn = n - 1\n\treturn 0\n", c"moved value")
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 2\n\twhile n > 0:\n\t\town int* q = p\n\t\tp = new int\n\t\tn = n - 1\n\treturn *p\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 2\n\tref int* r = p\n\twhile n > 0:\n\t\tn = *r\n\t\t*p = 0\n\treturn 0\n", c"conflicting access")
	safe_case(c"int main():\n\town int* p = new int\n\twhile 1:\n\t\town int* q = p\n\t\tbreak\n\treturn 0\n", 0)


void test_safe_calls():
	safe_case(c"int sum(int a, int b):\n\treturn a + b\nint change(refmut int* p):\n\t*p = 3\n\treturn *p\nint main():\n\town int* p = new int\n\tint n = 2\n\tint doubled = sum(n, n)\n\treturn sum(n, change(&n)) + doubled - 9\n", 0)
	safe_case(c"int take(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\t*p = 8\n\treturn take(p) - 8\n", 0)
	safe_case(c"int safe_read_value(ref int* p):\n\treturn *p\nint main():\n\tint n = 4\n\treturn safe_read_value(&n) - 4\n", 0)
	safe_case(c"int both(refmut int* a, ref int* b):\n\t*a = *b\n\treturn 0\nint main():\n\town int* p = new int\n\treturn both(p, p)\n", c"conflicting")
	safe_case(c"own int* make():\n\town int* p = new int\n\t*p = 3\n\treturn p\nint main():\n\town int* p = make()\n\treturn *p - 3\n", 0)
	safe_case(c"ref int* bad():\n\tint n = 4\n\treturn &n\nint main():\n\treturn 0\n", c"returning references")
	safe_case(c"int recur(ref int* p, int n):\n\tif n == 0: return *p\n\treturn recur(p, n - 1)\nint main():\n\town int* p = new int\n\treturn recur(p, 3)\n", 0)


void test_safe_arrays_slices_and_boundaries():
	safe_case(c"int sum(int[] s):\n\tint i = 0\n\tint n = 0\n\twhile i < s.length:\n\t\tn = n + s[i]\n\t\ti = i + 1\n\treturn n\nint main():\n\town int* p = new int\n\tint[3] a\n\ta[0] = 3\n\tint[] s = a[0:2]\n\treturn sum(s) - 3\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\tint[3] a\n\tint[] s = a[0:2]\n\ta[0] = 3\n\treturn s[0]\n", c"conflicting access")
	safe_case(c"int main():\n\town int* p = new int\n\tint[3] a\n\tint[] s = a[0:2]\n\ts[0] = 3\n\treturn 0\n", c"shared reference")
	safe_case(c"int main():\n\town int* p = new int\n\tunsafe:\n\t\tint n = 3\n\t\tint* q = &n\n\t\t*q = 4\n\treturn *p\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\tunsafe:\n\t\t*p = 3\n\treturn 0\n", c"cannot manipulate checked")
	safe_case(c"int main():\n\town int* p = new int\n\tdefer free(p)\n\treturn 0\n", c"runtime call has no audited ownership contract")
	safe_case(c"struct Box:\n\town int* p\nint main():\n\treturn 0\n", 0)
	safe_case(c"type Owner = own int*\nint main():\n\tOwner p = new int\n\tOwner q = p\n\treturn *p\n", c"moved value")


void test_safe_expression_paths():
	safe_case(c"int take(own int* p):\n\treturn *p\nint main():\n\town int* p = new int\n\tint n = 0\n\tint x = n && take(p)\n\treturn *p\n", c"moved value")
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 3\n\tif n > 0 && n < 4:\n\t\t*p = 7\n\treturn *p - 7\n", 0)
	safe_case(c"int change(refmut int* p):\n\t*p = 2\n\treturn 0\nint combine(ref int* p, int n):\n\treturn *p + n\nint main():\n\town int* p = new int\n\treturn combine(p, change(p))\n", c"conflicting access")
	safe_case(c"int main():\n\town int* p = new int\n\tint n\n\treturn n\n", c"uninitialized")
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 1\n\tif n:\n\t\town int* q = p\n\t\treturn *q\n\treturn *p\n", 0)


void test_safe_transitive_views_and_transfers():
	safe_case(c"int main():\n\town int* p = new int\n\tint[3] a\n\tint[] s = a[0:3]\n\tint[] t = s[0:2]\n\ta[0] = 5\n\treturn t[0]\n", c"conflicting access")
	safe_case(c"own int* bad():\n\town int* p = new int\nint main():\n\treturn 0\n", c"without returning a value")
	safe_case(c"int main():\n\town int* p = new int\n\tq := p\n\treturn *q\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\tq := p\n\treturn *p\n", c"moved value")
	safe_case(c"int main():\n\town int* p = new int\n\tref int* r = p\n\tref int* s = p\n\treturn *r + *s\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\tref char* r = p\n\treturn 0\n", c"incompatible checked pointer")
	safe_case(c"int main():\n\town int* p = new int\n\tint unsafe = 0\n\tunsafe = *p\n\treturn unsafe\n", 0)


void test_safe_import_contracts():
	safe_case(c"import tests.safe_import_fixture\nint main():\n\town int* p = new int\n\t*p = 3\n\tint n = safe_import_read(p)\n\treturn safe_import_consume(p) - n\n", 0)
	safe_case(c"import tests.safe_import_fixture\nint main():\n\town int* p = new int\n\tint n = safe_import_consume(p)\n\treturn *p + n\n", c"moved value")
	safe_case(c"import lib.safe\nint main():\n\town int* p = new int\n\tsafe_print_int(*p)\n\treturn 0\n", 0)


void test_safe_runtime_pins():
	char* root = c"bin/safe_pin32"
	if (__word_size__ == 8): root = c"bin/safe_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/structures")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/w_list.w")
	char* original = file_read_text(c"structures/w_list.w")
	char* modified = strjoin(original, c"\n# contract changed\n")
	assert1(file_write_text(path, modified))
	char** args = strv_new(8)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--json")
	strv_set(args, 3, c"--quiet")
	strv_set(args, 4, c"--safe")
	strv_set(args, 5, c"--import-root")
	strv_set(args, 6, root)
	strv_set(args, 7, c"tests/safe_cli_fixture.w")
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	assert1(result != 0)
	assert_equal(1, result.status)
	assert_contains(result.stdout_text, c"runtime implementation differs")
	process_result_free(result)
	free(cast(void*, args))
	unlink(path)
	free(original)
	free(modified)
	free(path)
	free(directory)


void test_safe_scalar_and_struct_operations():
	safe_case(c"struct Pair:\n\tint x\n\tint y\nint main():\n\town Pair* p = new Pair\n\tp.x = 3\n\tref Pair* r = p\n\treturn r.x - 3\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\tint16 n = 3\n\tint x = cast(int, n)\n\tx++\n\treturn x - 4\n", 0)
	safe_case(c"int main():\n\town int* p = new int\n\tint n = cast(int, p)\n\treturn n\n", c"casts require scalar")
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 1\n\tint x = n ? 4 : 3\n\treturn x - 4\n", 0)


void test_safe_representation_coverage():
	safe_case(c"int main():\n\tint n = 0\n\tif (n) own int* p = new int\n\treturn 0\n", c"unsupported expression fallback")
	safe_case(c"int bad(own int* p):\n\tasm x86:\n\t\t\"xor eax, eax\"\n\t\t\"ret\"\n\tasm x64:\n\t\t\"xor eax, eax\"\n\t\t\"ret\"\n\treturn *p\nint main():\n\town int* p = new int\n\treturn bad(p)\n", c"assembly function bodies")
	safe_case(c"int bad(own int* p):\n\tasm x86:\n\t\t\"jmp portable\"\n\tasm x64:\n\t\t\"jmp portable\"\n\treturn *p\nint main():\n\town int* p = new int\n\treturn bad(p)\n", c"assembly function bodies")


void test_safe_forward_contracts():
	safe_case(c"int later(ref int* p);\nint main():\n\town int* p = new int\n\treturn later(p)\nint later(ref int* p):\n\treturn *p\n", 0)
	safe_case(c"int later();\nint main():\n\town int* p = new int\n\treturn later()\nint later():\n\tint* raw = 0\n\treturn *raw\n", c"unsupported type")
	safe_case(c"int later(ref int* p);\nint main():\n\town int* p = new int\n\tint n = later(p)\n\treturn *p + n\nint later(own int* p):\n\treturn *p\n", c"forward declaration")


void test_safe_returned_references():
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\tint n = 7\n\tref int* r = view(&n)\n\treturn *r - 7\n", 0)
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\tref int* r = view(p)\n\t*p = 7\n\treturn *r\n", c"conflicting access")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\tref int* r = view(p)\n\town int* q = p\n\treturn *r\n", c"moved value")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\tref int* r = view(p)\n\tint n = *r\n\town int* q = p\n\treturn *q - n\n", 0)
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\trefmut int* r = view(p)\n\treturn *r\n", c"mutable borrow from a shared")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\tref int* r = view(view(p))\n\t*p = 1\n\treturn *r\n", c"conflicting access")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint read_view(ref int* p):\n\treturn *p\nint main():\n\tint n = 9\n\treturn read_view(view(view(&n))) - 9\n", 0)
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nrefmut int* view_mut(refmut int* p):\n\treturn p\nint main():\n\tint n = 5\n\trefmut int* m = view_mut(&n)\n\tref int* r = view(m)\n\tint old = *r\n\t*m = old + 1\n\treturn n - 6\n", 0)
	safe_case(c"refmut int* view_mut(refmut int* p):\n\treturn p\nint main():\n\tint n = 0\n\trefmut int* r = view_mut(view_mut(&n))\n\t*r = 3\n\treturn n - 3\n", 0)
	safe_case(c"refmut int* view_mut(refmut int* p):\n\treturn p\nint main():\n\tint n = 0\n\trefmut int* r = view_mut(&n)\n\tint old = n\n\t*r = old\n\treturn 0\n", c"conflicting access")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\trefmut int* m = p\n\tref int* r = view(m)\n\t*m = 3\n\treturn *r\n", c"conflicting access")
	safe_case(c"ref int* bad(ref int* p):\n\tint local = 1\n\treturn &local\nint main():\n\treturn 0\n", c"must borrow from")
	safe_case(c"ref int* bad(ref int* p):\n\town int* local = new int\n\treturn local\nint main():\n\treturn 0\n", c"must borrow from")
	safe_case(c"ref int* bad(own int* p):\n\treturn p\nint main():\n\treturn 0\n", c"exactly one borrowed parameter")
	safe_case(c"ref int* bad(ref int* a, ref int* b):\n\treturn a\nint main():\n\treturn 0\n", c"exactly one borrowed parameter")
	safe_case(c"refmut int* bad(ref int* p):\n\treturn p\nint main():\n\treturn 0\n", c"mutable reference return requires")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nref int* bad(ref int* p):\n\tint local = 0\n\treturn view(&local)\nint main():\n\treturn 0\n", c"must borrow from")
	safe_case(c"ref int* branch(ref int* p, int n):\n\tif n:\n\t\tref int* r = p\n\t\treturn r\n\treturn p\nint main():\n\tint n = 6\n\tref int* a = branch(&n, 1)\n\tref int* b = branch(&n, 0)\n\treturn *a + *b - 12\n", 0)
	safe_case(c"ref int* bad(ref int* p, int n):\n\tif n:\n\t\treturn p\n\tint local = 0\n\treturn &local\nint main():\n\treturn 0\n", c"must borrow from")
	safe_case(c"ref int* bad(ref int* p):\n\tif *p:\n\t\treturn p\nint main():\n\treturn 0\n", c"without returning a value")
	safe_case(c"ref int* recur(int n, ref int* p):\n\tif n == 0:\n\t\treturn p\n\treturn recur(n - 1, p)\nint main():\n\tint n = 3\n\tref int* r = recur(4, &n)\n\treturn *r - 3\n", 0)
	safe_case(c"refmut int* recur(refmut int* p, int n):\n\tif n == 0:\n\t\treturn p\n\trefmut int* r = recur(p, n - 1)\n\treturn r\nint main():\n\tint n = 3\n\trefmut int* r = recur(&n, 4)\n\t*r = 4\n\treturn n - 4\n", 0)
	safe_case(c"struct Pair:\n\tint x\n\tint y\nref int* first(ref Pair* p):\n\treturn &p.x\nint main():\n\town Pair* p = new Pair\n\tp.x = 11\n\tref int* r = first(p)\n\treturn *r - 11\n", 0)
	safe_case(c"struct Pair:\n\tint x\n\tint y\nrefmut int* first(refmut Pair* p):\n\treturn &p.x\nint main():\n\town Pair* p = new Pair\n\trefmut int* r = first(p)\n\t*r = 11\n\treturn p.x - 11\n", 0)
	safe_case(c"ref int* first(int[] values):\n\treturn &values[0]\nint main():\n\tint[2] values\n\tvalues[0] = 5\n\tref int* r = first(values[0:2])\n\treturn *r - 5\n", 0)
	safe_case(c"ref int* first(int[] values):\n\treturn &values[0]\nint main():\n\tint[2] values\n\tref int* r = first(values[0:2])\n\tvalues[0] = 5\n\treturn *r\n", c"conflicting access")
	safe_case(c"int[] bad(ref int* p):\n\tint[1] a\n\treturn a[0:1]\nint main():\n\town int* p = new int\n\treturn *p\n", c"returning slices")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\tref int* r = view(p)\n\tint n = 2\n\twhile n > 0:\n\t\tn = n - 1\n\t\tint value = *r\n\t\t*p = value\n\treturn 0\n", c"conflicting access")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\tint n = 2\n\twhile n > 0:\n\t\tref int* r = view(p)\n\t\tn = n - 1\n\t\tif *r: break\n\t*p = 4\n\treturn *p - 4\n", 0)
	safe_case(c"ref int* later(ref int* p);\nint main():\n\tint n = 8\n\tref int* r = later(&n)\n\treturn *r - 8\nint unused():\n\treturn 0\nref int* later(ref int* p):\n\treturn p\n", 0)
	safe_case(c"ref int* later(ref int* p);\nint main():\n\tint n = 8\n\tref int* r = later(&n)\n\treturn *r - 8\nref int* later(own int* p):\n\treturn p\n", c"forward declaration")
	safe_case(c"type View = ref int*\nView alias_view(View p):\n\treturn p\nint main():\n\tint n = 4\n\tView r = alias_view(&n)\n\treturn *r - 4\n", 0)
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint change(refmut int* p):\n\t*p = 2\n\treturn 0\nint combine(ref int* p, int n):\n\treturn *p + n\nint main():\n\town int* p = new int\n\treturn combine(view(p), change(p))\n", c"conflicting access")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint combine(refmut int* p, ref int* q):\n\treturn *p + *q\nint main():\n\town int* p = new int\n\treturn combine(p, view(p))\n", c"conflicting")
	safe_case(c"import tests.safe_import_fixture\nint main():\n\tint n = 8\n\tref int* r = safe_import_view(&n)\n\treturn *r - 8\n", 0)
	safe_case(c"import tests.safe_import_fixture\nint main():\n\tint n = 8\n\tref int* r = safe_import_view(&n)\n\tn = 1\n\treturn *r\n", c"conflicting access")


void test_safe_return_contract_boundaries():
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nown int* make():\n\town int* p = new int\n\treturn p\nint main():\n\tref int* r = view(make())\n\treturn *r\n", c"borrowed return contract")
	safe_case(c"ref int* bad(ref int* p, own int* q):\n\treturn q\nint main():\n\treturn 0\n", c"must borrow from")
	safe_case(c"ref int* bad(ref int* p, int n):\n\treturn &n\nint main():\n\treturn 0\n", c"must borrow from")
	safe_case(c"ref int* bad(ref int* p):\n\tref int* r = p\n\tunsafe:\n\t\treturn r\nint main():\n\treturn 0\n", c"cannot transfer control")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nint main():\n\town int* p = new int\n\tref int* r = view(p)\n\tp = new int\n\treturn *r\n", c"conflicting access")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nref int* bad(ref int* p):\n\tint n = 2\n\twhile n > 0:\n\t\tint local = n\n\t\tif n == 1: return view(&local)\n\t\tn = n - 1\n\treturn p\nint main():\n\treturn 0\n", c"must borrow from")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nref int* shared(refmut int* p):\n\tref int* r = view(p)\n\treturn r\nint main():\n\tint n = 7\n\tref int* r = shared(&n)\n\treturn *r - 7\n", 0)
	safe_case(c"ref int* bad(ref int* p, int[] s):\n\treturn p\nint main():\n\treturn 0\n", c"exactly one borrowed parameter")
	safe_case(c"refmut int* bad(int[] s):\n\treturn &s[0]\nint main():\n\treturn 0\n", c"mutable reference return requires")
	safe_case(c"ref int* bad(ref int* p):\n\treturn 0\nint main():\n\treturn 0\n", c"incompatible checked pointer")


void test_safe_reference_slice_representation():
	# Safety must reject these even when ordinary type warnings are nonfatal.
	safe_case(c"ref int* bad(int[] s):\n\treturn s\nint main():\n\treturn 0\n", c"pointer/slice representation mismatch", 1)
	safe_case(c"ref int* bad(int[] s):\n\treturn s[0:1]\nint main():\n\treturn 0\n", c"pointer/slice representation mismatch", 1)
	safe_case(c"ref int* bad(int[] s):\n\tref int* r = s\n\treturn r\nint main():\n\treturn 0\n", c"pointer/slice representation mismatch", 1)
	safe_case(c"int main():\n\tint n = 0\n\tref int* r = &n\n\tint[] s = r\n\treturn s[0]\n", c"pointer/slice representation mismatch", 1)
	safe_case(c"int main():\n\town int* p = new int\n\tint[] s = p\n\treturn s[0]\n", c"pointer/slice representation mismatch", 1)
	safe_case(c"int main():\n\town int* p = new int\n\tint n = 0\n\tint[] s = &n\n\treturn s[0]\n", c"pointer/slice representation mismatch", 1)


void test_safe_buffer_metadata_lifetimes():
	safe_case(c"ref int* bad(int[] s):\n\treturn &s.length\nint main():\n\treturn 0\n", c"buffer metadata cannot be borrowed")
	safe_case(c"ref int* bad(int[] s):\n\tint[] t = s[0:1]\n\treturn &t.length\nint main():\n\treturn 0\n", c"buffer metadata cannot be borrowed")
	safe_case(c"ref int* view(ref int* p):\n\treturn p\nref int* bad(int[] s):\n\tint[] t = s[0:1]\n\treturn view(&t.length)\nint main():\n\treturn 0\n", c"buffer metadata cannot be borrowed")
	safe_case(c"int main():\n\town int* p = new int\n\tint[1] a\n\trefmut int* size = &a.length\n\t*size = 999\n\treturn 0\n", c"buffer metadata cannot be borrowed")
	safe_case(c"int main():\n\town int* p = new int\n\tint[1] a\n\tref int* size = &a.length\n\treturn *size\n", c"buffer metadata cannot be borrowed")
	safe_case(c"struct Size:\n\tint length\nref int* field(ref Size* p):\n\treturn &p.length\nint main():\n\town Size* p = new Size\n\tp.length = 6\n\tref int* r = field(p)\n\treturn *r - 6\n", 0)
	safe_case(c"ref int* element(int[] s):\n\tint[] t = s[0:1]\n\treturn &t[0]\nint main():\n\tint[1] a\n\ta[0] = 7\n\tref int* r = element(a[0:1])\n\treturn *r - 7\n", 0)
