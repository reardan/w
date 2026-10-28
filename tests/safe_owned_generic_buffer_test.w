# wbuild: x64
# wbuild: deps=lib/safe_owned_vector.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int owned_generic_buffer_case_number


void owned_generic_buffer_result(process_result* result, char* diagnostic, int checking, char* path):
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


void owned_generic_buffer_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	owned_generic_buffer_case_number = owned_generic_buffer_case_number + 1
	char* number = itoa(owned_generic_buffer_case_number)
	char* prefix = c"bin/owned_generic_buffer_case32_"
	if (__word_size__ == 8): prefix = c"bin/owned_generic_buffer_case64_"
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
		owned_generic_buffer_result(checked, diagnostic, 1, full)
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
		owned_generic_buffer_result(compiled, diagnostic, 0, full)
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

void test_owned_generic_buffer_0():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\treturn owned_buffer_length[Item](values)\n", 0)

void test_owned_generic_buffer_1():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\town Item* result = owned_buffer_pop[Item](values)\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_owned_generic_buffer_2():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\towned_buffer_set[Item](values, 0, item(11))\n\tref Item* result = owned_buffer_get[Item](values, 0)\n\tref int* view = result.value\n\treturn *view - 11\n", 0)

void test_owned_generic_buffer_3():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\towned_buffer_clear[Item](values)\n\treturn owned_buffer_length[Item](values)\n", 0)

void test_owned_generic_buffer_4():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](0)\n\toptown Item* result = owned_buffer_try_push[Item](values, item(7))\n\tif result:\n\t\tref int* view = result.value\n\t\treturn *view - 7\n\treturn 1\n", 0)

void test_owned_generic_buffer_5():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\toptown Item* result = owned_buffer_try_push[Item](values, item(7))\n\tif result: return 1\n\treturn owned_buffer_length[Item](values) - 1\n", 0)

void test_owned_generic_buffer_6():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\town Item* input = item(7)\n\toptown Item* result = owned_buffer_try_push[Item](values, input)\n\tref int* view = input.value\n\treturn *view\n", c"moved")

void test_owned_generic_buffer_7():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\towned_buffer_push[Item](values, item(8))\n\tref int* view = held.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_8():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\towned_buffer_clear[Item](values)\n\tref int* view = held.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_9():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\towned_buffer_set[Item](values, 0, item(8))\n\tref int* view = held.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_10():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\town Item* popped = owned_buffer_pop[Item](values)\n\tref int* view = held.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_11():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\tref int* view = held.value\n\tint previous = *view\n\towned_buffer_clear[Item](values)\n\treturn previous - 7\n", 0)

void test_owned_generic_buffer_12():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\town WOwnedBuffer[Item]* moved = values\n\tref int* view = held.value\n\treturn *view\n", c"safe:")

void test_owned_generic_buffer_13():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\town int* stolen = held.value\n\treturn 0\n", c"owner")

void test_owned_generic_buffer_14():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\treturn values.length\n", c"opaque")

void test_owned_generic_buffer_15():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tvalues.maximum = 100\n\treturn 0\n", c"opaque")

void test_owned_generic_buffer_16():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\ntype Buffer = WOwnedBuffer[Item]\nint main():\n\town Buffer* values = new Buffer\n\treturn 0\n", c"opaque")

void test_owned_generic_buffer_17():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\t__w_owned_buffer_drop(cast(void*, values))\n\treturn 0\n", c"runtime call has no audited")

void test_owned_generic_buffer_18():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Borrowed:\n\tref[a] int* value\nint main():\n\town WOwnedBuffer[Borrowed]* values = owned_buffer_new[Borrowed](-1)\n\treturn 0\n", c"unsupported")

void test_owned_generic_buffer_19():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nint main():\n\town WOwnedBuffer[int*]* values = owned_buffer_new[int*](-1)\n\treturn 0\n", c"checked pointers require a single pointer")

void test_owned_generic_buffer_20():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nint main():\n\town WOwnedBuffer[void]* values = owned_buffer_new[void](-1)\n\treturn 0\n", c"checked pointers require a sized pointee")

void test_owned_generic_buffer_21():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tref Item* result = owned_buffer_get[Item](values, 0)\n\treturn 0\n", 0, 0, -1, 0, c"owned generic buffer index out of range")

void test_owned_generic_buffer_22():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\towned_buffer_set[Item](values, -1, item(8))\n\treturn 0\n", 0, 0, -1, 0, c"owned generic buffer index out of range")

void test_owned_generic_buffer_23():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\town Item* result = owned_buffer_pop[Item](values)\n\treturn 0\n", 0, 0, -1, 0, c"pop from empty owned generic buffer")

void test_owned_generic_buffer_24():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-2)\n\treturn 0\n", 0, 0, -1, 0, c"invalid owned buffer maximum")

