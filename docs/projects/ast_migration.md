# Production AST migration

The production compiler in `compiler/`, `grammar/` and `code_generator/` is the
single ongoing AST implementation. Continue migration here, using the existing
backend, diagnostic, self-host, REPL and debugger gates. The separate `wc2`
experiment has been retired; [its findings and retirement record](wc2.md)
remain available. Task numbering below continues the original experiment's
history, beginning with task 5, the first production change.

## Current production migration status

The numbered tasks below record successive stages; their fallback lists describe
that stage, and later tasks supersede them. The production compiler remains
streaming by default. `--ast-full-expressions` enables the hybrid AST path;
`--ast-required` rejects any runtime expression that still needs streaming.
Compiler self-host coverage is a narrower gate than full language coverage.

The integrated path prepares and lowers runtime expressions, statements,
control-flow regions, function boundaries, global layouts, enum constants and
extern bindings through the existing backends. It includes inferred generics,
qualified and method calls, operator overloads, C/W varargs, dynamic values,
JSON/protobuf/ndarray builtins, GPU/device operations and diagnostic events.
First-use composite types remain transactional, and unsigned operations retain
`main`'s target-word-size semantics.

`./wbuild ast_expression_suite` generates a required-mode manifest with the
W-native `wast_audit` tool and runs it serially. Positive direct compiler steps
and diagnostic fixture children reject expression fallback; expected failures
use permissive AST mode to preserve diagnostics. Explicit comparison modes,
pinned seeds and other nested compiler drivers retain their existing modes.
The positive full-AST image comparison leg also rejects fallback. These gates
prove the tested corpus, not unrestricted source-language coverage.

Bodies are still visited incrementally. Nodes do not survive as persistent
function or module trees; some symbol bindings remain borrowed. Deferred
expressions, generics and helper bodies can be reparsed, while type/import
declarations still update semantic tables during parsing. Bounded arenas still
fall back on oversized expressions (or reject them in required mode). The
retired `wc2` resident cache is not part of this implementation.

## Remaining milestones

1. Retain complete function and module trees with owned source locations and
   stable bindings. Remove body reparsing and parse-time semantic side effects;
   replace bounded temporary arenas with appropriate lifetime management.
2. Establish multi-error semantic analysis, REPL/debugger rollback and incremental
   emission on those retained trees, then add a resident cache using the retired
   experiment's ownership and invalidation findings.
3. Make and validate the production-default migration decision separately from
   opt-in corpus coverage. Issue #489 remains open for this architectural work.

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
remain later work. The experiment's resident cache was separate and has since
been retired; it was never part of the production compiler.
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

Tests assert twelve direct AST paths on both compiler host widths and cover
allocation, nested container types, struct element copies, receiver/argument
order, nested list calls, C-string conversion, scalar and float pops,
short-circuit versus bitwise side effects, mutation and cleanup, as well as
normal/lint diagnostic parity. Brace blocks now terminate whole
expression preflight, with container-literal keywords protected from being
mistaken for ordinary indexed names. The required-mode rejection fixture
now uses an unsupported interpolated string.

Integration with the unsigned-word arithmetic changes keeps AST result types,
comparisons, division, remainder and right shifts aligned with the streaming
compiler. The unsigned-word and x64 uint64 regression programs also run through
the AST differential image matrix.

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

## Task 37: interpolated string expressions

AST template nodes retain a chain of literal chunks and embedded values.
Preflight validates chunk/brace boundaries without changing lexer state;
committed replay resumes the template tokenizer and decodes each chunk at
its original source event. Emission reuses the existing builder, append
and finish helpers, including lazy formatter imports. Results preserve
the string-literal pseudo-type so `char*` arguments, stores and returns
decay to the data pointer.

The image matrix covers empty and plain templates, adjacent values,
evaluation order, nested templates and quoted literals, escaped braces,
embedded NUL, Unicode, scalar values, floats and metadata access. A
required-mode fixture verifies coverage. Explicit format specifications,
comments/newlines inside interpolation, and unsupported value classes
remain on the streaming path. A buffer slice now exercises required-mode
rejection instead of a supported simple template.

