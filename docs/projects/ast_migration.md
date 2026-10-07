# Production AST migration

The production compiler in `compiler/`, `grammar/` and `code_generator/` is the
single ongoing AST implementation. Continue migration here, using the existing
backend, diagnostic, self-host, REPL and debugger gates. The separate `wc2`
experiment has been retired; [its findings and retirement record](wc2.md)
remain available. Task numbering below continues the original experiment's
history, beginning with task 5, the first production change.

## Current production migration status

The numbered tasks below record successive stages; their fallback lists describe
that stage, and later tasks supersede them. Since completion-plan unit P1.4 the
production compiler compiles **through the AST front end by default**: every
root is tried as an AST and falls back to the streaming grammar only where the
AST declines (an expression too large for the bounded arena;
`ast_expression_suite` finds no other fallback in the tested corpus, and none
at all in the compiler). `--streaming` selects the
streaming front end for the whole program, implicit runtime imports included;
it cannot be combined with `--ast-full-expressions`, `--ast-audit`,
`--ast-retain`, `--ast-required` or the retaining `tree` query
(`check --all-errors` works on either front end). `--ast-full-expressions` is now a no-op kept for
scripts, `--ast-expressions` selects grouped scalar AST only together with
`--streaming`, and `--ast-required` still rejects any runtime expression that
would fall back to streaming. The REPL and wdbg follow the same default and
accept `--streaming`. The pinned seed predates the flip, so the bootstrap
`./w w.w -o bin/wv2` stage still compiles streaming; `bin/wv2` and every later
stage compile AST, and images are byte-identical either way. Compiler
self-host coverage is a narrower gate than full language coverage.

The integrated path prepares and lowers runtime expressions, statements,
control-flow regions, function boundaries, global layouts, enum constants and
extern bindings through the existing backends. It includes inferred generics,
qualified and method calls, operator overloads, C/W varargs, dynamic values,
JSON/protobuf/ndarray builtins, GPU/device operations and diagnostic events.
First-use composite types remain transactional, and unsigned operations retain
`main`'s target-word-size semantics.

`verify` now exercises the AST path, and `ast_expression_verify` is the
streaming oracle: `bin/wv2 --streaming` (and `--streaming --ast-expressions`)
must reproduce `bin/wv3` on both hosts and reach their own fixpoints.
`./wbuild ast_expression_suite` generates a required-mode manifest with the
W-native `wast_audit` tool and runs it serially. Positive direct compiler steps
and diagnostic fixture children reject expression fallback; expected failures
use permissive AST mode to preserve diagnostics. Explicit comparison modes
(`--ast-*`, `--streaming`), pinned seeds and other nested compiler drivers
retain their existing modes. Before rewriting, `wast_audit required-manifest`
fails if a direct compiler step still opts in with a flag the default made
redundant. These gates prove the tested corpus, not unrestricted
source-language coverage.

Bodies are still visited incrementally. `--ast-retain` now preserves owned
production traversal trees (described below), including function/statement
nesting, expression payloads, owned semantic type graphs and session-local binding
identities. `w tree --json` exposes this graph. It is not yet an independently
executable module IR; lowering still uses temporary nodes and some borrowed
symbol bindings. Deferred
expressions, generics and helper bodies can be reparsed, while type/import
declarations still update semantic tables during parsing. Bounded arenas still
fall back on oversized expressions (or reject them in required mode). The
retired `wc2` resident cache is not part of this implementation.

## Remaining milestones

1. Retain complete function and module trees with owned source locations and
   stable bindings. Remove body reparsing and parse-time semantic side effects;
   replace bounded temporary arenas with appropriate lifetime management.
2. Move the opt-in production multi-error checker and native incremental function
   sessions onto independent retained-tree analysis/emission. `check --all-errors`
   now recovers at statement/declaration boundaries on POSIX hosts, and
   `repl/incremental.w` reuses emitted scalar-function prefixes. General module
   invalidation, arbitrary-definition reuse and a resident module cache remain.
3. Make and validate the production-default migration decision separately from
   opt-in corpus coverage. P1.4 flips the default; the measurements behind the
   decision are in "AST front end by default (P1.4)" below. Retiring the
   streaming grammar (P1.5) waits for a release that carries the flip. Issue
   #489 remains open for this architectural work.

The forward plan for these milestones, split into parallelizable units
with file ownership and gates, is [ast_completion_plan.md](ast_completion_plan.md).

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


## Retained production traversal ownership

`--ast-retain` enables full-expression mode and retains a session-owned forest
alongside the existing production parser. `--ast-required` can be combined with
it to reject expression fallback. `--stats` reports the retained node count.
The flag is also accepted by the REPL and debugger.

```sh
bin/wv2 check --quiet --ast-retain --ast-required --stats program.w
bin/repl --ast-retain
bin/wdbg program.w --ast-retain
```

`compiler/retained_ast.w` owns growable source buffers and individually allocated
nodes. A source version copies the bytes the tokenizer consumes, rather than
reopening a pathname after compilation. Each fresh file compilation gets a new
version; replays cannot overwrite previously captured bytes. Module roots own
function and statement nesting from the production traversal. Existing definition
hooks adopt the corresponding function/initializer children into declarations.
Expression groups retain their opcode/operand topology, decoded scalar and text
literals, type descriptions, and copied ordinary variable/direct-call bindings.
Operand indices retain their opcode-specific meaning inside the expression group.
No retained names, literal bytes, source paths or binding descriptions borrow
storage from expression arenas or the symbol/type tables.

The REPL checkpoint, reset and debugger-evaluation rollback path retracts the
failed entry's retained suffix, including partially built nodes and imported
sources. Node IDs remain stable until that suffix is retracted or the session
is cleared. Sources and nodes are released by `retained_clear`; there is no
fixed retained-node capacity. The parser's temporary expression limits remain.

At this ownership-only stage, this was **not completion of the remaining
milestones**; the following section records its semantic and tooling extensions.
The forest records the traversal, including repeated deferred/generic visits;
it is not a replacement for those reparses. Binding/type descriptions are not
stable semantic identities, and opcode-specific lowering payloads are not yet
fully retained. Parsing still changes semantic tables and emits code. Multi-error
semantic analysis, analysis/emission separation, incremental emission and a
resident cache remain outstanding. #489 stays open; the retired experiment's
#488 stays closed.

`ast_retained_test` and its x64 twin exercise real compilation, nested statement
membership, scope-slot reuse, source ownership after file deletion, expression
execution, failed-entry rollback and reset. `ast_retained_memory_test` and its
x64 twin force the guard allocator and verify growth, independent source versions,
source-change rejection, suffix rollback, repeated clear and zero retained leaks.

Validation: pinned-seed bootstrap, x86/x64 self-host fixpoints and the full
`./wbuild tests` suite pass (841 targets). The permanent AST differential test
compares retained and streaming images on all six backends from both compiler
host widths and executes the native x86/x64 images. Manual retained-mode debugger
checks on both host widths recover from a failed watch expression. The compiler
also checks itself with `--ast-retain --ast-required` without expression fallback.


## Semantic ownership, isolated analysis and incremental function sessions

The retained forest now owns semantic type records, including recursive field
shapes, aliases, pointer targets, function signatures, enum members and source
locations. Explicit import nodes own their spelling, normalized module path and
alias, including declarations whose compilation the import registry deduplicates.
Bindings receive session-local IDs keyed by source version, declaration location
and lexical function owner. Their names, types and signatures survive temporary
symbol-table reuse; rollback retracts the matching semantic suffix. These are
declaration identities: prototype and definition records are not yet unified
into one linker identity. Unused locals are not yet separately inventoried. Expression
records copy scalar lowering payloads, text/name arenas and diagnostic text.
Backend table indices remain explicitly raw metadata where a semantic replacement
has not yet been introduced.

```sh
bin/wv2 tree --json --quiet program.w
bin/wv2 x64 tree --json --quiet program.w
bin/wv2 check --json --quiet --all-errors program.w
```

`tree` emits versioned NDJSON source, node, type and binding records. IDs refer to
one query/session, not a persistent cross-build identity. Parent links can point
forward because completed declarations adopt their bodies. Expression operands
retain their opcode-specific, group-local meaning. Length-delimited literal and
arena bytes use hex fields, preserving NUL and non-UTF8 bytes. Failed compilation
returns diagnostics without a partial tree dump.

`check --all-errors` uses the production semantic checks in isolated copy-on-write
processes at statement and declaration boundaries. A failed probe cannot mutate
its parent's symbols, types, emission buffers or retained graph. Successful
probes replay with nested probing disabled; kernel source-file offsets are
restored before replay. This reports independent errors inside the same function
and across declarations/imports in deterministic source order, and returns a
failure status before final output. It is opt-in, requires a POSIX host with
`fork` and seekable source files, and stops after 100 errors. It is recovery around
the production parser, not an emission-free semantic pass: broken lexing or
imports can still prevent further analysis, and uses of discarded declarations
can produce follow-on diagnostics.

`repl/incremental.w` supplies a native x86/x64 incremental compilation API over
the production REPL checkpoints. An ordered set of admitted scalar function
sources stays resident. An unchanged update emits nothing; an edit, insertion or
deletion preserves the identical prefix and recompiles only the affected suffix.
The API owns source copies, validates admission before mutation, rejects changes
to compiler options/environment, and removes failed/stale suffix definitions.
Tests check actual code bytes, addresses, retained-node ownership and execution
after edits and recovery. See [incremental compilation](incremental_compilation.md)
for the API and its intentionally restricted admission rules.

These changes do not complete the independent module-IR migration. Parsing still
updates semantic tables and emits code; generic/deferred bodies still reparse;
some expression operands are raw backend IDs; temporary expression arenas remain
bounded. Incremental sessions do not yet handle arbitrary imports, types, globals,
generics or relocation of independently compiled definitions. A persistent
module cache and a production-default decision remain separate work.
**#489 remains open; #488 remains closed.**

