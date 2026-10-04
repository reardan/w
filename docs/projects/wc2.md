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
from this experimental result. The opt-in production experiment below does
not replace the streaming compiler.

## Task 5: first production AST expression path

The production compiler now has an experimental `--ast-expressions` option.
It builds a temporary semantic tree for **parenthesized, single-line integer
arithmetic**: decimal/hex/binary literals, unary `+`/`-`, nested parentheses,
and binary `+`, `-`, `*`, `/`, `%` with the existing precedence and associativity.
Task 6 extends this same path to the typed scalar operands described below.
It is off by default. Like `--strict`, the compiler option applies to inputs
that follow it; place it before the source path.

```sh
bin/wv2 --ast-expressions --stats program.w -o bin/program
bin/wv2 check --json --ast-expressions program.w
bin/repl --ast-expressions
bin/wdbg program.w --ast-expressions
```

`--stats` includes `AST expressions: N` to establish that the experimental
path was actually used. The REPL option applies to startup compilation and
subsequent entries; wdbg uses it for the debuggee, expression evaluation and
attach-mode source reconstruction. Other syntax continues through the streaming
grammar, including calls, floats, binary bitwise/logical operations,
comments and multiline groups. An unsupported outer group may still contain
supported inner groups. Pending lvalue/call/statement state also forces fallback.

`compiler/expression_ast.w` owns a stack arena of 128 nodes with source byte
offsets. `grammar/ast_expression.w` first inspects the tokenizer's existing
buffer without I/O or state changes. Only a closed group whose bytes cannot
trigger lexer diagnostics is probed. The shared tokenizer builds the AST;
the complete changed tokenizer state, including its serial counter, is then
restored. A successful parse replays the tokens for the existing integer
decoding and diagnostics before `code_generator/expression_ast.w` walks the
tree through the production backend dispatch. No executable code is emitted
during the AST parse. The temporary tokenizer snapshot is freed before the
diagnostic pass, and the arena unwinds with the stack on REPL error recovery.

The probe is bounded to 2048 bytes, 128 nodes, 96 recursive levels and the
current tokenizer buffer window (including one closing-token lookahead byte).
Exceeding any bound falls back to the original grammar and its nesting guard;
these are not new language limits. Literal decoding retains the existing
32-bit literal ceiling/sign extension, while arithmetic uses the target word
size. The AST adds no independent constant folder or machine-code encoder.

`./wbuild ast_expression_test ast_expression_verify` checks:

- Byte-identical legacy/AST images for x86, x64, ARM64 ELF, ARM64 Darwin,
  win64 and wasm; native x86/x64 execution and both compiler host widths.
- Matching JSON/lint diagnostics, literal limits, unsupported/malformed
  input, missing final newlines, bounded fallback and excessive nesting;
  matching symbols, dependencies and definition hashes.
- REPL evaluation, reset and error recovery, plus debugger locals, source
  locations, expression evaluation and recovery on both host widths.
- Byte-identical compiler self-hosts with the option on/off, and repeated
  AST-enabled fixpoints on x86 and x64. The pinned seed remains unchanged.

Cross-target image comparisons do not claim runtime testing on those target
systems. This first island also makes no performance claim: it reparses its
accepted tokens, and production parsing is not cached or incremental.

## Task 6: resolved scalar operands

`--ast-expressions` now also accepts ASCII identifiers resolving to integer
locals, parameters, globals, thread-local globals and enum constants. The
tree records each resolved symbol and its declared type, preserving aliases,
const qualification, signed/unsigned load widths, and the distinction between
an address and a value. `(x)` remains an lvalue for grouped assignment or
`&(x)`; arithmetic promotes it through the existing backend helpers. This
stage also accepts `true`, `false`, `__word_size__`, `__target_isa__`, and
unary `!`, `!!`, `~` alongside `+` and `-`. Boolean expressions retain their
boolean result type. Storage must fit in the target word.

