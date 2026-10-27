# Sweep across antlr/grammars-v4

## Current pinned measurement

Measured W `08775258` plus the runtime examples stage and memoized prediction
calls (#679) against corpus
commit `89fd36482e8cb68a4e55df021a8adbc7541b52f2`. The same 291 roots and
original grammar bytes are used in every configuration. Translation, generation
and compilation are unchanged from the compile-only measurement of clean commit
`b1887a858969ba341fb1449793dfd69ed4113677`; the examples column is new.
Memoizing prediction calls moved the exact examples from 215/244 cases and
1088/1190 files (permissive) and 187/200 and 886/913 (strict) to the totals
below; no example verdict regressed.

| Configuration | Translation | Generation | W compile | W compile `--strict` | Examples: cases | Examples: files |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Default permissive | 218 | 214 | **214** | **214** | 66/194 | 431/913 |
| Default translator `--strict` | 10 | 10 | 10 | 10 | 8/8 | 39/39 |
| Stateful permissive | 218 | 214 | 214 | 214 | 95/194 | 523/913 |
| Stateful translator `--strict` | 28 | 28 | 28 | 28 | 27/27 | 105/105 |
| Exact permissive | 267 | 267 | **267** | **267** | **223/244** | **1118/1190** |
| Exact translator `--strict` | 218 | 218 | **218** | **218** | **194/200** | **905/913** |

Stage cells are out of 291. Exact means `--exact-lexer --prediction`; stateful
means `--stateful`. Translator `--strict` refuses reported semantic gaps.
W compiler `--strict` separately rejects warnings in generated W.

The examples stage runs the compiled parser on up to ten pinned upstream example
files per case (1,315 files across 262 cases; 29 cases have no usable examples)
and checks the accept/reject verdict, not the parse tree. "Cases" counts compiled
cases with examples whose every example got the expected verdict; "files" counts
example files. No example hung, crashed or hit an infrastructure error; the
slowest took 3.6 seconds of its 10-second limit.

Exact permissive example failures: **9 files in 7 cases** still exceed the
one-million-step parser prediction budget (agc, arden, cpp, html, objc, php and
tinyos_nesc; 43 files in 16 cases before calls were memoized). **51 files in 15
cases** are syntax errors (bcpl, bencoding, bison, gdscript, haskell, javadoc,
langium, lua, mumps, php, pike, properties, stringtemplate, tinyos_nesc, wren),
two Lua files hit an invalid token, and SDL's ten examples are not UTF-8. Four
files that used to exhaust the budget now finish and are rejected as syntax
errors. These are not yet triaged; several of these grammars rely on host
predicates, actions or a lexer superclass. Exact strict fails only 8 files: 5
over budget (agc, arden, html) and 3 syntax errors (mumps, pike, properties).
Default-mode failures are dominated by its approximate lexer lowering (93 files
rejected with `invalid character`, e.g. JSON's negative numbers) and ordered-choice
parsing without continuation (370 syntax errors).

The merged #689 → #690 → #692 baseline compiled 212 cases, of which only 49
passed W compiler `--strict`. All original 212 now compile without warnings.
Default compilation adds Informix and JPA through explicitly reported inferred
token identities; their undefined token matchers still prevent strict acceptance.
Exact mode adds **55 of the original 79 compile misses**, reaching 267/291
(91.8%). Exact strict accepts all original 15 default strict cases and **203 of
the original 276 strict misses**, reaching 218/291 (74.9%). No exact-mode case
is lost between successful translation and strict W compilation.

The compile-only measurement completed all six configurations with **zero
infrastructure errors and zero regressions against the reviewed baseline**; its
longest stage took 7.176 seconds. The historical 288-name subset now compiles 212 cases in default
mode; this is a separate denominator from the current 291-root matrix.

Per-case stages and diagnostic counts are in
[sweep_current_results.csv](sweep_current_results.csv). The machine-readable
[sweep_remaining.json](sweep_remaining.json) records all 291 cases, original and
current outcomes, first failed stages, and deduplicated findings with source
locations. [sweep_baseline.json](sweep_baseline.json) preserves original
`recorded_pass` and `pre_compatibility_expected_pass`, pins input and tool hashes,
and independently protects the measured stages of all six configurations and
every pinned example's verdict. The gate fails on unexpected passes as well as on
regressions, so these totals are exactly what the committed baseline expects.
The complete pre-implementation matrix is retained in
[sweep_pre_compatibility_results.csv](sweep_pre_compatibility_results.csv).

## Strict reclassifications

Default strict acceptance is intentionally **15 → 10**. PMMN, PropCalc, Roman
numerals, SPASS, and EBNF had executable cases where ANTLR accepted input that the
old ordered-choice parser rejected. Their unmodified upstream grammars, hashes,
entry rules, and witnesses are maintained in
[STRICT_RECLASSIFICATIONS.json](../../../../tests/grammars/antlr_differential/STRICT_RECLASSIFICATIONS.json).
All five pass exact strict now. SPASS's witness uses its public `term` entry.

Historical stateful strict acceptance is **58 → 28** with the added parser
continuation audit. Of the 30 refusals, five have the witnesses above; the other
25 are conservative unproven cases, not demonstrated runtime bugs. All original
58 pass every exact-strict stage and default permissive W compilation with
`--strict`. [STRICT_CONTINUATION_REVIEW.json](STRICT_CONTINUATION_REVIEW.json)
records each decision and final pipeline confirmation. Optional proofs have
explicit grammar-size and work limits; exhausted proofs refuse acceptance.

## Remaining compile coverage

All **24 exact compile misses** fail during translation. There are no remaining
exact generator failures or generated-W warning failures in this pinned corpus.
Twenty-one grammars contain unsupported left-recursion shapes:

| Grammar | Refused rules |
| --- | --- |
| alef | `setlist`, `zelist` |
| alloy | `expr` |
| awk | `non_unary_expr`, `non_unary_print_expr` |
| cayenne | `expr` |
| clu | `primary` |
| eiffel | `expression` |
| elixir | `expression` |
| gql | `valueType` |
| gvpr | `expr` |
| hypertalk | `chunk` |
| kirikiri-tjs | `expression` |
| peoplecode | `expr` |
| plucid | `expression` |
| refal | `program` |
| rust | `expression` |
| sapf | `expression` |
| semver | `build`, `preRelease` |
| spl | `expression` |
| tl | `proposition` |
| vb6 | `valueStmt` |
| z | `expression`, `predicate` |

The other three are:

| Grammar | Blocking condition |
| --- | --- |
| AspectJ | Unresolved Java lexer/parser imports in the selected input/dependency closure |
| TrapC | Unresolved `OverridesLexer`, `CLexer`, `OverridesParser`, and `CParser` dependencies |
| SHARC | `StringLiteral` and `CharLiteral` can emit visible tokens without consuming input |

Some grammars have additional host-code or token findings; these are overlapping
causes, not additional cases. Direct precedence, ternaries, labeled alternatives,
compound operators, and postfix levels are supported within the implemented
normalization. Arbitrary indirect or nullable-prefix left recursion remains
outside that support. Lisp now compiles by retaining its nonproductive fragment
as an actual failing call; no productive base is invented.

## Remaining strict coverage

**73 cases fail exact strict translation**, including the 24 compile misses.
The 49 additional cases compile permissively but have reported semantic gaps.
The most frequent finding classes among refused cases are:

| Finding | Grammars affected |
| --- | ---: |
| Host actions, predicates, or element options (`AT_HOST_SITE`) | 34 |
| Unsupported declarations/dependencies (`AT_DECLARATION`) | 27 |
| Unsupported left recursion | 21 |
| Nongreedy constructs requiring adaptation | 13 |
| Case-insensitive parser literals requiring explicit lexer rules | 5 |
| Unsupported lexer commands | 5 |
| Inferred token identities | 3 |
| Declared tokens without lexer matchers | 3 |

Counts overlap. The remaining less frequent findings include missing dependencies,
undefined symbols, command conflicts, unsupported exact lexer shapes, Unicode,
token ambiguity/remapping, nonproductivity, and empty tokens. The per-case ledger
contains every reported code, rule, reason, and source location. Strict translation
is a compatibility audit, not a complete validator of ANTLR source legality.

## Runtime evidence and limits

The implemented lexer keeps fragment endpoints and enclosing continuations,
ordered greedy/nongreedy behavior, token priority, Unicode scalar matching,
lexer modes, custom channels, and EOF/`more` state. The parser uses bounded
complete-input continuation search with delayed AST replay and source metadata.
It does not implement ANTLR ALL(*) or its context/listener APIs, and has no DFA
cache. Search can be exponential up to its explicit work budget. Resource and
provider failures are sticky across backtracking. The input domain is valid UTF-8
without embedded NUL; malformed UTF-8 and embedded NUL fail explicitly.

The separate runtime differential covers **24 families / 170 inputs**, including
expression results and labels, lexer state, Unicode, token sets, fragment remaps,
strict reclassification witnesses, and deterministic mutations. The live ANTLR
4.13.2 oracle has **zero mismatches** in exact mode. An independent lexer endpoint
oracle compares **7,104 cases**, also with zero mismatches. Unicode tables and CI
use Java 17. These bounded suites do not establish runtime conformance for every
compiling corpus grammar. The 291-case sweep therefore continues to report
`runtime_smoke: not_configured`.

See the [runtime fixtures](../../../../tests/grammars/antlr_differential/README.md),
[endpoint oracle](../../../../tests/grammars/antlr_exact_lexer/README.md), and
[implementation plan and capability ledger](COMPATIBILITY_PLAN.md) for contracts,
reference-system comparisons, reproduction commands, and remaining limits.

## Validation

- Full `env -u NO_COLOR ./wbuild tests`: **1,270 targets passed**, including
  self-host fixpoint and architecture checks.
- Six configurations × 291 roots: zero crashes, timeouts, missing artifacts,
  regressions, or tool changes; every successful exact translation passes W `--strict`.
- Live ANTLR differential: **170/170**; endpoint oracle: **7,104/7,104**.
- Offline sweep harness: **17 tests**; runtime differential harness: **11 tests**.
- Structured W checks and generated-parser checks pass. Original corpus bytes,
  root selections, hashes, and historical baseline evidence are preserved.

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
