# Testing

How W's tests are written and run, and the tools around them: the
`lib/testing.w` runner (summary, filter, leak checks), execution coverage,
compiler performance tracking, and the flaky-test policy. Issue #538
introduced the runner features, `bin/wcoverage`, the `wbench` baseline
and this policy.

Writing a test is covered in `AGENTS.md` and `CLAUDE.md`: create
`tests/foo_test.w` (or `lib/foo_test.w` next to the module), import
`lib.testing`, write zero-argument `test_*` functions, and add
`# wbuild:` directives for expectations and extra steps
(`tools/wbuildgen_lib.w` documents the vocabulary).

## The runner (`lib/testing.w`)

Importing `lib.testing` provides `main()`. The compiler registers every
zero-argument `test_*` function, and the runner calls them in
definition order. Each test prints `Run: 'test_x()'` and then
`Test 'test_x()' passed!`. The run ends with a summary line and
`All tests passed!`:

```
Summary: 12 passed, 0 failed, 0 skipped
All tests passed!
```

A failing assertion (`lib/assert.w`, or `assert_near`) prints its
message and a stack trace, then the runner prints a summary and the
failing test's name before exiting 1. The summary includes earlier
passing tests, leak failures, and this assertion failure. Later tests
remain unrun; they are not counted as filtered/skipped. Assertions
remain fail-fast, while leak-check failures let the remaining tests run.
Programs importing only `lib.assert` retain their existing diagnostics
and exit behavior without a runner summary.

### Running a subset

```sh
bin/foo_test --filter parse            # tests whose name contains "parse"
bin/foo_test --filter=parse,lexer      # either substring
W_TEST_FILTER=parse bin/foo_test       # same, from the environment
bin/foo_test --list --filter parse     # print the selected names, run nothing
```

Tests that do not match are counted as `skipped`, and the summary
names the filter. If the argv form and `W_TEST_FILTER` are both set,
argv wins. A filter that matches no test fails the run with
`Tests FAILED: the filter matched no test.`, so a typo cannot pass
silently, including with `--list`. A missing value after `--filter`
exits 2 with a usage diagnostic. The runner ignores every other argument,
so a test that reads its own argv keeps working.

### Leak checks

With `W_TEST_LEAKS=1`, the runner switches to the guard-page debug
allocator (`lib/memory_debug.w`, the same backend `W_DEBUG_ALLOC=1`
selects) and checks each test. A test that returns while heap blocks
it allocated are still live fails:

```
LEAK: 'test_leaks_one_block()' returned with 1 heap block(s), 40 byte(s) still allocated:
  40 byte(s) at 0xf7f2afd8
...
Summary: 2 passed, 1 failed, 0 skipped [leak check]
Leaked: test_leaks_one_block
Tests FAILED: leak check.
```

The remaining tests still run, and the exit status is 1. A test's
blocks are the ones it allocated between its start and its return.
Blocks allocated earlier and freed during the test do not count, and
neither does anything the runner prints. `W_DEBUG_ALLOC=1` on its own
keeps its old meaning: it traps overflows and use-after-free, with no
leak verdict.

To check a test on every run, add a step to its source:

```
# wbuild: step="bin/hash_table_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
```

This step runs the binary a second time under the leak check, after
the normal run. The following tests currently have this step:
`structures/hash_table_test.w`, `structures/json_test.w`,
`structures/string_test.w`, `lib/event_loop_test.w`,
`lib/byte_buf_test.w`, `lib/result_test.w` and `lib/path_test.w`.
Enable the check only for a test that passes it. Most tests don't pass
yet, mostly because they never free their own results. Fix the test
first, then add the step.

Limits:

- Only `malloc`'d blocks are tracked. Memory that is `mmap`'d directly
  is invisible to the check, for example a generator's 64 KB stack.
- A module that allocates a global cache on first use reports that
  cache as a leak in whichever test touches it first.
- A test that asserts free-list block reuse cannot run under the debug
  allocator, because it never reuses a block. `lib/lib_test.w`,
  `lib/arena_test.w` and `lib/ndarray_test.w` fail for this reason.