## Task 38: unbound generic signature syntax

Generic definitions now retain a signature AST alongside their source span.
Capture records named types, pointer depth and nested map/set/list types
without binding names, interning compiler types or emitting code. Unsupported
headers keep their existing instantiation parser; complex generic return
syntax, arrays, qualifiers, defaults and variadics are not captured yet.

Lexer-isolated tests cover nested shapes, unnamed parameters, empty and
trailing-comma parameter lists, cleanup on unsupported forms, and an
unchanged type-table count. Signature binding and generic call emission are
the next stage; this metadata alone does not remove expression fallbacks.

## Task 39: explicit generic call expressions

Explicit generic calls now bind captured signature syntax into AST argument
and return types. Pointer and signature records share the expression's
transaction: failed probes remove all staged records, while committed
replay registers signatures at the original closing type-argument bracket.
Repeated calls share the reserved signature, including canonical aliases.
Emission handles queued instantiations and already compiled functions,
record return buffers, argument coercion and evaluation order.

The compiler itself now builds with zero expression fallbacks on x86 and
x64, producing the same images as the streaming compiler. The full-expression
self-host target now uses `--ast-required` to enforce this. Differential
fixtures cover containers, records, aliases, nested calls, pointer registration
and invalid-call diagnostics. Inferred generics, uncaptured signature shapes,
new composite types and calls with more than ten parameters still fall back.
Statements and declarations remain a separate migration; this milestone is
complete expression coverage of the compiler, not a completed AST frontend.

## Task 40: array and slice values

AST roots, call arguments and assignment operands now accept array and
slice values. Promotion stages a slice-value record at the original source
event, preserving registration order before later pointer types and generic
signatures. End-of-root promotion events are committed before emission.
Buffer indexing and metadata access use the same transaction instead of
blocking subsequent pointer registration.

Tests cover typed pointer decay, slice parameters and returns, pointer and
slice stores, typed and raw indirect calls, first-use promotion followed by
a new pointer type, and diagnostic recovery. Raw indirect calls preserve
the descriptor argument because they have no typed parameter requesting
decay. Buffer slicing, explicit buffer casts and array assignment remain
separate work.

## Task 41: buffer slices and explicit casts

Slice nodes retain the receiver and optional start/end expressions. Emission
preserves left-to-right evaluation, omitted-bound defaults, range checks and
shared backing storage through the existing descriptor helper. Nested array
and string slices can feed indexing, calls and metadata access.

Explicit array/slice casts stage value promotion before coercion. Matching
pointer and word-sized integer casts decay to element data; mismatched-pointer
warnings and sub-word-address errors retain the streaming diagnostic path.
Tests cover all bound forms, empty/nested slices, mutation through a view,
cast decay and malformed bounds. A failed start expression is distinguished
from an omitted start. Required-mode rejection now uses a template format
specification rather than a supported slice.

## Task 42: typed container literals

List, map and set literals now retain ordered entry nodes. Emission reuses
container allocation and insertion helpers, including record-copy helpers,
and releases each entry's temporary return buffers before the next entry.
Preflight tracks literal braces separately from statement block delimiters,
including nested and multiline entries.

Differential tests cover empty literals, trailing commas, nesting, key/value
evaluation order, duplicate set keys, record values and invalid-entry
diagnostics. The parser-generator grammar now accepts multiline container
literals already accepted by the compiler, with focused grammar tests.
First-use composite type registration remains a separate step: literals
whose container type is not yet registered still use the streaming path.

## Task 43: record constructors

Record value constructors and heap constructors retain ordered field nodes,
including named fields and partial named initialization. The visitor reuses
field stores and aggregate copies, preserving temporary-buffer cleanup,
array-descriptor initialization, zeroing order and by-value argument layout.
A heap constructor registers its result pointer after its arguments, matching
the streaming type-registration order. Scalar field access can consume a
value constructor's temporary buffer.

Tests cover positional/named/nested constructors, record arguments, union
fields, heap allocation, empty constructors with array descriptors, and
constructors inside container literals. Wrong field names, mixed argument
forms, arity warnings, fixed-array field initialization and incompatible
arguments retain their existing diagnostics. Qualified constructors and
dynamic array allocation remain separate work.