Validation: `env -u NO_COLOR ./wbuild tests` passed all 849 targets, including
x86/x64 self-host fixpoints and the existing AST cross-backend comparisons.
The final incremental admission changes additionally passed both focused native
targets. Both compiler host widths checked `w.w` with
`--ast-retain --ast-required`; win64 and arm64_darwin compiler checks passed.
The parser-generator grammar also parsed every newly added W file explicitly
(the ordinary corpus gate selects tracked files).


## Declaration inventory and independent module dependency analysis

The next increment adds declaration inventory and a consumer of the owned
records that does not invoke the parser or backend. Native function bodies and
prototypes retain named parameters even when unused; local declarations made
inside retained functions have explicit `local` nodes. Their parents preserve
the production traversal's lexical membership, and their binding IDs distinguish
shadowed names after symbol slots have been recycled. Inferred locals retain
the name's location rather than the token following their initializer.

Global binding occurrences now carry a `linkage` ID. An unresolved prototype,
its uses, and its definition share this identity while keeping their individual
declaration records. A REPL redefinition starts a new identity. Existing records
remain immutable, so rollback removes a suffix without rewriting the prefix.
These IDs still belong to one retained session, not to a persistent cache.

Types record their source version. Imports record `import_source`, the source
ID selected by the actual resolver, including aliases, duplicate imports and
cycles. The import spelling alone is not used to guess which file was opened.
Resolver context is included in retained checkpoints so a failed nested import
cannot label later input with the abandoned import's identity.

`compiler/module_dependencies.w` builds an independently owned graph from these
records. Edges cover explicit imports, resolved bindings (including both the
prototype and defining module), and recursive semantic type shapes. The graph
owns its paths and adjacency lists and remains usable after `retained_clear()`.
`module_dependencies_invalidate` computes the changed source IDs and their
transitive users in deterministic source-ID order, handling cycles and duplicate
seeds. Building and querying it neither reads source files nor changes compiler
symbols, types or code. `module_dependencies_free` releases it.

`w tree --json` now emits schema **version 2**, adding `local` nodes, binding
`linkage`, type `source`, import `import_source`, and `dependency` records.
Each dependency has `source`, `target`, and a `reasons` bitmask: import = 1,
binding = 2, type = 4. Multiple reasons for an edge are combined.

This is an analysis and invalidation-planning API, **not an incremental emission
cache**. It describes dependencies present in retained records. It does not yet
inventory every parse-time dependency, such as all constant evaluation and
uninstantiated generic bodies, or record negative import lookups. Changed import
resolution requires rebuilding the snapshot. It must not be used on its own to
authorize machine-code reuse. Complete module IR, parse/analysis/emission
separation, independent multi-error semantic checking, relocation and persistent
caching remain outstanding. **#489 remains open; #488 remains closed.**

`module_dependencies_test` and its x64 twin cover unused declarations, shadowing,
prototype resolution across separate inputs, global/type/generic import users,
failed-import rollback, redefinition, graph ownership, and cyclic invalidation.
The retained-memory tests include graph teardown under the guard allocator.

Validation: `env -u NO_COLOR ./wbuild tests` passes all 861 targets, including
x86/x64 fixpoints, strict self-host checks and AST differential comparisons.
Both native targets check `w.w` with `--ast-retain --ast-required`; compiler
checks for win64 and arm64 Darwin also pass. The reference parser additionally
parses the two new W files explicitly, beyond its tracked-file corpus gate.



## AST parse cost (completion plan P1.1)

Profiling `bin/wv2 --ast-required --strict w.w` under callgrind (symbols
mapped through `nm`) showed that the speculative parse itself was not the
main cost. Three overheads dominated the AST path's 2.5x wall-clock ratio:

1. **Arena initialisation.** `expression_ast` held 22 `int[4096]` node
   columns and 32 KiB of decoded text inline. Every grammar frame that
   declares one zero-filled about 400 KiB (x86) or 750 KiB (x64) of stack,
   whether or not the probe accepted. Expression statements, guards,
   returns and declarations each paid this once per root, about a third of
   all instructions retired for `w.w`.
2. **Lexing every accepted root twice, with a quadratic replay.** The
   tokenizer was snapshotted (malloc and token clone), the root parsed,
   the tokenizer restored, and every token lexed again. At each replayed
   token the whole arena was scanned for events.
3. **Per-byte preflight and eager chain facts.** The root and group
   preflights ran a long comparison chain on every byte. Every `&`/`^`/`|`
   level scanned its operand's nodes for calls, even when no operator
   followed.

What changed:

- The node columns, decoded text and token records live in reusable heap
  **node slabs** (`compiler/expression_ast.w`), bound by
  `expression_ast_bind` when a probe starts. The stack header keeps only
  the small staged-type tables. Slabs form a stack ordered by owner
  address. A bind releases every slab whose owner is at or below the new
  tree, because that owner's frame has returned. Enclosing live roots, such
  as a generic body compiled while an outer root emits, keep theirs.
  Columns start at 64 nodes and grow to the unchanged 4096-node limit.
  For `w.w`, 136 slabs exist at the deepest point, set by the 132-branch
  `else if` chain in `lib/lib.w`.
- **One lexing pass per accepted root.** While parsing, the probe records
  each token's complete lexer state: offset, both diagnostic positions,
  line/column/tab, `nextc`, `byte_offset`, newline flag, length, raw bytes
  and serial. An accepted root leaves the lexer where its parse ended,
  which is exactly where lexing the root again would have left it.
  `ast_expression_replay_recorded` then commits the source-ordered events
  in the original visit order: staged pointer records, then nodes by arena
  index, with a node's generic commit after its offset event. Those events
  are literal decoding, committed symbol uses, generic commits and replayed
  diagnostics, including bit-31 cast notes and `--lint` checks. Before
  each event token, the recorded state is restored, so `token`,
  `diag_token_*`, `line_number` (source-context lines) and `byte_offset`
  match what the second lexing pass produced.
  Afterwards the parse's end state is restored, with one exception. The
  old visit left an in-place decoded final token in the buffer whenever
  the root ended virtually right after it. That buffer is visible to the
  next real token's whitespace diagnostic, so it is preserved.
  Template roots, whose events lex chunks again, and roots shortened at a
  statement colon keep the old restore-and-lex replay
  (`ast_expression_replay_by_lexing`). A declined probe restores from an
  allocation-free `tokenizer_snapshot` (`compiler/tokenizer.w`).
- The preflights skip runs of word bytes and blanks with a byte-class
  table. A bitwise chain computes its bool and call facts only when an
  operator actually follows; both are pure queries of the same node range.
  `ast_expression_scalar_type` looks the type kind up once instead of once
  per `type_is_<kind>` predicate.

`--stats` in AST modes now also prints `AST preflight bytes`,
`AST tokenizer snapshots`, `AST tokens replayed` (tokens whose state was
re-established for an event), `AST relexed roots` and `AST node slabs`.
For `w.w` on x86 these are 1,161,210 / 44,808 / 115,566 / 3 / 136. Before
this change every accepted root replayed all of its tokens by lexing.

During development an environment-gated self-check lexed every
fast-replayed root again and compared each recorded token row and the end
state field by field. It found one difference, the in-place decoded final
token, which was then fixed. With the check enabled, the whole serial
`ast_expression_suite` and `ast_expression_test` passed with no
mismatches. The check is not part of the landed code.
`tests/ast_parse_cost_test.w` covers 300-deep root nesting, roots of
about 2,400 nodes (column growth), final-token events followed by a
whitespace diagnostic, bit-31 notes, template roots and the new counters.
Each case is compared against the streaming compiler on both hosts and
both widths.

Measured for `bin/wv2 … --strict w.w`, median of five runs on the shared
4-core container (load from other agents present):

| mode | x86 before | x86 after | x64 before | x64 after |
| --- | ---: | ---: | ---: | ---: |
| default (streaming) | 0.790 s | 0.800 s | 0.703 s | 0.690 s |
| `--ast-full-expressions` | 2.100 s | 0.960 s | 2.170 s | 0.893 s |
| `--ast-required` | 2.056 s | 0.921 s | 2.191 s | 0.914 s |
| `--ast-retain --ast-required` | 7.70 s | 6.12 s | 8.30 s | 6.43 s |
| **`--ast-required` / default** | **2.60x** | **1.15x** | **3.12x** | **1.32x** |

"x86"/"x64" are the host compiler (`bin/wv2` vs `bin/wv2_64`) compiling
`w.w` for its own width. Every output image was byte-identical to
`bin/wv3`/`bin/wv3_64` in every mode. On the x86 host the plan's 1.25x
target is met. On the x64 host it is just missed. An interleaved run of
nine default/`--ast-required` pairs measured 0.696 s vs 0.880 s (1.26x),
and earlier runs ranged from 1.22x to 1.32x with load. Instructions retired
(callgrind) are 6.41G vs 5.63G on x86 (1.14x) and 6.60G vs 5.90G on x64
(1.12x). The remaining x64 wall gap is front-end bound: I1 misses are 82M
vs 57M, spread thinly over the probe, emitter and replay functions with no
single hotspot. D1 misses (7.4M) match the streaming compile. Padding the
slab column stride to avoid L1 set aliasing was tried and measured. It
made no difference and was not kept.

What this does not claim. Emission still happens per root during
parsing; nothing here moves toward tree-then-emit (checkpoint B). The
retained forest (`--ast-retain`) is only faster by the same parse
savings. Its own allocation cost is P1.2. The streaming front end is
still the default (P1.4). Template roots still lex twice. The slab stack
assumes AST trees are compiler stack locals, which every caller is today;
a heap-allocated tree would need an explicit release. **#489 remains open.**

## Retained-forest cost and query ergonomics (P1.2)

Retaining the forest no longer dominates an AST compile. Before this change
`--ast-retain --ast-required` compiled `w.w` in 7.9 s against 2.1 s for
`--ast-required` (3.8x on this container); it now takes 2.8 s (x86 host) and
3.0 s (x64 host), about 1.3x, with identical images. Under callgrind the
retained compile of a fixed corpus went from 77.3 G to 17.4 G instructions,
against 13.8 G for `--ast-required` alone.

