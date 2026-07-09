# Typed Containers

Design and decision record for issue #26 ("Typed Containers or Generics"):
how W provides typed, growable containers, and why the language extends its
closed set of built-in containers instead of adding true generics.

## Decision: built-in typed containers, not generics

W is a single-pass compiler with no AST: grammar rules emit machine code
while parsing, and every expression is represented only by a type index and
the code already emitted. True generics or templates would require capturing
token ranges and re-parsing each function or struct body per instantiation,
plus name mangling, instantiation caching, and diagnostics that reference
the original source. That machinery works against everything that keeps
this compiler small, and `docs/projects/type_system_p0.md` already scoped
generics out of the type system rework.

What programs actually need day to day is a small set of typed collection
shapes. The `map[K, V]` / `set[K]` MVP (issue #47) established the pattern
that delivers them cheaply:

- The type table stores parse-time-monomorphized container types: one
  record per distinct element/key/value combination, deduplicated on
  lookup, with the parameter types in the record.
- Grammar hooks lower container syntax directly to a small `__w_*` runtime
  that every program auto-imports.
- The parameter types exist only at compile time; the runtime works with
  element sizes and word values, so no per-instantiation code is generated.

`list[T]` extends that closed set with the growable vector shape. True
generics (user-defined parameterized functions and structs) were deferred
here as out of scope for *containers* specifically — and later landed for
a different reason (issue #26's other half): `T max[T](T a, T b)` and
`struct pair[T]:` with explicit instantiation, plus call-site
type-argument inference (`max(3, 5)` without `[int]`), are implemented
per `docs/projects/generics.md`. The two mechanisms coexist as predicted:
built-in `map`/`set`/`list` stay the closed-set, no-monomorphization path
for containers, while user-defined generic functions/structs use
token-range re-parse monomorphization separately; their syntax does not
overlap.

## `list[T]`

A typed, growable, heap-backed list. Lists are reference values like maps
and sets: assigning a list variable copies the container pointer, not the
elements.

```
list[int] l = new list[int]
l.push(10)
l.push(20)
l[0] = 5
print_int("first: ", l[0])
print_int("count: ", l.length)
int last = l.pop()
for int x in l:
	print_int("x: ", x)

list[char*] names = list[char*]{"alpha", "beta"}
list[list[int]] grid = new list[list[int]]
```

### Syntax

- `list[T]` is a list with element type `T`.
- `new list[T]` allocates an empty list.
- `list[T]{a, b, c}` allocates and populates a literal.
- `l[i]` reads or writes element `i`; out-of-range indexes abort.
- `l.push(v)` appends; `l.pop()` removes and returns the last element
  (aborts when empty).
- `.length` returns the element count.
- `for T x in l` iterates elements in order.
- Struct elements iterate by address: `for point* p in l` (a word-sized
  loop variable cannot hold a struct value; the pointer also allows
  in-place mutation).

### Element types

Any scalar, pointer, `string`, slice, map, set, or list type, plus struct
values. Rejected at parse time:

- `void` and other zero-sized types.
- Fixed-size arrays (`int[3]`) and structs containing fixed-array fields:
  array descriptors point into the enclosing object, so a byte copy would
  corrupt them.
- Multi-word scalars that do not fit the target word (`int64` on x86 is
  already rejected by the type checker).

### Runtime layout

`structures/w_list.w` is auto-imported into every program, like the hash
runtime. Storage is byte-addressed:

```
struct __w_list:
	int capacity      # in elements
	int length        # in elements
	int element_size  # bytes per element slot
	char* items       # length * element_size payload bytes
```

`length` stays the second field so `.length` compiles to the same
one-word-offset read the map/set containers use. Scalar elements occupy
their natural width (`list[char]` stores one byte per element); struct
slots round up to a word multiple to match W's word-granular struct
copies. Growth doubles the capacity.

### Compiler integration

- `compiler/type_table.w`: `type_kind_list`, element type in the record,
  list-to-list compatibility requires identical element types.
- `grammar/type_name.w`: parses `list[T]` (a contextual keyword: `list`
  only starts a type when immediately followed by `[`) and validates the
  element type.
- `grammar/list_builtin.w`: lowers `new`, literals, indexing, push/pop.
  `l[i]` calls `__w_list_addr` and leaves the element's address in eax, so
  element reads and writes flow through the normal lvalue machinery with
  the element type's own width — unlike map indexing, no pending-lvalue
  state is needed.
- `grammar/for_statement.w`: cursor-protocol loop over `__w_list_iter_*`
  (or `__w_list_addr` for struct elements).

## Aggregate values in containers

Struct values are stored by value in both `list[T]` slots and `map[K, V]`
value slots:

- Writes pass the source struct's address; the runtime copies the slot's
  bytes (`__w_list_push_bytes`, `__w_map_set_bytes`).
- Reads return the stored bytes' address (`__w_list_addr`,
  `__w_map_get_addr`, `__w_list_pop_addr`), which is exactly how W passes
  struct values everywhere, so field access, whole-struct copies, and
  method-call sugar work unchanged.
- `m[k].x = 1` and `l[i].x = 1` write the container's storage in place.
- A read's address is only valid until the next insertion (maps rehash,
  lists reallocate), and `pop`'s result only until the next push. Copies
  into locals (`point p = m[k]`) happen immediately, so this only matters
  for code that stores the address itself.

Map value storage is byte-addressed with one slot per entry
(`__w_hash_slot_size`); scalar values keep the original one-word slots, so
existing behavior is unchanged.

## Deferred work

- `l.insert(i, v)`, `l.remove(i)`, `l.clear()` and other pseudo-methods.
- `in` membership for lists (linear scan) if a use case appears.
- Multi-word scalar elements on x86 (e.g. `list[int64]`).
- Struct keys for maps and sets (values are done; keys still hash words,
  C strings, or `string` descriptors).
- Migrating compiler-internal containers (`structures/list.w`, the symbol
  table) to `list[T]`: blocked until a seed update (`./wbuild update`) makes
  the syntax available inside `compiler/`, `grammar/`, and
  `code_generator/` sources.
