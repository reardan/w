# Line execution coverage

`--coverage` instruments executable statement entries on Linux x86, x64 and
arm64.
It uses the profile runtime's counters and writes `<binary>.wprofmap`. Running
that binary with `W_PROFILE_OUT` set appends its nonzero counters to the named
file. `wcoverage lines` combines those counters with the complete map to report
both executed and unexecuted lines, including bodies of functions never called.
The default `wcoverage` command still reports static module reachability.

```sh
./wbuild wcoverage
./bin/wv2 --coverage tests/wcoverage/line_fixture.w -o bin/covered
: > bin/covered.raw
W_PROFILE_OUT=bin/covered.raw ./bin/covered
./bin/wcoverage lines --file tests/wcoverage/line_fixture.w \
  bin/covered.wprofmap bin/covered.raw
```

The report lists `path:line: hit` or `path:line: miss` in file/line order, followed
by the number and percentage of executable lines hit. `--file path` is optional
and repeatable; without it the report includes the entire compiled closure.
Paths match the map exactly, normally relative to the compiler's working
folder. A filter that matches no executable lines is an error.

Several runs of the same binary can append to the same dump. Clear it before
starting a fresh measurement. Several binaries can be combined by listing a
map followed by its dump(s), then the next map followed by its dump(s):

```sh
./bin/wcoverage lines --file lib/my_module.w \
  bin/test_a.wprofmap bin/test_a.raw \
  bin/test_b.wprofmap bin/test_b_first.raw bin/test_b_second.raw
```

A source line is hit if any corresponding statement site in any input ran.
Repeated generic instantiations, multiple statements on one line, and deferred
statements emitted at several exits therefore count as one source line. Empty
dumps are valid and report all mapped lines as missed. Missing dumps, invalid
rows, out-of-range indices, and maps without statement counters are errors.

On arm64 the increment is an `adrp`/`add` pair addressing the counter
through the backend's scratch registers `x9`/`x10`, then `ldr`/`add`/`str`;
the exit hook is a `b` over `exit`'s first instruction. Run the binary under
`bin/wrun arm64` (qemu-user) or natively; `coverage_arm64_test` (in
`tests_arm64`) checks the same fixture results as the x86 run. arm64_darwin,
win64 and wasm still reject `--coverage` and `--profile-generate`.

Always keep each dump paired with the exact binary's map. Recompiling can
change counter indices; the raw format has no binary fingerprint to detect a
stale or incorrectly paired dump (`wcoverage suite` clears its dump
directories before every run for this reason). Use separate dump files for different
binaries, including different target architectures. Maps can subsequently be
combined because the reporter unions hits by source file and line.

Coverage means reaching a statement, not evaluating every subexpression;
`--branches` adds decision outcomes for `if`/`elif` (below). Blank/comment lines, block delimiters, function headers,
and labels are excluded. A loop header is hit on entry to the loop statement,
even if its body never executes. A `defer` line can be hit when its statement is
registered; coverage does not prove every deferred action ran. Uninstantiated
generic bodies and files absent from the compiled closure are not measured.
Normal returns from `main` and explicit `exit()` flush counters; signals,
crashes and `_exit` do not. Counters are not atomic across threads. Instrumented
runs are for coverage, not performance measurements.

The streaming and retained AST emitters share the instrumentation. Existing
`--profile-generate` function/loop profiles and ordinary compilation are
unchanged. A coverage map also contains the existing function/loop counter
records; the line reporter ignores them and consumes the `s` (statement)
records. Use `wcoverage lines`, not `wprof merge`, for coverage maps.

`./wbuild coverage_test wcoverage_test` checks branch misses, never-called
functions, loops, early exit, generics, defer, generator resumption, inferred
locals, labels, map/dump validation, retained-emitter byte parity, and merged
x86/x64 execution. The existing `verify` and `verify_x64` guards still apply to
compiler changes.

## Report formats

`wcoverage lines` prints the per-line list by default. Other views of the
same merged data:

- `--prefix <p>` (repeatable) keeps only paths starting with `p`, next to
  the exact-path `--file` filter.
