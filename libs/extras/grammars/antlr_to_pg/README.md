# antlr_to_pg

A best-effort translator from ANTLR4 grammars to the ParserGenerator
`.pg` DSL, written in W using W's own grammar tooling: two `.pg`
grammars describe the two formats involved, run through
`tools/parser_generator.w` like any other `.pg` grammar.

## Layout

- `tools/antlr_to_pg.w` — the CLI entry point; its `# wbuild:` header
  owns the `antlr_to_pg`, `antlr_to_pg_test` and `grammars_refresh`
  targets (and `grammars_parser_generator`, the ParserGenerator build the
  grammar demos share).
- `antlr4.pg` — describes the ANTLR4 grammar-file syntax this translator
  understands (grammar header, `fragment`/lexer/parser rules,
  alternatives, groups, `?`/`*`/`+`, labels, lexer commands, `[...]`
  charsets, `'...'` string literals). Validated by parsing the real
  `testdata/antlr/*.g4` files below *and* the ~1200-line SQLite grammar
  from `grammars-v4` structurally (see "Stress-testing" below).
- `pg.pg` — describes the `.pg` DSL itself (a self-referential grammar:
  the DSL describing its own format), mirroring
  `tests/parser_generator/{c,w,sample}.pg`'s shape. Used both as a
  dogfooding exercise and as an internal self-check: `antlr_to_pg`
  parses its own emitted `.pg` text with it before writing the output
  file, so an emitter bug fails loudly instead of producing
  subtly-broken `.pg` syntax.
- `antlr4_matchers.w` — two custom pg lexer matchers `antlr4.pg` needs
  that `libs/extras/parser_generator/lexer.w` doesn't provide: a `[...]`
  character-class matcher and a balanced `{...}` block matcher (the
  latter also swallows options{}/tokens{}/channels{}/@header{} bodies and
  rule-body actions/predicates as a single hidden token, so the grammar
  itself never has to special-case them). `antlr4.pg` imports it.
- `types.w`, `ast.w`, `charsets.w`, `classify.w`, `emit.w` — the
  translator: walks the `pg_ast_node` tree `antlr4.pg`'s generated parser
  produces for an input `.g4` file, reconstructs a Rule/Alt/Element model
  from it (`ast`), classifies each lexer rule's *shape* against a fixed
  set of known matchers (`charsets`, `classify`; see below), lifts
  every parenthesized group into its own synthesized helper rule (the
  same manual pattern `w.pg`/`c.pg`/`sql.pg` use, since `.pg` has no
  inline grouping), and emits `.pg` text (`emit`). Shared structs,
  globals, and forward declarations live in `types`, which every other
  module imports.
- `matchers_{ascii,analyze,emit}.w` — the generated-matcher emitter:
  compiles regular ANTLR lexer rules into W matcher functions (ASCII
  approximation of Unicode charsets, rule-shape analysis / refusals, and
  the emission engine, respectively; see `MATCHER_GENERATION_PLAN.md`).
- `testdata/antlr/` — small ANTLR4 grammars vendored from
  `antlr/grammars-v4` (see its own `README.md`) so the translator has
  something to run against without a network fetch. `antlr_to_pg_test`
  translates them and compares the output with the committed
  `../json.pg`/`../csv.pg` (plus reports and matcher modules);
  `./wbuild grammars_refresh` rewrites those after an intended change.
- `sweep_grammars_v4.sh`, `SWEEP_RESULTS.md`, `sweep_results.csv` — the
  whole-corpus sweep (see "Stress-testing").
- `MATCHER_GENERATION_PLAN.md` — design notes for the matcher generator
  (written against an earlier layout, so its paths are historical).

## Why w, not a scripting language

An earlier version of this tool was a ~500-line Python script doing its
own hand-rolled ANTLR tokenizing/parsing. Rewriting it in W using w's own
`.pg` DSL for *both* input and output formats is more in the spirit of
this repo (and `w` itself, which is self-hosting): the ANTLR-parsing part
is no longer bespoke code to maintain, it's just another `.pg` grammar
validated the same way every other grammar here is.

## What it does and doesn't handle

Lexer rules are first matched against a fixed set of shapes and mapped to
the closest existing `libs/extras/parser_generator/lexer.w` matcher
(stable output for `json`/`csv`):

- a single fixed string alternative (`TRUE: 'true';`) → `literal`
- ANTLR's classic per-letter case-insensitive-keyword idiom
  (`K_SELECT: S E L E C T;` with `fragment S: [sS];` etc.) → `literal`,
  reconstructing the text from each fragment's letter