Most of the old cost was quadratic lookup, not allocation. Every source byte
compared the file name against the cached path with `strcmp`; every binding and
type note scanned every source version by path; a definition scanned all
earlier bindings for the prototype it completes; parameters were found by
walking the whole symbol index per function; and each declaration walked every
node created since the previous declaration, imported modules included. These
are now a pointer-identity cache on the per-byte path (every new source version
and every rollback resets it), a path index plus a debug-file-index cache,
an `origin_previous` chain per raw symbol offset, a binary search into the
sorted symbol index, and a per-source list of top-level children. Binding
lookup keys use the debug file index instead of the path and are built in a
reused buffer.

Storage changed as planned. Nodes live in 1024-node chunks owned by the
session; `retained_nodes[i]` still points at node `i`, so consumers are
unchanged. Names, files, type spellings, payload text and import paths are
interned once per session. Each expression group's text and type-name arenas are
copied once into a chunked session text arena, and string-literal operands are
slices of that copy instead of separate allocations. Rollback is therefore a
high-water mark: it truncates the node list and the text arena and frees no
per-node strings; chunks above the mark are reused. `retained_clear` frees
chunks, arena and interned text, and `ast_retained_memory_test` now also runs
under `W_DEBUG_ALLOC=1` and covers chunk reuse, record placement at chunk
boundaries and the path index across rollback.

`w tree --json` streams. It flushes at record boundaries once 64 KiB are
buffered instead of building the whole dump (185 MB for `w.w`) in one buffer,
and writes integers and plain strings without per-field allocation. The `w.w`
dump takes 4.1 s instead of 12 s and peaks at 90 MB instead of 302 MB (x86
host); its bytes are unchanged. Two filters avoid the full dump:
`--file <path>` (repeatable; a recorded path or a suffix at a directory
boundary) keeps the source, node, type, binding and dependency records of the
named sources, and `--no-expressions` drops `expression` and
`expression_group` nodes. Filters never renumber: the leading `tree` record
still carries the session totals and references may name omitted records. A
`--file` that matches no compiled source is an error. No field was added, so
the schema stays **version 2**.

What this does not claim: the per-byte pointer cache relies on every new
source version entering through `retained_source_begin`; the forest is still a
record of the traversal and is not read back to emit; interned text survives
rollback until `retained_clear` (it is bounded by distinct spellings). The
remaining retained cost is mostly the per-operand binding and type notes.
**#489 remains open.**

## Diagnostic codes, end columns and related notes (C3.2)

`w check --json` records gain four fields, appended after `arch`:
`code`, `end_line`, `end_column` and `related` (the optional `help`
sits between `end_column` and `related`). `docs/projects/lint.md`
"JSON output" specifies them.

Codes come from one append-only table in `compiler/diagnostics.w`
(W0001-W0399): each row is a frozen message with `@` for its variable
parts, and the most specific matching row wins. The emitter computes
the code from the final message text, so no call site changed for it.
Every message in the 382-file fixture corpus (1,729 records across
default, `--lint` and `--ast-required` on both widths) maps to a
specific row; none falls back to W0000.

The end position is the exclusive end of the reported token, checked
against the source bytes when the file can be read back. Related notes
are attached by the call sites that know the declaration: the
did-you-mean suggestion and the later definition for "Cannot find
symbol", the earlier definition for `symbol redefined`, generic
redefinition and `:=` redeclaration, and the callee or enclosing
function for argument and return mismatches. They are recorded
only under `--json` and dropped by `diag_clear()`, so a suppressed
probe warning cannot pass its note on. Human-readable output, exit
statuses and the existing seven fields are byte-identical over the
same corpus.

What it does not claim: the span is the current token's, not a
retained node's. No closed retained node covers a diagnostic when it
fires, because expressions are retained after emission. Node-span ends
need tree-then-emit. Related notes cover the listed diagnostics only;
arity warnings have none because the AST-mode replay event carries no
callee symbol and both front ends must emit identical records. `ast_diagnostic_codes_test` pins the codes, spans
and notes. **#489 remains open.**

## Required-mode suite in CI and the retained canary

CI now runs `./wbuild ast_expression_suite` as its own job, beside the ordinary
`./wbuild tests` job and bootstrapped the same way (the pinned seed, the
32-bit runtime and ptrace attach). The suite stays out of `tests`: it
regenerates a required-mode manifest and reruns the whole `tests` umbrella
serially, so it is a slower separate leg.

`./wbuild tests` gains a cheap canary owned by `tests/ast_canary_test.w`.
`ast_canary_test` runs `bin/wv2 check --quiet --ast-retain --ast-required w.w`
on the 32-bit host, and `ast_canary_64_test` (in `tests_x64`) runs the same
check with `bin/wv2_64` for the x64 target. Each run retains the compiler's
own forest and fails on any expression fallback. `ast_audit_test` pins that
the required-mode rewrite leaves both explicit-mode steps untouched.

The serial suite is a workaround. `tools/wast_audit.w` now records why: a
nested default-manifest `bin/wexec` (for example `wexec_test`'s
`bin/wexec hello`) can rebuild `bin/wv2` in place, because wexec's
`WEXEC_LOCK_HELD` exemption assumes its parent is blocked on that one step,
which holds only at `-j 1`. The canary covers only `w.w`'s closure on two
hosts, not the language corpus, and the CI leg does not remove that race.

## Module-dependency invalidation in wbuildd (C3.4)

`tools/wbuildd.w` now decides which memoized answers an edit affects
with the module-dependency graph instead of scanning closures. The
compiler-free half of `compiler/module_dependencies.w`
(the graph type, `module_dependency_add`, `module_dependencies_invalidate`,
`module_dependencies_free`, plus new `module_graph_new`,
`module_graph_add_module` and `module_dependencies_forget`) moved to
`compiler/module_graph.w`. The daemon imports that without the compiler;
`module_dependencies_build` still fills the same type from the retained
forest. The daemon's graph has one node per file and one per memoized
answer, built from the `bin/wv2 deps` closure that pins each answer.
`module_dependencies_invalidate` over the edited paths gives the answers
to drop, and `bin/wbuildd affected PATH...` prints them.

Resolution-changing events no longer drop the whole memo:

- A `.w` file created, deleted or renamed drops the answers that read
  that path, or its `bin/` fallback twin, which a new file shadows.
- A directory event drops the answers that read a path under it.
- A C header, a rebuilt `bin/wv2` or `bin/wtest`, and an inotify
  overflow still drop the whole memo.

Dropped answers are re-checked in the background. The run is bounded,
most recently used first, and discarded if an edit overtakes it. So the
next query after a save is usually a memo hit. For an 18-root working
set, saving `compiler/tokenizer.w` by rename used to drop all 36 memo
entries and cost 6.1 s to re-answer every root. It now drops 4 entries,
re-checks 2 roots in the background, and every root is warm again in
1.7 s ([wbuildd.md](wbuildd.md) §8 has the full table). That
change also fixed a `wbuildd_test` flake: under a parallel
`./wbuild tests`, another test's scratch `.w` file under `bin/`
cleared the memo between the test's "before" query and its edit.

What it does not claim:

- The graph is file-level and comes from `deps` output, not from the
  retained binding/type edges. A check's output depends on every file
  it read, so file-level is the sound granularity for re-checking.
- A re-check is a full compile of that root; no machine code is
  reused. Per-definition relocation, which build-level reuse needs, is
  designed in
  [incremental_compilation.md](incremental_compilation.md)
  ("Per-definition relocation") and is not implemented.
- `wbuildd_test` and `module_dependencies_test` (plus its x64 twin)
  are the gates. **#489 remains open.**

## Emitting expressions from the retained forest (S2.1)

`--ast-emit-retained` (implies `--ast-retain` and full-expression mode)
lowers every AST expression from its retained `expression_group` instead
of from the temporary parse arena. `retained_expression_note` copies the
prepared arena into the forest as before; in this mode
`code_generator/retained_emit.w` then rebuilds every arena column and the
text/type-name arenas from that group alone, and the unchanged backend
visitor lowers the rebuilt arena. The temporary arena stays the default
emitter.

Compiling with the mode found the fields the retained copy lacked, and each
became a retained field or a resolved reference:

- types in the result, generic-signature, call-receiver and inference
  columns come from retained semantic types, with a per-node flag
  (`type_value_flags`) for the arena's value-type encoding of the last
  three (`result_is_value` already covered the first);
- symbol-table operands (`v`, `C`, `X`, `z`, `l`, `G`, `W`) resolve
  through their retained binding, and the name operand is rebuilt as the
  spelling just before the binding's record;
- argument-count, argument-type and self-assignment warnings name a symbol
  by spelling and the argument warning also borrows its record; the node
  keeps a binding for it (`name_binding`);
- message-bearing warnings use their interned message text;
- generic calls name their definition and resolve it by name, not by
  `generic_defs` index.

The adapter also compares each rebuilt field with the arena it replaces
and stops with an internal error on any difference, so a lost field cannot
hide behind an image that happens to match. `--stats` prints
`Retained-emitted expressions:` (46,866 groups for `w.w`).

Verification: `ast_retained_emit_test` compiles every source fixture of
`ast_expression_test` in both modes and compares exit status, stdout,
stderr and image bytes (x86 on the 32-bit host, x64 on the 64-bit host, one
of arm64/arm64_darwin/win64/wasm32 per fixture on alternating hosts, and a
`check --json --lint` leg), plus a REPL session with error rollback and
redefinition on both hosts. `ast_required_expression_verify` gains an
`--ast-required --ast-emit-retained` self-host fixpoint on both widths, and
it equals `bin/wv3` / `bin/wv3_64`. Outside the suite, the full matrix
(150 fixtures x six targets x both hosts, and `check --json --lint` for
x86/x64/arm64/wasm32 on both hosts) was byte-identical. Cost on `w.w` is
that of `--ast-retain --ast-required`: about 1.4 s against 0.8 s for the
default on either host under load, with the same peak RSS.

What this does not claim: the expression is still parsed and type-checked
into the temporary arena first, so every parse-time side effect (symbol
lookup, type registration, generic reservation) still happens in the
parse; the forest is only the emitter's input. Columns that overload
`value`/`symbol` with type-table indices, helper and descriptor numbers or
group-local node ids are held verbatim, as is `generic_instance` (an index
into the generic-instance queue). No `tree --json` field was added, so the
schema stays **version 2**. **#489 remains open.**