- `--uncovered-only` drops hit lines (and, in summaries, fully covered
  groups and functions that ran).
- `--summary dir|file|function` prints a table instead: per top-level
  directory, per file, or per function (`path:line: name` with the share
  of its lines that ran; the closing `function coverage` line counts
  functions entered at least once).
- `--format lcov` writes an lcov tracefile (`SF`/`FN`/`FNDA`/`DA`
  records) for genhtml, Codecov or an editor gutter; hit counts are 0/1
  because the reporter keeps hit/miss only. `--format json` writes one
  object per file: `{"file", "lines", "hit", "missed": [...]}`.
- `--diagnostics` lists the diagnostic call sites among the selected
  lines: lines that call `error`, `warning` or another `*_error` /
  `*_warning` / `warn_*` reporter with a string literal (found by a small
  lexical scan that skips comments and string contents). A site is hit
  when the *last* statement counter on its line ran, so for
  `if (bad): error(c"...")` the condition alone does not count.
- `--branches` lists every `if`/`elif` header line with its two
  outcomes, `taken hit|miss, not taken hit|miss`. The compiler marks the
  header's statement counter (ordinal 1 in the map); the reader pairs it
  with the next statement counter of the same function, the first
  statement of the then-arm. Taken means the arm ran; not taken means the
  header was reached more often than the arm ran (the `elif`/`else` arm
  or the fall-through ran). Text reports add a `branch coverage` total
  whenever the selection has decisions, the summaries add a branch
  column, lcov gets `BRDA`/`BRF`/`BRH` records and json `branches` /
  `branches_hit`. Loops are not decisions here: their head counter sits
  inside the rotated loop and counts iterations, and a loop whose body
  never ran already shows as missed lines. `&&`/`||` operands and `?:`
  arms are not counted separately. Counts are summed across dumps and
  capped at 10^9, which only matters past a billion executions.
- `--baseline <file>` checks floors: each non-comment line is
  `<prefix> <percent>` (one decimal at most); `diagnostics` is the
  diagnostic-site floor and `branches:<prefix>` a branch floor. A floor that is not met prints `baseline: FAIL`
  and the command exits 1.

A dump argument may be a directory: every file in it is read as a dump of
the preceding map. Dumps are streamed, so thousands of them are fine.

## Compiler coverage

`./wbuild compiler_coverage` measures the compiler itself, the REPL and
wdbg under the full `tests` umbrella:

1. `bin/wcoverage suite` builds x86 and x64 `--coverage` copies of `w.w`,
   `repl.w` and `debugger/debugger.w` into `bin/coverage/`.
2. It reruns `tests` (`bin/wexec --no-cache --keep-going`) with
   `$W_COVERAGE_COMPILER`, `$W_COVERAGE_COMPILER_64`, `$W_COVERAGE_REPL[_64]`,
   `$W_COVERAGE_WDBG[_64]` and `$W_COVERAGE_OUT` set. Every compiler, REPL
   and debugger build checks its variable first thing in `main`
   (`compiler/coverage_exec.w`) and re-executes as the instrumented copy
   with the same arguments, so manifest steps, `wfixture` and the
   compilers tests spawn themselves are all measured without wrapper
   scripts. Each process appends to
   `bin/coverage/<tag>_<arch>/<pid>.raw`. A process that already has
   `$W_PROFILE_OUT` set is being profiled by its caller and is not
   redirected.
3. It merges every map with its dumps and writes `summary.txt`,
   `files.txt`, `functions_uncovered.txt`, `lines_uncovered.txt`,
   `diagnostics.txt`, `lcov.info` and `coverage.json` under
   `bin/coverage/`, prints the summary, and checks
   `tools/coverage_baseline.txt`.

The report covers `compiler/`, `grammar/`, `code_generator/`, `repl/`,
`debugger/` and the root drivers (`--prefix` changes that). The
`lib/` and `structures/` lines in these maps are only what the compiler
imports, so they say nothing about the library's own tests; plain
`wcoverage` and per-test `--coverage` cover those. A test that fails
under the instrumented builds still contributes what it flushed; the run
writes reports even when tests fail, and returns a nonzero status.
`completeness.txt` distinguishes successful execution from failed or missing
runs. `--no-run` re-renders the reports from the dumps and completion receipt
of the last run, preserving its failure status.

