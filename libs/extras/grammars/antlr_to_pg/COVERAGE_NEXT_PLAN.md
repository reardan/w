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
