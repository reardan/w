/*
wexec --trace <target>: ptrace-based traced-dependency audit (issue #251
Direction 2, docs/projects/wexec.md). An AUDIT surface only -- it changes
nothing about how a plain `wexec <target>` runs; it is a separate mode
that runs the target's own steps under ptrace instead of a plain
process_run, and reports every file the steps successfully opened for
reading against the target's declared input set (wexec.w's
wexec_trace_collect_declared: the "inputs" array plus, when bin/wv2
exists, the deps-driven compile-root closures wexec_cache_key already
computes for caching -- see wexec.w's "Deps-driven cache keys" section).
Linux-only; see the word-size note below.

Mechanism: for each step, fork a child that calls ptrace(PTRACE_TRACEME)
before execve (mirroring lib/process.w's process_spawn child path, which
has no pre-execve hook to install one, hence this small dedicated spawn
rather than a lib/process.w change). The parent reaps the post-execve
SIGTRAP stop, then alternates PTRACE_SYSCALL resumes: a syscall-entry
stop reads the syscall number from orig_eax/orig_rax and, for open/openat,
decodes the filename argument by peeking the child's memory a word at a
time -- the same PTRACE_PEEKDATA primitive debugger/attach.w's
at_read_word uses, though this module keeps its own copy (see below) --
and the matching syscall-exit stop reads the return value from eax/rax,
recording the path when the call requested read access (O_ACCMODE !=
O_WRONLY) and returned a non-negative fd.

This module intentionally does not import debugger/attach.w: that file's
ptrace helpers (at_read_word et al.) are wired to a single live
attach-mode session's global state (attach_pid, attach_wordbuf, the
dbg_mem_* target-access seam), not parameterized for a fresh ptraced
child per manifest step, so reusing them directly would mean fighting
that coupling instead of a few dozen lines of a self-contained,
differently-shaped ptrace loop. The request numbers and register-offset
math below are the same ones documented in debugger/attach.w's own
comments (i386: 17-word user_regs_struct; x86-64: 27-word, with syscall
arg4 in r10 rather than rcx because the syscall instruction clobbers
rcx) -- cross-checked against attach.w's at_print_registers offsets.

Word-size scope: ptrace cannot usefully cross tracer/tracee bitness (a
32-bit tracer cannot GETREGS/PEEKDATA a 64-bit tracee, and vice versa),
so this module's register decoding is selected by __word_size__ of the
*tracer* -- i.e. of bin/wexec itself. wexec's own manifest target
(build.base.json) compiles it for the default (x86, 32-bit) arch, so in
practice `bin/wexec --trace` traces 32-bit (x86) target processes, which
covers ordinary `bin/wv2 ...` compiles and the default-arch test
binaries those targets run. A target whose steps run x64-compiled
binaries (`bin/wv2 x64 ...`) cannot be traced by a 32-bit wexec; running
this feature from an x64-compiled wexec would flip that (the register
offsets below already branch on __word_size__), but that build is not
part of the default toolchain today. Multi-threaded tracees are also out
of scope: only the initially traced thread's syscalls are seen (no
PTRACE_O_TRACECLONE), which is fine for wexec's own steps (statically
linked, single-threaded W binaries and ordinary Unix tools).

Filter (documented per the issue's request, applied in wtr_is_noise
before a read is ever checked against the declared set or reported):

  - /proc/**, /sys/**, /dev/**            -- self-introspection and
                                             device nodes, never a build
                                             input.
  - /lib/**, /lib64/**, /usr/lib/**,
    /etc/ld.so*                            -- the dynamic loader: W
                                             binaries are statically
                                             linked and never touch
                                             these, but a step that
                                             shells out to a real
                                             dynamically linked tool
                                             (cp, diff, sh, ...) does.
  - /usr/lib/locale/**, /usr/share/locale/**,
    /etc/localtime                         -- locale/timezone data the
                                             same external tools may
                                             read.
  - bin/**                                 -- this repository's own
                                             build output directory: a
                                             compiler or test binary
                                             reading back a file it (or
                                             an earlier step in the same
                                             target) just produced is
                                             not an external dependency
                                             leak, it's the build working
                                             as intended.
  - the step's own resolved program path   -- covers a tool that
                                             explicitly reopens argv[0]
                                             (rather than going through
                                             /proc/self/exe, already
                                             covered above).

Report format: for each step, one NDJSON line per distinct file read
during that step (in discovery order), `{"file": "...", "declared":
true|false}`, followed by a `wexec: trace summary: N read, M undeclared`
line once every step has run. `--hermetic` turns a nonzero M into a
nonzero process exit; without it the trace always exits 0 as long as
every step's command itself exited 0 (a step that fails for its own
reasons still fails the trace either way).

Scope of what a step "does" under trace: only "cmd" runs, with stdio
inherited directly (so a traced program's own stdout/stderr interleave
with the NDJSON lines exactly as they are produced -- fine for a
read-only audit, since nothing here needs to capture and re-check them).
"stdin", "stdout_file", "stderr_file", "timeout_ms" and the expect_stdout,
expect_stderr, reject_stdout, reject_stderr assertions wexec_run_step
(wexec.w) implements for a normal run are not honored here -- this is a
read-only audit mode, not a substitute
for a normal `wexec <target>` run, so a target chain that depends on a
prior step's "stdout_file" artifact (or whose correctness the assertions
were guarding) can fail differently under --trace than it does normally.
Tracing such a target is still useful up to the step that needs the
missing behavior; simpler steps (most compile-and-run targets) are
unaffected.
*/
import lib.lib
import lib.env
import lib.process
import lib.stream
import lib.utf8
import structures.string
import structures.json


