# Retired wc2 experiment

Retired on 2026-10-04. The production compiler's
[AST migration](ast_migration.md) is the single ongoing implementation.
`bin/wc2`, its resident service, source-owned build targets and benchmark driver
have been removed. The production compiler never imported its AST, semantic
analysis, emitter or cache, so retirement does not change bootstrap behavior.
Use `bin/wv2 --ast-full-expressions` for hybrid compilation and
`bin/wv2 --ast-required` to reject runtime-expression fallbacks. Neither flag
means that complete module/statement trees are retained yet.

## What the experiment established

The four #488 tasks implemented a parser-generator-based semantic AST, a limited
Linux x86 emitter, functions/control flow/basic structs/imports, and a resident
JSON-lines service. The work preceded the production migration; it was a
feasibility experiment, not a second supported W implementation. Its subset,
private struct ABI, diagnostics and definite-initialization rules differed
from production W. The final pre-retirement implementation is available in git
at `1440b2a4` (`tools/wc2/`, `tools/wc2.w`, `tests/wc2*` and
`tools/bench_wc2.py`).

Preserve these requirements when production gains retained trees:

- Own source bytes, filenames, tokens, syntax nodes, diagnostics and bindings
  for their full lifetime. Keep stable node IDs and source spans; separate
  semantic tables from syntax. Emission should not mutate checked trees.
- Parser backtracking, shared factored prefixes and recovery can leave nodes
  outside the successful root. Stream ownership must release every allocation
  once, including failed parses. The parser-generator's shared ownership API
  remains, with independent guard-allocator tests.
- A syntax-shaped `w.pg` tree does not supply W's contextual type/name decisions
  or reliable semantic block ownership. Moving to it required a separate
  lowering/type-checking implementation; do not repeat that parallel compiler.
- Cache identity must use source bytes and resolved imports, not just mtimes.
  Test same-size edits, restored timestamps, newly shadowing imports, creation,
  deletion, transitive changes, invalid programs and recovery after repairs.
- Checked program snapshots must own their state independently of replaceable
  per-file cache entries. Bound cache retention and test eviction/clear/failure
  paths with the guard allocator. Do not promise incremental emission merely
  because parsing is cached.

## Measurements retained as historical evidence

The [recorded benchmark](wc2_benchmark.json) used seven samples per operation
on 2026-10-03. The 810-line / six-file synthetic workload took a median 61.072 ms
for a new wc2 process versus 30.564 ms for wv2; a resident changed-leaf build took
42.927 ms. Warm resident checks took 0.200 ms and warm builds 0.170 ms, reusing
analysis and emitted bytes. Changed programs still reanalyzed and emitted as a
whole. The smaller case omitted production runtime imports, so its speedup was
not evidence of a general compiler improvement. The removed benchmark driver
can be recovered at the revision above; these are historical measurements,
not commands or performance claims for the production AST path.

## Coverage disposition

- The 44 fixed-width arithmetic/comparison/short-circuit cases and long forward
  branch case now run against the production compiler in
  `tests/ast_integer32_test.w`, comparing legacy and required-AST images from
  each compiler host width and executing the resulting x86 programs. Image
  parity is checked within each host, not across different compiler hosts.
- Stream-owned W parser lifecycle coverage now lives in
  `tests/parser_generator/owned_ast_memory_test.w`: success, abandoned parses,
  recovery, lexical errors, empty input and simultaneous stream lifetimes.
  It also checks shared child ownership and the default independent-tree API.
- Production AST differential fixtures already cover calls/evaluation order,
  recursion, branches, loops, record copies, precedence and diagnostics. The
  wc2-specific dump schema, private ABI, restricted-language rejection and
  resident-service tests retire with their implementation. Cache/snapshot
  requirements above remain future acceptance criteria, not claimed coverage.
- The experiment exposed a production integer-to-boolean return defect:
  `bool truth(int n): return n`, called with `-7`, should return true. Its wc2
  test proved only the experimental emitter's result. Preserve this finding
  alongside the broader [fundamentals audit](../fundamentals_audit.md); fixing
  production coercion and adding its regression test is separate work.
