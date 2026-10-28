# wbuild: x64
# wbuild: deps=lib/safe_typed_arena.w
# Budget-arena contracts, each checked and compiled with and without --safe.
# Rejections must prevent publication of an executable.
import lib.testing
import lib.process
import lib.file


int budget_arena_case_number


void budget_arena_result(process_result* result, char* diagnostic, int checking, char* path):
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


void budget_arena_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	budget_arena_case_number = budget_arena_case_number + 1
	char* number = itoa(budget_arena_case_number)
	char* prefix = c"bin/budget_arena_case32_"
	if (__word_size__ == 8): prefix = c"bin/budget_arena_case64_"
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
		budget_arena_result(checked, diagnostic, 1, full)
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
		budget_arena_result(compiled, diagnostic, 0, full)
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

# Charges, recoverable refusal, refunds and reading the budget through the arena.
void test_budget_arena_0():
	budget_arena_case(c"import lib.safe_typed_arena\nstruct Node:\n\town int* value\n\tint number\nint main():\n\town WArenaBudget* budget = arena_budget_new(sizeof(Node) * 2)\n\town[b] WBudgetArena[Node]* nodes = budget_arena_new[Node](budget, -1)\n\tint refused = 0\n\tfor i in range(3):\n\t\toptown Node* rejected = budget_arena_try_insert[Node](nodes, new Node(new int, i))\n\t\tif (rejected): refused += 1\n\tif (refused != 1): return 1\n\tif (budget_arena_remaining[Node](nodes) != 0): return 2\n\tif (budget_arena_destroy[Node](nodes, 0) != 1): return 3\n\tif (budget_arena_remaining[Node](nodes) != sizeof(Node)): return 4\n\tbudget_arena_reset[Node](nodes)\n\treturn budget_arena_remaining[Node](nodes) - sizeof(Node) * 2\n", 0)

# A budget is reusable once the arena borrowing it is gone, with every charge refunded.
void test_budget_arena_1():
	budget_arena_case(c"import lib.safe_typed_arena\nint fill(refmut WArenaBudget* budget):\n\town[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\trefmut int* first = budget_arena_alloc[int](values, 1)\n\tint seen = *first\n\toptrefmut int* second = budget_arena_try_alloc[int](values, 2)\n\tif (second): return 0\n\treturn seen\nint main():\n\town WArenaBudget* budget = arena_budget_new(sizeof(int))\n\tif (fill(budget) != 1): return 1\n\tif (arena_budget_used(budget) != 0): return 2\n\tif (1):\n\t\town[b] WBudgetArena[int]* again = budget_arena_new[int](budget, -1)\n\t\trefmut int* third = budget_arena_alloc[int](again, 3)\n\t\t*third = 4\n\treturn arena_budget_remaining(budget) - arena_budget_limit(budget)\n", 0)

# The arena borrows its budget exclusively until it is dropped.
void test_budget_arena_2():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\tbudget_arena_insert[int](values, new int)\n\treturn arena_budget_used(budget)\n", c"conflicting access while a borrow is live")

# One budget backs one live arena.
void test_budget_arena_3():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[int]* first = budget_arena_new[int](budget, -1)\n\town[c] WBudgetArena[int]* second = budget_arena_new[int](budget, -1)\n\tbudget_arena_insert[int](first, new int)\n\treturn 0\n", c"conflicting")

# The budget cannot move while an arena borrows it.
void test_budget_arena_4():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\town WArenaBudget* moved = budget\n\tbudget_arena_insert[int](values, new int)\n\treturn 0\n", c"budget")

# Destroying the budget before its arena would refund freed memory.
void test_budget_arena_5():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\toptown[b] WBudgetArena[int]* outer = 0\n\tif (1):\n\t\town WArenaBudget* budget = arena_budget_new(64)\n\t\touter = budget_arena_new[int](budget, -1)\n\treturn 0\n", c"budget arena outlives the budget it borrows")

# Declaring the arena's home before the budget would drop the budget first.
void test_budget_arena_6():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\toptown[b] WBudgetArena[int]* values = 0\n\town WArenaBudget* budget = arena_budget_new(64)\n\tvalues = budget_arena_new[int](budget, -1)\n\treturn 0\n", c"budget arena outlives the budget it borrows")

# A holder record's budget arena is dropped with the holder.
void test_budget_arena_7():
	budget_arena_case(c"import lib.safe_typed_arena\nstruct Holder:\n\town[h] WBudgetArena[int]* values\n\tint tag\nint main():\n\toptown[b] Holder* holder = 0\n\town WArenaBudget* budget = arena_budget_new(64)\n\tholder = new Holder(budget_arena_new[int](budget, -1), 1)\n\treturn 0\n", c"budget arena outlives the budget it borrows")