`sym_probe` resolves names without changing the symbol index, use tracking,
lookup counters or diagnostics, including immediately after a scope has
been truncated. Unknown names and unsupported operand types decline the
whole candidate. Once accepted, the token replay performs the usual import
warnings and marks the identifier uses at their original locations. The
walker passes resolved symbol records to `sym_emit_value`, also used by the
streaming parser, so stack-relative addresses are calculated at emission
time with the current operand stack depth. The tree's symbol/name offsets
are valid only during this operation; they are not persistent bindings.

Pointers, calls, member/index access, floating-point and aggregate operands,
dynamic `var` values and PTX device bodies still use the streaming grammar.
The same bounded single-line probe and default-off option remain in place.
The differential fixture now checks mixed-width parameters, unsigned loads,
shadowing, grouped lvalues, aliases/enums, generics instantiated with scalar
types, TLS, overload fallback, and REPL/debugger evaluation of local names.
`ast_symbol_probe_test` and its x64 twin additionally assert that speculative
binding leaves unused-local tracking and stale scope heads untouched, and
respects retired debugger bindings. Both host widths still pass byte-identical
AST-enabled self-host fixpoints.

## Task 7: pointers, floating-point expressions and scalar calls

The opt-in production AST now accepts host pointers and word-fitting float
storage, decimal/exponent literals, float unary signs and arithmetic, and
direct fixed-arity calls with compatible scalar arguments and scalar results.
Pointer addition/subtraction shares result typing with the streaming grammar:
offsets remain byte offsets and the result preserves the pointer's element
width. Float literals are decoded only during committed token replay; float64
bits are stored as two halves so a 32-bit compiler host loses no precision.
Float loads, arithmetic and conversions use the existing backend helpers.

Call nodes bind the callee before parsing arguments and retain an ordered
argument list. Emission materializes the function address, evaluates/coerces
arguments left to right and uses the ordinary call/stack-cleanup helpers.
This preserves forward-reference patches, target call conventions, and REPL
callsite tracking when functions are redefined. No imports or declarations
can occur inside an accepted candidate. Argument mismatches and incorrect
arity decline the candidate so diagnostics retain their original positions
and order. Defaults that need insertion, variadics, indirect/foreign calls,
generics, builtins, constructors, generators, aggregate/void results and GPU
objects remain with the streaming parser. Unsupported float16 backends also
fall back before replay. Member/index/dereference syntax can surround an
accepted group but is still parsed by the streaming grammar.

The differential tests cover nested calls and argument side effects, scalar
coercion, forward references, pointer results and sub-word dereferences,
float32/float64 and native float16 operands, signed zero, decimal rounding,
subnormals, malformed literals/calls, fallback diagnostics and REPL redefinition
and recovery. The common scalar fixture joins the six-target image comparison
matrix; float16 executes only on x86/x64 and float64-only cases on x64.
Both compiler host widths retain AST-enabled byte-identical self-host gates.

## Task 8: comparisons, short-circuit logic and postfix access

The production AST now handles scalar `<`, `<=`, `>`, `>=`, `==`, `!=`,
`&&` and `||`, typed pointer indexing, ordinary struct/union fields, typed
pointer dereference and address-of. Precedence matches the streaming grammar;
comparisons remain left-associative and retain boolean result types. Float
comparisons reuse its existing operand-swap and unordered-result conventions.

Each same-precedence logical chain is a single node with ordered operands,
one branch target, and one final booleanization. Parenthesized subchains
remain separate nodes. The walker emits the same conditional branches as the
streaming parser, so skipped calls and memory reads remain skipped and flat
chains retain byte-identical output rather than adding a booleanization per
binary pair. Compilation still diagnoses every operand, including unreachable
ones; replay does not short-circuit diagnostic checks.

Postfix nodes retain lvalue types, element sizes and resolved field offsets.
Structs enter as intermediate addresses for field/element access and
address-taking; whole-aggregate operations still fall back. Pointer indexes scale by element
size, while pointer arithmetic continues to use byte offsets. Member and
index results support grouped assignment and address-taking. Qualified import
names, methods, container/buffer access, imported C bit-fields and GPU objects
continue through the streaming parser, preserving their diagnostics, bounds
checks and pending-element state. Bitwise operators, shifts, ternaries,
assignment expressions and casts are also still outside this island.

