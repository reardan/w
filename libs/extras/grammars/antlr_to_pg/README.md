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
  latter retains options{}/tokens{}/channels{}/@header{} bodies and
  rule-body actions/predicates as visible tokens, with comments and quoted
  braces handled while balancing). `antlr4.pg` imports it.
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
- `dependencies.w` — loads explicit inputs, sibling `tokenVocab` grammars,
  and transitive plain grammar imports. Token vocabularies currently require a
  lexer grammar; combined grammars' implicit parser literals need separate work.
  Grammar names, cycles, missing inputs,
  ambiguous supplied/sibling files, incompatible grammar kinds, and imported
  rule overrides are checked before publishing outputs. Plain `tokens { NAME }`
  declarations create token identities for commands such as `type(NAME)`;
  they do not invent matchers. `--dependencies FILE` records actual loaded paths.
- `matchers_{ascii,analyze,emit}.w` — the generated-matcher emitter:
  compiles regular ANTLR lexer rules into W matcher functions (ASCII
  approximation of Unicode charsets, rule-shape analysis / refusals, and
  the emission engine, respectively; see `MATCHER_GENERATION_PLAN.md`).
- `normalize.w`, `normalize_operators.w`, `normalize_lists.w` — bounded expression and list/postfix
  recursion lowering before the structural safety audit. The supported shapes
  and normalized AST contracts are described below.
- `testdata/antlr/` — small ANTLR4 grammars vendored from
  `antlr/grammars-v4` (see its own `README.md`) so the translator has
  something to run against without a network fetch. `antlr_to_pg_test`
  translates them and compares the output with the committed
  `../json.pg`/`../csv.pg` (plus reports and matcher modules);
  `./wbuild grammars_refresh` rewrites those after an intended change.
- `sweep_grammars_v4.sh` / `.py`, `sweep_baseline.json` — the pinned,
  staged corpus sweep and per-grammar regression gate (see "Stress-testing").
  `sweep_current_results.csv` records the current pinned run;
  `SWEEP_RESULTS.md` also retains the historical `sweep_results.csv` measurement.
- `MATCHER_GENERATION_PLAN.md` — design notes for the matcher generator
  (written against an earlier layout, so its paths are historical).
- [`COMPATIBILITY_PLAN.md`](COMPATIBILITY_PLAN.md) — the next implementation
  plan after PRs #689, #690, and #692, with parallel ownership, separate compile
  and semantic gates, exact lexer work, and imported-ANTLR parser prediction.

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

Parser `.` maps to a shared `PG_ANY` token (`any` matcher). Simple parser
`~[...]` / `~('a'|'b')` become synthetic `PG_NEGSET_N` tokens with
generated matchers; token-ref negations like `~(LeftParen|...)` still
refuse.

`'a'..'z'` range atoms are folded into charsets by `antlr4.pg`. The legacy
path groups skips, tokens and literals separately and resolves literal-vs-token
ties in the literal's favor. Stateful lowering below preserves source priority.

## Stateful lexer lowering

Grammars with modes, token-only declarations, remaps, or accumulation commands
select the stateful path automatically; `--stateful` selects it explicitly for
other inputs. The legacy JSON/CSV output remains unchanged. Stateful output
uses generated matchers instead of heuristic built-in substitutions, explicit
mode-local trivia, and longest match followed by declaration order. Implicit
parser literals precede explicit lexer rules; named literal rules retain their
original priority. Distinct rules with the same spelling retain distinct token
identities, including across modes. Parser literals that ambiguously alias
multiple identities or an accumulated/remapped rule remain strict blockers.

Supported commands are `mode`, `pushMode`, `popMode`, `type`, `skip`, `more`,
`channel(HIDDEN)`, and `channel(DEFAULT_TOKEN_CHANNEL)`. Commands execute in
source order after selecting the winner. `more` accumulates text across mode
changes until a terminal rule chooses the token kind. ANTLR permits EOF in a
nondefault mode, so translated grammars explicitly emit `lexer_eof any_mode`;
pending `more` at EOF is still diagnosed conservatively. Skip and hidden-channel
tokens are retained as hidden trivia for complete source reconstruction.
Custom channels, malformed command arguments, and repeated/conflicting commands
remain semantic losses. Best-effort emission omits commands the runtime cannot
represent; strict mode refuses before publishing output.

Generated matchers do not generally backtrack from a greedy subexpression into
its following continuation. Strict stateful auditing therefore refuses
variable-width pieces before another atom unless a narrow disjoint-delimiter
proof applies (for example optional CR before LF, or `~["]*` before `"`).
Repeated variable-width bodies require a prefix-free proof: fixed-width
alternatives with disjoint first-byte sets are supported, while overlapping
choices such as `('aa' | 'aaa')+` remain blocked.
Host actions/predicates, Unicode approximations and nongreedy matching remain
separately audited. Parser wildcards and token negation also remain strict
blockers in this path: their legacy lexer-token fallback does not implement
token-level parser semantics. Strict acceptance is not a conformance proof.

