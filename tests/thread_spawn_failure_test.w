# wbuild: x64
# wbuild: step="bin/thread_spawn_failure_test" env="W_DEBUG_ALLOC=1"
/*
Spawn failure is an ordinary return, never a crash or a leak
(lib/thread.w thread_spawn, the thread_create builtin in
code_generator/{x86,x64}_asm.w, lib/safe_thread.w "Failure").

- Stack mmap failure: RLIMIT_AS is lowered to just above the current
  address-space size, so the builtin's 4MB stack mmap fails with
  -ENOMEM. The builtin must return that error instead of writing the
  entry slot through it (which used to segfault the parent);
  thread_spawn returns 0, safe_thread_spawn an absent handle that has
  destroyed its payload, and safe_thread_fork_join runs both halves on
  the caller.
- clone failure: a seccomp filter makes clone return -EAGAIN. The
  builtin must munmap the stack it just mapped, so failed spawns leave
  the address-space size unchanged (each used to leak 4MB).

The filter cannot be removed, so the clone case runs last. The whole
run is measured for leaks; the extra step repeats it under
W_DEBUG_ALLOC=1, where the count is real.
*/
import lib.assert
import lib.memory_debug
import lib.safe_thread


struct Payload:
	own int* value
	int index


type Entry = fn[](own Payload*) -> int


int read_payload(own Payload* payload):
	ref int* value = payload.value
	return *value + payload.index


own Payload* make_payload(int index):
	own int* value = new int
	*value = 100
	return new Payload(value, index)


# The started handle's result, or -1 for an absent handle (the payload
# was destroyed by the refused spawn).
int safe_spawn_join(int index):
	Entry* entry = read_payload
	optown WSafeThread* thread = safe_thread_spawn(entry, make_payload(index))
	if (!thread): return -1
	own WSafeThread* started = thread
	return safe_thread_join(started)


struct Pair:
	int value


type Reader = fn[](ref Pair*) -> int


int read_pair(ref Pair* pair):
	return pair.value


# Both halves run whether or not the child thread starts.
int safe_fork_join(int value):
	own Pair* pair = new Pair(value)
	ref Pair* shared = pair
	Reader* reader = read_pair
	return safe_thread_fork_join(reader, shared, shared)


void raw_worker(void* arg):
	int* cell = cast(int*, arg)
	*cell = 7


# lib/thread.w spawn + join; returns 1 when the spawn started.
int raw_spawn_join():
	int cell = 0
	wthread* t = thread_spawn(raw_worker, cast(void*, &cell))
	if (t == 0): return 0
	assert_equal(0, thread_join(t))
	assert_equal(7, cell)
	return 1


# The process's address-space size in bytes (/proc/self/statm, first
# field, in pages).
int vm_size():
	int fd = open(c"/proc/self/statm", 0, 0)
	asserts(c"open statm", fd >= 0)
	char[128] buf
	int n = read(fd, &buf[0], 127)
	close(fd)
	asserts(c"read statm", n > 0)
	buf[n] = 0
	return atoi(&buf[0]) * 4096


int syscall_nr(int x86, int x64):
	if (sizeof(int) == 8): return x64
	return x86


# prlimit64(0, RLIMIT_AS, new, old) on struct rlimit64 (two u64 words).
int limit_as(int* new_limit, int* old_limit):
	return syscall7(syscall_nr(340, 302), 0, 9, cast(int, new_limit), cast(int, old_limit), 0, 0)


# A struct rlimit64 with soft limit `soft` and the hard limit of `from`.
int* rlimit_with_soft(int* from, int soft):
	int* limit = cast(int*, malloc(16))
	if (sizeof(int) == 8):
		limit[0] = soft
		limit[1] = from[1]
	else:
		limit[0] = soft
		limit[1] = 0
		limit[2] = from[2]
		limit[3] = from[3]
	return limit


void put16(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255


void put32(char* p, int v):
	put16(p, v & 65535)
	put16(p + 2, (v >> 16) & 65535)


# One classic-BPF instruction (struct sock_filter, 8 bytes).
void bpf_insn(char* p, int code, int jt, int jf, int k):
	put16(p, code)
	p[2] = jt
	p[3] = jf
	put32(p + 4, k)


# Make every later clone fail with -EAGAIN: no_new_privs, then a
# seccomp filter (load nr; nr == clone ? ERRNO(EAGAIN) : ALLOW).
# Returns 0, or the failing prctl's -errno.
int forbid_clone():
	char* filter = cast(char*, malloc(32))
	bpf_insn(filter, 0x20, 0, 0, 0)  # ld [0]: seccomp_data.nr
	bpf_insn(filter + 8, 0x15, 0, 1, syscall_nr(120, 56))  # jeq clone
	bpf_insn(filter + 16, 0x06, 0, 0, 0x50000 + 11)  # ret ERRNO(EAGAIN)
	bpf_insn(filter + 24, 0x06, 0, 0, 0x7fff0000)  # ret ALLOW
	int* program = cast(int*, malloc(2 * sizeof(int)))
	program[0] = 4  # sock_fprog.len (the u16 sits in the low bytes)
	program[1] = cast(int, filter)
	int prctl = syscall_nr(172, 157)
	int status = syscall7(prctl, 38, 1, 0, 0, 0, 0)  # PR_SET_NO_NEW_PRIVS
	if (status == 0): status = syscall7(prctl, 22, 2, cast(int, program), 0, 0, 0)  # PR_SET_SECCOMP, filter
	# The kernel copied the program.
	free(cast(void*, program))
	free(filter)
	return status


void check_refused(int index):
	assert_equal(0, raw_spawn_join())
	assert_equal(-1, safe_spawn_join(index))
	assert_equal(2 * index, safe_fork_join(index))


void test_mmap_failure():
	int* original = cast(int*, malloc(16))
	assert_equal(0, limit_as(cast(int*, 0), original))
	int* tight = rlimit_with_soft(original, vm_size() + 2 * 1048576)
	assert_equal(0, limit_as(tight, cast(int*, 0)))
	for i in range(4): check_refused(i + 1)
	assert_equal(0, limit_as(original, cast(int*, 0)))
	free(cast(void*, tight))
	free(cast(void*, original))
	# Nothing was left half-started: spawning works again.
	assert_equal(1, raw_spawn_join())
	assert_equal(105, safe_spawn_join(5))


void test_clone_failure():
	int status = forbid_clone()
	if (status != 0):
		print2(c"clone failure case skipped: seccomp unavailable, prctl returned ")
		println2(itoa(status))
		return
	int before = vm_size()
	for i in range(4): check_refused(i + 1)
	# Each leaked stack would add 4MB; small heap growth stays below one.
	asserts(c"failed clones leave no stack mapped", vm_size() - before < 4194304)


int main():
	# Warm up: the first spawn installs the per-thread heaps.
	assert_equal(1, raw_spawn_join())
	assert_equal(103, safe_spawn_join(3))
	int leaks_before = 0
	unsafe:
		leaks_before = debug_alloc_report_leaks()
	test_mmap_failure()
	test_clone_failure()
	int leaks_after = 0
	unsafe:
		leaks_after = debug_alloc_report_leaks()
	assert_equal(leaks_before, leaks_after)
	println(c"spawn failure OK")
	return 0
