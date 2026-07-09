# P0 explicit type system

Status: in progress.

Completed so far:

- `bool`, `const`, transparent `type` aliases, `fn(...) -> T` typed function
  pointers, `enum`, `union`, direct-call return typing and struct
  return-by-value are implemented and covered by `type_system_p0_test`.
- `int64`/`uint64` storage, arithmetic, fields, globals and returns are
  implemented on the x64 target; the 32-bit target rejects them with a clear
  diagnostic.
- Milestone 1's compatibility item and Milestone 12's shim removal:
  `types_compatible()` no longer treats `int` as an untyped word or
  `function` values as universally convertible. `int` <-> pointer and
  function-value conversions warn unless spelled with an explicit
  `cast()`; only the `constant` pseudo-type (literals, `&x`) remains a
  wildcard until typed literals land.
- Milestone 2 partially: `cast(T, x)` exists, flows through
  `coerce_explicit()`, rejects struct-value casts and pointer-to-sub-word
  integer casts, and every previously implicit "int as untyped word" use
  in the compiler, library, tools and tests is now either a safe implicit
  conversion (`void*`-based allocator signatures, scalar widening) or an
  explicit cast. `./wbuild self_host_warning_test` keeps the self-hosted
  compile warning-free on both targets.
- The committed seed was promoted to a post-P0 compiler so the bootstrap
  core can use `cast()` itself.

This plan turns W's current permissive, word-centric type checks into an
explicit type system that remains compatible with the compiler's single-pass
parser/code-generator architecture.

## Goals

- Make every expression carry a trustworthy type, including literals, calls,
  function pointers, struct values, enum values, and union values.
- Replace implicit wildcard behavior with explicit conversions and casts.
- Add first-class surface syntax for `bool`, `const`, type aliases, typed
  function pointers, enums, unions, and fixed 64-bit integers.
- Support struct return-by-value without losing the existing by-value struct
  parameter behavior.
- Keep x86 and x64 bootstraps deterministic: `./wbuild verify`, `./wbuild tests`, and
  `./wbuild verify_x64` must stay green at every completed milestone.

## Current constraints

- The compiler has no AST or IR. Grammar rules parse and emit code immediately,
  so type changes must fit the current "expression emits code and returns type"
  model.
- `compiler/type_table.w` currently stores name, field count, size, pointer
  level, and struct-field metadata. It does not encode kind, signedness,
  alias identity, qualifiers, enum tags, union variants, function signatures,
  or canonical types.
- `compiler/symbol_table.w` records function parameter counts and up to ten
  parameter type slots. Direct calls now preserve the declared return type for
  the tested P0 cases, including `bool`, struct pointers and struct returns.
- `constant` and `function` are pseudo-types. `types_compatible()` still
  treats `constant` (literals, `&x`) as broadly compatible; `int` and
  `function` wildcards have been removed in favor of explicit casts.
- Struct values can be locals, by-value parameters, globals and function
  returns. Fixed-array-bearing structs are copied by value; fixed arrays are
  still intentionally rejected as parameters, union fields and constructor
  arguments.
- Typed function pointer aliases (`type binary_op = fn(int, int) -> int`) can
  be stored in locals/fields and called with checked signatures. Generic
  function values still warn unless converted through a matching typed pointer
  or an explicit cast.
- `int`/`uint` are target-word-sized. Explicit widths exist for 8/16/32-bit
  integers on both targets; `int64`/`uint64` are x64-only for arithmetic today.

## Success criteria

- A clean fixture compiles without type warnings; a negative fixture proves
  incorrect assignments, calls, returns, casts, const writes, function-pointer
  calls, enum/union misuse, and 64-bit truncations are diagnosed.
- All direct function calls and typed indirect calls preserve declared return
  type, including `bool`, pointers, aliases, enums, structs, unions, and
  `int64`/`uint64`.
- Explicit casts are the only way to silence unsafe conversions.
- Struct values round-trip through function returns, nested calls, assignment,
  field access and method receivers.