`./wbuild antlr_to_pg_stateful_test` executes local precedence/mode fixtures and
pinned upstream swift-fin/properties parsers. It checks token identity, spans,
line/column positions, mode-local whitespace, source reconstruction, escapes,
continuations, EOF without a final newline, and malformed inputs, alongside
strict-audit and output-preservation checks.


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

`sweep_grammars_v4.sh` runs a pinned set of **291 selected top-level grammar
cases**, not every grammar or subdirectory variant in grammars-v4. Its Python 3
standard-library driver records separate translation, parser generation, W
compilation, and strict-translation results. Compilation appends an empty `main`
and does **not** execute the generated parser. Strict acceptance is a conservative
audit result, not evidence of semantic equivalence. Runtime checks belong in
focused tests with positive/negative examples and token assertions; this sweep
explicitly reports runtime smoke as `not_configured`.

The initial audit at corpus commit `89fd36482e8cb68a4e55df021a8adbc7541b52f2`, measured
with W commit `298246c6d6906650d4cd9c677e93933abd9bf619`: **196 translated,
179 generated and compiled, 10 accepted in strict mode**, out of 291. The original
288-directory cohort compiled 178 cases in this run. The older 258/288 result in
`SWEEP_RESULTS.md` used different upstream inputs and predates safety checks;
those totals are not a direct regression comparison.

The same pinned cases now produce **218 translations, 212 generated/compiled
parsers, and 15 strict translations**, up from PR #690's 215/209/14. The
historical 288-name subset compiles 210. This increment adds Lua, TNT, and V
translation/compile passes, plus strict acceptance for TNT. Every prior
expected pass is retained; `recorded_pass` still preserves the initial
179-compilation audit. The earlier Lisp reclassification remains: its
`ATOM_PART` fragment has no productive base, so its old repetition rewrite
was invalid. See [`SWEEP_RESULTS.md`](SWEEP_RESULTS.md),
[`sweep_current_results.csv`](sweep_current_results.csv), and the
[implementation plan and remaining gaps](EXPRESSION_COVERAGE_PLAN.md).

Run from the W checkout after obtaining the pinned corpus:

```sh
git clone --filter=blob:none --no-checkout https://github.com/antlr/grammars-v4 /tmp/grammars-v4
git -C /tmp/grammars-v4 sparse-checkout init --no-cone
git -C /tmp/grammars-v4 sparse-checkout set '/*/*.g4'
git -C /tmp/grammars-v4 checkout --detach 89fd36482e8cb68a4e55df021a8adbc7541b52f2
./wbuild antlr_to_pg antlr_sweep_harness_test
GV4=/tmp/grammars-v4 libs/extras/grammars/antlr_to_pg/sweep_grammars_v4.sh --jobs 4 --timeout 90
```

`--case json --case csv` selects a focused subset. `--work DIR` (or `WORK`) must
name a new or empty directory; the default creates `bin/grammar_sweep/run-*`.
`GV4`, `WORK`, `JOBS`, and `OUT_CSV` remain supported. CSV now has explicit stage
columns instead of mixing generator failures into `wv2_exit`; JSON contains
the full provenance, commands, return codes, timings, and per-case stages.
Each case retains generated sources, reports, audits, and full stage logs.
Timeouts terminate the process group; timeouts and signal crashes count as
infrastructure errors, even for an already unsupported grammar. A successful exit without required outputs
also fails the gate. A run does not reuse previous output artifacts.

`sweep_baseline.json` pins each selected input path and SHA-256. Selection freezes
the historical shortest `*Lexer.g4`/`*Parser.g4` pair, directory-named grammar,
or top-level `.g4` list. The translator now resolves grammar dependencies, so the
sweep also requires a clean corpus `.g4` worktree with no untracked sibling
grammars; the pinned revision covers every dependency's bytes. Each result records
the actual dependency paths and hashes, including stringtemplate's transitive
`LexBasic`/`LexUnicode` imports. Do not replace selected roots implicitly while
comparing coverage: review those changes separately and retain their provenance.

The gate compares every case's `expected_pass` stages, so gains cannot hide
regressions elsewhere. `recorded_pass` preserves the original audit measurement.
After reviewing new passes, add their stages to `expected_pass`. If a correctness
fix intentionally rejects a formerly accepted grammar, remove only its affected
expectations and add a `reclassified` object mapping each removed recorded stage
to a concrete reason. Do not lower expectations merely to make CI pass or
regenerate the baseline from an arbitrary run. Cases without parser rules or
with upstream symbol defects remain in the denominator.

