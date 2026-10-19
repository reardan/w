# wbuild: x64
# Thread transfer/share eligibility and the audited spawn/join API (#699).
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int transfer_case_number


void transfer_result(process_result* result, char* diagnostic, int checking, char* path):
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


void transfer_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	transfer_case_number = transfer_case_number + 1
	char* number = itoa(transfer_case_number)
	char* prefix = c"bin/transfer_case32_"
	if (__word_size__ == 8): prefix = c"bin/transfer_case64_"
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
		transfer_result(checked, diagnostic, 1, full)
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
		transfer_result(compiled, diagnostic, 0, full)
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

# Spawn transfers a nested owned payload; join returns the entry result.
void test_transfer_0():
	transfer_case(c"import lib.safe_thread\n\nstruct Payload:\n\town int* value\n\nstruct Job:\n\town Payload* payload\n\tint index\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\tref Payload* payload = job.payload\n\tref int* value = payload.value\n\treturn *value + job.index\n\nown Job* make_job(int index):\n\town int* value = new int\n\t*value = 40\n\treturn new Job(new Payload(value), index)\n\nint main():\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, make_job(2))\n\tif (!thread): return 1\n\town WSafeThread* started = thread\n\treturn safe_thread_join(started) - 42\n", 0)

# Explicit type arguments accept a bare entry function name.
void test_transfer_1():
	transfer_case(c"import lib.safe_thread\n\nstruct Payload:\n\town int* value\n\nstruct Job:\n\town Payload* payload\n\tint index\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\tref Payload* payload = job.payload\n\tref int* value = payload.value\n\treturn *value + job.index\n\nown Job* make_job(int index):\n\town int* value = new int\n\t*value = 40\n\treturn new Job(new Payload(value), index)\n\nint main():\n\toptown WSafeThread* thread = safe_thread_spawn[Worker, Job](run_job, make_job(2))\n\tif (!thread): return 1\n\town WSafeThread* started = thread\n\treturn safe_thread_join(started) - 42\n", 0)

# Callable fields, audited storage and unshared markers are transferable.
void test_transfer_2():
	transfer_case(c"import lib.safe_thread\nimport lib.safe_buffer\n\ntype Scale = fn[](int) -> int\n\nstruct Job:\n\tScale* scale\n\town WIntBuffer* items\n\tWThreadUnshared marker\n\ntype Worker = fn[](own Job*) -> int\n\nint double(int value):\n\treturn value * 2\n\nint run_job(own Job* job):\n\tref WIntBuffer* items = job.items\n\treturn job.scale(int_buffer_get(items, 0))\n\nint main():\n\town WIntBuffer* items = int_buffer_new()\n\trefmut WIntBuffer* writer = items\n\tint_buffer_push(writer, 21)\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, new Job(double, items, WThreadUnshared(0)))\n\tif (!thread): return 1\n\town WSafeThread* started = thread\n\treturn safe_thread_join(started) - 42\n", 0)

# A dropped unjoined handle waits for its child.
void test_transfer_3():
	transfer_case(c"import lib.safe_thread\n\nstruct Payload:\n\town int* value\n\nstruct Job:\n\town Payload* payload\n\tint index\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\tref Payload* payload = job.payload\n\tref int* value = payload.value\n\treturn *value + job.index\n\nown Job* make_job(int index):\n\town int* value = new int\n\t*value = 40\n\treturn new Job(new Payload(value), index)\n\nint detach_then_drop():\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, make_job(1))\n\tif (!thread): return 1\n\treturn 0\n\nint main():\n\treturn detach_then_drop()\n", 0)

# A borrowed field of a labeled owner cannot reach detached work.
void test_transfer_4():
	transfer_case(c"import lib.safe_thread\n\nstruct Job:\n\tref[a] int* value\n\ntype Worker = fn[a](own[a] Job*) -> int\n\nint run_job(own[a] Job* job):\n\tref int* value = job.value\n\treturn *value\n\nint main():\n\tint local = 6\n\town[a] Job* job = new Job(&local)\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\treturn 0\n", c"thread payload field 'value' borrows storage that the thread could outlive")