void test_owned_generic_buffer_25():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](0)\n\towned_buffer_push[Item](values, item(7))\n\treturn 0\n", 0, 0, -1, 0, c"owned buffer insertion failed")

void test_owned_generic_buffer_26():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\tfor i in range(30): owned_buffer_push[Item](values, item(i))\n\tint total = 0\n\tfor i in range(30):\n\t\town Item* value = owned_buffer_pop[Item](values)\n\t\tref int* view = value.value\n\t\ttotal += *view\n\treturn total - 435\n", 0)

void test_owned_generic_buffer_27():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\town WOwnedBuffer[Item]* moved = values\n\treturn owned_buffer_length[Item](values)\n", c"moved")

void test_owned_generic_buffer_28():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nref[a] Item* first(ref[a] WOwnedBuffer[Item]* values):\n\treturn owned_buffer_get[Item](values, 0)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* result = first(values)\n\towned_buffer_clear[Item](values)\n\tref int* view = result.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_29():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nref Item* bad():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\treturn owned_buffer_get[Item](values, 0)\nint main():\n\treturn 0\n", c"borrow")

void test_owned_generic_buffer_30():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\tif owned_buffer_length[Item](values): owned_buffer_clear[Item](values)\n\tref int* view = held.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_31():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\tfor i in range(2): owned_buffer_push[Item](values, item(i))\n\tref int* view = held.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_32():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\ntype Buffer = WOwnedBuffer[Item]\nint main():\n\town Buffer* values = owned_buffer_new[Item](-1)\n\tvalues.owned_buffer_push[Item](item(7))\n\town Item* result = values.owned_buffer_pop[Item]()\n\tref int* view = result.value\n\treturn *view - 7\n", 0)

void test_owned_generic_buffer_33():
	owned_generic_buffer_case(c"import lib.safe_owned_vector as vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = vector.owned_buffer_new[Item](-1)\n\tvector.owned_buffer_push[Item](values, item(7))\n\treturn vector.owned_buffer_length[Item](values) - 1\n", 0)

void test_owned_generic_buffer_34():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[WOwnedBuffer[Item]]* outer = owned_buffer_new[WOwnedBuffer[Item]](-1)\n\town WOwnedBuffer[Item]* inner = owned_buffer_new[Item](-1)\n\towned_buffer_push[Item](inner, item(7))\n\towned_buffer_push[WOwnedBuffer[Item]](outer, inner)\n\treturn owned_buffer_length[WOwnedBuffer[Item]](outer) - 1\n", 0)

void test_owned_generic_buffer_35():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](0)\n\towned_buffer_try_push[Item](values, item(7))\n\treturn 0\n", c"cannot escape")

void test_owned_generic_buffer_36():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Node:\n\town WOwnedBuffer[Node]* children\nint main():\n\town WOwnedBuffer[Node]* values = owned_buffer_new[Node](-1)\n\treturn 0\n", c"checked pointers in aggregates")

void test_owned_generic_buffer_37():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Data:\n\tint[2] numbers\nint main():\n\town Data* value = new Data\n\tvalue.numbers[0] = 7\n\town WOwnedBuffer[Data]* values = owned_buffer_new[Data](-1)\n\towned_buffer_push[Data](values, value)\n\tref Data* view = owned_buffer_get[Data](values, 0)\n\treturn view.numbers[0] - 7\n", 0)

void test_owned_generic_buffer_38():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\ntype Invoke = fn[](int) -> int\nstruct Captured:\n\tInvoke* code\n\town int* environment\nint plus(int value):\n\treturn value + 1\nint main():\n\town int* environment = new int\n\town Captured* captured = new Captured(plus, environment)\n\town WOwnedBuffer[Captured]* values = owned_buffer_new[Captured](-1)\n\towned_buffer_push[Captured](values, captured)\n\tref Captured* view = owned_buffer_get[Captured](values, 0)\n\treturn view.code(6) - 7\n", 0)

void test_owned_generic_buffer_39():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](-1)\n\town Item* element = item(7)\n\towned_buffer_push[Item](values, element)\n\tref int* view = element.value\n\treturn *view\n", c"moved")

void test_owned_generic_buffer_40():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nint main():\n\town WOwnedBuffer[Item]* values = owned_buffer_new[Item](1)\n\towned_buffer_push[Item](values, item(7))\n\tref Item* held = owned_buffer_get[Item](values, 0)\n\toptown Item* rejected = owned_buffer_try_push[Item](values, item(8))\n\tref int* view = held.value\n\treturn *view\n", c"borrow")

void test_owned_generic_buffer_41():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nstruct Item:\n\town int* value\n\nown Item* item(int number):\n\town int* value = new int\n\t*value = number\n\treturn new Item(value)\nstruct Box:\n\town WOwnedBuffer[Item]* values\nint main():\n\town Box* box = new Box(owned_buffer_new[Item](-1))\n\towned_buffer_push[Item](box.values, item(7))\n\town WOwnedBuffer[Item]* moved = box.values\n\tbox.values = owned_buffer_new[Item](-1)\n\treturn owned_buffer_length[Item](moved) - 1\n", 0)