## Task 44: dynamic array allocation

`new T[count]` now has an AST allocation node. The count is evaluated once;
emission preserves the existing count limits, two-word descriptor, payload
zeroing and element-width arithmetic. The result's slice-value type is staged
after the count expression, so later type registration keeps its original
order.

Tests cover scalar/record elements, zero lengths, calls, casts, indexing and
invalid allocation diagnostics. Native x86/x64 checks also verify negative
count traps and byte-identical execution with bounds checks disabled.

## Task 45: generic struct and slice parameter shapes

Unbound signature syntax now represents generic struct applications and
slice wrappers, including nested applications and pointer element types.
Binding resolves existing instantiated structs and slice types without
instantiating either during a speculative call parse. Pointer and function
signature registration retain their existing transaction.

Shape tests verify nested argument lists and unchanged compiler type counts.
The differential/required fixture now covers generic struct parameters,
generic slice reads/stores and `lib.array`'s `array_free` wrapper. Complex
return signatures and first-use composite instantiation remain separate work.

## Integrated map defaults and formatted interpolation

This integration reconciles compiler-completion through `db157ce8`, migration
through `435b4b50`, and the unsigned arithmetic baseline in `7ccc2a01`. Later
work on those development branches is not implicitly included.

Map default constructors retain scalar defaults, factories and automatic nested
container defaults as explicit AST operands. Lowering preserves allocation and
argument evaluation order through the existing runtime helpers. Format nodes
capture fill/alignment, padding, width, precision and format kind without
emitting speculative diagnostics, then replay the existing template tokenizer
and formatter at their source positions. Invalid forms keep streaming diagnostic
parity.

These paths are combined with the newer generic signature binding, buffer type
registration, constructors and allocation nodes. The differential matrix retains
the fixtures from both development branches, including cross-feature cases.

## Owned production statements

Expression preparation now returns a root into a caller-owned arena before
machine-code emission. Ordinary return nodes own that arena or represent a bare
return. The shared return lowering retains coercion, aggregate copies, deferred
cleanup and frame unwinding. Generator/GPU return forms retain their existing
handling.

Statement ownership is currently bounded by immediate lowering; symbol and type
references are not stable across later declarations or REPL rollback. This is a
step toward statement trees, not a persistent module representation.

Ordinary expression statements now also own a prepared expression arena after
statement dispatch has ruled out declarations and labels. Lowering retains the
streaming expression's assignment flag, stack temporaries and read-only state;
emission precedes the final lexer advance to preserve source-sensitive
warnings. Prefix increments keep their existing dedicated statement dispatch.
Stats distinguish AST/streaming expression statements from expression roots.

The integrated compiler's required-mode check on 2026-10-03 reports 39,361
expression roots, 5,681 return statements and 18,232 ordinary expression
statements on x86; x64 reports 39,604, 5,698 and 18,348 respectively. Each category
has zero streaming fallbacks for this corpus. These are parser-entry counts,
not percentages of source coverage or an all-language AST guarantee.

## Reproducible production AST audit

The W-native `wast_audit` tool generates an AST-enabled manifest from the current
`build.base.json` and source directives. It adds `--ast-full-expressions` to
direct production compiler compile/check commands, preserving pinned-seed steps
and commands that already select an AST mode. It writes a JSON selection report
listing the changed target/step pairs. Generation does not execute the manifest.

```sh
./wbuild wast_audit
bin/wast_audit manifest bin/ast_suite_manifest.json > bin/ast_suite_selection.json
env -u NO_COLOR bin/wexec -f bin/ast_suite_manifest.json -j 1 tests
```

Run the audit suite separately from ordinary builds. Serial execution avoids the
known nested-build race in which a driver rebuilds a compiler still being used
by another target. The flag covers implicit runtime imports, but compiler
launches inside test drivers retain their own mode selection. A hybrid-suite
pass permits fallbacks and does not prove complete language coverage.

A fallback census summarizes one or more compiler audit logs deterministically
by file and starting token, along with the emitted/streaming parser counters:

