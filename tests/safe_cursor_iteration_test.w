# wbuild: x64
# wbuild: deps=lib/safe_hash.w deps=lib/safe_keyed_map.w
# Checked user cursor and hash iteration (#697). Every contract is
# checked and compiled with and without --safe. Rejections must prevent
# publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int cursor_iteration_case_number


void cursor_iteration_result(process_result* result, char* diagnostic, int checking, char* path):
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


void cursor_iteration_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	cursor_iteration_case_number = cursor_iteration_case_number + 1
	char* number = itoa(cursor_iteration_case_number)
	char* prefix = c"bin/cursor_iteration_case32_"
	if (__word_size__ == 8): prefix = c"bin/cursor_iteration_case64_"
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
		cursor_iteration_result(checked, diagnostic, 1, full)
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
		cursor_iteration_result(compiled, diagnostic, 0, full)
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


# Scalar user cursor
void test_cursor_iteration_0():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(4)\n\tint total = 0\n\tfor x in c: total += x\n\treturn total - 6\n", 0)

# Empty user cursor
void test_cursor_iteration_1():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(0)\n\tfor x in c: return 1\n\treturn 0\n", 0)

# Nested cursor loops and exits
void test_cursor_iteration_2():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint count(ref Counter* c):\n\tint total = 0\n\tfor x in c:\n\t\tfor y in c:\n\t\t\tif y == 1: continue\n\t\t\tif x == 2: return total\n\t\t\ttotal += 1\n\treturn 99\nint main():\n\town Counter* c = new Counter(3)\n\treturn count(c) - 4\n", 0)

# Backing mutation blocked despite unused element
void test_cursor_iteration_3():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(4)\n\tfor x in c: c.count = 0\n\treturn 0\n", c"borrow")

# Mutation resumes after last cursor read
void test_cursor_iteration_4():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(4)\n\tfor x in c:\n\t\tif x == 1: break\n\tc.count = 8\n\treturn c.count - 8\n", 0)

# Owning iterable temporary rejected
void test_cursor_iteration_5():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\tfor x in new Counter(4): return 0\n\treturn 0\n", c"named owner")

# Raw operation cannot bypass checking
void test_cursor_iteration_6():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(1)\n\tfor x in c: return x\n\treturn 0\n", c"shared container reference", 0, -1, c"unsupported type")

