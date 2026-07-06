# Dynamic `var` type

A dynamically-typed value for W: a `var` variable can hold an int, a
C string (`char*`), or a string, can be rebound to a different runtime
type, and dispatches arithmetic/comparison at runtime.

```w
var x = 5           # tagged int
var y = c"hello"    # tagged char*
x = s"now a string" # rebinding to a different runtime type is legal
var sum = x + x     # runtime dispatch; traps on type mismatch
int n = x           # unbox with runtime type check (traps on mismatch)
print_var(x)        # runtime inspection helper
```

## Representation

A `var` value is one word: a pointer to a heap-allocated tagged box
(precedent: `json_value` in `structures/json.w`). The box lives in
`structures/w_dynamic.w`:

```
struct __w_var_box:
	int tag        # 0 null, 1 int, 2 char*, 3 string
	int payload    # int value / char* pointer / string data pointer
	int payload2   # string length (tag 3 only)
```

Tags v1:

- `0` null/uninitialized. A null box **pointer** (0) is also treated as
  the null tag, so zero-initialized `var` globals behave as null.
- `1` int — covers all int-likes: fixed-width ints, `char`, `bool`,
  enum values. Stored sign-extended in one word.
- `2` `char*` — the pointer is stored as-is (not cloned).
- `3` string — the descriptor's `data`/`length` are copied into
  `payload`/`payload2`; the character data is shared, not cloned.

In the compiler, `var` is a builtin type in `compiler/type_table.w`:
`var_type` (storage, one word, like `string`) plus the `"var value"`
pseudo-type `var_value_type` (eax holds the box pointer), both with a
new kind `type_kind_var()`. Because `type_name()` recognizes any name
in the type table, `var` parses as a type with **zero** grammar
changes: locals, parameters, return types, globals, struct fields and
`cast(var, ...)` all work through the existing declaration rules.

## Boxing and unboxing (coerce)

`coerce()` in `grammar/promote.w` delegates to `var_coerce()` in the
new `grammar/var_builtin.w` whenever either side is `var`:

- target `var`, source int-like/enum/bool/constant → `__w_var_box_int`
- target `var`, source `char*` → `__w_var_box_cstr`
- target `var`, source string → `__w_var_box_str` (takes the
  descriptor; `payload`/`payload2` take over data pointer and length)
- target `var`, source `var` → pointer copy (aliasing, see below)
- target int-like, source `var` → `__w_var_unbox_int` (runtime tag
  check, traps on mismatch); target `bool` additionally normalizes the
  unboxed word with `setne`
- target `char*`, source `var` → `__w_var_unbox_cstr` (accepts tag 2,
  and tag 3 when the data is NUL-terminated-copied; see runtime)
- target string, source `var` → `__w_var_unbox_str` (accepts tags 2/3)
- target `void*`, source `var` → pass-through: the raw box pointer is
  exposed. This is the escape hatch that lets seed-safe runtime/lib
  code accept a `var` without using the new type (e.g. `print_var`).
- anything else (floats, structs, containers, other pointers) in
  either direction is a **compile-time error**, not a miscompile.

`types_compatible()` in `compiler/type_table.w` mirrors these rules so
no bogus mismatch warnings fire.

Unbox helpers trap from plain W code: they print
`var runtime error: expected <t>, got <t>` to stderr and `exit(1)`
(same style as `cstr_invalid_utf8` in `lib/lib.w`; simpler than the
emitted bounds-trap machinery and fine for a runtime library).

## Operators

Handled in `grammar/var_builtin.w`, called from the additive /
multiplicative / equality / relational layers when either promoted
operand is `var`. The non-`var` operand is boxed first (same rules as
above), then:

- `+ - * /` → `__w_var_add/sub/mul/div`, result is a new `var`.
  `+` on two strings/cstrs **concatenates** (documented extra); all
  other arithmetic requires both tags to be int and traps otherwise.
- `== !=` → `__w_var_eq` (int compare for int tags; **content**
  compare for string/cstr tags, so `c"hi" == s"hi"` boxed both ways is
  true; null equals only null; mismatched tag families are unequal,
  not a trap). `!=` inverts the result.
- `< <= > >=` → `__w_var_cmp` returning -1/0/1, ints only, traps
  otherwise; the compiler compares the result against 0.
- `% << >> & |` on `var` are compile-time errors.
- Logical `&& || !` and `if (x):` truthiness are NOT overloaded: they
  see the box pointer (always truthy for an initialized var). v1
  limitation, kept to avoid touching the short-circuit layers.

## Runtime import

`structures/w_dynamic.w` is imported **on demand** (the json-codec /
template-string deferred-import pattern): call sites emitted before
the import go through per-helper backpatch chains, and the drivers
(`compiler/compiler.w::link_impl`, `repl.w`, `debugger/wdbg.w`) call
`var_finish_import()` at a top-level boundary. Programs that never use
`var` pay nothing. Programs may also `import structures.w_dynamic`
explicitly; helpers then resolve directly.

## Interaction with Wave-1 features

- Template strings: `f"{x}"` where `x` is `var` appends via
  `__w_var_to_cstr` (null → `null`, int → decimal, cstr/string →
  the text). Wired through the type dispatch in
  `grammar/template_string.w`.
- `var` as a W-variadic element type (`var... xs`) and default values
  on `var` parameters (`var x = 5`) are **out of scope** v1 and are
  clean compile errors (`grammar/program.w`).
- Generators may take/return `var` like any word-sized type (coerce
  runs on `yield` through the ordinary statement path); not
  specifically hardened in v1.

## Scope and memory

- Locals, parameters, return types and globals all work (globals are
  zero words → null tag; there is no global initializer syntax).
- `var`-to-`var` assignment copies the box **pointer** (aliasing) v1;
  rebinding `x = 5` allocates a fresh box, it does not mutate the old
  one, so aliases keep the old value.
- Boxes are heap-allocated and **leak** v1, consistent with the
  compiler's arena style. String data is shared with the source
  descriptor (no clone); `__w_var_to_cstr` and string concatenation
  allocate fresh buffers.
- `print_var(v)` (in `structures/w_dynamic.w`, seed-safe: takes the
  box through the `void*` pass-through) prints a readable rendering
  and a trailing newline to stdout; `__w_var_tag(v)` exposes the tag
  for tests.
