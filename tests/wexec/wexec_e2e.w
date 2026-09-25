/*
End-to-end driver for the procedural parts of wexec's own test targets
(tests/wexec/wexec_e2e.w.wbuild declares wexec_test, wexec_lock_test,
wexec_timeout_test, wexec_group_kill_test and wexec_exec_diag_test). It
replaced their inline `sh -c` steps (issue #323: no shell scripts): the
cases below need environment edits (PATH, WEXEC_LOCK_FILE,
WEXEC_LOCK_HELD, WEXEC_STEP_TIMEOUT_MS), background processes, signals
or executable scratch files, which single argv build steps cannot
express. Every child is spawned through lib/process.w with an argv
vector -- no /bin/sh.

Usage (from the repository root, after bin/wexec is built):
  <driver> xok              PATH lookup skips non-executable shadows
  <driver> lock             bin/.wexec_lock acquire / stale reclaim / reentrancy
  <driver> timeout          WEXEC_STEP_TIMEOUT_MS default step timeout
  <driver> group_kill       timeout / SIGTERM kill the whole process group
  <driver> exec_diag_setup  write the exec-failure fixtures under
                            bin/wexec_exec_diag/ (asserted by the
                            wexec_exec_diag_test steps themselves)
Each checking mode prints "wexec_<mode>: OK" on success, or a FAIL line
on stderr and exits 1.

The driver binary is also its own fixture program, so no shell script is
ever written: copied under the name wexec_xok_probe it prints the probe
line, copied as exits_127 it exits 127, and the tests/wexec/timeout.json
targets 'leaky' and 'term_hang' run it in the leaky-child / term-hang
helper modes (a background grandchild, and a process that records its
pid and hangs).

Scratch paths (the xok PATH directories, lock files) are pid-scoped
under bin/ and removed on success. The pid files the timeout.json
fixtures write are fixed paths, since that manifest is static.
*/
import lib.lib
import lib.env
import lib.process
import lib.path
import lib.file
import lib.str
import lib.dir


char* self_path
char* mode_name
list[char*] cleanup_paths


void err(char* s):
	write(2, s, strlen(s))


void cleanup():
	for char* p in cleanup_paths:
		dir_remove_all(p)


void fail(char* msg):
	err(c"wexec_")
	err(mode_name)
	err(c": FAIL: ")
	err(msg)
	err(c"\n")
	cleanup()
	exit(1)


int has(char* text, char* needle):
	if (text == 0):
		return 0
	return index_of(text, needle) >= 0


# Copy of base without any "name=" entry (unset name).
char** env_without(char** base, char* name):
	int count = env_vector_count(base)
	char* vector = malloc((count + 1) * __word_size__)
	int out = 0
	int i = 0
	while (i < count):
		char* entry = env_entry_at(base, i)
		if (env_match_name(entry, name) < 0):
			save_word(vector + out * __word_size__, cast(int, entry))
			out = out + 1
		i = i + 1
	save_word(vector + out * __word_size__, 0)
	return cast(char**, vector)


# The environment for a nested wexec that owns the scratch lock file:
# held == 0 unsets WEXEC_LOCK_HELD (so it really locks), held == 1 sets
# it (the reentrant path).
char** lock_env(char* lock_file, int held):
	char** env = env_without(env_current(), c"WEXEC_LOCK_HELD")
	if (held):
		env = env_copy_with(env, c"WEXEC_LOCK_HELD", c"1")
	return env_copy_with(env, c"WEXEC_LOCK_FILE", lock_file)


spawn_options* env_opts(char** env):
	spawn_options* opts = spawn_options_new()
	opts.env = env
	return opts


# argv for 'bin/wexec -f <manifest> <target>'.
char** wexec_argv(char* manifest, char* target):
	char** argv = strv_new(4)
	strv_set(argv, 0, c"bin/wexec")
	strv_set(argv, 1, c"-f")
	strv_set(argv, 2, manifest)
	strv_set(argv, 3, target)
	return argv


process_result* run_wexec(char* manifest, char* target, char** env):
	process_result* r = process_run(c"bin/wexec", wexec_argv(manifest, target), env_opts(env), 0, 120000)
	if (r == 0):
		fail(c"could not spawn bin/wexec")
	if (r.status == process_status_timeout()):
		fail(strjoin(c"bin/wexec timed out running ", target))
	return r


void show(process_result* r):
	err(c"--- stdout:\n")
	err(r.stdout_text)
	err(c"--- stderr:\n")
	err(r.stderr_text)


