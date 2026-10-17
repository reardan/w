# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int nested_move_case_number


void nested_move_result(process_result* result, char* diagnostic, int checking, char* path):
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


void nested_move_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	nested_move_case_number = nested_move_case_number + 1
	char* number = itoa(nested_move_case_number)
	char* prefix = c"bin/nested_move_case32_"
	if (__word_size__ == 8): prefix = c"bin/nested_move_case64_"
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
		nested_move_result(checked, diagnostic, 1, full)
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
		nested_move_result(compiled, diagnostic, 0, full)
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





void test_nested_move_0():
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\trefmut int* second = outer.left.second\n\t*first = 7\n\t*second = 8\n\treturn *first + *second - 15\n", 0)
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\town int* second = outer.right.first\n\t*first = 7\n\t*second = 8\n\treturn *first + *second - 15\n", 0)
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\town int* again = outer.left.first\n\treturn 0\n", c"moved")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\town Child* left = outer.left\n\treturn 0\n", c"moved")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\town Outer* moved = outer\n\treturn 0\n", c"moved")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\tref Child* left = outer.left\n\treturn left.tag\n", c"moved")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\trefmut int* second = outer.right.second\n\t*first = 7\n\t*second = 8\n\treturn *first + *second - 15\n", 0)
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\touter.left = new Child(new int, new int, 7)\n\town Outer* moved = outer\n\treturn moved.left.tag - 7\n", 0)

void test_nested_move_1():
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\touter = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\t*first = 8\n\treturn *first - 8\n", 0)
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\tref int* borrowed = outer.left.first\n\town int* first = outer.left.first\n\treturn *borrowed\n", c"moved")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\tref Child* borrowed = outer.left\n\town int* first = outer.left.first\n\treturn borrowed.tag\n", c"conflicting")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nown int* take(own Outer* outer):\n\treturn outer.left.first\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = take(outer)\n\t*first = 8\n\treturn *first - 8\n", 0)
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nown int* bad(refmut Outer* outer):\n\treturn outer.left.first\nint main():\n\treturn 0\n", c"unique owner path")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nown int* bad(ref Outer* outer):\n\treturn outer.left.first\nint main():\n\treturn 0\n", c"unique owner path")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nown T* pass[T](own T* value):\n\treturn value\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = pass[int](outer.left.first)\n\t*first = 8\n\treturn *first - 8\n", 0)
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\tif (outer.left.tag):\n\t\town int* first = outer.left.first\n\tref int* borrowed = outer.left.first\n\treturn *borrowed\n", c"moved")

void test_nested_move_2():
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\tfor i in range(3):\n\t\town int* first = outer.left.first\n\t\touter.left = new Child(new int, new int, i)\n\t\tif (i == 0): continue\n\t\tbreak\n\treturn outer.left.tag - 1\n", 0)
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\touter.left.first = first\n\treturn 0\n", c"named unique owner")
	nested_move_case(c"struct Leaf:\n\town int* stored\n\trefmut[data] int* data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Middle(new Leaf(new int, &x)))\n\town[a] Leaf* leaf = outer.middle.leaf\n\trefmut int* value = leaf.data\n\t*value = 8\n\treturn x - 8\n", 0)
	nested_move_case(c"struct Leaf:\n\town int* stored\n\trefmut[data] int* data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nown[a] Leaf* take(own[a] Outer* outer):\n\treturn outer.middle.leaf\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Middle(new Leaf(new int, &x)))\n\town[a] Leaf* leaf = take(outer)\n\trefmut int* value = leaf.data\n\t*value = 8\n\treturn x - 8\n", 0)
	nested_move_case(c"struct Leaf:\n\town int* stored\n\trefmut[data] int* data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Middle(new Leaf(new int, &x)))\n\town[a] Leaf* leaf = outer.middle.leaf\n\trefmut int* value = outer.middle.leaf.data\n\treturn *value\n", c"moved")
	nested_move_case(c"struct Leaf:\n\town int* stored\n\trefmut[data] int* data\nstruct Middle:\n\town[group] Leaf* leaf\nstruct Outer:\n\town[group] Middle* middle\nint main():\n\tint x = 3\n\town[a] Outer* outer = new Outer(new Middle(new Leaf(new int, &x)))\n\trefmut int* value = outer.middle.leaf.data\n\town[a] Leaf* leaf = outer.middle.leaf\n\treturn *value\n", c"conflicting")
	nested_move_case(c"struct Child:\n\town int* first\n\town int* second\n\tint tag\nstruct Outer:\n\town Child* left\n\town Child* right\nint inspect(ref Child* child):\n\tref int* first = child.first\n\treturn *first\nint main():\n\town Outer* outer = new Outer(new Child(new int, new int, 3), new Child(new int, new int, 4))\n\town int* first = outer.left.first\n\treturn inspect(outer.left)\n", c"moved")
