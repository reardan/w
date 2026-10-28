# wbuild: x64
# wbuild: deps=lib/safe_keyed_map.w
# Checked maps keyed by owned values with checked user hashing/equality
# (#697). Every contract is checked and compiled with and without --safe.
# Rejections must prevent publication of an executable.
import lib.testing
import lib.process
import lib.file


int keyed_map_case_number


void keyed_map_result(process_result* result, char* diagnostic, int checking, char* path):
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


void keyed_map_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	keyed_map_case_number = keyed_map_case_number + 1
	char* number = itoa(keyed_map_case_number)
	char* prefix = c"bin/keyed_map_case32_"
	if (__word_size__ == 8): prefix = c"bin/keyed_map_case64_"
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
		keyed_map_result(checked, diagnostic, 1, full)
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
		keyed_map_result(compiled, diagnostic, 0, full)
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

# Owned record keys with checked hash and equality functions.
void test_keyed_map_0():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\n\tint y\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x * 31 + p.y\nint point_equal(ref Point* a, ref Point* b):\n\treturn (a.x == b.x) && (a.y == b.y)\nint main():\n\tPointHash* hash = point_hash\n\tPointEqual* equal = point_equal\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](hash, equal)\n\tfor i in range(20):\n\t\toptown Point* duplicate = keyed_map_insert[Point, int](map, new Point(i % 10, 1), i)\n\town Point* probe = new Point(3, 1)\n\treturn keyed_map_get[Point, int](map, probe) + keyed_map_length[Point, int](map) - 23\n", 0)

# Function names convert to the declared contracts at the call.
void test_keyed_map_1():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\toptown Point* duplicate = keyed_map_insert[Point, int](map, new Point(4), 9)\n\town Point* probe = new Point(4)\n\treturn keyed_map_get_or[Point, int](map, probe, 0) - 9\n", 0)

# The hash function cannot take ownership of the key.
void test_keyed_map_2():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](own Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(own Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\tPointHash* hash = point_hash\n\tPointEqual* equal = point_equal\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](hash, equal)\n\treturn 0\n", c"keyed map operations must be fn[](ref K*) -> int")

# The equality function cannot mutate a key.
void test_keyed_map_3():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](refmut Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(refmut Point* a, ref Point* b):\n\ta.x = b.x\n\treturn 1\nint main():\n\tPointHash* hash = point_hash\n\tPointEqual* equal = point_equal\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](hash, equal)\n\treturn 0\n", c"keyed map operations must be fn[](ref K*) -> int")

# Operations over another key type are rejected.
void test_keyed_map_4():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\nstruct Other:\n\tint x\ntype OtherHash = fn[](ref Other*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint other_hash(ref Other* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\tOtherHash* hash = other_hash\n\tPointEqual* equal = point_equal\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, OtherHash, PointEqual](hash, equal)\n\treturn 0\n", c"keyed map operations must be fn[](ref K*) -> int")

# The equality function must take two keys.
void test_keyed_map_5():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint main():\n\tPointHash* hash = point_hash\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointHash](hash, hash)\n\treturn 0\n", c"keyed map operations must be fn[](ref K*) -> int")

# Optional key views are not the declared contract.
void test_keyed_map_6():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](optref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(optref Point* p):\n\tif (p): return p.x\n\treturn 0\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\tPointHash* hash = point_hash\n\tPointEqual* equal = point_equal\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](hash, equal)\n\treturn 0\n", c"keyed map operations must be fn[](ref K*) -> int")

# Raw function pointers are not checked operations.
void test_keyed_map_7():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype RawHash = fn(Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(Point* p):\n\treturn 0\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\tPointEqual* equal = point_equal\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, RawHash, PointEqual](point_hash, equal)\n\treturn 0\n", c"safe:")

# A checked hash body cannot write through its shared key view.
void test_keyed_map_8():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\tp.x = 0\n\treturn 0\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\tPointHash* hash = point_hash\n\tPointEqual* equal = point_equal\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](hash, equal)\n\treturn 0\n", c"safe:")

# Duplicate insertion returns the argument key and replaces the value.
void test_keyed_map_9():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\n\town int* payload\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nown Point* point(int x, int payload):\n\town int* value = new int\n\t*value = payload\n\treturn new Point(x, value)\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\toptown Point* first = keyed_map_insert[Point, int](map, point(1, 10), 1)\n\tif (first): return 1\n\toptown Point* second = keyed_map_insert[Point, int](map, point(1, 20), 2)\n\tif (!second): return 2\n\tref int* payload = second.payload\n\town Point* probe = point(1, 0)\n\treturn *payload + keyed_map_get[Point, int](map, probe) - 22\n", 0)

# A live found value blocks insertion even with spare capacity.
void test_keyed_map_10():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\toptown Point* d = keyed_map_insert[Point, int](map, new Point(1), 1)\n\town Point* probe = new Point(1)\n\toptref int* found = keyed_map_find[Point, int](map, probe)\n\toptown Point* e = keyed_map_insert[Point, int](map, new Point(2), 2)\n\tif (found): return *found\n\treturn 0\n", c"borrow")

# A live found value blocks removal.
void test_keyed_map_11():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\toptown Point* d = keyed_map_insert[Point, int](map, new Point(1), 1)\n\town Point* probe = new Point(1)\n\toptref int* found = keyed_map_find[Point, int](map, probe)\n\tkeyed_map_clear[Point, int](map)\n\tif (found): return *found\n\treturn 0\n", c"borrow")

