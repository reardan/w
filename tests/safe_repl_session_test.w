# wbuild: x64 timeout=600000 deps=tests/safe_repl_session_fixture.w deps=tests/safe_repl_thread_fixture.w
# Checked ownership across persistent REPL entries (#713): owners and
# borrows persist between entries, failed entries roll back without
# publishing anything, replaced and remaining owners are destroyed exactly
# once (W_DEBUG_ALLOC turns a second destruction into a fault and the
# fixture counts live cells), and unsupported entry forms fail explicitly.
# The 32-bit test drives a 32-bit REPL and the x64 twin a 64-bit one.
import lib.testing
import lib.process
import lib.file
import lib.env
import lib.str


char* safe_repl_binary


char* safe_repl_path(char* stem, char* suffix):
	char* name = strjoin(stem, itoa(__word_size__ * 8))
	char* path = strjoin(name, suffix)
	free(name)
	return path


process_result* safe_repl_exec(char** args, char* input):
	spawn_options* opts = spawn_options_new()
	opts.env = env_copy_with(env_current(), c"W_DEBUG_ALLOC", c"1")
	process_result* result = process_run(args[0], args, opts, input, 300000)
	assert1(result != 0)
	return result


char* safe_repl_build():
	if (safe_repl_binary != 0): return safe_repl_binary
	safe_repl_binary = safe_repl_path(c"bin/safe_repl_session_repl", c"")
	char** args = strv_new(5)
	strv_set(args, 0, c"bin/wv2")
	int at = 1
	if (__word_size__ == 8):
		strv_set(args, 1, c"x64")
		at = 2
	strv_set(args, at, c"repl.w")
	strv_set(args, at + 1, c"-o")
	strv_set(args, at + 2, safe_repl_binary)
	process_result* built = process_run(args[0], args, 0, 0, 600000)
	assert1(built != 0)
	if (built.status != 0): println(built.stderr_text)
	assert_equal(0, built.status)
	process_result_free(built)
	free(cast(void*, args))
	return safe_repl_binary


# Run one session with the fixture loaded.
process_result* safe_repl_run(char* input):
	char** args = strv_new(4)
	strv_set(args, 0, safe_repl_build())
	strv_set(args, 1, c"--no_main")
	strv_set(args, 2, c"tests/safe_repl_session_fixture.w")
	process_result* result = safe_repl_exec(args, input)
	free(cast(void*, args))
	return result


# Each needle occurs in text, in this order.
void safe_repl_expect_order(char* text, list[char*] needles):
	int at = 0
	for i in range(needles.length):
		int found = index_of(text + at, needles[i])
		if (found < 0):
			print(c"missing in order: ")
			println(needles[i])
			println(text)
		assert1(found >= 0)
		at = at + found + strlen(needles[i])


list[char*] safe_repl_lines(char* a, char* b, char* c, char* d):
	list[char*] lines = new list[char*]
	if (a != 0): lines.push(a)
	if (b != 0): lines.push(b)
	if (c != 0): lines.push(c)
	if (d != 0): lines.push(d)
	return lines


