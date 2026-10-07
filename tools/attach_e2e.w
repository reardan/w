/*
End-to-end test for wdbg's --attach mode (debugger/attach.w), run by the
`attach_test` target in build.base.json (it replaced tools/attach_test.sh,
issue #323: no shell scripts).

Attach mode controls a separate running process through ptrace, so it
cannot be exercised by single-command build steps like the other
debugger tests; this driver launches the spinning fixture, attaches wdbg
to it with a piped command script, and checks the output. Every child is
spawned through lib/process.w with an argv vector — no /bin/sh.

The fixture (tests/attach_target_fixture.w) calls PR_SET_PTRACER_ANY, so a
sibling tracer can attach even under YAMA ptrace_scope=1. Both fixtures
print "attach_ready" to their (piped) stdout once their globals are set
and they are about to enter their loop; each case waits for that line
(bounded by the same timeout) instead of the old fixed 400ms settle
sleep.

Cases are independent (each launches its own fixture and wdbg), so they
run in forked workers, up to one per online CPU (ATTACH_TEST_JOBS=<n>
overrides; 1 runs them in-process, serially). A worker buffers its
case's report and hands it back through a bin/ file; the parent prints
reports in declaration order, so output is identical to a serial run
(2026-09-25: 26.7 s serial wall time, most of it the settle sleeps). Prerequisites,
built by the attach_test target before this program runs: bin/wdbg,
bin/wdbg64, bin/attach_target, bin/attach_target64,
bin/attach_finite_target and bin/attach_finite_target64.

Every wdbg invocation runs under a timeout: an execution-control
regression (e.g. continue failing to re-arm a stepped-over breakpoint)
otherwise leaves wdbg blocked in wait4 forever and hangs CI instead of
failing. A passing case takes ~1-2s standalone, but wdbg recompiles the
fixture source on attach, and under a cold parallel `./wbuild tests`
that compile competes with every other build job -- the old 30s was
exceeded once under a cold 20-target run (2026-07-27,
docs/projects/ai_tooling_next_steps.md), so the ceiling is 120s: still a
hard hang stop, with compile-load headroom. Override with
ATTACH_TEST_TIMEOUT=<seconds> for slower machines (0 disables it, as
timeout(1) did). A timeout failure is reported as its own
"FAIL (wdbg timed out ...)" banner so it is never misread as an
assertion failure.
*/
import lib.lib
import lib.env
import lib.file
import lib.process
import lib.str
import structures.string


char* WDBG
char* WDBG64
char* FIXTURE_BIN
char* FIXTURE_BIN64
char* FIXTURE_SRC
char* WRONG_SRC
char* FINITE_BIN
char* FINITE_BIN64
char* FINITE_SRC


void init_paths():
	WDBG = c"bin/wdbg"
	WDBG64 = c"bin/wdbg64"
	FIXTURE_BIN = c"bin/attach_target"
	FIXTURE_BIN64 = c"bin/attach_target64"
	FIXTURE_SRC = c"tests/attach_target_fixture.w"
	# Any other compilable source proves the calibration mismatch path: it
	# builds cleanly but is not the program actually running.
	WRONG_SRC = c"tests/debug_fixture.w"
	FINITE_BIN = c"bin/attach_finite_target"
	FINITE_BIN64 = c"bin/attach_finite_target64"
	FINITE_SRC = c"tests/attach_finite_fixture.w"


int failed = 0
int timeout_secs = 120
# Non-zero inside a case worker: out() buffers the case's report here.
string_builder* case_out = 0


void out(char* s):
	if (case_out != 0):
		string_append(case_out, s)
		return
	write(1, s, strlen(s))


void out_bytes(char* s, int n):
	if (case_out != 0):
		string_append_bytes(case_out, s, n)
		return
	write(1, s, n)


void outln(char* s):
	out(s)
	out(c"\n")


# Echo captured output indented by four spaces per line (the script's
# `printf '%s\n' "$out" | sed 's/^/    /'`).
void out_indented(char* text):
	outln(c"  actual output:")
	int start = 0
	int i = 0
	while (1):
		if ((text[i] == 10) || (text[i] == 0)):
			out(c"    ")
			out_bytes(text + start, i - start)
			out(c"\n")
			if (text[i] == 0): return
			if (text[i + 1] == 0): return
			start = i + 1
		i = i + 1