# Unique ownership alone does not make a borrowing child transferable.
void test_transfer_5():
	transfer_case(c"import lib.safe_thread\n\nstruct Inner:\n\tref[a] int* value\n\nstruct Job:\n\town[a] Inner* inner\n\ntype Worker = fn[a](own[a] Job*) -> int\n\nint run_job(own[a] Job* job):\n\treturn 0\n\nint main():\n\tint local = 6\n\town[a] Job* job = new Job(new Inner(&local))\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\treturn 0\n", c"thread payload field 'inner' carries a borrowed lifetime")

# A shared reference to stack data is never an owner for detached work.
void test_transfer_6():
	transfer_case(c"import lib.safe_thread\n\nstruct Job:\n\tint count\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\treturn job.count\n\nint main():\n\tJob local = Job(3)\n\tref Job* view = &local\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, view)\n\treturn 0\n", c"owner requires new storage or an ownership transfer")

# A thread-affine marker anywhere in the owned graph forbids transfer.
void test_transfer_7():
	transfer_case(c"import lib.safe_thread\n\nstruct Inner:\n\tint count\n\tWThreadAffine affinity\n\nstruct Job:\n\town Inner* inner\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\treturn 0\n\nint main():\n\town Job* job = new Job(new Inner(1, WThreadAffine(0)))\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\treturn 0\n", c"thread payload field 'inner.affinity' is explicitly thread-affine")

# A directly thread-affine payload is rejected.
void test_transfer_8():
	transfer_case(c"import lib.safe_thread\n\ntype Worker = fn[](own WThreadAffine*) -> int\n\nint run_job(own WThreadAffine* job):\n\treturn 0\n\nint main():\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, new WThreadAffine(0))\n\treturn 0\n", c"thread payload is explicitly thread-affine")

# The entry must consume exactly the transferred owner.
void test_transfer_9():
	transfer_case(c"import lib.safe_thread\n\nstruct Job:\n\tint count\n\ntype Worker = fn[](ref Job*) -> int\n\nint run_job(ref Job* job):\n\treturn 0\n\nint main():\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, new Job(1))\n\treturn 0\n", c"thread entry must be fn[](own T*) -> int")

# The payload is moved into the thread.
void test_transfer_10():
	transfer_case(c"import lib.safe_thread\n\nstruct Payload:\n\town int* value\n\nstruct Job:\n\town Payload* payload\n\tint index\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\tref Payload* payload = job.payload\n\tref int* value = payload.value\n\treturn *value + job.index\n\nown Job* make_job(int index):\n\town int* value = new int\n\t*value = 40\n\treturn new Job(new Payload(value), index)\n\nint main():\n\town Job* job = make_job(1)\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, job)\n\treturn job.index\n", c"moved")

# A joined handle is consumed.
void test_transfer_11():
	transfer_case(c"import lib.safe_thread\n\nstruct Payload:\n\town int* value\n\nstruct Job:\n\town Payload* payload\n\tint index\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\tref Payload* payload = job.payload\n\tref int* value = payload.value\n\treturn *value + job.index\n\nown Job* make_job(int index):\n\town int* value = new int\n\t*value = 40\n\treturn new Job(new Payload(value), index)\n\nint main():\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, make_job(1))\n\tif (!thread): return 1\n\town WSafeThread* started = thread\n\tint result = safe_thread_join(started)\n\treturn safe_thread_join(started)\n", c"moved")

# A refused spawn yields an absent handle that must be tested.
void test_transfer_12():
	transfer_case(c"import lib.safe_thread\n\nstruct Payload:\n\town int* value\n\nstruct Job:\n\town Payload* payload\n\tint index\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\tref Payload* payload = job.payload\n\tref int* value = payload.value\n\treturn *value + job.index\n\nown Job* make_job(int index):\n\town int* value = new int\n\t*value = 40\n\treturn new Job(new Payload(value), index)\n\nint main():\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, make_job(1))\n\town WSafeThread* started = thread\n\treturn safe_thread_join(started)\n", c"presence check")