## Parse a statement, then emit it from its record (S2.2a)

Under `--ast-emit-retained`, simple statements (`pass`, `debugger`,
`break`, `continue`), expression statements and `return`/`yield` are now
parsed completely, terminator included, before any of their code is
emitted; a walk then emits them from what the parse recorded. This is the
first construct family of S2.2 and it defines the walk that the other
families extend (`code_generator/retained_emit.w`, S2.2 section).

- **The record.** `retained_walk_begin` attaches a walk record to the
  dispatcher's retained statement node (new field
  `retained_node.statement_walk`). It holds the statement's resolved
  `statement_ast` node, the retained group of its expression child
  (recorded by `retained_expression_note` at the same moment as before,
  but not lowered) and an ordered list of *phases*: the emission steps the
  streaming hooks ran during the parse (lower the expression, replay the
  root's end-of-expression warnings, coerce the value, transfer control),
  each tagged with an *emission point*, the lexer state that step ran in.
- **The walk.** `retained_emit_statement(node)` is the entry point. It runs
  the remaining phases in recorded order, switching the lexer to each
  phase's point and back to the parse's position afterwards, so
  diagnostics, constant-narrowing checks and anything else that reads the
  current token see what they saw before. The expression is lowered from
  its retained group through S2.1's adapter. A family plugs in by passing
  its own emitter to `retained_walk_begin`
  (`void emitter(retained_statement_walk*, int phase)`); phase codes are
  private to the family (family (a)'s are `ast_walk_*` in
  `compiler/statement_ast.w`, its emitter is `emit_statement_ast_walk`), so
  no shared switch has to be edited by the next families.
- **Order-sensitive parse steps.** Moving emission after the rest of the
  parse cannot change the image, but it can change the order of
  diagnostics: lexing the token after the expression can print an
  indentation or end-of-file warning (or an unterminated-literal error),
  and accepting `;` lexes the next line. The parse therefore drains the
  phases recorded so far (`retained_walk_drain`) before such a step:
  always before an explicit `;` or a missing terminator, and before the
  post-expression lex unless the raw bytes up to the next newline show it
  cannot print (`ast_statement_lex_may_print`). The second guard is
  defensive: the AST probe already declines the expressions whose lowering
  could print, so no fixture reaches it; the first one is exercised by
  `ast_retained_emit_test`.
- **Fallback.** A statement without a walk is emitted during its parse
  exactly as before: the mode is off, the expression probe declined (the
  streaming tails), or the hook was reached outside the statement
  dispatcher.

`--stats` prints `Retained-emitted statements:` and `Immediate
statements:` (every other retained statement node). For `w.w`: 29,423
walked and 35,759 immediate on the x86 host, 29,439 and 35,778 on x64;
the immediate ones are the blocks, `if`/`while`/`for`/`switch`,
declarations, `defer`, labels and the other families' statements (each
block and each control statement is itself a statement node).

The unit of deferral is one statement, not a body. Deferring a run of
statements needs two things this family does not own. The dispatcher
(`grammar/statement.w` `statement_impl`) emits a peephole barrier and a
DWARF line row (`be_notes_reset`, `debug_line_note`) at the start of every
statement, so those must become recorded phases of the enclosing body's
walk; and a statement of a family that still emits while parsing has no
hook before it at which the pending run could be drained. Both arrive with
the block walk (family b) and the dispatcher's owner (P1.5). Beyond that,
whole-body deferral moves every emitter diagnostic (the return-type
mismatch and void-return warnings in the value phase, for example) after
all of the body's parse diagnostics, which the streaming order does not
allow; those checks depend only on types and should move into the parse
before bodies are deferred.

Verification: `ast_retained_emit_test` now also compiles a tracked fixture
(`tests/ast_statement_walk_fixture.w`: `;`-separated statements, return
and yield warnings, defers, a generator, a generic body, loop and switch
branches) and twelve generated sources that are not valid W (space
indentation after a statement, `;` before a space-indented line, a missing
terminator after a value warning, no final newline, an unterminated
literal, `break`/`continue`/`yield` errors) on the same legs, and checks
the new counters. Removing the terminator drain makes it fail. `verify`,
`verify_x64`, `ast_expression_test`, `ast_required_expression_verify`
(whose `--ast-emit-retained` fixpoint equals `bin/wv3`/`bin/wv3_64`) and
`tests` pass. Cost on `w.w` is unchanged within noise: about 1.6 s with
`--ast-required --ast-emit-retained` on either host, against 0.9 s for
`--ast-required`.

What this does not claim: no function body is parsed whole before
emission yet; the walk record borrows the hook's `statement_ast` node and
expression arena, which is sound only because the family walks before its
hook returns (a cross-statement walk must own copies); exit phases still
read the live `defer`/`for`-cleanup lists and `stack_pos` (families (c)
and (d) must record those as facts once runs span statements); and the
parse-time side effects of the expression itself are unchanged from
S2.1. No `tree --json` field was added; the schema stays **version 2**.

## #558's conversion warnings in the AST front end

PR #558 added the unsafe-conversion warnings (`grammar/type_check.w`)
and the `[call-int]` / `[void-pointer-conversion]` lint rules through
hooks in the streaming expression grammar only, so `--ast-required`
dropped the narrowing and enum warnings, rejected `==`/`!=` on struct
values, and lost both lint rules, and `ast_expression_suite` failed on
`unsafe_conversion_warning_fixture` and `type_check_lint_test`.

The AST front end now records an `ast_warning` event (high 8) wherever
the streaming grammar runs `check_value_conversion`: call arguments
(direct, through a function pointer, method and UFCS receivers, explicit
and inferred generic calls), assignment, map stores and compound map
stores, map keys and `get`/`add`/`remove` arguments, set `add`, list
methods and literals, and parallel assignment; initialization, `return`
and `yield` check after emission as before. Only conversions a check can
report are recorded (`conversion_check_relevant`). The streaming checks
trust a literal only while it is the last token parsed; the event keeps
the converted node, `ast_expression_literal_before` applies the same
token rule to the tree's token records, and the replay sets
`const_note_override` with the literal's decoded value and position.
`==`/`!=` on two struct lvalues is accepted and lowered like
`equality_op`, with its warning as a high-3 event at the operator;
calls through a non-function value record a high-9 `[call-int]` event
after the `(`. The #558 messages also have rows W0400-W0407 in the
diagnostic code table, so neither front end reports them as W0000.

Diagnostics (human and `check --json --lint`) are byte-identical
between the default streaming grammar, `--ast-full-expressions` and
`--ast-required` over every tracked `.w` file outside the compiler
tree that compiles in required mode (1,374 files plus `w.w`), on the
x86 and x64 targets, and the produced binaries of the new fixtures are
identical. The high-8 context string is interned in the retained forest
and compared by text in `retained_emit.w`, so `--ast-emit-retained`
reports the same diagnostics. What it does not claim: a struct
compared with a non-struct operand, or a struct-returning call, still
falls back to the streaming grammar (and fails `--ast-required`).
**#489 remains open.**

## Declarations, labels, raw_asm and defer from their record (S2.2d)

Under `--ast-emit-retained`, local declarations (typed and `:=`), `goto`,
labels, `raw_asm(...)` and `defer` statements are now parsed completely
before any of their code is emitted, and family (a)'s walk
(`retained_emit_statement`) emits them from what the parse recorded. The
emitter is `emit_declaration_ast_walk` (`code_generator/statement_ast.w`),
with private phase codes `ast_walk_declaration_*`, `ast_walk_goto`,
`ast_walk_raw` and `ast_walk_defer_register`; a declaration's initializer
reuses family (a)'s expression and expression-end phases.

The parse records the facts and the walk reproduces each side effect at
the point the streaming parse ran it:

- **Local slot assignment.** The record holds the local's declared type,
  its name (`:=`) and the initializer's promoted type. The slot is the
  stack depth when the local's storage is pushed, which only emission
  knows, so the bind phase (`emit_declaration_ast_bind`) assigns it: it
  fills the typed local's slot (the type-name parse already declared the
  symbol) or declares the inferred local after its initializer, then the
  storage phase pushes it. `inferred_storage_type`'s errors therefore stay
  after the initializer's warnings. A declaration in a `for` header is not
  its own statement and keeps emitting during its parse.
- **Defer registration.** The parse checks the form and records the span
  (path, offset, line, column); the walk registers it
  (`defer_record_span`, `grammar/defer.w`) after the rest of the line is
  skipped, so registration order is statement order as before. The
  exit-time replay (`ast_deferred_expression`) is unchanged: it is a
  reparse inside an exit phase or block end, not a statement of its own.
- **Labels.** The label index and the stack depth at the `goto` or label
  are parse facts; a label's duplicate check now reads a parse-side flag
  (`goto_label_defined`) instead of the emitted label position, so it no
  longer depends on when the label is emitted. Pending forward gotos and
  label positions stay emitter state, resolved by
  `emit_goto_target`/`emit_label_target` in walk order.
- **raw_asm.** The decoded bytes live in the token buffer, which the rest
  of the parse overwrites, so the record owns a copy until the walk emits
  it (before a missing `)` is reported).

