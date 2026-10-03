# wc2: semantic AST foundation

First implementation task for [#488](https://github.com/reardan/w/issues/488).
`wc2` lowers the parser-generator W tree into an AST with explicit expression
precedence, block membership, scopes and source spans. It currently exposes
AST inspection; executable emission is the next task.

```sh
./wbuild wc2
bin/wc2 --dump-ast path/to/program.w
```

Successful output is deterministic JSON (schema 1). Invalid or unsupported
input produces location-bearing diagnostics on stderr, no stdout, and exit
status 1. Incorrect command-line arguments return 2.

## Supported foundation

The initial subset covers `int`, `bool` and `void` type spellings; function
definitions and named parameters; global and local declarations; inferred
locals (`:=`); integer and boolean literals; names; unary `+ - ! ~`; arithmetic,
comparison, bitwise and logical operators; assignment and compound assignment;
ordinary calls; `return`, `if`/`elif`/`else`, `while`, `break`, `continue` and
`pass`. Bodies use colon blocks, including inline and empty bodies.

This is structural lowering, not a completed type checker. Declarations record
their builtin type; integer literals retain their spelling and an untyped
integer tag. Name bindings and inferred expression types remain unresolved.
Declaration visibility, duplicate names, argument/return compatibility, literal
width checking and target-specific integer interpretation belong to the later
semantic pass. A successful dump does not yet certify that a program compiles.

Imports, structs, pointers, arrays, strings, floats, generics, prototypes,
default/variadic parameters, ternaries, non-call postfix operations, brace
blocks and multiline expressions are rejected explicitly. In particular,
multiline expressions cannot silently inherit `w.pg`'s permissive newline
joining. These restrictions bound the experiment without changing W itself.

## Representation and ownership

`tools/wc2/ast.w` defines the nodes and module context. `wc2_parse(source, path)`
clones both arguments; the caller may immediately free them. Each module owns
its source, filename, token stream, parser tree, diagnostics, AST node table and
scope table. `wc2_module_free` releases these on success or failure. Multiple
modules can coexist without sharing compiler globals.

Node and scope IDs are local to one module and stable for its lifetime. Node
spans are half-open byte ranges; line and column are one-based. Children are
node IDs, and scopes contain parent/owner IDs and declaration IDs. `binding=-1`
and `type=-1` mean unresolved, not production-compiler table entries. Other
type tags are 0 (`int`), 1 (`bool`), 2 (`void`), 3 (integer literal).

| Node | Ordered children |
|---|---|
| module | top-level declarations |
| function | parameters, then body block |
| block | statements |
| declaration | optional initializer |
| return | optional value |
| if | condition, then block, optional else block or nested if |
| while | condition, body block |
| expression_statement / unary | expression / operand |
| binary / logical / assignment | left, right |
| call | callee, then arguments |
| parameter / integer / name / pass / break / continue | none |

Logical `&&`/`||` have their own node kind so future code generation preserves
short-circuit evaluation. Binary operators follow the production grammar's
precedence and left associativity; assignment follows its right associativity.
The dump uses flat node/scope tables and contains no process addresses.

`tools/wc2/lower.w` flattens PG statement headers into source order and rebuilds
blocks using actual indentation. This is necessary because `w.pg` accepts any
positive indentation in a block and can attach a dedented sibling under an
inner statement. Its expression trees are lowered by `expressions.w`, which
reconstructs precedence from the PG's flat binary-operator sequence.

The PG runtime has an opt-in stream-owned AST mode. `wc2` enables it before
parsing and releases the stream rather than recursively freeing only the
returned root. This also frees abandoned backtracking/factored-prefix nodes
and error-recovery nodes. The ownership state is per stream; ordinary parser
callers retain the default independently owned tree behavior.

## Build and tests

The source-owned `wc2_parser` target generates `bin/wc2_parser.w` from the
existing `tests/parser_generator/w.pg`; `wc2` depends on it. A separate output
avoids racing the repository parser test's `bin/generated_w_parser.w`.
The production grammar and compile entry point do not import the leaf tool.
The small PG ownership helpers are shared runtime code and remain seed-safe.

```sh
./wbuild wc2_test wc2_64_test wc2_cli_test wc2_memory_test wc2_memory_64_test
./wbuild tests
```

Tests cover operator precedence/associativity, source spans, calls, scopes,
dedents and branch binding, unsupported syntax, independent module lifetimes,
JSON escaping and CLI exit/output contracts. The memory tests run in fresh
processes with the guard allocator and require zero outstanding allocations
after successful, failed, recovered and lexically invalid parses.

## Next task

Add executable emission for the smallest integer/function/return slice, using
this AST as input. Start with `int main(): return 2 + 3 * 4`, compare its exit
status with `bin/wv2`, and expand language coverage with differential fixtures.
Name/type resolution, module invalidation, resident queries and the production
compiler migration remain later tasks. This foundation alone does not close
#488 or unblock all of #489.
