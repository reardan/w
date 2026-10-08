# Line execution coverage

`--coverage` instruments executable statement entries on Linux x86 and x64.
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

Always keep each dump paired with the exact binary's map. Recompiling can
change counter indices; the raw format has no binary fingerprint to detect a
stale or incorrectly paired dump. Use separate dump files for different
binaries, including different target architectures. Maps can subsequently be
combined because the reporter unions hits by source file and line.

Coverage means reaching a statement, not testing every branch or evaluating
every subexpression. Blank/comment lines, block delimiters, function headers,
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
