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
and semantic actions are intentionally left for a later milestone.

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