/* --- ptrace request numbers and register layout (see the module doc
above; cross-checked against debugger/attach.w's at_* constants and
at_print_registers offsets, kept as an independent copy here). --- */

int wtr_TRACEME():
	return 0
int wtr_PEEKDATA():
	return 2
int wtr_GETREGS():
	return 12
int wtr_SYSCALL():
	return 24


int wtr_off_syscall_nr():
	if (__word_size__ == 8):
		return 120  /* orig_rax: index 15 */
	return 44  /* orig_eax: index 11 */

int wtr_off_return():
	if (__word_size__ == 8):
		return 80  /* rax: index 10 */
	return 24  /* eax: index 6 */

int wtr_off_arg1():
	if (__word_size__ == 8):
		return 112  /* rdi: index 14 */
	return 0  /* ebx: index 0 */

int wtr_off_arg2():
	if (__word_size__ == 8):
		return 104  /* rsi: index 13 */
	return 4  /* ecx: index 1 */

int wtr_off_arg3():
	if (__word_size__ == 8):
		return 96  /* rdx: index 12 */
	return 8  /* edx: index 2 */


int wtr_open_nr():
	if (__word_size__ == 8):
		return 2
	return 5

int wtr_openat_nr():
	if (__word_size__ == 8):
		return 257
	return 295


/* --- register + memory access on the traced child --- */

int wtr_regs      /* user_regs_struct scratch, GETREGS'd fresh per stop */
int wtr_wordbuf   /* one peeked word, read back byte-wise (see wtr_read_cstring) */


void wtr_getregs(int pid):
	sys_ptrace(wtr_GETREGS(), pid, 0, wtr_regs)


int wtr_reg(int offset):
	return load_word(cast(char*, wtr_regs + offset))


# Peek one word at addr in pid's memory into wtr_wordbuf. Returns 0 when
# the address is unmapped (mirrors debugger/attach.w's at_read_word).
int wtr_peek(int pid, int addr):
	int r = sys_ptrace(wtr_PEEKDATA(), pid, addr, wtr_wordbuf)
	if ((r < 0) && (r >= -4095)):
		return 0
	return 1


# NUL-terminated string at a child address, peeked a word at a time and
# copied out in raw byte order -- tracer and tracee run on the same
# little-endian x86/x86-64 hardware, so wtr_wordbuf's bytes already match
# memory order and need no shifting, unlike wtr_reg's load_word (which
# reconstructs a machine int for arithmetic use). Bounded to a generous
# path length so a corrupt or unmapped pointer cannot spin forever;
# always NUL-terminated, possibly truncated when the bound is hit or a
# peek fails partway through.
char* wtr_read_cstring(int pid, int addr):
	int cap = 256
	char* buf = malloc(cap)
	int len = 0
	int offset = 0
	int done = 0
	while ((done == 0) && (len < 4096)):
		if (wtr_peek(pid, addr + offset) == 0):
			done = 1
		else:
			char* wb = cast(char*, wtr_wordbuf)
			int k = 0
			while ((k < __word_size__) && (done == 0)):
				char b = wb[k]
				if ((len + 1) >= cap):
					int old_cap = cap
					cap = cap * 2
					buf = realloc(buf, old_cap, cap)
				buf[len] = b
				len = len + 1
				if (b == 0):
					done = 1
				k = k + 1
			offset = offset + __word_size__
	if ((len == 0) || (buf[len - 1] != 0)):
		if ((len + 1) >= cap):
			int old_cap = cap
			cap = cap + 1
			buf = realloc(buf, old_cap, cap)
		buf[len] = 0
	return buf