void test_owners_persist_and_drop_once():
	process_result* r = safe_repl_run(c"safe_repl_report(c\"start\")\nown cell* a = new cell\na.value = 5\na.value + 37\nsafe_repl_report(c\"one\")\nown cell* a = new cell\nsafe_repl_report(c\"replaced\")\na.value + 40\nown cell* l = new cell\nown cell* m = new cell\nown pair* p = new pair(l, m)\np.left.value = 4\np.left.value + 1\nsafe_repl_report(c\"three\")\n:reset\nsafe_repl_report(c\"reset\")\nown cell* kept = new cell\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"start live=0", c"42", c"one live=1", c"replaced live=1"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"replaced live=1", c"40", c"5", c"three live=3"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"three live=3", c"reset live=0", 0, 0))
	assert_lacks(r.stderr_text, c"error")
	assert_lacks(r.stdout_text, c"memory_debug")
	process_result_free(r)


void test_moves_borrows_and_failed_entries():
	process_result* r = safe_repl_run(c"own cell* q = new cell\nq.value = 9\nref cell* r = q\nint bad = qq_missing + safe_repl_take(q)\nsafe_repl_take(q); safe_repl_peek(r)\nsafe_repl_peek(r) + 100\nsafe_repl_take(q) + 200\nq.value\nsafe_repl_peek(r)\nsafe_repl_report(c\"moved\")\nown cell* q = new cell\nq.value = 1\nq.value + 300\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"109", c"209", c"moved live=0", c"301"))
	safe_repl_expect_order(r.stderr_text, safe_repl_lines(c"Cannot find symbol: 'qq_missing'", c"error: safe:", c"use of uninitialized or moved value", c"use of uninitialized or moved value"))
	assert_contains(r.stderr_text, c"note: checked session transcript line")
	process_result_free(r)


void test_fault_discards_only_changed_bindings():
	process_result* r = safe_repl_run(c"own cell* g = new cell\nown cell* keep = new cell\nkeep.value = 4\nown cell* h = g; 1 / 0\ng.value\nkeep.value + 1\nsafe_repl_report(c\"faulted\")\n:reset\nsafe_repl_report(c\"after\")\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"entry rolled back", c"note: checked session bindings were discarded after the fault", c"5", c"faulted live=2"))
	# keep is destroyed at :reset; g's cell is leaked, never destroyed twice.
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"faulted live=2", c"after live=1", 0, 0))
	assert_contains(r.stderr_text, c"this checked session binding was discarded after a runtime fault")
	process_result_free(r)


void test_unsupported_forms_fail_explicitly():
	process_result* r = safe_repl_run(c"own cell* a = new cell\nint sneaky():\n\treturn a.value\n\nint use(own cell* c):\n\treturn c.value\n\nint use(ref cell* c):\n\treturn c.value\n\n:type own cell* z = new cell\nint flag = 1\nif (flag): safe_repl_take(a)\nown cell* a = new cell; own cell* a = new cell\na.value + 7\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stderr_text, safe_repl_lines(c"cannot use a checked session binding; pass it as an argument", c"redefinition changes a checked function contract", c"an entry that is not run cannot declare checked session bindings", c"must be held or moved on every path of an entry"))
	assert_contains(r.stderr_text, c"a checked session binding cannot be redeclared in the entry that declared it")
	assert_contains(r.stdout_text, c"7")
	process_result_free(r)


# Lifetime-labeled bindings (tests/safe_repl_session_fixture.w): a shared
# borrowed record and its copy, an exclusive one, owners carrying a
# borrowed group (replaced, destroyed at :reset, discarded after a fault).
# Struct-valued initializers copy the record into its persistent storage.
# Lock guards are labeled owners too (test_lock_guards_across_entries).
void test_lifetime_labeled_bindings():
	string_builder* in = string_new()
	string_append(in, c"own cell* a = new cell\na.value = 4\nref[x] holder h = holder(a, 3)\nref holder k = h\nsafe_repl_hold(k) + 50\nsafe_repl_hold(h) + 10\n")
	# Replacing the borrowed owner destroys it; the borrow is dead after.
	string_append(in, c"own cell* a = new cell\nsafe_repl_report(c\"replaced\")\nsafe_repl_hold(h)\na.value = 6\n")
	string_append(in, c"own[y] stored* s = safe_repl_store(a)\nsafe_repl_stored(s) + 20\nown[y] stored* s = safe_repl_store(a)\nsafe_repl_report(c\"restored\")\n")
	# An exclusive record ends the shared loan's validity for later uses.
	string_append(in, c"refmut exclusive e = exclusive(a, 1)\nsafe_repl_bump(e) + 30\nsafe_repl_stored(s)\n")
	string_append(in, c"struct plain_pair:\n\tint u\n\tint v\n\nplain_pair pp = plain_pair(1, 2)\nplain_pair pq = pp\npq.v + 60\n")
	string_append(in, c"own cell* b = new cell\nb.value = 8\nown[q] stored* t = safe_repl_store(b)\nint z = safe_repl_take_stored(t); 1 / 0\nsafe_repl_stored(t)\nsafe_repl_report(c\"faulted\")\n:reset\nsafe_repl_report(c\"reset\")\n")
	string_append(in, c"own cell* c = new cell\nown[r] stored* u = safe_repl_store(c)\nsafe_repl_report(c\"last\")\n:quit\n")
	process_result* r = safe_repl_run(in.data)
	string_free(in)
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"57", c"17", c"replaced live=1", c"26"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"26", c"restored live=2", c"37", c"62"))
	# t's scratch was freed by the call that faulted afterwards; :reset
	# destroys a, s and b, never t a second time.
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"62", c"note: checked session bindings were discarded after the fault", c"faulted live=3", c"reset live=0"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"reset live=0", c"last live=2", 0, 0))
	safe_repl_expect_order(r.stderr_text, safe_repl_lines(c"use of uninitialized or moved value", c"conflicting access while a borrow is live", c"this checked session binding was discarded after a runtime fault", 0))
	assert_lacks(r.stdout_text, c"memory_debug")
	process_result_free(r)


