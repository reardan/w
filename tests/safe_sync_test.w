# wbuild: x64
# Guarded mutexes and explicit-order atomics for checked threads (#699
# deliverable 4): guard and view lifetimes, guard thread binding, mutex and
# atomic shareability, and static memory-order contracts.
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int sync_case_number


void sync_result(process_result* result, char* diagnostic, int checking, char* path):
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


void sync_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* explicit_safe_diagnostic = 0, char* runtime_diagnostic = 0):
	sync_case_number = sync_case_number + 1
	char* number = itoa(sync_case_number)
	char* prefix = c"bin/sync_case32_"
	if (__word_size__ == 8): prefix = c"bin/sync_case64_"
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
		sync_result(checked, diagnostic, 1, full)
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
		sync_result(compiled, diagnostic, 0, full)
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

# A lock returns a guard whose view mutates the payload; unlock releases it.
void test_sync_0():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\tref WSafeMutex[int]* shared = m\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(shared)\n\trefmut int* v = safe_guard_value(g)\n\t*v = *v + 1\n\tsafe_guard_unlock(g)\n\town[b] WSafeGuard[int]* h = safe_mutex_lock(shared)\n\trefmut int* w = safe_guard_value(h)\n\treturn *w - 6\n", 0)

# Guards may live in owners and cross calls under the mutex's lifetime.
void test_sync_1():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard[int]* guard\n\tint tag\n\nown[a] Holder* hold(ref[a] WSafeMutex[int]* m):\n\treturn new Holder(safe_mutex_lock(m), 3)\n\nown[a] WSafeGuard[int]* relock(ref[a] WSafeMutex[int]* m):\n\treturn safe_mutex_lock(m)\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\tif (1):\n\t\town[a] Holder* h = hold(m)\n\t\tif (h.tag != 3): return 1\n\town[b] WSafeGuard[int]* g = relock(m)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v - 5\n", 0)

# A mutex is shareable: fork-join threads contend through guards.
void test_sync_2():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Bump = fn[](ref WSafeMutex[int]*) -> int\n\nint bump(ref WSafeMutex[int]* m):\n\tfor i in range(1000):\n\t\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\t\trefmut int* v = safe_guard_value(g)\n\t\t*v = *v + 1\n\treturn 0\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(0))\n\tref WSafeMutex[int]* shared = m\n\tBump* entry = bump\n\tsafe_thread_fork_join(entry, shared, shared)\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(shared)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v - 2000\n", 0)

# A mutex and an atomic are transferable inside a spawned payload.
void test_sync_3():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Job:\n\town WSafeMutex[int]* mutex\n\town WSafeAtomic* count\n\ntype Worker = fn[](own Job*) -> int\n\nint run(own Job* job):\n\tref WSafeMutex[int]* m = job.mutex\n\tref WSafeAtomic* c = job.count\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v + safe_atomic_fetch_add(c, 1, memory_order_relaxed)\n\nint main():\n\tWorker* entry = run\n\toptown WSafeThread* t = safe_thread_spawn(entry, new Job(safe_mutex_new(boxed(40)), safe_atomic_new(2)))\n\tif (!t): return 1\n\town WSafeThread* started = t\n\treturn safe_thread_join(started) - 42\n", 0)

# Every admitted memory order compiles for each atomic operation.
void test_sync_4():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\tref WSafeAtomic* r = a\n\tsafe_atomic_store(r, 7, memory_order_release)\n\tsafe_atomic_store(r, 7, memory_order_relaxed)\n\tint x = safe_atomic_load(r, memory_order_acquire)\n\tx = x + safe_atomic_load(r, memory_order_seq_cst) - 7\n\tint y = safe_atomic_fetch_add(r, 3, memory_order_relaxed)\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_acquire) - 10\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_release) - 10\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_acq_rel) - 10\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_seq_cst) - 10\n\tint z = safe_atomic_compare_exchange(r, 10, 1, memory_order_seq_cst, memory_order_acquire)\n\tz = z + safe_atomic_compare_exchange(r, 9, 2, memory_order_release, memory_order_relaxed) - 1\n\tz = z + safe_atomic_compare_exchange(r, 1, 3, memory_order_acq_rel, memory_order_seq_cst) - 1\n\tsafe_atomic_store(r, 2, memory_order_seq_cst)\n\treturn x + y + z - 24 + safe_atomic_load(r, memory_order_relaxed) - 2\n", 0)

