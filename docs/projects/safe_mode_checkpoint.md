# Safe mode implementation checkpoint

Status: incomplete draft, paused at the user's request for shutdown.
Tracking issue: [#644](https://github.com/reardan/w/issues/644).
Design plan: [PR #645](https://github.com/reardan/w/pull/645).

This checkpoint preserves parallel implementation work. It does not build
yet and provides no memory-safety guarantee. Do not merge or use it as a
working safe compiler.

## Work preserved

- Contextual `own T*`, `ref T*`, and `refmut T*` syntax, distinct type
  records, shared-reference const pointees, retained type metadata and
  parser-generator grammar changes.
- `--safe` option parsing, semantic-retention setup, conflicting-option
  checks, help text, REPL rejection and incremental option fingerprints.
- Initial owner move and cleanup lowering for declarations, calls,
  returns, assignments and scope exits. Moved slots are cleared; cleanup
  conditionally frees live slots. This code still needs integration and
  correctness testing.
- Initial type-table, CLI and incremental-cache test changes.

## Known blockers

The structured check `./bin/wv2 check --json w.w` currently fails in
`code_generator/expression_ast.w` with `Cannot find symbol: 'left_type'`.
The owner-assignment insertion is in the wrong assignment branch/scope and
must be relocated and reviewed.

`compiler/compiler.w` imports `compiler.safe`, which has not been written.
The planned module must define `safe_mode`, `safe_reset()`,
`safe_trust_sources(int first)` and `safe_check_finish()`. The last function
must perform real checking; a no-op stub would incorrectly accept unsafe
programs. No ownership dataflow, borrow-liveness or escape checker has been
implemented in this checkpoint.

Semantic retention when checked types appear without `--safe` remains
unresolved. Discovering a qualifier during parsing is too late to retain
earlier locals whose symbol records have already been reused. Enable the
required metadata before the module is parsed, or implement equivalent
sound reconstruction. Type semantics must not depend on the flag.

## Next integration work

Implement complete control-flow and expression coverage for a bounded
subset, with errors for unsupported operations. Track initialization,
moves, borrow provenance and conflicting access across branches and loops.
Verify calls, imported contracts and returns. Preserve qualifiers through
conversions and reject raw-pointer routes that bypass the checker.

Review cleanup slot addressing, replacement assignment, owned parameters,
returned owners, implicit function exit and early control-flow exits. Define
the interaction with exit-time `defer` and reject unmodeled cases. Confirm
cleanup uses the existing `__w_new_object` initialization and allocation
failure guarantees correctly.

Finish trusted runtime boundaries, compiler-session resets and rollback,
target restrictions, source/contract cache invalidation and diagnostics.
Add positive, negative and runtime ownership fixtures before expanding the
admitted subset. The plan's automatic cleanup, safe library interfaces and
release gates remain outstanding.

## Validation state

- `git diff --check` passed at the checkpoint.
- Structured compiler checking fails as recorded above.
- The new implementation has not passed bootstrap, fixpoint, coverage or
  the full test suite. New tests are not yet validated.
- On the unmodified baseline, `./wbuild tests` stopped at
  `did_you_mean_test`: the environment's `NO_COLOR=1` overrides its
  `FORCE_COLOR` expectation. The focused rerun with
  `env -u NO_COLOR ./wbuild did_you_mean_test` passed. Use the same environment
  adjustment when running the eventual full suite; the baseline run left
  365 of 1164 targets unattempted.

Resume with the repository's structured check, diff-selected tests,
cross-architecture checks and full verification workflow. Update this
checkpoint to reflect the implemented result before marking the PR ready.
