/*
End-to-end test for the core-dump processor (tools/wcore.w).

Crashes the null-deref crash fixture (a real kernel SIGSEGV) with core
dumps enabled, then runs bin/wcore on the resulting ET_CORE file and
asserts the report symbolizes the faulting function and shows a
plausible backtrace, for both a 32-bit and a 64-bit fixture binary.
It also checks the build-id cross-check: the core's copy of the
fixture's build-id matches the fixture, a different same-architecture
W binary is refused, and a core whose ELF header page was filtered out
(coredump_filter without bit 4) is processed with an "unverified" note.

Real kernel cores need a cooperative environment: a plain-filename
/proc/sys/kernel/core_pattern (so the core lands in the crashing
process's cwd) and a raisable RLIMIT_CORE. When either is missing -- a
piped core_pattern (apport/systemd-coredump, common on CI hosts) or a
hard core limit of 0 -- the test SKIPS cleanly, printing the reason to
stderr and the OK banner to stdout so the build step still passes.
Prerequisites, built by the wcore_test target before this runs:
bin/wcore, bin/wcore_fixture32, bin/wcore_fixture64.

Run by the wcore_test target (tests/crash_null_deref_fixture.w.wbuild).
It replaced tools/wcore_test.sh (issue #323: no shell scripts): every
child is spawned through lib/process.w with an argv vector -- no
/bin/sh. The script's subshell "ulimit -c unlimited" and
"echo 0x23 > /proc/self/coredump_filter" are applied to this process
(setrlimit(2) and a /proc write), which the fixture inherits across
fork+exec; the filter is restored after each crash. Each case's
scratch directory is pid-scoped under bin/.
*/
import lib.lib
import lib.env
import lib.process
import lib.path
import lib.file
import lib.str
import lib.shell_commands
import structures.string


char* WCORE
char* ROOT
char* PATTERN
int FAILED = 0
int RLIMIT_OK = 0


void out(char* s):
	write(1, s, strlen(s))


void err_out(char* s):
	write(2, s, strlen(s))


void skip(char* reason):
	err_out(c"wcore test SKIP: ")
	err_out(reason)
	err_out(c"\n")
	out(c"wcore test OK\n")
	exit(0)


# expect <case> <output> <substring>
void expect(char* desc, char* text, char* needle):
	if (index_of(text, needle) < 0):
		out(c"FAIL: ")
		out(desc)
		out(c": output does not contain '")
		out(needle)
		out(c"'\n")
		FAILED = 1


char* cat3(char* a, char* b, char* c):
	return strjoin(strjoin(a, b), c)


# "ulimit -c unlimited": soft and hard RLIMIT_CORE (4) to RLIM_INFINITY
# (all bits set, -1 as a word). setrlimit is syscall 75 on i386 and 160
# on x86-64; struct rlimit is two words.
int raise_core_limit():
	char* rl = malloc(2 * __word_size__)
	save_word(rl, -1)
	save_word(rl + __word_size__, -1)
	int nr = 75
	if (__word_size__ == 8):
		nr = 160
	int r = syscall(nr, 4, rl, 0)
	free(rl)
	return r == 0


# First "core*" entry of dir in name order (ls "$dir"/core* | head -n 1),
# as a dir-relative path, or 0 when there is none.
char* find_core(char* dir):
	int fd = open(dir, 65536, 0) /* 65536 = O_DIRECTORY */
	if (fd < 0):
		return 0
	char* best = 0
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = shell_commands_load_uint16(entry + 2 * __word_size__)
			char* name = entry + 2 * __word_size__ + 2
			if ((name[0] == 'c') && (name[1] == 'o') && (name[2] == 'r') && (name[3] == 'e')):
				if ((best == 0) || (strcmp(name, best) < 0)):
					best = strclone(name)
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	if (best == 0):
		return 0
	return path_join(dir, best)


# Remove every core* file of dir (rm -f "$dir"/core*).
void remove_cores(char* dir):
	char* core = find_core(dir)
	while (core != 0):
		unlink(core)
		core = find_core(dir)


# Crash <fixture> with W_CRASH_TRACE=0 (keeps the fixture's own
# in-process crash report out of the way; the kernel core dump is what
# this test is about) in dir, discarding its output.
void crash_fixture(char* fixture, char* dir):
	char* path = path_join(ROOT, fixture)
	char** argv = strv_new(1)
	strv_set(argv, 0, path)
	spawn_options* opts = spawn_options_new()
	opts.cwd = dir
	opts.env = env_copy_with(env_current(), c"W_CRASH_TRACE", c"0")
	process_result* r = process_run(path, argv, opts, 0, 120000)
	if (r != 0):
		process_result_free(r)
	free(opts)


