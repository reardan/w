# Cloud Agent environment setup — status / WIP notes

Status: **in progress** (2026-07-09). Environment is working end-to-end
(build, verify, full `tests`, lint, REPL, compile/run) but the bootstrap
needs a non-obvious workaround for a seed bug that only manifests on the
current Cloud VM kernel. This file records the investigation, the
workaround now encoded in the startup update script, and the follow-ups.

## Symptom

On the Cursor Cloud VM (kernel `6.12.94`, x86_64, default `ulimit -s`
= 8192 KB) the committed 32-bit seed `./w` **segfaults** while compiling
`w.w`, so a cold `./wbuild build` / `verify` / `tests` dies immediately:

```
$ ./wbuild build
Segmentation fault (core dumped)      # ./w w.w -o bin/wv2
```

Trivial programs compile fine with the seed (`./w tests/hello.w -o h`),
so the seed can run — only the large self-host compile faults.

## Root cause (as far as run without a debugger/strace on the VM)

The seed's heap grows via `brk` (syscall 45; see `lib/__arch__/x86/syscalls.w`).
The fault tracks `RLIMIT_STACK`, not the source:

| `ulimit -s`        | seed compiling `w.w`                                        |
|--------------------|-------------------------------------------------------------|
| 8 MB (default)     | SIGSEGV, 0 bytes stderr                                      |
| 16–256 MB (finite) | SIGSEGV, 0 bytes stderr                                      |
| `unlimited`        | exit 0, **valid `bin/wv2`**, but floods ~2.46 GB of NUL bytes to stderr |

`setarch -L/-B/-3/--addr-compat-layout` (legacy VA layout) do **not**
help; only `ulimit -s unlimited` does. The NUL flood is a bug in the
*old seed* — a freshly built `wv2` compiles `w.w` cleanly at the default
8 MB stack (16 bytes of normal stderr, no flood, no fault), and the whole
downstream toolchain runs fine at the default stack. So the problem is
confined to the committed seed binary interacting with this kernel's
memory layout.

## Why `./wbuild` can't just run the seed under `unlimited`

`./wbuild` → `bin/wexec` runs the `wv2` target (`./w w.w -o bin/wv2`) and
**captures** the child's stdout/stderr into memory (`process_run` in
`lib/process.w`, doubling buffer). `bin/wexec` is itself a 32-bit binary,
so it cannot buffer the ~2.46 GB NUL flood in its <4 GB address space: the
capture realloc fails and the seed step dies with a non-zero status.
Result: even with `ulimit -s unlimited`, `./wbuild` fails at the `wv2`
step. A direct `./w w.w -o bin/wv2 2>/dev/null` (flood to a regular
file/`/dev/null`, no in-process capture) succeeds.

`wexec` has no "mark target fresh" flag (`-f`, `--list`, `--no-cache`,
`-j` only — see `main()` in `tools/wexec.w`), so the cache stamp can only
be created by a successful run of the target.

## Workaround (encoded in the Cloud startup update script)

`./w` is **not** an input of the `wv2` wexec target (its inputs are
`w.w`, `compiler/`, `grammar/`, `code_generator/`, `lib/`, `structures/`,
`libs/`, `debugger/`), so the content-hash cache key does not depend on
the seed's bytes. That lets us prime the stamp with a good compiler and
then restore the committed seed:

```sh
ulimit -s unlimited
mkdir -p bin
[ -x bin/wv2 ]   || ./w w.w -o bin/wv2 2>/dev/null          # seed bootstrap, flood discarded
[ -x bin/wexec ] || ./bin/wv2 tools/wexec.w -o bin/wexec 2>/dev/null
if [ ! -f bin/.wexec_cache/wv2 ]; then
  cp bin/wv2 w                       # temporarily stand the good compiler in as ./w
  ./bin/wexec wv2 wexec >/dev/null 2>&1 || true   # succeeds under the pipe → writes stamps
  git checkout -- w                  # restore the committed seed (self-healing on interruption)
fi
```

