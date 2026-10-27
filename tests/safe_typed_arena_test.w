# wbuild: x64
# wbuild: deps=lib/safe_typed_arena.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int typed_arena_case_number


void typed_arena_result(process_result* result, char* diagnostic, int checking, char* path):
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


void typed_arena_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	typed_arena_case_number = typed_arena_case_number + 1
	char* number = itoa(typed_arena_case_number)
	char* prefix = c"bin/typed_arena_case32_"
	if (__word_size__ == 8): prefix = c"bin/typed_arena_case64_"
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
		typed_arena_result(checked, diagnostic, 1, full)
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
		typed_arena_result(compiled, diagnostic, 0, full)
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

void test_typed_arena_0():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 7)\n\t*item += 2\n\toptref int* found = typed_arena_get[int](arena, 0)\n\tif found: return *found - 9\n\treturn 1\n", 0, 0)

void test_typed_arena_1():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\tfor i in range(24):\n\t\town int* item = new int\n\t\t*item = i\n\t\tif typed_arena_insert[int](arena, item) != i: return 1\n\tif typed_arena_length[int](arena) != 24: return 2\n\tif typed_arena_destroy[int](arena, 3) != 1: return 3\n\tif typed_arena_destroy[int](arena, 3) != 0: return 4\n\tif typed_arena_length[int](arena) != 23: return 5\n\tif typed_arena_slots[int](arena) != 24: return 6\n\toptref int* hole = typed_arena_get[int](arena, 3)\n\tif hole: return 7\n\treturn 0\n", 0, 0)

void test_typed_arena_2():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\toptref int* missing = typed_arena_get[int](arena, -1)\n\tif missing: return 1\n\toptrefmut int* beyond = typed_arena_get_mut[int](arena, 1)\n\tif beyond: return 2\n\treturn typed_arena_destroy[int](arena, 0)\n", 0, 0)

void test_typed_arena_3():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 7)\n\ttyped_arena_reset[int](arena)\n\treturn *item\n", c"borrow", 0)

void test_typed_arena_4():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 7)\n\ttyped_arena_release[int](arena)\n\treturn *item\n", c"borrow", 0)

void test_typed_arena_5():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 7)\n\ttyped_arena_destroy[int](arena, 0)\n\treturn *item\n", c"borrow", 0)

void test_typed_arena_6():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 7)\n\trefmut int* second = typed_arena_alloc[int](arena, 8)\n\treturn *item + *second\n", c"borrow", 0)

void test_typed_arena_7():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 7)\n\tint old = *item\n\ttyped_arena_reset[int](arena)\n\trefmut int* next = typed_arena_alloc[int](arena, 2)\n\treturn old + *next - 9\n", 0, 0)

void test_typed_arena_8():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](0)\n\town int* item = new int\n\t*item = 9\n\toptown int* rejected = typed_arena_try_insert[int](arena, item)\n\tif rejected: return *rejected - 9\n\treturn 1\n", 0, 0)

void test_typed_arena_9():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\town int* item = new int\n\toptown int* rejected = typed_arena_try_insert[int](arena, item)\n\tif rejected: return 1\n\treturn typed_arena_length[int](arena) - 1\n", 0, 0)

void test_typed_arena_10():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\town int* item = new int\n\ttyped_arena_insert[int](arena, item)\n\treturn *item\n", c"moved", 0)

void test_typed_arena_11():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\treturn arena.length\n", c"opaque", 0)

void test_typed_arena_12():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\town WTypedArena[int]* moved = arena\n\treturn typed_arena_length[int](arena)\n", c"moved", 0)

void test_typed_arena_13():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 3)\n\town WTypedArena[int]* moved = arena\n\treturn *item\n", c"safe:", 0)

void test_typed_arena_14():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 3)\n\toptref int* shared = typed_arena_get[int](arena, 0)\n\tif shared: *shared = 4\n\treturn 0\n", c"assignment to const", 0)

void test_typed_arena_15():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 3)\n\toptrefmut int* mutable = typed_arena_get_mut[int](arena, 0)\n\tif mutable: *mutable = 8\n\toptref int* shared = typed_arena_get[int](arena, 0)\n\tif shared: return *shared - 8\n\treturn 1\n", 0, 0)

