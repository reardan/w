# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int optional_owner_case_number


void optional_owner_result(process_result* result, char* diagnostic, int checking, char* path):
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


void optional_owner_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	optional_owner_case_number = optional_owner_case_number + 1
	char* number = itoa(optional_owner_case_number)
	char* prefix = c"bin/optional_owner_case32_"
	if (__word_size__ == 8): prefix = c"bin/optional_owner_case64_"
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
		optional_owner_result(checked, diagnostic, 1, full)
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
		optional_owner_result(compiled, diagnostic, 0, full)
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










void test_optional_owner_0():
	optional_owner_case(c"int main():\n\toptown int* value = 0\n\tif (value): return 1\n\treturn 0\n", 0)
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\t*value = 7\n\treturn *value - 7\n", 0)
	optional_owner_case(c"int main():\n\toptown int* value = 0\n\treturn *value\n", c"presence check")
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\toptown int* next = value\n\t*next = 7\n\treturn *next - 7\n", 0)
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\toptown int* next = value\n\treturn *value\n", c"moved")
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\tvalue = 0\n\treturn *value\n", c"presence check")
	optional_owner_case(c"int main():\n\toptown int* value = 0\n\tvalue = new int\n\t*value = 7\n\treturn *value - 7\n", 0)
	optional_owner_case(c"int main():\n\toptown int* value = 0\n\town int* next = value\n\treturn 0\n", c"presence check")

void test_optional_owner_1():
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\town int* next = value\n\t*next = 7\n\treturn *next - 7\n", 0)
	optional_owner_case(c"int main():\n\town int* value = 0\n\treturn 0\n", c"incompatible checked pointer")
	optional_owner_case(c"optown int* make(int choose):\n\tif (choose): return new int\n\treturn 0\nint main():\n\toptown int* value = make(1)\n\tif (value):\n\t\t*value = 7\n\t\treturn *value - 7\n\treturn 1\n", 0)
	optional_owner_case(c"optown int* make(int choose):\n\tif (choose): return new int\n\treturn 0\nint main():\n\toptown int* value = make(1)\n\treturn *value\n", c"presence check")
	optional_owner_case(c"optown int* make(int choose):\n\tif (choose): return new int\n\treturn 0\nint main():\n\toptown int* value = make(1)\n\tif (value):\n\t\town int* next = value\n\t\treturn *next\n\treturn 0\n", 0)
	optional_owner_case(c"optown int* make(int choose):\n\tif (choose): return new int\n\treturn 0\nint main():\n\toptown int* value = make(0)\n\twhile (value): value = 0\n\treturn 0\n", 0)
	optional_owner_case(c"optown int* make(int choose):\n\tif (choose): return new int\n\treturn 0\nint main():\n\toptown int* value = make(1)\n\tif (value): value = 0\n\treturn *value\n", c"presence check")
	optional_owner_case(c"optown int* pass_owner(optown int* value):\n\treturn value\nint main():\n\toptown int* value = pass_owner(0)\n\tif (value): return 1\n\treturn 0\n", 0)

void test_optional_owner_2():
	optional_owner_case(c"int consume(optown int* value):\n\tif (value): return *value\n\treturn 0\nint main():\n\toptown int* value = new int\n\t*value = 7\n\treturn consume(value) - 7\n", 0)
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\tref int* view = value\n\tvalue = 0\n\treturn *view\n", c"conflicting")
	optional_owner_case(c"int main():\n\toptown int* value = 0\n\toptref int* view = value\n\tif (view): return 1\n\treturn 0\n", 0)
	optional_owner_case(c"int main():\n\toptown int* value = 0\n\tref int* view = value\n\treturn *view\n", c"presence check")
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\tvalue = value\n\t*value = 7\n\treturn *value - 7\n", 0)
	optional_owner_case(c"struct Box:\n\toptown int* child\n\tint tag\nint main():\n\town Box* box = new Box(0, 7)\n\toptown int* child = box.child\n\tif (child): return 1\n\treturn box.tag - 7\n", 0)
	optional_owner_case(c"struct Box:\n\toptown int* child\n\tint tag\nint main():\n\town Box* box = new Box(new int, 7)\n\treturn *box.child\n", c"presence check")
	optional_owner_case(c"struct Box:\n\toptown int* child\n\tint tag\nint main():\n\town Box* box = new Box(new int, 7)\n\toptown int* child = box.child\n\tif (child): *child = 7\n\tbox.child = child\n\toptown int* next = box.child\n\tif (next): return *next - 7\n\treturn 1\n", 0)