After this, `bin/.wexec_cache/{wv2,wexec}` exist, `git status` is clean,
and every subsequent `./wbuild <target>` runs at the **default** 8 MB
stack because the `wv2` target is a cache hit and the seed is never run
again (freshly built `wv2` has no stack/flood problem).

`git checkout -- w` (rather than a backup copy) makes the prime block
self-healing: if a run is interrupted after `cp bin/wv2 w`, the next run
re-primes and restores from the committed blob regardless.

## Other environment gap found

`libc6:i386` (the 32-bit loader `/lib/ld-linux.so.2`) was **missing** on
the VM, so `dynamic_test`, `c_import_test`, and `c_import_errno_test`
failed with exit 127. AGENTS.md already says this must be baked into the
VM snapshot, not reinstalled on every startup. Installed once during
setup:
`sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install -y libc6:i386`.

## Verified working (default 8 MB stack, after the update script runs)

- `./wbuild verify` — self-host fixpoint `wv3 == wv4 == wv5`.
- `./wbuild tests` — `wexec: OK (186 targets)`.
- `./wbuild warning_test` (lint) — OK.
- REPL: `./bin/wv2 repl.w -o bin/repl && ./bin/repl` (defined `factorial`,
  `factorial(6)` → `720`).
- Compile/run x86 + x64 of an ad-hoc program.

## Follow-ups / open questions

- [ ] Confirm the update script runs correctly on a genuinely fresh pod
      (cold `rm -rf bin`) in the real Cloud pipeline, not just a local
      `rm -rf bin` here.
- [ ] Get `libc6:i386` (and, per AGENTS.md, `qemu-user-static` /
      `binutils-aarch64-linux-gnu` / `wine`) baked into the VM snapshot so
      the update script stays network-free. Owner action.
- [ ] Decide whether to promote a flood-free seed via `./wbuild update`
      (the flood is an old-seed bug; a current `bin/wv2` does not flood).
      That would remove the need for the `unlimited`-stack bootstrap
      entirely, but changes the committed binary and is out of scope for
      env setup — tracked as its own decision.
- [ ] File the GitHub issue below (agent `gh` is read-only; could not
      create it automatically).

## Proposed GitHub issue

> **Title:** Committed 32-bit seed `./w` segfaults compiling `w.w` at the
> default 8 MB stack on kernel 6.12 (Cursor Cloud), breaking cold
> `./wbuild`
>
> **Body:**
> On the Cursor Cloud VM (Linux `6.12.94`, x86_64, `ulimit -s` = 8192)
> the committed seed `./w` segfaults compiling `w.w`, so a cold
> `./wbuild build`/`verify`/`tests` fails at the first step. The seed
> compiles small programs fine. Behavior is `RLIMIT_STACK`-dependent:
> finite stack → SIGSEGV; `ulimit -s unlimited` → produces a valid
> `bin/wv2` but floods ~2.46 GB of NUL bytes to stderr. `setarch`
> legacy-layout personalities do not help.
>
> Because `bin/wexec` is 32-bit and captures child output in memory, it
> cannot absorb the NUL flood, so `./wbuild` fails even under
> `unlimited`. A freshly built `wv2` compiles `w.w` cleanly at the
> default stack with no flood, so the bug is specific to the old seed
> binary + this kernel.
>
> Workaround now in the Cloud startup script: bootstrap `bin/wv2`
> directly under `ulimit -s unlimited` (flood → `/dev/null`), then prime
> the `wexec` `wv2`/`wexec` cache stamps by temporarily standing the good
> compiler in as `./w` and restoring it with `git checkout -- w`.
>
> Proper fixes to consider: (1) promote a current, flood-free seed via
> `./wbuild update`; (2) investigate the seed's `brk`/stderr behavior
> under a constrained stack so it degrades gracefully; (3) have `wexec`
> stream/bound step capture instead of buffering unboundedly in a 32-bit
> process.
>
> Also: `libc6:i386` was missing on the VM (needed by the dynamic-link
> tests); it should be baked into the snapshot per AGENTS.md.
