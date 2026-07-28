# Golf Ergonomics

Design and decision record for the "make short programs short" batch:
script mode (implicit main), a prelude with polymorphic print and stdin
helpers, `:=` type-inferred locals, C-style ternary conditionals,
algorithm methods on the built-in `list[T]`, and the small string/math
stdlib fills. The goal is that a stdin-to-stdout puzzle program needs no
entry-point boilerplate, no imports and no manual formatting:

	s := 0
	for int x in ints(): if x % 2 == 0: s += x * x
	println(s)

## Decision: ergonomics that help golf, not golf-only features

Every feature here is ordinary language ergonomics that happens to make
programs shorter. Nothing golf-specific (one-character aliases, implicit
output) enters the core language; those could live in a prelude variant
later without touching the compiler.

The compiler stays single-pass with no AST, so each feature reuses an
established mechanism instead of inventing new machinery:

- span scan-ahead with `generic_reparse_save()` + `seek` + restore
  (grammar/generic.w) for the one-token lookaheads;
- short-circuit forward jumps with `jmp_zero_int32` / `be_branch_patch`
  (grammar/logical_and_expr.w) for the ternary;
- deferred on-demand module import with per-helper backpatch chains
  (grammar/template_string.w) for the prelude runtime;
- the REPL's "compile statements into an anonymous function" model
  (repl.w) for script mode;
- the `list_*_suffix` lowering + `__w_list_*` runtime split
  (grammar/list_builtin.w, structures/w_list.w) for the list methods.

## `name := expression` (grammar/variable_declaration.w)

The tokenizer merges `:` with a directly following `=` into one `:=`
token; a bare `:` (blocks, slices, map literals, ternary else) never has
`=` directly after it. In statement position, an identifier followed by
`:=` declares a local whose type is the initializer's: value pseudo-types
map back to their storage types (the `generic_infer_declarable` rule),
untyped constants default to `int`, bare function names and void
expressions are errors. Unlike `type name = expr` the symbol is declared
after the initializer parses, so the initializer cannot reference the
new name. The lookahead only fires when the identifier is followed by
`:`, space or tab, and rewinds with the generic reparse trick otherwise.

## Ternary `cond ? a : b` (grammar/conditional_expr.w)

A new precedence layer between assignment and `||`, right-associative
like C. The postfix `?` (wresult unwrap/propagate) binds tighter and is
only claimed by postfix_expr when the operand actually is a
`wresult[...]*`, so both meanings coexist; `x?` on a non-wresult operand
is now a syntax error at the missing then-arm rather than a dedicated
diagnostic. The then arm decides the result type (an untyped-constant
arm defers to the else arm); the else arm is coerced on its own branch
before the join. Scalars come back as rvalues so a ternary is never an
assignment target.

## Polymorphic print/println (grammar/print_builtin.w, structures/prelude.w)

`print(` / `println(` intercept in primary_expr (the to_json pattern)
and dispatch on the argument's static type, compile time only: int-likes
as decimals, `char*`/`string` bytes, float32 through a private ftoa
clone, `var` through `__w_var_to_cstr`, and `list[T]` of scalars as
`[a, b, c]`. `println()` with no argument emits just the newline.
Unsupported types (maps, sets, structs, non-char pointers, float64) are
compile errors. lib/lib.w keeps its `print(string)` / `println(string)`
functions and call sites behave identically for those types, so existing
programs compile unchanged.

The runtime lives in structures/prelude.w, imported on demand at a
top-level boundary (`prelude_finish_import()` next to the template
string finisher) with per-helper backpatch chains. The prelude
deliberately avoids lib/format.w: that module defines a W `printf`,
which would collide with programs that `c_import` libc's printf.

## Stdin helpers: input(), read_all(), ints() (structures/prelude.w)

Plain functions in the prelude, reachable without an import: primary
expression parsing resolves the three names to the prelude only when no
user symbol shadows them. `input()` returns one line (newline stripped,
0 at EOF), `read_all()` the whole stream, `ints()` every integer in the
input (signs included) as a `list[int]`.

