# Plan: generated lexer matchers for antlr_to_pg

> Written against an earlier layout: `grammars/` paths, `build.sh`,
> `translate_samples.sh` and the `*_demo_body.w` files are now
> `libs/extras/grammars/`, the `grammars_<name>_test` / `grammars_refresh`
> wbuild targets and `tests/grammars/<name>_demo.w`.

Goal: raise end-to-end compile coverage of translated grammars-v4 grammars
(currently 19/288 per `SWEEP_RESULTS.md`) by generating W matcher functions
for regular ANTLR lexer rules instead of only classifying against the fixed
`libs/extras/parser_generator/lexer.w` matcher set. Everything below happens
in this repo; no upstream `w` changes are required (the `.pg` DSL's
`token NAME <matcher>` already accepts any matcher symbol, and the build
scripts already concatenate matcher files ahead of generated parsers).

Baseline failure data (from the current sweep and per-grammar reports):

- 254 grammars fail `wv2` with "Cannot find symbol" (unmapped lexer tokens)
- 10 fail with "symbol redefined" (name collisions)
- 1 (`v`) emits an empty `.pg` the ParserGenerator rejects
- first-blocker categories: ~66 identifier/name shapes, ~55 other
  single-shape rules, ~36 visible newline/EOL tokens, ~31 numeric,
  ~27 string/text, ~43 multi-alternative tokens, ~10 `--` comments

## Phase 1 — small classifier/plumbing fixes (no generator needed)

1. Map `--` line comments to `sql_line_comment`: the matcher landed
   upstream (`pg_lexer_matcher_sql_line_comment`, w PR #127 era); replace the
   UNRECOGNIZED branch in `at_classify_lexer_rule` with classification 1/2
   like the `//`/`#` cases. Also update `sql.pg`'s known-limitations story:
   add `skip LINE_COMMENT sql_line_comment` and switch `STRING` to
   `doubled_quote_string` (SQL `''` escaping), updating `sql_demo_body.w`
   cases and `grammars/README.md`.
2. Never drop referenced rules: two-pass classification. First collect every
   name referenced from parser-rule bodies, then classify lexer rules; a
   whitespace/newline-shaped rule that is referenced becomes a visible
   `token` (matcher `newline`/`tabs`, or a generated matcher once Phase 2
   lands) instead of being DROPPED. Fixes the `NL`/`EOL`/`WS`-as-syntax
   family (`bicep`, `callable`, `databank`, `agc`, `bnf`, `url`, ...).
3. Collision fixes ("symbol redefined", 10 grammars):
   - Source lexer rules named `TAB`/`NEWLINE` collide with the two
     always-emitted skip lines; emit those skips under reserved names
     (`PG_SKIP_NEWLINE`/`PG_SKIP_TAB`) or remap the colliding source name
     through the existing `g_name_remap` machinery.
   - Multi-file directories that hold independent grammars (not
     lexer/parser pairs) currently merge duplicate rule names (`eiffel`,
     `glsl`, `cobol85`, ...). Dedupe by rule name at `at_collect_rules`
     time (keep first, report the skip), and prefer the
     `XLexer.g4`+`XParser.g4` pairing heuristic in the sweep script.
4. Empty-grammar guard: if zero parser rules were emitted, fail translation
   with a report line instead of writing a `.pg` the ParserGenerator
   rejects (`v`).

## Phase 2 — matcher generator for regular lexer rules

The core change. New emitter in sibling concatenated source files (now
`antlr_to_pg_matchers_{ascii,analyze,emit}.w`) that compiles an `at_rule`'s existing
`at_alt`/`at_element` tree — literals, charsets, negated charsets, fragment
refs, groups, wildcard, `?`/`*`/`+` — into a W matcher function.

- Naming: `pg_lexer_matcher_g_<parser>_<RULE>` for rules,
  `pg_g_<parser>_frag_<NAME>` helpers for fragments (grammar-prefixed, so
  nothing collides with `lexer.w` or `grammars/matchers.w`).
- Semantics: try-all alternatives with position save/restore, longest match
  wins, recursion over the element tree. This matches ANTLR's maximal munch
  on everything we accept. Refuse (report UNRECOGNIZED, as today):
  - loops whose body can match empty (try-all divergence risk)
  - non-ASCII charsets (`\u` beyond 0x7F, bytes > 127) — W matchers are
    byte-oriented
  - recursive fragment references (depth-capped cycle check)
  - actions/predicates, `mode`/`pushMode`/`popMode`/`more`/`type` commands
  - `'a'..'z'` range atoms unless/until `antlr4.pg` parses them
- Classifier integration: keep the fixed-matcher mapping for the shapes it
  already handles (stable output for `json`/`csv`); fall back to the
  generator for anything else regular, including multi-alternative tokens
  (alternation is native to the emitter, so the "N alternatives" report
  category disappears for regular rules).
- Token ordering: emit `token` lines in ANTLR declaration order (already
  insertion order today — add a regression check). Known deviation to
  document: the pg lexer resolves literal-vs-token ties in the literal's
  favor regardless of declaration order, which matches the common
  keyword-before-identifier convention but not a grammar that declares
  `ID` first.
- Output plumbing: new `--matchers FILE` flag on `antlr_to_pg`;
  `translate_samples.sh`, `build.sh`, and `sweep_grammars_v4.sh` concatenate
  the per-grammar generated matcher file (when present) after
  `grammars/matchers.w` and before the generated parser.

## Phase 3 — validation and measurement

1. Rerun the sweep; refresh `sweep_results.csv` + `SWEEP_RESULTS.md`
   (expectation: from 19 into the 60–100 range; the dominant remaining
   failures should become genuinely irregular lexers — modes, Unicode,
   predicates).
2. Compile e2e is not correctness: pick 2–3 newly-green grammars that ship
   `examples/` files in grammars-v4 (candidates: `abnf`, `dot`, `graphql`)
   and add `<name>_demo_body.w` tests plus vendored sample snippets,
   following the `csv` pattern. Keep `sql`/`json`/`csv` demos green.
3. Docs: update `tools/README.md`'s "What it does and doesn't handle"
   (generated matchers, new refuse list) and `grammars/README.md`
   (`sql.pg` limitation fixes from Phase 1).

## Upstream (reardan/w) coordination

- w#125 can close: both requested matchers have landed (doubled delimiter
  strings via w#127; `sql_line_comment` present) and this repo now consumes
  them.
- Filed upstream design issue
  [w#131](https://github.com/reardan/w/issues/131) (low priority): matcher
  expressions in the `.pg` token directive (charsets/alternation/repetition
  compiled to the same matcher-function shape), as the long-term native
  home for what this repo will do via generated, concatenated matcher
  functions. Not a blocker for any phase above.