# An atomic is shareable across fork-join threads.
void test_sync_5():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Bump = fn[](ref WSafeAtomic*) -> int\n\nint bump(ref WSafeAtomic* a):\n\tfor i in range(10000): safe_atomic_fetch_add(a, 1, memory_order_relaxed)\n\treturn 0\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(0)\n\tref WSafeAtomic* r = a\n\tBump* entry = bump\n\tsafe_thread_fork_join(entry, r, r)\n\treturn safe_atomic_load(r, memory_order_seq_cst) - 20000\n", 0)

# A view cannot outlive an explicit unlock.
void test_sync_6():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\trefmut int* v = safe_guard_value(g)\n\tsafe_guard_unlock(g)\n\treturn *v\n", c"use of uninitialized or moved value")

# A view cannot outlive its guard's scope.
void test_sync_7():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\toptrefmut int* v = 0\n\tif (1):\n\t\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\t\tv = safe_guard_value(g)\n\tif (v): return *v\n\treturn 0\n", c"use of uninitialized or moved value")

# A guard cannot be used after it is released.
void test_sync_8():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\tsafe_guard_unlock(g)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v\n", c"use of uninitialized or moved value")

# Two live views of one guard conflict.
void test_sync_9():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\trefmut int* v = safe_guard_value(g)\n\trefmut int* w = safe_guard_value(g)\n\t*w = 1\n\treturn *v\n", c"conflicting access while a borrow is live")

# A shared guard reference cannot open the exclusive view.
void test_sync_10():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint peek(ref WSafeGuard[int]* g):\n\trefmut int* v = safe_guard_value(g)\n\treturn *v\n\nint main():\n\treturn 0\n", c"cannot make a mutable borrow from a shared reference")

# A view cannot escape the function holding its guard.
void test_sync_11():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nrefmut int* grab(ref WSafeMutex[int]* m):\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\treturn safe_guard_value(g)\n\nint main():\n\treturn 0\n", c"mutable reference return requires a mutable borrowed parameter")

# A guard of a local mutex cannot be returned.
void test_sync_12():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nown[a] WSafeGuard[int]* leak():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\treturn safe_mutex_lock(m)\n\nint main():\n\treturn 0\n", c"returned lifetime must name a borrowed parameter")

# A guard cannot escape inside a returned owner either.
void test_sync_13():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard[int]* guard\n\nown[a] Holder* hold(ref[a] WSafeMutex[int]* m):\n\treturn new Holder(safe_mutex_lock(m))\n\nown[a] Holder* bad():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(1))\n\treturn hold(m)\n\nint main():\n\treturn 0\n", c"returned lifetime must name a borrowed parameter")

# Moving a locked mutex conflicts with the guard's pending drop.
void test_sync_14():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\town WSafeMutex[int]* moved = m\n\treturn 0\n", c"conflicting access while a borrow is live")

# Consuming a locked mutex conflicts with the guard's pending drop.
void test_sync_15():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nvoid eat(own WSafeMutex[int]* m):\n\treturn\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\teat(m)\n\treturn 0\n", c"conflicting access while a borrow is live")

# Replacing a locked mutex conflicts with the guard's pending drop.
void test_sync_16():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\tm = safe_mutex_new(boxed(6))\n\treturn 0\n", c"conflicting access while a borrow is live")

# A guard released on only one path still pins its mutex.
void test_sync_17():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint run(int early):\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\tif (early): safe_guard_unlock(g)\n\town WSafeMutex[int]* moved = m\n\treturn 0\n\nint main():\n\treturn run(1)\n", c"conflicting access while a borrow is live")

# A guard cannot outlive a mutex declared in an inner block.
void test_sync_18():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\toptown[a] WSafeGuard[int]* outer = 0\n\tif (1):\n\t\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\t\touter = safe_mutex_lock(m)\n\treturn 0\n", c"lock guard outlives the mutex it borrows")

# A guard owner must carry its mutex lifetime.
void test_sync_19():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town WSafeGuard[int]* g = safe_mutex_lock(m)\n\treturn 0\n", c"a lock guard owner must name its mutex lifetime (own[a] WSafeGuard[T]*)")

# A guard cannot move to a spawned thread.
void test_sync_20():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Worker = fn[a](own[a] WSafeGuard[int]*) -> int\n\nint run(own[a] WSafeGuard[int]* g):\n\treturn 0\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\tWorker* entry = run\n\toptown WSafeThread* t = safe_thread_spawn(entry, g)\n\treturn 0\n", c"thread payload is a lock guard bound to its locking thread")