## Script mode (grammar/program.w)

A top-level token that cannot start a declaration opens an implicit
`int main():`; every remaining token in the file must belong to a
statement. Declarations therefore must precede the first top-level
statement — mid-file declarations would splice module or function code
into the implicit main's instruction stream, which the REPL solves with
skip-jumps; batch mode v1 keeps the restriction and reports
"declarations must come before the first top-level statement" (function
definitions get the same message via a one-token scan-ahead). The
implicit main returns 0 and plugs into the normal entry chain: lib.lib's
`_main` calls it when the prelude pulled lib.lib in, and elf_finish's
direct `main` fallback covers programs that never imported anything.
A top-level `defer` is now a legal script statement (it runs when the
implicit main exits) instead of the old "'defer' outside of a function"
error.

## list[T] methods (grammar/list_builtin.w, structures/w_list.w)

New pseudo-methods, lowered like push/pop with the runtime split:

- `l.sort()` — in-place stable insertion sort; int-likes compare as
  signed words, `char*` by contents (the map/set key rule). Structs,
  strings and floats are rejected.
- `l.sort_by(f)` — comparator returns negative/zero/positive like
  strcmp. Scalar elements pass values; struct elements pass element
  addresses (`__w_list_sort_by_addr` stages the moved element).
- `l.map(f)` — new list; the element type is f's declared return type
  (from the symbol table for named functions, the signature for
  `fn(...)` alias pointers).
- `l.filter(f)` / `l.reduce(f, init)` — new list of the same element
  type / left fold whose result type is the init expression's type.
- `l.sum()`, `l.min()`, `l.max()` — int-like elements only.
- `l.reverse()` — in-place, any element type.
- `l.count(x)`, `l.index(x)` — scalar and `char*`-content scans;
  index returns -1 when absent.

Callbacks cross the boundary as words and the runtime calls through a
plain int parameter (the `repl_error_jump` precedent), so
structures/w_list.w stays seed-compatible with no `fn` types. W has no
lambdas: callbacks are named functions or `fn` alias pointers, which is
why only `sort`/`sort_by` carry their weight for terseness while
map/filter mostly serve pipeline-style composition.

## Stdlib fills (lib/str.w, lib/math.w)

lib/str.w: `substring` (clamping, half-open), `index_of`, `split`
(non-mutating, unlike `split_string` in structures/list.w; empty pieces
preserved), `replace` (multi-character), `join` over `list[char*]`.
lib/math.w grows `abs`, `sign`, `gcd`, `pow` (integer, by squaring).

## Wave 2 (issue #360)

### Inferred for-loop variables (grammar/for_statement.w)

`for x in ...` drops the loop-variable type when the range or container
already fixes it. The name is consumed and its stack slot reserved up
front, but the symbol is declared only after the iterable expression
parses (the `:=` precedent), so the iterable cannot reference the new
name. The inferred types mirror the typed form's coercion sources:
range and `string` loops bind `int`; maps bind the key type, and the
optional second variable the value type (struct values as stored-value
addresses, the `__w_map_iter_value_addr` rule); sets the key type;
lists and slices the element type (struct list elements as element
pointers); custom cursor-protocol containers their `T_iter_value`
return type, with `for_iter_require` still validating the protocol.
Typed and inferred bindings mix freely in the two-variable map form.
The parser-generator grammar's `for_binding` rule had accepted a bare
`IDENT` binding since #42, so `w.pg` only gained a comment. One known
rough edge: the debugger's local note is recorded at declaration with
the final type, but wdbg's view of a struct-element pointer variable is
only as good as `debug_local_note`'s type rendering.

### Safer ':=' (grammar/variable_declaration.w)