### Parallel coverage jobs

CI prepares the compiler, REPL, debugger and compiler API harness builds once,
executes four target shards, and merges the counters before applying either
coverage gate. Each shard also runs the API harnesses, stores their counters
beside the matching maps, and includes harness failures in its completion receipt:

```sh
bin/wcoverage suite --out bin/coverage --prepare-only
cp bin/wcoverage bin/coverage/wcoverage
# Run each I=0,1,2,3 in an isolated checkout restored from preparation:
bin/coverage/wcoverage suite --out bin/coverage --skip-build --shard 0/4
# Collect all four shard directories alongside the prepared builds:
bin/coverage/wcoverage suite --out bin/coverage --merge-shards 4 \
  --baseline tools/coverage_baseline.txt
```

Preparation artifacts must preserve executable modes. Each shard publishes
`bin/coverage/shards/I-of-4/`, including its exact map snapshots,
`preparation.id`, PID-named raw directories, `run.status`, and timing reports.
Keep these directories separate when downloading artifacts: different runners
can reuse the same PID. The merge validates all four completion receipts,
target selections, preparation identities, and maps against preparation.
Missing receipts or mismatched artifacts fail the command. A receipt records
executor failures too: their counters still generate reports, but cannot pass
the completeness check. Individual shards do not apply coverage floors.

`--shard I/N` uses the same zero-based manifest target partition as `wexec`.
Dependencies are retained in each shard, so overlapping setup can execute on
multiple runners. The AST expression test has independently scheduled test
function shards, allowing its expensive cases to run on multiple workers.
`phases.tsv` records preparation, tests, merge and report durations in
milliseconds; `targets.jsonl` records executor target durations and outcomes.
These measurements can guide later shard balancing without relying on log
arrival timestamps.

The counter runtime batches complete rows into appends of at most 4096 bytes,
reducing write syscalls while preserving the text format and concurrent append
behavior. Its uint64 decimal formatter uses a stack scratch buffer instead of
allocating one per counter. `profile_buffer_test` checks several buffer
boundaries and concurrent appenders on x86 and x64; `coverage_suite_test`
checks merged branches and diagnostics, colliding PIDs, missing receipts,
failed runs, and mismatched maps or preparation identities.

Running the instrumented copies does not change any output: they are the
same source, and the self-host fixpoint steps inside `tests` still
compare equal. What the redirect cannot see: binaries `tests` never
starts (the arm64/win64/wasm/darwin legs, `tests_gpu`), processes that
die by signal (no flush), and the seed-built `bin/wv2` stage.

### Baseline and the new-code rule

`tools/coverage_baseline.txt` holds a floor per directory and for
diagnostic sites, set just under the measured values. The CI
`coverage` merge job applies those floors after collecting all test shards
and fails (without blocking merges yet) when a directory drops below its floor. Raise a floor in
the same PR that adds the tests; lower one only with a reason in the
commit message.

On pull requests the job also runs

```sh
git diff -U0 origin/main...HEAD > changed.diff
bin/coverage/wcoverage changed changed.diff bin/coverage/lcov.info
```

which requires at least 80% of the changed executable lines in
`compiler/`, `grammar/` and `code_generator/` to be reached by some test
(`--min`, `--prefix` adjust it). Lines in a function whose definition
line carries `# coverage: exempt <reason>` are skipped; use it for debug
dumps and internal-error paths that cannot be reached from a program.

### Gaps the first runs found, and what is still open

The first suite run (2026-10-09, Linux x86_64) measured 93% of the
compiler-side lines and 35% of its diagnostic call sites. Follow-ups
from that run: `tests/diagnostic_sites/` covers 28 of the unreached
diagnostic sites, nineteen never-entered functions with no caller were
deleted, and a REPL echo bug (float variables printed as raw bits)
turned up while covering the REPL's commands.

Still open, in rough order of value:

- The remaining unreached diagnostics (`diagnostics.txt`), largely
  gpu/PTX, protobuf/json builtins, extern/C-import and the streaming
  front end's copies of AST-reported errors.