- Tests using native resources or allocator-specific behavior need
  their own lifecycle assertions in addition to heap accounting.

#### Ownership and retention regressions

`tests/resource_leak_test.w` runs under both `W_DEBUG_ALLOC=1` and
`W_TEST_LEAKS=1` in manifest steps on x86 and x64. It checks manual
generator cleanup before starting, after yielding and after exhaustion;
automatic generator-loop cleanup on exhaustion, continue, break, return
and error propagation; function-scoped defer cleanup; and timer teardown
with a virtual clock. Its companion `resource_leak_fixture.w` deliberately
reproduces the cases below and must produce leak verdicts and exit 1.
The suite also checks that a cleanup test runs after the reported leaks.

These cases preserve the documented ownership/defer semantics; the test
infrastructure detects them, rather than changing when resources are freed.

1. **Generators driven by hand.** Creating a generator and calling
   `gen_next(g)` with no `gen_free(g)` leaks the 24-byte generator
   object and its 64 KB + 16 KB stack mapping. The leak check sees only
   the object. Draining the generator (`while (gen_next(g)): ...`)
   releases the stack but still leaks the object. A
   `for x in gen(...)` loop frees correctly on normal exit, `break`,
   `continue`, `return` and `?` (all checked clean). The leak exists
   only when the API is driven by hand, and the language has no
   destructor that could catch it.
2. **`defer` in a loop.** `defer` is function-scoped and evaluated at
   exit (docs/projects/defer.md), so the following code frees only the
   last block and leaks the first `n - 1`:

   ```
   char* p = 0
   for i in range(n):
   	p = malloc(16)
   	defer free(p)
   ```

   This is documented semantics, but nothing warns about it. A lint
   rule for `defer` inside a loop body would catch it.
3. **`return` before `defer`.** In
   `char* p = malloc(16); if (early): return 1; defer free(p)`, the
   early return leaks `p`, because a `return` placed textually before
   the `defer` does not run it (documented caveat). `defer` together
   with `?` was checked and is clean.
4. **Cancelled timers.** `event_loop_cancel_timer` only marks the timer
   inactive. The timer stays in the heap until its deadline, so adding
   and cancelling 100 one-hour timers leaves 100 live timer blocks
   (lib/event_loop.w:470-477). `event_loop_free` releases them, so the
   leak check passes. A long-running loop that keeps cancelling
   long-deadline timers grows without bound. Fix: compact the heap
   when the number of cancelled timers passes half its length.

## Coverage

`./wbuild wcoverage_report` (or `bin/wcoverage` after
`./wbuild wcoverage`) lists the `lib/` and `structures/` modules that
no test program imports, directly or through other modules:

```
roots: 907 (203 did not compile, skipped)
uncovered modules (4 of 141):
  lib/context_aarch64.w
  lib/logging.w
  lib/pty.w
  lib/wmeta.w
reached only through the test harness (4 of 141):
  lib/crash_dump.w
  lib/float_text.w
  lib/signal.w
  structures/prelude.w
module coverage: 133/141 (94%)
```

That is the report at the time of #538.

The roots are every `.w` file under `tests/`, plus every `*_test.w` and
`*_e2e.w` under `lib/`, `structures/`, `graphics/`, `libs/` and
`tools/`. Each root's import closure comes from `bin/wv2 deps`. A root
that does not compile for the default target is retried as `x64`. The
measured modules leave out `*_test.w` files and the per-target
`__arch__/` trees. Use `--roots <dir>` and `--modules <dir>` to measure
something else, `--covered` to list the covered modules as well, and
`-j N` to change parallelism (default 4). A full run takes about two
minutes. It is a tool target, not part of `tests`. `wcoverage_test`
(in `tests`) checks the tool on the fixture tree in `tests/wcoverage/`.