`:=` always declares a new variable, so using it on a name still
visible as a local or parameter is now an error (":=' redeclares 'x';
use '=' to assign, or a typed declaration to shadow"): the silent
inner-scope shadow was the classic bug where `x := 2` inside a block
left the outer `x` untouched. Scope exit truncates the symbol table,
so a name whose previous binding lived in a closed block is free for
reuse, and globals stay silently shadowable exactly like typed
declarations. The REPL's persistent-variable path
(`repl_infer_declaration`) is separate and still allows re-entering
`x := ...` at the prompt. The inference diagnostics now name the
variable ("cannot infer a type for 'x' from a void expression" / "...
from a bare function name"; the list-reduce init reuses the same
helper as "reduce init"), and all four errors are pinned by the
`infer_safety_test` fixture group. The untyped-constant default is
unchanged and now spelled out: constants infer `int`, the word-sized
type, so the same source infers the same storage on every target
(literals wider than 32 significant bits were already tokenizer
errors). Inferred `for` variables deliberately do NOT get the
redeclare error: sequential `for i in range(...)` loops in one
function each declare their own `i`, matching the typed form.

### Prelude math: max/min/abs/len (grammar/print_builtin.w)

`max(a, b)`, `min(a, b)`, `abs(a)` and `len(x)` work with no import
when no user symbol shadows the name -- the input()-helper rule:
primary_expr resolves the bare name to the prelude only when
sym_lookup misses, so imports of lib/math.w (or a user definition,
including forward 'U' prototypes) win unchanged. A user GENERIC
function of the same name also wins (generic_def_lookup): bare calls
of 'T max[T](T a, T b)' keep resolving through generic argument
inference, which tests/generics_inference_test.w pins. Like the stdin
helpers this is single-pass: a call site textually before a
same-file user definition binds the prelude, later sites bind the
user function. max/min/abs are int-only (constants, enums, bool, char
and the fixed-width ints; anything else is "prelude 'max' argument
must be an int-like value: '...'") and lower to __w_max/__w_min/__w_abs
in structures/prelude.w through the existing helper backpatch chains.
len is compile-time polymorphic, not a runtime helper: list/map/set
and the buffers (string, slice, decayed fixed array) read their length
word at container + word_size (exactly the '.length' rule, so string
lengths are byte counts), and char* borrows lib/lib.w's strlen through
the chain (the prelude import always pulls lib.lib in). Unsupported
argument types are "unsupported len argument type: '...'"; both
diagnostics are pinned by the prelude_math_error_test fixture group.
No new syntax: these are ordinary call sites, so the parser-generator
grammar is untouched.

## Wave 3: better strings (issue #360 item 4)

### char print (grammar/print_builtin.w, structures/prelude.w)

print/println render a genuinely char-typed value as the character
itself (one byte, via `__w_print_char`) instead of its numeric code.
The boundary is the static type: character literals are untyped
constants and char arithmetic yields int, so `println('a')` and
`println(c + 1)` keep printing numerically, as do `byte`/`int8`/
`uint8` values. `list[char]` elements and f-string `{c}`
interpolations keep the numeric int-like rendering of the shared
f-string helper-kind table — only the scalar print dispatch changed.
`type_is_char` (compiler/type_table.w) is the level-0 sibling of
`type_is_char_pointer`.

## Acceptance

- `./wbuild verify` — self-host fixpoint (wv3 == wv4 == wv5) with every
  feature active; the compiler sources themselves now compile through
  the print builtin.
- `./wbuild tests` / `./wbuild tests` — full suite, including the new
  targets: infer_test, ternary_test, print_builtin_test,
  script_mode_test, prelude_test, list_methods_test, str_test,
  math_test.
- `parser_generator_w_test` — tests/parser_generator/w.pg learned
  `:=` (COLON_ASSIGN + infer_decl) and the ternary postfix form, and
  still parses every tracked `.w` file.
- Seed compatibility: all compiler/grammar/structures changes are in
  seed-understood syntax; new syntax appears only in tests/. No
  `./wbuild update` in this batch.