`--stats` on `w.w` (compile, `--ast-required --ast-emit-retained`, this
branch's source): 36,726 walked and 28,817 immediate statements on the
x86 host, against 29,579 and 35,964 before; 36,746 and 28,825 on x64.
`w.w` has no goto, label, raw_asm or defer statement; its 7,147 local
declarations account for the difference (the 12 others are `for`
headers). The remaining immediate statements are blocks,
`if`/`while`/`for`/`switch` and function-level nodes (families b, c, e).

Verification: `ast_retained_emit_test` compiles a tracked fixture
(`tests/ast_declaration_walk_fixture.w`: typed, inferred, struct, array and
array-field locals, `;`-separated declarations, initialization warnings,
forward and backward gotos across declarations and blocks, defers,
raw_asm) and fifteen generated invalid sources (initialization warnings
around indentation, terminator and end-of-file diagnostics, bind-phase and
parse-phase declaration errors, duplicate and undefined labels, raw_asm
without `)`, defers whose skipped line prints) on the same legs as S2.2a,
and checks that a program with one statement of each kind walks all of
them and adds no immediate statement. `verify`, `verify_x64`,
`ast_expression_test`, `ast_required_expression_verify` (whose
`--ast-emit-retained` fixpoint equals `bin/wv3`/`bin/wv3_64`) and `tests`
pass.

What this does not claim: the unit is still one statement, so the bind
phase reads the live `stack_pos` and `last_declared_symbol`, and an
inferred local is declared by the walk; a body-level walk must declare it
at parse time (its type is known once the initializer is prepared) so later
statements can resolve it. Gotos and labels are emitted at the end of
their statement exactly as before; forward-goto resolution remains emitter
state. No `tree --json` field was added; the schema stays **version 2**.

## For-loop and switch headers walked from their records (S2.2c)

Under `--ast-emit-retained`, `for` loops over a range or a container and
`switch` statements are now walked like S2.2a's statements: their
headers are parsed before their code is emitted, the emission steps are
recorded as phases of the statement's walk, and
`retained_emit_statement` emits them. Each family keeps its own emitter
and phase codes: `emit_loop_ast_walk` with `loop_walk_*`
(`code_generator/loop_ast.w`) and `emit_switch_ast_walk` with
`switch_walk_*` (`code_generator/statement_ast.w`). When no walk is open
(the mode is off, or the hook is reached outside the dispatcher) the
grammar runs the same steps in place through the same phase functions
(`emit_loop_ast_phase`, `emit_switch_ast_phase`), so the streaming order
is the walk's order by construction.

- **What one walk covers.** A range loop's walk records each argument's
  lowering, end-of-root warnings and spill, then the loop scaffold; a
  switch's records the selector, the break region, and each clause's
  region, case values, duplicate-value check, comparisons and branches.
  The steps after a body (the increment and back edge, the cursor
  advance and container release, `loop_leave`, the switch's
  fall-through region and the restore of the enclosing break context)
  are the walk's last phases, recorded when the body ends and emitted
  with the statement. The enclosing break/continue context a header sets
  up is a phase too (`switch_walk_enter`, `switch_walk_leave`), recorded
  from facts kept in the record, not read from parse state at emission.
- **What may not move past a pending phase**, so the walk is drained
  first (`ast_walk_settle`, `ast_walk_lex` in `grammar/ast_statement.w`):
  a parse step that may print (every header error, and any lex that
  `ast_walk_lex_may_print` cannot rule out: a following line indented
  with spaces, a literal, a comment opener, non-ASCII bytes, or no
  newline left in the read window); the next header value's
  preparation, which commits types, symbols, literal notes and its own
  replayed diagnostics, so header values are walked one at a time; and
  every body, whose parse reads the stack depth, the loop and switch
  slots and the break region the header's phases set up.
- **The for-in iterable** starts its loop's walk in
  `ast_iteration_value`, but the for rule (`grammar/for_statement.w`,
  owned by no S2.2 family) checks the iterable's type and resolves the
  iterator protocol between the iterable and `ast_for_cursor_loop`, and
  those checks print and intern generic instances; so the iterable is
  walked before it returns, and the cursor loop continues the same walk
  (`ast_loop_iterable_walk`). The loop variable's declaration and its
  zero store, emitted by the for rule before `in`, are also emitted
  during the parse.

`--stats` on `w.w` (`--ast-required --ast-emit-retained`) now reports
37,155 retained-emitted and 28,613 immediate statements on the x86 host
(36,829 and 28,939 on the S2.2d base), and 37,179 and 28,624 on x64
(36,853 and 28,950): the compiler's range loops, cursor loops and
switches (326 statements) are all walked, so no immediate statement on
`w.w` belongs to this family.

Verification: `ast_retained_emit_test` compiles a tracked fixture
(`tests/ast_loop_switch_walk_fixture.w`: range loops with one to three
arguments and multi-line headers, list, map, set, slice, string,
generator, cursor-protocol and `enumerate` loops, switches on ints,
enums, strings and `char*`, multi-value cases, duplicate-value and
case-type warnings, `break`/`continue` across nested switches and loops)
and ten generated invalid sources on the same legs; each pins a header
phase that prints (a selector error, a duplicate case value, a case type
mismatch) against a later parse step that prints too. Disabling the
drains makes four of them fail. `verify`, `verify_x64`,
`ast_expression_test`, `ast_required_expression_verify` (whose
`--ast-emit-retained` fixpoint equals `bin/wv3`/`bin/wv3_64`),
`parser_generator_w_test` and `tests` pass, and the 518 tracked `.w`
files outside the compiler tree that contain a `for` or `switch`
compile to the same exit status, output and image with and without the
mode on x86 and x64, apart from the files whose default compile already
crashes (library files without `main`). Cost, on a shared and loaded 4-core
box (median of 5): the `--ast-required --ast-emit-retained` compile of
`w.w` measured 1.72-1.80 s before and 1.88-1.97 s after on x86 (CPU time
1.59 s and 1.58 s), and 1.81-1.97 s and 1.95-1.98 s on x64 (CPU 1.50 s
and 1.69 s); the default compile stays within noise (x86 0.96 s and
0.86-0.88 s, x64 0.73-0.79 s and 0.80-0.84 s).

What this does not claim: a header is walked as a whole only between
its values; each value is lowered before the next one is prepared, and
everything is drained before each body, so a loop or switch is still
not parsed whole before its code is emitted. Lifting that needs the
preparation of an expression to stop committing types and literal notes
(a forward reference to a later lowering), and the body walk of family
(b). The record borrows the hook's nodes and expression arena, which is
sound because the walk ends before the hook returns (the iterable's
record is drained before `ast_iteration_value` returns). No `tree
--json` field was added; the schema stays **version 2**.

## Blocks, if/elif/else and while from their records (S2.2b)

Under `--ast-emit-retained`, blocks (`{ }` and `:`), `if`/`elif`/`else`
chains and `while` loops are now statement walks too, on S2.2a's
mechanism (`code_generator/retained_emit.w`). Each of them is a
compound statement, so its *header* is the unit: the opening token, or
the keyword and its condition, is parsed completely before the header's
code is emitted, the body's statements are walked by their own families
as they are reached, and the steps after a body are phases emitted once
the body has been parsed.

- **Emitters and phases.** `emit_guard_ast_walk` (if chains and while
  loops, with their conditions) and `emit_block_ast_walk` in
  `code_generator/statement_ast.w`, with private phase codes 101-110.
  An if/while walk keeps a small frame-owned record,
  `control_ast_walk` (the arm's if node or the while node, and the
  `loop_enter` context the begin phase returns), found by walk id; a
  block's walk needs only its `statement_ast`.
- **Conditions.** `ast_statement_guard` records into the enclosing
  if/while walk, handed over in `control_ast_guard_pending` by the
  statement that calls `statement_guard` (whose signature is shared with
  the streaming grammar and unchanged). It reuses S2.2a's
  `ast_statement_walk_expression`, so the condition is lowered from its
  retained group after the token that follows it is lexed, unless that
  lex might print. The region the branch targets is opened by the
  header's begin phase, so the branch phase reads it when it is emitted.
  The guard drains before it returns: the lowering reads the lint
  condition state and `condition_context` it then resets, and
  `statement_guard`'s constant-true check reads the `true` tokens the
  lowering replays.
- **Chains.** An `if`/`elif`/`else` chain is one statement node and one
  walk. Each arm swaps its own node into the record and drains before it
  returns (its node lives in its frame); the then-arm's exit phase stays
  pending across the `elif`/`else` lex (it cannot print), and an `elif`
  arm drains it before swapping its node in.
- **Blocks.** The scope opening (`stack_pos`, the DWARF lexical block,
  the `-v` trace) is a phase recorded after the token after `{`/`:` is
  lexed. At the end, a function body's deferred statements are emitted
  and drained before the unused-local lint (both may print), the symbol
  table is truncated in the parse, and the scope end and unwind are the
  last phase.
- **Fallback.** Without a walk (the mode is off, or no retained
  statement node owns the statement) each construct is emitted during
  its parse exactly as before. A condition the AST probe declines drains
  the header's phases and is parsed by the streaming grammar.

`--stats` on `w.w` (x86 and x64 hosts alike): 58,109 statements walked
and 7,473 immediate on S2.2a's base, from 29,516 and 35,896; on top of
S2.2d, 65,381 walked and 325 immediate (the `for` and `switch`
statements); with S2.2c too, **zero immediate statements**: 65,938
walked on the x86 host and 65,973 for the x64 target.

Verification: `ast_retained_emit_test` compiles a new tracked fixture,
`tests/ast_control_walk_fixture.w` (every `elif` shape, brace and
same-line arms, empty blocks, conditions with bool-bitwise warnings and
assignment-in-condition lint, constant-true loops, a generic body,
unreachable code and an unused local), and eleven generated sources (a
condition warning before a space-indented or unterminated body line, an
`elif` on a space-indented line, the source ending inside or right
after a block, conditions the probe declines, and a deferred
statement's warnings before the unused-local lint) on the same legs as
S2.2a's, plus an if/while REPL session with failing conditions. Removing
the drain before the unused-local lint makes it fail; an `elif` arm that
did not drain the enclosing arm's exit crashes on `w.w`. The `-v -v`
trace is identical to `--ast-full-expressions`. `verify`, `verify_x64`,
`ast_expression_test`, `ast_required_expression_verify` and `tests` pass.

What this does not claim: no body is parsed whole before emission (the
unit is still one statement or header, and every body is preceded by a
drain); the condition's lowering is drained before the following lex
whenever S2.2a's `ast_statement_lex_may_print` cannot rule out a lexer
diagnostic, which happens when the read window ends near the condition
(about 10 of the 2,100 roots of the fixture's compile, mostly near the
end of a file); `while_statement.w`'s `statement_guard` and
`loop_enter` are unchanged, so the loop's parse state (`loop_depth`,
`break_in_switch`) is still set by the begin phase rather than recorded
as a fact, which is sound only because the header is drained before
the body. No `tree --json` field was added; the schema stays
**version 2**.

## Launch and gpu for statements walked after their parse (S2.2e)

Family (e) of S2.2 covers function, script, generator and kernel
boundaries, globals, thread-locals, linkage declarations and GPU
launches. Of these, only `launch` and `gpu for` are statements of the
dispatcher (retained statement nodes); under `--ast-emit-retained` both
are now walked through `retained_emit_statement` with their own emitter
(`emit_gpu_walk_ast`, `code_generator/gpu_ast.w`; private
`ast_gpu_walk_*` phase codes in `compiler/gpu_ast.w`).

- **launch.** The kernel name, both dimensions, the argument list and the
  arity check are parsed before the last value's lowering, coercion and
  slot push and the runtime call are emitted. Each header value records
  the phases family (a) records for an expression child (lower from the
  retained group, end-of-root warnings at the token after it) plus its
  own value step (`check_call_argument`, coercion, slot push).
- **gpu for.** The range operands and the host-side tail (capture pushes
  and the `__w_gpu_launch` call) are walked. The outlined kernel's
  prologue, loop-variable slot and guard are emitted before the body
  parses, because the body's parse reads what they set (device mode,
  `device_symbol_base`, the capture table, `in_gpu_for_body`, the slot the
  loop variable is declared at); its epilogue is emitted when the body
  ends, before the host side resolves captures in host mode. Capture
  bindings are resolved during the parse and kept on the node.