void test_imported_source_edit_and_reset():
	char* module = safe_repl_path(c"bin/safe_repl_session_mod", c".w")
	char* second = safe_repl_path(c"bin/safe_repl_session_mod_next", c".w")
	file_write_text(module, c"int safe_repl_mod(ref cell* c):\n\treturn c.value + 1\n")
	file_write_text(second, c"int safe_repl_mod(own cell* c):\n\treturn c.value + 2\n")
	char* import_line = safe_repl_path(c"import bin.safe_repl_session_mod", c"\n")
	string_builder* input = string_new()
	string_append(input, import_line)
	string_append(input, c"own cell* a = new cell\na.value = 3\nsafe_repl_mod(a) + 10\nsafe_repl_mod(a) + 20\n!cp ")
	string_append(input, second)
	string_append_char(input, ' ')
	string_append(input, module)
	string_append(input, c"\n:reset\nsafe_repl_report(c\"reset\")\n")
	string_append(input, import_line)
	string_append(input, c"own cell* b = new cell\nb.value = 5\nsafe_repl_mod(b) + 30\nb.value\nsafe_repl_report(c\"end\")\n:quit\n")
	process_result* r = safe_repl_run(input.data)
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"14", c"24", c"reset live=0", c"37"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"37", c"end live=0", 0, 0))
	assert_contains(r.stderr_text, c"use of uninitialized or moved value")
	process_result_free(r)
	string_free(input)
	unlink(module)
	unlink(second)


void test_safe_flag_still_rejected():
	char** args = strv_new(3)
	strv_set(args, 0, safe_repl_build())
	strv_set(args, 1, c"--safe")
	process_result* r = safe_repl_exec(args, c":quit\n")
	assert1(r.status != 0)
	assert_contains(r.stderr_text, c"--safe is not supported by in-process REPL or debugger sessions")
	process_result_free(r)
	free(cast(void*, args))


# Threads and lock guards (#713) run under W_DEBUG_ALLOC too: the REPL
# keeps its own compiler on the free list (malloc_host_freelist_mode), so
# only the session's blocks take guard pages and a second unlock or
# destruction faults. fixture is 0 for a bare session.
process_result* safe_repl_thread_run(char* fixture, char* input):
	char** args = strv_new(4)
	strv_set(args, 0, safe_repl_build())
	int count = 1
	if (fixture != 0):
		strv_set(args, 1, c"--no_main")
		strv_set(args, 2, fixture)
		count = 3
	strv_set(args, count, 0)
	process_result* result = safe_repl_exec(args, input)
	assert_lacks(result.stdout_text, c"memory_debug")
	assert_lacks(result.stderr_text, c"memory_debug")
	free(cast(void*, args))
	return result