# Owned elements cross threads with their storage: a thread-affine element
# makes the buffer thread-affine, while transferable elements may move.
void test_owned_generic_buffer_42():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nimport lib.safe_thread\nstruct Inner:\n\tint count\n\tWThreadAffine affinity\nstruct Job:\n\town WOwnedBuffer[Inner]* items\ntype Worker = fn[](own Job*) -> int\nint run_job(own Job* job):\n\treturn 0\nint main():\n\town Job* job = new Job(owned_buffer_new[Inner](-1))\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\treturn 0\n", c"thread payload field 'items.affinity' is explicitly thread-affine")

void test_owned_generic_buffer_43():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nimport lib.safe_thread\nstruct Inner:\n\town int* value\nstruct Job:\n\town WOwnedBuffer[Inner]* items\ntype Worker = fn[](own Job*) -> int\nint run_job(own Job* job):\n\treturn owned_buffer_length[Inner](job.items)\nint main():\n\town Job* job = new Job(owned_buffer_new[Inner](-1))\n\towned_buffer_push[Inner](job.items, new Inner(new int))\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\tif (!thread): return 1\n\town WSafeThread* started = thread\n\treturn safe_thread_join(started) - 1\n", 0)

void test_owned_generic_buffer_44():
	owned_generic_buffer_case(c"import lib.safe_owned_vector\nimport lib.safe_thread\nstruct Inner:\n\tint count\n\tWThreadUnshared marker\ntype Read = fn[](ref WOwnedBuffer[Inner]*) -> int\nint count(ref WOwnedBuffer[Inner]* items):\n\treturn owned_buffer_length[Inner](items)\nint main():\n\town WOwnedBuffer[Inner]* left = owned_buffer_new[Inner](-1)\n\town WOwnedBuffer[Inner]* right = owned_buffer_new[Inner](-1)\n\tref WOwnedBuffer[Inner]* first = left\n\tref WOwnedBuffer[Inner]* second = right\n\tRead* entry = count\n\treturn safe_thread_fork_join(entry, first, second)\n", c"explicitly unshareable across threads")


void test_owned_generic_buffer_runtime_pin():
	char* root = c"bin/safe_owned_vector_pin32"
	if (__word_size__ == 8): root = c"bin/safe_owned_vector_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/lib")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/safe_owned_vector.w")
	char* source = strjoin(root, c".w")
	char* output = strjoin(root, c".out")
	char* original = file_read_text(c"lib/safe_owned_vector.w")
	assert1(original != 0)
	char* changed = strjoin(original, c"\n# changed implementation cannot inherit checked contracts\n")
	assert1(file_write_text(path, changed))
	assert1(file_write_text(source, c"import lib.safe_owned_vector\nint main():\n\town WOwnedBuffer[int]* buffer = owned_buffer_new[int](-1)\n\treturn owned_buffer_length[int](buffer)\n"))
	for mode in range(2):
		for checking in range(2):
			unlink(output)
			char** args = strv_new(9)
			strv_set(args, 0, c"bin/wv2")
			strv_set(args, 1, c"--quiet")
			strv_set(args, 2, c"--quiet")
			if (checking):
				strv_set(args, 1, c"check")
				strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--quiet")
			if (mode): strv_set(args, 3, c"--safe")
			strv_set(args, 4, c"--quiet")
			if (__word_size__ == 8): strv_set(args, 4, c"x64")
			strv_set(args, 5, c"--import-root")
			strv_set(args, 6, root)
			strv_set(args, 7, source)
			strv_set(args, 8, c"--quiet")
			if (checking == 0):
				free(cast(void*, args))
				args = strv_new(10)
				strv_set(args, 0, c"bin/wv2")
				strv_set(args, 1, c"--quiet")
				if (mode): strv_set(args, 1, c"--safe")
				strv_set(args, 2, c"--quiet")
				if (__word_size__ == 8): strv_set(args, 2, c"x64")
				strv_set(args, 3, c"--import-root")
				strv_set(args, 4, root)
				strv_set(args, 5, source)
				strv_set(args, 6, c"-o")
				strv_set(args, 7, output)
				strv_set(args, 8, c"--quiet")
				strv_set(args, 9, c"--strict")
			process_result* result = process_run(args[0], args, 0, 0, 30000)
			owned_generic_buffer_result(result, c"runtime implementation differs", checking, source)
			assert1(open(output, 0, 0) < 0)
			process_result_free(result)
			free(cast(void*, args))
	unlink(path)
	unlink(source)
	free(original)
	free(changed)
	free(path)
	free(directory)
	free(source)
	free(output)
