# Sweep across antlr/grammars-v4

## Current pinned measurement

Corpus commit: `89fd36482e8cb68a4e55df021a8adbc7541b52f2`.
All columns measure the same 291 selected grammar cases:

| Stage | Initial audit | PR #689 | PR #690 | Current implementation |
| --- | ---: | ---: | ---: | ---: |
| Translation | 196/291 | 205/291 | 215/291 | 218/291 |
| Parser generation | 179/291 | 200/291 | 209/291 | 212/291 |
| W compilation | 179/291 | 200/291 | 209/291 | **212/291** |
| Strict translation audit | 10/291 | 13/291 | 14/291 | 15/291 |

The original 288-directory-name cohort now compiles **210** cases. Historical
229/288 and 258/288 figures below used different inputs and are not directly
comparable.

Current per-case results: [`sweep_current_results.csv`](sweep_current_results.csv).
[`sweep_baseline.json`](sweep_baseline.json) pins roots, preserves the initial
`recorded_pass` stages, records measured tool/runner hashes, and protects every
current `expected_pass` independently. The final sweep measured clean
implementation commit `6c1e7f69`. It had no regressions, crashes, timeouts,
missing output artifacts, or tool changes. All #690 expectations are retained.

This increment adds **three compiling grammars: Lua, TNT, and V**. All three
also gain translation; TNT gains strict acceptance. New support includes finite
operator aliases, productive recursive expression bases, leading mixed postfix
chains, and compound prefixes with proven token boundaries. Ambiguous choices
and prefix continuations remain refused. See
[`EXPRESSION_COVERAGE_PLAN.md`](EXPRESSION_COVERAGE_PLAN.md).

PR #690 added nine compiling cases: arithmetic, c, cql, icon, ltl, microc, ocl,
pmmn, and tinyc; PowerQuery gained translation and PMMN strict acceptance.
PR #689 previously added 22 compiling cases: agc,
amazon-states-language-intrinsic-functions, bencoding, css3, graphql,
graphstream-dgs, html, ixml, less, lucene, plantUML, properties, romannumerals,
scss, stringtemplate, swift-fin, tiny, tnsnames, toml, wkt, xml, and xsd-regex.
Its sole intentional lost compile/strict pass remains Lisp: the fragment
`ATOM_PART: (LETTER | NUMBER) ATOM_PART;` has no productive base. The old
rewrite invented a repetition language; the baseline retains the explicit
reclassification reasons. This increment removes no expectations.

**79 cases remain non-compiling:** 73 fail translation and six fail parser
generation (bison, informix, jpa, langium, lisp, powerquery). Of the translation
failures, 68 report unsupported left recursion; the others include
zero-consumption hazards and unresolved dependency-provided symbols. Labels,
ternaries, indirect binary operands, and lower/interleaved postfix tiers remain
outside the bounded normalization slice. Teal's overlapping `NAME` bases and
PromQL's compound/optional operators need further ordered-choice and precedence
work. Undefined upstream tokens and nonproductive lexer rules remain failures.

Bison and Langium need continuation-aware lexer backtracking: Bison's comment
and code fragments can consume a closing delimiter, while Langium's regex
character fragments can consume the enclosing `]` or `/`. Returning only a
helper's longest endpoint cannot implement those grammars. Merely admitting
recursive helper calls would conceal this gap; no such relaxation was made.

Compilation supplies an empty main and does not execute the generated parser.
New focused tests execute unmodified, hash-pinned Lua and TNT grammars and
local expression fixtures, checking AST binding, association, mixed postfix
chains, quantifier prefixes, malformed inputs, complete consumption, and atomic
refusals. See the [runtime fixture notes](../../../../tests/grammars/antlr_expression_coverage/README.md).
Lua still has host-code, Unicode, lexer, and ordered-choice semantic gaps;
V has compile coverage only. Earlier TinyC/MicroC/Arithmetic runtime tests
remain in the suite, with their documented ordered-choice limitations.
Neither compile coverage nor strict acceptance claims full ANTLR equivalence.
The corpus sweep continues to report runtime smoke as `not_configured`.

Validation: 24 focused targets, all 1,254 targets in `./wbuild tests`, and all
10 offline sweep-harness tests passed. The full suite used Node 20.19.3 with
`NO_COLOR` unset. Structured W checks are clean; vendored grammar bytes and
hashes match the pinned corpus. Final results satisfy the strengthened per-case
expectations.

## Historical measurements

> Historical results, retained for comparison with the original coverage ticket.
> Paths and inputs below predate the current layout and safety audit. The original
> compile harness also omitted `main`; its recorded totals are not a reproducible
> current baseline. Use `sweep_baseline.json` and the instructions in `README.md`
> for the pinned 291-case sweep and per-grammar regression gate.

The corrected initial audit at corpus commit
`89fd36482e8cb68a4e55df021a8adbc7541b52f2` and W commit
`298246c6d6906650d4cd9c677e93933abd9bf619` measured **179/291 compiling** and
**10/291 strict translations**. There were 94 safety rejections, 17 generator
failures, and one input without parser rules. Compilation supplies an empty main;
it does not demonstrate parser runtime behavior or ANTLR semantic equivalence.
The historical 288-name subset compiles 178 cases at those revisions. Current
run artifacts report stages and provenance independently of this historical table.

`sweep_grammars_v4.sh` ran `bin/antlr_to_pg` against every top-level
grammar directory in `antlr/grammars-v4` (288 grammars with `.g4` files
directly in their directory — not counting subdirectory variants like
`sql/postgresql`), then tried to compile each result with `bin/wv2`.
Raw results: `sweep_results.csv` (one row per grammar).