int safe_repl_occurrences(char* text, char* needle):
	int count = 0
	int at = 0
	while (1):
		int found = index_of(text + at, needle)
		if (found < 0): return count
		count = count + 1
		at = at + found + strlen(needle)
	return count


# Guards declared at the prompt are labeled owners of their mutex's loan:
# they persist across entries, a failed redeclaration changes nothing, a
# replacement unlocks the old guard exactly once before its initializer
# runs (so relocking the same mutex cannot deadlock, and a second unlock
# at commit would have released h), the mutex cannot be replaced while a
# guard borrows it, a fault discards the replaced guard without unlocking
# it again (the new guard's lock is leaked: n stays locked), and :reset
# and exit release every held guard once.
void test_lock_guards_across_entries():
	string_builder* in = string_new()
	string_append(in, c"own WSafeMutex[int]* m = safe_mutex_new(safe_repl_boxed(5))\nsafe_repl_unlocked(m) + 10\nown[a] WSafeGuard[int]* g = safe_mutex_lock(m)\nsafe_repl_unlocked(m) + 20\nsafe_repl_bump(g) + 30\nsafe_repl_bump(g) + 40\n")
	string_append(in, c"own[a] WSafeGuard[int]* g = safe_mutex_lock(qq_missing)\nsafe_repl_bump(g) + 50\nown[a] WSafeGuard[int]* g = safe_mutex_lock(m)\nsafe_repl_bump(g) + 60\n")
	string_append(in, c"own WSafeMutex[int]* n = safe_mutex_new(safe_repl_boxed(1))\nown[a] WSafeGuard[int]* g = safe_mutex_lock(n); own[b] WSafeGuard[int]* h = safe_mutex_lock(m)\nsafe_repl_unlocked(m) + 70\nsafe_repl_unlocked(n) + 80\n")
	string_append(in, c"own WSafeMutex[int]* n = safe_mutex_new(safe_repl_boxed(2))\nsafe_guard_unlock(g)\nsafe_repl_unlocked(n) + 90\nown WSafeMutex[int]* n = safe_mutex_new(safe_repl_boxed(2))\nsafe_guard_unlock(h)\n")
	string_append(in, c"own[a] WSafeGuard[int]* g = safe_mutex_lock(m)\nint z = 0\nown[a] WSafeGuard[int]* g = safe_mutex_lock(n); 1 / z\nsafe_repl_unlocked(m) + 100\nsafe_repl_unlocked(n) + 110\nsafe_repl_bump(g)\n")
	# Checked thread handles: joined by the call, by replacement and at :reset.
	string_append(in, c"optown WSafeThread* job = safe_repl_start(4)\nsafe_repl_finish(job) + 120\noptown WSafeThread* job = safe_repl_start(5)\noptown WSafeThread* job = safe_repl_start(6)\n")
	string_append(in, c"own[c] WSafeGuard[int]* hold = safe_mutex_lock(m)\n:reset\nown WSafeMutex[int]* w = safe_mutex_new(safe_repl_boxed(0))\nown[c] WSafeGuard[int]* hold = safe_mutex_lock(w)\nsafe_repl_unlocked(w) + 130\n:quit\n")
	process_result* r = safe_repl_thread_run(c"tests/safe_repl_thread_fixture.w", in.data)
	string_free(in)
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"11\n", c"20\n", c"36\n", c"47\n"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"47\n", c"58\n", c"69\n", c"70\n"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"70\n", c"80\n", c"91\n", c"entry rolled back"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"entry rolled back", c"101\n", c"110\n", c"128\n"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"128\n", c"note: released 1 held lock guard(s) of the session", c"session reset to its startup state", c"130\n"))
	assert_equal(2, safe_repl_occurrences(r.stdout_text, c"held lock guard(s) of the session"))
	safe_repl_expect_order(r.stderr_text, safe_repl_lines(c"Cannot find symbol: 'qq_missing'", c"conflicting access while a borrow is live", c"this checked session binding was discarded after a runtime fault", 0))
	assert_lacks(r.stderr_text, c"session bindings cannot hold lock guards")
	process_result_free(r)


