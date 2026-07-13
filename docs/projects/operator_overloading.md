# Operator Overloading

Design doc for issue #104, deliberately minimal for v1: user code can
define what the **binary arithmetic operators `+ - * / %`** mean for
**struct values**, C++-style. Nothing else changes meaning —
comparisons, prefix/postfix forms, other types and minted spellings
are all staged behind this (see Staging and the extension section).
Restricting to operator tokens the language already has means **no
tokenizer changes at all**, and precedence comes free.

Status: design only, nothing implemented.

## Proposed surface

```w
struct vec3:
	float x
	float y
	float z

vec3 operator+(vec3 a, vec3 b):
	return vec3(a.x + b.x, a.y + b.y, a.z + b.z)

float operator*(vec3 a, vec3 b):     # dot product
	return a.x * b.x + a.y * b.y + a.z * b.z

vec3 operator*(vec3 a, float s):     # scaling; same spelling, distinct
	return vec3(a.x * s, a.y * s, a.z * s)   # operand types

vec3 n = a + b * 0.5
```

Definitions look exactly like functions with `operator` + one of
`+ - * / %` in name position, and take exactly two parameters.
Forward declarations (`vec3 operator+(vec3 a, vec3 b);`) follow the
normal prototype rules; single-pass compilation means
define-or-declare before first use, like everything else in W.

**Dispatch rule**: an overload is consulted only when at least one
operand is a struct **value** (pointer level 0). Scalar arithmetic
can never change meaning, and struct *pointers* keep pointer
arithmetic exactly as today (`vec3* p; p + 1` stays pointer math —
C++ makes the same cut). Mixed operands like `vec3 * float` are in
scope — scaling is half the point for the motivating vector case —
and cost nothing: resolution is an exact match on
(spelling, left type, right type), no conversions tried. A
struct-value operand with no matching overload becomes a compile
error (see Diagnostics) — today it silently falls through to
word-sized ALU code on the value's address, which is garbage in the
same family as the method-chain silent-ignore that
`docs/projects/struct_methods.md` fixed.

## How it fits the compiler

The compiler is single-pass with no AST: each precedence level is a
grammar function that string-matches the operator token, parses the
right operand at the next-tighter level, and lowers immediately —
by which point *both operand types are known*
(e.g. `additive_op` in `grammar/additive_expr.w`: `binary1()` pushes
the promoted left operand, the right side parses, then the var and
float layers are tried before the integer ALU fallback). That makes
overloading a new first layer in the existing lowering chain of just
two grammar files (`additive_expr.w`, `multiplicative_expr.w`), not
a parser change:

```
user-overload layer → var layer → float layer → ALU fallback
```

The layer is one lookup — gated on "either operand is a struct
value", so ordinary code pays one type-table check — and, on a hit,
emits a call instead of ALU ops. Precedence and associativity come
free: existing spellings keep their ladder level.

### Lowering: operator use = function call

The hard part — the left operand was already evaluated before we knew
a call was coming — is precisely what struct method sugar solved, and
the `.method()` branch in `grammar/postfix_expr.w` is the template:
save the already-evaluated operand, `sym_get_value` the callee
(callee-first stack layout), park a return buffer when the operator
returns a struct by value (`has_return_buffer`), push the operands as
arguments with `check_call_argument`/`coerce`, and emit the call
tail. One refactor is needed: `parse_call_suffix` parses its
arguments *from source* (`arg, arg, ...)`) and an operator has none,
so the "finish a call whose arguments are already pushed" tail gets
extracted into a helper both paths share. Riding this machinery means
struct-by-value arguments and returns (`vec3 + vec3 → vec3`), type
warnings and result chaining all work on every target for free.

### Declarations, mangling, the registry

`program()` (`grammar/program.w`) parses the definition: after
`type_name()`, a token spelled `operator` followed by an arithmetic
operator token enters the operator path; it synthesizes a mangled
symbol and reuses `function_definition`. `operator` stays a
contextual keyword — `int operator = 5` still declares a variable
(today the word appears only in comments, so nothing in the tree
re-lexes).

Mangled names encode the operand types with `$`, the established
internal-mangling character (`max$int` in generics):
`op$+$vec3$vec3`, `op$*$vec3$float`. This is what allows several
definitions of `operator*` to coexist — the "one definition per
name" rule (`docs/projects/generics.md`) is preserved because the
*names* differ. The registry is the symbol table itself: the
lowering layer builds the mangled name from the spelling and the two
unqualified operand type names and does a `sym_lookup`, exactly how
method sugar resolves `Type_method`. Imports carry definitions
across files as usual, and `w check`, `symbols`, `deps`, the REPL
and wdbg inherit the feature because they share the grammar.

Operator functions must be ordinary functions: w-variadic, generator
and generic definitions are rejected (`operator+[T]` composing with
`docs/projects/generics.md` instantiation is future work; bind a
concrete wrapper meanwhile).

## Diagnostics (new messages, frozen by fixtures)