- x86 rejects unsupported 64-bit value operations with clear diagnostics, or
  implements them with a documented helper convention; x64 supports full
  register-width `int64`/`uint64` arithmetic and comparisons.

## Design direction

### 1. Split type identity from expression value state

Keep type-table indices as source-level type identities, but add an expression
metadata layer for how the value currently lives:

- `type`: source type index.
- `mode`: address/lvalue, value-in-register, function-address, void, or
  aggregate-address.
- `is_assignable`: whether assignment may target this expression.
- `is_const`: whether writes through this expression are forbidden.

Do this first as small helper functions and side-channel globals if returning a
struct would create a bootstrap cycle. Once struct return-by-value is complete,
the helper can become an ordinary `expr_info` struct return.

This removes pressure to encode "already promoted value" as fake source types
such as `constant` or `float32 value`.

### 2. Expand type-table records in compatible slices

Add new fields behind helper accessors instead of open-coding offsets:

- `kind`: void, integer, bool, pointer, array-like pointer, struct, union,
  enum, function, alias, value pseudo-kind, and opaque/imported.
- `size` and `align`: field layout should stop depending only on size.
- `signedness`: signed, unsigned, or not-numeric.
- `base_type`: pointer target, alias target, enum backing type, const target.
- `return_type` plus parameter types for function signatures.
- `flags`: const-qualified, literal-only, incomplete, imported, varargs.
- aggregate member table: field/variant name, type, offset, and tag value.

The first implementation can keep the fixed-size record strategy, but all
callers should move through `type_*` helpers before layout changes land.

## Milestones

### Milestone 0 - Baseline and guardrails

- Add focused fixtures before behavior changes:
  - precise direct-call return type fixture,
  - function-pointer call fixture,
  - struct return-by-value fixture marked expected-fail until implemented,
  - conversion-warning fixture expansion,
  - x64 integer fixture.
- Add build targets that compile and run these fixtures directly.
- Record current warning output and expected runtime results.

Exit criteria: new tests document current gaps without destabilizing `tests:`.

### Milestone 1 - Type metadata helpers and typed literals

- Replace raw type-table offset reads in grammar code with helpers where P0
  features will touch them.
- Add kind/signedness/canonical-type helper accessors.
- Introduce typed integer literal handling:
  - decimal/hex literals start as a literal integer value with range metadata,
  - assignment/call/return contexts choose the destination width,
  - overflow and narrowing warn unless an explicit cast is present.
- Stop treating `int` as a universal escape hatch in `types_compatible()`.
  Preserve only well-defined implicit conversions:
  - exact literal to destination when in range,
  - scalar widening,
  - `void*` pointer conversions if kept as a language rule.

Exit criteria: existing code compiles with intentional warnings fixed or casted,
and new warning fixtures prove mismatches are real.

### Milestone 2 - Explicit casts

Syntax:

```
cast(type_name, expr)
```

Use a keyword form first because it fits the current parser and avoids
ambiguity with parenthesized expressions.

Semantics:

- `cast(T, x)` emits conversions through a single `coerce_explicit(T, got)`
  path.
- Explicit casts silence compatibility warnings but still reject impossible
  conversions, such as casting a struct value to an unrelated struct value.
- Numeric casts define truncation/sign-extension behavior.
- Pointer casts are allowed between pointer types; pointer-to-integer and
  integer-to-pointer are allowed only for word-sized integer destinations.
- `const` may be added by cast but not removed unless a later unsafe-cast
  spelling is deliberately introduced.

Exit criteria: every previously required "int as untyped word" use in the
compiler and library is either a safe implicit conversion or an explicit cast.

### Milestone 3 - `bool`

- Add `bool` as a 1-byte integer kind with values `0` and `1`.
- Add `true` and `false` keywords as typed bool literals.
- Relational, equality, logical, and `!`/`!!` operators return `bool`, not
  generic constants.