# thread_local at the prompt: every lib/thread.w thread gets its own
# zeroed copy, the main thread's persists across entries, a declaration
# after :reset starts zeroed again, and while the parallel_for pool is
# alive a redefinition leaves earlier call sites alone (with a note).
void test_threads_and_thread_local():
	string_builder* in = string_new()
	string_append(in, c"import lib.thread\nthread_local int tl\ntl = 3\nvoid tl_worker(void* p):\n\ttl = tl + 40\n\tint* out = cast(int*, p)\n\t*out = tl\n\nint seen = 0\nwthread* w = thread_spawn(tl_worker, &seen); thread_join(w)\nseen + 1000\ntl + 2000\n")
	string_append(in, c"void chunk(int s, int e, void* a):\n\ttl = tl + 1\n\nparallel_for(0, 8, 4, chunk, 0)\ntl + 3000\nthread_local int later\nlater + 4000\n")
	string_append(in, c"int f():\n\treturn 1\n\nf() + 5000\nint f():\n\treturn 2\n\nf() + 6000\nthread_pool_shutdown()\nint f():\n\treturn 3\n\nf() + 6100\n")
	string_append(in, c"tl = 9\n:reset\nthread_local int fresh\nfresh + 7000\n:quit\n")
	process_result* r = safe_repl_thread_run(0, in.data)
	string_free(in)
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"1040\n", c"2003\n", c"3004\n", c"4000\n"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"4000\n", c"5001\n", c"note: threads started by entries are still running, so earlier call sites keep the previous definition", c"6002\n"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"6002\n", c"6103\n", c"session reset to its startup state", c"7000\n"))
	assert_equal(1, safe_repl_occurrences(r.stdout_text, c"earlier call sites keep"))
	assert_lacks(r.stdout_text, c"still running; the code")
	assert_lacks(r.stderr_text, c"error")
	process_result_free(r)


# The per-thread block is fixed (64KB): a declaration that would not fit is
# rejected and the session continues.
void test_thread_local_capacity():
	string_builder* in = string_new()
	string_append(in, c"struct tl16:\n\tint a\n\tint b\n\tint c\n\tint d\n\tint e\n\tint f\n\tint g\n\tint h\n\tint i\n\tint j\n\tint k\n\tint l\n\tint m\n\tint n\n\tint o\n\tint p\n\n")
	string_append(in, c"struct tl256:\n\ttl16 a\n\ttl16 b\n\ttl16 c\n\ttl16 d\n\ttl16 e\n\ttl16 f\n\ttl16 g\n\ttl16 h\n\ttl16 i\n\ttl16 j\n\ttl16 k\n\ttl16 l\n\ttl16 m\n\ttl16 n\n\ttl16 o\n\ttl16 p\n\n")
	string_append(in, c"struct tl4k:\n\ttl256 a\n\ttl256 b\n\ttl256 c\n\ttl256 d\n\ttl256 e\n\ttl256 f\n\ttl256 g\n\ttl256 h\n\ttl256 i\n\ttl256 j\n\ttl256 k\n\ttl256 l\n\ttl256 m\n\ttl256 n\n\ttl256 o\n\ttl256 p\n\n")
	string_append(in, c"struct tl16k:\n\ttl4k a\n\ttl4k b\n\ttl4k c\n\ttl4k d\n\nthread_local tl16k big\nthread_local int small\nsmall + 8000\n:quit\n")
	process_result* r = safe_repl_thread_run(0, in.data)
	string_free(in)
	assert_equal(0, r.status)
	assert_contains(r.stderr_text, c"thread_local storage exceeds the in-process session's 64KB per-thread block; start a new session")
	assert_contains(r.stdout_text, c"8000\n")
	process_result_free(r)