void test_typed_arena_16():
	typed_arena_case(c"import lib.safe_typed_arena\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WTypedArena[Pair]* arena = typed_arena_new[Pair](-1)\n\trefmut Pair* item = typed_arena_alloc[Pair](arena, Pair(4, 5))\n\treturn item.left + item.right - 9\n", 0, 0)

void test_typed_arena_17():
	typed_arena_case(c"import lib.safe_typed_arena\nstruct Pair:\n\town int* child\nint main():\n\town WTypedArena[Pair]* arena = typed_arena_new[Pair](-1)\n\town int* child = new int\n\t*child = 11\n\town Pair* item = new Pair(child)\n\ttyped_arena_insert[Pair](arena, item)\n\toptref Pair* shared = typed_arena_get[Pair](arena, 0)\n\tif shared: return *shared.child - 11\n\treturn 1\n", 0, 0)

void test_typed_arena_18():
	typed_arena_case(c"import lib.safe_typed_arena\nstruct Bad:\n\tint* raw\nint main():\n\town WTypedArena[Bad]* arena = typed_arena_new[Bad](-1)\n\treturn 0\n", c"unsupported type", 0)

void test_typed_arena_19():
	typed_arena_case(c"import lib.safe_typed_arena\nstruct Bad:\n\tref[a] int* borrowed\nint main():\n\town WTypedArena[Bad]* arena = typed_arena_new[Bad](-1)\n\treturn 0\n", c"unsupported type", 0)

void test_typed_arena_20():
	typed_arena_case(c"import lib.safe_typed_arena\nstruct Bad:\n\town Bad* child\nint main():\n\town WTypedArena[Bad]* arena = typed_arena_new[Bad](-1)\n\treturn 0\n", c"sized pointee", 0)

void test_typed_arena_21():
	typed_arena_case(c"import lib.safe_typed_arena\nrefmut[a] int* return_item(refmut[a] WTypedArena[int]* arena):\n\treturn typed_arena_alloc[int](arena, 17)\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = return_item(arena)\n\treturn *item - 17\n", 0, 0)

void test_typed_arena_22():
	typed_arena_case(c"import lib.safe_typed_arena\nrefmut int* bad(refmut int* fallback):\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\treturn typed_arena_alloc[int](arena, 1)\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\treturn 0\n", c"returned reference", 0)

void test_typed_arena_23():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\tfor i in range(10):\n\t\trefmut int* item = typed_arena_alloc[int](arena, i)\n\t\tif *item != i: return 1\n\t\ttyped_arena_release[int](arena)\n\treturn typed_arena_length[int](arena)\n", 0, 0)

void test_typed_arena_24():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-2)\n\treturn 0\n", 0, 0, -1, 0, c"invalid typed arena maximum")

void test_typed_arena_25():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](0)\n\trefmut int* item = typed_arena_alloc[int](arena, 1)\n\treturn 0\n", 0, 0, -1, 0, c"typed arena allocation failed")

void test_typed_arena_26():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](0)\n\town int* item = new int\n\ttyped_arena_insert[int](arena, item)\n\treturn 0\n", 0, 0, -1, 0, c"typed arena insertion failed")

void test_typed_arena_27():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[WTypedArena[int]]* outer = typed_arena_new[WTypedArena[int]](-1)\n\town WTypedArena[int]* child = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](child, 4)\n\ttyped_arena_insert[WTypedArena[int]](outer, child)\n\treturn typed_arena_length[WTypedArena[int]](outer) - 1\n", 0, 0)

void test_typed_arena_28():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[byte]* arena = typed_arena_new[byte](-1)\n\trefmut byte* item = typed_arena_alloc[byte](arena, cast(byte, 255))\n\treturn cast(int, *item) - 255\n", 0, 0)

void test_typed_arena_29():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](1)\n\trefmut int* item = typed_arena_alloc[int](arena, 1)\n\tint old = *item\n\ttyped_arena_destroy[int](arena, 0)\n\town int* next = new int\n\toptown int* rejected = typed_arena_try_insert[int](arena, next)\n\tif rejected: return old - 1\n\treturn 1\n", 0, 0)

void test_typed_arena_30():
	typed_arena_case(c"import lib.safe_typed_arena\ntype Invoke = fn[](int) -> int\nstruct Captured:\n\tInvoke* code\n\town int* environment\nint plus(int value):\n\treturn value + 1\nint main():\n\town WTypedArena[Captured]* arena = typed_arena_new[Captured](-1)\n\town Captured* item = new Captured(plus, new int)\n\ttyped_arena_insert[Captured](arena, item)\n\toptref Captured* view = typed_arena_get[Captured](arena, 0)\n\tif view: return view.code(4) - 5\n\treturn 1\n", 0, 0)