- Conditions accept `bool` directly. Numeric and pointer conditions remain
  allowed at first, but they should pass through a documented truthiness
  conversion.
- Stores to `bool` canonicalize to `0` or `1` unless the source is already
  bool.

Exit criteria: bool fields, bool parameters, bool returns, and bool arrays work
on both x86 and x64.

### Milestone 4 - Precise function-call return types

- Change `parse_call_suffix()` so the returned type is the callee's declared
  return type whenever the callee signature is known.
- Preserve value mode correctly: scalar returns are value-in-register, struct
  returns are aggregate-address or hidden-return-buffer based on Milestone 5,
  and void returns are void.
- Direct calls read return type from the function symbol.
- Method calls reuse the same call-result path.
- Unknown function pointers keep a compatibility warning path until typed
  function pointers land.

Exit criteria: call chaining through typed struct pointers works, float return
  handling no longer needs special pseudo-type logic, and REPL echoing uses
  return type rather than `last_call_return_type` hacks.

### Milestone 5 - Struct return-by-value

Adopt a hidden return-buffer ABI for aggregate returns:

- Caller allocates result storage in its stack frame or a temporary spill area.
- Caller passes the result address as a hidden first argument.
- Callee writes returned struct bytes into that address.
- Source-level parameters keep their current order; the hidden slot is internal
  to call setup and debugger metadata.
- `return expr` for a struct copies the bytes of `expr` into the hidden return
  buffer before function epilogue.
- A struct-returning call expression is an aggregate lvalue-like address that
  can feed field access, assignment, method receiver lowering, or another
  call.

Exit criteria: `make_pair().x`, `pair p = make_pair()`, `return make_pair()`,
and `make_point().move()` style tests pass.

### Milestone 6 - `const`

Start with shallow const qualification:

- Syntax: `const T name`, `const T* p`, and `T const* p` can be normalized by
  the parser to one internal representation.
- Const on an object forbids assignment to that object.
- Const on a pointed-to type forbids writes through dereference or field access.
- Non-const to const conversion is implicit.
- Const to non-const conversion warns or errors unless an unsafe cast spelling
  is intentionally accepted.

Defer deep transitive immutability, readonly function effects, and const
methods until the shallow rules are stable.

Exit criteria: const locals, globals, parameters, struct fields, and pointer
targets are enforced by assignment and field-store paths.

### Milestone 7 - Type aliases

Syntax:

```
type size_t = uint
type byte_ptr = byte*
```

Semantics:

- Alias identity is transparent by default: diagnostics print the alias name in
  source-facing contexts, but compatibility checks use the canonical target.
- Add a separate future `newtype` design if nominal aliases are needed.
- Aliases can name pointers, const-qualified types, function signatures, enums,
  unions, and structs.
- Imported aliases should be recorded in type metadata, not only in the symbol
  table.

Exit criteria: aliases work in declarations, fields, parameters, returns, casts,
and debugger/REPL type display.

### Milestone 8 - Typed function pointers

Syntax:

```
type binary_op = int(int a, int b)
binary_op* op = add
int x = op(1, 2)
```

If the parser cannot comfortably support named parameter syntax at first, use:

```
type binary_op = fn(int, int) -> int
```

Semantics:

- Function types store return type, parameter count, and parameter types in the
  type table.
- Function pointer types are ordinary pointer types whose base is a function
  type, not the current generic `function*`.
- Assigning a function to a function pointer checks the full signature.
- Calling through a typed function pointer checks arity and argument types and
  returns the declared return type.
- Keep generic `function*` temporarily for bootstrapping internals, but make it
  warn when called without a typed signature.

Exit criteria: callbacks in structs, parameters, globals, and locals are fully
typed, and indirect calls no longer collapse return type.

### Milestone 9 - 64-bit integer coverage

- Add `int64` and `uint64` as explicit fixed-width integer kinds on both
  targets.