- wdbg (78%): the attach-mode commands (`at_hw_list`, `at_delete_command`,
  `at_help`, ...) need scripted sessions like `tests/wdbg_*`.
- Register-allocation slow paths (`rs_take_ident_slow`,
  `regalloc_guard_fail`) and the retained-AST source checks only fire on
  inputs no test builds yet; the coverage-guided fuzzer
  (`tools/wfuzz.w`) is the intended source of such inputs.
- Coverage of the arm64_darwin, win64 and wasm backends' own code paths:
  `--coverage` does not support those targets (it needs a counter
  section and an exit hook per object format), so their lines count
  only through the x86/x64/arm64 Linux compilers that emit them.
- Mutation testing (a smoke run that flips operators in a few hot
  grammar files and checks `tests` notices) is not started.

## Fuzzing

`tools/wfuzz.w` (`./wbuild wfuzz`) is a coverage-guided fuzzer driven by
the same counters (issue #440). It runs a `--coverage` binary on mutated
inputs and keeps an input when its dump reaches a counter index no
earlier run reached:

```sh
./wbuild wfuzz
./bin/wv2 --coverage my_parser.w -o bin/my_parser_cov
./bin/wfuzz --binary bin/my_parser_cov --corpus seeds/ --out bin/fuzz \
  --seed 1 --cases 2000
```

Each case picks a corpus entry (a third of the time the newest one),
then either applies `tools/fuzz/core.w`'s `wf_generate` mutation or a
stack of one to four edits: byte overwrite/insert/delete, insertion of a
W token (`if (`, `struct `, `2147483647`, ...), line duplication,
deletion or move, and a splice from another entry. The input is written
to `<out>/work/case.w` and the binary runs with `--arg` list (`{}` is the
case path, `{out}` a scratch output path), a fresh `$W_PROFILE_OUT` and
`--timeout-ms` (default 10 s). Exit status 0 or 1 is a normal outcome;
any other status or a signal is a crash (`<out>/crashes/<sha256>.w` with a
`.log` holding the status and stderr), a timeout goes to `<out>/hangs/`,
and new coverage to `<out>/corpus/`. Crashing runs flush no counters, so
they never grow the corpus. `--diff <exe>` (with `--diff-arg`) also runs
every input the binary exits 0 on through a reference command and saves
a different status, stdout or `{out}` file to `<out>/diffs/` (with both
`{out}` files as `.out` / `.out_ref` and a `.log` of both stderrs); seeds that
already differ are listed as "seed diffs" and their mutants skip the
oracle. The run is deterministic for a given `--seed` and `--cases`
(case *i* draws from `wf_rng(seed, i)`); `--seconds` bounds it by time
instead. `--minimize <file>` deletes lines and then bytes while the exit
status stays the same, and prints the result. The header of
`tools/wfuzz.w` lists every flag.

`./wbuild wfuzz_test` (in `tests`) fuzzes
`tests/wcoverage/fuzz_target_fixture.w`, whose nested conditions end in
a null dereference, for 400 cases: coverage must grow past the seed, the
crash must be found, a second run must produce the same corpus, and the
minimizer must reduce a crashing input to `if (while (`.

`./wbuild wfuzz_compiler` (in no umbrella) builds
`bin/wfuzz_compiler/compiler_cov` from `w.w`, seeds the corpus with
every `.w` file under `tests/` of at most 4 KiB, and fuzzes it for
`$WFUZZ_SECONDS` (default 300) with `bin/wv2 --streaming` as the
differential reference, so a program the AST front end compiles must
compile to the same bytes under the streaming front end. Results are in
`bin/wfuzz_compiler/out/`. The nightly `.github/workflows/fuzz.yml`
workflow (also runnable by hand with a budget) runs it for 20 minutes,
writes the summary and the list of findings to the job summary, and
uploads the corpus, crashes, hangs and diffs as the `compiler-fuzz`
artifact for 14 days. Findings do not fail the workflow; reproduce one
with `bin/wv2 <file> -o /tmp/out` and shrink it with `--minimize`.