# Handles are opaque.
void test_transfer_13():
	transfer_case(c"import lib.safe_thread\n\nstruct Payload:\n\town int* value\n\nstruct Job:\n\town Payload* payload\n\tint index\n\ntype Worker = fn[](own Job*) -> int\n\nint run_job(own Job* job):\n\tref Payload* payload = job.payload\n\tref int* value = payload.value\n\treturn *value + job.index\n\nown Job* make_job(int index):\n\town int* value = new int\n\t*value = 40\n\treturn new Job(new Payload(value), index)\n\nint main():\n\tWorker* entry = run_job\n\toptown WSafeThread* thread = safe_thread_spawn(entry, make_job(1))\n\tif (!thread): return 1\n\town WSafeThread* started = thread\n\treturn started.result\n", c"opaque collection metadata is not accessible")

# Handles have no checked constructor.
void test_transfer_14():
	transfer_case(c"import lib.safe_thread\n\nint main():\n\town WSafeThread* thread = new WSafeThread\n\treturn 0\n", c"opaque collections require an audited constructor")

# Raw runtime helpers are not exposed.
void test_transfer_15():
	transfer_case(c"import lib.safe_thread\n\nint main():\n\town int* value = new int\n\tif (__w_safe_thread_start(0, 0) == 0): return 1\n\treturn 0\n", c"runtime call has no audited ownership contract")

# Fork-join lends disjoint exclusive borrows to two threads.
void test_transfer_16():
	transfer_case(c"import lib.safe_thread\n\nstruct Chunk:\n\tint start\n\tint total\n\ntype Sum = fn[](refmut Chunk*) -> int\n\nint fill(refmut Chunk* chunk):\n\tchunk.total = chunk.start + 1\n\treturn chunk.total\n\nint main():\n\town Chunk* left = new Chunk(10, 0)\n\town Chunk* right = new Chunk(30, 0)\n\trefmut Chunk* first = left\n\trefmut Chunk* second = right\n\tSum* entry = fill\n\tint total = safe_thread_fork_join(entry, first, second)\n\tif (total != 42): return 1\n\treturn left.total + right.total - 42\n", 0)

# Fork-join shares a read-only borrow of stack data.
void test_transfer_17():
	transfer_case(c"import lib.safe_thread\n\nstruct Table:\n\tint base\n\tWThreadUnshared marker\n\ntype Read = fn[](ref int*) -> int\n\nint read_value(ref int* value):\n\treturn *value\n\nint main():\n\tint shared = 21\n\tref int* view = &shared\n\tRead* reader = read_value\n\treturn safe_thread_fork_join(reader, view, view) - 42\n", 0)

# An exclusive borrow may carry an unshared value to one thread.
void test_transfer_18():
	transfer_case(c"import lib.safe_thread\n\nstruct Counter:\n\tint count\n\tWThreadUnshared marker\n\ntype Bump = fn[](refmut Counter*) -> int\n\nint bump(refmut Counter* counter):\n\tcounter.count = counter.count + 1\n\treturn counter.count\n\nint main():\n\town Counter* left = new Counter(0, WThreadUnshared(0))\n\town Counter* right = new Counter(1, WThreadUnshared(0))\n\trefmut Counter* first = left\n\trefmut Counter* second = right\n\tBump* entry = bump\n\treturn safe_thread_fork_join(entry, first, second) - 3\n", 0)

# Fork-join cannot lend the same exclusive storage twice.
void test_transfer_19():
	transfer_case(c"import lib.safe_thread\n\nstruct Chunk:\n\tint start\n\tint total\n\ntype Sum = fn[](refmut Chunk*) -> int\n\nint fill(refmut Chunk* chunk):\n\tchunk.total = chunk.start + 1\n\treturn chunk.total\n\nint main():\n\town Chunk* chunk = new Chunk(10, 0)\n\trefmut Chunk* first = chunk\n\tSum* entry = fill\n\treturn safe_thread_fork_join(entry, first, first)\n", c"conflicting call arguments")