- **Order-sensitive parse steps.** The header values share one
  `statement_ast`/`expression_ast` pair in the statement's frame, so at
  most one value's phases are pending. The parse drains them before a
  value is prepared (preparation replays warnings and decodes literals),
  before every parse error (missing `[`/`,`/`]`/`)`, arity, a third range
  operand, an unresolvable capture), and before lexing a token unless the
  raw bytes of the rest of the line rule out a lexer diagnostic
  (`ast_gpu_lex_may_print`). Without these drains the new tests fail on
  both diagnostics and images.

Function, generator, script and kernel bodies, globals, thread-locals,
enum values and extern declarations are not statement nodes, so they are
outside the walk's coverage counter, and none has a parse step between
its boundary emission and the body (or the end of the declaration) that
deferral could move: the boundary emitters (`emit_function_begin_ast`,
`emit_function_end_ast`, `emit_global_declaration_ast`,
`emit_thread_local_ast`, `emit_linkage_ast`) are unchanged. A global's
storage is still bound before its constant initializer parses, and a
kernel's parameters still take their slots as they parse (the slot is
the declared local's offset).

`w.w` has no GPU statements, so this family does not change its counters
(66,125 walked and 0 immediate on x86, 66,160 and 0 on x64, with S2.2b-d
in). The 8 launch and gpu for statements of
`tests/ast_gpu_walk_fixture.w` were the only immediate statements left
there (4,125 walked / 8 immediate before, 4,133 / 0 after). Compile time
of `w.w` is unchanged within this box's noise in either mode.
Verification: `ast_retained_emit_test` adds that fixture and
eleven generated sources (argument warnings followed by an indentation
warning, a continuation line, a warning printed while the next argument
is prepared, an arity error, a missing `)`, no final newline, a comment
or unterminated literal after an argument, a third range operand, a
space-indented line after a gpu for body), compiled in both modes on its
x64 legs with identical images and diagnostics; `verify`, `verify_x64`,
`ast_expression_test`, `ast_required_expression_verify`, the compile-only
`cuda_*`/`gpu_*` targets and `tests` pass.

What this does not claim: no function body is parsed whole before
emission; the gpu for kernel's prologue and epilogue are walked phases
that are drained immediately, not deferred; the coverage counter does
not count function, global or linkage boundaries at all. The tree
schema is unchanged (**version 2**).

## Generic instantiation and deferred statements from the retained forest (S2.3)

Under `--ast-emit-retained`, no generic instantiation and no deferred
statement replay reopens its source file and seeks to the recorded span
any more. Two mechanisms replace the seek:

- **Retained type trees.** A generic struct's field list is captured as
  unbound type trees (`generic_field_ast`, the `generic_type_ast` shapes of
  tasks 38/45/46) while its definition is skipped; a generic function's
  header already was (`generic_signature_ast`). A struct instantiation, an
  instantiation signature (`generic_inst_signature`) and the placeholder
  inference shapes (`generic_infer_shapes`) are now built by walking those
  trees under the substitution (`generic_tree_resolve`, grammar/generic.w),
  making exactly the type-table calls `type_name()` makes for the same
  tokens in the same order, so type indices and images stay identical. A
  side-effect-free check (`generic_tree_valid`) runs first and declines any
  tree whose re-parse would report an error or read the tokens differently
  (unknown names, wrong arity, list/map storage rules, 64-bit types on x86,
  a bound parameter applied to arguments, a generic struct's bare name as a
  slice element), and a field list or header whose lexing printed anything
  is not captured; those are re-parsed, so the diagnostic is the
  re-parse's. Fixed-size arrays, `const`, `gpu` and alias-qualified types
  are not captured shapes and are re-parsed too.
- **Retained source bytes.** What must still be parsed again - every
  function body, whose meaning depends on the type arguments, and every
  deferred statement, whose names bind at each exit - is re-lexed from the
  retained source version: the bytes `retained_source_byte` recorded while
  the file was first read (code_generator/retained_emit.w, S2.3 section).
  The re-parse gets a descriptor whose getchar window is a private copy of
  those bytes over file offsets [0, length), so every absolute
  `getchar_seek` inside it (diagnostic context lines, preflight rewinds,
  walk drains) stays in memory. The descriptor is `/dev/null` when a token
  the first read consumed follows the span (or the span has no
  expression), so no expression preflight can run into the window's end;
  a body or deferred statement that ends its file gets the file's own
  descriptor positioned at the end of the retained bytes, because the
  preflight's refill (`ast_expression_refill`) compacts the window there
  and getchar then re-reads the prefix from the descriptor. No byte of the
  span is read from the file in either case. A source version that was
  replaced or rolled back, or a descriptor beyond getchar's table, falls
  back to the old file re-parse.

`--stats` prints `Generic instantiation source seeks:` and `Deferred
statement source seeks:` in every mode, and under `--ast-emit-retained`
also `Generic types from retained trees:`, `Retained-source reparses:` and
`Retained-source reparses positioned at the file's end:`. For `w.w` the
default `check` reports 5 generic source seeks (2 signatures and 3 bodies
from `lib/container.w`); `check --ast-required --ast-emit-retained` reports
**0 and 0**, with 2 signatures from trees and 3 bodies from retained bytes
(one, `list_remove_at`, ends its file), identically on the x86 and x64
hosts. A compile of `w.w` (not `check`, which also instantiates unused
generics once) has 4 seeks by default and 0 in the mode.

Verification: `ast_generic_retained_test` compiles a tracked fixture
(`tests/ast_generic_retained_fixture.w` and its helper: recursive,
container, slice, pointer and nested-application fields, a fixed-array and
a by-value-list-element struct that are re-parsed, explicit, inferred and
placeholder-inferred calls, a generic-struct return, defers in plain and
generic functions, generics from another file) and 18 generated sources
(each declined shape with its error, lexer warnings in a field list,
errors and warnings inside re-lexed bodies and defers with their context
lines, bodies and defers that end their file with and without a final
newline) in the default mode and with `--ast-emit-retained` on the x86
target of the 32-bit host and the x64 target of the 64-bit host, requiring
identical status, output, diagnostics and image; it runs the fixture's
binaries and pins the `--stats` counters, including 0 seeks for `w.w` in
both `check` and compile. Outside the suite, 691 tracked `.w` files that
mention generics or `defer` compiled with `--ast-emit-retained` by this
branch and by its base gave identical status, output and image on both
hosts (346 x86 / 365 x64 of them exercise the new paths), apart from the
six library files whose compile already crashes in both, and none of them
reports a source seek. `verify`, `verify_x64`, the `generics_*`, `defer_*`
and `operator_overload_*` targets, `ast_retained_emit_test` and `tests`
pass.

What this does not claim: function bodies and deferred statements are
still re-parsed (re-lexed from memory), not instantiated from a retained
tree. A body's types, overloads, method and generic resolution all depend
on the type arguments and are decided during the parse, and S2.2 defers
emission one statement at a time, so no type-independent body tree exists
to walk under a substitution; a deferred statement must bind its names at
each exit, so a tree parsed at registration cannot stand in for it.
`defhash` still hashes tokens from the file (a cache key, not an emitter).
The operator-overload parameter pre-scan, the declaration lookaheads
(`generic_declaration_scan_generic_return`, `generic_declaration_scan_repl`)
and the lazy runtime helpers' backpatch chains are unchanged: the first two
are lookahead rewinds within the file being parsed, and the last never
re-read source. The default (streaming) compile and `-v` traces keep the
file re-parse. No `tree --json` field was added; the schema stays
**version 2**. **#489 remains open.**

## REPL and wdbg on the retained path (S2.4)

The in-process compilers now take the retained-AST modes exactly as a
compile does. `repl.w` and `wdbg` read `--ast-expressions`,
`--ast-full-expressions`, `--ast-retain`, `--ast-required` and
`--ast-emit-retained` through `repl_ast_options` (`repl/core.w`), which
applies each present flag with the driver's own `link_option`, so
`--ast-emit-retained` implies the retained forest and full-expression mode
here too. A flag only raises a mode, so a default that S2.5 sets in
`compiler/compiler.w` reaches both front ends without another edit. Before
this, both front ends silently ignored `--ast-required` and
`--ast-emit-retained`; the REPL legs that S2.1 and S2.2b added to
`ast_retained_emit_test` therefore compared `--ast-full-expressions` with
itself, and now compare it with real retained lowering. wdbg's attach mode
forwards the active modes (`--ast-emit-retained`, `--ast-required`) to the
recompile that rebuilds its symbol tables.

- **Rollback.** An entry that fails in the middle of a walked statement
  leaves that statement's walk record open; its node is retracted by the
  entry's rollback. `repl_state_restore` now returns such records to the
  walk pools (`retained_walk_release`) as part of the rollback instead of
  at the next walked statement, so the pools are empty between entries,
  after errors and runtime faults alike. Nothing else needed to change:
  the checkpoint already covered the retained suffix, and walk records
  never outlive the statement that opened them.