# One wexec run's assertions: want_ok (exit 0) or failure, plus up to two
# stdout substrings, one stderr substring and one rejected stderr
# substring (0 = none).
void check(char* what, process_result* r, int want_ok, char* out1, char* out2, char* err1, char* reject_err):
	int ok = 1
	if (want_ok && (r.status != 0)):
		ok = 0
	if ((want_ok == 0) && (r.status == 0)):
		ok = 0
	if ((out1 != 0) && (has(r.stdout_text, out1) == 0)):
		ok = 0
	if ((out2 != 0) && (has(r.stdout_text, out2) == 0)):
		ok = 0
	if ((err1 != 0) && (has(r.stderr_text, err1) == 0)):
		ok = 0
	if ((reject_err != 0) && has(r.stderr_text, reject_err)):
		ok = 0
	if (ok == 0):
		show(r)
		fail(what)
	process_result_free(r)


void write_file(char* path, char* text):
	if (file_write_text(path, text) == 0):
		fail(strjoin(c"cannot write ", path))


# A readable but NOT executable file (lib/file.w creates files with the
# executable bits set, so clear them explicitly).
void write_plain_file(char* path, char* text):
	write_file(path, text)
	if (chmod(path, 420) < 0):
		fail(strjoin(c"cannot chmod ", path))


# Writes length raw bytes (the ELF fixture carries NULs).
void write_bytes(char* path, char* data, int length):
	int fd = open(path, 577, 420)
	if (fd < 0):
		fail(strjoin(c"cannot create ", path))
	if (write(fd, data, length) != length):
		fail(strjoin(c"short write to ", path))
	close(fd)


void make_executable(char* path):
	if (chmod(path, 493) < 0):
		fail(strjoin(c"cannot chmod ", path))


# cp keeps the source's executable mode.
void copy_self(char* dest):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/cp")
	strv_set(argv, 1, self_path)
	strv_set(argv, 2, dest)
	process_result* r = process_run(c"/bin/cp", argv, 0, 0, 60000)
	if ((r == 0) || (r.status != 0)):
		fail(strjoin(c"cannot copy the driver to ", dest))
	process_result_free(r)
	make_executable(dest)


char* scratch(char* stem):
	return strjoin(strjoin(c"bin/", stem), itoa(getpid()))


/* xok: a PATH lookup must skip a readable but non-executable shadow and
reach the real executable behind it, and a failed lookup names what it
skipped (the old wexec_test PATH=... steps). */
void mode_xok():
	char* dir = scratch(c"wexec_xok_")
	cleanup_paths.push(dir)
	dir_remove_all(dir)
	char* shadow = path_join(dir, c"shadow")
	char* real = path_join(dir, c"real")
	mkdir(dir, 493)
	mkdir(shadow, 493)
	mkdir(real, 493)
	write_plain_file(path_join(shadow, c"wexec_xok_probe"), c"not a program\n")
	copy_self(path_join(real, c"wexec_xok_probe"))
	write_plain_file(path_join(shadow, c"wexec_xok_unusable"), c"not a program\n")
	char* old_path = env_get(c"PATH")
	if (old_path == 0):
		old_path = c"/usr/bin:/bin"
	char* new_path = strjoin(strjoin(strjoin(shadow, c":"), strjoin(real, c":")), old_path)
	char** env = env_copy_with(env_current(), c"PATH", new_path)

	check(c"probe did not run the real executable behind the shadow", run_wexec(c"tests/wexec/path_xok.json", c"probe", env), 1, c"xok probe: real executable ran", c"wexec: OK (1 targets)", 0, 0)
	char* want = strjoin(c"command failed with exit status 127: no executable 'wexec_xok_unusable' on PATH; skipped readable but non-executable ", path_join(shadow, c"wexec_xok_unusable"))
	check(c"unusable: missing skipped-shadow diagnostic", run_wexec(c"tests/wexec/path_xok.json", c"unusable", env), 0, 0, 0, want, 0)
	check(c"missing: wrong diagnostic", run_wexec(c"tests/wexec/path_xok.json", c"missing", env), 0, 0, 0, c"command failed with exit status 127: no executable 'wexec_xok_no_such_command' on PATH", c"skipped readable")


