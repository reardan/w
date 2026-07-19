# ParserGenerator

This is the first implementation milestone for
[reardan/w#15](https://github.com/reardan/w/issues/15): a standalone
ParserGenerator and runtime for generated parsers.

## Why it is outside the compiler core

The W compiler parses and emits machine code in one pass. It intentionally has
no AST or IR. ParserGenerator therefore lives under `libs/extras/` as optional
tooling and generates ordinary W modules instead of changing `compiler/`,
`grammar/`, `code_generator/`, or the bootstrap path.

## Layout

- `libs/extras/parser_generator/token.w`: token kind, text, channel, and source
  span.
- `libs/extras/parser_generator/token_stream.w`: lookahead, consume, mark, and
  rewind.
- `libs/extras/parser_generator/lexer.w`: reusable character scanner helpers.
- `libs/extras/parser_generator/diagnostics.w`: structured syntax diagnostics.
- `libs/extras/parser_generator/ast_node.w`: AST nodes, child lists, metadata,
  and simple visitor/listener traversal hooks.
- `libs/extras/parser_generator/grammar_reader.w`: parser for the first grammar
  description format.
- `libs/extras/parser_generator/generator.w`: deterministic W source emitter.
- `tools/parser_generator.w`: CLI wrapper.

Generated parsers import `libs.extras.parser_generator.runtime`, which pulls in
the reusable runtime modules.

## Grammar format

The initial format is line-oriented:

```text
parser sample
token WORD letters
token NUMBER digits
token IDENT = [a-zA-Z_] [a-zA-Z0-9_-]*
fragment HEX_DIGIT = [0-9a-fA-F]
token HEX = "#" ("x" | "X") HEX_DIGIT+
skip SQL_COMMENT = "--" [^\r\n]*
literal COMMA ","
start list
rule value = WORD | NUMBER
rule list = value value* EOF
```

Supported token matchers are runtime helper names such as `letters`, `digits`,
`identifier`, `number`, `string`, `char_literal`, `newline`, `tabs`, and `any`,
which map to `pg_lexer_matcher_<name>`. `skip <NAME> <matcher>` declares
comment or trivia matchers. Skip matches are emitted as hidden-channel tokens
(negative kinds starting at -3): the parser never sees them, but they stay in
the stream's `all_tokens` list so tools can reproduce the input.

Tokens and skips may instead use an inline matcher expression after `=`:

```text
token IDENT = [a-zA-Z_] [a-zA-Z0-9_-]*
token HEX = "#" ("x" | "X") [0-9a-fA-F]+
token NEWLINE_TOK = "\r"? "\n"
token NUMCONST = DECNUM | HEXNUM | CHAR
```

Matcher expressions are byte-oriented and ASCII-only. They support string
literals, character classes with ranges and leading `^` negation, grouping,
alternation (`|`), concatenation, and the `?`, `*`, and `+` suffixes. Standard
`\n`, `\r`, and `\t` escapes work in strings and classes; a backslash also
quotes punctuation such as `]`, `-`, `\`, or `"`.

`fragment <NAME> = <expression>` defines a reusable matcher without creating a
token kind. Expressions may reference fragments or token definitions,
including tokens backed by an existing named matcher. Forward references are
allowed; unknown references and reference cycles are errors. A `*` or `+`
operand must consume at least one byte on every successful match, preventing
generated matcher loops from stalling.

Rule terms are token names, literal names, rule names, or `EOF`. A term may end
with `?`, `*`, or `+`. Alternatives are separated by `|`. Parenthesized groups
are intentionally left for a later milestone; `{ code }` action terms and a
`&{ expr }` predicate leading an alternative are supported in `mode
streaming` grammars only (issue #329 milestone 4 — see below).

## Lossless token stream

Generated lexers are lossless: inline whitespace runs become hidden tokens
with the reserved kind `pg_token_whitespace_kind()` (-2), skip rules (comments)
become hidden tokens with their own kinds, and invalid characters become hidden
`pg_token_invalid_kind()` (-1) tokens alongside their diagnostic. Every token
records `offset`/`length` (zero-based byte span) in addition to one-based
line/column. `pg_token_stream_source()` concatenates all channels back into the
original input byte for byte; `pg_token_stream_all_count()` /
`pg_token_stream_all_get()` expose the full stream to tools such as formatters.
The parser-facing cursor (`peek`/`consume`/`mark`/`rewind`) only sees
default-channel tokens, so grammar behavior is unchanged.

AST nodes carry spans: `pg_ast_first_token()` / `pg_ast_last_token()` give the
first and last token a rule node covers (0 for nodes that matched only
optional terms), maintained as children are attached.

## Error recovery

`recover <rule> <sync-token> [<skip-token>...]` enables multi-error parsing
for repetitions (`*`/`+`) of `<rule>`. When an iteration fails before EOF, the
generated parser records a `syntax error` diagnostic at the furthest token any
attempt reached, wraps the skipped tokens in an `error` node (kind
`pg_ast_error_kind()`, -1), consumes through the next sync token whose
successor is neither the sync token nor one of the skip tokens, and resumes
the repetition. The W grammar uses `recover top_item NEWLINE TAB`, which
resynchronizes at the next line that starts at tab level zero, so one bad
top-level construct yields one diagnostic instead of aborting the parse.
Recovery is intended for repetitions in single-alternative contexts (like the
start rule); a recovered repetition inside an alternative that later fails
would leave its diagnostics behind after backtracking.

Generated lexers use longest-match token selection, both among matcher
alternatives and among token declarations. Equal-length token matches are
resolved by declaration order. Exact `literal` directives retain their
existing priority over an equal-length token match, so a grammar can list
generic identifiers and exact keyword/operator literals together: `integer`
stays an identifier, while `int` can become a keyword token. Declared
token/skip/literal rules are attempted before the implicit inline-whitespace
fallback, allowing a matcher such as `"\r"? "\n"` to consume CRLF as one
token.

Since 2026-07 (issue #329 milestone 1) the generated selection code is a
first-byte dispatch instead of a linear try-every-matcher sweep: the lexer
branches on the current byte (a log-depth comparison tree over first-byte
ranges) and only runs the matchers that can start with that byte. Literals
sharing a first byte compile to a nested comparison trie (`<`, `<<`, `<<=`),
and identifier-shaped literals are matched by scanning the identifier once
and probing a length-bucketed keyword chain. This is purely an
implementation change inside the generated `_lex` function; the selection
semantics above are preserved exactly (`generated_matcher_expressions_test`
pins the edge cases).

Since 2026-07 (issue #329 milestone 2) the generated rule bodies use LL(1)
analysis (`libs/extras/parser_generator/analysis.w`: per-rule nullability,
FIRST sets, and attempt purity, computed by fixpoint over the grammar)
instead of blindly attempting every alternative in order. Alternatives and
`?`/`*`/`+` terms are guarded by first-set membership tests on the current
token's kind, so a non-matching alternative is skipped without allocating
its `pg_ast_node` or entering its sub-parses; where alternatives' FIRST
sets are disjoint this is committed dispatch. Consecutive alternatives
sharing identical leading plain terms are left-factored mechanically: the
shared prefix is parsed once and only the suffix choice dispatches (e.g.
`extern_decl`'s two `KW_EXTERN type_ref IDENT` alternatives). A guard is
only emitted where skipping is provably unobservable — the guarded
sequence cannot match empty and a first-set miss fails without consuming
tokens or recording diagnostics — so nullable alternatives, overlapping
FIRST sets, and recover-marked repetitions keep the original ordered
mark/rewind backtracking, and accept/reject behavior, AST shape, and
furthest-token error positions are unchanged (verified by differential
AST comparison of the whole tracked `.w` corpus plus truncation/mutation
error-path fuzz against the previous generator). `tools/parser_generator.w
--report` prints the rules kept on the backtracking path with their
colliding FIRST tokens — the left-factoring worklist for milestone 3
(w.pg: 109 of 118 rules committed; c.pg: 80 of 99). The
`parser_generator_w_test` whole-repo sweep runs ~4x faster (78s to 19s).

Since 2026-07 (issue #329 milestone 3) an optional `mode streaming`
directive after the `parser` line switches a grammar's generated output
from the AST-building parser above to a **streaming, listener-callback**
parser: no `pg_ast_node` tree, no `pg_token_stream_mark`/`rewind`
anywhere, ever. This is legal only where milestone 2's analysis proves
the *entire* grammar is committed dispatch, which is a stronger
requirement than `--report`'s per-rule "committed" count: streaming mode
also refuses a grammar containing any `?`/`*`/`+` term over a *rule*
reference (only a token/literal repeat is committed by construction —
its first set is one kind — a rule-referenced repeat still wraps a trial
mark/rewind attempt today even when its entry is FIRST-set guarded,
because a FIRST-set match proves the decision to enter is right, not
that the callee rule goes on to succeed) and any grammar declaring a
`recover` directive (resynchronization is itself bounded backtracking).
`pg_streaming_check` (`libs/extras/parser_generator/analysis.w`) runs
both checks before generation and, on any violation, prints the same
rule/alternatives/colliding-tokens diagnostic `--report` prints (for the
choice-conflict case) or a one-line "requires token or literal" message
naming the offending rule reference (for the repeated-rule-reference
case); `pg_generate_parser` returns 0 instead of emitting an unsound
parser, and `tools/parser_generator.w` reports "generation failed" and
exits 1. There is no bounded-buffering fallback: a backtracking region is
rejected outright, not silently narrowed.

Where a grammar clears both checks, every rule commits to an alternative
with a single first-set test (an `if`/`else if` chain, reusing the same
choice-unit planning and left-factoring as AST mode) and then runs that
alternative's terms in a straight line — no rewind exists to reach for,
since once a guard chose an alternative there was never a sibling to
fall back to. A mandatory term that still fails despite the guard (a
genuine syntax error, not an ambiguity) is therefore a direct "record a
diagnostic, return failure" up through the call chain, rather than AST
mode's rewind-and-try-the-next-alternative. The callback surface is a
generated `<parser>_listener` struct: one `void* context` field, one
shared `on_token` fired for every consumed token (any rule), and an
`on_enter_<rule>`/`on_exit_<rule>` pair per rule, fired with the token
stream so a listener can inspect the triggering token. Any field left
unset (`<parser>_listener_new()` zeroes them all) is simply skipped —
`on_enter_<rule>` fires before that rule's alternative is even chosen, so
a rule that enters but never exits is exactly the rule that failed. The
entry point is `<parser>_parse_streaming(input, filename, diagnostics,
listener)`, returning a plain success flag; as with the AST entry point,
the grammar's start rule is expected to end with an `EOF` term.
`tests/parser_generator/streaming_sample.pg` /
`generated_streaming_test.w` are a small worked example (assignments,
a brace-delimited block of one-or-more numbers, a two-alternative value
rule, and right-recursive statement lists) exercising enter/exit/token
callbacks over real input, a genuine syntax-error path, and the
rule-referenced-repeat rejection.

Since 2026-07 (issue #329 milestone 4, the last of the streaming-mode
milestones) a rule alternative may contain `{ code }` action terms and
lead with a `&{ expr }` semantic predicate. Both are **streaming-mode
only**: AST mode has no commit point to run an action at exactly once
(every rule there still marks and rewinds), so a grammar carrying either
in AST mode is rejected at generation time, by rule name, before the AST
emitter ever runs (`pg_action_safety_check` in `analysis.w`).

- **`{ code }` action terms** are verbatim W source, copied into the
  generated rule function at exactly that position in the alternative and
  executed once the alternative is committed to. An action may hold
  several statements, one per (trimmed) source line, but each line must be
  a single flat top-level statement — an action body cannot itself open a
  nested indented block (`if`/`while`/etc.); split control flow like that
  into a plain function and call it from the action instead. Because
  streaming mode already requires the *entire* grammar to be committed
  dispatch (no `pg_token_stream_mark`/`rewind` anywhere in the generated
  file), an action term is safe by construction the moment its grammar
  passes `pg_streaming_check` — there is no backtracking region left
  anywhere for it to run inside of more than once.
- **`&{ expr }` semantic predicates** may appear only as the first term of
  an alternative. Where two or more alternatives share an overlapping
  first set, a predicate-headed one is tried in declaration order among
  them — `if (<expr1>): ... else if (<expr2>): ... else if
  (<first-set test>): ...` — gated purely by the predicate's boolean
  value, not combined with a first-set test, so a predicate can resolve
  exactly the kind of context-sensitive ambiguity the hand-written
  compiler resolves with its own symbol-table-aware gates (e.g.
  `variable_declaration()`'s `type_lookup(token) >= 0`). The predicate
  expression must be side-effect-free and a single line; this is a
  documented author contract, not something the generator enforces or
  proves. `analysis.w`'s conflict detector (`pg_report_choice`, also used
  by `--report` and `pg_streaming_check`) exempts a predicate-headed
  alternative from the first-set overlap check in both directions — its
  dispatch is resolved by the predicate, not by first-set disjointness —
  but two *unpredicated* overlapping alternatives are still flagged
  exactly as before milestone 4.
- **`$n` / `text(n)` bindings**: inside an action, `$n` or `text(n)` is the
  text of term *n* (1-based, counting every term in the same alternative,
  action/predicate terms included) — deliberately narrow for v1: `n` must
  name an *earlier*, plain (no `?`/`*`/`+`) token or literal term in the
  same alternative; referencing a rule term, a repeated/optional term, a
  later term, or an out-of-range index is a generation-time error naming
  the rule (`pg_validate_action_bindings` in `generator.w`). A binding
  reference is also rejected outright when its own alternative shares a
  leading term with a sibling (i.e. could ever be left-factored with it):
  a left-factored shared prefix is parsed once under the factored unit's
  representative alternative, and extending the binding surface to name
  the right captured variable across that renaming is left for a later
  milestone — rewrite the rule to avoid the shared prefix if this fires.
- **Host-provided functions**: an action or predicate calling a function
  that isn't in scope needs the generated file to import whatever module
  defines it. A grammar's own top-level `import <dotted.path>` directive
  (e.g. `import tests.parser_generator.actions_support`) adds exactly that
  line to the generated output, alongside the standard runtime import; a
  grammar that declares no `import` directive (every grammar before
  milestone 4) is generated byte-for-byte as before.
- **Demonstration**: `tests/parser_generator/actions_sample.pg` /
  `generated_actions_test.w` is a small "emit-as-you-parse" example: a
  left-to-right sum/difference chain whose actions call
  `tests/parser_generator/actions_support.w` to record stack-machine
  instructions (`PUSH n`, `ADD`, `SUB`, ...) as each term commits — the
  instruction list *is* the parse's output, with no AST and no buffering
  — plus a predicate (`&{ actions_prefer_call() }`) choosing between two
  alternatives that share the same `IDENT` first token, the same
  ambiguity shape `w.pg` still needs milestone 4 for.

`w.pg` itself is unchanged and stays in the default AST mode: the
intentional over-acceptance it uses for context-sensitive parses
(`top_item`'s declaration-vs-statement re-parse, `name_token`'s
deliberately broad keyword set, `type_ref`-prefixed declaration dispatch,
and the "does this alternative's leading token also start a nested
primary expression" family in
`paren_expression_opt`/`range_expr`/`postfix_tail`) is exactly the set of
rules `--report` still lists as backtracking after milestone 2 — porting
it to streaming mode with predicates is future work, not part of this
milestone (see `docs/projects/ai_tooling_next_steps.md` for the
known-unsound-shape caveat discovered while building the demonstration
grammar above).

## W grammar

`tests/parser_generator/w.pg` is the first generated-parser grammar for W
source. It covers the lexical forms used by W source files (comments,
identifiers, numbers, char/string literals, keywords, operators, newlines, and
tab runs), plus grammar rules for imports, structs/unions/enums, type aliases,
extern/c_lib declarations, functions, global/local declarations, blocks,
control-flow statements, calls, indexing, field access, unary/binary
expressions, `new`, and `range`.

The generated W parser is intentionally separate from the production compiler:
it produces a ParserGenerator AST and validates syntax-shaped W input, but it
does not perform symbol resolution, type checking, or code generation. The
existing compiler remains the executable source of truth for bootstrapping.

`./wbuild parser_generator_w_test` generates `bin/generated_w_parser.w`, compiles
it, writes a manifest with `git ls-files '*.w'`, and parses every tracked W
source file in the repository. The target also keeps smaller inline fixtures for
specific syntax shapes and explicit checks for `w.w` and `tests/hello.w`.

## C grammar

`tests/parser_generator/c.pg` is the generated-parser grammar for C source.
It is header-oriented and, combined with the C preprocessor
(`libs/extras/c_preprocessor/`), covers full glibc system headers: typedefs,
structs/unions (bit-fields, anonymous members), enums, function prototypes,
pointers and function pointers, arrays, abstract declarators in parameter
lists, variadic parameters, cast and `sizeof` expressions, initializers, and
the C statement set for `static inline` function bodies.

The grammar is syntax-only: `c_import` preprocesses first and evaluates
constant expressions on the parsed AST afterwards (see
`docs/projects/c_import.md`). Because the parser has no typedef symbol
table, casts of bare typedef names parse as call shapes; the importer's
evaluator resolves those against the W type table. Generated parsers report
syntax errors at the furthest token any parse attempt reached.

`./wbuild parser_generator_c_test` generates `bin/generated_c_parser.w`, compiles
it, verifies it matches `libs/extras/c_import/generated_c_parser.w`, and runs
focused lexer and parser fixtures for the declaration shapes needed by the first
import milestone.

## Usage

```sh
mkdir -p bin
./bin/wv2 tools/parser_generator.w -o ./bin/parser_generator
./bin/parser_generator tests/parser_generator/sample.pg -o ./bin/generated_sample_parser.w
./bin/wv2 tests/parser_generator/generated_sample_test.w -o ./bin/parser_generator_test
./bin/parser_generator_test
```

`./wbuild parser_generator_test` wraps this, and `./wbuild tests` now
includes that target.
