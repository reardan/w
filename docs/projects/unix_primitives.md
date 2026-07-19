# Unix metadata / process primitives (wunix foundation)

Status: **partially implemented** (2026-07-19). This note covers the
underlying calls that unblock owner/group names, `cp -a`-style
cross-device moves, and `xargs -P` — without requiring NSS, and without
shipping the higher-level tools yet.

Context: the portable `lib/stat.w` stack (`statx` / `chmod` /
`utimensat` / `readlink` / `symlink`) and the `lib/process.w` spawn/wait
API already cover numeric uid/gid via `stat`, "touch now" via
`utimensat(times=0)`, and per-child `process_wait` /
`process_try_wait`. Gaps called out for a W-native unix toolset:

| Nice-to-have | Gap | Approach here |
|---|---|---|
| Owner/group names | no `getpwuid` / `getgrgid` (NSS) | Parse `/etc/passwd` + `/etc/group` in W |
| Cross-device dir mv fidelity | can't restore mtime/atime; no ownership round-trip | Explicit `utimensat` times; `fchownat` / `lchown` |
| `xargs -P` | no "wait for any of N children" helper | `process_wait_any` on top of `wait4(-1)` / try-wait |

## Layers

1. **Syscall wrappers** (`lib/__arch__/{x86,x64,arm64}/syscalls.w`;
   Darwin / win64 / wasm stub `-1`):
   - `utimensat(path, times, flags)` — already passed a pointer;
     `times == 0` means "now" for both stamps. Non-zero `times` is a
     pointer to two word-sized `timespec`s `{atime, mtime}` (same layout
     as `lib/time.w`'s `timespec`).
   - `fchownat(path, uid, gid, flags)` — Linux `*at` form; `uid`/`gid`
     of `-1` leave that id unchanged (kernel convention).
   - `chown` / `lchown` — thin wrappers (`flags = 0` /
     `AT_SYMLINK_NOFOLLOW`).
   - `getuid` / `getgid` — current real ids (i386 uses the `*32`
     variants).

2. **Portable helpers** (`lib/stat.w`):
   - `file_utimens(path, atime_sec, mtime_sec, flags)` — builds the
     two-`timespec` buffer (nsec = 0) and calls `utimensat`.
   - `file_chown` / `file_lchown`.

3. **Name database without NSS** (`lib/passwd.w`):
   - `passwd_uid_name` / `passwd_gid_name` — malloc'd name or `0`.
   - `passwd_name_uid` / `passwd_name_gid` — id or `-1` if missing.
   - Path-taking variants (`passwd_uid_name_at`, …) so tests can feed
     fixtures instead of the live `/etc` files.
   - No caching in v1; each lookup re-reads the file. Enough for `ls -l`
     / `stat` and for rare chown-by-name CLIs.

4. **Multi-child wait** (`lib/process.w`):
   - `process_wait_any(list[process*] kids, int hang)` — returns the
     index of the reaped child. Non-blocking (`hang == 0`) returns
     `process_status_running()` when none of the listed children have
     exited. Blocking path uses `wait4(-1, …)` then matches the pid
     against the list (and falls back to per-child `try_wait` when the
     reaped pid is not in the list). Windows polls `process_try_wait`.

## Non-goals (this change)

- No `cp` / `mv` / `xargs` tools — only the primitives they need.
- No NSS / `getpwnam_r` / libc linkage.
- No Darwin / win64 / wasm real implementations of the new syscalls
  (stubs stay `-1`; Linux is the dogfood target for unix tools).
- No xattr / ACL / sparse-file fidelity for `cp -a`.
- No `pidfd` / `WaitForMultipleObjects` optimization yet (see
  `docs/projects/process.md` future work).

## Testing

- `stat_test`: explicit `file_utimens` round-trip; `file_chown` to
  current uid/gid (no privilege escalation required).
- `passwd_test`: fixture files under `bin/passwd_test_work/` covering
  hits, misses, and gid/uid cross-lookups.
- `process_test`: two children, blocking `wait_any` reaps the faster
  one first; non-blocking returns `process_status_running()` while both
  live.

## Follow-ups

- Wire owner/group names into `tools/stat.w` / a future `ls -l`.
- Recursive copy helper that restores mode + mtime (+ optional chown)
  for cross-device `mv`.
- `xargs -P` on `process_spawn` + `process_wait_any`.
- Optional in-process passwd/group cache if lookup volume warrants it.