`.github/workflows/grammar-coverage.yml` fetches the pinned sparse corpus and runs
this gate separately from the offline suite, uploading results and diagnostics.
`antlr_sweep_harness_test` belongs to `./wbuild tests`; its local synthetic tools
exercise stage attribution, missing outputs, timeouts, pin validation, and
per-case regression detection without fetching grammars or requiring ANTLR.

## Semantic preservation and strict imports

`--strict` refuses translation before publishing parser or matcher files when
semantic audit or lowering reports a loss. `--audit FILE` saves deterministic
source-located diagnostics separately from the legacy lowering report; losses
are always printed to stderr, including best-effort runs. Strict mode also runs
the shared ParserGenerator grammar safety check on its emitted model. Direct
and indirect nullable-prefix recursion and zero-consumption repetitions are
refused in both modes because running the generated parser could hang.

The source model now preserves exact action/predicate/option text and spans,
ordered alternative sites with atom positions, labels, greedy/non-greedy
suffixes, grammar dependency/header blocks, lexer mode membership, and ordered
commands including arguments. `at_rule.command` remains only a legacy summary;
new consumers must use `commands`. Semantic site spans borrow tokens from the
ANTLR input tree, whose lifetime must enclose the model. Collection copies raw
text from `g_at_source`; set it before `at_collect_rules`.

Unmapped host code, unresolved dependency blocks (`superClass` included),
custom channels, non-greedy suffixes, Unicode escapes/properties, and unsupported
associativity options remain strict blockers. No foreign code is executed.
This is a conservative blocker check, not an ECMAScript conformance guarantee
or a general ANTLR action translator. On the legacy path, heuristic built-in
matcher substitutions, undeclared implicit whitespace and literal priority
over earlier matchers remain blockers. Stateful lowering addresses these
specific losses without removing the source-semantic checks. Use the JS-specific
provider/grammar for JavaScript compatibility work.

Successfully resolved plain imports, `tokenVocab` options, and `tokens` blocks
are exempted individually from the dependency audit. A mixed option block with
`tokenVocab` and an unsupported option remains an audit loss; resolving its
vocabulary does not certify the foreign option. Missing dependencies and import
cycles are hard failures in both modes. `antlr_to_pg_dependencies_test` exercises
the closure and token identities, runtime remapping, and failure atomicity.

`./wbuild antlr_to_pg_strict_test` checks model preservation, malformed host
blocks, recursion/nullable loops, source hashes, deterministic JS blocker output,
and CLI failure atomicity. The existing JSON/CSV `.pg`, `.report`, and matcher
goldens remain byte-identical. See `testdata/antlr/javascript/README.md` for
pinned upstream provenance and the adaptation audit.

## Bounded recursion normalization

Before the safety audit, the translator lowers action-free direct list and
postfix recursion of the form `A: A suffix | base` to `base (suffix)*`.
Multiple base and suffix alternatives retain their original relative order.
Suffixes must consume input. A sole syntactically empty base is supported;
other nullable bases are refused because greedy optional consumption or an
empty ordered choice can hide a valid continuation. References back to `A`
are admitted only inside mandatory matching
`(...)`, `[...]`, or `{...}` delimiters, including through other rules. This
admits nested terms such as `sum: sum PLUS term | term` with
`term: NUMBER | LPAREN sum RPAREN`, while refusing un-delimited indirect
operands that require separate expression precedence analysis. Rule options,
alternative/element labels,
actions, predicates, and non-greedy annotations exclude a rule from this pass.
Expression recursion is handled only by the separate restricted slice below;
indirect or nullable-prefix cycles remain unsupported and are refused by the
final safety audit.

The output exposes a normalized W AST: the original rule name owns the chosen
base followed by one generated suffix-group node per iteration in input order.
For example, `items: items ',' item | item` produces an `items` node containing
an `item`, then zero or more `items_g1` nodes containing the comma and next item.
Multiple bases use an additional generated base-group node. This contract does
not reproduce ANTLR's left-nested tree or labeled contexts. Existing consumers
that require those contexts need an explicit adapter instead of this lowering.
The generated-group naming follows the translator's existing group-lifting
scheme and can change when the source grammar's groups change.

Nullable lexer fragments are allowed when their enclosing tokens consume;
standalone nullable token rules and repetitions over nullable bodies remain
errors. Lexer recursion rewriting requires consuming loop bodies and preserves
only supported regular shapes. Required recursion without a productive base
case is refused; it is not interpreted as repetition. Recursive groups with
trailing suffixes are refused because flattening would lose the suffix at each
nesting depth. Right-recursive `BASE | PREFIX X` requires provably disjoint
ASCII first-character sets for `BASE` and `PREFIX`; unknown and Unicode-escape
sets are conservatively refused, since generated matcher loops do not
backtrack into a required suffix.