# Runs bin/wcore with up to three arguments (0 ends the list); returns
# stdout followed by stderr (the script's 2>&1) and sets *status.
char* run_wcore(char* a, char* b, char* c, int* status):
	char** argv = strv_new(4)
	strv_set(argv, 0, WCORE)
	int n = 1
	if (a != 0):
		strv_set(argv, n, a)
		n = n + 1
	if (b != 0):
		strv_set(argv, n, b)
		n = n + 1
	if (c != 0):
		strv_set(argv, n, c)
	process_result* r = process_run(WCORE, argv, 0, 0, 120000)
	free(cast(void*, argv))
	if (r == 0):
		*status = 127
		return c"(could not spawn bin/wcore)"
	*status = r.status
	char* text = strjoin(r.stdout_text, r.stderr_text)
	process_result_free(r)
	return text


# run_case <description> <fixture-binary> <ip-register-name> <other-binary>
# <other-binary> is a different W binary of the same architecture, which
# wcore must refuse by build-id.
void run_case(char* desc, char* fixture, char* ipreg, char* other):
	string_builder* d = string_new()
	string_append(d, c"bin/wcore_e2e_")
	string_append_int(d, getpid())
	string_append(d, c"_")
	string_append(d, ipreg)
	char* dir = d.data
	shell_commands_rm_one(dir, 1, 1)
	shell_commands_mkdir_one(dir, 1)
	# Crash the fixture with cores enabled, in its own directory so the
	# "core" file cannot collide with another case.
	if (RLIMIT_OK):
		crash_fixture(fixture, dir)
	char* core = find_core(dir)
	if (core == 0):
		shell_commands_rm_one(dir, 1, 1)
		skip(cat3(desc, c": no core file appeared (RLIMIT_CORE hard-capped, or core_pattern '", cat3(PATTERN, c"' points elsewhere)", c"")))

	int status = 0
	char* text = run_wcore(core, fixture, 0, &status)
	# The .debug_line file table records the path the compiler saw, which
	# may be absolute: assert the basename, like crash_trace_test does.
	expect(desc, text, c"SIGSEGV")
	expect(desc, text, c"faulting address: 0x00000000")
	expect(desc, text, c"at crash_deep (")
	expect(desc, text, c"crash_null_deref_fixture.w:")
	expect(desc, text, c"at main (")
	expect(desc, text, cat3(c"  ", ipreg, c" 0x"))
	expect(desc, text, c"stack trace (most recent call first):")

	char* jdesc = strjoin(desc, c" (--json)")
	char* json = run_wcore(c"--json", core, fixture, &status)
	expect(jdesc, json, c"\"signal\":11")
	expect(jdesc, json, c"\"signal_name\":\"SIGSEGV\"")
	expect(jdesc, json, c"\"function\":\"crash_deep\"")
	expect(jdesc, json, cat3(c"\"", ipreg, c"\":\"0x"))
	expect(jdesc, json, c"\"build_id_verified\":true")
	expect(desc, text, c"(core and binary match)")

	char* wrong = run_wcore(core, other, 0, &status)
	if (status == 0):
		out(c"FAIL: ")
		out(desc)
		out(c": wcore accepted a binary with a different build-id\n")
		FAILED = 1
	expect(strjoin(desc, c" (wrong binary)"), wrong, c"build-id mismatch")

	# Drop coredump_filter bit 4 (ELF headers) so the core has no copy of
	# the binary's first page, hence no build-id: wcore still reports.
	remove_cores(dir)
	char* old_filter = file_read_text(c"/proc/self/coredump_filter")
	if (RLIMIT_OK && (old_filter != 0)):
		if (file_write_text(c"/proc/self/coredump_filter", c"0x23\n")):
			crash_fixture(fixture, dir)
			# The kernel parses the value with base 0: restore it as hex.
			int i = strlen(old_filter)
			while ((i > 0) && (old_filter[i - 1] == 10)):
				old_filter[i - 1] = 0
				i = i - 1
			file_write_text(c"/proc/self/coredump_filter", cat3(c"0x", old_filter, c"\n"))
	core = find_core(dir)
	if (core != 0):
		char* ndesc = strjoin(desc, c" (no build-id in core)")
		text = run_wcore(core, fixture, 0, &status)
		expect(ndesc, text, c"unverified: the core has no build-id")
		expect(ndesc, text, c"at crash_deep (")

	shell_commands_rm_one(dir, 1, 1)


int main(int argc, char** argv):
	WCORE = c"bin/wcore"
	ROOT = malloc(4096)
	if (getcwd(ROOT, 4096) <= 0):
		err_out(c"wcore test: getcwd failed\n")
		return 1

	PATTERN = file_read_text(c"/proc/sys/kernel/core_pattern")
	if (PATTERN == 0):
		PATTERN = c""
	int i = strlen(PATTERN)
	while ((i > 0) && (PATTERN[i - 1] == 10)):
		PATTERN[i - 1] = 0
		i = i - 1
	if (PATTERN[0] == '|'):
		skip(cat3(c"core_pattern is piped (", PATTERN, c"): no core file lands in the cwd"))

	RLIMIT_OK = raise_core_limit()

	run_case(c"32-bit core", c"bin/wcore_fixture32", c"eip", c"bin/wv2")
	run_case(c"64-bit core", c"bin/wcore_fixture64", c"rip", c"bin/wcore")

	if (FAILED != 0):
		return 1
	out(c"wcore test OK\n")
	return 0