# The FAIL line for a case, distinguishing "wdbg timed out" from an
# ordinary assertion failure on wdbg's output.
void fail_banner(int timed_out, char* desc):
	if (timed_out):
		out(c"FAIL (wdbg timed out after ")
		out(itoa(timeout_secs))
		out(c"s): ")
	else: out(c"FAIL: ")
	outln(desc)
	failed = 1


# Fixed wdbg argv: <dbg> --attach <pid> [src].
char** wdbg_argv(char* dbg, int pid, char* src):
	char** argv = strv_new(4)
	strv_set(argv, 0, dbg)
	strv_set(argv, 1, c"--attach")
	strv_set(argv, 2, itoa(pid))
	if (src != 0): strv_set(argv, 3, src)
	return argv


char** single_argv(char* path):
	char** argv = strv_new(1)
	strv_set(argv, 0, path)
	return argv


struct attach_run:
	char* text        # wdbg's stdout (plus stderr when requested)
	int timed_out


# Waits (up to timeout_ms) for the fixture's "attach_ready" line on its
# piped stdout, reading byte by byte so nothing after the newline is
# consumed. 1 once the line arrived; 0 on EOF, error or timeout.
int wait_ready(process* target, int timeout_ms):
	int deadline = process_monotonic_ms() + timeout_ms
	char* fds = malloc(8)
	char* ch = malloc(1)
	int ready = 0
	while (1):
		int left = deadline - process_monotonic_ms()
		if ((timeout_ms > 0) && (left <= 0)): break
		if (timeout_ms <= 0): left = 0 - 1
		process_pollfd_set(fds, 0, target.stdout_fd, 1)
		int n = poll(cast(int*, fds), 1, left)
		if (n < 0):
			if (n == 0 - 4): continue
			break
		if (n == 0): continue
		if (read(target.stdout_fd, ch, 1) != 1): break
		if (ch[0] == 10):
			ready = 1
			break
	free(fds)
	free(ch)
	return ready


# Spawns fixture with stdout piped and waits for its readiness line; 0
# (fixture killed and reaped) when it cannot be spawned or never becomes
# ready, with why in *why.
process* start_fixture(char* fixture, char** why):
	spawn_options* opts = spawn_options_new()
	opts.stdout_mode = process_pipe
	process* target = process_spawn(fixture, single_argv(fixture), opts)
	free(opts)
	if (target == 0):
		*why = c"(could not spawn the fixture)"
		return 0
	if (wait_ready(target, timeout_secs * 1000) == 0):
		process_kill(target, sigkill)
		process_wait(target)
		process_free(target)
		*why = c"(the fixture never printed attach_ready)"
		return 0
	return target


# Launches a fresh fixture, waits until it reports reaching its spin loop, attaches dbg with
# the command script on stdin, and always kills the fixture afterwards.
# wdbg's stderr is dropped unless want_stderr (it only ever carries the
# "compiling '...'" progress banner, which no case asserts on); cases that
# assert on a println2 diagnostic (attach.w's fatal/mismatch messages)
# append it.
attach_run* run_attach(char* dbg, char* fixture, char* src, char* commands, int want_stderr):
	attach_run* r = new attach_run()
	r.text = c""
	r.timed_out = 0
	char* why = 0
	process* target = start_fixture(fixture, &why)
	if (target == 0):
		r.text = why
		return r
	process_result* res = process_run(dbg, wdbg_argv(dbg, target.pid, src), 0, commands, timeout_secs * 1000)
	process_kill(target, sigkill)
	process_wait(target)
	process_free(target)
	if (res == 0):
		r.text = c"(could not spawn wdbg)"
		return r
	r.timed_out = (res.status == process_status_timeout)
	if (want_stderr): r.text = strjoin(res.stdout_text, res.stderr_text)
	else: r.text = res.stdout_text
	return r


void check_contains(char* desc, attach_run* r, char* expect):
	if (contains(r.text, expect)):
		out(c"ok: ")
		outln(desc)
		return
	fail_banner(r.timed_out, desc)
	out(c"  expected substring: ")
	outln(expect)
	out_indented(r.text)




