# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int mixed_owner_case_number


void mixed_owner_result(process_result* result, char* diagnostic, int checking, char* path):
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


void mixed_owner_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0):
	mixed_owner_case_number = mixed_owner_case_number + 1
	char* number = itoa(mixed_owner_case_number)
	char* prefix = c"bin/mixed_owner_case32_"
	if (__word_size__ == 8): prefix = c"bin/mixed_owner_case64_"
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
		mixed_owner_result(checked, diagnostic, 1, full)
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
		mixed_owner_result(compiled, diagnostic, 0, full)
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


void test_mixed_owner_0():
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* p = extract(holder)\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* bad(ref[a] int* input):\n\tint local = 0\n\treturn new Mixed(new int, &local)\nint main():\n\treturn 0\n", c"must borrow from")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.stored\nint main():\n\treturn 0\n", c"must borrow from")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tx = 9\n\tref int* p = holder.view\n\treturn *p\n", c"conflicting")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint consume(own[a] Mixed* holder):\n\tref int* p = holder.view\n\treturn *p\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tint before = consume(holder)\n\tx = 9\n\treturn before + x - 12\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint consume(own[a] Mixed* holder):\n\tref int* p = holder.view\n\treturn *p\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* p = holder.view\n\tint before = consume(holder)\n\treturn *p + before - 6\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint consume(own[a] Mixed* holder):\n\tref int* p = holder.view\n\treturn *p\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tint before = consume(holder)\n\tref int* p = holder.view\n\treturn *p + before\n", c"moved")
	mixed_owner_case(c"int main():\n\town[a] int* value = new int\n\treturn 0\n", c"owner lifetime arity")


void test_mixed_owner_1():
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nint main():\n\tint x = 3\n\tint y = 4\n\town Mixed* holder = new Mixed(new int, &x)\n\treturn 0\n", c"unsupported type")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nint main():\n\tint x = 3\n\tint y = 4\n\tMixed holder = Mixed(new int, &x)\n\treturn 0\n", c"unsupported type")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nint inspect(ref Mixed* holder):\n\treturn 0\nint main():\n\treturn 0\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\trefmut[data] int* view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = new Mixed(new int, &x)\n\treturn 0\n", c"safe:")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\toptref[data] int* view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = new Mixed(new int, &x)\n\treturn 0\n", c"safe:")
	mixed_owner_case(c"struct View:\n\tref[data] int* item\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] View* view = new View(&x)\n\tref int* p = view.item\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Mixed* holder = make(&x)\n\treturn 0\n", c"owner lifetime arity")
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(ref[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nref[a] int* first(own[a,b] Wide* holder):\n\treturn holder.first\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = make(&x, &y)\n\tref int* p = first(holder)\n\ty = 9\n\treturn *p + y - 12\n", 0)


void test_mixed_owner_2():
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nref[a] int* first(own[a,b] Wide* holder):\n\treturn holder.second\nint main():\n\treturn 0\n", c"must borrow from")
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(ref[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nref[a] int* first(own[a,b] Wide* holder):\n\treturn holder.first\ntype Make = fn[a,b](ref[a] int*, ref[b] int*) -> own[a,b] Wide*\ntype First = fn[a,b](own[a,b] Wide*) -> ref[a] int*\nint main():\n\tint x = 3\n\tint y = 4\n\tMake* factory = make\n\tFirst* get = first\n\town[a,b] Wide* holder = factory(&x, &y)\n\tref int* p = get(holder)\n\ty = 9\n\treturn *p + y - 12\n", 0)
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nref[a] int* first(own[a,b] Wide* holder):\n\treturn holder.first\ntype Wrong = fn[a,b](own[a,b] Wide*) -> ref[b] int*\nint main():\n\tWrong* get = first\n\treturn 0\n", c"contract")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nown[a] T* identity[T](own[a] T* value):\n\treturn value\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = identity[Mixed](make(&x))\n\tref int* p = extract(holder)\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nstruct Outer:\n\town[group] Mixed* child\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Outer* outer = new Outer(make(&x), 7)\n\tref int* p = outer.child.view\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nint main():\n\tint x = 3\n\tint y = 4\n\town int* value = new int\n\tref int* view = value\n\town[a] Mixed* holder = new Mixed(value, view)\n\treturn 0\n", c"conflicting")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nint main():\n\tint x = 3\n\tint y = 4\n\town int* value = new int\n\town[a] Mixed* holder = new Mixed(value, value)\n\treturn 0\n", c"moved")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint mutate(refmut int* value):\n\t*value = 9\n\treturn 0\nint take(own[a] Mixed* holder, int tag):\n\tref int* p = holder.view\n\treturn *p + tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\treturn take(holder, mutate(&x))\n", c"conflicting")


void test_mixed_owner_3():
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint mutate(refmut int* value):\n\t*value = 9\n\treturn 0\nstruct Outer:\n\town[group] Mixed* child\n\tint tag\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\town[a] Outer* outer = new Outer(holder, mutate(&x))\n\treturn 0\n", c"conflicting")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* bad(refmut[a] int* input):\n\tdefer *input = 9\n\treturn new Mixed(new int, input)\nint main():\n\treturn 0\n", c"conflicting")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tholder = make(&x)\n\tref int* p = extract(holder)\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tholder = make(&y)\n\tx = 9\n\tref int* p = holder.view\n\treturn *p\n", c"conflicting")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nown[a] Mixed* choose(own[a] Mixed* first, own[a] Mixed* second, int use_first):\n\tif (use_first): return first\n\treturn second\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = choose(make(&x), make(&y), 1)\n\tref int* p = extract(holder)\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tfor i in range(3):\n\t\tref int* p = holder.view\n\t\tif (*p != 3): return 1\n\t\tholder = make(&x)\n\treturn 0\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tref int* child = holder.stored\n\tholder = make(&x)\n\treturn *child\n", c"conflicting")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = make(&x)\n\tholder.view = &y\n\treturn 0\n", c"references cannot be reassigned")


