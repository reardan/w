# wbuild: x64
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int callback_storage_case_number


void callback_storage_result(process_result* result, char* diagnostic, int checking, char* path):
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


void callback_storage_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	callback_storage_case_number = callback_storage_case_number + 1
	char* number = itoa(callback_storage_case_number)
	char* prefix = c"bin/callback_storage_case32_"
	if (__word_size__ == 8): prefix = c"bin/callback_storage_case64_"
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
		callback_storage_result(checked, diagnostic, 1, full)
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
		callback_storage_result(compiled, diagnostic, 0, full)
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

void test_callback_storage_0():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tInvoke* code = captured.code\n\tref Environment* environment = captured.environment\n\treturn code(environment, 3) - 10\n", 0)

void test_callback_storage_1():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tref Environment* environment = captured.environment\n\treturn captured.code(environment, 3) - 10\n", 0)

void test_callback_storage_2():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\town Captured* moved = captured\n\tref Environment* environment = moved.environment\n\treturn moved.code(environment, 3) - 10\n", 0)

void test_callback_storage_3():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\town Captured* moved = captured\n\tInvoke* code = captured.code\n\treturn 0\n", c"moved")

void test_callback_storage_4():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nint main():\n\town Captured* captured = new Captured\n\treturn 0\n", c"pointer-free sized value")

void test_callback_storage_5():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nint main():\n\town int* value = new int\n\town Environment* environment = new Environment(value)\n\town Captured* captured = new Captured(0, environment)\n\treturn 0\n", c"matching quantified contract")

void test_callback_storage_6():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nint main():\n\town int* value = new int\n\town Environment* environment = new Environment(value)\n\town Captured* captured = new Captured(cast(Invoke*, 1), environment)\n\treturn 0\n", c"unsupported checked function value")

void test_callback_storage_7():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nint main():\n\town Captured* captured = new Captured(run)\n\treturn 0\n", c"expects 2 arguments")

void test_callback_storage_8():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tcaptured.code = 0\n\treturn 0\n", c"matching quantified contract")