# A guard cannot be lent to fork-join threads.
void test_sync_21():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Peek = fn[](refmut WSafeGuard[int]*) -> int\n\nint peek(refmut WSafeGuard[int]* g):\n\trefmut int* v = safe_guard_value(g)\n\treturn *v\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town WSafeMutex[int]* n = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\town[b] WSafeGuard[int]* h = safe_mutex_lock(n)\n\trefmut WSafeGuard[int]* x = g\n\trefmut WSafeGuard[int]* y = h\n\tPeek* entry = peek\n\treturn safe_thread_fork_join(entry, x, y) - 10\n", c"scoped thread argument is a lock guard bound to its locking thread")

# A guard nested in a payload cannot cross either.
void test_sync_22():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard[int]* guard\n\ntype Worker = fn[a](own[a] Holder*) -> int\n\nint run(own[a] Holder* h):\n\treturn 0\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] Holder* h = new Holder(safe_mutex_lock(m))\n\tWorker* entry = run\n\toptown WSafeThread* t = safe_thread_spawn(entry, h)\n\treturn 0\n", c"thread payload field 'guard' carries a borrowed lifetime")

# A guard nested in a lent record stays on its thread.
void test_sync_23():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard[int]* guard\n\tint tag\n\ntype Peek = fn[](refmut Holder*) -> int\n\nint peek(refmut Holder* h):\n\treturn h.tag\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town WSafeMutex[int]* n = safe_mutex_new(boxed(5))\n\town[a] Holder* g = new Holder(safe_mutex_lock(m), 1)\n\town[b] Holder* h = new Holder(safe_mutex_lock(n), 2)\n\trefmut Holder* x = g\n\trefmut Holder* y = h\n\tPeek* entry = peek\n\treturn safe_thread_fork_join(entry, x, y) - 3\n", c"scoped thread argument field 'guard' is a lock guard bound to its locking thread")

# The payload is unreachable without a guard.
void test_sync_24():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\tref int* inner = m.value\n\treturn *inner\n", c"opaque collection metadata is not accessible")

# The payload cannot be moved out of a mutex.
void test_sync_25():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town int* stolen = m.value\n\treturn *stolen\n", c"opaque collection metadata is not accessible")

# Guards are opaque.
void test_sync_26():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\tref wmutex* word = g.lock\n\treturn 0\n", c"opaque collection metadata is not accessible")

# Atomics are opaque.
void test_sync_27():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\treturn a.value\n", c"opaque collection metadata is not accessible")

# Mutexes have no checked allocation outside the audited constructor: the
# untyped storage record behind every WSafeMutex[T] has no checked shape.
void test_sync_28():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town __w_safe_mutex_storage* m = new __w_safe_mutex_storage\n\treturn 0\n", c"unsupported type or reference-bearing aggregate")

# Atomics cannot be fabricated as plain values.
void test_sync_29():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* real = safe_atomic_new(0)\n\tWSafeAtomic local = WSafeAtomic(1)\n\treturn 0\n", c"opaque collections require an audited constructor")

# A load cannot release.
void test_sync_30():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\treturn safe_atomic_load(a, memory_order_release)\n", c"atomic load cannot use release or acq_rel ordering")

# A load cannot be acq_rel.
void test_sync_31():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\treturn safe_atomic_load(a, memory_order_acq_rel)\n", c"atomic load cannot use release or acq_rel ordering")

# A store cannot acquire.
void test_sync_32():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\tsafe_atomic_store(a, 1, memory_order_acquire)\n\treturn 0\n", c"atomic store cannot use acquire or acq_rel ordering")

# A failed compare-exchange performs no store to release.
void test_sync_33():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\treturn safe_atomic_compare_exchange(a, 5, 6, memory_order_seq_cst, memory_order_release)\n", c"compare-exchange failure ordering cannot be release or acq_rel")

# Orders must be named constants, not runtime values.
void test_sync_34():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\tWMemoryOrder order = memory_order_acquire\n\treturn safe_atomic_load(a, order)\n", c"atomic memory order must be a memory_order_* constant")

# Orders cannot be forged from integers.
void test_sync_35():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\tsafe_atomic_store(a, 1, cast(WMemoryOrder, 2))\n\treturn safe_atomic_fetch_add(a, 1, cast(WMemoryOrder, 9))\n", c"atomic memory order must be a memory_order_* constant")

# Raw lock helpers are not exposed.
void test_sync_36():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\t__w_safe_atomic_order_trap()\n\treturn 0\n", c"runtime call has no audited ownership contract")

