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
literal COMMA ","
start list
rule value = WORD | NUMBER
rule list = value value* EOF
```

Supported token matchers are runtime helper names such as `letters`, `digits`,
`identifier`, `number`, `string`, `char_literal`, `newline`, `tabs`, and `any`,
which map to `pg_lexer_matcher_<name>`. `skip <NAME> <matcher>` declares
comment or trivia matchers that the generated lexer consumes without emitting a
token.

Rule terms are token names, literal names, rule names, or `EOF`. A term may end
with `?`, `*`, or `+`. Alternatives are separated by `|`. Parenthesized groups
and semantic actions are intentionally left for a later milestone.

Generated lexers use longest-match token selection. This lets a grammar list
generic identifiers and exact keyword/operator literals together: `integer`
stays an identifier, while `int` can become a keyword token.

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

`make parser_generator_w_test` generates `bin/generated_w_parser.w`, compiles
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

`make parser_generator_c_test` generates `bin/generated_c_parser.w`, compiles
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

The Makefile wraps this as `make parser_generator_test`, and `make tests` now
includes that target.