# Mutation resumes after the found value's last use.
void test_keyed_map_12():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\toptown Point* d = keyed_map_insert[Point, int](map, new Point(1), 5)\n\town Point* probe = new Point(1)\n\tint total = 0\n\toptref int* found = keyed_map_find[Point, int](map, probe)\n\tif (found): total = *found\n\ttotal += keyed_map_remove[Point, int](map, probe)\n\treturn total - 6 + keyed_map_length[Point, int](map)\n", 0)

# Taking a key transfers its ownership out of the map.
void test_keyed_map_13():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\n\town int* payload\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\town int* value = new int\n\t*value = 7\n\toptown Point* d = keyed_map_insert[Point, int](map, new Point(1, value), 5)\n\town int* other = new int\n\town Point* probe = new Point(1, other)\n\toptown Point* taken = keyed_map_take[Point, int](map, probe)\n\tif (!taken): return 1\n\town Point* key = taken\n\tref int* payload = key.payload\n\treturn *payload - 7 + keyed_map_length[Point, int](map)\n", 0)

# An inserted key is consumed.
void test_keyed_map_14():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\town Point* key = new Point(1)\n\toptown Point* d = keyed_map_insert[Point, int](map, key, 5)\n\treturn key.x\n", c"moved")

# Map metadata stays private.
void test_keyed_map_15():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\treturn map.count\n", c"safe:")

# Private runtime helpers are not checked contracts.
void test_keyed_map_16():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\tkeyed_map_clear[Point, int](map)\n\t__w_keyed_map_drop_keys(cast(__WKeyedMapHeader*, map))\n\treturn 0\n", c"safe:")

# Values must be pointer-free.
void test_keyed_map_17():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int*]* map = keyed_map_new[Point, int*, PointHash, PointEqual](point_hash, point_equal)\n\treturn 0\n", c"safe:")

# Keys cannot carry borrowed fields.
void test_keyed_map_18():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct View:\n\tref[v] int* value\ntype ViewHash = fn[](ref View*) -> int\ntype ViewEqual = fn[](ref View*, ref View*) -> int\nint view_hash(ref View* p):\n\treturn 0\nint view_equal(ref View* a, ref View* b):\n\treturn 1\nint main():\n\town WKeyedMap[View, int]* map = keyed_map_new[View, int, ViewHash, ViewEqual](view_hash, view_equal)\n\treturn 0\n", c"safe:")

# Keys cross threads with their map.
void test_keyed_map_19():
	keyed_map_case(c"import lib.safe_keyed_map\nimport lib.safe_thread\nstruct Key:\n\tint x\n\tWThreadAffine key\nstruct Job:\n\town WKeyedMap[Key, int]* map\ntype KeyHash = fn[](ref Key*) -> int\ntype KeyEqual = fn[](ref Key*, ref Key*) -> int\nint key_hash(ref Key* p):\n\treturn p.x\nint key_equal(ref Key* a, ref Key* b):\n\treturn a.x == b.x\ntype Worker = fn[](own Job*) -> int\nint run_job(own Job* job):\n\treturn 0\nint main():\n\town Job* job = new Job(keyed_map_new[Key, int, KeyHash, KeyEqual](key_hash, key_equal))\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\treturn 0\n", c"thread payload field 'map.key' is explicitly thread-affine")

# Keyed maps nest inside owned storage and records; aliases resolve.
void test_keyed_map_20():
	keyed_map_case(c"import lib.safe_keyed_map as keyed\nimport lib.safe_owned_vector\nstruct Point:\n\tint x\nstruct Holder:\n\town WKeyedMap[Point, int]* map\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WOwnedBuffer[Holder]* holders = owned_buffer_new[Holder](-1)\n\tfor i in range(3):\n\t\town Holder* holder = new Holder(keyed.keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal))\n\t\toptown Point* d = keyed.keyed_map_insert[Point, int](holder.map, new Point(i), i)\n\t\towned_buffer_push[Holder](holders, holder)\n\tint total = 0\n\tfor holder in holders: total += keyed.keyed_map_length[Point, int](holder.map)\n\treturn total - 3\n", 0)

# A constant hash and an always-false equality stay memory safe.
void test_keyed_map_21():
	keyed_map_case(c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn 0\nint point_equal(ref Point* a, ref Point* b):\n\treturn 0\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\tfor i in range(30):\n\t\toptown Point* duplicate = keyed_map_insert[Point, int](map, new Point(1), i)\n\t\tif (duplicate): return 1\n\town Point* probe = new Point(1)\n\treturn keyed_map_length[Point, int](map) - 30 + keyed_map_contains[Point, int](map, probe)\n", 0)

void test_keyed_map_runtime_pin():
	char* root = c"bin/safe_keyed_map_pin32"
	if (__word_size__ == 8): root = c"bin/safe_keyed_map_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/lib")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/safe_keyed_map.w")
	char* source = strjoin(root, c".w")
	char* output = strjoin(root, c".out")
	char* original = file_read_text(c"lib/safe_keyed_map.w")
	assert1(original != 0)
	char* changed = strjoin(original, c"\n# changed implementation cannot inherit checked contracts\n")
	assert1(file_write_text(path, changed))
	assert1(file_write_text(source, c"import lib.safe_keyed_map\nstruct Point:\n\tint x\ntype PointHash = fn[](ref Point*) -> int\ntype PointEqual = fn[](ref Point*, ref Point*) -> int\nint point_hash(ref Point* p):\n\treturn p.x\nint point_equal(ref Point* a, ref Point* b):\n\treturn a.x == b.x\nint main():\n\town WKeyedMap[Point, int]* map = keyed_map_new[Point, int, PointHash, PointEqual](point_hash, point_equal)\n\treturn keyed_map_length[Point, int](map)\n"))
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
			keyed_map_result(result, c"runtime implementation differs", checking, source)
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
