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

## Implemented outcome

The three parallel tasks delivered finite operator analysis in
`normalize_operators.w`, expression-tier lowering in `normalize.w`, and
independent pinned Lua/TNT runtime coverage. Local fixtures cover alias AST
preservation, source-order unary/binary binding, mixed leading postfix chains,
compound prefixes, productive recursive bases, and atomic refusal.

The clean implementation at `6c1e7f69` measures **218/291 translations,
212/291 generated and compiled parsers, and 15/291 strict translations**.
Lua, TNT, and V gain translation/compilation; TNT gains strict acceptance.
All earlier expectations and input hashes remain unchanged. The historical
288-name cohort now compiles 210 cases. The sweep has no regressions or
infrastructure errors; compilation remains separate from runtime conformance.

Review tightened the planned scope: postfix alternatives must precede every
binary alternative and share one highest-binding loop. Compound prefixes need
a mandatory finite-token boundary plus disjoint optional/repeated continuations
through parser aliases. Regressions cover operand stealing (`'-' NUMBER? e`),
delimiter stealing (`'-' ':'? ':' e`), hidden trailing loops, and overlapping
recursive bases. The final structural recursion audit remains mandatory.

Teal remains blocked by overlapping `NAME` bases (`NAME 'is' typ` versus
`prefixexp`). PromQL uses optional group clauses in operators and overlapping
UNLESS tiers, beyond finite single-token aliases. Labels/context adapters,
ternaries, lower postfix tiers, indirect binary operands, and continuation-aware
lexer matching remain future work. Of 79 non-compiling cases, 73 fail
translation (68 report unsupported left recursion), and six fail generation.
Pinned Lua/TNT runtime checks demonstrate selected behavior; V remains
compile-only, and the fixture notes describe remaining semantic gaps.

Validation: 24 focused targets, all 1,254 targets in `./wbuild tests`, and all
10 offline sweep-harness tests passed. The full suite used Node 20.19.3 with
`NO_COLOR` unset. Structured W checks are clean; vendored grammar bytes and
hashes match the pinned corpus. Final results satisfy the strengthened per-case
expectations.
