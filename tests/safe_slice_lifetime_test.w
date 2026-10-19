# wbuild: x64
# wbuild: deps=tests/safe_slice_lifetime_import_fixture.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int slice_lifetime_case_number


void slice_lifetime_result(process_result* result, char* diagnostic, int checking, char* path):
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


void slice_lifetime_case(char* source, char* diagnostic, int relaxed = 0, char* runtime_diagnostic = 0):
	slice_lifetime_case_number = slice_lifetime_case_number + 1
	char* number = itoa(slice_lifetime_case_number)
	char* prefix = c"bin/slice_lifetime_case32_"
	if (__word_size__ == 8): prefix = c"bin/slice_lifetime_case64_"
	char* path = strjoin(prefix, number)
	free(number)
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
		slice_lifetime_result(checked, diagnostic, 1, full)
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
		slice_lifetime_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			if (runtime_diagnostic):
				assert_equal(1, executed.status)
				assert_contains(executed.stderr_text, runtime_diagnostic)
			else: assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)


void test_checked_slice_values():
	slice_lifetime_case(c"int main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = values\n\treturn s[0] + s.length - 9\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = view(values)\n\treturn s[0] + s.length - 9\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = view(view(view(values)))\n\treturn s[0] + s.length - 9\n", 0)
	slice_lifetime_case(c"int main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = values\n\tref int[] t = s\n\treturn s[0] + t[0] + t.length - 16\n", 0)
	slice_lifetime_case(c"ref int[] inferred(ref int[] values):\n\treturn values\nint main():\n\tint[1] values\n\tvalues[0] = 7\n\tref int[] s = inferred(values)\n\treturn s[0] - 7\n", 0)
	slice_lifetime_case(c"type View = ref[a] int[]\nView identity(View values):\n\treturn values\nint main():\n\tint[1] values\n\tvalues[0] = 7\n\tView s = identity(values)\n\treturn s[0] - 7\n", 0)
	slice_lifetime_case(c"ref[a] char[] bytes(ref[a] char[] values):\n\treturn values\nint main():\n\tchar[3] values\n\tvalues[0] = 65\n\tvalues[1] = 0\n\tvalues[2] = 66\n\tref char[] s = bytes(values)\n\treturn cast(int, s[0]) + cast(int, s[1]) + cast(int, s[2]) + s.length - 134\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[0] values\n\tref int[] s = view(values)\n\treturn s.length\n", c"array length must be positive")


void test_checked_slice_return_storage():
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint clobber(int n):\n\tint[64] values\n\tvalues[0] = n\n\treturn values[0]\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = view(values)\n\tint n = clobber(5)\n\treturn s[0] + s.length + n - 14\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[1] a\n\tint[2] b\n\ta[0] = 7\n\tb[0] = 9\n\tref int[] s = view(a)\n\tref int[] t = view(b)\n\treturn s[0] + t[0] + s.length + t.length - 19\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint sum(int before, ref int[] values, int after):\n\treturn before + values[0] + values.length + after\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\treturn sum(3, view(values), 5) - 17\n", 0)
	slice_lifetime_case(c"ref[a] int[] middle(int before, ref[a] int[] values, int after):\n\tif before < after: return values\n\treturn values\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = middle(3, values, 5)\n\treturn s[0] + s.length - 9\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint pair(ref int[] a, int middle, ref int[] b):\n\treturn a[0] + a.length + middle + b[0] + b.length\nint main():\n\tint[1] a\n\tint[2] b\n\ta[0] = 7\n\tb[0] = 9\n\treturn pair(view(a), 3, view(b)) - 22\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nref[a] int* element(ref[a] int[] values):\n\treturn &values[0]\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int* p = element(view(values))\n\treturn *p - 7\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nref[a] int[] recurse(ref[a] int[] values, int n):\n\tif n == 0: return view(values)\n\treturn recurse(values, n - 1)\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = recurse(values, 4)\n\treturn s[0] + s.length - 9\n", 0)