/* --- wait4 status decoding (mirrors lib/process.w's process_decode_status
and debugger/attach.w's at_status_* helpers; kept local so this module
has no dependency on either). --- */

int wtr_status_exited(int status):
	return (status & 127) == 0

int wtr_status_signalled(int status):
	int s = status & 127
	return (s != 0) && (s != 127)

int wtr_status_stopsig(int status):
	return (status >> 8) & 255

int wtr_decode_status(int status):
	int sig = status & 127
	if (sig == 0):
		return (status >> 8) & 255
	return 128 + sig


/* --- path normalization ---
The compiler resolves every import through an absolute path derived from
getcwd() before opening it (compiler/compiler.w), so a traced compile
step's opens arrive as absolute paths even though the manifest's
"inputs"/deps-closure entries (and the noise filter's "bin/" rule) are
all repo-relative -- wexec, and everything it forks, always runs with
its cwd at the repository root. Stripping that one prefix here, once,
keeps both the noise filter and the declared-set lookup working against
the same repo-relative spelling manifests already use, without needing
to know which syscalls do or don't resolve to absolute paths internally. */

char* wtr_cwd_prefix   # memoized "<cwd>/"; "" when getcwd fails


char* wtr_get_cwd_prefix():
	if (wtr_cwd_prefix == 0):
		char* buf = malloc(4096)
		int n = getcwd(buf, 4096)
		if (n < 0):
			buf[0] = 0
		string_builder* s = string_new()
		string_append(s, buf)
		string_append_char(s, '/')
		free(buf)
		wtr_cwd_prefix = s.data
		free(s)
	return wtr_cwd_prefix


char* wtr_normalize_path(char* path):
	char* prefix = wtr_get_cwd_prefix()
	if (prefix[0] == 0):
		return path
	if (starts_with(path, prefix)):
		return path + strlen(prefix)
	return path


/* --- the noise filter (see the module doc for the rule list) --- */

int wtr_is_noise(char* path, char* program):
	if (starts_with(path, c"/proc/")):
		return 1
	if (starts_with(path, c"/sys/")):
		return 1
	if (starts_with(path, c"/dev/")):
		return 1
	if (starts_with(path, c"/lib/") || starts_with(path, c"/lib64/") || starts_with(path, c"/usr/lib/")):
		return 1
	if (starts_with(path, c"/etc/ld.so")):
		return 1
	if (starts_with(path, c"/usr/share/locale/") || starts_with(path, c"/usr/lib/locale/")):
		return 1
	if (strcmp(path, c"/etc/localtime") == 0):
		return 1
	if (starts_with(path, c"bin/")):
		return 1
	if (strcmp(path, program) == 0):
		return 1
	return 0


# A leading "./" is tolerated on the observed path (some tools add one)
# but not otherwise normalized -- an openat against a non-AT_FDCWD
# directory fd, or a path reached through a symlink, may not textually
# match a manifest-declared path even when it refers to the same file;
# documented limitation, not attempted here.
int wtr_is_declared(map[char*, int] declared, char* path):
	if (declared.get(path, 0)):
		return 1
	if (starts_with(path, c"./")):
		if (declared.get(path + 2, 0)):
			return 1
	return 0


int wtr_hex_digit(int value):
	if (value < 10):
		return '0' + value
	return 'a' + value - 10


void wtr_json_escape(string_builder* s, char* text):
	string_append_char(s, '"')
	int i = 0
	while (text[i] != 0):
		int ch = text[i] & 255
		if (ch == '"'):
			string_append(s, c"\\\"")
		else if (ch == 92):
			string_append(s, c"\\\\")
		else if (ch == 10):
			string_append(s, c"\\n")
		else if (ch < 32):
			string_append(s, c"\\u00")
			string_append_char(s, wtr_hex_digit(ch >> 4))
			string_append_char(s, wtr_hex_digit(ch & 15))
		else:
			string_append_char(s, ch)
		i = i + 1
	string_append_char(s, '"')


void wtr_report_read(char* path, int is_declared):
	string_builder* line = string_new()
	string_append(line, c"{\"file\": ")
	wtr_json_escape(line, path)
	string_append(line, c", \"declared\": ")
	if (is_declared):
		string_append(line, c"true")
	else:
		string_append(line, c"false")
	string_append_char(line, '}')
	wstream* out = stdout_writer()
	stream_write_line(out, line.data)
	stream_flush(out)
	string_free(line)


