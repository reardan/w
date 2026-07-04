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
`identifier`, and `any`, which map to `pg_lexer_matcher_<name>`.

Rule terms are token names, literal names, rule names, or `EOF`. A term may end
with `?`, `*`, or `+`. Alternatives are separated by `|`. Parenthesized groups
and semantic actions are intentionally left for a later milestone.

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