The differential fixture checks mixed precedence, grouped and flat chains,
side-effect order, null-pointer guards, comparisons passed to calls, nested
fields, pointer-returning calls followed by member access, indexed/field
assignment, float comparisons and NaN parity. Hit counters prove an entire
mixed logical/call/index/member expression enters the AST. Both host widths
also check malformed and unreachable operands, bool-bitwise hints, REPL
recovery and debugger evaluation. All six target image comparisons and both
AST-enabled self-host fixpoint gates remain in place.

## Task 9: remaining scalar operators

The opt-in AST now handles bitwise operators, shifts, casts to existing scalar
types, and scalar conditional expressions. Precedence and right-associative
conditional arms match the streaming grammar. Cast nodes retain literal cast
context for bit-31 diagnostics; incompatible ternary arms and address-truncating
casts fall back before emitting diagnostics. Ternary nodes use the existing
three-region branch layout and branch-local coercion, preserving image parity.
Bool-bitwise conditions that may issue the existing hint still fall back.

The differential matrix includes mixed precedence, signed shifts, nested casts,
bit-31 suppression, selected-arm side effects, nested ternaries and float/pointer
results. Dedicated hit tests prove these constructs enter the AST together.

The next stage measures and expands coverage beyond parenthesized islands;
AST-required compilation must reject a fallback rather than report a successful
hybrid compile as full AST coverage. Source ownership across modules,
declarations/statements,
multi-error production analysis, REPL checkpoints and incremental emission
remain later work. wc2's resident caches are still confined to the leaf tool.
The production migration remains opt-in while coverage is incomplete.
GitHub issue state is unchanged.

## Task 10: full-expression entry and coverage gates

`--ast-full-expressions` tries the AST at every `expression()` entry, including
unparenthesized expressions and the implicit container-runtime imports. It
remains a hybrid mode: unsupported roots use the streaming parser. A buffered,
single-line preflight identifies the expression boundary, and a virtual end
offset prevents speculative lexing of the following statement. Committed
emission precedes the final real tokenizer advance, retaining the previous
token spelling for indentation and EOF diagnostics. Statement-position commas
remain with the parallel-assignment parser.

`--ast-audit` adds one JSON fallback record per streaming expression entry on
stderr, naming file, line, column and starting token. With `--stats`, the
compiler prints separate AST-root and streaming-root counts. These are parser
entry counts, including nested entries when a parent falls back; they are not
percentages of source coverage. `--ast-required` rejects the first unsupported
expression, including one in implicit runtime code. It is a migration gate,
not yet a usable general compilation mode, and does not claim that declaration
or statement parsing has moved to ASTs.

The initial whole-compiler audit produced roughly 37,500 AST roots and 28,900
streaming roots. Assignment, string, void-call and composite-type paths remain
substantial gaps. Both full-expression compiler host widths produce the same
images as the streaming compiler and are covered by repeated self-host checks.
The expression test matrix compares both AST modes against the default path,
including malformed input and statement-boundary diagnostics.

## Task 11: scalar mutations and direct calls

Scalar assignment and compound assignment now have AST nodes. They retain the
lvalue's declared width, evaluate its address once, preserve right-associative
chains, and return the stored value. The visitor reuses `assign_store` and
`compound_assign_apply`; REPL assignment suppression remains intact. Const,
non-lvalue, incompatible and aggregate stores still fall back, as do stores
when lint mode requires source-sensitive assignment diagnostics.

Direct calls now also accept void results, fixed imported-function wrappers,
and fixed-arity assembly stubs. Unknown parameter metadata skips coercion just
as the streaming call path does; known parameters retain the same checks and
coercion. Variadic, generator, kernel and indirect calls remain separate work.
Tests cover nested stores in calls and conditionals, skipped stores, pointer
stores, float compound assignment, boolean stores and void calls on all six
image targets, plus diagnostic parity and explicit AST-hit assertions.

## Task 12: character and string literals

