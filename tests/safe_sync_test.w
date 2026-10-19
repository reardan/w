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
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\tref WSafeMutex* shared = m\n\town[a] WSafeGuard* g = safe_mutex_lock(shared)\n\trefmut int* v = safe_guard_value(g)\n\t*v = *v + 1\n\tsafe_guard_unlock(g)\n\town[b] WSafeGuard* h = safe_mutex_lock(shared)\n\trefmut int* w = safe_guard_value(h)\n\treturn *w - 6\n", 0)

# Guards may live in owners and cross calls under the mutex's lifetime.
void test_sync_1():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard* guard\n\tint tag\n\nown[a] Holder* hold(ref[a] WSafeMutex* m):\n\treturn new Holder(safe_mutex_lock(m), 3)\n\nown[a] WSafeGuard* relock(ref[a] WSafeMutex* m):\n\treturn safe_mutex_lock(m)\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\tif (1):\n\t\town[a] Holder* h = hold(m)\n\t\tif (h.tag != 3): return 1\n\town[b] WSafeGuard* g = relock(m)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v - 5\n", 0)

# A mutex is shareable: fork-join threads contend through guards.
void test_sync_2():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Bump = fn[](ref WSafeMutex*) -> int\n\nint bump(ref WSafeMutex* m):\n\tfor i in range(1000):\n\t\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\t\trefmut int* v = safe_guard_value(g)\n\t\t*v = *v + 1\n\treturn 0\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(0))\n\tref WSafeMutex* shared = m\n\tBump* entry = bump\n\tsafe_thread_fork_join(entry, shared, shared)\n\town[a] WSafeGuard* g = safe_mutex_lock(shared)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v - 2000\n", 0)

# A mutex and an atomic are transferable inside a spawned payload.
void test_sync_3():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Job:\n\town WSafeMutex* mutex\n\town WSafeAtomic* count\n\ntype Worker = fn[](own Job*) -> int\n\nint run(own Job* job):\n\tref WSafeMutex* m = job.mutex\n\tref WSafeAtomic* c = job.count\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v + safe_atomic_fetch_add(c, 1, memory_order_relaxed)\n\nint main():\n\tWorker* entry = run\n\toptown WSafeThread* t = safe_thread_spawn(entry, new Job(safe_mutex_new(boxed(40)), safe_atomic_new(2)))\n\tif (!t): return 1\n\town WSafeThread* started = t\n\treturn safe_thread_join(started) - 42\n", 0)

# Every admitted memory order compiles for each atomic operation.
void test_sync_4():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\tref WSafeAtomic* r = a\n\tsafe_atomic_store(r, 7, memory_order_release)\n\tsafe_atomic_store(r, 7, memory_order_relaxed)\n\tint x = safe_atomic_load(r, memory_order_acquire)\n\tx = x + safe_atomic_load(r, memory_order_seq_cst) - 7\n\tint y = safe_atomic_fetch_add(r, 3, memory_order_relaxed)\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_acquire) - 10\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_release) - 10\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_acq_rel) - 10\n\ty = y + safe_atomic_fetch_add(r, 0, memory_order_seq_cst) - 10\n\tint z = safe_atomic_compare_exchange(r, 10, 1, memory_order_seq_cst, memory_order_acquire)\n\tz = z + safe_atomic_compare_exchange(r, 9, 2, memory_order_release, memory_order_relaxed) - 1\n\tz = z + safe_atomic_compare_exchange(r, 1, 3, memory_order_acq_rel, memory_order_seq_cst) - 1\n\tsafe_atomic_store(r, 2, memory_order_seq_cst)\n\treturn x + y + z - 24 + safe_atomic_load(r, memory_order_relaxed) - 2\n", 0)

# An atomic is shareable across fork-join threads.
void test_sync_5():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Bump = fn[](ref WSafeAtomic*) -> int\n\nint bump(ref WSafeAtomic* a):\n\tfor i in range(10000): safe_atomic_fetch_add(a, 1, memory_order_relaxed)\n\treturn 0\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(0)\n\tref WSafeAtomic* r = a\n\tBump* entry = bump\n\tsafe_thread_fork_join(entry, r, r)\n\treturn safe_atomic_load(r, memory_order_seq_cst) - 20000\n", 0)

# A view cannot outlive an explicit unlock.
void test_sync_6():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\trefmut int* v = safe_guard_value(g)\n\tsafe_guard_unlock(g)\n\treturn *v\n", c"use of uninitialized or moved value")

# A view cannot outlive its guard's scope.
void test_sync_7():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\toptrefmut int* v = 0\n\tif (1):\n\t\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\t\tv = safe_guard_value(g)\n\tif (v): return *v\n\treturn 0\n", c"use of uninitialized or moved value")

# A guard cannot be used after it is released.
void test_sync_8():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\tsafe_guard_unlock(g)\n\trefmut int* v = safe_guard_value(g)\n\treturn *v\n", c"use of uninitialized or moved value")

# Two live views of one guard conflict.
void test_sync_9():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\trefmut int* v = safe_guard_value(g)\n\trefmut int* w = safe_guard_value(g)\n\t*w = 1\n\treturn *v\n", c"conflicting access while a borrow is live")

# A shared guard reference cannot open the exclusive view.
void test_sync_10():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint peek(ref WSafeGuard* g):\n\trefmut int* v = safe_guard_value(g)\n\treturn *v\n\nint main():\n\treturn 0\n", c"cannot make a mutable borrow from a shared reference")

# A view cannot escape the function holding its guard.
void test_sync_11():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nrefmut int* grab(ref WSafeMutex* m):\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\treturn safe_guard_value(g)\n\nint main():\n\treturn 0\n", c"mutable reference return requires a mutable borrowed parameter")