`./wbuild antlr_to_pg_safety_test` exercises nullable-fragment execution,
recursive matcher lengths, normalized list/postfix ASTs, expression evaluation,
unsupported-shape and annotation refusals, complete input consumption, and CLI
output preservation.

### Restricted expression precedence

The expression pass admits direct binary alternatives `expr op expr`. Operators
may be literals, finite lexer alternatives, parser aliases, or groups of these.
Every alias alternative must contain exactly one mandatory atom; cycles,
nullable aliases, commands, modes, options, and semantic annotations refuse.
Operator analysis preserves the source references and AST nodes. Spellings and
named token identities must be distinct across binary tiers. Earlier binary
alternatives bind more tightly; grouped operators share a tier. Default
association is left. A single leading `<assoc=left>` or `<assoc=right>` option
on a binary alternative is recognized; other options remain audit blockers.
This ordering follows ANTLR 4.13.2's
[`LeftRecursiveRuleAnalyzer`](https://github.com/antlr/antlr4/blob/4.13.2/tool/src/org/antlr/v4/analysis/LeftRecursiveRuleAnalyzer.java).

Prefix alternatives retain their source-position binding power: recursive
alternatives before the prefix bind inside its operand, later ones outside.
Thus `-2^2` groups as `(-2)^2` when unary appears first, and as `-(2^2)` when
exponentiation appears first. Compound prefixes must consume, have no hidden
owner recursion, and end in a mandatory finite token boundary. Their parser
aliases and groups also require disjoint FIRST sets and safe continuations:
optional/repeated pieces cannot steal a following delimiter. For example,
`'-' ':'? ':' expr` refuses rather than rejecting valid `-:1` at runtime.

Bases may be consuming sequences, direct expressions enclosed in mandatory
matching parentheses/brackets/braces, or indirect calls back to the expression
through consuming parser rules. Indirect calls retain full-precedence semantics.
The owner must have a productive derivation, and nullable-prefix recursion
still refuses. Compound and recursive bases require distinct first tokens from
other bases and prefixes; ambiguous ordered choices remain excluded.

Postfix alternatives may precede all binary alternatives. These leading
postfixes share one highest-binding repeated tier, allowing mixed member,
index, and call chains. Their consuming tails require disjoint FIRST sets from
other postfixes and binaries, with nested recursion guarded by delimiters.
Postfixes after a binary tier and prefixes between postfix alternatives refuse.
Ternaries, indirect binary operands, labels, and host code remain excluded.
Unsupported forms stay intact for the final structural audit; normalization
never disables the recursion check.

The normalized AST retains the original `expr` node with a generated lowest
precedence child. Helpers are `<owner>_primary` and `<owner>_precN`, with `N=0`
the tightest tier (the shared postfix tier when present); underscores avoid
existing rule-name collisions. Binary tiers contain their tighter operand
followed by operator/RHS nodes in input order. Left-associative tiers repeat
these nodes; right-associative tiers contain at most one whose RHS calls the
same tier. Postfix tiers retain every tail element in mixed-chain order.
Primary nodes preserve base and prefix children; the final prefix operand
calls the tier selected by its source position. Operator aliases and groups
retain their normal AST nodes. This W AST contract preserves grouping without
claiming ANTLR parse-tree identity.

The executable fixture verifies `1+2*3`, `8-3-1`, `2^3^2`, explicit parentheses,
unary chains, complete input consumption, and malformed expressions. Lexer
semantic audit results remain independent of successful expression lowering.

`antlr_to_pg_expressions_test` covers named operators, compound bases, unary
binding at three source positions, ambiguous-shape refusals, and evaluated ASTs.
`antlr_to_pg_nested_lists_test` covers nested/postfix ASTs, empty lists, and
nullable/unguarded recursion refusals. `antlr_to_pg_coverage_next_test` executes
unmodified pinned TinyC, MicroC, and Arithmetic grammars; its
[fixture notes](../../../../tests/grammars/antlr_coverage_next/README.md) document
remaining ordered-choice limitations. These runtime checks supplement compile
coverage without claiming whole-grammar ANTLR equivalence.

`antlr_to_pg_operators_test` exercises finite aliases, AST preservation, and
atomic refusals. `antlr_to_pg_expression_tiers_test` covers mixed postfix chains,
compound prefixes, nested bases, precedence, and unsafe continuation refusals.
`antlr_to_pg_expression_coverage_test` executes unmodified pinned Lua and TNT
grammars; its [fixture notes](../../../../tests/grammars/antlr_expression_coverage/README.md)
document the tested subset and remaining semantic gaps. V has compile coverage
only. See [the increment plan](EXPRESSION_COVERAGE_PLAN.md).
