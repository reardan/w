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

## Not yet done (the rest of the migration)

- Port the last non-test conveniences: `update` (seed promotion — port
  last, keeping behavior byte-for-byte), `test_changed` (needs wexec
  to accept target names on stdin or an equivalent), and the
  interactive/debug targets that need tools the environment does not
  install (`ddd`, `gdb`, `stap`, `radare2`).
- Delete the Makefile once parity is reached and CI runs `./wbuild`.
