# Plan: extend the pinned 200/291 ANTLR compile baseline

Stack this work on PR #689 (`codex/grammar-compile-coverage`, `10f10961`).
Keep the corpus revision, 291 selected roots, dependency hashes, safety checks,
and all existing per-case expectations. Measure gains using the staged sweep;
compilation alone does not establish parser runtime equivalence.

## Missing functionality and grammar gaps

The baseline has 91 non-compiling cases: 84 safety rejections, two unresolved
external grammar dependencies, and five parser-generation failures.

1. **Expression normalization is too narrow.** It accepts literal operators,
   literal parentheses, single-element bases, and unary alternatives only before
   binary alternatives. Token-named operators/delimiters and consuming compound
   bases occur in `arithmetic`, `golang`, `ctl`, `ltl`, and other grammars.
   Extend only shapes whose precedence and associativity can be preserved;
   exercise grouping, operator priority, malformed input, and complete consumption.
2. **List/postfix normalization rejects all transitive self references.** This
   excludes ordinary nested expressions such as tinyc's `sum_ -> term ->
   paren_expr -> expr -> sum_`, even though parentheses consume before re-entry.
   Distinguish consuming nested recursion from nullable-prefix cycles. Investigate
   nullable bases separately; consuming tails must remain mandatory. Test nested
   constructs and refusals of genuinely unsafe recursion.
3. **Lexer recursion still blocks generator output.** `bison` needs nested
   prologue/code matchers and `langium` needs recursive regular-expression
   fragments. Investigate bounded, consuming recursive matcher support with
   positive/negative runtime cases; do not invent productive bases or silently
   flatten recursive suffixes.
4. **Gaps that are not safe automatic fixes.** `informix` and `jpa` refer to
   undefined upstream tokens; Lisp's `ATOM_PART` has no productive base;
   `aspectj` and `trapc` need dependencies outside the selected sibling inputs.
   Foreign actions/predicates, indentation providers, labeled ANTLR AST contracts,
   indirect left recursion, and ambiguous lexer backtracking need separate work.
   Preserve explicit failures and audit diagnostics for unsupported forms.

## Parallel implementation

- Agent A: expression normalization and dedicated runtime/refusal fixtures.
- Agent B: list/postfix recursion analysis and dedicated runtime/refusal fixtures.
- Agent C: investigate and implement a bounded lexer-recursion extension, with
  focused tests; retain refusal if no sound extension fits the identified shapes.
- Integrator: maintain separate module ownership, review combined changes, run
  the unchanged corpus, update expectations only for verified new passes, and
  document the remaining failures.

## Validation and delivery

Run structured W checks after edits and use `bin/wtest changed` to select focused
targets. Execute generated parsers/matchers for each new supported behavior and
assert failure atomicity for unsupported inputs. Run the complete pinned sweep,
offline sweep harness tests, and `./wbuild tests`. Preserve original
`recorded_pass` data and refresh current measurement provenance. Open a stacked
PR targeting `codex/grammar-compile-coverage`, reporting measured gains and
remaining limitations.

## Implemented outcome

The finalized sweep reaches **209/291 compiled** (+9), **215 translated** (+10),
and **14 strict translations** (+1), with no regressions or infrastructure
errors. The original 200 compile expectations and every other stage expectation
from #689 remain protected. New compiles are arithmetic, c, cql, icon, ltl,
microc, ocl, pmmn, and tinyc; PowerQuery gains translation only. PMMN gains
strict acceptance.

Agents A/B implemented expression and list normalization in separate modules.
Agent C established that Bison/Langium need continuation-aware lexer matching,
then added executable, unmodified pinned TinyC/MicroC/Arithmetic fixtures.
Cross-review identified greedy-choice counterexamples and added refusals:

- Nullable list bases are supported only as one syntactically empty alternative.
  `a: a 'x' 'y' | 'x'?` cannot become greedy `x? (xy)*` without losing `xy`.
  Competing empty/nonempty bases remain unsupported for the same reason.
- Compound expression bases need disjoint first tokens from other bases, prefix
  operators, and parenthesized expressions. A successful short prefix must not
  conceal a longer valid base; literal, group, optional-prefix, and alias forms
  all receive regression coverage.
- Nested list recursion requires mandatory matching `()`, `[]`, or `{}` around
  re-entry. Consuming an operator alone does not justify lowering an indirect
  expression operand. The final nullable-prefix safety audit remains mandatory.

The new runtime tests evaluate ASTs, check unary binding at three source
positions and binary association, parse nested/postfix/empty lists, and reject
malformed or trailing input. Atomic refusal tests retain the original IR when
a shape is unsupported. All three vendored grammars match the existing corpus
hashes; none of the 291 selected inputs changed.

## Remaining work after this increment

There are 82 non-compiling cases: 76 translation failures (71 report left
recursion) and six generator failures. Future work should address:

1. Label/context-preserving normalization, ternaries, mixed binary/postfix
   expressions, multi-token operators, and indirect expression operands. These
   require an explicit AST contract and precedence tests, not disabling the
   recursion audit.
2. Continuation-aware lexer matching for Bison/Langium and PowerQuery's remaining
   lexer-derived symbols. Bison's overlapping fallback/comment/code alternatives
   and Langium's enclosing regex delimiters require shorter match endpoints
   after a greedy helper succeeds; consuming recursion alone is insufficient.
3. Upstream undefined tokens in Informix/JPA, Lisp's nonproductive fragment, and
   dependency-provided symbols outside the selected sibling closure. Keep these
   visible in the denominator and review any future input/dependency changes.
4. Generated-parser ordered-choice limitations. The pinned TinyC/MicroC tests
   exposed valid assignments/comparisons that an earlier successful alternative
   hides, and TinyC's analogous `else` limitation. The fixture README records
   these; the tests do not misclassify known valid programs as negative cases.
5. Additional strict adaptations and runtime coverage. Compile success remains
   separate from Unicode, host actions/predicates, lexer priority, and complete
   ANTLR semantic equivalence.

## Completed validation

- 21 focused targets passed, including all three new targets and existing ANTLR
  safety, strict, stateful, dependency, golden, and generated-W-grammar checks.
- `./wbuild tests` passed all 1,251 targets with `NO_COLOR` unset and the
  repository-required Node 20.19.3 on `PATH`.
- All 10 offline sweep-harness tests passed.
- The complete 291-case sweep passed at clean implementation commit `705674f0`,
  with no regressions or infrastructure errors; its results also satisfy the
  strengthened per-case baseline. Corpus hashes and historical results are
  unchanged.