void test_mixed_owner_4():
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = new Mixed\n\treturn 0\n", c"safe:")


void test_mixed_owner_contracts():
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* forward(ref[a] int* value);\nown[x] Mixed* forward(ref[x] int* value):\n\treturn new Mixed(new int, value)\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = forward(&x)\n\tref int* p = extract(holder)\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nown[a,b] Wide* forward(ref[a] int* x, ref[b] int* y);\nown[b,a] Wide* forward(ref[a] int* x, ref[b] int* y):\n\treturn new Wide(new int, y, x)\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = forward(&x, &y)\n\treturn 0\n", c"disagrees")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[b] Mixed* shorten(ref[a] int* value) where a > b:\n\treturn new Mixed(new int, value)\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Mixed* holder = shorten(&x)\n\tref int* p = extract(holder)\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(ref[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nref[a] int* first(own[a,b] Wide* holder):\n\treturn holder.first\nown[a,b] T* identity[T](own[a,b] T* value):\n\treturn value\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = identity[Wide](make(&x, &y))\n\tref int* p = first(holder)\n\ty = 9\n\treturn *p + y - 12\n", 0)
	mixed_owner_case(c"struct View:\n\tref[data] int* p\nstruct Holder:\n\town int* stored\n\tref[data] View view\nref[a] View take(own[a] Holder* holder):\n\treturn holder.view\nint main():\n\tint x = 3\n\tint y = 4\n\town[a] Holder* holder = new Holder(new int, View(&x))\n\tref[a] View view = take(holder)\n\tref int* p = view.p\n\treturn *p - 3\n", 0)
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nint main():\n\tint x = 3\n\town[a] Mixed* holder = make(&x)\n\tif (1):\n\t\tint local = 4\n\t\tholder = make(&local)\n\tref int* p = holder.view\n\treturn *p\n", c"moved")
	mixed_owner_case(c"struct Mixed:\n\town int* stored\n\tref[data] int* view\nown[a] Mixed* make(ref[a] int* input):\n\treturn new Mixed(new int, input)\nref[a] int* extract(own[a] Mixed* holder):\n\treturn holder.view\ntype Held = own[a] Mixed*\nint main():\n\tint x = 3\n\tint y = 4\n\tHeld holder = make(&x)\n\tref int* p = extract(holder)\n\treturn *p - 3\n", 0)


void test_mixed_owner_speculative_types():
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(ref[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nref[a] int* first(own[a,b] Wide* holder):\n\treturn holder.first\nT typed_identity[T](T value):\n\treturn value\nint main():\n\tint x = 3\n\tint y = 4\n\town[a,b] Wide* holder = typed_identity[own[c,d] Wide*](make(&x, &y))\n\tref int* p = first(holder)\n\ty = 9\n\treturn *p + y - 12\n", 0)
	mixed_owner_case(c"struct Wide:\n\town int* stored\n\tref[left] int* first\n\tref[right] int* second\nown[a,b] Wide* make(ref[a] int* first, ref[b] int* second):\n\treturn new Wide(new int, first, second)\nref[a] int* first(own[a,b] Wide* holder):\n\treturn holder.first\nA typed_choose[A,B](A first, B second):\n\treturn first\nint main():\n\tint x = 3\n\tint y = 4\n\tint z = 5\n\tint w = 6\n\town[a,b] Wide* holder = typed_choose[own[first_a_labellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabel,first_b_labellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabel] Wide*, own[second_a_labellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabel,second_b_labellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabellabel] Wide*](make(&x, &y), make(&z, &w))\n\tref int* p = first(holder)\n\tz = 7\n\tw = 8\n\treturn *p + z + w - 18\n", 0)