- **Incremental sessions** (`repl/incremental.w`). `--ast-emit-retained`
  is part of a session's mode key. An unchanged prefix is no longer only
  the run of byte-equal sources: a definition whose bytes changed keeps
  its compiled function (and its suffix) when its retained tree is
  unchanged. A body is not parsed without emitting it, so the new tree
  comes from a probe: when the two sources differ only in `#` comments and
  trailing blanks, the new source compiles once at the end of the session
  with standard error muted, its retained nodes and bindings are compared
  with the kept compile's (kinds, operands, literals and arenas verbatim;
  semantic types structurally; nodes, bindings and symbol-table offsets of
  the definition's own compile by position; every location by line and
  column, an extent that ends in trailing blanks or a comment counting as
  ending at the line's code), and the probe is rolled back. A probe that
  fails, warns differently or differs anywhere falls back to recompiling
  the suffix, which prints its own diagnostics once. The admission rules
  did not change. `incremental_result` gains `tree_reused` and
  `tree_probed`.

Verification: `repl_retained_emit_test` replays every stdin script of
`repl_test` (87) and `debug_test` (71 for `bin/wdbg`, 69 for
`bin/wdbg64`) through the default compile and through
`--ast-emit-retained` on both widths and requires equal status, stdout and
stderr. Pids, addresses, timings, the `:symbols` pointer column (see
below) and fault stack traces (which list stale stack words) are
normalized first; a difference is retried twice, and a script whose
default output differs between two runs is skipped and counted (3 or 4 of
174 REPL runs, 4 of 140 wdbg runs). It also runs the REPL recovery scripts of
`ast_expression_test` and `ast_retained_emit_test` plus one with errors
inside walked function bodies, a fault inside a walked loop, `for`,
`switch` and `defer` entries, on all three front-end modes.
`ast_expression_test`'s REPL recovery and debugger evaluation legs run
`--ast-emit-retained` as a third AST mode. `incremental_compilation_test`
runs its suffix scenario in both lowering modes and checks that the walk
pool is empty right after a failed update, and adds tree-reuse scenarios
(comment and trailing-blank edits keep code, symbols and nodes
byte-for-byte; a moved line or a code edit recompiles; a probe whose
compile warns is discarded and the warning is printed once; the
streaming mode never probes).

Measured on this 4-core box under load (medians):

| | default | `--ast-full-expressions` | `--ast-emit-retained` |
| --- | --- | --- | --- |
| REPL startup and `:quit`, x86 | 43 ms | 52 ms | 124 ms |
| REPL startup and `:quit`, x64 | 56 ms | 48 ms | 117 ms |

The difference is retaining the preloaded library (`lib.lib`,
`lib.assert`, the container runtime) in the forest; entries themselves
cost the same within noise. An incremental session of 100 functions,
editing the first one (x86, `--ast-emit-retained`): an unchanged update
takes 5-8 ms (admission), a comment edit 11-14 ms (one probe, everything
kept), a code edit 61-67 ms (all 100 recompile, as a comment edit did
before).

What this does not claim: the REPL and wdbg still default to the
streaming compile until S2.5 flips the default; the bare-expression and
persistent-variable items of a REPL entry (`repl_entry_item`) compile
through `expression()` outside the statement dispatcher, so they lower
from the retained group but are not walked statements. Tree reuse needs
a probe compile because bodies are deferred one statement at a time, not
parsed whole; it only reuses a definition whose positions are unchanged,
so a comment line added or removed is still an edit, and its probe can
mark earlier functions as used (lint state). The `:symbols` dump's
`pointer (n)` column differs between the modes for identifiers referenced
before their declaration (for example `SYS_CREAT` and `__w_list` in the
preloaded runtime): it records the global `pointer_indirection` at the
placeholder's creation, a field nothing reads back. The tree schema is
unchanged (**version 2**).

## Multi-error checking without fork (C3.1)

`check --all-errors` no longer forks. Every declaration and statement is
still an analysis boundary (`analysis_run`, `compiler/analysis.w`), but
the boundary now records the parse state in process
(`compiler/analysis_state.w`) and arms `error()` to jump back to it with
the native `repl_setjmp`/`repl_longjmp` stubs, through the existing
`analysis_probe_error_status` hook in `error()`. After an error the
boundary restores that state, returns the lexer to the failed item's
first token, skips to the next sibling with `analysis_skip` as before,
and the parse continues. Boundaries nest, so the innermost failing
statement is the unit of recovery and the enclosing function, loop or
block completes normally.

- **What is restored.** What later parsing reads: the lexer (position,
  token text and buffer, file and filename; a generic reparse's reopened
  file is closed), the retained forest (`retained_rollback`, and the
  failed statement's `--ast-emit-retained` walk record is released so
  the enclosing walk can record its next phase), the stack depth, the
  loop/switch/defer/for-cleanup state, the control-region stack, the
  DWARF block stack, the statement and expression nesting guards,
  the device, generator and bounds modes, the generic substitution
  block, and the parse-context flags. A failed statement reports
  `flow_terminates`, so a function whose final statement failed does not
  get a follow-on missing-return warning.
- **What is not restored, on purpose.** No executable is written in
  check mode, so the code a failed item emitted is simply abandoned and
  the code buffer is not rewound (forward call chains may thread through
  it). The symbol and type tables are not rolled back: a binding the
  failed item had made stays visible ("poisoned symbols",
  `compiler/diagnostics.w`). A typed local whose initializer failed, a
  function whose parameter type or body failed and a struct whose field
  failed therefore no longer produce a "Cannot find symbol" at every
  later use, which the forked checker did, because it discarded the
  whole failed probe.
- **Diagnostics.** Each error is reported once, where the parse meets
  it; warnings are reported once, as the parse meets them, including the
  warnings of a function that also has errors (the forked checker
  suppressed every warning of a probe that later failed). The skip
  re-reads the failed item's tokens with lexer warnings muted up to the
  error, so they are not repeated. An error at end of input (an
  unterminated literal, a missing block end) is final and reported
  once. Two skip fixes ride along: an `else`/`elif` continues a failed
  statement only when that statement is an `if` at the same
  indentation, so a failed `elif x: return y` arm or a failed nested if
  no longer swallows the enclosing chain's arms. The 100-error limit is
  a plain counter (`stopping after 100 semantic errors`, unchanged).
- **Hosts.** No `fork`, no pipe, no `seek` of the kernel offset and no
  wait status: the Windows restriction is gone, and the only host
  without recovery is wasm (no `longjmp`), which `check` now rejects
  with its own message. arm64 Linux was spot-checked under qemu.
  `W0388` ("requires seekable source files") no longer fires; its code
  row stays.

Cost of `w.w` (no errors, so every boundary is entered and none
fails), on the shared, loaded 4-core box, median of five:

| `bin/wv2 check --quiet ... w.w` | x86 host | x64 host |
| --- | --- | --- |
| `check` | 0.80 s | 0.61 s |
| `check --all-errors`, forked (before) | 46.6-102 s (load-dependent, 2-3 runs) | — |
| `check --all-errors`, in process (after) | 0.79 s | 0.66 s |

On a file with errors (`tests/wbuildd_test.w`, 598 lines, with three
injected mistakes) the in-process checker takes 0.14 s and reports 20
errors (one of the mistakes is an unknown type, whose variable's 17 uses
are follow-ons); the forked one took 3.5 s and stopped at its 100-error
limit, because discarding the failed functions made every call to
them and every use of their locals an error. `check` stops at the first
error in 0.10 s.

Verification: `analysis_errors_test` and `analysis_errors_64_test` keep
their eight cases and add five (bindings that stay visible, warnings
beside errors with no missing-return follow-on, the enclosing `elif`/
`else` arms, an unterminated literal reported once, and recovery under
`--ast-required --ast-emit-retained` where the failed if is its block's
last statement; without the walk release that case trips
`retained_walk_phase`'s assertion). A mutation run over 620 random picks
of clean `tests/*.w` files (1,824 mutants, three per file) (an inserted call to a missing
function, a failing inferred declaration, an invalid assignment, a
renamed identifier), in the default, `--ast-required`, `--ast-retain
--ast-required` and `--ast-required --ast-emit-retained` modes and on
the x64 host and target (9,120 checks, plus 128 mutants of the GPU
fixtures on the x64 target with and without `--ast-emit-retained`),
found no crash, hang or stderr output, and every inserted error was
reported except those inside generic bodies or inside the body of a
statement whose own header was mutated. Against the forked checker on
297 mutants, the error sets differ only by the
forked checker's follow-ons (discarded declarations, and repeated
"unterminated string literal" reports from its skip) and by errors
those follow-ons pushed past its 100-error limit. `verify`,
`verify_x64`, `warning_test`, the `type_system_*_test` targets,
`lint_test`, `ast_diagnostic_codes_test` and `tests` pass.