# Number of lines containing needle (grep -cF).
int count_lines_with(char* text, char* needle):
	list[char*] lines = split(text, 10)
	int count = 0
	for char* line in lines:
		if (contains(line, needle)): count = count + 1
	return count


# Like run_case, but requires the substring on at least min lines: a
# substring that the FIRST occurrence already satisfies (e.g. "hit
# breakpoint 1") cannot otherwise prove a second stop happened.
void exec_count_case(char* desc, char* dbg, char* fixture, char* commands, char* expect, int min):
	attach_run* r = run_attach(dbg, fixture, FIXTURE_SRC, commands, 0)
	int got = count_lines_with(r.text, expect)
	if (got >= min):
		out(c"ok: ")
		outln(desc)
		return
	fail_banner(r.timed_out, desc)
	out(c"  expected at least ")
	out(itoa(min))
	out(c" occurrences of: ")
	out(expect)
	out(c" (got ")
	out(itoa(got))
	outln(c")")
	out_indented(r.text)


# The value of the LAST "n = <decimal> (0x" on the line (the script's
# greedy `sed 's/.*n = \([0-9][0-9]*\) (0x.*/\1/p'`), or 0 when the line
# has none. The non-tty prompt is glued to the front of the line, so the
# value may sit anywhere on it.
char* print_n_value(char* line):
	int i = strlen(line) - 1
	while (i >= 0):
		if (starts_with(line + i, c"n = ")):
			int j = i + 4
			while (isdigit(line[j])): j = j + 1
			if ((j > i + 4) && starts_with(line + j, c" (0x")): return substring(line, i + 4, j)
		i = i - 1
	return 0


# Frame selection must address the CALLER's stack slot, not re-read frame
# 0's: the fixture passes bump its n plus a fixed 7000000 call-site
# offset, so 'p n' at frame 0 and again after 'up' (both at the same
# stop) must differ by exactly that offset. A frame-base regression that
# reads frame 0's slot twice yields delta 0 and fails; a plain substring
# check could not tell the two apart when both frames held the same value.
void exec_frame_delta_case(char* desc, char* dbg, char* fixture):
	attach_run* r = run_attach(dbg, fixture, FIXTURE_SRC, c"b bump\nc\np n\nup\np n\nkill\n", 0)
	char* n0 = 0
	char* n1 = 0
	list[char*] lines = split(r.text, 10)
	for char* line in lines:
		char* v = print_n_value(line)
		if (v != 0):
			if (n0 == 0): n0 = v
			else:
				if (n1 == 0): n1 = v
	if ((n0 != 0) && (n1 != 0) && ((atoi(n0) - atoi(n1)) == 7000000)):
		out(c"ok: ")
		outln(desc)
		return
	if (n0 == 0): n0 = c""
	if (n1 == 0): n1 = c""
	fail_banner(r.timed_out, desc)
	out(c"  frame 0 n='")
	out(n0)
	out(c"' caller n='")
	out(n1)
	outln(c"' (want delta 7000000)")
	out_indented(r.text)