Character, C-string, plain string and UTF-8 string literals now have AST nodes.
The byte preflight recognizes complete quoted tokens and escaped quotes without
interpreting their contents. Literal decoding and UTF-8 checks run during the
committed source replay, so diagnostics retain their original token and order.
Decoded string bytes live in a bounded stack-owned arena; the visitor emits
them with the ordinary C-string and descriptor encoders in evaluation order.
No literal allocation survives REPL error recovery.

String values and variables retain the streaming type conventions and string
content equality helper. Templates remain a fallback because their tokenizer
has expression-bearing chunks and different diagnostic behavior. Tests cover
Unicode characters, malformed escapes/UTF-8, embedded NULs, literal delimiters,
string equality, calls and assignments across both compiler host widths and
all six image targets. The whole-compiler audit falls to about 3,500 streaming
expression roots; full-expression self-host images remain byte-identical.

## Task 13: scalar print builtins and continuation boundaries

`print` and `println` now lower through dedicated AST nodes for integer,
character, enum, boolean, C-string, string and float32 values, including the
zero-argument newline form. The visitor preserves argument evaluation order,
stack cleanup and the existing lazy prelude helper registration. Unsupported
types and malformed argument lists retain their existing diagnostics.

Differential tests also exposed a pre-existing full-expression boundary bug:
a newline followed by a postfix or infix continuation could end an AST root
too early. The byte preflight now declines these roots, preserving both the
streaming interpretation and its cross-line call warning. Multi-line trees
remain a later stage. Tests compare target images, diagnostics and explicit
AST-hit counts without assuming the lazy runtime contributes no AST nodes.

## Task 14: buffer element access

Fixed arrays, slices and strings now have AST indexing nodes. Their visitor
loads the descriptor, evaluates the index once, emits the existing bounds
trap, and computes the element address at the declared width. Array fields
and arrays of ordinary records compose with field access; indexed elements
can participate in assignment and compound assignment. Whole-array values,
range slices and read-only descriptor fields remain separate work.

The differential matrix covers nested field/index access, side effects,
integer widths, strings and slice parameters. Explicit AST-hit and upper/
negative bounds-trap tests supplement byte comparisons; the bounds-off path
also produces the same image. Cross-line membership (`in`) now declines the
single-line probe just like other expression continuations.

## Task 15: inline comments

Closed, single-line block comments now participate in expression preflight
and token replay. Comments may separate operands, arguments and operators,
or follow the final token. The virtual-end guard skips trailing comments
before deciding whether a real tokenizer advance is safe. Boundary lookahead
also skips standalone block comments, including multi-line ones, when checking
whether the following token continues the expression. Unterminated comments,
comments containing expression-spanning newlines and the legacy lexer's
ambiguous `/*/` shape still decline the speculative path.

Tests cover operator-like comment contents, adjacent comments, trailing
comments, malformed input, literal warnings and next-statement diagnostics.
Both full-expression self-host images remain byte-identical.

## Task 16: list element access

Typed list indexing now has an AST node that evaluates the list and index
once, calls the ordinary `__w_list_addr` helper and returns the element's
lvalue address. Nested lists, scalar assignment, compound assignment, string
elements and fields of stored records compose with existing nodes. List
methods, slices and whole-list values remain separate work. Tests compare
images across both host widths and all six targets and assert direct AST
coverage, evaluation order and diagnostic parity.

## Task 17: empty-string regression from suite-wide AST compilation

A generated-manifest audit enabled `--ast-full-expressions` on 1,084 compiler
steps (leaving the pinned seed and explicit AST-mode regression commands
alone). Its first full-suite run exposed an empty-literal bug: the AST parser
treated the second quote in `""` as evidence of a prefixed literal, so decoding
started after the closing quote. Prefix detection now also checks the first
character. Differential tests cover empty plain, prefixed and C strings,
including comparisons against returned string values.

This audit covers compiler steps represented directly in the manifest. Test
drivers that launch the compiler themselves retain their own mode choices,
and full-expression mode still permits streaming fallback. It supplements
the required-mode coverage gate; it does not establish a complete migration.

