/*
Shell helpers: run commands and capture their output, on top of
lib/process.w (spawn/pipe/wait) and lib/env.w (environment vector
access). Useful standalone for scripts and agent tooling; the REPL's `!`
escape (docs/projects/repl_improvements.md Q4/Q5) is a later consumer.

sh(cmd) runs cmd through /bin/sh -c with stdout and stderr captured
separately; run_argv(argv) does the same without a shell, executing argv
directly (no $PATH search -- argv[0] must be an absolute or otherwise
resolvable path, exactly like lib/process.w's process_run). Both return a
shell_result with the decoded exit status (lib/process.w's
process_decode_status: 0..255 for a normal exit, 128 + signum for a
signal death).

Session state: cd() calls the real chdir() syscall, so it affects the
whole process (there is no subshell). Environment writes are different:
this platform has no setenv/putenv syscall (see lib/env.w's header), so
setenv() cannot touch the real process environment lib/env.w reads.
Instead it maintains a session-local override vector that sh() and
run_argv() pass as the child's envp; getenv() consults that override when
one exists, falling back to lib/env.w's env_get otherwise. A program that
never calls setenv sees ordinary inherited-environment behavior.
*/
import lib.lib
import lib.env
import lib.process


struct shell_result:
	int status        # decoded exit status, see lib/process.w's process_decode_status
	char* out         # malloc'd stdout, NUL-terminated
	int out_length
	char* err         # malloc'd stderr, NUL-terminated
	int err_length


void shell_result_free(shell_result* r):
	free(r.out)
	free(r.err)
	free(r)


# Session-local environment override for sh()/run_argv(); 0 (the default)
# means "inherit the real process environment". Set by setenv().
char** shell_env


# spawn_options with cwd left at "inherit the real process cwd" (cd()
# already changed that for the whole process) and env set to the session
# override, if any.
spawn_options* shell_spawn_options():
	spawn_options* opts = spawn_options_new()
	opts.env = shell_env
	return opts


# Take ownership of pr's output buffers and free the rest of it.
shell_result* shell_result_from_process(process_result* pr):
	shell_result* r = new shell_result()
	r.status = pr.status
	r.out = pr.stdout_text
	r.out_length = pr.stdout_length
	r.err = pr.stderr_text
	r.err_length = pr.stderr_length
	free(pr)
	return r


# Run cmd via /bin/sh -c with stdout and stderr captured separately.
# Returns 0 only when the spawn itself failed (e.g. /bin/sh missing); a
# shell-reported error (bad syntax, nonzero exit, a signal death) still
# returns a shell_result with the decoded status.
shell_result* sh(char* cmd):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/sh")
	strv_set(argv, 1, c"-c")
	strv_set(argv, 2, cmd)
	spawn_options* opts = shell_spawn_options()
	process_result* pr = process_run(c"/bin/sh", argv, opts, 0, 0)
	free(opts)
	free(cast(void*, argv))
	if (pr == 0):
		return 0
	return shell_result_from_process(pr)


# Run argv directly, no shell: argv[0] is both the executable path
# (resolved exactly like execve -- no $PATH search) and argv's own
# program name. Returns 0 when argv is empty or the spawn itself failed.
shell_result* run_argv(list[char*] argv):
	if (argv.length == 0):
		return 0
	char** vec = strv_new(argv.length)
	int i = 0
	while (i < argv.length):
		strv_set(vec, i, argv[i])
		i = i + 1
	spawn_options* opts = shell_spawn_options()
	process_result* pr = process_run(argv[0], vec, opts, 0, 0)
	free(opts)
	free(cast(void*, vec))
	if (pr == 0):
		return 0
	return shell_result_from_process(pr)


# Change the process's working directory. Affects the whole process (no
# subshell), so it also changes what relative paths in later sh()/
# run_argv() calls -- and everything else in the program -- resolve
# against. Returns 0 on success, a negative errno on failure.
int cd(char* path):
	return chdir(path)


# Value of name as seen by sh()/run_argv(): the session override set by
# setenv() when there is one, otherwise the real process environment
# (same lookup as lib/env.w's env_get). Returns 0 when unset.
char* getenv(char* name):
	if (shell_env == 0):
		return env_get(name)
	int i = 0
	char* entry = env_entry_at(shell_env, i)
	while (entry != 0):
		int value_index = env_match_name(entry, name)
		if (value_index >= 0):
			return entry + value_index
		i = i + 1
		entry = env_entry_at(shell_env, i)
	return 0


# Set name=value in the session override that sh()/run_argv() pass to
# children from now on. Does not touch the real process environment (see
# the module comment) -- a later env_get(name) in the same process still
# reports the unmodified value.
void setenv(char* name, char* value):
	char** base = shell_env
	if (base == 0):
		base = env_current()
	shell_env = env_copy_with(base, name, value)