## Headline numbers

- **286/288 (99.3%)** parse structurally with `antlr4.pg` and produce
  `.pg` output (translator + `pg.pg` self-check) — up from **282/288**.
  Only empty-grammar inputs (`v`, `trapc`) still refuse to write an
  empty `.pg`.
- **258/288 (89.6%)** compile clean end-to-end (`bin/parser_generator` +
  `bin/wv2`) — up from **229/288** after #7/#8. This was a compile-only
  measurement; separate demos remained green for
  `abnf`/`dot`/`graphql`/`json`/`csv`/`sql`.

  Full green list is in `sweep_results.csv` (`wv2_exit=0`); newly green
  this pass include action, basic, fusion-tables, powerquery, vb6, lisp,
  rfc1035, cpp, icalendar, unreal_angelscript, eiffel, clojure,
  racket-bsl/isl, cobol85, creole, apt, pascal, restructuredtext,
  stacktrace, codeql, d2, scss, yini, z, and others.

- Remaining failures: **28 Cannot find symbol** + **2 translate
  failures** (empty `v`/`trapc`). **0** symbol-redefined failures remain.

**Read "286/288 structurally translate" and "258/288 fully compile" as
two different claims** — the tool understands most real-world ANTLR4
*syntax*, and generated matchers now cover regular right-recursion,
token-ref parser negations, and singleton Unicode ops.

## Remaining gaps, by category

Among the 286 that translated, first-blocker themes among the 28
compile failures (from `--report` lines):

- **Modes** (`pushMode`/`popMode`/`more`) — still the largest refuse
  class (~17: html, xml, php, toml, velocity, golang, aspectj, less,
  yara, objc, bencoding, …).
- **Mutual / nested recursion** beyond unrolled right-recursion and
  nested-delimiter / self-nested block-comment shapes (algol60
  `StdString`, dart2 interpolated strings, langium `RegexLiteral`,
  bison `NestedPrologue`).
- **Upstream grammar holes** — informix typo `CHARARACTER` (parser
  refs `CHARACTER`), jpa undefined `TRIM_CHARACTER`/`INT_NUMERAL`.
- **Mode-gated tokens** still reported as undefined (solidity
  `PragmaSemicolon`, plantUML `BODY_OPEN`, gdscript `INDENT`, …).

## Bugs found and fixed via this sweep

Earlier sweep-driven fixes (still relevant):

1. **`rule_trailer_item` was unbounded** — fixed by accepting only
   `options` there.
2. **`pg.pg` reserved words** — rename-on-collision for `rule`/`token`/…
3. **`mode` as lexer command** — accept `KW_MODE` in command names.

Phase 1/2 additions from the same corpus:

4. **`NEWLINE`/`TAB` skip collisions** — always-emitted skips renamed to
   `PG_SKIP_NEWLINE`/`PG_SKIP_TAB`.
5. **Multi-grammar directories** — prefer `XLexer.g4`+`XParser.g4` (or a
   directory-named `.g4`); dedupe duplicate rule names.
6. **Empty `.pg` for `v`** — refuse to write when no parser rules emit.
7. **Generated matchers** — regular lexer IR → W matcher functions via
   `--matchers`, including multi-alternative tokens.

Issue #7 follow-ups:

8. **Matcher mid-insert** — deep-preemit fragments and buffer function
   bodies so nested group refs no longer splice helpers into an open
   caller (fixes bogus `_asN`/`_sN` errors).
9. **`-> type(...)`** — allowed like skip/channel (remap ignored);
   full command list scanned so type+mode still refuses.
10. **ASCII-subset charset fallback** — drop `\u` / bytes>127, keep
    ASCII ID/WS shapes; report the approximation.
11. **Parser `.` → `any`**; simple parser `~[...]` → synthetic
    `PG_NEGSET_N` matcher tokens.
12. **Recursive special cases** — nested delimiters
    (`D F D | OPEN .*? CLOSE`) and direct self-nested block comments.

Issue #12 follow-ups (this pass):

13. **Right-/left-recursive unrolling** — `PREFIX X?` → `PREFIX+`,
    `BASE | PREFIX X` → `PREFIX* BASE`, `PREFIX (MID X)*` →
    `PREFIX (MID PREFIX)*`, plus nested-bracket comments
    (`OPEN (SELF | ~[CLOSE])* CLOSE`).
14. **Parser token-ref negations** — `~(LeftParen|…)` /
    `~(CRLF|CONTROL|…)` fold to `PG_NEGSET` via single-char token
    resolution.
15. **`antlr4.pg` gaps** — `<true>` element options, `??` nongreedy,
    `(: …)` colon-prefixed groups (langium/pascal/rst/stacktrace).
16. **Singleton Unicode charsets** → UTF-8 literal matchers; `\u{…}`
    charset escapes; EOF-in-lexer as end-anchor.
17. **Parser-referenced skip/channel** rules emitted as tokens
    (d2/scss/codeql/yini/z COMMENT-like refs).

## Next steps

- Modes (hard wall; ~17 remaining).
- Mutual recursion (dart2 interpolations, langium regex, algol60
  corner strings, bison nested prologue).
- More demo bodies for newly-green grammars that ship `examples/`.
- Upstream [w#131](https://github.com/reardan/w/issues/131) for native
  matcher expressions in the `.pg` token directive.