## Task 18: first-use pointer types

Simple casts can now introduce pointer types during AST parsing. Temporary
records live in the arena and borrow an existing type name; the probe appends
their addresses to the type table for ordinary semantic queries. Before
restoring the tokenizer, it truncates those entries and invalidates the lazy
type-name index. Accepted token replay creates persistent pointer records at
their source stars, before emission. Literal diagnostics therefore cannot
leave pointers into an unwound arena in the type table.

The bounded type plan declines on exhaustion, and conservatively declines
new pointer types after an array promotion that would itself intern a type,
preserving registration order. Const and composite type construction remain
later work. Tests cover rollback, index rebuilding, committed ownership,
capacity exhaustion, nested pointer levels, malformed casts, literal warnings
and REPL recovery, in addition to the cross-target image matrix.

## Task 19: buffered boundaries and EOF

Preflight now distinguishes unsupported syntax from an incomplete buffered
window. It can compact the candidate's retained bytes and read ahead before
taking the tokenizer snapshot, preserving the logical read position without
seeking. EOF is established by a zero-length read, not by assuming a short
read is final. This also lets a final newline terminate an AST expression at
physical EOF. Missing-final-newline diagnostics and unavailable source
prefixes still use the conservative path.

Tests cover an expression crossing the 8 KiB buffer boundary, short reads
from a pipe, replay within a compacted buffer, final-newline coverage and
diagnostic parity. The whole-compiler audit drops to about 1,600 streaming
entries; self-host images remain identical.

## Task 20: call-containing boolean bitwise chains

The AST parser tracks boolean type and definite emitted calls across each
same-precedence `&`/`|` chain. A call-containing join can now use AST emission
when the default bool-bitwise warning would be suppressed. A pure prefix
still declines before a later call can hide its warning, and `--bool-ops`
retains the streaming warning path. Runtime short-circuit reachability does
not affect this count, matching the existing emitted-call purity rule.

Tests cover eager side effects, three-term chains, nested chains, explicit
AST hits and exact default/opt-in warning parity.

## Task 21: function values and indirect calls

Function references retain their symbol binding in AST nodes. A pure
signature-to-record predicate validates callback arguments and assignments
without consulting the streaming parser's mutable `last_identifier`.
Indirect calls support typed function pointers and untyped word/pointer
callees, scalar arguments and returns, and void results. They reuse
`finish_call`, preserving ABI lowering and the legacy delayed load of an
lvalue callee after argument evaluation.

Tests cover callbacks in locals and fields, returned function pointers,
function addresses cast to words, callback arguments and stores, float and
void calls, signature mismatches, narrowing diagnostics, and an argument
that changes the callee before the call executes.

## Task 22: default call arguments

Direct AST calls append declaration-time constants for omitted trailing
parameters. The parser validates the whole missing suffix and parameter
types before accepting the call; each default then uses the existing
argument coercion and stack layout. Indirect calls still require their
declared arguments because defaults belong to a function symbol.

Tests cover partial and fully defaulted calls, parenthesized callees,
prototype defaults, integer, character, boolean, float and null-pointer
parameters, explicit argument order, and missing/extra/type-mismatched
argument diagnostics.

## Task 23: tokens spanning an input refill

Whole-expression preflight can recover the current token's discarded prefix
when the tokenizer has already crossed a buffer boundary. It copies the raw
token prefix and every retained input byte into a larger owned buffer,
without changing the logical position or seeking. A bounded spelling/span
check rejects inputs whose source bytes cannot be reconstructed exactly.

Tests cover a long identifier across the 8 KiB boundary, audit coverage,
image and diagnostic parity, and replay of recovered bytes from a pipe.

## Task 24: function addresses and untyped byte indexing

The scalar-value predicate now explicitly includes the compiler's function
pseudo-type. Task 21's indirect calls already emitted through ASTs, but bare
function references in casts, callback arguments and comparisons had still
fallen back because that pseudo-type has size zero. Coverage assertions now
exercise those forms directly as well as comparing their images.