# Detach truly restores patched bytes: drives a fixture that terminates on
# its own through a real detach and waits for its natural exit instead of
# killing it, so a regression that skips the int3 byte restore surfaces
# as a crash or a wrong exit code instead of silently passing. Both the
# fixture's final printed line and its real exit code are asserted from
# one run.
void exec_detach_case(char* prefix, char* dbg, char* fixture):
	char* why = 0
	process* target = start_fixture(fixture, &why)
	string_builder* report = string_new()
	int timed_out = 0
	int code = -1
	if (target == 0):
		string_append(report, why)
		string_append(report, c"\n")
	else:
		process_result* res = process_run(dbg, wdbg_argv(dbg, target.pid, FINITE_SRC), 0, c"b bump\nc\ndetach\n", timeout_secs * 1000)
		if (res != 0): timed_out = (res.status == process_status_timeout)
		# The script's bare `wait` had no ceiling; bound it by the same
		# timeout so a target left stopped by a detach regression fails
		# instead of hanging.
		code = process_wait_or_kill(target, timeout_secs * 1000)
		# The fixture has exited, so its stdout pipe drains to EOF.
		process_capture captured
		process_capture_init(&captured)
		int got = process_capture_read(&captured, target.stdout_fd)
		while (got > 0): got = process_capture_read(&captured, target.stdout_fd)
		string_append(report, process_capture_take(&captured))
		string_append(report, c"wdbg_status=")
		if (timed_out): string_append(report, c"timeout")
		else:
			if (res == 0): string_append(report, c"spawn-failed")
			else: string_append_int(report, res.status)
		string_append(report, c"\nexit_code=")
		if (code == process_status_timeout): string_append(report, c"timeout")
		else: string_append_int(report, code)
		string_append(report, c"\n")
		process_free(target)
	char* text = report.data

	char* desc = strjoin(prefix, c"detach lets the target print its final output")
	if (contains(text, c"attach_finite_done")):
		out(c"ok: ")
		outln(desc)
	else:
		fail_banner(timed_out, desc)
		out_indented(text)

	desc = strjoin(prefix, c"detach lets the target exit naturally (code 42)")
	if (code == 42):
		out(c"ok: ")
		outln(desc)
	else:
		out(c"FAIL: ")
		out(desc)
		out(c": ")
		outln(text)
		failed = 1


/* Case registry and parallel runner. main declares every case through
the run_* helpers below, which only record it; run_all_cases then
executes them. */

struct attach_case:
	int kind          # 0 substring, 1 line count, 2 frame delta, 3 detach
	char* desc        # the detach kind's description prefix
	char* dbg
	char* fixture
	char* src
	char* commands
	char* expect
	int want_stderr
	int min


list[attach_case*] cases
# The parent's pid, naming the report files (a worker's getpid differs).
int runner_pid


attach_case* add_case(int kind, char* desc, char* dbg, char* fixture, char* src, char* commands, char* expect):
	attach_case* c = new attach_case()
	c.kind = kind
	c.desc = desc
	c.dbg = dbg
	c.fixture = fixture
	c.src = src
	c.commands = commands
	c.expect = expect
	c.want_stderr = 0
	c.min = 0
	cases.push(c)
	return c


# run_case: the 32-bit fixture and wdbg; src 0 is raw mode.
void run_case(char* desc, char* src, char* commands, char* expect):
	add_case(0, desc, WDBG, FIXTURE_BIN, src, commands, expect)


void run_case_stderr(char* desc, char* src, char* commands, char* expect):
	attach_case* c = add_case(0, desc, WDBG, FIXTURE_BIN, src, commands, expect)
	c.want_stderr = 1


void run_case_64(char* desc, char* src, char* commands, char* expect):
	add_case(0, desc, WDBG64, FIXTURE_BIN64, src, commands, expect)


void run_count_case(char* desc, char* dbg, char* fixture, char* commands, char* expect, int min):
	attach_case* c = add_case(1, desc, dbg, fixture, FIXTURE_SRC, commands, expect)
	c.min = min


void run_frame_delta_case(char* desc, char* dbg, char* fixture):
	add_case(2, desc, dbg, fixture, FIXTURE_SRC, 0, 0)


void run_detach_case(char* prefix, char* dbg, char* fixture):
	add_case(3, prefix, dbg, fixture, FINITE_SRC, 0, 0)


void exec_case(attach_case* c):
	if (c.kind == 0):
		check_contains(c.desc, run_attach(c.dbg, c.fixture, c.src, c.commands, c.want_stderr), c.expect)
	else:
		if (c.kind == 1): exec_count_case(c.desc, c.dbg, c.fixture, c.commands, c.expect, c.min)
		else:
			if (c.kind == 2): exec_frame_delta_case(c.desc, c.dbg, c.fixture)
			else: exec_detach_case(c.desc, c.dbg, c.fixture)


# Online CPU count from /proc/cpuinfo (tools/wexec.w's
# wexec_default_jobs); 1 when it cannot be read.
int cpu_count():
	char* text = file_read_text(c"/proc/cpuinfo")
	if (text == 0): return 1
	int count = 0
	int line_start = 1
	int i = 0
	while (text[i] != 0):
		if (line_start):
			if (starts_with(text + i, c"processor")): count = count + 1
		line_start = text[i] == 10
		i = i + 1
	free(text)
	if (count < 1): return 1
	return count