- `no operator '+' for operands 'vec3', 'int'` — struct-value operand
  on an arithmetic operator with no matching definition (replaces
  today's silent address arithmetic),
- `operator '==' cannot be overloaded` — any non-arithmetic token
  after `operator` (comparisons, `&&`, `=`, `[]`, `++`, ...),
- `operator definition takes 2 parameters`,
- duplicate definitions fall out of the existing symbol-redefinition
  error via the mangled name.

No existing message text changes (`warning_test` and the
`type_system_*` fixtures stay untouched).

## Gates checklist

- **Seed constraint**: the implementation (`grammar/`, the lowering
  layer, `program()`) is inside the seed's import graph, so it may
  not *use* operator definitions — only `tests/` and leaf consumers
  can once `bin/wv2` exists. Library adoption (e.g. `graphics/`)
  waits for a seed promotion per `docs/release.md`.
- **`./wbuild verify`** plus `verify_x64` / `verify_arm64` — the
  lowering rides the call machinery on every target.
- **`tests/parser_generator/w.pg`**: one `operator_def` rule
  (`type_ref KW_OPERATOR arith_op params block`); list `operator` in
  `name_token` like `case`/`default` so it stays usable as an
  identifier.
- **Fixtures**: each diagnostic above gets a compile-only fixture
  with `# expect_stderr:` directives (`bin/wfixture`).
- **Tests**: `tests/operator_overload_test.w` with a `# wbuild: x64`
  twin — all five operators on struct values, mixed operand types
  (`vec3 * float`), struct-by-value returns chained into further
  expressions, precedence against built-ins, pointer arithmetic
  unchanged; then `./wbuild manifest` (never hand-edit
  `build.json`).

## Staging

1. **v1 (this doc): binary `+ - * / %` on struct values.**
   `graphics/` is the proving consumer: `operator+` etc. can delegate
   to the existing `vec3_add` family, so the module migrates without
   churn.
2. **Prefix `-`** — mechanically trivial once the binary layer
   exists (the same lookup in `unary_expression()` before the
   float/int negate lowering; arity 1 distinguishes it), but kept
   out of v1 to keep the first change one hook pattern.
3. **Comparisons `== != < <= > >=`** — needs its own small decision
   pass: whether `!=` auto-derives from `==` (lean no — zero magic)
   and whether overloads must return `bool` (lean: warn).
4. **Postfix `++`/`--`** — blocked on #103 (the tokens don't exist;
   `++` lexes as two `+` today). Two rules recorded now: a spelling
   with any binary meaning can never be postfix (after a left
   operand the parse is ambiguous, and the tokenizer tracks no
   whitespace adjacency to break ties), and token gluing bites
   (`a!=b` lexes `!=` as one token, so postfix `!` is off the
   table).
5. **Compound assignment** (`v += w` as `v = v + w` through the
   overload) — today compound assignment on struct values is an
   error, so this is purely additive.
6. **Minting new spellings** — parked; see below.

## Future extension: new operator spellings

Considered and *parked*, with the analysis kept for when demand
shows up. Three routes, best first:

- **Fixed-inventory extension (Julia model)**: the *language* adds a
  closed set of extra operator tokens (`**`, `|>`, ...) to the
  tokenizer and `w.pg`, and user code overloads them like any
  existing operator. Lexing stays deterministic and the PG grammar
  static; each addition is a small, reviewable language change. This
  subsumes most real demand for "custom operators".
- **Backtick infix**: ``a `f` b`` calls any 2-argument function
  infix. Backtick is unused (lexes as a single-char token today), so
  this costs one grammar branch at a single precedence level and no
  declarations. Cheap, but covers binary only.
- **Sigil-led user spellings** (`@+`, `@dot`): a leading `@` gives
  declaration-order-independent lexing (one `get_token()` branch, one
  generic `CUSTOM_OP` class in `w.pg`) — but it is the syntax tax the
  primary design exists to avoid, and `@` is currently load-bearing
  as the source-illegal generics placeholder marker
  (`grammar/generic.w`). Only worth revisiting if the fixed
  inventory proves too rigid.

**Rejected outright: registry-driven lexing** (user declarations
teaching the tokenizer arbitrary spellings like `<+>`, which today
lexes as three tokens). Token boundaries would depend on which
declarations have been seen — import order changes how a file lexes
(the Prolog `op/3` disease) — and `parser_generator_w_test` parses
every tracked `.w` file against a *static* grammar, which cannot
express registry-dependent lexing.

New binary spellings, whichever route, would share one new
left-associative ladder level between `relational` and `shift`
(operator results compare naturally; all arithmetic binds tighter). A
precedence-climbing rewrite of the ladder was rejected: the level
functions carry per-operator special cases that don't table-ize (the
float and `var` layers, the bool-`|` warning, `in`, the
`*`-on-a-fresh-line rule in `multiplicative_expr.w`), and they are
the most battle-tested code in `grammar/`.

## Open questions

- Whether `operator+` definitions should *also* be callable by their
  mangled name from user code. Lean no — internal names stay
  internal.
- Generic operator definitions (`T operator+[T](T a, T b)`) — needs
  the generics doc's inference machinery; out of scope here.

## Related

- #104 — the tracking issue.
- #103 — `++`/`--` tokens; prerequisite for the postfix stage.
- #101/#102 — other missing built-in operators (`^`, `~`).
- #27 — Matrix class; likely second consumer after `graphics/`.
- `docs/projects/struct_methods.md` — the dispatch/lowering pattern
  this design parallels.
- `docs/projects/graphics.md` — the motivating consumer
  (`vec3_add(a, b)` today, `a + b` after v1).
- `docs/projects/generics.md` — `$`-mangling precedent and the
  instantiation machinery a generic-operator story would need.
