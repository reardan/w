# Next increment: expression grammar coverage after #690

Base: PR #690 (`codex/grammar-coverage-next`, `67611370`). The pinned corpus
currently has 209/291 compiling cases, 215 translations, and 14 strict passes.
Keep all inputs, historical results, and existing per-case expectations.

## Planned support

1. Resolve action-free finite operator aliases through parser rules and token
   alternatives. Preserve source references in the emitted AST; reject cycles,
   nullable/annotated aliases, overlapping operator identities, and lexer
   commands that invalidate the proof. Teal/PromQL and similar grammars use
   named operator rules rather than direct literal groups.
2. Admit consuming expression bases whose recursion is enclosed by mandatory
   delimiters, using the same bounded safety discipline as nested lists. Lua's
   expression bases contain nested expressions through function, table, and
   parenthesized forms. Preserve the final nullable-prefix recursion audit.
3. Extend precedence lowering to a bounded mix of binary and postfix
   alternatives, retaining source-position binding and a documented normalized
   AST. Consider consuming compound prefixes only where their boundary can be
   proven. Reject ternaries/indirect operands beyond the implemented slice.
4. Add executable local fixtures and unmodified pinned examples for actual
   newly compiling cases. Evaluate AST grouping/association and test malformed
   input, complete consumption, ambiguity refusal, and atomic failure.

## Parallel ownership and validation

One agent owns operator-analysis helpers, another owns expression lowering,
and a third owns independent runtime fixtures and cross-review. Integration
retains the earlier list normalizer and existing safety fixtures except where
a documented new supported form replaces a previous refusal.

Run structured checks after W edits, manifest-selected focused tests, the
complete pinned sweep, the offline harness tests, and `./wbuild tests`. Add
expectations only for measured gains, document remaining gaps, and open a PR
against `codex/grammar-coverage-next`.

Labels/context adapters, foreign actions, general indirect left recursion,
upstream missing tokens, and continuation-aware lexer matching remain separate
work. Compilation and strict acceptance are not complete ANTLR equivalence.