/* lock: bin/.wexec_lock acquire, live-holder refusal, stale reclaim,
release, and the WEXEC_LOCK_HELD reentrancy bypass -- against a scratch
WEXEC_LOCK_FILE, never the outer run's live lock. */
void mode_lock():
	char* lock = scratch(c".wexec_lock_scratch_")
	cleanup_paths.push(lock)
	char* manifest = c"tests/wexec/lock_scratch.json"
	char** env = lock_env(lock, 0)
	unlink(lock)

	# A live holder (pid 1 always exists) refuses the run and keeps the lock.
	write_file(lock, c"1")
	check(c"live lock holder was not refused", run_wexec(manifest, c"noop", env), 0, 0, 0, strjoin(strjoin(c"wexec: another build is running in this directory (pid 1); remove ", lock), c" if stale"), 0)
	if (path_exists(lock) == 0):
		fail(c"a refused run removed the other holder's lock")
	unlink(lock)

	# A dead holder's pid (a reaped child) is a stale lock: reclaimed,
	# the run succeeds, and the lock is released afterwards.
	char** argv = strv_new(2)
	strv_set(argv, 0, self_path)
	strv_set(argv, 1, c"exit0")
	process* p = process_spawn(self_path, argv, 0)
	if (p == 0):
		fail(c"could not spawn the dead-pid child")
	int dead_pid = p.pid
	process_wait(p)
	process_free(p)
	write_file(lock, itoa(dead_pid))
	check(c"stale lock was not reclaimed", run_wexec(manifest, c"noop", env), 1, c"lock scratch target ran", c"wexec: OK (1 targets)", 0, 0)
	if (path_exists(lock)):
		fail(c"lock not released after a successful run")

	# Acquire + release twice in a row.
	check(c"first fresh-lock run failed", run_wexec(manifest, c"noop", env), 1, c"wexec: OK (1 targets)", 0, 0, 0)
	check(c"second fresh-lock run failed", run_wexec(manifest, c"noop", env), 1, c"wexec: OK (1 targets)", 0, 0, 0)

	# WEXEC_LOCK_HELD: a nested wexec skips locking entirely and leaves
	# the (live-held) lock file alone.
	write_file(lock, c"1")
	check(c"reentrant run did not bypass the lock", run_wexec(manifest, c"noop", lock_env(lock, 1)), 1, c"wexec: OK (1 targets)", 0, 0, 0)
	if (path_exists(lock) == 0):
		fail(c"reentrant run touched the held lock")
	unlink(lock)


/* timeout: WEXEC_STEP_TIMEOUT_MS is the default for steps without their
own timeout_ms; an explicit timeout_ms (even 0) wins. */
void mode_timeout():
	char* manifest = c"tests/wexec/timeout.json"
	char** env = env_copy_with(env_current(), c"WEXEC_STEP_TIMEOUT_MS", c"300")
	check(c"default step timeout not applied", run_wexec(manifest, c"hangs_default", env), 0, 0, 0, c"target 'hangs_default' step 1: command timed out after 300 ms and was killed", 0)
	check(c"explicit timeout_ms lost to the default", run_wexec(manifest, c"slow_ok", env), 1, c"wexec: OK (1 targets)", 0, 0, c"timed out")
	check(c"explicit timeout_ms 0 lost to the default", run_wexec(manifest, c"explicit_zero", env), 1, c"wexec: OK (1 targets)", 0, 0, c"timed out")


# 1 when pid no longer runs: /proc/<pid>/stat unreadable, or a zombie.
int pid_gone(int pid):
	char* stat = file_read_text(strjoin(strjoin(c"/proc/", itoa(pid)), c"/stat"))
	if (stat == 0):
		return 1
	# The state letter follows "pid (comm) ", and comm may hold spaces.
	int close_paren = -1
	int i = 0
	while (stat[i] != 0):
		if (stat[i] == ')'):
			close_paren = i
		i = i + 1
	if (close_paren < 0):
		return 0
	return stat[close_paren + 2] == 'Z'