char* case_report_path(int i):
	string_builder* s = string_new()
	string_append(s, c"bin/attach_e2e_")
	string_append_int(s, runner_pid)
	string_append_char(s, '_')
	string_append_int(s, i)
	string_append(s, c".txt")
	return s.data


# Runs case i in-process with its report buffered; returns the report.
char* exec_case_buffered(int i):
	case_out = string_new()
	exec_case(cases[i])
	char* text = case_out.data
	case_out = 0
	return text


void run_all_cases(int jobs):
	if (jobs <= 1):
		for attach_case* c in cases: exec_case(c)
		return
	runner_pid = getpid()
	int total = cases.length
	list[char*] texts = new list[char*]
	list[int] done = new list[int]
	for i in range(total):
		texts.push(0)
		done.push(0)
	list[process*] kids = new list[process*]
	list[int] owner = new list[int]
	int next = 0
	int running = 0
	int printed = 0
	while (printed < total):
		while ((next < total) && (running < jobs)):
			int pid = fork()
			if (pid == 0):
				# Worker: run the case, hand its report back, exit with
				# its verdict.
				failed = 0
				char* report = exec_case_buffered(next)
				if (file_write_text(case_report_path(next), report) == 0): exit(2)
				exit(failed)
			if (pid < 0):
				# No worker: run it here instead.
				texts[next] = exec_case_buffered(next)
				done[next] = 1
			else:
				process* p = new process()
				p.pid = pid
				p.stdin_fd = 0 - 1
				p.stdout_fd = 0 - 1
				p.stderr_fd = 0 - 1
				p.status = 0
				p.reaped = 0
				p.win_handle = 0
				kids.push(p)
				owner.push(next)
				running = running + 1
			next = next + 1
		# Print every finished case whose predecessors are all printed.
		while ((printed < total) && (done[printed] != 0)):
			out(texts[printed])
			printed = printed + 1
		if (running > 0):
			int k = process_wait_any(kids, 1)
			if (k < 0):
				outln(c"FAIL: waiting for a case worker failed")
				failed = 1
				return
			running = running - 1
			int c = owner[k]
			int status = process_decode_status(kids[k].status)
			char* path = case_report_path(c)
			char* text = file_read_text(path)
			unlink(path)
			if (status != 0): failed = 1
			if (text == 0):
				failed = 1
				string_builder* s = string_new()
				string_append(s, c"FAIL: ")
				string_append(s, cases[c].desc)
				string_append(s, c" (case worker exited with status ")
				string_append_int(s, status)
				string_append(s, c" and no report)\n")
				text = s.data
			texts[c] = text
			done[c] = 1