- bare `.` → `token ... any`
- `[a-zA-Z_][a-zA-Z_0-9]*`-shaped → `token ... identifier`
- `[0-9]+`-shaped → `token ... digits`
- digit/sign/`[eE]`-only combinations (optional leading sign, decimal
  point, exponent) → `token ... number` — **except** the pg `number`
  matcher doesn't consume a leading sign, so a rule that allows one gets
  a `NOTE` in the report flagging that negative literals won't lex
  (see `json.pg.report`)
- `"..."`/`'...'`-wrapped → `token ... string`/`char_literal`; doubled
  delimiter escaping (`''` / `""`) maps to
  `doubled_quote_string` / `doubled_double_quote_string`
- CSV-style unquoted fields (`~[,\n\r"]+`) → `token ... csv_text`, supplied
  by `../matchers.w`
- `/* */`, `//`, `#`, `--` comments → `block_comment`/`c_line_comment`/
  `line_comment`/`sql_line_comment`
- whitespace-only rules are dropped (reported) when unreferenced; the
  translator always emits `skip PG_SKIP_NEWLINE newline` /
  `skip PG_SKIP_TAB tabs`. A newline-/tab-shaped rule referenced from a
  parser rule is kept as a visible `token`.
- duplicate rule names across multi-file inputs are skipped (first wins);
  the sweep prefers `XLexer.g4`+`XParser.g4` pairs (or a single
  directory-named `.g4`). Translation fails rather than writing an empty
  `.pg` when no parser rules were emitted.

Anything else that is still *regular* (literals, ASCII charsets, negated
charsets/singleton groups, fragment and lexer-rule refs, groups,
wildcard, `?`/`*`/`+`, multi-alternative) is compiled to a generated W
matcher via `--matchers FILE` (`pg_lexer_matcher_g_<parser>_<RULE>`,
with `pg_g_<parser>_frag_<NAME>` helpers). Programs import that
module after `libs.extras.grammars.matchers` and before the generated
parser (the sweep script concatenates them in that order). Refuse (report UNRECOGNIZED, as before):

- loops whose body can match empty
- charsets whose ASCII subset is empty after dropping `\u` / bytes > 127
  (otherwise non-ASCII ranges are approximated to the ASCII subset and
  reported as `NOTE ASCII-subset approximation`)
- recursive fragment references, except two special-cased shapes:
  nested delimiters (`D F D | OPEN .*? CLOSE`, Lua/CMake/Rust raw strings)
  and direct self-nested block comments (`'/*' (SELF | .)* '*/'`)
- actions/predicates, `mode`/`pushMode`/`popMode`/`more` commands
  (`type` is allowed; the token-id remap is ignored)

Parser `.` maps to a shared `PG_ANY` token (`any` matcher). Simple parser
`~[...]` / `~('a'|'b')` become synthetic `PG_NEGSET_N` tokens with
generated matchers; token-ref negations like `~(LeftParen|...)` still
refuse.

`'a'..'z'` range atoms are folded into charsets by `antlr4.pg`. Token
lines keep ANTLR declaration order. Known deviation: the pg lexer
resolves literal-vs-token ties in the literal's favor regardless of
declaration order.


## Stress-testing

Beyond `json.pg`/`csv.pg` (both used as working demos — see
`tests/grammars/{json,csv,sql}_demo.w`),
`antlr4.pg` was validated by parsing the real, ~1200-line
`SQLiteLexer.g4`/`SQLiteParser.g4` from `grammars-v4` structurally (no
crashes, no unparsed trailing input), and the full translator was run
against them too: it correctly reconstructs all ~310 parser rules
(including deeply nested group-lifting) and narrowly flags exactly the
handful of lexer rules it can't map (`IDENTIFIER`'s 4-alternative shape,
`NUMERIC_LITERAL`'s hex-vs-decimal split, `STRING_LITERAL`'s doubled-quote
escaping, two `~[...]` negated-set parser atoms, etc.) — with accurate,
specific reasons for each. SQLite itself isn't a target grammar here
(`../sql.pg` already covers common SQL, hand-written); this is included
as evidence the tool degrades honestly on a large real-world input rather
than as a deliverable.

`sweep_grammars_v4.sh` goes further: it runs the translator across all
288 top-level grammars in `grammars-v4` (not just SQLite) and tries to
compile every result with `bin/wv2`, to find both the classifier's real
coverage on a large, varied corpus and translator bugs a handful of
hand-picked samples wouldn't exercise. See `SWEEP_RESULTS.md` for the
numbers, the bugs it found, and next steps.
