# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int nested_replacement_case_number


void nested_replacement_result(process_result* result, char* diagnostic, int checking, char* path):
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


void nested_replacement_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	nested_replacement_case_number = nested_replacement_case_number + 1
	char* number = itoa(nested_replacement_case_number)
	char* prefix = c"bin/nested_replacement_case32_"
	if (__word_size__ == 8): prefix = c"bin/nested_replacement_case64_"
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
		nested_replacement_result(checked, diagnostic, 1, full)
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
		nested_replacement_result(compiled, diagnostic, 0, full)
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


void test_nested_replacement_0():
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* value = outer.left.first\n\touter.left.first = value\n\town Outer* complete = outer\n\treturn complete.left.tag - 3\n", 0)
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\trefmut int* sibling = outer.left.second\n\touter.left.first = new int\n\t*sibling = 8\n\treturn *sibling - 8\n", 0)
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\trefmut Child* sibling = outer.right\n\touter.left.first = new int\n\tsibling.tag = 8\n\treturn sibling.tag - 8\n", 0)
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\tref int* value = outer.left.first\n\touter.left.first = new int\n\treturn *value\n", c"conflicting")
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\tref Child* value = outer.left\n\touter.left.first = new int\n\treturn value.tag\n", c"conflicting")
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\touter.left.first = outer.left.first\n\trefmut int* first = outer.left.first\n\t*first = 9\n\treturn *first - 9\n", 0)
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\touter.left.first = outer.left.second\n\touter.left.second = new int\n\town Outer* complete = outer\n\treturn complete.left.tag - 3\n", 0)
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nown int* take(own Child* child):\n\treturn child.first\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\touter.left.first = take(outer.left)\n\treturn 0\n", c"conflicting")

void test_nested_replacement_1():
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nown int* take(own Outer* owner):\n\treturn owner.left.first\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\touter.left.first = take(outer)\n\treturn 0\n", c"conflicting")
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nown int* take(own Child* child):\n\treturn child.first\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\touter.left.first = take(outer.right)\n\touter.right = new Child(new int, new int, 8)\n\treturn outer.right.tag - 8\n", 0)
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nvoid bad(refmut Outer* outer):\n\touter.left.first = new int\nint main():\n\treturn 0\n", c"stable unique owner path")
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town Child* left = outer.left\n\touter.left.first = new int\n\treturn left.tag - 3\n", c"moved")
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\touter.left.second = new int\n\town Outer* complete = outer\n\treturn complete.left.tag - 3\n", c"moved")
	nested_replacement_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\tfor i in range(4):\n\t\town int* first = outer.left.first\n\t\touter.left.first = new int\n\t\tif (i < 2): continue\n\t\tbreak\n\town Outer* complete = outer\n\treturn complete.left.tag - 3\n", 0)
	nested_replacement_case(c"struct Leaf:\n\trefmut[first] int* first\n\trefmut[second] int* second\nstruct Middle:\n\town[y,x] Leaf* leaf\nstruct Outer:\n\town[b,a] Middle* middle\nint main():\n\tint x = 2\n\tint y = 3\n\tint z = 4\n\town[a,b] Outer* outer = new Outer(new Middle(new Leaf(&x, &y)))\n\touter.middle.leaf.first = &z\n\trefmut int* first = outer.middle.leaf.first\n\t*first = 8\n\treturn z - 8\n", 0)
	nested_replacement_case(c"struct Leaf:\n\trefmut[first] int* first\n\trefmut[second] int* second\nstruct Middle:\n\town[y,x] Leaf* leaf\nstruct Outer:\n\town[b,a] Middle* middle\nint main():\n\tint x = 2\n\tint y = 3\n\tint z = 4\n\town[a,b] Outer* outer = new Outer(new Middle(new Leaf(&x, &y)))\n\touter.middle.leaf.first = &x\n\trefmut int* first = outer.middle.leaf.first\n\t*first = 8\n\treturn x - 8\n", 0)