Every test imports `lib/testing.w`, so without a special rule the
modules the runner itself imports (`lib/format.w`,
`lib/float_text.w`, `lib/crash_dump.w`, ...) would count as covered by
every test. A module in the harness's closure therefore counts as
covered only when some root names it in its own `import` line.
Otherwise it is listed under "reached only through the test harness"
and does not count. The rule does not apply to modules that an empty
program already pulls in (the auto-imported runtime). `--harness
<file>` changes the harness (default `lib/testing.w`) and `--harness
none` turns the rule off. The audit's earlier figure, 31 of 120
modules imported by no test, counted only `*_test.w` roots. This report
also counts the fixtures and helper programs that test steps run, plus
a root's x64 closure when it is x64-only.

This is static reachability, not execution coverage. A "covered" module
can still contain functions that no test calls.

For execution coverage, compile with `--coverage` on Linux x86 or x64,
run with `W_PROFILE_OUT` set, then report the recorded hits together with
the binary's map:

```sh
./bin/wv2 --coverage tests/stdlib_property_test.w -o bin/property_coverage
: > bin/property_coverage.raw
W_PROFILE_OUT=bin/property_coverage.raw ./bin/property_coverage
./bin/wcoverage lines --file structures/json.w \
  bin/property_coverage.wprofmap bin/property_coverage.raw
```

The report includes hit/miss for every emitted executable statement line,
including never-called functions, and a total percentage. Multiple runs
and binaries can be merged by source file/line. It measures statement
entry, plus `if`/`elif` outcomes with `--branches`; absent modules and
uninstantiated generic bodies remain outside the denominator. Normal return and `exit()` flush
data, while crashes do not. See [line execution coverage](projects/line_coverage.md)
for map/dump pairing, filtering, supported paths and limitations.

`./wbuild compiler_coverage` measures the compiler, REPL and wdbg
themselves under the whole `tests` umbrella, writes per-directory, per-file,
per-function, diagnostic, lcov and json reports under `bin/coverage/`, and
checks the floors in `tools/coverage_baseline.txt`; the CI `coverage` job
runs it on every push and PR and applies the changed-lines rule
(`wcoverage changed`). See "Compiler coverage" in
[line execution coverage](projects/line_coverage.md).

## Performance

`tools/wbench.w` benchmarks the compiler on four workloads: `prelude`
(an empty program, which still compiles the auto-imported container
runtime), `sym1000` and `sym4000` (generated programs with many
symbols) and `self` (`w.w`). For each workload it reports
`sym_lookup` calls, records visited, the output size in bytes and the
best wall time.

```sh
./wbuild wbench_compare                          # compare against tools/wbench_baseline.txt
bin/wbench --compare tools/wbench_baseline.txt   # same, by hand
bin/wbench --write-baseline tools/wbench_baseline.txt   # refresh the baseline
```

`--compare` fails (exit 1) when a workload's calls, records visited or
output bytes are more than `--tolerance` percent (default 10) above the
baseline. These three numbers are deterministic, so the check gives
the same result on any machine and under any load. Wall time is only
reported. Pass `--time-factor <x>` to also fail when the best time is
more than x times the baseline's (with 50 ms of slack). Use it only
when comparing against a baseline recorded on the same machine.
`--only <workload>` runs a single workload.

The **Performance regressions** CI job runs `wbench_compare` on every
pull request, push to `main`, and manual workflow run, using
`tools/wbench_baseline.txt`. It fails on deterministic counter/size
growth above 10%; wall time remains diagnostic because hosted runners
vary in speed. Its job summary shows the comparison, and the
`compiler-performance` artifact retains the log, measured
`bin/wbench_results.txt`, and committed baseline for 14 days, including
on failure. This baseline does not need a runner-class variant because
wall-clock measurements are not gated.

`wbench_compare` is also runnable locally and is not part of `tests`: a
deliberate compiler change shifts the counters. After an intended
change, re-run `--write-baseline` (default `-n 3` on an idle machine,
so the recorded times are meaningful) and commit the new
`tools/wbench_baseline.txt` with the change. The commit message should
say why the numbers moved. `wbench_compare_test` (in `tests`) checks
the compare logic itself against fixture baselines in `tests/wbench/`
and `tests/bench/fixtures/`.