void test_checked_slice_origins():
	slice_lifetime_case(c"ref[a] int[] choose(ref[a] int[] left, ref[a] int[] right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint[1] a\n\tint[2] b\n\ta[0] = 7\n\tb[0] = 9\n\tref int[] s = choose(a, b, 0)\n\treturn s[0] + s.length - 11\n", 0)
	slice_lifetime_case(c"ref[a] int[] choose(ref[a] int[] left, ref[a] int[] right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint[1] a\n\tint[2] b\n\tref int[] s = choose(a, b, 1)\n\ta[0] = 9\n\treturn s[0]\n", c"conflicting")
	slice_lifetime_case(c"ref[a] int[] choose(ref[a] int[] left, ref[a] int[] right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint[1] a\n\tint[2] b\n\tref int[] s = choose(a, b, 1)\n\tb[0] = 9\n\treturn s[0]\n", c"conflicting")
	slice_lifetime_case(c"ref[a] int[] choose(ref[a] int[] left, ref[a] int[] right, int first):\n\tif first: return left\n\treturn right\nint main():\n\tint[1] a\n\tint[2] b\n\ta[0] = 7\n\tref int[] s = choose(a, b, 1)\n\tint old = s[0]\n\ta[0] = 3\n\tb[0] = 5\n\treturn old + a[0] + b[0] - 15\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nref[a] int* element(ref[a] int[] values):\n\treturn &values[0]\nint main():\n\tint[1] values\n\tref int* p = element(view(values))\n\tvalues[0] = 9\n\treturn *p\n", c"conflicting")
	slice_lifetime_case(c"ref[a] int[] first(ref[a] int[] a, ref[b] int[] b):\n\treturn a\nint main():\n\tint[1] a\n\tint[2] b\n\ta[0] = 7\n\tref int[] s = first(a, b)\n\tb[0] = 9\n\treturn s[0] + b[0] - 16\n", 0)
	slice_lifetime_case(c"ref[a] int[] bad(ref[a] int[] a):\n\tint[1] local\n\treturn local\nint main():\n\treturn 0\n", c"must borrow from")
	slice_lifetime_case(c"ref[a] int[] bad(ref[a] int[] a, ref[b] int[] b):\n\treturn b\nint main():\n\treturn 0\n", c"must borrow from")


void test_checked_slice_imports_and_forwards():
	slice_lifetime_case(c"import tests.safe_slice_lifetime_import_fixture\nint main():\n\tint[2] values\n\tvalues[0] = 7\n\tref int[] s = slice_lifetime_import_view(values)\n\tref int* p = slice_lifetime_import_element(s)\n\treturn *p + s.length - 9\n", 0)
	slice_lifetime_case(c"ref[a] int[] later(ref[a] int[] a, ref[b] int[] b);\nint main():\n\tint[1] a\n\tint[2] b\n\ta[0] = 7\n\tref int[] s = later(a, b)\n\tb[0] = 9\n\treturn s[0] + b[0] - 16\nref[x] int[] later(ref[x] int[] p, ref[y] int[] q):\n\treturn p\n", 0)


void test_checked_slice_boundaries():
	slice_lifetime_case(c"int main():\n\tint[1] values\n\tref int[] s = values\n\ts[0] = 9\n\treturn 0\n", c"shared reference")
	slice_lifetime_case(c"int main():\n\tint[1] values\n\tref int[] s = values\n\trefmut int* p = &s[0]\n\treturn *p\n", c"mutable borrow from a shared")
	slice_lifetime_case(c"ref[a] int* bad(ref[a] int[] s):\n\treturn &s.length\nint main():\n\treturn 0\n", c"buffer metadata cannot be borrowed")
	slice_lifetime_case(c"int main():\n\tint[1] values\n\tref int[] s = values\n\tref int* p = s.data\n\treturn *p\n", c"safe:", 1)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[1] values\n\tint[] raw = values[0:1]\n\tref int[] s = view(raw)\n\treturn s.length\n", c"safe:", 1)
	slice_lifetime_case(c"int main():\n\tint[1] values\n\tref int[] s = values\n\tint[] raw = s\n\treturn raw.length\n", c"safe:", 1)
	slice_lifetime_case(c"int main():\n\tint[1] values\n\tref int[] s = values[0:1]\n\treturn s.length\n", c"safe:", 1)
	slice_lifetime_case(c"int main():\n\tint[1] values\n\tref int[] s = values\n\tref int[] t = s[0:1]\n\treturn t.length - 1\n", 0)
	slice_lifetime_case(c"int main():\n\tint n = 0\n\tref int* p = &n\n\tref int[] s = p\n\treturn s.length\n", c"incompatible checked slice types", 1)
	slice_lifetime_case(c"int main():\n\tref int[] s\n\treturn 0\n", c"initialization")
	slice_lifetime_case(c"int main():\n\tint[1] a\n\tint[1] b\n\tref int[] s = a\n\ts = b\n\treturn s.length\n", c"cannot be reassigned")