```sh
bin/wv2 check --quiet --ast-audit --stats w.w 2> bin/compiler_ast_audit.jsonl
bin/wast_audit census bin/compiler_ast_audit.jsonl
```

Check the compiler exit status separately. A census is a description of its
input log; it cannot certify that the log is complete or that compilation
succeeded. Malformed audit records, invalid or overflowing counters, and a
mismatch between fallback records and summed streaming-root counters make the
census command fail. `records_match_streaming_roots` is null when streaming-root
stats are absent or any counter is invalid. Counts aggregate across invocations;
even matching totals cannot detect truncation after an earlier complete
invocation. Counts include nested parser entries after an outer fallback, so
they are not source-coverage percentages. Required-mode self-host checks remain
in `ast_required_expression_verify`, and the differential fixture matrix remains
in `ast_expression_test`.

## Integration validation

The first integrated wave passed the pinned-seed bootstrap, x86/x64 self-host
fixpoints and strict AST-required image/fixpoint gates. Differential fixtures
compare both compiler host widths across x86, x64, ARM64 ELF, ARM64 Darwin,
win64 and wasm images, with native x86/x64 execution and REPL/debugger recovery.
Cross-target image parity is distinct from executing every image on its target.

`env -u NO_COLOR ./wbuild tests` passed all 846 targets. The generated AST
manifest selected 1,137 direct compile/check steps, preserved six explicit AST
mode steps, and its serial `tests` run also passed all 846 targets. Selection
counts describe the complete manifest, not how many selected steps the `tests`
target executes. No compiler fallback records appeared in the x86/x64 compiler
census. The production mode remains opt-in; the scope and remaining architecture
work are listed in the current-status section above.

## Task 46: generic return shapes

The generic declaration lookahead now retains the return type's syntax
instead of only skipping its brackets. Capture tracks bracket depth through
nested types; unsupported shapes finish the original balanced scan without
rewinding or duplicating lexer diagnostics. Accepted return graphs transfer
directly into the signature AST.

Tests cover generic pointer and by-value record returns, nested return
shapes, and recovery past unsupported qualifiers, fixed-array arguments and
oversized type-argument lists. Ordinary non-generic declarations still rewind
to their original type parser. Binding continues to require existing
instantiated struct and slice records.

## Task 47: list slices

List slicing now retains the receiver and optional bound expressions in a
dedicated AST node. Emission preserves left-to-right evaluation and passes
omitted-end information to the existing copy helper. Negative indexes,
range checks and record element copies retain their existing behavior.

Differential and required-mode tests cover all bound forms, nested slices,
independent backing storage, record copies and malformed bounds.

## Second integration wave

This wave incorporates generic return-shape capture from `5096465a` and list
slices from `d22ae415`. These are fixed source snapshots; later development
branch changes are not automatically included.

Numeric `map.add(key[, delta])` uses dedicated accumulation nodes. The receiver,
key and optional delta are evaluated once in streaming order; floating-point
values retain the existing read/add/store lowering. Unsupported value classes
and invalid calls retain streaming diagnostics. Map/set `keys()` and map
`values()` retain snapshot method nodes, using the same element-width helpers as
the streaming path. Their result list type must already be registered; creating
new composite types remains separate work. List slicing copies through the
existing runtime helper and retains omitted-bound and negative-index behavior.

`if`/`elif` and `while` headers now own their prepared condition arenas through
expression and branch lowering. The shared condition tail preserves promotion,
lint completion, enclosing condition state and the false branch. Separate
AST/streaming header counters identify the migrated scope. Header arenas are
released before parsing the bodies: block membership, body statements and loop
regions still use the streaming parser, so these are not retained control-flow
trees.

The second-wave compiler census reports 39,570 expression roots, 5,723 return
statements, 18,316 expression statements, 8,972 if/elif headers and 945 while
headers on x86. On x64 these counts are 39,813, 5,740, 18,432, 9,014 and 958.
All corresponding streaming counters and fallback-record counts are zero;
the census confirms record/counter consistency on both hosts. These figures
describe the compiler corpus, not complete language coverage.