### The benchmark corpus (run-time performance)

`tests/bench/` holds small compute-bound programs that measure the
code the compiler emits rather than the compiler itself
(docs/projects/register_allocation_pgo.md §5): `sum` (the two-local
summation loop), `sieve`, `sha256_1m` (`lib/sha256.w`), `siphash_keys`
(map inserts and lookups, the container runtime's hash table),
`inflate_corpus` (`libs/extras/compress/inflate.w` over the DEFLATE
corpus), `regex_backtrack` (`lib/regex.w`), `matmul_256` and
`strcmp_sort` (`list.sort` on strings), plus `self` (the compiler
compiling `w.w`). Each program is deterministic, takes an optional size
argument, and prints one line, `<name> size=<n> checksum=<hex>`, that
is the same on the 32-bit and 64-bit targets and from the C twin in
`tests/bench/c/<name>.c` (a port of the same algorithm and, where the
W program uses a library, of that W library code). The default sizes
run 0.4-1.1 s each on the x86 build.

```sh
./wbuild bench                 # run every program x86+x64 (checksums asserted), write bin/bench.txt
./wbuild bench_compare         # the same, then compare against tests/bench/baseline.txt
./wbuild bench_sum             # one program, both widths, full size
bin/wbench --programs --compiler bin/wv3 --write-baseline bin/bench_new.txt   # another compiler
bin/wbench --programs --only sha256_1m --no-valgrind -n 5                      # quick look
tools/bench_vs_c.sh            # W x86/x64 vs gcc -O2 / clang -O2 (markdown tables)
```

`bin/wbench --programs` compiles each program for x86 and x64 with the
given compiler (`--compiler`, default `bin/wv2`; the x64 `self` row
uses `--compiler64`, default `bin/wv2_64` from `build_x64`, and is
skipped when that does not exist), runs each `-n` times (default 3)
and reports per `<name>.<arch>` row the executable size, the callgrind
instruction count in thousands (`kIr`) with the three hottest
functions, and the best wall time. `kIr` is measured once per row when
`valgrind` is on `PATH` (`--no-valgrind` skips it); like the size it is
a deterministic property of the binary, so it is the number to gate
on and to quote. `--compare` applies the rules above to the
`bytes` and `kIr` columns (`kIr` only when both the run and the
baseline measured it: without valgrind the check is skipped, not
failed), reports wall time, and fails on a row missing from the
baseline or on an x86/x64 checksum mismatch. `bin/bench.txt` is
written in baseline format with the top functions as comments, so
refreshing `tests/bench/baseline.txt` after an intended codegen change
is copying it over (on an idle machine, so the recorded times mean
something) and saying why in the commit message. The baseline's `kIr`
column moves slightly between runs of `siphash_keys` and `self`
(the map seed is random per process), well inside the tolerance.

`bench` and `bench_compare` are local, opt-in targets outside `tests`
(they take minutes under valgrind). The CI performance job above gates
the compiler workloads with `wbench_compare`; it does not run this
run-time corpus comparison.
`bench_<name>_smoke_test` targets (in `tests`) compile and run each
program at a tiny size on both widths and assert its checksum, so the
corpus never stops compiling. Adding a program is one source file with
its own `# wbuild: target=bench_<name> tag=bench` and
`bench_<name>_smoke_test` blocks (copy an existing one), its C twin,
and a new row in the baseline; `tools/wbench.w`'s `prog_names` lists
the corpus.

`tools/bench_vs_c.sh [-c <compiler>] [-n <runs>] [-o <name>] [-V]`
builds every program but `self` with the W compiler for both widths
and its C twin with `gcc -O2`, `clang -O2` and (when the toolchain has
32-bit multilib; skipped otherwise) `gcc -O2 -m32`, checks that all of
them print the same line, and prints markdown tables of wall time and
instruction count. Note that `sum`'s loop is folded to a closed form by
both C compilers, so that row measures their optimiser, not a loop.

### Profiles (`profiles/*.wprof`)

`profiles/self.wprof`, `self_x64.wprof` (the compiler compiling `w.w`,
x86 and x64) and `bench.wprof` (the corpus above) are committed text
profiles taken with `--profile-generate` and merged by `bin/wprof`
(docs/projects/register_allocation_pgo.md §3.3). `--profile-use=<path>`
reads one explicitly — the compiler never looks for a profile on its
own — and `./wbuild verify_pgo` (in `tests`) is the self-host fixpoint
with the flag: `wv3_pgo == wv4_pgo == wv5_pgo`, the default front end
(retained emission) equal to `--streaming`, and the x64 chain. Entries are keyed by
`w defhash`, so editing a function's body only makes its entry stale
(the static heuristic applies to it) and never changes what the
compiler computes; `./wbuild profile_check` (in `tests`, never fails)
prints how much of each profile still matches the tree. A PR that
changes hot code re-runs `./wbuild profile_refresh` and commits the
result, saying why the numbers moved, with the same idle-machine
caveat as the benchmark baseline; counts of the hash-table probe loops
differ slightly between refreshes (addresses), which is expected.

## Flaky tests

A **flake** is a test target that fails and then passes on an
unchanged tree: same commit, same inputs, same machine class. Some
failures are not flakes:

- A failure that reproduces on rerun is a real failure.
- A failure that only happens on one platform or under one
  configuration is a platform bug. It needs its own issue, not the
  flake label.
- A failure caused by a missing tool or environment (no display, no
  `qemu-user-static`, no `libc6:i386`) is a setup problem. The target
  should skip or say so clearly.

**One retry, at most.** When a target fails, it may be rerun once,
locally or in CI, without changing anything (`./wbuild <target>`; the
failing target is named in `wexec: failed: <target>`). If the retry
fails too, it is a real failure: fix it before merging. Never rerun
until green. A second retry hides exactly the intermittent bugs these
tests exist to catch.

**Every flake becomes an issue.** If the retry passes, use the
[flaky-test issue form](../.github/ISSUE_TEMPLATE/flaky-test.yml) to open
a GitHub issue the same day with the `flaky-test` label. Include the target
name, the first failure's log (the full `wexec` output for that
target), the commit, the platform, and how often it has been seen. If
an issue already exists, add a comment to it instead. Mention the
issue in the PR that hit the flake. Assign an owner and keep the issue
open until a deterministic reproducer or regression test and a fix land.
CI does not automatically retry failed jobs; the single retry is an
explicit maintainer action, with both attempt logs retained.