void test_nested_replacement_2():
	nested_replacement_case(c"struct Leaf:\n\trefmut[first] int* first\n\trefmut[second] int* second\nstruct Middle:\n\town[y,x] Leaf* leaf\nstruct Outer:\n\town[b,a] Middle* middle\nint main():\n\tint x = 2\n\tint y = 3\n\tint z = 4\n\town[a,b] Outer* outer = new Outer(new Middle(new Leaf(&x, &y)))\n\touter.middle.leaf.second = &y\n\trefmut int* second = outer.middle.leaf.second\n\t*second = 8\n\treturn y - 8\n", 0)
	nested_replacement_case(c"struct Leaf:\n\trefmut[first] int* first\n\trefmut[second] int* second\nstruct Middle:\n\town[y,x] Leaf* leaf\nstruct Outer:\n\town[b,a] Middle* middle\nint main():\n\tint x = 2\n\tint y = 3\n\tint z = 4\n\town[a,b] Outer* outer = new Outer(new Middle(new Leaf(&x, &y)))\n\touter.middle.leaf.first = &y\n\trefmut int* first = outer.middle.leaf.first\n\treturn *first\n", c"conflicting")
	nested_replacement_case(c"struct Leaf:\n\trefmut[first] int* first\n\trefmut[second] int* second\nstruct Middle:\n\town[y,x] Leaf* leaf\nstruct Outer:\n\town[b,a] Middle* middle\nint main():\n\tint x = 2\n\tint y = 3\n\tint z = 4\n\town[a,b] Outer* outer = new Outer(new Middle(new Leaf(&x, &y)))\n\trefmut int* old = outer.middle.leaf.first\n\touter.middle.leaf.first = old\n\treturn 0\n", c"reborrow cycle")
	nested_replacement_case(c"struct Leaf:\n\trefmut[first] int* first\n\trefmut[second] int* second\nstruct Middle:\n\town[y,x] Leaf* leaf\nstruct Outer:\n\town[b,a] Middle* middle\nint main():\n\tint x = 2\n\tint y = 3\n\tint z = 4\n\town[a,b] Outer* outer = new Outer(new Middle(new Leaf(&x, &y)))\n\tif (z):\n\t\tint local = 7\n\t\touter.middle.leaf.first = &local\n\trefmut int* first = outer.middle.leaf.first\n\treturn *first\n", c"moved")
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint main():\n\tint[2] a\n\tint[3] b\n\tb[1] = 7\n\town[group] Outer* outer = new Outer(new Middle(new Leaf(a)))\n\tref int[] old = outer.middle.leaf.data\n\touter.middle.leaf.data = b\n\tref int[] view = outer.middle.leaf.data\n\treturn old.length + view[1] - 9\n", 0)
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nown[a] Outer* bad(ref[a] int[] data):\n\town[a] Outer* outer = new Outer(new Middle(new Leaf(data)))\n\tint[2] local\n\touter.middle.leaf.data = local\n\treturn outer\nint main():\n\treturn 0\n", c"return")
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint main():\n\tint[2] a\n\tint[3] b\n\tb[1] = 7\n\town[group] Outer* outer = new Outer(new Middle(new Leaf(a)))\n\touter.middle.leaf.data = b\n\tdefer (b[1] = 8)\n\tref int[] view = outer.middle.leaf.data\n\treturn view[1] - 7\n", 0)
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint inspect(ref int[] value):\n\treturn value[0]\nint main():\n\tint[2] a\n\tint[3] b\n\tb[1] = 7\n\town[group] Outer* outer = new Outer(new Middle(new Leaf(a)))\n\touter.middle.leaf.data = b\n\tdefer (inspect(outer.middle.leaf.data))\n\tb[1] = 8\n\treturn 0\n", c"conflicting")

void test_nested_replacement_3():
	nested_replacement_case(c"struct Leaf:\n\trefmut[g] int* value\nstruct Middle:\n\town[g] Leaf* leaf\n\trefmut[g] int* sibling\nstruct Outer:\n\town[g] Middle* middle\nint main():\n\tint x = 1\n\tint y = 2\n\town[g] Outer* outer = new Outer(new Middle(new Leaf(&x), &y))\n\touter.middle.leaf.value = &y\n\trefmut int* value = outer.middle.leaf.value\n\treturn *value\n", c"conflicting")
	nested_replacement_case(c"struct Leaf:\n\trefmut[g] int* value\nstruct Middle:\n\town[g] Leaf* leaf\nstruct Outer:\n\town[g] Middle* middle\n\trefmut[g] int* sibling\nint main():\n\tint x = 1\n\tint y = 2\n\town[g] Outer* outer = new Outer(new Middle(new Leaf(&x)), &y)\n\touter.middle.leaf.value = &y\n\trefmut int* value = outer.middle.leaf.value\n\treturn *value\n", c"conflicting")
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nown[a] Outer* bad(own[a] Outer* outer, ref[b] int[] data):\n\touter.middle.leaf.data = data\n\treturn outer\nint main():\n\treturn 0\n", c"must borrow from")
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nown[a] Outer* change(own[a] Outer* outer, ref[b] int[] data) where b > a:\n\touter.middle.leaf.data = data\n\treturn outer\nint main():\n\tint[2] a\n\tint[3] b\n\tb[1] = 7\n\town[group] Outer* outer = new Outer(new Middle(new Leaf(a)))\n\touter = change(outer, b)\n\tref int[] view = outer.middle.leaf.data\n\treturn view[1] - 7\n", 0)
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint main():\n\tint[2] a\n\tint[3] b\n\tb[1] = 7\n\town[group] Outer* outer = new Outer(new Middle(new Leaf(a)))\n\touter.middle.leaf = new Leaf(b)\n\tref int[] view = outer.middle.leaf.data\n\treturn view[1] - 7\n", 0)
	nested_replacement_case(c"struct Leaf:\n\tref[data] int[] data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint main():\n\tint[2] a\n\tint[3] b\n\tb[1] = 7\n\town[group] Outer* outer = new Outer(new Middle(new Leaf(a)))\n\tref int[] old = outer.middle.leaf.data\n\touter.middle.leaf = new Leaf(b)\n\treturn old.length - 2\n", 0)
	nested_replacement_case(c"struct Leaf:\n\trefmut[first] int* first\n\trefmut[second] int* second\nstruct Middle:\n\town[y,x] Leaf* leaf\nstruct Outer:\n\town[b,a] Middle* middle\nint main():\n\tint x = 2\n\tint y = 3\n\tint z = 4\n\town[a,b] Outer* outer = new Outer(new Middle(new Leaf(&x, &y)))\n\touter.middle.leaf = new Leaf(&x, &y)\n\trefmut int* value = outer.middle.leaf.first\n\t*value = 8\n\treturn x - 8\n", 0)