int read_pid_file(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		fail(strjoin(c"fixture never wrote ", path))
	int pid = atoi(text)
	if (pid <= 0):
		fail(strjoin(c"no pid in ", path))
	return pid


/* group_kill: a step timeout kills the step's whole process group (a
leaked background grandchild included), and SIGTERM to wexec itself
kills the running step's group and still releases the lock. */
void mode_group_kill():
	char* manifest = c"tests/wexec/timeout.json"
	char* leak_pid = c"bin/wexec_group_leak_pid"
	char* term_pid = c"bin/wexec_group_term_pid"
	char* lock1 = scratch(c".wexec_group_lock_")
	char* lock2 = scratch(c".wexec_group_lock2_")
	cleanup_paths.push(lock1)
	cleanup_paths.push(lock2)
	unlink(leak_pid)
	unlink(term_pid)
	unlink(lock1)
	unlink(lock2)

	check(c"leaky step did not time out", run_wexec(manifest, c"leaky", lock_env(lock1, 0)), 0, 0, 0, c"target 'leaky' step 1: command timed out after 400 ms and was killed", 0)
	process_sleep_ms(500)
	if (pid_gone(read_pid_file(leak_pid)) == 0):
		fail(c"the leaked background grandchild survived the step timeout")

	spawn_options* opts = env_opts(lock_env(lock2, 0))
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	process* p = process_spawn(c"bin/wexec", wexec_argv(manifest, c"term_hang"), opts)
	if (p == 0):
		fail(c"could not spawn bin/wexec term_hang")
	if (process_wait_timeout(p, 600) != process_status_timeout()):
		fail(c"term_hang finished before SIGTERM (expected it to hang)")
	process_kill(p, sigterm())
	process_wait(p)
	process_free(p)
	process_sleep_ms(500)
	if (pid_gone(read_pid_file(term_pid)) == 0):
		fail(c"SIGTERM to wexec left the running step alive")
	if (path_exists(lock2)):
		fail(c"SIGTERM to wexec left its lock file behind")
	unlink(leak_pid)
	unlink(term_pid)


/* exec_diag_setup: the exec-failure fixtures tests/wexec/exec_diag.json
runs. bin/wexec_exec_diag/ itself is (re)created by the target's own
rm/mkdir steps. */
void mode_exec_diag_setup():
	char* dir = c"bin/wexec_exec_diag"
	write_plain_file(path_join(dir, c"unusable"), c"not a program\n")
	char* bad_interp = path_join(dir, c"bad_interp")
	write_file(bad_interp, c"#!/no/such/interp\n")
	make_executable(bad_interp)
	copy_self(path_join(dir, c"exits_127"))
	# A minimal 32-bit ELF executable whose one program header is a
	# PT_INTERP naming /no/such/elf_interp (84 header bytes + 19 of path).
	char* elf = malloc(104)
	int i = 0
	while (i < 104):
		elf[i] = 0
		i = i + 1
	elf[0] = 127
	elf[1] = 'E'
	elf[2] = 'L'
	elf[3] = 'F'
	elf[4] = 1        # ELFCLASS32
	elf[5] = 1        # little endian
	elf[6] = 1        # EV_CURRENT
	elf[16] = 2       # e_type ET_EXEC
	elf[18] = 3       # e_machine EM_386
	elf[20] = 1       # e_version
	elf[28] = 52      # e_phoff
	elf[40] = 52      # e_ehsize
	elf[42] = 32      # e_phentsize
	elf[44] = 1       # e_phnum
	elf[52] = 3       # p_type PT_INTERP
	elf[56] = 84      # p_offset
	elf[68] = 20      # p_filesz
	elf[72] = 20      # p_memsz
	elf[76] = 4       # p_flags PF_R
	elf[80] = 1       # p_align
	char* interp = c"/no/such/elf_interp"
	i = 0
	while (interp[i] != 0):
		elf[84 + i] = interp[i]
		i = i + 1
	char* bad_elf = path_join(dir, c"bad_elf")
	write_bytes(bad_elf, elf, 104)
	make_executable(bad_elf)


int main(int argc, char** argv):
	self_path = argv[0]
	cleanup_paths = new list[char*]
	# Fixture-program personalities, chosen by the copy's name.
	char* base = path_basename(self_path)
	if (strcmp(base, c"wexec_xok_probe") == 0):
		println(c"xok probe: real executable ran")
		return 0
	if (strcmp(base, c"exits_127") == 0):
		return 127
	if (argc < 2):
		err(c"usage: wexec_e2e xok|lock|timeout|group_kill|exec_diag_setup\n")
		return 2
	mode_name = argv[1]
	if (strcmp(mode_name, c"exit0") == 0):
		return 0
	if (strcmp(mode_name, c"sleep") == 0):
		process_sleep_ms(30000)
		return 0
	if (strcmp(mode_name, c"leaky-child") == 0):
		# timeout.json 'leaky': leave a background grandchild in the step's
		# process group, record its pid, then hang in the foreground.
		char** sleeper = strv_new(2)
		strv_set(sleeper, 0, self_path)
		strv_set(sleeper, 1, c"sleep")
		process* bg = process_spawn(self_path, sleeper, 0)
		if (bg == 0):
			return 1
		write_file(argv[2], itoa(bg.pid))
		process_sleep_ms(30000)
		return 0
	if (strcmp(mode_name, c"term-hang") == 0):
		# timeout.json 'term_hang': record this pid, then hang.
		write_file(argv[2], itoa(getpid()))
		process_sleep_ms(30000)
		return 0
	if (strcmp(mode_name, c"xok") == 0):
		mode_xok()
	else if (strcmp(mode_name, c"lock") == 0):
		mode_lock()
	else if (strcmp(mode_name, c"timeout") == 0):
		mode_timeout()
	else if (strcmp(mode_name, c"group_kill") == 0):
		mode_group_kill()
	else if (strcmp(mode_name, c"exec_diag_setup") == 0):
		mode_exec_diag_setup()
	else:
		fail(c"unknown mode")
	cleanup()
	println(strjoin(strjoin(c"wexec_", mode_name), c": OK"))
	return 0