# A holder record keeps the budget's lifetime and drops its arena first.
void test_budget_arena_8():
	budget_arena_case(c"import lib.safe_typed_arena\nstruct Holder:\n\town[h] WBudgetArena[int]* values\n\tint tag\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] Holder* holder = new Holder(budget_arena_new[int](budget, -1), 1)\n\trefmut int* value = budget_arena_alloc[int](holder.values, 4)\n\t*value = 5\n\treturn budget_arena_length[int](holder.values) - 1\n", 0)

# An arena cannot escape the function that owns its budget.
void test_budget_arena_9():
	budget_arena_case(c"import lib.safe_typed_arena\nown[b] WBudgetArena[int]* leak(int limit):\n\town WArenaBudget* budget = arena_budget_new(limit)\n\treturn budget_arena_new[int](budget, -1)\nint main():\n\treturn 0\n", c"returned lifetime must name a borrowed parameter")

# A budget arena is always a labeled owner.
void test_budget_arena_10():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\treturn 0\n", c"unsupported type or reference-bearing aggregate")

# Budget metadata is private to the audited implementation.
void test_budget_arena_11():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = new WArenaBudget(64, 0)\n\treturn 0\n", c"opaque")

# Reading or writing budget fields directly is rejected.
void test_budget_arena_12():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\tbudget.used = 64\n\treturn 0\n", c"opaque")

# Allocation copies plain values only; owners enter through insert.
void test_budget_arena_13():
	budget_arena_case(c"import lib.safe_typed_arena\nstruct Pair:\n\tint[2] items\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[Pair]* pairs = budget_arena_new[Pair](budget, -1)\n\tPair initial\n\trefmut Pair* stored = budget_arena_alloc[Pair](pairs, initial)\n\treturn 0\n", c"audited ownership contract")

# Destroying an object while a view into it is live is rejected.
void test_budget_arena_14():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\tbudget_arena_insert[int](values, new int)\n\toptref int* view = budget_arena_get[int](values, 0)\n\tbudget_arena_destroy[int](values, 0)\n\tif (view): return *view\n\treturn 0\n", c"conflicting access while a borrow is live")

# Reset invalidates every live view.
void test_budget_arena_15():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\trefmut int* first = budget_arena_alloc[int](values, 1)\n\tbudget_arena_reset[int](values)\n\treturn *first\n", c"conflicting access while a borrow is live")

# Destroyed positions are holes, so budget arenas are not iterable.
void test_budget_arena_16():
	budget_arena_case(c"import lib.safe_typed_arena\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\tint total = 0\n\tfor ref int* value in values:\n\t\ttotal += *value\n\treturn total\n", c"is not iterable")

# A spawned thread could outlive the budget.
void test_budget_arena_17():
	budget_arena_case(c"import lib.safe_typed_arena\nimport lib.safe_thread\ntype Worker = fn[b](own[b] WBudgetArena[int]*) -> int\nint run(own[b] WBudgetArena[int]* values):\n\treturn 0\nint main():\n\town WArenaBudget* budget = arena_budget_new(64)\n\town[b] WBudgetArena[int]* values = budget_arena_new[int](budget, -1)\n\tWorker* entry = run\n\toptown WSafeThread* thread = safe_thread_spawn(entry, values)\n\treturn 0\n", c"carries a borrowed lifetime")

# Objects with owned fields are destroyed exactly once on every exit, and recursion stays bounded.
void test_budget_arena_18():
	budget_arena_case(c"import lib.safe_typed_arena\nstruct Node:\n\town int* value\n\town WArenaBudget* nested\nint build(refmut WArenaBudget* budget, int early):\n\town[b] WBudgetArena[Node]* nodes = budget_arena_new[Node](budget, 4)\n\tfor i in range(4):\n\t\tbudget_arena_insert[Node](nodes, new Node(new int, arena_budget_new(i)))\n\t\tif (early && (i == 1)): return 1\n\tbudget_arena_destroy[Node](nodes, 2)\n\tbudget_arena_release[Node](nodes)\n\treturn budget_arena_slots[Node](nodes)\nint main():\n\town WArenaBudget* budget = arena_budget_new(1024)\n\tif (build(budget, 1) != 1): return 1\n\tif (build(budget, 0) != 0): return 2\n\treturn arena_budget_used(budget)\n", 0)
