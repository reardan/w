# wc2: leaf AST compiler

First three implementation tasks for [#488](https://github.com/reardan/w/issues/488).
`wc2` lowers the parser-generator W tree into an AST with explicit expression
precedence, block membership, scopes and source spans. It exposes AST inspection
and emits Linux x86 executables with functions, local values, control flow,
plain imports and basic structs.

```sh
./wbuild wc2
bin/wc2 --dump-ast path/to/program.w
bin/wc2 path/to/program.w -o bin/program
bin/program
```

Successful `--dump-ast` output is deterministic JSON (schema 1). Invalid or unsupported
input produces location-bearing diagnostics on stderr, no stdout, and exit
status 1. Incorrect command-line arguments return 2.

## Supported foundation

The parsed subset covers `int`, `bool`, `void` and named struct types; function
definitions and named parameters; global and local declarations; inferred
locals (`:=`); integer and boolean literals; names; unary `+ - ! ~`; arithmetic,
comparison, bitwise and logical operators; assignment and compound assignment;
ordinary calls; `return`, `if`/`elif`/`else`, `while`, `break`, `continue` and
`pass`; plain dotted imports; struct declarations and field access. Bodies use
colon blocks, including inline and empty bodies.

This is structural lowering, not a completed type checker. Declarations record
their builtin type; integer literals retain their spelling and an untyped
integer tag. Name bindings and inferred expression types remain unresolved.
Declaration visibility, duplicate names, argument/return compatibility, literal
width checking and target-specific integer interpretation are not part of the
dump. The executable path performs name/type and control-flow checks in
separate semantic tables. A successful dump does not certify that a program
compiles, and `--dump-ast` does not read imported files.

Pointers, arrays, strings, floats, generics, prototypes, import aliases,
default/variadic parameters, ternaries, other postfix operations, brace
blocks and multiline expressions are rejected explicitly. In particular,
multiline expressions cannot silently inherit `w.pg`'s permissive newline
joining. These restrictions bound the experiment without changing W itself.

## Executable subset (tasks 2–3)

An executable needs a zero-argument `int main()`. For example:

```w
int main():
	return 2 + 3 * 4
```

This compiles to an executable that exits with status 14. Expressions support
decimal/hex/binary integer literals, booleans, parentheses, unary `+ - ! ~`,
and binary `+ - * / % << >> & | ^ == != < <= > >= && ||`. Both logical
operators short-circuit and produce 0/1. Arithmetic uses signed 32-bit x86
operations, with wrapping add/subtract/multiply, arithmetic right shift,
hardware-masked shift counts, and signed division/remainder. Division by zero
and signed division overflow trap if evaluated, as on the production x86 path.
All 32 literal bits are accepted and interpreted as a signed value, independent
of the host compiler's word size; wider literals are diagnosed. This spike
does not yet reproduce production lint/style warnings for literal spellings.

`semantics.w` resolves lexical names in declaration order, allows typed local
shadowing, rejects `:=` redeclaration of a visible local/parameter, checks
function argument counts and value types, and diagnoses uninitialized reads.
Functions may call themselves and earlier functions. Forward declarations and
mutual recursion are not supported yet. `int` and `bool` interoperate; stores,
arguments and returns to `bool` normalize to 0/1. Void calls are allowed as
expression statements, but cannot be used as values.

Locals may use explicit types or `:=` inference. Assignment and compound
assignment are expressions. `if`/`elif`/`else`, `while`, `break`, `continue`,
`pass` and early returns compile from the AST. Definite initialization merges
only paths that reach the following statement. Loop bodies and short-circuit
right operands cannot establish initialization on every path. Non-void
functions must provably return on all paths; this conservative check does not
prove constant conditions or infinite loops. Unreachable code is still checked.
`validate.w` supplies target-width literal checking. Executable expression
nesting is capped at 200.

Structs currently contain 1–30 `int`/`bool` fields. Named local struct values
support field reads/writes, whole-value copy, `:=` inference, and by-value
parameters. Initialization is tracked per field; passing or copying an entire
struct requires every field to be initialized. Nested structs, struct returns,
heap allocation, pointers, methods and generic structs remain unsupported.
Each scalar field occupies a four-byte slot in wc2's private layout; this is
not an external ABI. No `sizeof` or address operations expose that layout.

`load.w` expands plain dotted imports at their source position and loads each
resolved path once. It searches the invocation directory and its parents;
there is no compiler-binary-directory fallback or implicit standard-library
import. Cycles, missing modules and import depth beyond 64 are diagnosed.
Imported files must use the same supported subset. Globals and non-function,
non-struct top-level declarations are rejected by semantic analysis.

`x86.w` uses the existing `libs/asm` instruction encoder and byte buffer.
Each function has a fixed EBP-relative local frame. Calls evaluate and push
arguments left to right, with the last argument nearest the return address;
callers remove arguments, callees preserve EBP, and scalar results use EAX.
Aggregate expressions carry addresses and value arguments are copied onto the
stack. No external calls are supported. Every expression balances its temporary
stack use; all returns restore the frame. Branch and call offsets are patched
after their targets are known. No production parser or compiler globals are
imported. `emit.w` adds a static ELF32 header, an entry stub calling main, an RX
load segment and a non-executable stack declaration. The production ELF writer
depends on global image, symbol and dynamic-linking state, so this leaf uses
its own minimal layout with shared integer field-writing helpers.

For file compilation, call `wc2_load_imports(module)` before emission.
`wc2_emit(module)` returns an owned `asm_buffer`, or zero with module diagnostics.
The image remains valid after `wc2_module_free`; release it with `asm_buffer_free`.
Emission does not change AST nodes and can be repeated on a valid module.
Images are identical across 32-bit/64-bit emitter hosts and source filenames.
The CLI writes an exclusive sibling temporary and renames it only after a
complete write, preserving previous output on validation or I/O failure.
Compile success produces no stdout. Output is currently Linux x86 ELF only;
there is no architecture option, linking, debug metadata, or optimizer.

## Representation and ownership

`tools/wc2/ast.w` defines the nodes and module context. `wc2_parse(source, path)`
clones both arguments; the caller may immediately free them. Each module owns
its source, filename, token stream, parser tree, diagnostics, AST node table and
scope table. Imported modules retain ownership of their sources/token trees
while their node and scope tables are transferred into the root module.
`wc2_module_free` releases these on success or failure. Multiple
modules can coexist without sharing compiler globals.

Node and scope IDs are local to one compilation. Import loading rebases IDs
once; they remain stable through analysis and emission. Every node owns its
source filename, also exposed as `file` in the dump, so imported diagnostics
retain their origin. Spans are half-open byte ranges in that source; line and column are one-based. Children are
node IDs, and scopes contain parent/owner IDs and declaration IDs. `binding=-1`
and `type=-1` mean unresolved, not production-compiler table entries. Other
type tags are 0 (`int`), 1 (`bool`), 2 (`void`), 3 (integer literal), and
4 (a named type whose spelling is in `type_name`). The dump stays structural.
`wc2_analyze` creates separately owned tables for resolved types/bindings, stack
slots, frames and initialization; release them with `wc2_semantics_free`.
Resolved struct types are tagged with 1000 plus the struct node ID.

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
| struct | field-declaration block |
| member | base expression (field spelling in text) |
| import | none (dotted module spelling in text) |
| parameter / integer / name / pass / break / continue | none |

Logical `&&`/`||` have their own node kind so code generation preserves
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
./wbuild wc2_emit_test wc2_emit_64_test wc2_program_test wc2_program_64_test
./wbuild tests
```

Tests cover operator precedence/associativity, source spans, calls, scopes,
dedents and branch binding, unsupported syntax, independent module lifetimes,
JSON escaping and CLI exit/output contracts. The memory tests run in fresh
processes with the guard allocator and require zero outstanding allocations
after successful, failed, recovered and lexically invalid parses.
The executable tests compare 45 expression fixtures against `bin/wv2`, checking
full 32-bit results inside each program rather than only truncated exit codes.
They also cover ELF layout, byte-identical emission on both host widths,
unsupported programs, CLI failures and output preservation. Guard-allocator
tests include repeated emission, full programs, imported modules, failed
imports and rejected out-of-range literals. Program fixtures cover argument
evaluation order, recursion, shadowing, boolean conversion, definite
initialization, nested loops, struct copies/parameters and diamond imports.
The production compiler currently faults on a direct `int`-to-`bool` return
(`bool truth(int n): return n`), confirmed with wdbg; differential fixtures use
`return n != 0`, and wc2 tests the direct conversion independently.

## Next task

Task 4 adds resident module reuse/invalidation, multiple-error and query
surfaces, and measurements for the AST spike. Extending language coverage
beyond the documented subset remains incremental work. The production
compiler migration in #489 remains a later task; these three implementation
tasks do not close #488 or unblock all of #489.