void test_callback_storage_9():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nint changed(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value - extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tcaptured.code = changed\n\tref Environment* environment = captured.environment\n\treturn captured.code(environment, 3) - 4\n", 0)

void test_callback_storage_10():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tInvoke* code = captured.code\n\tcaptured = make()\n\tref Environment* environment = captured.environment\n\treturn code(environment, 3) - 10\n", 0)

void test_callback_storage_11():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nint bad(refmut Environment* environment, int extra):\n\treturn extra\n\nint main():\n\town int* value = new int\n\town Environment* environment = new Environment(value)\n\town Captured* captured = new Captured(bad, environment)\n\treturn 0\n", c"disagrees with its quantified contract")

void test_callback_storage_12():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tref Environment* environment = captured.environment\n\tcaptured = make()\n\treturn captured.code(environment, 3)\n", c"borrow")

void test_callback_storage_13():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\town Environment* environment = captured.environment\n\tInvoke* code = captured.code\n\treturn code(environment, 3) - 10\n", 0)

void test_callback_storage_14():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tunsafe:\n\t\tcaptured.code = cast(Invoke*, 1)\n\treturn 0\n", c"unsafe")

void test_callback_storage_15():
	callback_storage_case(c"type Raw = fn(int*) -> int\nstruct Bad:\n\tRaw* code\nint raw(int* value): return *value\nint main():\n\town Bad* bad = new Bad(raw)\n\treturn 0\n", c"unsupported")

void test_callback_storage_16():
	callback_storage_case(c"type Bad = fn[](int*) -> int\nstruct Holder:\n\tBad* code\nint main():\n\treturn 0\n", c"unsupported type")

void test_callback_storage_17():
	callback_storage_case(c"struct BorrowedEnvironment:\n\tref[data] int* value\n\ntype BorrowedInvoke = fn[](ref BorrowedEnvironment*, int) -> int\n\nstruct BorrowedCapture:\n\tBorrowedInvoke* code\n\town[capture] BorrowedEnvironment* environment\n\nint borrowed_run(ref BorrowedEnvironment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown[a] BorrowedCapture* capture(ref[a] int* value):\n\town[a] BorrowedEnvironment* environment = new BorrowedEnvironment(value)\n\treturn new BorrowedCapture(borrowed_run, environment)\n\nint main():\n\tint n = 7\n\town[a] BorrowedCapture* captured = capture(&n)\n\tref BorrowedEnvironment* environment = captured.environment\n\treturn captured.code(environment, 3) - 10\n", 0)

void test_callback_storage_18():
	callback_storage_case(c"struct BorrowedEnvironment:\n\tref[data] int* value\n\ntype BorrowedInvoke = fn[](ref BorrowedEnvironment*, int) -> int\n\nstruct BorrowedCapture:\n\tBorrowedInvoke* code\n\town[capture] BorrowedEnvironment* environment\n\nint borrowed_run(ref BorrowedEnvironment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown[a] BorrowedCapture* capture(ref[a] int* value):\n\town[a] BorrowedEnvironment* environment = new BorrowedEnvironment(value)\n\treturn new BorrowedCapture(borrowed_run, environment)\n\nint main():\n\tint n = 7\n\town[a] BorrowedCapture* captured = capture(&n)\n\tn = 8\n\tref BorrowedEnvironment* environment = captured.environment\n\treturn captured.code(environment, 3)\n", c"borrow")

void test_callback_storage_19():
	callback_storage_case(c"struct BorrowedEnvironment:\n\tref[data] int* value\n\ntype BorrowedInvoke = fn[](ref BorrowedEnvironment*, int) -> int\n\nstruct BorrowedCapture:\n\tBorrowedInvoke* code\n\town[capture] BorrowedEnvironment* environment\n\nint borrowed_run(ref BorrowedEnvironment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown[a] BorrowedCapture* capture(ref[a] int* value):\n\town[a] BorrowedEnvironment* environment = new BorrowedEnvironment(value)\n\treturn new BorrowedCapture(borrowed_run, environment)\n\nown[a] BorrowedCapture* bad(ref[a] int* input):\n\tint local = 7\n\treturn capture(&local)\n\nint main():\n\treturn 0\n", c"borrow")

void test_callback_storage_20():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype View = fn[a](ref[a] Environment*) -> ref[a] int*\n\nstruct Capture:\n\tView* code\n\town Environment* environment\n\nref[a] int* view(ref[a] Environment* environment):\n\treturn environment.value\n\nint main():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\town Capture* capture = new Capture(view, environment)\n\tref Environment* context = capture.environment\n\tref int* result = capture.code(context)\n\treturn *result - 7\n", 0)

void test_callback_storage_21():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype View = fn[a](ref[a] Environment*) -> ref[a] int*\n\nstruct Capture:\n\tView* code\n\town Environment* environment\n\nref[a] int* view(ref[a] Environment* environment):\n\treturn environment.value\n\nint main():\n\town int* value = new int\n\town Environment* environment = new Environment(value)\n\town Capture* capture = new Capture(view, environment)\n\tref Environment* context = capture.environment\n\tref int* result = capture.code(context)\n\tcapture.environment = new Environment(new int)\n\treturn *result\n", c"borrow")

void test_callback_storage_22():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint execute(own Captured* captured, int fail):\n\tif fail: return -1\n\tref Environment* environment = captured.environment\n\treturn captured.code(environment, 3)\n\nint main():\n\tif execute(make(), 1) != -1: return 1\n\treturn execute(make(), 0) - 10\n", 0)

void test_callback_storage_23():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nref[a] int* escape(ref[a] int* input):\n\town Captured* captured = make()\n\tref Environment* environment = captured.environment\n\treturn environment.value\n\nint main(): return 0\n", c"borrow")

void test_callback_storage_24():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\town Captured* moved = captured\n\tcaptured.code = run\n\treturn 0\n", c"moved")

void test_callback_storage_25():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tInvoke* code = captured.code\n\town Captured* moved = captured\n\tref Environment* environment = moved.environment\n\treturn code(environment, 3) - 10\n", 0)

void test_callback_storage_26():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tInvoke* code = captured.code\n\treturn cast(int, code)\n", c"casts require scalar operands")

void test_callback_storage_27():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\tref Captured* borrowed = captured\n\tInvoke* code = borrowed.code\n\tref Environment* environment = borrowed.environment\n\treturn code(environment, 3) - 10\n", 0)

void test_callback_storage_28():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\town Captured* captured = make()\n\toptown Captured* optional = captured\n\tif optional:\n\t\tInvoke* code = optional.code\n\t\tref Environment* environment = optional.environment\n\t\treturn code(environment, 3) - 10\n\treturn 1\n", 0)

void test_callback_storage_29():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Invoke = fn[](ref Environment*, int) -> int\n\nstruct Captured:\n\tInvoke* code\n\town Environment* environment\n\nint run(ref Environment* environment, int extra):\n\tref int* value = environment.value\n\treturn *value + extra\n\nown Captured* make():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\treturn new Captured(run, environment)\n\nint main():\n\toptown Captured* optional = 0\n\tInvoke* code = optional.code\n\treturn 0\n", c"optional")

void test_callback_storage_30():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Mutate = fn[](refmut Environment*, int) -> int\n\nstruct Captured:\n\tMutate* code\n\town Environment* environment\n\nint mutate(refmut Environment* environment, int extra):\n\trefmut int* value = environment.value\n\t*value += extra\n\treturn *value\n\nint main():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\town Captured* captured = new Captured(mutate, environment)\n\trefmut Environment* context = captured.environment\n\treturn captured.code(context, 3) - 10\n", 0)

void test_callback_storage_31():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Mutate = fn[](refmut Environment*, int) -> int\n\nstruct Captured:\n\tMutate* code\n\town Environment* environment\n\nint mutate(refmut Environment* environment, int extra):\n\trefmut int* value = environment.value\n\t*value += extra\n\treturn *value\n\nint main():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\town Captured* captured = new Captured(mutate, environment)\n\tref Environment* context = captured.environment\n\treturn captured.code(context, 3)\n", c"mutable")

void test_callback_storage_32():
	callback_storage_case(c"struct Environment:\n\town int* value\n\ntype Mutate = fn[](refmut Environment*, int) -> int\n\nstruct Captured:\n\tMutate* code\n\town Environment* environment\n\nint mutate(refmut Environment* environment, int extra):\n\trefmut int* value = environment.value\n\t*value += extra\n\treturn *value\n\nint main():\n\town int* value = new int\n\t*value = 7\n\town Environment* environment = new Environment(value)\n\town Captured* captured = new Captured(mutate, environment)\n\tref Environment* shared = captured.environment\n\trefmut Environment* context = captured.environment\n\tint result = captured.code(context, 3)\n\tref int* old = shared.value\n\treturn result + *old\n", c"borrow")
