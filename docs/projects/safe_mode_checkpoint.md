# Safe mode checkpoint (superseded)

The paused draft checkpoint from PR #648 has been implemented and merged.
It is not an active resume plan. The experimental subset has since gained
named lifetimes, returned slices, aggregates and audited storage through
PRs #663 and #674, followed by the extensions tracked in issue #644.

Use [safe_mode.md](safe_mode.md) for current syntax, targets, guarantees,
restrictions and measured validation. Use
[safe_mode_roadmap.md](safe_mode_roadmap.md) for remaining work and
[safe_mode_contracts.md](safe_mode_contracts.md) for implementation contracts.

The [tracking issue](https://github.com/reardan/w/issues/644) remains open
for the broader roadmap. A completed bounded subset does not establish a
soundness proof or make arbitrary legacy W programs memory-safe.

Validation continues to use structured checks, manifest-selected tests,
architecture/root checks, self-host fixpoints, the full suite and compiler
coverage. Run instrumented coverage without concurrent builds or `bin/wtest`
processes because its harness temporarily replaces compiler/tool binaries.