int main(int argc, char** argv):
	init_paths()
	char* override = env_get(c"ATTACH_TEST_TIMEOUT")
	if ((override != 0) && (override[0] != 0)): timeout_secs = atoi(override)
	int jobs = cpu_count()
	char* jobs_override = env_get(c"ATTACH_TEST_JOBS")
	if ((jobs_override != 0) && (jobs_override[0] != 0)): jobs = atoi(jobs_override)
	cases = new list[attach_case*]

	# Symbolized mode: the current location resolves to the fixture's source.
	run_case(c"symbolized location", FIXTURE_SRC, c"l\ndetach\n", c"attach_target_fixture.w:")

	# Symbolized mode: the attach banner reports symbols were loaded.
	run_case(c"symbols loaded banner", FIXTURE_SRC, c"detach\n", c"symbols loaded")

	# Registers dump works against the stopped process.
	run_case(c"registers", FIXTURE_SRC, c"r\ndetach\n", c"eip: 0x")

	# A breakpoint set by function name is hit after continue, and the
	# disarm/step-over/re-arm dance lets it hit again on the next
	# iteration: require TWO "hit breakpoint 1" stops, since one match is
	# already satisfied by the first stop (a re-arm regression used to
	# pass here, with the second 'c' hanging until the timeout instead of
	# failing).
	run_count_case(c"breakpoint hit twice (re-armed)", WDBG, FIXTURE_BIN, c"b slow_step\nc\nc\nkill\n", c"hit breakpoint 1", 2)

	# Locals/frames through the seam (#123 phase 5): 'bump' is called from
	# 'slow_step', which is called from 'main', so a breakpoint in bump
	# gives a real two-level call stack to inspect.

	# Argument inspection at the innermost frame (frame 0): visible
	# immediately at function entry, unlike a not-yet-executed local.
	run_case(c"args at breakpoint", FIXTURE_SRC, c"b bump\nc\ni a\nkill\n", c"n = ")

	# print <name> resolves the same argument by name.
	run_case(c"print arg at breakpoint", FIXTURE_SRC, c"b bump\nc\np n\nkill\n", c"n = ")

	# Frame selection ('up') addresses the caller's (slow_step's) own
	# argument, not bump's -- proves the frame list's base tracking, not
	# just frame 0, by requiring the two frames' n to differ by the
	# fixture's fixed offset.
	run_frame_delta_case(c"frame selection: caller arg differs by the call-site offset", WDBG, FIXTURE_BIN)

	# A non-numeric frame argument is an error, not a silent frame-0 select.
	run_case(c"frame rejects a non-numeric argument", FIXTURE_SRC, c"f x\ndetach\n", c"frame: not a number: x")

	# 'bt' after 'up' shows the caller was selected without losing the list.
	run_case(c"up then backtrace still names both frames", FIXTURE_SRC, c"b bump\nc\nup\nbt\nkill\n", c"main (")

	# Memory examine reads the target's ELF magic at the fixed load base.
	run_case(c"examine memory", FIXTURE_SRC, c"x 0x8048000 1\ndetach\n", c"0x464c457f")

	# --- restricted expression eval (#123 phase 6, debugger/attach_eval.w) ---
	# The fixture initializes attach_pair {first=1234, second=5678}, a
	# struct pointer to it and a 4-element heap int array
	# {111,222,333,444} before its spin loop, so these are stable at any
	# stop.

	# Field access on a struct value.
	run_case(c"eval: struct field read", FIXTURE_SRC, c"p attach_pair.first\ndetach\n", c"attach_pair.first = 1234")

	# Field access through a struct pointer (one auto-deref, like compiled '.').
	run_case(c"eval: field through a struct pointer", FIXTURE_SRC, c"p attach_pair_ref.second\ndetach\n", c"attach_pair_ref.second = 5678")

	# Dereference reads at the pointee's width through the ptrace seam.
	run_case(c"eval: dereference", FIXTURE_SRC, c"p *attach_items\ndetach\n", c"*attach_items = 111")

	# Indexing scales by the element size (never the raw byte offset).
	run_case(c"eval: indexing", FIXTURE_SRC, c"p attach_items[2]\ndetach\n", c"attach_items[2] = 333")

	# Arithmetic combines evaluated results: 222 + 1234.
	run_case(c"eval: arithmetic on results", FIXTURE_SRC, c"p attach_items[1] + attach_pair.first\ndetach\n", c"= 1456")

	# set writes through a field lvalue and echoes the new value.
	run_case(c"eval: set through a field", FIXTURE_SRC, c"set attach_pair.second 42\np attach_pair.second\ndetach\n", c"attach_pair.second = 42")

	# In-target calls are rejected with a clear diagnostic, not silently 0.
	run_case(c"eval: function calls rejected", FIXTURE_SRC, c"p bump(3)\ndetach\n", c"function calls are not supported in attach mode")

	# UTF-8 names are one word to the expression reader (#287).
	run_case(c"eval: UTF-8 global name", FIXTURE_SRC, c"p zähler\ndetach\n", c"zähler = 777")

	# --- hardware watchpoints (DR0-DR3; #123's last remaining phase) ---
	# Native x86/x86-64 only: the debug registers are real hardware state
	# (PTRACE_PEEKUSER/POKEUSER on the user area), which qemu-user does
	# not emulate -- this suite already assumes a native host for ptrace
	# itself.

	# A write watch on the spinning counter stops the tracee on the next
	# iteration's store and names the watchpoint that fired (DR6), with
	# the same old -> new report shape as the in-process software scan.
	run_case(c"hw watchpoint fires and names the watchpoint", FIXTURE_SRC, c"watch attach_counter\nc\nkill\n", c"watchpoint 1: attach_counter changed: ")

	# The stop reports where the write happened (back in the fixture source).
	run_case(c"hw watchpoint stop is located", FIXTURE_SRC, c"watch attach_counter\nc\nkill\n", c"attach_target_fixture.w:")

	# Four debug registers exist; a fifth watch is a hard error, never a
	# silent degradation (attach mode has no software fallback scan).
	run_case(c"hw watchpoint exhaustion", FIXTURE_SRC, c"watch attach_counter\nwatch attach_pair.first\nwatch attach_pair.second\nwatch attach_items[0]\nwatch attach_items[1]\nkill\n", c"no free debug register")

	# Raw mode (no source): attach still works, reporting no symbols.
	run_case(c"raw mode banner", 0, c"detach\n", c"raw mode: no symbols")

	# A backtrace in symbolized mode names the fixture's main frame.
	run_case(c"backtrace names main", FIXTURE_SRC, c"bt\ndetach\n", c"main (")

	# A backtrace taken while stopped inside a callee names both frames:
	# the callee at #0 and its caller (main) further up the stack, proving
	# the heuristic frame walk -- not just the current-ip line -- resolves
	# symbols.
	run_case(c"backtrace names fixture functions", FIXTURE_SRC, c"b slow_step\nc\nbt\nkill\n", c"main (")

	# 'list' shows a multi-line source window (not just the single current
	# line 'l' prints), centered on wherever the process is stopped --
	# always somewhere in main's loop body, so this line is always in
	# range.
	run_case(c"list shows source", FIXTURE_SRC, c"list\ndetach\n", c"attach_counter = slow_step")

	# 'i functions' lists the debuggee's defined functions by name.
	run_case(c"i functions lists symbols", FIXTURE_SRC, c"i functions\ndetach\n", c"slow_step")

	# 'i files' lists the debuggee's known source files.
	run_case(c"i files lists source file", FIXTURE_SRC, c"i files\ndetach\n", c"attach_target_fixture.w")

	# Attaching with a source file that does not match the running binary
	# (tests/debug_fixture.w, a different program) must be caught by the
	# recompile-vs-/proc/<pid>/exe comparison, not silently trusted: a
	# clear diagnostic and a fall back to raw mode, never wrong symbol
	# names.
	run_case_stderr(c"mismatched source: clean diagnostic", WRONG_SRC, c"detach\n", c"does not match this source")
	run_case(c"mismatched source: raw fallback", WRONG_SRC, c"detach\n", c"raw mode: no symbols")

	# Disassembly of a named function in symbolized mode shows its header.
	run_case(c"disassemble function", FIXTURE_SRC, c"disas slow_step\ndetach\n", c"slow_step:")

	# No-argument disassembly marks the stopped instruction.
	run_case(c"disassembly marks ip", FIXTURE_SRC, c"disas\ndetach\n", c"=> 0x")

	# Single-stepping shows the surrounding instructions automatically.
	run_case(c"step shows instructions", FIXTURE_SRC, c"si\ndetach\n", c"=> 0x")

	# Raw mode still disassembles from the stopped ip (PTRACE_PEEKDATA reads).
	run_case(c"raw mode disassembly", 0, c"disas\ndetach\n", c"=> 0x")

	# Raw mode has no symbol table: function targets point at the address form.
	run_case(c"raw mode disas boundary", 0, c"disas slow_step\ndetach\n", c"no symbols: disassemble by address")

	# --- execution control: s/n/fin (#123 phase 4 remainder) ---
	# 'n' (next) steps over a call: from slow_step's call-site line, one
	# 'next' runs bump to completion and stops at slow_step's own
	# following statement, never reporting a stop inside bump itself.
	run_case(c"next steps over a call", FIXTURE_SRC, c"b slow_step\nc\nn\nkill\n", c"return step")

	# 's' (step) steps into a call: from the same call-site line, one
	# 'step' lands on bump's first statement instead.
	run_case(c"step steps into a call", FIXTURE_SRC, c"b slow_step\nc\ns\nkill\n", c"bump (")

	# A second 'next' from inside bump (after stepping in) advances by
	# source line within the same frame, same as wdbg.w's in-process 'n'.
	run_case(c"next advances within a frame", FIXTURE_SRC, c"b bump\nc\nn\nkill\n", c"return inc")

	# 'fin' runs to the caller's return site and reports the returned
	# value (bump's argument n plus one).
	run_case(c"finish reports the returned value", FIXTURE_SRC, c"b bump\nc\nfin\nkill\n", c"value returned = ")

	# After 'fin' reports the value it glides to the next statement
	# boundary in the caller (slow_step's own 'return step'), matching
	# wdbg.w's in-process 'fin' rather than stopping mid-statement at the
	# bare return address.
	run_case(c"finish lands on the caller's next statement", FIXTURE_SRC, c"b bump\nc\nfin\nkill\n", c"return step")

	# --- detach truly restores patched bytes (#123 phase 4) ---
	# Every other case above kills the fixture with SIGKILL after
	# detaching, which never proves the patched int3 byte was put back.
	run_detach_case(c"", WDBG, FINITE_BIN)

	# --- x86-64 attach: symbolization, registers, locals/frames (#123 phase 3) ---
	# Same fixture, compiled and attached as a 64-bit target: bin/wdbg64
	# (built with 'bin/wv2 x64 debugger/debugger.w') recompiles the source
	# with the x64 selector too (debugger/wdbg.w's wdbg_attach_compile), so
	# calibration validates against a 64-bit /proc/<pid>/exe instead of
	# falling back to raw mode the way a 32-bit recompile always did
	# against a 64-bit process.
	run_case_64(c"x64: symbolized location", FIXTURE_SRC, c"l\ndetach\n", c"attach_target_fixture.w:")
	run_case_64(c"x64: symbols loaded banner", FIXTURE_SRC, c"detach\n", c"symbols loaded")
	run_case_64(c"x64: registers dump uses 64-bit names", FIXTURE_SRC, c"r\ndetach\n", c"rip: 0x")
	run_case_64(c"x64: breakpoint hit names function", FIXTURE_SRC, c"b bump\nc\nkill\n", c"hit breakpoint 1")
	run_count_case(c"x64: breakpoint hit twice (re-armed)", WDBG64, FIXTURE_BIN64, c"b slow_step\nc\nc\nkill\n", c"hit breakpoint 1", 2)
	run_case_64(c"x64: args through the seam", FIXTURE_SRC, c"b bump\nc\ni a\nkill\n", c"n = ")
	run_frame_delta_case(c"x64: frame selection: caller arg differs by the call-site offset", WDBG64, FIXTURE_BIN64)
	run_case_64(c"x64: backtrace names main", FIXTURE_SRC, c"b bump\nc\nbt\nkill\n", c"main (")

	# x64: execution control twins (#123 phase 4 remainder).
	run_case_64(c"x64: next steps over a call", FIXTURE_SRC, c"b slow_step\nc\nn\nkill\n", c"return step")
	run_case_64(c"x64: step steps into a call", FIXTURE_SRC, c"b slow_step\nc\ns\nkill\n", c"bump (")
	run_case_64(c"x64: finish reports the returned value", FIXTURE_SRC, c"b bump\nc\nfin\nkill\n", c"value returned = ")

	# x64: restricted eval + hardware watchpoint twins (#123 phase 6 / 5).
	run_case_64(c"x64: eval field through a struct pointer", FIXTURE_SRC, c"p attach_pair_ref.second\ndetach\n", c"attach_pair_ref.second = 5678")
	run_case_64(c"x64: eval indexing", FIXTURE_SRC, c"p attach_items[2]\ndetach\n", c"attach_items[2] = 333")
	run_case_64(c"x64: eval set through a field", FIXTURE_SRC, c"set attach_pair.second 42\np attach_pair.second\ndetach\n", c"attach_pair.second = 42")
	run_case_64(c"x64: hw watchpoint fires and names the watchpoint", FIXTURE_SRC, c"watch attach_counter\nc\nkill\n", c"watchpoint 1: attach_counter changed: ")

	# x64: detach truly restores patched bytes, same shape as the 32-bit
	# case above.
	run_detach_case(c"x64: ", WDBG64, FINITE_BIN64)

	run_all_cases(jobs)

	if (failed == 0):
		outln(c"attach test OK")
		return 0
	outln(c"attach test FAILED")
	return 1
