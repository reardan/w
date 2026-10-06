# wbuild: x64
/*
Worker stack guard pages (lib/thread.w, issue #526).

test_guard_page_mapped: while a worker is alive, /proc/self/maps shows
a PROT_NONE ("---p") page at thread_stack_guard(stack_base), so the
thread_local block and the signal stack below it are fenced off from
the stack proper.

test_overflow_faults_on_guard: a worker that recurses without bound
runs into that guard page. A forked child does it with its stderr on a
pipe; the parent asserts the child died of SIGSEGV after the crash
handler (installed by lib/testing.w, running on the worker's own
signal stack) reported a stack overflow whose faulting address lies in
the guard page -- the recursion stopped there instead of silently
overwriting the thread_local block and whatever is mapped below it.
*/
import lib.testing
import lib.thread
import lib.str


int guard_go


void guard_waiter(void* arg):
	thread_wait_word(&guard_go)


int guard_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return c - '0'
	if ((c >= 'a') && (c <= 'f')): return c - 'a' + 10
	return 0 - 1


# Parse the hex number at s[*pos], advancing *pos past it.
int guard_parse_hex(char* s, int* pos):
	int v = 0
	int d = guard_hex_digit(s[*pos])
	while (d >= 0):
		v = (v << 4) + d
		*pos = *pos + 1
		d = guard_hex_digit(s[*pos])
	return v


# Read a whole file (or pipe) into a NUL-terminated buffer.
char* guard_read_all(int fd):
	int cap = 65536
	char* buf = malloc(cap + 1)
	int total = 0
	int n = read(fd, &buf[total], cap - total)
	while (n > 0):
		total = total + n
		if (total == cap):
			buf = realloc(buf, cap + 1, cap * 2 + 1)
			cap = cap * 2
		n = read(fd, &buf[total], cap - total)
	buf[total] = 0
	return buf


# The permissions of the /proc/self/maps line that starts at lo and
# ends at hi ("---p", ...), or 0 when there is none.
char* guard_maps_perms(int lo, int hi):
	int fd = open(c"/proc/self/maps", 0, 0)
	asserts(c"/proc/self/maps opened", fd >= 0)
	char* maps = guard_read_all(fd)
	close(fd)
	int pos = 0
	while (maps[pos] != 0):
		int start = guard_parse_hex(maps, &pos)
		pos = pos + 1   /* '-' */
		int end = guard_parse_hex(maps, &pos)
		pos = pos + 1   /* ' ' */
		if ((start == lo) && (end == hi)): return substring(maps, pos, pos + 4)
		while ((maps[pos] != 0) && (maps[pos] != 10)): pos = pos + 1
		if (maps[pos] == 10): pos = pos + 1
	return 0


void test_guard_page_mapped():
	guard_go = 0
	wthread* t = thread_spawn(guard_waiter, cast(void*, 0))
	asserts(c"thread_spawn failed", cast(int, t) != 0)
	int guard = thread_stack_guard(t.stack_base)
	asserts(c"guard page is page-aligned", (guard & 4095) == 0)
	asserts(c"guard page lies inside the stack mapping", (guard > t.stack_base) && (guard < t.stack_base + thread_stack_size))
	char* perms = guard_maps_perms(guard, guard + 4096)
	asserts(c"guard page has its own /proc/self/maps line", perms != 0)
	assert_strings_equal(c"---p", perms)
	guard_go = 1
	thread_wake_word(&guard_go)
	assert_equal(0, thread_join(t))


int guard_depth


int guard_recurse(int n):
	guard_depth = n
	return guard_recurse(n + 1) + 1


void guard_overflow_worker(void* arg):
	thread_wait_word(&guard_go)
	guard_recurse(0)


# Forked child: report the worker's guard page on stderr, then let it
# overflow. Never returns: the process dies of the worker's SIGSEGV.
void guard_overflow_child():
	guard_go = 0
	wthread* t = thread_spawn(guard_overflow_worker, cast(void*, 0))
	if (cast(int, t) == 0): exit(3)
	char* g = hex_word(thread_stack_guard(t.stack_base))
	write(2, c"guard ", 6)
	write(2, g, strlen(g))
	write(2, c"\x0a", 1)
	guard_go = 1
	thread_wake_word(&guard_go)
	thread_join(t)
	exit(4)


# The hex number following needle in text (lowercase digits after
# "0x"), or -1 when needle is absent.
int guard_value_after(char* text, char* needle):
	int at = index_of(text, needle)
	if (at < 0): return 0 - 1
	int pos = at + strlen(needle)
	return guard_parse_hex(text, &pos)


void test_overflow_faults_on_guard():
	int[2] fds
	asserts(c"pipe", pipe(&fds[0]) == 0)
	int rfd = load_int32(cast(char*, &fds[0]))
	int wfd = load_int32(cast(char*, &fds[0]) + 4)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		close(rfd)
		dup2(wfd, 2)
		guard_overflow_child()
	close(wfd)
	char* report = guard_read_all(rfd)
	close(rfd)
	int status = 0
	asserts(c"wait4", wait4(pid, &status, 0, 0) == pid)
	assert_equal(11, status & 127)   /* killed by SIGSEGV */
	assert_contains(report, c"fatal signal: SIGSEGV")
	assert_contains(report, c"likely a stack overflow")
	assert_contains(report, c"at guard_recurse (")
	int guard = guard_value_after(report, c"guard 0x")
	int fault = guard_value_after(report, c"faulting address 0x")
	asserts(c"child reported its guard page", guard != 0 - 1)
	asserts(c"the overflow faulted inside the guard page", (fault >= guard) && (fault < guard + 4096))