# A record payload: the view mutates fields and an owned child, which the
# mutex destroys once.
void test_sync_37():
	sync_case(c"import lib.safe_thread\n\nstruct Account:\n\tint balance\n\town int* history\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex[Account]* m = safe_mutex_new(new Account(5, boxed(1)))\n\tref WSafeMutex[Account]* shared = m\n\tif (1):\n\t\town[a] WSafeGuard[Account]* g = safe_mutex_lock(shared)\n\t\trefmut Account* v = safe_guard_value(g)\n\t\tv.balance = v.balance + 1\n\t\trefmut int* h = v.history\n\t\t*h = 2\n\toptown[b] WSafeGuard[Account]* t = safe_mutex_try_lock(shared)\n\tif (!t): return 1\n\town[c] WSafeGuard[Account]* h = t\n\trefmut Account* w = safe_guard_value(h)\n\tref int* last = w.history\n\treturn w.balance + *last - 8\n", 0)

# A mutex payload may itself be a mutex; each level has its own guard.
void test_sync_38():
	sync_case(c"import lib.safe_thread\n\nint main():\n\town WSafeMutex[int]* inner = safe_mutex_new(new int)\n\town WSafeMutex[WSafeMutex[int]]* outer = safe_mutex_new(inner)\n\tref WSafeMutex[WSafeMutex[int]]* r = outer\n\town[a] WSafeGuard[WSafeMutex[int]]* g = safe_mutex_lock(r)\n\trefmut WSafeMutex[int]* m = safe_guard_value(g)\n\town[b] WSafeGuard[int]* h = safe_mutex_lock(m)\n\trefmut int* v = safe_guard_value(h)\n\t*v = 3\n\treturn *v - 3\n", 0)

# Explicit type arguments select the same audited operations.
void test_sync_39():
	sync_case(c"import lib.safe_thread\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new[int](new int)\n\tref WSafeMutex[int]* r = m\n\town[a] WSafeGuard[int]* g = safe_mutex_lock[int](r)\n\trefmut int* v = safe_guard_value[int](g)\n\t*v = 4\n\tsafe_guard_unlock[int](g)\n\treturn 0\n", 0)

# A payload whose own lock-free marker forbids sharing is still shareable behind the lock.
void test_sync_40():
	sync_case(c"import lib.safe_thread\n\nstruct Solo:\n\tint value\n\tWThreadUnshared marker\n\ntype Bump = fn[](ref WSafeMutex[Solo]*) -> int\n\nint bump(ref WSafeMutex[Solo]* m):\n\tfor i in range(500):\n\t\town[a] WSafeGuard[Solo]* g = safe_mutex_lock(m)\n\t\trefmut Solo* s = safe_guard_value(g)\n\t\ts.value = s.value + 1\n\treturn 0\n\nint main():\n\town WSafeMutex[Solo]* m = safe_mutex_new(new Solo(0, WThreadUnshared(0)))\n\tref WSafeMutex[Solo]* r = m\n\tBump* entry = bump\n\tsafe_thread_fork_join(entry, r, r)\n\town[a] WSafeGuard[Solo]* g = safe_mutex_lock(r)\n\trefmut Solo* s = safe_guard_value(g)\n\treturn s.value - 1000\n", 0)

# A payload with a borrowed lifetime cannot be erased into a mutex.
void test_sync_41():
	sync_case(c"import lib.safe_thread\n\nstruct View:\n\tref[v] int* p\n\nint main():\n\town int* x = new int\n\tref int* r = x\n\town[a] View* view = new View(r)\n\town WSafeMutex[View]* m = safe_mutex_new(view)\n\treturn 0\n", c"unsupported type or reference-bearing aggregate")

# A guard cannot become a mutex payload.
void test_sync_42():
	sync_case(c"import lib.safe_thread\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(new int)\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\town WSafeMutex[WSafeGuard[int]]* bad = safe_mutex_new(g)\n\treturn 0\n", c"a lock guard owner must name its mutex lifetime (own[a] WSafeGuard[T]*)")

# A raw pointer payload has no checked owner shape.
void test_sync_43():
	sync_case(c"import lib.safe_thread\n\nstruct Raw:\n\tint* p\n\nint main():\n\town Raw* raw = new Raw(0)\n\town WSafeMutex[Raw]* m = safe_mutex_new(raw)\n\treturn 0\n", c"unsupported type or reference-bearing aggregate")

# A thread-affine payload makes its mutex unshareable.
void test_sync_44():
	sync_case(c"import lib.safe_thread\n\nstruct Pinned:\n\tint value\n\tWThreadAffine marker\n\ntype Peek = fn[](ref WSafeMutex[Pinned]*) -> int\n\nint peek(ref WSafeMutex[Pinned]* m):\n\treturn 0\n\nint main():\n\town WSafeMutex[Pinned]* m = safe_mutex_new(new Pinned(1, WThreadAffine(0)))\n\tref WSafeMutex[Pinned]* r = m\n\tPeek* entry = peek\n\treturn safe_thread_fork_join(entry, r, r)\n", c"scoped thread argument field 'marker' is explicitly thread-affine")