Integer-address indexing also preserves W's legacy byte element default;
typed pointers continue to use their pointee's size. Tests cover reads,
stores and compound stores through raw addresses, callback signature
diagnostics, and cross-target image parity.

## Task 25: runtime stubs, sizeof and ordinary allocation

Direct AST calls accept runtime assembly symbols whose parameter count is
unknown, keeping their existing unchecked word-argument convention. `sizeof`
uses the transactional simple-type reader and emits the target type's size.
Ordinary `new T` and `new T()` allocate through the production malloc call
sequence, including zeroing and descriptor setup for embedded fixed arrays.
First-use pointer types participate in the existing replay plan.

Tests cover primitive/record/union/pointer sizes, raw runtime-stub calls,
heap records and primitive values, fixed-array initialization, first-use
pointer registration, diagnostic parity and cross-target image equality.
Container allocation syntax, sized array allocation and nonempty
constructors remain later work.

The trivial-program coverage gate now compiles its entire implicit runtime
with zero expression fallbacks and passes `--ast-required`. A separate
unsupported container allocation verifies required-mode rejection. This
does not yet cover the full compiler or move statement/declaration parsing
into ASTs.

## Task 26: multiline expressions and statement boundaries

Preflight accepts newlines and line/block comments inside expressions,
while declining space-indentation diagnostics before speculative lexing.
Lookahead distinguishes a new dereference or prefix-increment statement
from an operator that continues the preceding expression. The AST parser
also preserves the streaming grammar's fresh-line multiplication boundary
and its warning for a call opening on a later line.

Tests cover multiline arithmetic, calls and conditions, comments, continued
operators, following dereference/increment statements, malformed input,
literal warnings and call-continuation diagnostics.
The multiline fixture also passes `--ast-required` on both compiler host
widths, ensuring its expressions do not fall back to streaming compilation.
The parser-generator grammar now also accepts the existing multiline call
argument syntax, including newlines immediately inside the parentheses.

## Task 27: container values and read-only metadata

Map, set and list handles can flow through ordinary AST values, calls,
returns and compatible assignments. Buffer/container `.length` and buffer
`.data` accesses use explicit descriptor-field nodes. The parser tracks
the streaming grammar's read-only state through nested expression entries,
arguments, indexing and conditionals, and commits it after emission. This
preserves both rejected metadata stores and assignable payload elements.
Map indexing still declines until it has dedicated read/store nodes.

Untyped word-address dereference now uses the legacy word-sized lvalue
default, complementing byte-wide untyped indexing. Tests cover container
identity calls, metadata reads, data-pointer indexing, raw dereference,
payload stores and exact read-only diagnostics for nested lvalues.

## Task 28: existing container types and basic list operations

The AST type reader resolves already-registered nested map/set/list types
in casts, sizes and bare container allocations. Allocations reuse the
normal runtime helpers. First-use composite type registration and map
default constructors still decline. Basic list push, scalar pop, insert,
remove, clear and free operations have explicit nodes; record pushes and
inserts select the byte-copy helpers after validating the argument type.

Tests cover allocation, nested container types, struct element copies,
argument order, C-string conversion, scalar pops, mutation and cleanup,
as well as normal/lint diagnostic parity. Brace blocks now terminate whole
expression preflight, with container-literal keywords protected from being
mistaken for ordinary indexed names. The required-mode rejection fixture
now uses an unsupported interpolated string.

## Task 29: record values, copies and arguments

Ordinary struct and union values can now be whole AST roots, compatible
assignment sources and by-value arguments to direct or indirect calls with
scalar returns. Record copies use the existing aggregate-copy lowering,
including rebuilding inline array descriptors. Basic list pop selects the
record-address helper for aggregate elements, and record values can feed
list pushes and inserts.

The differential fixture checks small records, unions, nested fields, inline
array independence, by-value mutation isolation, indirect calls and record
list operations across the image-comparison matrix. Record-returning calls
and constructors still decline while their return-buffer stack handling is
migrated separately. Value-record field access also remains conservative.

