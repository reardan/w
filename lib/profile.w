/*
Runtime half of --profile-generate (docs/projects/register_allocation_pgo.md
§3.2; the emitter half is code_generator/profile_counters.w).

compiler/compiler.w auto-imports this module only when the flag is on,
and at finish writes the counter table's address and length into the two
globals below, then redirects lib's exit() to __w_profile_exit. Every
exit of the program — _main's exit(main(...)) and direct exit() calls —
therefore reaches __w_profile_flush: when $W_PROFILE_OUT is set, it
appends one "index count\n" line per nonzero counter to that file, each
batch of complete lines in one write(2) on an O_APPEND descriptor so concurrent processes
(a test suite, a parallel build) interleave whole lines, never bytes.
bin/wprof merges these dumps with the compiler's .wprofmap sidecar.

Counters are 8 bytes on both targets; on x86 the int is 32-bit, so the
value is read as two halves and formatted through 16-bit limbs, which
keeps every intermediate below 2^20 without a 64-bit divide. A crash or
_exit skips the flush by design (a crashing run is not a sample).

Compiled by the pinned seed (it is in the compiler's import graph when
the compiler is built with the flag): seed-era syntax only, and the
names here are reserved (__w_ prefix) like the container runtime's.
*/
import lib.lib
import lib.env
import lib.linux
import code_generator.integer


# Set by the compiler at finish (profile_finish): the first counter's
# address in the RW data segment and the number of 8-byte counters.
char* __w_profile_counters
int __w_profile_count
int __w_profile_flushed


# Decimal digits of the 64-bit value whose little-endian bytes are at p,
# written into out (at least 21 bytes); returns the length.
int __w_profile_format_counter(char* p, char* out):
	int lo = load_int32(p)
	int hi = load_int32(p + 4)
	int[4] limb
	limb[0] = lo & 65535
	limb[1] = (lo >> 16) & 65535
	limb[2] = hi & 65535
	limb[3] = (hi >> 16) & 65535
	char[24] digits
	int n = 0
	int nonzero = 1
	while (nonzero):
		# One long-division step by 10 over the four limbs, top first.
		int rem = 0
		int i = 3
		nonzero = 0
		while (i >= 0):
			int cur = rem * 65536 + limb[i]
			limb[i] = cur / 10
			rem = cur - limb[i] * 10
			if (limb[i] != 0): nonzero = 1
			i = i - 1
		digits[n] = '0' + rem
		n = n + 1
	# digits are least significant first
	int k = 0
	while (k < n):
		out[k] = digits[n - 1 - k]
		k = k + 1
	return n


int __w_profile_counter_is_zero(char* p):
	return (load_int32(p) == 0) && (load_int32(p + 4) == 0)


void __w_profile_flush():
	if (__w_profile_flushed): return
	__w_profile_flushed = 1
	if (__w_profile_counters == 0): return
	char* path = env_get(c"W_PROFILE_OUT")
	if (path == 0): return
	if (path[0] == 0): return
	# O_WRONLY|O_CREAT|O_APPEND (1|64|1024), mode 0644
	int fd = open(path, 1089, 420)
	if (fd < 0): return
	# Snapshot the table first: the formatting below calls instrumented
	# lib functions (itoa, strlen, write), whose own counters would
	# otherwise move while the lines are being written.
	int bytes = __w_profile_count * 8
	char* snapshot = cast(char*, malloc(bytes))
	int b = 0
	while (b < bytes):
		snapshot[b] = __w_profile_counters[b]
		b = b + 1
	# Keep complete records together; each append is at most PIPE_BUF.
	char* buffer = cast(char*, malloc(4096))
	int used = 0
	char* line = cast(char*, malloc(64))
	int i = 0
	while (i < __w_profile_count):
		char* counter = snapshot + i * 8
		if (__w_profile_counter_is_zero(counter) == 0):
			char* index_digits = itoa(i)
			int n = strlen(index_digits)
			int k = 0
			while (k < n):
				line[k] = index_digits[k]
				k = k + 1
			free(index_digits)
			line[n] = ' '
			n = n + 1
			n = n + __w_profile_format_counter(counter, line + n)
			line[n] = 10
			n = n + 1
			if (used + n > 4096):
				# Do not retry a short append: another writer could interleave
				# its rows between the two halves of our partial record.
				if (write(fd, buffer, used) != used):
					used = 0
					break
				used = 0
			k = 0
			while (k < n):
				buffer[used + k] = line[k]
				k = k + 1
			used = used + n
		i = i + 1
	if (used > 0): write(fd, buffer, used)
	free(buffer)
	free(line)
	free(snapshot)
	close(fd)


# exit() lands here (profile_patch_exit, code_generator/profile_counters.w):
# flush, then the exit_group syscall exit() itself would have made.
void __w_profile_exit(int code):
	__w_profile_flush()
	syscall(SYS_EXIT_GROUP, code, 0, 0)
