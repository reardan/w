# Sweep across antlr/grammars-v4

> Recorded against an earlier layout; paths below are historical (see
> `README.md` for the current layout).

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
  `bin/wv2`) — up from **229/288** after #7/#8. These are real, working
  parsers; demos remain green for
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
