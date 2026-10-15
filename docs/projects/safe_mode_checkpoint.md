# Safe mode implementation status

The paused checkpoint in PR #648 is now a working experimental implementation
of the bounded Linux x86/x64 subset described in
[safe_mode.md](safe_mode.md). The missing checker and broken owner-assignment
lowering have been replaced and integrated. The broader roadmap in
[issue #644](https://github.com/reardan/w/issues/644) and
[PR #645](https://github.com/reardan/w/pull/645) remains open.

## Implemented

- Contextual `own`, `ref` and `refmut` contracts, with the same ownership
  semantics whether or not `--safe` is present.
- Resolved control-flow analysis for initialization, moves, last-use borrow
  lifetimes, reborrows, branches, loops, calls and forward declarations.
- Owner transfer and conditional destruction on replacement, scope exit,
  return, break and continue, including inferred owner declarations and
  owned parameters.
- Bounds-checked arrays and immutable slices with backing-storage lifetime
  tracking; explicit unsafe blocks for raw operations.
- Audited runtime source pins, scalar formatting in `lib.safe`, structured
  diagnostics, compiler-session resets and option-cache fingerprints.
- Explicit rejection of unmodeled operations, unsupported targets and
  in-process entry points. Checked functions retain their cleanup and
  transfer behavior under the default optimizer.

The implementation has been integrated with main's optimizer and Android
changes. Runtime pins include the new page-size and platform helpers;
checked pointers remain limited to Linux x86/x64.

## Validation

Use the repository's normal workflow:

```sh
bin/wv2 check --json w.w
bin/wtest changed origin/main..HEAD
bin/wtest archs compiler/safe.w --check
env -u NO_COLOR ./wbuild tests
env -u NO_COLOR ./wbuild compiler_coverage
git diff -U0 origin/main...HEAD > bin/safe_changed.diff
bin/coverage/wcoverage changed bin/safe_changed.diff bin/coverage/lcov.info
```

`NO_COLOR` is removed because this environment sets it globally and the
color-diagnostic fixture explicitly tests `FORCE_COLOR` behavior. Run coverage
without concurrent builds or `bin/wtest` processes: its harness temporarily
replaces compiler/tool binaries and restores them afterwards.

The positive/negative matrix compiles and executes accepted programs under
both architectures, with and without `--safe`. Runtime fixtures use the guard
allocator to check destruction and leaks, including optimized and unoptimized
emission. The full suite includes the parser-generator syntax check and
self-hosting fixpoints. Cost measurements and limitations are recorded in
[safe_mode.md](safe_mode.md).

## Deliberate limits

This PR completes the checkpoint's bounded implementation, not the entire
safe-language roadmap. Optional or escaping references, reference-bearing
aggregates and containers, arbitrary control flow, deferred cleanup and
additional platforms still need contracts and analysis before they can be
admitted. They are rejected in checked code rather than silently accepted.