What this does not claim: no function body is parsed whole before
emission (the unit is still S2.2's one statement), so recovery is
around the production parser, not a walk of a failed tree; a binding
the failed item never made is still missing (an inferred `name := ...`
whose initializer failed, a declaration whose type name is unknown,
the variable of a generic struct whose instantiation failed), and
there is no error type, so a poisoned binding with a wrong or partial
type can still produce type diagnostics at its uses; a statement whose
header fails is skipped with its body, so errors inside that body are
not reported; generic bodies and the on-demand runtimes are still only
checked when no earlier error was recorded (`compiler/compiler.w`
returns before instantiating them); a deferred statement that fails is
reported at each exit that replays it; and an invalid UTF-8 identifier
mid-file is still reported twice (once by the parse, once by the skip
that re-reads it, which ends the check). No `tree --json` field was
added; the schema stays **version 2**.

## AST front end by default (P1.4)

`bin/wv2` now compiles through the AST front end unless told otherwise. The
reset in `compiler/compiler.w` sets `ast_expressions_mode = 2` for every
compile. `--streaming` is the opt-out; link_impl's flag pre-scan applies it so
the implicit runtime closure compiles streaming too, and it is an error next
to `--ast-full-expressions`, `--ast-audit`, `--ast-retain`, `--ast-required`
or a retaining query (the message names the conflicting flag). `--ast-required`
keeps its check and changes nothing else. `--ast-full-expressions` is
accepted and does nothing. `--ast-expressions` means grouped scalar AST only
after `--streaming`. The REPL and wdbg default to the AST path the same way
and accept `--streaming`: S2.4's `repl_ast_options` (`repl/core.w`) sets the
default, applies `--streaming` and rejects it next to an AST-only flag with
the driver's own error, and wdbg's attach recompile forwards `--streaming`,
`--ast-expressions`, `--ast-retain`/`--ast-emit-retained` and
`--ast-required` as needed. `repl_retained_emit_test`'s baseline legs pass
`--streaming`, so they still compare retained lowering with the streaming
front end; its recovery legs add the default (AST) run as the third leg.
S2.3's `ast_generic_retained_test` likewise compares `--ast-emit-retained`
with a `--streaming` baseline, the path that still seeks the source.

The gates were inverted. `verify` exercises the AST path because `bin/wv2`
and every later stage compile AST. Only the bootstrap step differs: the pinned
v0.3.0 seed still defaults to streaming, so `./w w.w -o bin/wv2` is a
streaming compile, and `bin/wv2 → wv3 → wv4 → wv5` are AST compiles. The
fixpoint holds because the two front ends emit the same bytes.
`ast_expression_verify` now compiles `w.w` with `--streaming` and with
`--streaming --ast-expressions` on both hosts, compares each against
`bin/wv3`/`bin/wv3_64` and takes each to its own fixpoint. Before rewriting,
`wast_audit required-manifest` fails if a direct compiler step still passes
`--ast-full-expressions`, or `--ast-expressions` without `--streaming`. It
treats `--streaming` steps as an explicit mode and leaves them alone. The
baselines in `ast_expression_test` (compile, query, check, REPL and wdbg
comparisons) now pass `--streaming`, so that test still compares against the
streaming front end.

Measured on the shared 4-core container, `bin/wv2 … --strict w.w`, median of
five runs, back to back on a quiet box (load average under 1). "Before" is
`origin/main` at `2f8b2e1`, compiling its own tree; "after" is this change.

| mode | x86 before | x86 after | x64 before | x64 after |
| --- | ---: | ---: | ---: | ---: |
| streaming (default before, `--streaming` after) | 0.813 s | 0.790 s | 0.692 s | 0.675 s |
| AST (`--ast-full-expressions` before, default after) | 0.902 s | 0.856 s | 0.804 s | 0.796 s |
| `--ast-required` | 0.862 s | 0.785 s | 0.832 s | 0.777 s |
| `--ast-retain --ast-required` | 1.49 s | 1.41 s | 1.48 s | 1.35 s |
| **AST default / streaming** | — | **1.08x** | — | **1.18x** |

Wall-clock noise on this box is about ±8% (the `--ast-required` and default
rows do the same work). Two earlier runs under load gave 1.12x/1.23x (before)
and 1.15x/1.25x (after) for x86/x64. Instructions retired (callgrind, one run
each) are stable: 7.55G vs 6.79G on x86 (1.11x) and 7.71G vs 6.92G on x64
(1.11x). A small program, `tests/hello.w`, takes 344M vs 294M (1.17x), which
is mostly the auto-imported runtime. Every image was byte-identical to
`bin/wv3`/`bin/wv3_64` in every mode. `w.w` compiled for x86, x64, arm64,
arm64_darwin, win64 and wasm is byte-identical between the default and
`--streaming`.

On `2f8b2e1`, `./wbuild ast_expression_suite` passed with this change: 888
targets serially, with 1,080 required-mode steps, 104 expected-failure steps
and 35 fixture groups, in 12 m 49 s. `./wbuild tests` also passed (888
targets); one `wbuildd_test` run failed under heavy load and passed on every
rerun. `verify`, `verify_x64`, `verify_arm64` (qemu) and `verify_win` (wine
9.0) passed. `verify_wasm` reaches its fixpoint under wasmtime 25 and under
`node --no-turbo-fast-api-calls`. The plain `bin/wrun wasm` fallback to Node
22.22 segfaults mid-compile. The crash is a V8 garbage collection inside WASI
`fd_read`'s fast API call (docs/projects/ai_tooling_next_steps.md); the
streaming front end does not trigger it. `verify_darwin` needs the arm64
macOS runner and was not run.

**Rebased onto `4f0efd0` (after #569, #570, #571 and #573-#576).** The two
blockers found on `df680d1` are fixed on `main`: #571 ports #558's
conversion warnings and lint rules to the AST front end, so `warning_test`
and `type_check_lint_test` pass in the default mode, and #569 fixes the
malloc growth misalignment that corrupted heap block headers. 300
`bin/wdbg64 tests/debug_fixture.w` sessions in the default mode now all
pass (it failed about 1-2% before). The Node crash in `verify_wasm` was not
the heap bug: it still happened after #569, with the same V8 stack (a
garbage collection from `uvwasi_fd_read`'s external-memory accounting
inside a fast API call). `tools/run_wasm.mjs` now turns Node's fast API
calls off with `v8.setFlagsFromString('--no-turbo-fast-api-calls')` before
it compiles the module, and `verify_wasm` reaches its fixpoint under the
Node fallback. `ast_parse_cost_test`, `ast_diagnostic_codes_test` and
`ast_integer32_test` measure a streaming baseline, so they now pass
`--streaming` for it. `--ast-emit-retained` (S2.1) is rejected next to
`--streaming` like the other AST-only flags.

On `4f0efd0` with this change, `./wbuild tests` passed (896 targets) and
`./wbuild ast_expression_suite` passed serially: 896 targets, 1,090
required-mode steps, 105 expected-failure steps and 35 fixture groups, in
17 m 56 s on a loaded box. `verify`, `verify_x64`, `verify_arm64` (qemu),
`verify_win` (wine) and `verify_wasm` (Node 22.22) passed. `w.w` compiled
for x86, x64, arm64, arm64_darwin, win64 and wasm is byte-identical between
the default and `--streaming`. `verify_darwin` needs the arm64 macOS runner
and was not run.

Timings on `49f167c` (the S2.2a base; #573-#576 change only
`--ast-emit-retained`), `bin/wv2 … --strict w.w`, eleven interleaved runs
on the shared box under load (load average 6-10); CPU is user plus system
time. Instructions are from callgrind, one run each.

| mode | x86 wall | x86 CPU | x64 wall | x64 CPU |
| --- | ---: | ---: | ---: | ---: |
| `--streaming` | 0.816 s | 0.744 s | 0.688 s | 0.654 s |
| default (AST) | 0.943 s | 0.879 s | 0.841 s | 0.807 s |
| `--ast-required` | 0.912 s | 0.861 s | 0.843 s | 0.827 s |
| `--ast-retain --ast-required` | 1.49 s | 1.37 s | 1.54 s | 1.54 s |
| **default / streaming** | **1.16x** | **1.18x** | **1.22x** | **1.23x** |

Instructions retired: 7.86G vs 7.16G on x86 (1.10x) and 7.80G vs 7.05G on
x64 (1.11x). Both hosts stay inside the plan's 1.25x checkpoint, x64 with
less margin in wall-clock time than in instructions.

What this does not claim. Emission still happens per root during parsing.
The streaming grammar is still compiled in and maintained; retiring it is
P1.5, after a release carries this change. Roots too large for the bounded
arena still fall back to streaming silently unless `--ast-required` is given.
The `--streaming` conflict error has no diagnostic code row yet (`check
--json` reports W0000). The Node workaround covers `tools/run_wasm.mjs`
only; the host-import runners under `tools/web/` keep fast API calls on.
**#489 remains open.**

After merging register allocation and PGO (#582) and asm function bodies
(#579). The register pre-scan (`compiler/regalloc_scan.w`) reads each body's
bytes from its own image of the source before the prologue,
`--profile-use`/`--profile-generate` key functions by `w defhash`, a hash of
the token stream, and `asm_function_body` runs ahead of both front ends'
body paths; none of them depends on the front end. `w.w` is byte-identical
between the default and `--streaming` on x86 and x64 with promotion on, with
`--no-regs`/`-O0`, with `--profile-use=profiles/self.wprof` (`self_x64.wprof`
on x64, and `bench.wprof` on x86) with and without `--no-regs`, and under
`--profile-generate` (image and `.wprofmap`); `--stats`' regalloc and
profile counters and `w defhash` output match too. `tests/asm_function_test.w`
is byte-identical across the default, `--streaming` and `--ast-required`
(with and without `--no-asm`/`--no-regs`), and every `asm_*_error_fixture`
gives the same output and exit status in the three modes. `profile_check`
reports 1000 of 1008 (x86) and 1045 of 1053 (x64) functions still
matching. The stale entries are functions whose source changed after the
profiles were generated: `link_option` and `link_impl`, which this change
edits, and six that #579 edited on `main` (`function_definition`,
`statement_impl`, `be_function_define` and three in `libs/asm/`). Their
hashes moved with their text, not with the front end. That is far above the
80% refresh threshold in register_allocation_pgo.md §8, so the committed
profiles were left as they are (those functions take the static heuristic
until the next `profile_refresh`).

Compile time on the merged tree, `bin/wv2 … --strict w.w`, median of nine
interleaved runs (load average under 1), and instructions retired (callgrind,
one run each, ±3% from the per-process hash seed):

| | default (AST) | `--streaming` | ratio |
| --- | ---: | ---: | ---: |
| x86 wall | 1.196 s | 1.033 s | 1.16x |
| x86 user + sys | 1.198 s | 1.032 s | 1.16x |
| x64 wall | 1.229 s | 1.088 s | 1.13x |
| x64 user + sys | 1.230 s | 1.088 s | 1.13x |
| x86 instructions | 8.92G | 8.09G | 1.10x |
| x64 instructions | 9.10G | 8.22G | 1.11x |

#582's register pre-scan and promotion add about the same cost to both
front ends, so the AST default stays inside the 1.25x checkpoint.
