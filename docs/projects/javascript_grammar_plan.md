# JavaScript grammar and lexer infrastructure plan

Status: implemented initial integration; full ECMAScript compatibility remains
an explicit follow-up. See [the implemented API, examples, qualification gates,
and limitations](javascript.md). The sections below preserve the implementation
plan and its acceptance goals; the table describes the starting point, not the
new runtime. Prepared against
`origin/main` at `0bc004f0628c8bed081be66449b844e91a7f765c` for
[#492: JavaScript grammar + compatibility](https://github.com/reardan/w/issues/492).

Deliver a JavaScript parser usable by W programs, with the infrastructure
needed to parse real source, construct syntax trees, and transform source.
Prove context-sensitive tokenization with a small grammar before expanding
JavaScript coverage. The infrastructure milestones below are prerequisites
for #492, not sufficient by themselves to close it.

**What the current implementation provides and what must change**

| Surface | Current implementation | Needed for JavaScript |
| --- | --- | --- |
| Lexer generation | `generator.w` emits an eager whole-input `_lex`; matchers receive input and byte index | Per-parse lexer state, modes, and incremental token production with parser-selected lexical goals |
| Tokens | Byte spans, default/hidden channels, lossless `all_tokens` | Preserve this contract; expose line terminators in intervening trivia |
| Backtracking | `token_stream.w` marks and rewinds only a token index | Restore lexer and parser context, speculative tokens, and diagnostics together |
| Predicates | `&{ expr }` only at the start of streaming-mode alternatives | Pure predicates at relevant positions in AST-mode sequences; rollback-safe context scopes |
| ANTLR reader | `antlr4.pg` hides balanced action/predicate blocks; `ast.w` drops element options and does not retain mode declarations | Preserve semantic constructs, their locations, mode membership, and ordered commands before translating |
| ANTLR commands | Model retains one command name; `type` remapping is ignored | Retain command arguments and order; implement supported semantics or reject explicitly |
| Expression translation | Groups are lifted into helper rules; no general left-recursion conversion | Diagnose recursive cycles; adapt JavaScript expressions into explicit precedence rules |
| Character matching | Inline matchers are ASCII; translated Unicode sets may be approximated | Explicit Unicode-aware JS matchers with pinned data and no silent approximation in compatibility builds |

Implementation references: [ParserGenerator](parser_generator.md),
[grammar collection](../../libs/extras/grammars/README.md), and
[ANTLR translator](../../libs/extras/grammars/antlr_to_pg/README.md).
The current `source_writer.w` emits W code; it is not a JavaScript printer.

**Architecture decisions**

- Keep existing eager lexer APIs and existing grammar behavior as the default.
  Add an opt-in stateful path. Existing W/C grammars and six grammar demos
  remain regression fixtures, including their token-priority behavior.
- Put generic lexer state, mode stacks, checkpoints, predicate terms, and
  provider interfaces under `libs/extras/parser_generator/`. Put JS lexical
  goals, template interpolation context, identifier rules, and syntax-specific
  predicates under a new `libs/extras/javascript/` support module.
- Treat lexer modes and lexical goals as distinct inputs. A mode controls
  which rules are active; a parser-selected goal determines whether `/`
  introduces division or a regex and whether `}` resumes a template.
  A previous-token heuristic is not the compatibility contract.
- Use a generated AST-mode parser for the initial JS slice. Enable pure
  predicates and explicit scoped context operations there; keep arbitrary
  side-effecting parser actions forbidden in backtracking AST mode.
- Begin with an explicitly adapted `javascript.pg`, referencing pinned
  upstream sources. Do not make a general ANTLR target-language translator,
  automatic left-recursion conversion, or `more` support prerequisites.
  The importer must explain and reject anything it cannot preserve.
- Expose an owned parse result retaining source, tokens, diagnostics, and the
  tree until explicitly freed. Keep raw spellings and source spans available
  for later printers and edits. A failed lex or parse cannot be reported as
  successful merely because a partial tree exists.

Proposed API/directive names in this plan are design sketches. Final spelling
should be settled in each implementation PR; the behavior and tests are the
acceptance contract. Use distinct names such as `lexer_mode` so lexical modes
do not collide with the existing `mode streaming` parser directive.

**1. Preserve ANTLR semantics and make omissions visible**

Files: `antlr_to_pg/{antlr4.pg,antlr4_matchers.w,types.w,ast.w,classify.w,
emit.w,matchers_analyze.w}`, `tools/antlr_to_pg.w`, and translator fixtures.

Replace `skip ACTION` with explicit action/predicate nodes. Preserve raw text,
source spans, alternative/sequence position, mode membership, command lists
with arguments, rule options, associativity, and greedy/non-greedy suffixes.
Retain relevant grammar options (`tokenVocab`, `superClass`) as dependencies.
Handle comments and quoted braces in action blocks; diagnose malformed blocks.
Parse options/header blocks as such rather than confusing them with rule
actions. This preservation step does not execute or translate foreign code.

Add a strict translation option that fails on unmapped predicates/actions,
unsupported modes/commands, Unicode approximation, ignored precedence or
matching semantics, unresolved vocabulary, and unsupported recursive rules.
Keep exploratory best-effort translation available, but always report semantic
loss with filename, rule, and location. Compatibility targets use strict mode.
Validate before publishing output files, so failure leaves no partial parser.

Detect direct and indirect left recursion, including cycles through nullable
prefixes, and zero-consumption repetition hazards. Share grammar-side cycle
checks with ParserGenerator rather than allowing generated recursion to hang.
Preserving non-greedy syntax is necessary even where the first implementation
rejects it or maps it to an explicitly verified custom matcher.

Exit gate: tiny fixtures prove that two commands and their arguments survive,
predicates cannot silently disappear, right-associativity is retained, and
unsupported constructs produce deterministic failures. Existing JSON/CSV
translation goldens remain stable unless a separately documented correction
is necessary. Record the pinned upstream JS grammar's complete blocker list.

**2. Add a stateful lexer provider and lossless incremental tokens**

Files: `parser_generator/{lexer.w,token.w,token_stream.w,generator.w,
runtime.w,diagnostics.w}`; a new lexer-state module if needed.

Introduce a per-parse token provider with input bounds, byte position, location,
mode state, opaque host context, and snapshot/restore hooks. No mutable global
state: two parser instances must be interleavable. Expose lazy peek/consume
through the stream while preserving the existing eager stream path. A new
length-aware entry point can wrap the old null-terminated API; explicitly
handle embedded NUL rather than silently accepting a truncated source.

Retain trivia, invalid-token spans, raw source bytes, and stable EOF behavior.
Add a line-break-before query derived from trivia, including block comments.
For the JS provider, LF, CR, CRLF, U+2028, and U+2029 must follow the JS line
terminator rules, with CRLF counted once. Keep byte spans canonical and document
column units; avoid silently changing existing grammars' location conventions.

Expose a generated parse-from-provider entry point returning an owned parse
result. Retain the legacy `_parse` and `_lex` entry points. Tests must cover
provider errors, invalid input, complete-input consumption, and cleanup.

Exit gate: a small context-free grammar parses identically through eager and
lazy paths (token kinds/text/spans, tree shape, diagnostics). Byte-for-byte
source reconstruction succeeds, including comments and trailing trivia; two
interleaved sessions do not share state. Repeated EOF lookahead is stable.

**3. Make speculation transactional before adding contextual JavaScript**

Files: `token_stream.w`, `diagnostics.w`, `ast_node.w`, `generator.w`,
`analysis.w`, and the provider state module.

Add checkpoint/restore/release operations for the opt-in parser path; preserve
the old integer mark/rewind API for eager consumers. A checkpoint covers cursor,
provider byte/location state, lexer-mode and template stacks, lexical goal,
parser context scopes, token/trivia buffer lengths, and diagnostic length.
Successful attempts release their checkpoints; failed attempts restore them.
All failure exits and error-recovery paths must obey this lifecycle.

Start without a context-sensitive token memoization cache: invalidate the
speculative suffix and rescan on rollback. If caching is later justified,
its key must include lexical goal and relevant state, not just source offset.
Setting a goal must happen before speculative lookahead, including generated
FIRST-set guards. A token buffered under a different goal cannot be reused.

Keep discarded tokens/nodes safely owned until parse-result cleanup, or prove
they have no live references before reclaiming them. Never truncate/free a
token while an allocated AST node still borrows it. The active `all_tokens`
sequence must contain only the selected tokenization, without duplicate trivia.
Track the furthest failure by source byte offset with stable copied diagnostic
data; token indices from different tokenizations are not comparable. Discard
branch-local diagnostics while retaining the information needed for the final
error. Bound retained speculative storage with explicit resource limits.

Exit gate: an alternative changes modes, emits trivia and a diagnostic, then
fails. Its sibling must observe exactly the pre-attempt state and a clean
diagnostic list. Nested checkpoints, recovery, and both successful/failed
cleanup pass allocator checks. Add counters for scanning, allocations, and
rollback to expose accidental repeated work in later corpus tests.

**4. Generate lexer modes, guarded candidates, and selected-token actions**

Files: `grammar_model.w`, `grammar_reader.w`, `generator.w`, lexer state,
and `antlr_to_pg/pg.pg` (the translator's emitted-DSL validator).

Add declared lexer modes, active-mode membership, ordered command lists, token
kind remapping, and channels. Implement `mode`, `pushMode`, `popMode`, `type`,
and `channel`; define lossless handling of `skip` as retained non-parser trivia.
Retain distinct channels where needed, with diagnostics on error-channel tokens.
Reject `more` until token accumulation and EOF semantics have their own tests.
Do not inject unconditional newline/tab skipping into template or string modes.

Add pure candidate predicates and host callbacks that update lexer state only
after the winning rule is selected. Evaluate guards at their declared match
position; only support placements whose semantics are implemented. Matchers
that lose maximal-munch selection must not push modes or change brace depth.
Callbacks may mutate checkpointed lexer state, not external program state;
rescanning after rollback may replay them.

Preserve global rule declaration order across literals, tokens, and skips for
an opt-in ANTLR-compatible priority policy. The legacy policy keeps literal
priority on equal lengths. Validate mode references, invalid command
combinations, stack underflow, and EOF inside an unfinished token/mode. Reject
zero-length matches that could prevent forward progress.

Exit gate: a small interpolation grammar handles nested templates and braces,
including `type` remapping on closing backticks. Losing candidates have no
effects; rollback restores the full mode stack. Equal-length match tests cover
both policies. Unterminated interpolation and mode-stack misuse fail cleanly.

**5. Add pure AST predicates and scoped parser-directed lexical goals**

Files: `grammar_model.w`, `grammar_reader.w`, `analysis.w`, `generator.w`,
provider interfaces, and new JS context helpers.

Separate predicate safety from action safety in `pg_action_safety_check`.
Permit pure zero-width predicates at supported sequence positions in AST mode,
including after a consumed token. Predicates read parser context, lookahead,
and preceding trivia; they do not emit diagnostics or mutate semantic state.
They can run repeatedly during backtracking. Reject unsupported action forms
at generation time and preserve the existing streaming-mode contracts.

Add explicit scoped context/goal operations, with automatic restoration on
both success and failure. Use these for expression-entry lexical goals and,
later, function/async/generator/module context. Do not smuggle state mutation
through a supposedly pure predicate. Update nullability, FIRST-set dispatch,
and left-factoring analysis: an operation that affects tokenization cannot be
hoisted, skipped, or guarded using tokens read under the previous goal. Disable
those optimizations for affected paths until equivalence is established.

The JS support layer chooses the regex/division and template-tail goals based
on syntactic position. Generic infrastructure carries opaque goal identifiers
and state; it does not contain a JavaScript keyword table.

Exit gate: AST-mode mid-rule predicates accept/reject correctly through optional
terms, repetitions, and shared prefixes. A failed branch re-lexes the same byte
offset under a different goal without reusing an incompatible token. Existing
streaming predicate/action fixtures retain their behavior and rejection tests.

**6. Prove a small JavaScript grammar end to end**

Files: new `libs/extras/javascript/` helpers,
`libs/extras/grammars/javascript.pg`, and `tests/javascript/` fixtures.

Implement the smallest coherent slice containing expressions, blocks, variable
declarations, functions/return, if-statements, throw, regex literals, and nested
template interpolation. Define goal transitions and newline-sensitive rules
explicitly. Implement statement termination at the parser level: making every
semicolon optional or treating every newline as a terminator is incorrect.

Adapt expressions into reviewed precedence tiers with appropriate associativity.
Do not emit the upstream left-recursive `singleExpression` rule unchanged.
Include trees in assertions, since accepting a string does not prove grouping
or associativity. Add syntax-context checks needed by the selected slice;
document the later semantic/early-error pass separately.

| Fixture | Required assertion |
| --- | --- |
| `const ratio = a / b / c;` | Left-associated division |
| `const ok = /ab+c/i.test(s);` | Regex literal and following member/call |
| `if (ok) /x/.test(s);` versus `f(ok) / n;` | The same preceding `)` does not imply the same lexical goal |
| ``const t = `a${{x: `b${n}`}.x}c`;`` | Nested template, nested object braces, return to outer template |
| `function f() { return\n/x/; }` | Bare return followed by a regex expression statement |
| `function f() { return /*\n*/ value; }` | A line break inside a comment restricts return |
| `throw\nerror;` | Reject the restricted newline |
| `a\n++b;` | Two expression statements; no postfix increment on `a` |
| `a = b\n/hi/g.exec(c);` | Division continuation, no inserted semicolon |
| `a - b - c`, `a ** b ** c`, `a = b = c` | Expected left/right association |
| Unterminated regex/template/comment | Stable diagnostic and no hang |

In the fixture table, `\n` denotes an actual source line break in the test.
Include regex character classes/escapes, comments between tokens, CRLF and
Unicode line separators, and multiple parses in one process. Test `/` after
object expressions and statement blocks as well as after parentheses.

Exit gate: exact tree/token expectations, rejection locations, source
reconstruction, and repeated parse/free tests pass. A pinned independent JS
parser or Node syntax check agrees on acceptance for this slice. Execution
checks use controlled fixtures with known results, not arbitrary corpus code.
Only after this gate should broad grammar expansion begin.

**7. Add reproducible import adaptation and expand compatibility**

Vendor the upstream lexer/parser and required base-class sources with licenses,
commit identifiers, and hashes. Start from the audited revision linked below;
verify it again when implementation begins. Never fetch a floating branch in
normal tests. The upstream grammar is a reference, not proof of ECMAScript
conformance.

Add an explicit JS adaptation profile: map recognized predicate/action sites
to reviewed W helpers, apply the expression-precedence rewrite, and record
every adaptation. Match mappings to the pinned rule/alternative/site and
expected source text. An unknown or changed site fails strict regeneration.
Do not blindly paste `this.*` code into W or broadly strip predicates.
If a rewrite cannot yet be generated faithfully, keep a reviewed hand-adapted
rule with a checked patch and provenance; report it as an adaptation.

Use exact JS matchers for strings, numbers, regex boundaries, identifiers and
identifier escapes. Pin Unicode identifier/property data appropriate to the
chosen ECMAScript baseline; raw UTF-8 byte acceptance and ASCII truncation are
insufficient. Preserve raw text separately from decoded values. Test astral
identifiers, invalid escapes/UTF-8, `$`, ZWNJ/ZWJ continuation, keyword escapes,
numeric boundaries, and template escape rules as their features are enabled.

Set ES2020 Script and Module syntax as the proposed first compatibility target;
track newer features and Annex B individually. Expand through arrows,
destructuring, classes, modules, async/generators, optional chaining, nullish
coalescing, and remaining statements. Add strict-mode/directive and relevant
early-error validation, including valid assignment targets and return/await/
yield context. Explicitly track unsupported syntax; do not claim a complete
edition until its agreed conformance gates pass.

Exit gate: regeneration is deterministic; every import override has a fixture;
the supported-feature matrix has no unexplained acceptance differences. Pin
Test262 syntax cases with script/module and strict-mode metadata, separating
parse/early-error expectations from resolution/runtime tests. Add a small
licensed real-source corpus and report passes, failures, exclusions with reasons,
time, and memory. Compare growth across input sizes, not only one elapsed time.

**8. Finish the consumer APIs and examples required by #492**

Build a stable JS AST facade over the grammar tree, then add node constructors,
visitors/replacement, a precedence-correct printer, and validated source-span
edits. Specify supported node kinds and ownership. Printer output must not
depend on original tokens for newly constructed nodes. Preserved-source edits
must reject overlaps and retain untouched bytes. Source maps and general
scope-aware renaming can be separate follow-ups.

Ship the parse/inspect, build/print, and import-specifier transformation examples
under `examples/javascript/`. Tests cover parse-print-parse normalized tree
equality, builder output, deterministic formatting, string escaping, comment
handling, and transformation goldens. Reparse transformed output independently;
include controlled execution comparisons for semantics-preserving examples.

Close #492 only after the declared compatibility scope, all three examples,
documentation, and regression gates pass. Finishing lexer infrastructure alone
does not close the JavaScript compatibility work.

**Implementation order and verification**

Milestones 1 through 6 should land in dependency order, each as one or more
reviewable PRs with fixtures. Milestones 7 and 8 expand the proven slice. Start
with milestone 1: it gives an honest import report and prevents later work
from being evaluated against silently weakened grammars.

New tests own their targets through source `# wbuild:` directives. Proposed
target families are `parser_generator_stateful_lexer_test`,
`parser_generator_checkpoint_test`, `parser_generator_ast_predicate_test`,
`antlr_to_pg_strict_test`, and `javascript_*_test`. The implementation combines
checkpoint coverage in `stateful_runtime_test` and AST predicates in
`parser_generator_stateful_lexer_test`; JavaScript targets use the named family.
Deterministic W tests belong in `./wbuild tests`. Pin external oracle versions
and corpus data in a dedicated compatibility CI target with no implicit skips;
do not make Node/ANTLR a runtime dependency of a W parser.

For every implementation PR, run `wv2 check --json` for edited W roots, fix
warnings, select targets using `wtest changed`, and inspect `wtest archs --check`
for affected shared modules. Exercise the applicable parser generator,
translator, W/C grammar, grammar-demo, metadata, and manifest checks. Run
`./wbuild tests` on the supported Linux environment before completion, plus
native Darwin checks where available. Keep the parser-generator import graph
compatible with the pinned seed; no seed promotion is implied by this plan.
If compiler-core files change, apply the repository's coverage gate as well.

Regression evidence must cover both successful and malformed inputs, independent
parse sessions, token/tree ownership, and the existing eager path. Preserve
existing generated-output goldens unless an intentional semantic correction
is documented. Measure scanner/parser work on increasing input sizes; introduce
memoization only if needed and only with state-correct keys.

Implementation verification on 2026-10-09: the native qualification script
passes runtime/generator/importer tests, all eight JavaScript suites, examples,
Unicode regeneration, 34 syntax cases, three growth cases, and three controlled
execution comparisons, plus two independently executed consumer examples.
The native self-host fixpoint and manifest/metadata
checks pass. Legacy generated grammars and JSON/CSV translation goldens remain
unchanged. After updating to `origin/main` at `ed379420` (including #621),
`./wbuild tests` passes on Apple Silicon: 18 targets, including the native
self-host fixpoint and macOS discovery/transitive-selection regression gate.
The host policy explicitly dispatches to `tests_darwin` and reports 1,061
excluded cross-platform targets; Linux full-suite execution remains outstanding.
The complete separate JavaScript native qualification also passes on this base.
The earlier `unknown target wprof` and native dependency-query blockers are
resolved by #621.

The compatibility CI job pins Node and uploads its report. Initial syntax and
consumer API milestones are implemented, with the exclusions in
[javascript.md](javascript.md); the full-edition gate in milestone 7 remains
open. The AST facade intentionally covers fewer constructs than the concrete
parser. Do not interpret completed infrastructure as full Test262 conformance.

**Primary references**

- [Pinned upstream JavaScript lexer](https://github.com/antlr/grammars-v4/blob/89fd36482e8cb68a4e55df021a8adbc7541b52f2/javascript/javascript/JavaScriptLexer.g4)
  and [parser](https://github.com/antlr/grammars-v4/blob/89fd36482e8cb68a4e55df021a8adbc7541b52f2/javascript/javascript/JavaScriptParser.g4).
  The lexer requires modes and host hooks; the parser requires predicates and
  expression adaptation. Their base classes must be included in the audit.
- [ECMAScript lexical grammar](https://tc39.es/ecma262/multipage/ecmascript-language-lexical-grammar.html),
  particularly lexical goals and automatic semicolon insertion. Pin the selected
  edition when making compatibility claims; this URL tracks the living spec.
- [Test262 interpretation rules](https://github.com/tc39/test262/blob/main/INTERPRETING.md)
  for parse/early errors, strict-mode variants, and module metadata.