# Threads that outlive their entry: :reset keeps the code and storage they
# may use (and says so), loading the thread runtime afresh under them is
# rejected, an older thread does not stop a fault from rolling back, and
# a fault while a thread the entry started still runs ends the session.
void test_threads_outliving_entries():
	char* wait_def = c"import lib.thread\nint spin = 1\nvoid wait(void* p):\n\twhile (atomic_load(&spin)): sys_futex(cast(int, &spin), 128, 1, 0)\n\n"
	string_builder* in = string_new()
	string_append(in, wait_def)
	string_append(in, c"wthread* t = thread_spawn(wait, 0)\nint z = 0\nint g():\n\treturn 7\n\ng() + 1 / z\ng() + 100\n:reset\nimport lib.thread\nprintln(c\"after reset\")\n:quit\n")
	process_result* r = safe_repl_thread_run(0, in.data)
	string_free(in)
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"entry rolled back", c"107\n", c"note: 1 thread(s) started by entries are still running; the code and thread_local storage they may use stay reserved", c"after reset"))
	assert_contains(r.stderr_text, c"lib/thread.w cannot be loaded again while threads started before a rollback or :reset still run on its previous copy")
	process_result_free(r)
	string_builder* second = string_new()
	string_append(second, wait_def)
	string_append(second, c"wthread* t = thread_spawn(wait, 0); int z = 0; 1 / z\nprintln(c\"unreachable\")\n:quit\n")
	r = safe_repl_thread_run(0, second.data)
	string_free(second)
	assert1(r.status != 0)
	assert_contains(r.stdout_text, c"a thread this entry started is still running and may use the entry's stack; the session cannot recover; exiting")
	assert_lacks(r.stdout_text, c"unreachable")
	process_result_free(r)


# A fault or a debugger stop on a thread an entry started has no
# checkpoint or command loop to return to.
void test_fault_on_entry_thread_ends_session():
	process_result* r = safe_repl_thread_run(0, c"import lib.thread\nvoid boom(void* p):\n\tint z = 0\n\tprintln(itoa(1 / z))\n\nwthread* t = thread_spawn(boom, 0); thread_join(t)\nprintln(c\"unreachable\")\n:quit\n")
	assert1(r.status != 0)
	assert_contains(r.stdout_text, c"runtime fault in a thread started by an entry: SIGFPE")
	assert_contains(r.stdout_text, c"the session cannot recover from a fault on another thread; exiting")
	assert_lacks(r.stdout_text, c"unreachable")
	process_result_free(r)
	r = safe_repl_thread_run(0, c"import lib.thread\nvoid stop(void* p):\n\tdebugger\n\nwthread* t = thread_spawn(stop, 0); thread_join(t)\nprintln(c\"unreachable\")\n:quit\n")
	assert1(r.status != 0)
	assert_contains(r.stdout_text, c"debugger: stop in a thread started by an entry; only the main thread can stop in the REPL; exiting")
	assert_lacks(r.stdout_text, c"unreachable")
	process_result_free(r)


# wdbg compiles its debuggee in process without the REPL's per-thread
# block, so thread_local (here lib/thread_heap.w's) stays rejected there.
void test_debugger_keeps_thread_local_rejected():
	char* binary = safe_repl_path(c"bin/safe_repl_session_wdbg", c"")
	char** args = strv_new(5)
	strv_set(args, 0, c"bin/wv2")
	int at = 1
	if (__word_size__ == 8):
		strv_set(args, 1, c"x64")
		at = 2
	strv_set(args, at, c"debugger/debugger.w")
	strv_set(args, at + 1, c"-o")
	strv_set(args, at + 2, binary)
	process_result* built = process_run(args[0], args, 0, 0, 600000)
	assert1(built != 0)
	assert_equal(0, built.status)
	process_result_free(built)
	free(cast(void*, args))
	char** run = strv_new(3)
	strv_set(run, 0, binary)
	strv_set(run, 1, c"tests/safe_repl_thread_fixture.w")
	process_result* r = process_run(run[0], run, 0, c"c\n", 300000)
	assert1(r != 0)
	assert1(r.status != 0)
	assert_contains(r.stderr_text, c"thread_local is not supported in the debugger or other in-process compiles; the REPL provides it")
	process_result_free(r)
	free(cast(void*, run))