# A guard of a local mutex cannot be returned.
void test_sync_12():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nown[a] WSafeGuard* leak():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\treturn safe_mutex_lock(m)\n\nint main():\n\treturn 0\n", c"returned lifetime must name a borrowed parameter")

# A guard cannot escape inside a returned owner either.
void test_sync_13():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard* guard\n\nown[a] Holder* hold(ref[a] WSafeMutex* m):\n\treturn new Holder(safe_mutex_lock(m))\n\nown[a] Holder* bad():\n\town WSafeMutex* m = safe_mutex_new(boxed(1))\n\treturn hold(m)\n\nint main():\n\treturn 0\n", c"returned lifetime must name a borrowed parameter")

# Moving a locked mutex conflicts with the guard's pending drop.
void test_sync_14():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\town WSafeMutex* moved = m\n\treturn 0\n", c"conflicting access while a borrow is live")

# Consuming a locked mutex conflicts with the guard's pending drop.
void test_sync_15():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nvoid eat(own WSafeMutex* m):\n\treturn\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\teat(m)\n\treturn 0\n", c"conflicting access while a borrow is live")

# Replacing a locked mutex conflicts with the guard's pending drop.
void test_sync_16():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\tm = safe_mutex_new(boxed(6))\n\treturn 0\n", c"conflicting access while a borrow is live")

# A guard released on only one path still pins its mutex.
void test_sync_17():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint run(int early):\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\tif (early): safe_guard_unlock(g)\n\town WSafeMutex* moved = m\n\treturn 0\n\nint main():\n\treturn run(1)\n", c"conflicting access while a borrow is live")

# A guard cannot outlive a mutex declared in an inner block.
void test_sync_18():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\toptown[a] WSafeGuard* outer = 0\n\tif (1):\n\t\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\t\touter = safe_mutex_lock(m)\n\treturn 0\n", c"lock guard outlives the mutex it borrows")

# A guard owner must carry its mutex lifetime.
void test_sync_19():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town WSafeGuard* g = safe_mutex_lock(m)\n\treturn 0\n", c"a lock guard owner must name its mutex lifetime (own[a] WSafeGuard*)")

# A guard cannot move to a spawned thread.
void test_sync_20():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Worker = fn[a](own[a] WSafeGuard*) -> int\n\nint run(own[a] WSafeGuard* g):\n\treturn 0\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\tWorker* entry = run\n\toptown WSafeThread* t = safe_thread_spawn(entry, g)\n\treturn 0\n", c"thread payload is a lock guard bound to its locking thread")

# A guard cannot be lent to fork-join threads.
void test_sync_21():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\ntype Peek = fn[](refmut WSafeGuard*) -> int\n\nint peek(refmut WSafeGuard* g):\n\trefmut int* v = safe_guard_value(g)\n\treturn *v\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town WSafeMutex* n = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\town[b] WSafeGuard* h = safe_mutex_lock(n)\n\trefmut WSafeGuard* x = g\n\trefmut WSafeGuard* y = h\n\tPeek* entry = peek\n\treturn safe_thread_fork_join(entry, x, y) - 10\n", c"scoped thread argument is a lock guard bound to its locking thread")

# A guard nested in a payload cannot cross either.
void test_sync_22():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard* guard\n\ntype Worker = fn[a](own[a] Holder*) -> int\n\nint run(own[a] Holder* h):\n\treturn 0\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] Holder* h = new Holder(safe_mutex_lock(m))\n\tWorker* entry = run\n\toptown WSafeThread* t = safe_thread_spawn(entry, h)\n\treturn 0\n", c"thread payload field 'guard' carries a borrowed lifetime")

# A guard nested in a lent record stays on its thread.
void test_sync_23():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nstruct Holder:\n\town[h] WSafeGuard* guard\n\tint tag\n\ntype Peek = fn[](refmut Holder*) -> int\n\nint peek(refmut Holder* h):\n\treturn h.tag\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town WSafeMutex* n = safe_mutex_new(boxed(5))\n\town[a] Holder* g = new Holder(safe_mutex_lock(m), 1)\n\town[b] Holder* h = new Holder(safe_mutex_lock(n), 2)\n\trefmut Holder* x = g\n\trefmut Holder* y = h\n\tPeek* entry = peek\n\treturn safe_thread_fork_join(entry, x, y) - 3\n", c"scoped thread argument field 'guard' is a lock guard bound to its locking thread")

# The payload is unreachable without a guard.
void test_sync_24():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\tref int* inner = m.value\n\treturn *inner\n", c"opaque collection metadata is not accessible")

# The payload cannot be moved out of a mutex.
void test_sync_25():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town int* stolen = m.value\n\treturn *stolen\n", c"opaque collection metadata is not accessible")

# Guards are opaque.
void test_sync_26():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\town[a] WSafeGuard* g = safe_mutex_lock(m)\n\tref wmutex* word = g.lock\n\treturn 0\n", c"opaque collection metadata is not accessible")

# Atomics are opaque.
void test_sync_27():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeAtomic* a = safe_atomic_new(5)\n\treturn a.value\n", c"opaque collection metadata is not accessible")

# Mutexes have no checked allocation outside the audited constructor.
void test_sync_28():
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = new WSafeMutex\n\treturn 0\n", c"opaque collections require an audited constructor")

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
	sync_case(c"import lib.safe_thread\n\nown int* boxed(int v):\n\town int* p = new int\n\t*p = v\n\treturn p\n\nint main():\n\town WSafeMutex* m = safe_mutex_new(boxed(5))\n\t__w_safe_atomic_order_trap()\n\treturn 0\n", c"runtime call has no audited ownership contract")