void wtr_error(char* message):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wexec: error: ")
	stream_write_line(err, message)
	stream_flush(err)


# Unix-only PATH lookup for argv[0] (trace mode is Linux-only, so this
# is a trimmed copy of wexec_resolve_program's non-Windows branch rather
# than a shared import).
char* wtr_resolve_program(char* name):
	int i = 0
	while (name[i] != 0):
		if (name[i] == '/'):
			return name
		i = i + 1
	char* path = env_get(c"PATH")
	if (path == 0):
		path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	while (at_end == 0):
		string_clear(candidate)
		while ((path[p] != ':') && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length > 0):
			string_append_char(candidate, '/')
			string_append(candidate, name)
			int fd = open(candidate.data, 0, 0)
			if (fd >= 0):
				close(fd)
				return candidate.data
	string_free(candidate)
	return name


char** wtr_build_argv(json_value* cmd):
	int n = json_array_length(cmd)
	char** argv = strv_new(n)
	int i = 0
	while (i < n):
		json_value* piece = json_array_get(cmd, i)
		char* text = c""
		if (piece.type == json_type_string()):
			text = piece.string_value
		strv_set(argv, i, text)
		i = i + 1
	return argv


void wtr_echo_command(char** argv, int count):
	string_builder* line = string_new()
	string_append(line, c"$")
	int i = 0
	while (i < count):
		string_append(line, c" ")
		string_append(line, strv_get(argv, i))
		i = i + 1
	wstream* out = stdout_writer()
	stream_write_line(out, line.data)
	stream_flush(out)
	string_free(line)


# Runs one step's argv under ptrace (see the module doc for the fork +
# PTRACE_TRACEME + execve dance and the syscall-entry/exit alternation).
# `seen` dedupes repeat opens of the same path within this one step;
# `undeclared_out`/`total_out` accumulate the distinct-file counts the
# caller folds into the target's summary line. Returns the decoded exit
# status (shell convention: 128 + signum for a signal death), or -1 when
# the fork itself failed.
int wtr_trace_step(char** argv, map[char*, int] declared, map[char*, int] seen, int* undeclared_out, int* total_out):
	char* program = wtr_resolve_program(strv_get(argv, 0))
	int pid = fork()
	if (pid < 0):
		return -1
	if (pid == 0):
		sys_ptrace(wtr_TRACEME(), 0, 0, 0)
		char** envp = env_current()
		execve(program, argv, envp)
		exit(127)

	if (wtr_regs == 0):
		wtr_regs = cast(int, malloc(512))
	if (wtr_wordbuf == 0):
		wtr_wordbuf = cast(int, malloc(16))

	int status = 0
	wait4(pid, &status, 0, 0)  # post-execve SIGTRAP stop, or an early exit(127)

	int pending_sig = 0
	int in_syscall = 0    # 0: the next syscall-stop is expected to be an entry
	int pending_nr = -1   # syscall number recorded at the matching entry
	int have_pending = 0
	char* pending_path = 0
	int pending_wants_read = 0

	while ((wtr_status_exited(status) == 0) && (wtr_status_signalled(status) == 0)):
		sys_ptrace(wtr_SYSCALL(), pid, 0, pending_sig)
		pending_sig = 0
		wait4(pid, &status, 0, 0)
		if (wtr_status_exited(status) || wtr_status_signalled(status)):
			break
		int sig = wtr_status_stopsig(status)
		if (sig != 5):
			# A real signal, not our syscall-stop trap: hold it for
			# redelivery on the next resume; the entry/exit toggle is
			# unaffected since no syscall-stop happened this time.
			if (sig != 19):
				pending_sig = sig
			continue
		wtr_getregs(pid)
		int nr = wtr_reg(wtr_off_syscall_nr())

		# Ptrace guarantees strict entry/exit alternation for ordinary
		# syscalls, but a syscall interrupted and restarted by a signal
		# (common here: SIGCHLD from wexec's own worker children landing
		# mid-wait4/poll when the traced step is itself a build-tool
		# process) can leave our toggle expecting an exit that never
		# comes -- the next stop is a fresh entry instead. Detect that by
		# checking the syscall number the kernel still reports (orig_eax/
		# orig_rax is not cleared at exit) against what entry recorded;
		# a mismatch means "not the exit we expected", so treat this stop
		# as an entry instead of misreading whatever registers are live
		# at "exit" of an unrelated syscall (that path previously showed
		# up as spurious {"file": "", ...} entries from an invalid
		# pointer read).
		if ((in_syscall == 1) && (nr != pending_nr)):
			if (have_pending):
				free(pending_path)
				pending_path = 0
				have_pending = 0
			in_syscall = 0

		if (in_syscall == 0):
			pending_nr = nr
			have_pending = 0
			if ((nr == wtr_open_nr()) || (nr == wtr_openat_nr())):
				int path_ptr = 0
				int flags = 0
				if (nr == wtr_open_nr()):
					path_ptr = wtr_reg(wtr_off_arg1())
					flags = wtr_reg(wtr_off_arg2())
				else:
					path_ptr = wtr_reg(wtr_off_arg2())
					flags = wtr_reg(wtr_off_arg3())
				pending_path = wtr_read_cstring(pid, path_ptr)
				pending_wants_read = (flags & 3) != 1  # O_ACCMODE != O_WRONLY
				have_pending = 1
			in_syscall = 1
		else:
			if (have_pending):
				int rv = wtr_reg(wtr_off_return())
				# Normalized in place; norm points inside pending_path's
				# own allocation (a plain offset, no copy), so it must be
				# used before pending_path is freed below. Only the map
				# key handed to `seen` needs its own clone to outlive it.
				char* norm = wtr_normalize_path(pending_path)
				if ((strlen(norm) > 0) && (rv >= 0) && pending_wants_read && (wtr_is_noise(norm, program) == 0)):
					if (seen.get(norm, 0) == 0):
						seen[strclone(norm)] = 1
						*total_out = *total_out + 1
						int declared_ok = wtr_is_declared(declared, norm)
						if (declared_ok == 0):
							*undeclared_out = *undeclared_out + 1
						wtr_report_read(norm, declared_ok)
				free(pending_path)
				pending_path = 0
				have_pending = 0
			in_syscall = 0

	if (have_pending):
		free(pending_path)
	return wtr_decode_status(status)