**No quarantine.** A flaky test is not disabled, skipped, removed from
its umbrella, wrapped in a retry loop or given a looser expectation
just to get it green. Its issue is fixed: by fixing the test, fixing
the code it exposed, or making the test deterministic (fake clocks via
`lib/wclock.w`, `lib/event_sim.w`, fixed seeds, explicit
synchronization). Until then, the one-retry rule keeps merges moving
and the issue keeps the flake visible.

## Property tests

`tests/stdlib_property_test.w` runs on x86 and x64 in the full suite:

- Map and set insert/overwrite/remove sequences are checked after every
  operation against independent fixed-size array models (8 seeds,
  600 operations per seed), including membership, size and stored values.
- List sorting must preserve the input multiset, order values, and be
  idempotent (32 generated inputs).
- Generated nested JSON arrays must preserve integer, boolean, null and
  string values through stringify/parse, including control characters,
  quotes and backslashes; canonical serialization must be stable (64 seeds).

The generator uses bounded integer arithmetic and fixed seeds, so the
same cases run on both word sizes. Failures identify the seed and case
or operation. These are bounded property checks, not exhaustive proofs;
add a focused regression case for a discovered bug before extending the
seed set. Run just one family with `--filter map`, `--filter list` or
`--filter json` on `bin/stdlib_property_test`.

## Not done yet

- Branch coverage for loops and `&&`/`||` operands, and execution coverage
  on targets beyond Linux x86/x64.
- Leak checks that also catch `mmap`-backed resources (generator
  stacks, thread stacks).
- Mutation testing and automatic shrinking of failing property cases.