void test_checked_slice_ranges():
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[1:3]\n\treturn t[0] + t[1] + t.length - 14\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[0:0]\n\treturn t.length\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[s.length:s.length]\n\treturn t.length\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[:2]\n\treturn t[0] + t[1] + t.length - 10\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[1:]\n\treturn t[0] + t[1] + t.length - 14\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[:]\n\treturn t[0] + t[2] + t.length - 13\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[1:3][0:1]\n\treturn t[0] + t.length - 6\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = view(s)[1:3]\n\treturn t[0] + t.length - 7\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = view(s[1:3])\n\treturn t[0] + t.length - 7\n", 0)
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = view(view(s)[1:3][0:1])\n\treturn t[0] + t.length - 6\n", 0)
	slice_lifetime_case(c"ref[a] int[] tail(ref[a] int[] values):\n\treturn values[1:]\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = tail(tail(s))\n\treturn t[0] + t.length - 8\n", 0)
	slice_lifetime_case(c"ref[a] int[] empty(ref[a] int[] values):\n\treturn values[0:0]\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = empty(s)\n\treturn t.length\n", 0)
	slice_lifetime_case(c"ref[a] int* second(ref[a] int[] values):\n\tref int[] tail = values[1:]\n\treturn &tail[0]\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int* p = second(s)\n\treturn *p - 5\n", 0)
	slice_lifetime_case(c"ref[a] char[] tail(ref[a] char[] values):\n\treturn values[1:]\nint main():\n\tchar[3] values\n\tvalues[0] = 65\n\tvalues[1] = 0\n\tvalues[2] = 66\n\tref char[] s = values\n\tref char[] t = tail(s)\n\treturn cast(int, t[0]) + cast(int, t[1]) + t.length - 68\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[1:3]\n\tvalues[0] = 9\n\treturn t[0]\n", c"conflicting")
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = view(s)[1:3]\n\tvalues[0] = 9\n\treturn t[0]\n", c"conflicting")
	slice_lifetime_case(c"int lower(refmut int* calls):\n\t*calls = *calls + 1\n\treturn 1\nint upper(refmut int* calls):\n\t*calls = *calls + 1\n\treturn 3\nint main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tint calls = 0\n\tref int[] t = s[lower(&calls):upper(&calls)]\n\treturn t[0] + t.length + calls - 9\n", 0)
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tint low = -1\n\tref int[] t = s[low:2]\n\treturn t.length\n", 0, 0, c"index out of range: index -1, length 3")
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tint high = 4\n\tref int[] t = s[0:high]\n\treturn t.length\n", 0, 0, c"index out of range: index 4, length 3")
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tint low = 2\n\tref int[] t = s[low:1]\n\treturn t.length\n", 0, 0, c"index out of range: index 2, length 1")
	slice_lifetime_case(c"int main():\n\tint[3] values\n\tvalues[0] = 3\n\tvalues[1] = 5\n\tvalues[2] = 7\n\tref int[] s = values\n\tref int[] t = s[0:0]\n\treturn t[0]\n", 0, 0, c"index out of range: index 0, length 0")


void test_checked_slice_temporary_boundaries():
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint change(refmut int* p):\n\t*p = 9\n\treturn 0\nint main():\n\tint[2] values\n\tref int[] s = view(values)[change(&values[0]):1]\n\treturn s[0]\n", c"conflicting")
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint change(refmut int* p):\n\t*p = 9\n\treturn 1\nint main():\n\tint[2] values\n\tref int[] s = view(values)[0:change(&values[0])]\n\treturn s[0]\n", c"conflicting")
	slice_lifetime_case(c"int consume(int n):\n\treturn n\nint main():\n\tint[3] values\n\tref int[] s = values\n\treturn consume(s[1:3].length)\n", c"named checked pointer")
	slice_lifetime_case(c"ref[a] int[] view(ref[a] int[] values):\n\treturn values\nint main():\n\tint[3] values\n\tref int[] s = values\n\treturn view(s)[0]\n", c"named checked pointer")