- x64:
  - load/store with 8-byte register operations,
  - arithmetic `+ - *`,
  - division/modulo with signed and unsigned variants,
  - shifts,
  - comparisons,
  - casts to/from smaller integers, pointers, bool, and float64.
- x86:
  - choose one P0 policy:
    - either compile-error all non-storage 64-bit operations with clear
      messages, or
    - implement helper-call lowering for add/sub/compare/shift and defer
      div/mod.
  - storage, struct layout, copying, and passing still need to work because
    x86 code may represent external data with 64-bit fields.
- Add literal suffixes only if needed after typed literal inference:
  `123i64`, `123u64`.

Exit criteria: x64 int64 tests cover arithmetic, comparisons, calls, returns,
fields, arrays, casts, and ABI interactions; x86 behavior is deliberate and
tested.

### Milestone 10 - Enums

Syntax:

```
enum color:
	red
	green = 4
	blue
```

Semantics:

- Enum is a distinct type with an integer backing type, initially `int32`.
- Enumerators are typed constants scoped as `color.red` if possible; if global
  names are easier initially, reserve a migration path to scoped names.
- Enum values implicitly convert to their backing integer only in comparison,
  switch-like future constructs, and explicit casts. Integer to enum requires a
  cast.
- Debug/type printing should display enum names when metadata is available.

Exit criteria: enum variables, fields, parameters, returns, comparisons, casts,
and duplicate-value handling are tested.

### Milestone 11 - Unions

Syntax:

```
union value:
	int i
	char* s
	point p
```

Semantics:

- Union layout size is max member size, alignment is max member alignment.
- Field access computes offset zero with the selected field type.
- Assignment between the same union type copies the full union size.
- No automatic tag is included in the MVP. Tagged unions can be expressed as a
  struct containing an enum tag and union payload.
- Const and alias rules apply to union fields the same way as struct fields.

Exit criteria: union locals, globals, fields, parameters, returns, assignment,
and nested struct/union layout tests pass on x86 and x64.

### Milestone 12 - Cleanup and hardening

- Remove compatibility shims that let `constant`, `function`, or `int` bypass
  real checks.
- Replace remaining direct symbol/type table offsets touched by P0 with helper
  calls.
- Update `docs/todo.txt`, `README.md`, and feature docs to describe the new
  type rules.
- Add debugger/REPL coverage for bool, aliases, enum names, union fields,
  typed function pointers, and struct-returning calls.
- Keep commits milestone-sized so bootstrap regressions are easy to bisect.

## Risk order and recommended implementation sequence

1. Metadata helpers and tests: low behavior risk, unlocks later work.
2. Typed literals and casts: removes the need for wildcard compatibility.
3. Bool: small surface area, validates typed operators.
4. Precise call returns: directly unblocks method chaining and function-pointer
   return work.
5. Struct return-by-value: highest ABI risk; do after call-result typing.
6. Const and aliases: mostly parser/type-checking once expression metadata is
   trustworthy.
7. Typed function pointers: depends on function-signature types.
8. 64-bit integers: substantial codegen work, especially x86 policy.
9. Enum and union: aggregate metadata and diagnostics become straightforward
   once aliases, constants, and layout helpers are reliable.

## Test strategy

For every milestone:

- Add a positive runtime fixture under `tests/` or focused compiler unit test
  under `compiler/`.
- Add compile-only warning/error fixtures when behavior is diagnostic.
- Run targeted tests first, then `./wbuild verify`, then `./wbuild tests`.
- For codegen milestones, also run `./wbuild verify_x64` directly while iterating
  before the full suite.
- Do not promote the seed with `./wbuild update` until the full P0 stack is stable
  and the self-host fixpoint is clean.

## Non-goals for P0

- Generics/templates.
- Deep const/effect systems.
- Nominal `newtype` aliases.
- Pattern matching or built-in tagged-union syntax.
- A full AST or IR rewrite.
- C header import. The plan should make C import easier later, but does not
  include parsing C declarations.