void test_typed_arena_31():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 1)\n\toptref int* shared = typed_arena_get[int](arena, 0)\n\tif shared:\n\t\ttyped_arena_reset[int](arena)\n\t\treturn *shared\n\treturn 0\n", c"borrow", 0)

void test_typed_arena_32():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* item = typed_arena_alloc[int](arena, 1)\n\toptrefmut int* mutable = typed_arena_get_mut[int](arena, 0)\n\tif mutable:\n\t\tint count = typed_arena_length[int](arena)\n\t\treturn *mutable + count\n\treturn 0\n", c"borrow", 0)

void test_typed_arena_33():
	typed_arena_case(c"import lib.safe_typed_arena\ntype Arena = WTypedArena[int]\nint main():\n\town Arena* arena = new Arena\n\treturn 0\n", c"opaque", 0)

void test_typed_arena_34():
	typed_arena_case(c"import lib.safe_typed_arena\nstruct Pair:\n\town int* child\nint main():\n\town WTypedArena[Pair]* arena = typed_arena_new[Pair](-1)\n\town int* child = new int\n\town Pair* item = new Pair(child)\n\trefmut Pair* duplicate = typed_arena_alloc[Pair](arena, *item)\n\treturn 0\n", c"safe:", 0)

void test_typed_arena_35():
	typed_arena_case(c"import lib.safe_typed_arena\nvoid bad(ref WTypedArena[int]* arena):\n\ttyped_arena_reset[int](arena)\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\treturn 0\n", c"safe:", 0)

# Arenas have holes, so they are never iterable, even when every slot is live.
void test_typed_arena_36():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* first = typed_arena_alloc[int](arena, 1)\n\tint total = 0\n\tfor ref int* value in arena:\n\t\ttotal += *value\n\treturn total\n", c"is not iterable")


# Thread transfer inspects the arena's object graph.
void test_typed_arena_37():
	typed_arena_case(c"import lib.safe_typed_arena\nimport lib.safe_thread\nstruct Inner:\n\tint count\n\tWThreadAffine affinity\nstruct Job:\n\town WTypedArena[Inner]* objects\ntype Worker = fn[](own Job*) -> int\nint run_job(own Job* job):\n\treturn 0\nint main():\n\town Job* job = new Job(typed_arena_new[Inner](-1))\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\treturn 0\n", c"thread payload field 'objects.affinity' is explicitly thread-affine")


# An arena of transferable owners crosses to a spawned thread and back.
void test_typed_arena_38():
	typed_arena_case(c"import lib.safe_typed_arena\nimport lib.safe_thread\nstruct Inner:\n\town int* value\nstruct Job:\n\town WTypedArena[Inner]* objects\ntype Worker = fn[](own Job*) -> int\nint run_job(own Job* job):\n\treturn typed_arena_length[Inner](job.objects)\nint main():\n\town Job* job = new Job(typed_arena_new[Inner](-1))\n\ttyped_arena_insert[Inner](job.objects, new Inner(new int))\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\tif (!thread): return 1\n\town WSafeThread* started = thread\n\treturn safe_thread_join(started) - 1\n", 0)


# A typed arena is never shared across threads, whatever its objects.
void test_typed_arena_39():
	typed_arena_case(c"import lib.safe_typed_arena\nimport lib.safe_thread\nstruct Inner:\n\tint count\n\tWThreadUnshared marker\ntype Read = fn[](ref WTypedArena[Inner]*) -> int\nint count(ref WTypedArena[Inner]* objects):\n\treturn typed_arena_length[Inner](objects)\nint main():\n\town WTypedArena[Inner]* left = typed_arena_new[Inner](-1)\n\town WTypedArena[Inner]* right = typed_arena_new[Inner](-1)\n\tref WTypedArena[Inner]* first = left\n\tref WTypedArena[Inner]* second = right\n\tRead* entry = count\n\treturn safe_thread_fork_join(entry, first, second)\n", c"scoped thread argument has unsynchronized interior mutation")