# Mutating operation rejected
void test_cursor_iteration_7():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(refmut Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(1)\n\tfor x in c: return x\n\treturn 0\n", c"shared container reference")

# Consuming operation rejected
void test_cursor_iteration_8():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(own Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(1)\n\tfor x in c: return x\n\treturn 0\n", c"shared container reference")

# Control result must be int
void test_cursor_iteration_9():
	cursor_iteration_case(c"struct Counter:\n\tint count\nbyte Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(1)\n\tfor x in c: return x\n\treturn 0\n", c"must return int")

# Loop type mismatch rejected even with warnings nonfatal
void test_cursor_iteration_10():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(1)\n\tfor ref int* x in c: return *x\n\treturn 0\n", c"incompatible iterator variable type")

# Borrowed values and retained reference
void test_cursor_iteration_11():
	cursor_iteration_case(c"struct Cursor:\n\town int* value\nint Cursor_iter_begin(ref Cursor* c): return 0\nint Cursor_iter_done(ref Cursor* c, int cursor): return cursor >= 1\nint Cursor_iter_next(ref Cursor* c, int cursor): return cursor + 1\nref[a] int* Cursor_iter_value(ref[a] Cursor* c, int cursor): return c.value\nint main():\n\town int* value = new int\n\t*value = 7\n\town Cursor* c = new Cursor(value)\n\toptref int* saved = 0\n\tfor x in c: saved = x\n\tif saved: return *saved - 7\n\treturn 1\n", 0)

# Saved value blocks mutation
void test_cursor_iteration_12():
	cursor_iteration_case(c"struct Cursor:\n\town int* value\nint Cursor_iter_begin(ref Cursor* c): return 0\nint Cursor_iter_done(ref Cursor* c, int cursor): return cursor >= 1\nint Cursor_iter_next(ref Cursor* c, int cursor): return cursor + 1\nref[a] int* Cursor_iter_value(ref[a] Cursor* c, int cursor): return c.value\nint main():\n\town int* value = new int\n\town Cursor* c = new Cursor(value)\n\toptref int* saved = 0\n\tfor x in c: saved = x\n\tc.value = new int\n\tif saved: return *saved\n\treturn 0\n", c"borrow")

# Empty loop leaves borrowed variable uninitialized
void test_cursor_iteration_13():
	cursor_iteration_case(c"struct Cursor:\n\town int* value\nint Cursor_iter_begin(ref Cursor* c): return 0\nint Cursor_iter_done(ref Cursor* c, int cursor): return cursor >= 1\nint Cursor_iter_next(ref Cursor* c, int cursor): return cursor + 1\nref[a] int* Cursor_iter_value(ref[a] Cursor* c, int cursor): return c.value\nint main():\n\town int* value = new int\n\town Cursor* c = new Cursor(value)\n\tfor x in c: break\n\treturn *x\n", c"initializ")

# Borrowed result can escape through parent lifetime
void test_cursor_iteration_14():
	cursor_iteration_case(c"struct Cursor:\n\town int* value\nint Cursor_iter_begin(ref Cursor* c): return 0\nint Cursor_iter_done(ref Cursor* c, int cursor): return cursor >= 1\nint Cursor_iter_next(ref Cursor* c, int cursor): return cursor + 1\nref[a] int* Cursor_iter_value(ref[a] Cursor* c, int cursor): return c.value\noptref[a] int* first(ref[a] Cursor* c):\n\tfor x in c: return x\n\treturn 0\nint main():\n\town int* value = new int\n\t*value = 8\n\town Cursor* c = new Cursor(value)\n\toptref int* found = first(c)\n\tif found: return *found - 8\n\treturn 1\n", 0)

# Local backing cannot escape
void test_cursor_iteration_15():
	cursor_iteration_case(c"struct Cursor:\n\town int* value\nint Cursor_iter_begin(ref Cursor* c): return 0\nint Cursor_iter_done(ref Cursor* c, int cursor): return cursor >= 1\nint Cursor_iter_next(ref Cursor* c, int cursor): return cursor + 1\nref[a] int* Cursor_iter_value(ref[a] Cursor* c, int cursor): return c.value\noptref int* bad():\n\town int* value = new int\n\town Cursor* c = new Cursor(value)\n\tfor x in c: return x\n\treturn 0\nint main(): return 0\n", c"borrow")

# Map keys and shared values
void test_cursor_iteration_16():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tmap_set[int, int](m, 2, 5)\n\tmap_set[int, int](m, 3, 7)\n\tint sum = 0\n\tfor key, value in m: sum += key + *value\n\tfor key in m: sum += key\n\treturn sum - 22\n", 0)

# Set iteration
void test_cursor_iteration_17():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* s = set_new[int]()\n\tset_add[int](s, 2)\n\tset_add[int](s, 4)\n\tset_add[int](s, 2)\n\tint total = 0\n\tfor x in s: total += x\n\treturn total - 6\n", 0)

# Map empty and tombstones
void test_cursor_iteration_18():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tfor key in m: return 1\n\tfor i in range(20): map_set[int, int](m, i, i)\n\tfor i in range(20): map_remove[int, int](m, i)\n\tfor key in m: return 2\n\treturn 0\n", 0)

# Map record value references
void test_cursor_iteration_19():
	cursor_iteration_case(c"import lib.safe_hash\nstruct Pair:\n\tint left\n\tint right\nint main():\n\town WMap[int, Pair]* m = map_new[int, Pair]()\n\tmap_set[int, Pair](m, 2, Pair(3, 4))\n\tint total = 0\n\tfor int key, ref Pair* value in m: total += key + value.left + value.right\n\treturn total - 9\n", 0)

# Map invalidation
void test_cursor_iteration_20():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tmap_set[int, int](m, 2, 5)\n\tfor key in m: map_set[int, int](m, 4, 7)\n\treturn 0\n", c"borrow")

# Map saved value blocks clear
void test_cursor_iteration_21():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tmap_set[int, int](m, 2, 5)\n\toptref int* saved = 0\n\tfor key, value in m: saved = value\n\tmap_clear[int, int](m)\n\tif saved: return *saved\n\treturn 0\n", c"borrow")

# Map mutate after loop
void test_cursor_iteration_22():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tmap_set[int, int](m, 2, 5)\n\tint total = 0\n\tfor key, value in m: total += *value\n\tmap_clear[int, int](m)\n\treturn total - 5\n", 0)

# Set invalidation
void test_cursor_iteration_23():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* s = set_new[int]()\n\tset_add[int](s, 1)\n\tfor x in s: set_remove[int](s, x)\n\treturn 0\n", c"borrow")

# Set second variable rejected
void test_cursor_iteration_24():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WSet[int]* s = set_new[int]()\n\tfor x, y in s: return 1\n\treturn 0\n", c"sets have no values")

# Map raw value variable rejected
void test_cursor_iteration_25():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tfor int key, int* value in m: return 1\n\treturn 0\n", c"matching shared reference")

# Map owning temporary rejected
void test_cursor_iteration_26():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\tfor key in map_new[int, int](): return 1\n\treturn 0\n", c"safe:")

# Optional map requires presence binding
void test_cursor_iteration_27():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\toptown WMap[int, int]* m = map_new[int, int]()\n\tfor key in m: return 1\n\treturn 0\n", c"present container")

# Keyed map keys and values
void test_cursor_iteration_28():
	cursor_iteration_case(c"import lib.safe_keyed_map\nstruct Key:\n\tint number\nint hash(ref Key* k): return k.number\nint equal(ref Key* a, ref Key* b): return a.number == b.number\ntype H = fn[](ref Key*) -> int\ntype E = fn[](ref Key*, ref Key*) -> int\nint main():\n\town WKeyedMap[Key, int]* m = keyed_map_new[Key, int, H, E](hash, equal)\n\toptown Key* unused = keyed_map_insert[Key, int](m, new Key(3), 9)\n\tint total = 0\n\tfor key, value in m: total += key.number + *value\n\tfor key in m: total += key.number\n\treturn total - 15\n", 0)

# Keyed map remove while iterator live
void test_cursor_iteration_29():
	cursor_iteration_case(c"import lib.safe_keyed_map\nstruct Key:\n\tint number\nint hash(ref Key* k): return k.number\nint equal(ref Key* a, ref Key* b): return a.number == b.number\ntype H = fn[](ref Key*) -> int\ntype E = fn[](ref Key*, ref Key*) -> int\nint main():\n\town WKeyedMap[Key, int]* m = keyed_map_new[Key, int, H, E](hash, equal)\n\toptown Key* unused = keyed_map_insert[Key, int](m, new Key(3), 9)\n\tfor key in m: keyed_map_clear[Key, int](m)\n\treturn 0\n", c"borrow")

# Keyed map saved key blocks destruction
void test_cursor_iteration_30():
	cursor_iteration_case(c"import lib.safe_keyed_map\nstruct Key:\n\tint number\nint hash(ref Key* k): return k.number\nint equal(ref Key* a, ref Key* b): return a.number == b.number\ntype H = fn[](ref Key*) -> int\ntype E = fn[](ref Key*, ref Key*) -> int\nint main():\n\town WKeyedMap[Key, int]* m = keyed_map_new[Key, int, H, E](hash, equal)\n\toptown Key* unused = keyed_map_insert[Key, int](m, new Key(3), 9)\n\toptref Key* saved = 0\n\tfor key in m: saved = key\n\tkeyed_map_clear[Key, int](m)\n\tif saved: return saved.number\n\treturn 0\n", c"borrow")

# Generic cursor imports and alias
void test_cursor_iteration_31():
	cursor_iteration_case(c"import tests.safe_cursor_module as cursor\nint main():\n\town int* a = new int\n\t*a = 6\n\town byte* b = new byte\n\town WCursor[int, byte]* c = cursor.make_cursor[int, byte](a, b)\n\tint total = 0\n\tfor x in c: total += *x\n\treturn total - 6\n", 0)


# Iterable call evaluated once
void test_cursor_iteration_32():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nref[a] Counter* once(ref[a] Counter* c, refmut[b] int* hits):\n\t*hits += 1\n\treturn c\nint main():\n\town Counter* c = new Counter(4)\n\town int* hits = new int\n\t*hits = 0\n\tint total = 0\n\tfor x in once(c, hits): total += x\n\treturn total + *hits - 7\n", 0)


# Two nested map iterators
void test_cursor_iteration_33():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tmap_set[int, int](m, 2, 5)\n\tmap_set[int, int](m, 3, 7)\n\tint total = 0\n\tfor a, x in m:\n\t\tfor b, y in m: total += *x + *y\n\treturn total - 48\n", 0)


# Mutable map values rejected
void test_cursor_iteration_34():
	cursor_iteration_case(c"import lib.safe_hash\nint main():\n\town WMap[int, int]* m = map_new[int, int]()\n\tfor int key, refmut int* value in m: *value = 1\n\treturn 0\n", c"matching shared reference")


# Owning cursor result rejected
void test_cursor_iteration_35():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nown int* Counter_iter_value(ref Counter* c, int cursor): return new int\nint main():\n\town Counter* c = new Counter(1)\n\tfor x in c: return 0\n\treturn 0\n", c"scalar or shared reference")


# Absent cursor implementation rejected
void test_cursor_iteration_36():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor);\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\town Counter* c = new Counter(1)\n\tfor x in c: return x\n\treturn 0\n", c"checked implementation")


# Owning cursor call result requires named owner
void test_cursor_iteration_37():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nown Counter* make(): return new Counter(2)\nint main():\n\tfor x in make(): return x\n\treturn 0\n", c"named owner")


# Parent owner cannot move during cursor reads
void test_cursor_iteration_38():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint take(own Counter* c): return c.count\nint main():\n\town Counter* c = new Counter(2)\n\tint total = 0\n\tfor x in c: total += take(c)\n\treturn total\n", c"safe:")


# Optional cursor rejected
void test_cursor_iteration_39():
	cursor_iteration_case(c"struct Counter:\n\tint count\nint Counter_iter_begin(ref Counter* c): return 0\nint Counter_iter_done(ref Counter* c, int cursor): return cursor >= c.count\nint Counter_iter_next(ref Counter* c, int cursor): return cursor + 1\nint Counter_iter_value(ref Counter* c, int cursor): return cursor\nint main():\n\toptown Counter* c = new Counter(2)\n\tfor x in c: return x\n\treturn 0\n", c"checked shared slice")
