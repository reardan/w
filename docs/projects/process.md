# Process Management Stdlib

Status: **implemented** (`lib/process.w`, `lib/env.w`, plus syscall
wrappers in `lib/__arch__/{x86,x64}/syscalls.w`).

Motivation: `docs/projects/ai_tooling.md` had to put the MCP server in
Python because `lib/` had no fork/exec/wait wrappers. This module closes
that gap so a W-native MCP server, LSP host or test runner can spawn and
supervise subprocesses with pipes, timeouts, and environment/cwd control.

## Layers

1. **Syscall wrappers** (both arch modules, same names, per-arch numbers):
   `fork`, `execve`, `wait4`, `pipe`, `dup2`, `kill`, `chdir`, `getpid`,
   `nanosleep`, `poll`, `clock_gettime`. As with the rest of the wrapper
   set, callers stay arch-agnostic; only the numbers differ. Note that the
   runtime is auto-imported into every program, so these names are global:
   `tests/dynamic_test.w` had to switch its libc probe from `getpid` to
   `getppid` when the wrapper claimed the symbol.
2. **Environment** (`lib/env.w`): `_main` in `lib/lib.w` captures the
   kernel envp vector — it sits immediately after argv's NULL terminator
   on the initial stack — into the `environ_ptr` global before calling
   `main`. `env_get`/`env_at`/`env_count` read it; `env_current` returns
   the raw `char**` for execve pass-through; `env_copy_with` builds a
   malloc'd copy with one variable added or replaced (entries are shared
   with the base vector, nothing mutates the parent's environment).
   Programs that define their own `_main` never populate `environ_ptr`,
   so `env_current()` returns 0 there — which execve accepts as an empty
   environment.
3. **Process API** (`lib/process.w`): see below.

## API sketch

```
char** argv = strv_new(2)              # NULL-terminated char* vector
strv_set(argv, 0, c"/bin/echo")
strv_set(argv, 1, c"hi")

spawn_options* opts = spawn_options_new()
opts.cwd = c"/tmp"                     # 0 = inherit
opts.env = env_copy_with(env_current(), c"KEY", c"value")  # 0 = inherit
opts.stdout_mode = process_pipe()      # inherit / pipe / null per stream

process* p = process_spawn(c"/bin/echo", argv, opts)   # opts may be 0
... read p.stdout_fd, write p.stdin_fd ...
int status = process_wait(p)           # or try_wait / wait_timeout
process_free(p)

# Or the one-call form a test runner wants:
process_result* r = process_run(path, argv, opts, stdin_text, timeout_ms)
# r.status, r.stdout_text/_length, r.stderr_text/_length
```

## Design decisions

### Status decoding

The wait family returns the *decoded* status: exit code `0..255` for a
normal exit, `128 + signum` for a signal death (the shell convention, so
SIGKILL reads as 137), or a negative kernel errno when the wait itself
failed. The raw wait4 status stays in `process.status`. Non-statuses use
sentinels outside the errno range (`-4095..-1`), so the three failure
kinds cannot collide: `process_status_running()` is -1000 and
`process_status_timeout()` is -1001.

### Exec failure reports as 127

The child calls `exit(127)` when `execve` (or a requested `chdir`)
fails — the shell convention for "command not found". The parent cannot
otherwise distinguish exec failure from a child that exits 127 itself; a
CLOEXEC error pipe (child writes the errno on a pipe that vanishes on a
successful exec) would disambiguate and is possible future work.

### Timeouts poll rather than use signals

`process_wait_timeout` loops WNOHANG `wait4` + 2ms `nanosleep` against a
CLOCK_MONOTONIC deadline. Signal-based timers (alarm/SIGCHLD) were
rejected because x86-64 signal handlers need an SA_RESTORER trampoline
the runtime does not provide (see the `rt_sigaction` note in
`lib/__arch__/x64/syscalls.w`). On expiry the child is *left running* so
the caller chooses between `process_kill` and more waiting;
`process_wait_or_kill` is the SIGKILL-and-reap convenience.

Deadline arithmetic uses differences (`deadline - now > 0`) so a wrapped
32-bit millisecond counter on long-uptime i386 hosts still compares
correctly.

### process_run drains with poll

The classic subprocess deadlock: the child fills its stderr pipe while
the parent blocks reading stdout (or the parent blocks writing a large
stdin while the child blocks writing output). `process_run` puts the
child's stdin (POLLOUT) and stdout/stderr (POLLIN) in one `poll` set and
services whichever is ready, writing stdin in ≤4096-byte chunks (POLLOUT
on a pipe guarantees PIPE_BUF writable bytes, so bounded writes cannot
block). The regression test pushes 256KB through `/bin/cat` — four times
the 64KB pipe buffer in each direction.

`poll`'s timeout doubles as the run deadline; on expiry the child is
SIGKILLed and the partial output is returned with
`process_status_timeout()`. A child that closes its stdio but keeps
running cannot stall the reap either: the remaining deadline budget is
applied to the final wait via `process_wait_or_kill`.

### Pipe end hygiene

`process_spawn`'s child closes the parent-side pipe ends before dup2'ing
its own (a retained stdin write end would keep the child's stdin open
forever and hang `/bin/cat`); the parent closes the child-side ends
before returning. `pipe(2)` writes two 32-bit fds on both architectures,
so the fds copy out with `load_int32` — same pattern as `socket_pair`.

### Struct layout portability

W's `int` is word-sized, which matches the kernel's `long` in `timespec`
on both targets (i386 `nanosleep`/`clock_gettime` take 32-bit fields,
x86-64 64-bit). `pollfd` is fixed-width (`int32 fd, int16 events,
int16 revents` = 8 bytes) on both, built with `save_int32`/`save_int16`.
wait4's status out-parameter is a 32-bit write into a word-sized W int,
so the wait family pre-zeroes it.

## Testing

`lib/env_test.w` and `lib/process_test.w`, wired as `env_test` /
`process_test` (x86, in `tests`) and `env_64_test` / `process_64_test`
(in `tests_x64`). Coverage: stdout capture, exit codes, stdin roundtrip,
the 256KB no-deadlock stream, stdout/stderr splitting, env and cwd
control, exec failure 127, timeout kill timing, `wait_timeout` leaving
the child running, signal decode `128 + signum`, cached reaps, manual
pipe spawns, and env vector add/replace/prefix-match semantics.

## Future work

- CLOEXEC error pipe to distinguish exec failure from a real 127 exit.
- `pidfd_open` + `poll` for wakeup-free waiting with a timeout (kernel
  5.3+), replacing the WNOHANG sleep loop.
- Process groups / `setsid` for killing whole trees under a test runner.
- A W-native `w-toolchain-mcp`, as flagged in
  `docs/projects/ai_tooling.md`.