void test_optional_owner_3():
	optional_owner_case(c"struct Box:\n\toptown int* child\n\tint tag\nint main():\n\town Box* box = new Box(new int, 7)\n\tbox.child = 0\n\tbox.child = new int\n\toptown int* child = box.child\n\tif (child): return *child\n\treturn 1\n", 0)
	optional_owner_case(c"struct Box:\n\toptown int* child\n\tint tag\nint main():\n\toptown Box* box = new Box(0, 7)\n\treturn box.tag - 7\n", 0)
	optional_owner_case(c"struct Box:\n\toptown int* child\n\tint tag\nint main():\n\toptown Box* box = 0\n\treturn box.tag\n", c"presence check")
	optional_owner_case(c"optown int* identity[T](optown T* value):\n\treturn value\nint main():\n\toptown int* value = identity[int](new int)\n\tif (value): return *value\n\treturn 1\n", 0)
	optional_owner_case(c"optown int* identity(optown int* value):\n\treturn value\ntype Pass = fn[](optown int*) -> optown int*\nint main():\n\tPass* call = identity\n\toptown int* value = call(0)\n\tif (value): return 1\n\treturn 0\n", 0)
	optional_owner_case(c"int main():\n\tint optown = 7\n\treturn optown - 7\n", 0)
	optional_owner_case(c"optown int* missing():\n\tpass\nint main():\n\treturn 0\n", c"without returning a value")
	optional_owner_case(c"int main():\n\toptown int* value\n\treturn 0\n", c"initialization")

void test_optional_owner_4():
	optional_owner_case(c"int main():\n\tint scalar = 7\n\toptown int* value = &scalar\n\treturn 0\n", c"incompatible checked pointer")
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\tint* raw = value\n\treturn 0\n", c"unsupported type")
	optional_owner_case(c"int main():\n\toptown int* value = new int\n\toptown int* next = value\n\tif (value): return 1\n\treturn 0\n", c"moved")
	optional_owner_case(c"struct Mixed:\n\toptown int* child\n\tref[data] int* external\nint main():\n\tint x = 7\n\toptown[a] Mixed* owner = new Mixed(0, &x)\n\tref int* view = owner.external\n\treturn *view - 7\n", 0)
	optional_owner_case(c"struct Mixed:\n\toptown int* child\n\tref[data] int* external\nint main():\n\tint x = 7\n\toptown[a] Mixed* owner = new Mixed(0, &x)\n\towner = 0\n\tx = 8\n\treturn x - 8\n", 0)
	optional_owner_case(c"struct Mixed:\n\toptown int* child\n\tref[data] int* external\noptown[a] Mixed* make(ref[a] int* value):\n\treturn new Mixed(0, value)\nint main():\n\tint x = 7\n\toptown[a] Mixed* owner = make(&x)\n\tif (owner):\n\t\tref int* view = owner.external\n\t\treturn *view - 7\n\treturn 1\n", 0)
	optional_owner_case(c"struct Mixed:\n\toptown int* child\n\tref[data] int* external\noptown[a] Mixed* bad(ref[a] int* value):\n\tint local = 8\n\treturn new Mixed(0, &local)\nint main():\n\treturn 0\n", c"must borrow from")
	optional_owner_case(c"struct Mixed:\n\toptown int* child\n\tref[data] int* external\noptown[a] Mixed* empty(ref[a] int* value):\n\tint local = 8\n\toptown[b] Mixed* result = new Mixed(0, &local)\n\tresult = 0\n\treturn result\nint main():\n\tint x = 7\n\toptown[a] Mixed* result = empty(&x)\n\tif (result): return 1\n\treturn 0\n", 0)

void test_optional_owner_5():
	optional_owner_case(c"type MaybeOwner = optown int*\nint main():\n\tMaybeOwner value = new int\n\t*value = 7\n\tMaybeOwner next = value\n\treturn *next - 7\n", 0)
	optional_owner_case(c"optown int* next(optown int* value):\n\treturn value\nint main():\n\toptown int* value = new int\n\tfor i in range(3):\n\t\tif (value):\n\t\t\tvalue = next(0)\n\t\t\treturn *value\n\treturn 0\n", c"presence check")
	optional_owner_case(c"struct Pair:\n\tref[left] int* first\n\tref[right] int* second\noptown[a,b] Pair* make(ref[a] int* first, ref[b] int* second):\n\treturn new Pair(first, second)\nint main():\n\tint x = 3\n\tint y = 4\n\toptown[a,b] Pair* owner = make(&x, &y)\n\tif (owner):\n\t\tref int* first = owner.first\n\t\tref int* second = owner.second\n\t\treturn *first + *second - 7\n\treturn 1\n", 0)
	optional_owner_case(c"int consume(optown int* first, optown int* second):\n\treturn 0\nint main():\n\toptown int* value = new int\n\treturn consume(value, value)\n", c"conflicting call arguments")
	optional_owner_case(c"int read_and_consume(ref int* value, optown int* owner):\n\treturn *value\nint main():\n\toptown int* value = new int\n\treturn read_and_consume(value, value)\n", c"conflicting")
	optional_owner_case(c"struct Outer:\n\toptown int* child\nint main():\n\toptown Outer* outer = 0\n\touter.child = new int\n\treturn 0\n", c"presence check")
	optional_owner_case(c"int consume(optown int* value):\n\treturn 0\nint main():\n\toptown int* value = new int\n\tdefer consume(value)\n\town int* moved = value\n\treturn *moved\n", c"moved")
	optional_owner_case(c"void consume(optown int* value, refmut int* out):\n\tif (value): *out = *value\nvoid inner(refmut int* out):\n\toptown int* value = new int\n\t*value = 7\n\tdefer consume(value, out)\nint main():\n\tint out = 0\n\tinner(&out)\n\treturn out - 7\n", 0)