# A thread-affine payload makes its mutex non-transferable.
void test_sync_45():
	sync_case(c"import lib.safe_thread\n\nstruct Pinned:\n\tint value\n\tWThreadAffine marker\n\ntype Worker = fn[](own WSafeMutex[Pinned]*) -> int\n\nint run(own WSafeMutex[Pinned]* m):\n\treturn 0\n\nint main():\n\tWorker* entry = run\n\toptown WSafeThread* t = safe_thread_spawn(entry, safe_mutex_new(new Pinned(1, WThreadAffine(0))))\n\treturn 0\n", c"thread payload field 'marker' is explicitly thread-affine")

# The view has the payload type of its own mutex.
void test_sync_46():
	sync_case(c"import lib.safe_thread\n\nstruct Account:\n\tint balance\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(new int)\n\town[a] WSafeGuard[int]* g = safe_mutex_lock(m)\n\trefmut Account* v = safe_guard_value(g)\n\treturn 0\n", c"initialization type mismatch")

# A guard has the payload type of the mutex it locks.
void test_sync_47():
	sync_case(c"import lib.safe_thread\n\nstruct Account:\n\tint balance\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(new int)\n\town[a] WSafeGuard[Account]* g = safe_mutex_lock(m)\n\treturn 0\n", c"initialization type mismatch")

# A record payload is unreachable without a guard.
void test_sync_48():
	sync_case(c"import lib.safe_thread\n\nstruct Account:\n\tint balance\n\town int* history\n\nint main():\n\town WSafeMutex[Account]* m = safe_mutex_new(new Account(1, new int))\n\tref Account* inner = m.value\n\treturn 0\n", c"opaque collection metadata is not accessible")

# Mutexes cannot be declared as plain values.
void test_sync_49():
	sync_case(c"import lib.safe_thread\n\nint main():\n\tWSafeMutex[int] local\n\treturn 0\n", c"unsupported type or reference-bearing aggregate")

# A guard declared before its mutex would unlock it after a return frees it.
void test_sync_50():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nint guard_first():\n\toptown[a] WSafeGuard[int]* g = 0\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\tg = safe_mutex_lock(m)\n\treturn 0\n\nint main():\n\treturn guard_first()\n", c"lock guard outlives the mutex it borrows")

# The same holds at the end of the block that declares both.
void test_sync_51():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nint main():\n\tif (1):\n\t\toptown[a] WSafeGuard[int]* g = 0\n\t\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\t\tg = safe_mutex_lock(m)\n\treturn 0\n", c"lock guard outlives the mutex it borrows")

# A try-lock guard declared before its mutex is rejected too.
void test_sync_52():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nint main():\n\toptown[a] WSafeGuard[int]* g = 0\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\tg = safe_mutex_try_lock(m)\n\treturn 0\n", c"lock guard outlives the mutex it borrows")

# So is an owner holding such a guard.
void test_sync_53():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nstruct Holder:\n\town[h] WSafeGuard[int]* guard\n\tint tag\n\nint main():\n\toptown[b] Holder* holder = 0\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\tholder = new Holder(safe_mutex_lock(m), 1)\n\treturn 0\n", c"lock guard outlives the mutex it borrows")

# And a loop body left by break.
void test_sync_54():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nint main():\n\tfor i in range(3):\n\t\toptown[a] WSafeGuard[int]* g = 0\n\t\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\t\tg = safe_mutex_lock(m)\n\t\tif (i == 1): break\n\treturn 0\n", c"lock guard outlives the mutex it borrows")

# A guard declared first is fine once it is released before the mutex drops.
void test_sync_55():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nint main():\n\toptown[a] WSafeGuard[int]* g = 0\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\tg = safe_mutex_lock(m)\n\tg = 0\n\treturn 0\n", 0)

# A guard declared after its mutex drops first.
void test_sync_56():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\toptown[a] WSafeGuard[int]* g = 0\n\tg = safe_mutex_lock(m)\n\treturn 0\n", 0)

# A guard of a borrowed parameter drops before the parameter.
void test_sync_57():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int value):\n\town int* item = new int\n\t*item = value\n\treturn item\n\nint run(ref WSafeMutex[int]* m):\n\toptown[a] WSafeGuard[int]* g = 0\n\tg = safe_mutex_lock(m)\n\treturn 0\n\nint main():\n\town WSafeMutex[int]* m = safe_mutex_new(boxed(5))\n\treturn run(m)\n", 0)
