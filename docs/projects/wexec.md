# wexec: the W-native build executor

Goal: replace the Makefile with a build system written in W itself. The
chosen shape (out of the designs considered) is a two-layer, Ninja-like
split: a static JSON manifest describes targets, and a small, dumb
executor written in W runs them. The manifest stays trivially parseable
and analyzable; the executor core stays small enough to trust while
being compiled by the toolchain it is building.

## Pieces

- `tools/wexec.w` — the executor. Loads a manifest, collects the
  requested dependency closure (with cycle detection), and schedules
  targets across up to `-j` concurrent workers. Each step runs as a
  child process via `lib/process.w`'s `process_run`, so stdout/stderr
  are captured, stdin can be fed from the manifest, and timeouts are
  enforced without any shell.
- `build.json` — the manifest at the repository root. Every
  prerequisite of the Makefile's `tests` aggregate is ported (plus
  `tests_x64`, the toolchain targets `wv2`/`build`/`verify`/`wdbg`/
  `wtest`/`wmcp`, and `wexec` itself), so `./wbuild tests` runs the
  full suite.
- `wbuild` — the bootstrap script, the only shell in the path. On a
  cold tree (`bin/wexec` missing) it seed-compiles the compiler and
  the executor; on a warm tree it runs the manifest's cached `wv2` and
  `wexec` targets (rebuilding either only when their input hashes
  changed) and then execs `bin/wexec "$@"`. Everything after that is
  manifest-driven. `rm -rf bin` resets the world.

## Manifest format

The root object has optional `"dirs"` (created with mkdir before any
target runs; `bin/` lives here because it is gitignored) and a
`"targets"` array. Each target: `"name"`, optional `"deps"` (names run
first), optional `"steps"`, and the optional caching fields `"inputs"`
and `"outputs"` described below. Each step:

- `"cmd"` — argv array, required. `argv[0]` is resolved against PATH
  when it contains no slash (execve does no lookup itself).
- `"stdin"` — text piped to the child.
- `"expect_stdout"` / `"expect_stderr"` — substring (or array of
  substrings) the captured stream must contain; replaces the
  Makefile's `| grep -q` pipelines, arrays replacing repeated greps
  of one command's output.
- `"reject_stdout"` / `"reject_stderr"` — substring(s) that must NOT
  appear; replaces `! grep -q`.
- `"expect_fail"` — step must exit nonzero; replaces Make's `! cmd`.
- `"expect_status"` — step must exit with this exact code; replaces
  `cmd; test $? -eq N`.
- `"stdout_file"` / `"stderr_file"` — save the captured stream to a
  path; replaces `> file` redirects and lets `grep -qE` regex checks
  and `diff -u` comparisons run as ordinary follow-up steps.
- `"timeout_ms"` — per-step timeout, 0/absent = none.

Execution model: targets run at most once per invocation. Steps run
sequentially within a target; the first failing target stops new
launches, in-flight targets drain, and the run exits 1 (make without
`-k`).

## Caching

A target that declares `"inputs"` (files, or directory prefixes ending
in `/` that are walked recursively with getdents) is cached by content
hash: a 64-bit rolling hash over the serialized target definition, the
dependencies' cache keys and every input file's contents. After a
successful run the key is stamped into `bin/.wexec_cache/<name>`; a
later invocation whose key matches the stamp — and whose declared
`"outputs"` files all exist — skips the target and prints
`wexec: target <name> (cached)`.