# Shared allocation keeps earlier views alive: objects never move.
void test_typed_arena_40():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\tref int* first = typed_arena_alloc_shared[int](arena, 1)\n\tref int* second = typed_arena_alloc_shared[int](arena, 2)\n\tfor i in range(20):\n\t\tref int* more = typed_arena_alloc_shared[int](arena, i)\n\toptref int* looked = typed_arena_get[int](arena, 0)\n\tref int* third = typed_arena_alloc_shared[int](arena, 3)\n\tint total = *first + *second + *third\n\tif (looked): total += *looked\n\treturn total - 7 - typed_arena_length[int](arena) + 23\n", 0)


# Shared allocation through a borrowed parameter, in a loop and a branch.
void test_typed_arena_41():
	typed_arena_case(c"import lib.safe_typed_arena\nint sum(ref WTypedArena[int]* arena, int count):\n\tint total = 0\n\tfor i in range(count):\n\t\tref int* value = typed_arena_alloc_shared[int](arena, i)\n\t\tif (i % 2): total += *value\n\treturn total\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\treturn sum(arena, 6) - 9\n", 0)


# The result is a shared view.
void test_typed_arena_42():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\tref int* first = typed_arena_alloc_shared[int](arena, 1)\n\t*first = 2\n\treturn 0\n", c"assignment to const")


# Destroying objects still needs the views to be dead.
void test_typed_arena_43():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\tref int* first = typed_arena_alloc_shared[int](arena, 1)\n\ttyped_arena_reset[int](arena)\n\treturn *first\n", c"conflicting access while a borrow is live")


# Destroying one object also waits for shared views.
void test_typed_arena_44():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\tref int* first = typed_arena_alloc_shared[int](arena, 1)\n\ttyped_arena_destroy[int](arena, 0)\n\treturn *first\n", c"conflicting access while a borrow is live")


# An exclusive view excludes shared allocation.
void test_typed_arena_45():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\trefmut int* first = typed_arena_alloc[int](arena, 1)\n\tref int* second = typed_arena_alloc_shared[int](arena, 2)\n\t*first = 3\n\treturn *second\n", c"conflicting access while a borrow is live")


# The arena cannot move while shared views live.
void test_typed_arena_46():
	typed_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* arena = typed_arena_new[int](-1)\n\tref int* first = typed_arena_alloc_shared[int](arena, 1)\n\town WTypedArena[int]* moved = arena\n\treturn *first\n", c"use of uninitialized or moved value")


# Shared allocation copies plain values only.
void test_typed_arena_47():
	typed_arena_case(c"import lib.safe_typed_arena\nstruct Pair:\n\tint[2] items\nint main():\n\town WTypedArena[Pair]* arena = typed_arena_new[Pair](-1)\n\tPair initial\n\tref Pair* stored = typed_arena_alloc_shared[Pair](arena, initial)\n\treturn 0\n", c"audited ownership contract")


# Two threads could allocate in one shared arena at once.
void test_typed_arena_48():
	typed_arena_case(c"import lib.safe_typed_arena\nimport lib.safe_thread\ntype Read = fn[](ref WTypedArena[int]*) -> int\nint count(ref WTypedArena[int]* arena):\n\tref int* value = typed_arena_alloc_shared[int](arena, 1)\n\treturn *value\nint main():\n\town WTypedArena[int]* left = typed_arena_new[int](-1)\n\town WTypedArena[int]* right = typed_arena_new[int](-1)\n\tref WTypedArena[int]* first = left\n\tref WTypedArena[int]* second = right\n\tRead* entry = count\n\treturn safe_thread_fork_join(entry, first, second)\n", c"has unsynchronized interior mutation")


void test_typed_arena_runtime_pin():
	char* root = c"bin/safe_typed_arena_pin32"
	if (__word_size__ == 8): root = c"bin/safe_typed_arena_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/lib")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/safe_typed_arena.w")
	char* source = strjoin(root, c".w")
	char* output = strjoin(root, c".out")
	char* original = file_read_text(c"lib/safe_typed_arena.w")
	assert1(original != 0)
	char* changed = strjoin(original, c"\n# changed implementation cannot inherit checked contracts\n")
	assert1(file_write_text(path, changed))
	assert1(file_write_text(source, c"import lib.safe_typed_arena\nint main():\n\town WTypedArena[int]* buffer = typed_arena_new[int](-1)\n\treturn typed_arena_length[int](buffer)\n"))
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
			typed_arena_result(result, c"runtime implementation differs", checking, source)
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