# A live shared view excludes lending the same storage exclusively.
void test_transfer_20():
	transfer_case(c"import lib.safe_thread\n\nstruct Chunk:\n\tint start\n\tint total\n\ntype Sum = fn[](refmut Chunk*) -> int\n\nint fill(refmut Chunk* chunk):\n\tchunk.total = chunk.start + 1\n\treturn chunk.total\n\nint main():\n\town Chunk* left = new Chunk(10, 0)\n\town Chunk* right = new Chunk(30, 0)\n\tref Chunk* view = left\n\trefmut Chunk* first = left\n\trefmut Chunk* second = right\n\tSum* entry = fill\n\tint total = safe_thread_fork_join(entry, first, second)\n\treturn view.start + total\n", c"conflicting access while a borrow is live")

# An unshared value cannot be read from two threads through a shared borrow.
void test_transfer_21():
	transfer_case(c"import lib.safe_thread\n\nstruct Counter:\n\tint count\n\tWThreadUnshared marker\n\ntype Read = fn[](ref Counter*) -> int\n\nint read_count(ref Counter* counter):\n\treturn counter.count\n\nint main():\n\town Counter* counter = new Counter(1, WThreadUnshared(0))\n\tref Counter* view = counter\n\tRead* reader = read_count\n\treturn safe_thread_fork_join(reader, view, view)\n", c"scoped thread argument field 'marker' is explicitly unshareable across threads")

# A thread-affine value cannot cross even inside a scoped borrow.
void test_transfer_22():
	transfer_case(c"import lib.safe_thread\n\nstruct Inner:\n\tWThreadAffine affinity\n\nstruct Counter:\n\tint count\n\town Inner* inner\n\ntype Bump = fn[](refmut Counter*) -> int\n\nint bump(refmut Counter* counter):\n\treturn counter.count\n\nint main():\n\town Counter* left = new Counter(0, new Inner(WThreadAffine(0)))\n\town Counter* right = new Counter(1, new Inner(WThreadAffine(0)))\n\trefmut Counter* first = left\n\trefmut Counter* second = right\n\tBump* entry = bump\n\treturn safe_thread_fork_join(entry, first, second)\n", c"scoped thread argument field 'inner.affinity' is explicitly thread-affine")

# Fork-join lends borrows; owners go through spawn.
void test_transfer_23():
	transfer_case(c"import lib.safe_thread\n\nstruct Chunk:\n\tint start\n\tint total\n\ntype Sum = fn[](refmut Chunk*) -> int\n\nint fill(refmut Chunk* chunk):\n\tchunk.total = chunk.start + 1\n\treturn chunk.total\n\ntype Take = fn[](own Chunk*) -> int\n\nint take(own Chunk* chunk):\n\treturn chunk.start\n\nint main():\n\tTake* entry = take\n\treturn safe_thread_fork_join(entry, new Chunk(1, 0), new Chunk(2, 0))\n", c"fork-join entry must be fn[](T) -> int for a ref or refmut pointer T")

# Fork-join entries must accept the lent type.
void test_transfer_24():
	transfer_case(c"import lib.safe_thread\n\nstruct Chunk:\n\tint start\n\tint total\n\ntype Sum = fn[](refmut Chunk*) -> int\n\nint fill(refmut Chunk* chunk):\n\tchunk.total = chunk.start + 1\n\treturn chunk.total\n\ntype Read = fn[](ref Chunk*) -> int\n\nint read_start(ref Chunk* chunk):\n\treturn chunk.start\n\nint main():\n\town Chunk* left = new Chunk(10, 0)\n\town Chunk* right = new Chunk(30, 0)\n\trefmut Chunk* first = left\n\trefmut Chunk* second = right\n\tRead* entry = read_start\n\treturn safe_thread_fork_join(entry, first, second)\n", c"fork-join entry must be fn[](T) -> int")