# Entry point called from wexec.w's wexec_trace_cmd. `declared` is the
# caller-computed input set (wexec_trace_collect_declared: explicit
# "inputs" plus, when available, the deps-driven compile-root closures --
# exactly what wexec_cache_key already treats as this target's
# cache-relevant inputs). Returns 0 on a clean trace (every step exited
# 0); with hermetic set, a trace with any undeclared reads also returns
# nonzero. A step that itself exits nonzero always fails the trace.
int wexec_trace_run(char* target_name, json_value* target, map[char*, int] declared, int hermetic):
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wexec: trace ")
	stream_write_line(out, target_name)
	stream_flush(out)

	json_value* steps = json_object_get(target, c"steps")
	int step_count = 0
	if (steps != 0):
		if (steps.type == json_type_array()):
			step_count = json_array_length(steps)
	if (step_count == 0):
		stream_write_line(out, c"  (no steps to trace)")
		stream_flush(out)
		return 0

	int total = 0
	int undeclared = 0
	int s = 0
	while (s < step_count):
		json_value* step = json_array_get(steps, s)
		json_value* cmd = json_object_get(step, c"cmd")
		if ((cmd == 0) || (cmd.type != json_type_array()) || (json_array_length(cmd) < 1)):
			wtr_error(cstr(f"target '{target_name}' step {s + 1}: \"cmd\" is missing or not a non-empty array"))
			return 1
		int argc = json_array_length(cmd)
		char** argv = wtr_build_argv(cmd)
		wtr_echo_command(argv, argc)
		map[char*, int] seen = new map[char*, int]
		int step_total = 0
		int step_undeclared = 0
		int decoded = wtr_trace_step(argv, declared, seen, &step_undeclared, &step_total)
		free(cast(char*, argv))
		if (decoded < 0):
			wtr_error(cstr(f"target '{target_name}' step {s + 1}: failed to spawn command under ptrace"))
			return 1
		total = total + step_total
		undeclared = undeclared + step_undeclared
		if (decoded != 0):
			wtr_error(cstr(f"target '{target_name}' step {s + 1}: command failed with exit status {decoded}"))
			return 1
		s = s + 1

	string_builder* summary = string_new()
	string_append(summary, c"wexec: trace summary: ")
	string_append_int(summary, total)
	string_append(summary, c" read, ")
	string_append_int(summary, undeclared)
	string_append(summary, c" undeclared")
	stream_write_line(out, summary.data)
	stream_flush(out)
	string_free(summary)

	if (hermetic && (undeclared > 0)):
		return 1
	return 0