Targets without `"inputs"` keep the Makefile's FORCE semantics and
always run. A target whose dependency has no cache key is itself never
cacheable (the dependency's fresh run may have changed anything), so
an `"inputs": []` target caches purely on its definition and its
dependencies' keys — that is how `build` and `verify` piggyback on
`wv2`'s source hash. `--no-cache` forces every target to run.

## Parallelism

The requested closure is collected depth-first up front (unknown
targets and dependency cycles are diagnosed before anything runs),
then targets whose dependencies have finished are launched oldest
first, up to `-j N` in flight (`-jN` also accepted; the default is one
per online CPU, and `-j 1` reproduces the serial behavior). Each
launched target is a forked wexec worker with its stdout/stderr on
pipes; the parent drains all pipes with one poll loop and prints each
target's output in start order — the oldest in-flight worker streams
live, later workers stay buffered until they reach the head — so
parallel logs never interleave. Cache keys are computed and stamps
written only by the parent; cache hits and step-less aggregate targets
complete inline without forking.

## Lessons already encoded

- A target that rebuilds a running executable (the `wexec` target
  rebuilding `bin/wexec`) must compile to a staging path and `mv` it
  into place: opening the running binary for write fails with ETXTBSY.
- The seed supports `-o`, so nothing needs the Makefile's
  `> file && chmod +x` redirect dance; wexec has no shell redirection
  on purpose.
- Parallel targets must not share scratch paths: `lib_64_test` writes
  `bin/lib_64_test` (the Makefile reused `bin/lib_test`), and
  `wexec_test` depends on `hello` because its end-to-end check
  rebuilds `bin/hello`.
- A worker's pipe write ends must be closed in the parent immediately
  after fork, or a sibling forked later would inherit them and delay
  the first worker's EOF.

## Testing

`make wexec_test` (part of `make tests`, and ported as the manifest's
`wexec_test` target) compiles the executor and drives it over the
fixture manifests in `tests/wexec/` (dependency order, run-once
semantics, `--list`, failing steps, `expect_fail`, missing-substring
failures, unknown targets, cycles, invalid JSON, missing manifest,
no-argument usage in `good.json`/`bad.json`; the extended step fields
in `features.json`; cache hits, misses on changed inputs or missing
outputs and `--no-cache` in `cache.json`; branch overlap under a
wall-clock bound, `-j 1` serialization and failure propagation in
`parallel.json`) and then runs the real `build.json` `hello` target
end to end. `tools/test_map.w` maps executor/manifest/fixture changes
to `wexec_test`.

## Makefile removal plan

Goal: delete the Makefile once `./wbuild`/`build.json` covers every target
anyone still runs, and every doc/tool that currently says `make X` says
`./wbuild X` instead. This section is the tracking checklist; each step
below should land as its own commit rather than as one large migration.

### Gap, measured

Diffing the Makefile's target names against build.json's `"name"` fields
(147 Makefile targets, 176 in build.json) finds 34 Makefile targets with
no build.json counterpart. They split into four groups:

**A. Toolchain targets** — `w`, `update`, `test_changed`.
- `w` (builds `bin/wv2` from the seed) isn't actually a gap: `wbuild`'s own
  bootstrap does this unconditionally on a cold tree, and build.json's
  `wv2` target does it warm (every ported target already depends on
  `wv2`, the same way Makefile targets depended on `w`). Nothing to port;
  the Makefile's `w` rule just gets dropped with no replacement.
- `update` (archives the seed via `archive.sh`, then promotes `bin/wv2` to
  `./w`) is the highest-blast-radius target in the file: it mutates the
  committed seed. **Manifest entry ported** (`deps: ["verify"]`, then
  `./archive.sh` and `mv -f bin/wv2 w`, byte-for-byte the same two
  commands the Makefile ran) but **deliberately never invoked** —
  running `./wbuild update` for real promotes a new seed, which is a
  judgment call for whoever's doing the promotion, not something to do
  as a side effect of a build-system migration. Verified narrowly
  instead: `archive.sh` itself (which the `update` rule already ran
  as-is before this change) only works when `./old/` already exists —
  it has no `mkdir -p`, so `cp w $filename` fails on a from-clean
  checkout while the script still prints "Backed up to ..." and exits
  0 regardless, because the `cp` failure is never checked. That's a
  pre-existing bug in `archive.sh`, unchanged by this port (ported
  byte-for-byte, not fixed) — flagged here since a botched backup that
  *looks* like it succeeded is worth a maintainer's attention before
  the next real `make update` / `./wbuild update`.
- `test_changed` (`git diff | wtest changed | xargs make`) needs the
  `wtest changed` output fed into a build run the same way. **Ported**:
  `wbuild` (the shell script, not wexec) now special-cases a
  `test_changed` first argument and runs
  `git diff --name-only HEAD | ./bin/wtest changed | xargs -r ./wbuild`
  — no executor change needed.

**B. Darwin toolchain** — `build_darwin`, `verify_darwin`, `update_darwin`
(the seed/verify/promote triad for the `w_darwin` Mach-O seed, codesign
steps included). wexec and build.json are Linux-only today; this needs
its own manifest entries (or a separate darwin manifest, since the host
differs) before CLAUDE.md's Mac-first workflow can drop `make`. **Not yet
ported** — must be authored and verified on a Mac (`make build_darwin`
and friends only run there), which blocks it from a Linux-only session.
This is the long pole for actually deleting the Makefile: everything
else in this list can be done and verified from Linux.

**C. Targets that don't fit wexec's execution model** — some because
they're genuinely interactive, some because they never terminate on
their own:
- `debug`, `net_debug`, `range_test_debug`, `simple_debug`,
  `struct_test_debug`, `threading_test_debug` (launch `ddd`/`gdb -ex run`
  against a freshly built binary) and `log_write`, `net_log`,
  `net_log_socket` (`sudo stap -e '...'`, streamed until killed): need a
  real TTY. `tools/wexec.w` always redirects a step's stdout/stderr into
  pipes it polls (`process_run` in `lib/process.w`) so it can buffer
  per-target output and check `expect_stdout`/`expect_stderr` — that's
  fundamentally incompatible with a full-screen debugger or a systemtap
  stream. The actual regression tests here (`debug_test`, `wdbg`) are
  already ported without needing a debugger UI, so there's no coverage
  gap, just a lost convenience wrapper.
- The bare `repl` target: also needs a live prompt (`repl_test` already
  covers the automated case and is ported).
- `tcp` and `whttp`: despite living in `tests/` and looking like ordinary
  test binaries, both `main()`s call a `server()` that `while (1): accept
  ...` forever — the Makefile rule never returns either, it's a "start a
  server, `curl`/connect to it by hand, Ctrl-C when done" convenience,
  not a one-shot test. Same bucket as the debuggers above.
- `graphics_demo`: opens a window and, unless invoked with `--frames N`,
  runs "until the window is closed" — also never terminates on its own
  in the Makefile's parameterless form. Same bucket.
- `asm_codegen_get_context`: not a W build/run step at all — one line
  that pipes a hardcoded snippet through `rasm2` as a lookup aid.
  Doesn't fit the "compile W, run binary" shape wexec targets have, and
  `rasm2` isn't installed in this environment. No wexec equivalent;
  drops with the Makefile with no replacement.
  Verdict for all of the above: leave as one-line manual instructions in
  README/AGENTS ("build with `./wbuild <binary-target>`, then run `ddd
  ./bin/<binary>` / `curl localhost:8080` / etc. yourself") once the
  Makefile goes away, rather than adding wexec's stdio-passthrough
  feature these would need. **Not yet done** — the manual-instructions
  doc pass is deferred to step 6 below, once the Makefile is actually
  being deleted and there's a concrete "where did this go" gap to fill.

**D. One-off dev/demo conveniences that do build, run, and terminate on
their own** — `asm_test`, `convert`, `cuda_smoke`, `elf`,
`grapheme_data`, `net`, `rewrite_c_strings`, `simple`, `testing_ground`.
**Ported** (commit alongside this doc update): each got a build.json
entry in the same idiom as the 176 pre-existing targets (compile step,
optional run step), verified by running `./wbuild <name>` for every one
of them. Two behave exactly as they already did under `make`, not as
regressions:
  - `asm_test` segfaults (exit 139) both under `make asm_test` and
    `./wbuild asm_test` — pre-existing breakage in `tests/asm_test.w`,
    unrelated to this migration, left as-is (not part of the `tests`
    aggregate either way).
  - `cuda_smoke` fails to compile (`symbol redefined: 'malloc'`) both
    under `make cuda_smoke` and `./wbuild cuda_smoke`, independent of
    GPU availability — also pre-existing, also outside `tests`.
  - `grapheme_data` regenerates `lib/grapheme_data.w`; running it
    produced no diff, confirming the checked-in file is current.
  Two Makefile targets in this same batch — `logging` (references a
  root-level `logging.w` that's now `lib/logging.w`) and `range`
  (references a root-level `range_test.w` that's now
  `tests/range_test.w`) — are **already dead**: `make logging` and
  `make range` both fail today (`file not found`, compiler search walks
  up to `/` and gives up) on an unmodified checkout. Not ported; they
  have nothing to port from.

**`clean`**: no manifest entry needed. `wbuild`'s own header comment
already documents the replacement (`rm -rf bin` resets the world); the
Makefile's extra `rm -f wv2 wv3 wv4 wv5 test test_output.txt
grammar_test` only cleans up root-level artifacts that the Makefile
itself wrote (wexec's outputs all live under `bin/`), so there's nothing
to port there beyond keeping `rm -rf bin/.wexec_cache` in the doc note.

### Functional (non-doc) dependents on `make`

Two files execute `make` at runtime, not just mention it in prose —
these block removal even after every target above is ported:
- `tools/mcp/w_toolchain_mcp.w`: `mcp_ensure_wv2`, `mcp_ensure_wtest`,
  `mcp_tool_build`, `mcp_tool_verify` and `mcp_tool_run_tests` all
  `words.push(c"make")` and shelled out to it. **Ported**: all five now
  push `c"./wbuild"` instead (the `mcp_valid_target` allowlist regex and
  JSON plumbing were unchanged — `./wbuild`'s target names are the same
  strings `make`'s were); doc comments and tool-schema description
  strings in the same file updated to match. `tools/lsp/w_lsp.w` and
  `tools/hooks/w_check_hook.w` had one cosmetic `make` mention each,
  also updated.
- `tools/test_map.w`: `wtest_add`'s dispatch has an explicit
  `strcmp(path, c"Makefile")` branch (currently falls through to the
  same `tests` catch-all as everything else, so it's behaviorally inert
  today) and a `build.json`/`wbuild` branch that adds `wexec_test` +
  `tests`. **Not yet done** — leave the Makefile branch alone until the
  Makefile is actually deleted (step 7); deleting it earlier would be
  dead-code removal for a file that still exists.

### Doc/prose references

`make <target>` phrasing to flip to `./wbuild <target>`, lowest priority
(do this pass last, once nothing is left to point at):  `README.md` (the
Quick facts / Build-verify-test / Repository-layout sections currently
present `make` as primary and `wbuild` as in-progress — invert that),
`AGENTS.md` (says commands "live in the Makefile"), `CLAUDE.md`'s
`## Commands` block, `.cursor/skills/{w-debug-wdbg,w-check-diagnostics,
w-repl-explore,w-select-tests}`, and the scattered single-line mentions in
`docs/todo.txt`, `docs/package_metadata.txt` and other `docs/projects/*.md`
files. **Not yet done** — deferred to step 6, together with group C's
manual-command notes, so both land as one coherent "here's what replaced
each `make` habit" pass instead of two.

### Sequencing

1. Port group D (mechanical, one commit, closes most of the gap). **Done.**
2. Port group B, the darwin triad — needs Mac verification, can't be
   done or verified from a Linux-only session. **Blocked** on running
   this step from a Mac.
3. Land group C per the recommendation above (doc-only, no executor
   change needed). **Pending**, folded into step 6.
4. Port group A's `update` and `test_changed` — `update` last and
   byte-for-byte, since it mutates the committed seed. Both **ported**:
   `test_changed` runs and was verified; `update`'s manifest entry was
   added and reasoned through (see above) but never actually invoked —
   promoting the seed is a maintainer decision, not a migration side
   effect.
5. Switch `tools/mcp/w_toolchain_mcp.w` off `make`. **Done**, see above.
6. Flip README/AGENTS/CLAUDE.md/skills to present `./wbuild` as primary;
   run a full `./wbuild tests` (plus `verify_x64`, plus the darwin triad
   on a Mac) as the parity gate before touching the Makefile itself.
   **Blocked** on step 2 (darwin): this repo's own rule is "make sure
   wbuild is at full parity first," and parity isn't full while the
   darwin triad is unported. `./wbuild tests` itself passes on Linux as
   of this writing (see below).
7. Delete `Makefile`, `tools/test_map.w`'s now-dead Makefile branch, and
   this section's framing; drop the `Makefile` row from README.md's
   repository-layout table. **Blocked** on 2 and 6.

Status as of this writing: group A (`test_changed` verified, `update`
ported but intentionally unrun) and group D are ported, the MCP server
no longer shells out to `make`, and a from-clean `./wbuild tests` run
passes (this container needed `libc6:i386` installed first for the
32-bit dynamic-linking tests — same host requirement `dynamic_test`
already documents for `make tests`; two pre-existing failures,
`asm_test`'s segfault and `cuda_smoke`'s compile error, are unrelated to
this migration and reproduce identically under `make`). The darwin
triad is the only remaining gap before the Makefile can actually go —
it needs a session with Mac access to author and verify.
