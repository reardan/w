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
  `./w`) should be ported last and byte-for-byte — it mutates the
  committed seed, so it's the highest-blast-radius target in the file.
- `test_changed` (`git diff | wtest changed | xargs make`) needs the
  `wtest changed` output fed into a build run the same way. Simplest
  path: teach `wbuild` itself (the shell script, not wexec) a
  `test_changed` verb that pipes `./bin/wtest changed | xargs ./wbuild`
  — no executor change needed.

**B. Darwin toolchain** — `build_darwin`, `verify_darwin`, `update_darwin`
(the seed/verify/promote triad for the `w_darwin` Mach-O seed, codesign
steps included). wexec and build.json are Linux-only today; this needs
its own manifest entries (or a separate darwin manifest, since the host
differs) before CLAUDE.md's Mac-first workflow can drop `make`. Must be
authored and verified on a Mac, not from a Linux-only session.

**C. Interactive/instrumentation targets that don't fit wexec's execution
model** — `debug`, `net_debug`, `range_test_debug`, `simple_debug`,
`struct_test_debug`, `threading_test_debug` (launch `ddd`/`gdb -ex run`
against a freshly built binary), `log_write`, `net_log`, `net_log_socket`
(`sudo stap -e '...'`, streamed until killed), and the bare `repl` target
(an interactive prompt — `repl_test` already covers the automated case and
is ported). These resist mechanical porting: `tools/wexec.w` always
redirects a step's stdout/stderr into pipes it polls (`process_run` in
`lib/process.w`) so it can buffer per-target output and check
`expect_stdout`/`expect_stderr`, which is fundamentally incompatible with
a full-screen debugger or a prompt that needs a real TTY. Two options:
  1. Add a step-level opt-out (e.g. `"tty": true`) that execs with
     inherited stdio instead of piping, forfeiting capture/timeout for
     that step.
  2. Leave these as one-line manual instructions in README/AGENTS
     ("build with `./wbuild <binary-target>`, then run `ddd
     ./bin/<binary>` yourself") instead of wexec targets — they were
     never part of `make tests` and don't need to be part of
     `./wbuild tests` either.
  Recommendation: option 2. Less code, and matches how the actual
  regression tests here (`debug_test`, `wdbg`) are already ported without
  needing a debugger UI.

**D. One-off dev/demo conveniences** — `asm_test`,
`asm_codegen_get_context`, `convert`, `cuda_smoke`, `elf`,
`grapheme_data`, `graphics_demo`, `logging`, `net`, `range`,
`rewrite_c_strings`, `simple`, `tcp`, `testing_ground`, `whttp`: build and
run a single binary, no interactivity, no `sudo`. Mechanical ports in
wexec's existing idiom (compile step, run step) — same shape as the 176
targets already ported. Do these in one pass so the gap count goes to
zero in one commit rather than piecemeal.

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
  `words.push(c"make")` and shell out to it. Swap each for
  `./wbuild`/`bin/wexec` invocations; the `mcp_valid_target` allowlist
  regex and JSON plumbing stay as-is, only argv[0] and the
  verify/verify_x64 argument names change (they must match build.json's
  target names).
- `tools/test_map.w`: `wtest_add`'s dispatch has an explicit
  `strcmp(path, c"Makefile")` branch (currently falls through to the
  same `tests` catch-all as everything else, so it's behaviorally inert
  today) and a `build.json`/`wbuild` branch that adds `wexec_test` +
  `tests`. Delete the Makefile branch once the Makefile is gone — dead
  code removal, not a behavior change.

### Doc/prose references

`make <target>` phrasing to flip to `./wbuild <target>`, lowest priority
(do this pass last, once nothing is left to point at):  `README.md` (the
Quick facts / Build-verify-test / Repository-layout sections currently
present `make` as primary and `wbuild` as in-progress — invert that),
`AGENTS.md` (says commands "live in the Makefile"), `CLAUDE.md`'s
`## Commands` block, `.cursor/skills/{w-debug-wdbg,w-check-diagnostics,
w-repl-explore,w-select-tests}`, and the scattered single-line mentions in
`docs/todo.txt`, `docs/package_metadata.txt` and other `docs/projects/*.md`
files.

### Sequencing

1. Port group D (mechanical, one commit, closes most of the gap).
2. Port group B, the darwin triad — needs Mac verification, can't be
   done or verified from a Linux-only session.
3. Land group C per the recommendation above (doc-only, no executor
   change needed).
4. Port group A's `update` and `test_changed` — `update` last and
   byte-for-byte, since it mutates the committed seed.
5. Switch `tools/mcp/w_toolchain_mcp.w` off `make`.
6. Flip README/AGENTS/CLAUDE.md/skills to present `./wbuild` as primary;
   run a full `./wbuild tests` (plus `verify_x64`, plus the darwin triad
   on a Mac) as the parity gate before touching the Makefile itself.
7. Delete `Makefile`, `tools/test_map.w`'s now-dead Makefile branch, and
   this section's framing; drop the `Makefile` row from README.md's
   repository-layout table.
