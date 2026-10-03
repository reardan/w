# wc2: leaf AST compiler

First four implementation tasks for [#488](https://github.com/reardan/w/issues/488).
`wc2` lowers the parser-generator W tree into an AST with explicit expression
precedence, block membership, scopes and source spans. It exposes AST inspection
and emits Linux x86 executables with functions, local values, control flow,
plain imports and basic structs. A resident JSON-lines service reuses parsed
modules and checked programs across queries and builds.

```sh
./wbuild wc2
bin/wc2 --dump-ast path/to/program.w
bin/wc2 path/to/program.w -o bin/program
bin/program
bin/wc2 check --json path/to/program.w
bin/wc2 symbols --json path/to/program.w
bin/wc2 deps --json path/to/program.w
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

## Resident service (task 4)

`bin/wc2 serve` is a foreground, single-threaded JSON-lines process. It owns
state until EOF or `shutdown`. There is no background autostart, socket,
production `wbuildd` integration, or invocation of `bin/wv2` on this path.
Example input (one object per line):

```json
{"id":1,"method":"check","file":"program.w"}
{"id":2,"method":"symbols","file":"program.w"}
{"id":3,"method":"deps","file":"program.w"}
{"id":4,"method":"build","file":"program.w","output":"bin/program"}
{"id":5,"method":"stats"}
{"id":6,"method":"clear"}
{"id":7,"method":"shutdown"}
```

Every line receives one JSON object. Optional `id` is echoed. Invalid JSON,
wrong field types and unknown methods return `ok:false` plus `error`; the
process remains available. Compiler requests return `ok`, a program `revision`,
`reused`, a `diagnostics` array and cumulative `stats`. `reused` means the
program graph snapshot was reused; a first check/build may still perform lazy
analysis/emission. `build` writes its output only when analysis succeeds and
keeps the existing destination on errors, including failed writes.

| Method | Result and validation |
|---|---|
| `check` | Parse, load and check the executable subset; no binary. Requires `int main()`. |
| `symbols` | Structural declarations from reachable parsed modules: name, kind, file, line/column, byte span, file-local scope, declared type and type spelling. No semantic analysis and no main requirement. |
| `deps` | `deps` lists resolved files including the root; `imports` lists each edge with importing file, line, spelling and resolved path (null when missing). No semantic analysis. |
| `build` | Check, emit Linux x86 ELF and write the requested `output`. |
| `stats` | Cache occupancy and work counters. |
| `clear` | Free cached programs and files; lifetime counters remain cumulative. |
| `shutdown` | Acknowledge and exit, freeing resident state. |

`symbols`/`deps` report parse/load errors and may include partial results;
`ok:true` on these methods does not certify semantic validity. Declaration
`type`/`scope` fields describe the parsed module, not resolved cross-module
bindings. `check`/`build` return all collected semantic diagnostics in one
response. Independent dependencies' parse errors are collected together;
semantic analysis starts only when the whole graph parses and loads. These
are surfaces for wc2's documented subset, not drop-in replacements for
production compiler JSON formats. The one-shot `check`, `symbols` and `deps`
commands use the same response format (`--json` is optional), exiting 0 on
`ok:true`, 1 on failure, and 2 for invalid command-line arguments.

`resident.w` rereads reachable source bytes and resolves each import on every
request. Equal bytes reuse the per-file PG tree, tokens and semantic AST;
there is no mtime-only shortcut. Embedded NULs and read errors are diagnosed.
Changed, deleted, restored and newly shadowing imports change the graph key,
even when an importer is untouched. Paths become absolute and redundant `.`
segments are removed; `..` and symlinks retain filesystem semantics and can
occupy separate cache entries. Reads across several files are not an atomic
filesystem snapshot; a subsequent request catches edits made during a request.

A graph key records file revisions and resolved edges in traversal order.
An unchanged graph reuses its linked AST, symbol/dependency answers, checked
semantic tables and, after the first build, emitted image. A changed file
reparses only that module. Each affected root gets a fresh linking snapshot,
whole-program semantic analysis and emission; unaffected roots remain reusable.
The unit owns its nodes, diagnostics and strings independently of the parsed
file cache. `snapshot.w` copies only semantic nodes/scopes, and linking rebases
those copies, so resident parse trees are never transferred or mutated.

The cache keeps at most 16 linked programs (FIFO eviction). Parsed files are
retained up to 256 entries; reaching that threshold clears resident state at
the start of the next compiler request. A single graph exceeding 256 files is
diagnosed. These are entry-count bounds, not byte budgets. `clear` can release
state explicitly. Useful counters are `reads`, `parses`, `parse_hits`,
`analyses`, `emissions`, and `program_hits`; `files`, `programs`, `source_bytes`
and `ast_nodes` report current occupancy. Source bytes and AST nodes count the
parsed cache, not PG nodes, linked copies, or total allocator/RSS memory.

The library API is `wc2_resident_new`, `wc2_resident_request` (returns owned
JSON), `wc2_resident_clear` and `wc2_resident_free`. Internal program pointers
are borrowed until that program is refreshed, evicted or cleared. The resident
emitter borrows already-checked tables through `wc2_emit_checked`; ordinary
`wc2_emit` still creates and frees its own semantic pass.

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
./wbuild wc2_resident_test wc2_resident_64_test
./wbuild wc2_resident_memory_test wc2_resident_memory_64_test
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
Resident tests exercise same-size edits with restored timestamps, shared dependencies,
import creation/deletion/shadowing, transitive closure changes, error caching
and repair, structural queries, snapshot eviction, malformed requests,
request IDs, both host widths and zero outstanding guard allocations.

## Measurements and recommendation

Run `python3 tools/bench_wc2.py --repeats 7` after `./wbuild wc2` (Python standard
library only, Linux). The harness creates and removes synthetic programs under
`bin/`, validates executable results and byte-identical cold/resident output,
and asserts that warm requests parse/analyze/emit nothing and a leaf edit
reparses exactly one file. Timings are observations, not test-suite thresholds.

The [recorded run](wc2_benchmark.json) on 2026-10-03 used an Intel i7-14700K,
Linux x86_64, with the default 32-bit compiler binaries. Seven samples per
operation; median wall milliseconds below. OS file caches were warm. Process
startup is included in the new-process rows; resident timings include request
serialization, file reads, response handling and output writing when applicable.

| Operation | 20 lines / 3 files | 810 lines / 6 files |
|---|---:|---:|
| wv2, new process | 25.619 | 30.564 |
| wc2, new process | 1.358 | 61.072 |
| Resident cold build (after clear) | 0.737 | 53.426 |
| Resident warm check | 0.052 | 0.200 |
| Resident warm symbols | 0.116 | 2.469 |
| Resident warm deps | 0.063 | 0.187 |
| Resident warm build (rewrites output) | 0.077 | 0.170 |
| Resident build after changing shared leaf | 0.360 | 42.927 |

The fixtures contain 403 and 13526 source bytes.
Resident process RSS after repeated edits was 824 KiB and
10164 KiB respectively (whole process, including allocator-retained
pages, not a live-AST measurement). The raw report includes ranges, counters,
image sizes, platform and compiler hashes. Both workloads had zero new parses,
analyses or emissions across all warm requests. Each shared-leaf edit reparsed
one module, but reanalyzed and emitted the entire affected program.

The small case benefits substantially from omitting production runtime imports.
`wv2` automatically compiles its container runtime; wc2 emits only this limited
subset. The image-size and cold-time differences do not demonstrate a general
compiler speedup. On the larger case, wc2 cold compilation was about twice as
slow as wv2, and even the changed-leaf rebuild was slower than wv2's full compile.
Warm symbols also pay for serializing all declarations. These synthetic cases
do not establish scalability to the self-hosting compiler or full W programs.

**Recommendation:** go ahead with a narrowly staged, opt-in AST migration
prototype in #489, preserving the existing compiler path and seed/fixpoint
checks. The spike demonstrates owned modules, invalidation, multi-error
reporting and resident queries. **No-go for replacing the production compiler
or promising incremental-build speedups yet.** First profile and reduce
whole-program linking/semantic/emission costs, and establish broader language,
REPL and debugger parity. Cached parsing alone does not solve incremental
compilation. The maintainer risk decision required by #489 remains separate
from this experimental result; no production migration is made here.

## Next task

Task 5 is the staged production AST migration after that risk decision: retain
seed compatibility and `verify`, start with one expression rule behind an
opt-in path, and require differential compiler/REPL/debugger tests before each
expansion. Pointer/aggregate-return/generic and other unsupported language
coverage also remains work. This leaf experiment does not itself unblock a
wholesale replacement or change GitHub issue state.