Independent comparisons compile the four new collection, composition,
list-slice and control-header fixtures plus `w.w` with legacy, full-AST and
required-AST modes. All 120 compilations produce identical images within each
host/target case across the six backends. All 48 native fixture executions pass;
the nonnative images are compared without execution.

The pinned-seed bootstrap, default and strict AST-required x86/x64 self-host
fixpoint gates, and audit-tool tests on both word sizes pass. Both
`env -u NO_COLOR ./wbuild tests` and the serial AST-enabled manifest run pass all
846 targets. The latter selects 1,137 direct compile/check steps across the
complete manifest and preserves six explicitly selected AST-mode steps; nested
driver launches retain their own mode selection. REPL recovery compares exact
output and diagnostics after normalizing only the process ID in its temporary
source directory, preserving entry names, source coordinates and caret text.

## Task 48: first-use container types

Expression type syntax now stages first-use `list[T]`, `map[K, V]` and `set[K]`
records, including nested containers, aliases and pointers to containers.
Literals, `new`, casts, `sizeof` and explicit generic type arguments share the
transaction. Map/set `keys()` and map `values()` also stage their result list
type, so snapshots no longer require an earlier list declaration.

Replay registers containers after their closing type bracket and snapshots
after their closing call parenthesis, preserving type order alongside pointer,
slice-value and generic signature events. Speculative names live in a bounded
arena; committed container names are independently owned, and pointer records
borrow the committed base name. Invalid element/value types retain the streaming
diagnostics. Exhausting either staging capacity leaves the ordinary fallback.

Type-table truncation and reset now explicitly invalidate the name index.
The previous length watermark could miss invalidation when replay appended
multiple records before the next lookup, retaining speculative names or stale
indices. Transaction tests cover rollback, replay, arena reuse and capacity
failure on both host widths.

The differential fixture covers nested literals, evaluation order, automatic
map defaults, snapshots, aliases and generic calls across the existing six
backends, with native x86/x64 execution and required-mode checks on both compiler
hosts. Diagnostic and REPL comparisons exercise failed probes and recovery
after literal decoding fails during committed replay. Generic struct
instantiation, new composite shapes introduced only while binding generic
signatures, and persistent statement/block ownership remain subsequent work.

Validation passed the pinned-seed bootstrap, x86/x64 fixpoints, focused AST
gates, and both ordinary and serial AST-enabled suites (836 targets each).
The generated audit selected 1,129 direct compile/check steps and preserved
eight explicit AST-mode steps. Its first run stopped on a VCS sync pull failure;
the tool and test images were byte-identical to their streaming builds, and
both the isolated retry and the complete audit rerun passed.

## Completion-branch integration

The local `ast-compiler-completion` history through `b31fec3f` (its tasks 46–108)
is integrated after main's task 48 above. Its expression, statement and
executable-declaration visitors replace the earlier partial visitors. Existing
main integration fixtures, unsigned arithmetic fixes, type-index invalidation
and `wc2` retirement are retained. Historical task numbers on the two branches
overlap; this section records their convergence rather than renumbering them.

The branch's Python suite transformation is implemented in `tools/ast_audit.w`
and exposed as `bin/wast_audit required-manifest <output.json>`. It recognizes
standard `env` prefixes, skips queries and compiler option operands, preserves
explicit modes and seeds, and activates required positive diagnostic fixtures.
The census accepts the new statement/declaration counters and historical logs.

`env -u NO_COLOR ./wbuild tests` passes all 837 targets, including strict
self-host warning checks and x86/x64 ordinary, permissive-AST and required-AST
image/fixpoint comparisons. The integrated compiler's required-mode census has
43,299 AST expression roots and zero streaming roots. The required suite
manifest selects 1,028 positive direct compiler steps, 104 expected-failure
steps and 35 diagnostic fixture groups, preserving eight explicit AST-mode
steps. Selection counts cover the manifest, not just the `tests` closure.

`env -u NO_COLOR ./wbuild ast_expression_suite` also passes all 837 inner
`tests` targets. The AST path remains opt-in, and #489 remains open for the
retained-tree, semantic-analysis and incremental-compilation milestones above.