## Task 30: record-returning calls

Direct and typed indirect AST calls now allocate the ordinary caller-owned
record return buffer and pass its hidden address. Arguments measure and
compact any temporary words left by nested calls; plain assignment reloads
its destination from beneath a returned record before copying. Returned
record fields preserve the streaming backend's load and buffer cleanup.

Tests exercise nested return calls, indirect factories, assignment inside
arguments, small and large records, inline arrays and returned fields. A
required-mode test covers return, initialization, assignment and nested
by-value consumption without expression fallback. Constructors and other
value-record field receivers remain separate migration work.

## Task 31: map elements and membership

Map indexing now has explicit read and store nodes. The emitter parks the
receiver and coerced key once, then chooses a scalar read, record-address
read, plain store or compound read/modify/write. Nested map accesses no
longer rely on the streaming parser's global pending-element state. A
parenthesized map element is finalized as a read before any outer operator,
preserving the distinction between `m[k] = x` and `(m[k]) = x`.

Membership nodes cover maps, sets and supported scalar/C-string lists,
including descriptor-to-pointer key decay and left-to-right evaluation.
Differential tests cover nested receivers and keys, chained stores, record
values and fields, signed and floating-point values, string conversions,
collection membership and diagnostic parity. Container methods and map
default constructors remain separate work.

## Task 32: parallel assignment statements

Whole-statement AST parsing now admits parallel assignment as linked
left/right pairs. Destinations are evaluated and parked first, followed by
all coerced right-hand values; stores run left to right and release the
parked span. Nested calls keep their own argument links. Expression contexts
still treat a comma as their enclosing construct's delimiter.

Tests compare swaps, repeated destinations, pointer and field targets,
indexed side effects, mixed scalar widths, strings, floats and returned
record fields across the image matrix. The complete parallel-assignment
fixture must also pass required mode on both compiler host widths. Arity,
map-target, read-only and type-mismatch diagnostics retain the streaming
fallback for exact parity.

## Task 33: increment and decrement statements

Prefix and postfix increment/decrement now lower through explicit AST
mutation nodes at statement position. Prefix dispatch enters the same
whole-statement probe, so required mode also covers that earlier grammar
path. Emission reuses the established implicit-one compound-store lowering.

The differential and required-mode fixture exercises narrow integers,
floats, record fields, side-effecting indexes, pointers, list elements,
brace blocks and newline boundaries. Value-position increments, const or
read-only targets, map elements and non-lvalues retain their diagnostics.

## Task 34: direct calls beyond ten arguments

Direct AST calls now use the declared arity and the expression arena's
capacity instead of imposing a separate ten-argument limit. Parameters
beyond the symbol table's recorded type slots follow the existing unchecked
calling convention. Tests cover twelve arguments, evaluation order, raw
indirect calls, missing-argument diagnostics and required-mode compilation.

Typed function-pointer signatures retain their current ten-parameter bound.
The existing alias parser's unchecked fixed allocation crashes on longer
signatures; that independent bug is already tracked in the tooling backlog.

## Task 35: retain the tokenizer's lookahead across refills

A failed inferred-declaration probe can refill the input buffer and seek
back to just after the current token's lookahead character. That leaves
both the raw token and one lookahead byte outside the retained window.
AST prefix recovery now reconstructs that byte from `nextc` as well as the
raw token, without changing the logical read position or adding a seek.

A nonseekable-pipe regression checks replay and unread-byte preservation.
End-to-end required-mode and image tests cover neighboring positions around
the original 8 KiB boundary and a window shifted by earlier AST read-ahead.

## Task 36: basic map and set methods

Map `get(key[, default])`, map/set `remove` and `free`, and set `add` now
use AST method nodes. Keys and defaults use their respective coercion
types, defaults are evaluated even when a key exists, and record getters
select the address-returning runtime helpers. Record results can feed
copies, fields and by-value calls.

Tests cover default evaluation order, record and string defaults, removal
results, cleanup, required-mode compilation and invalid-argument diagnostic
parity. Map accumulation and collection snapshots remain separate work.
