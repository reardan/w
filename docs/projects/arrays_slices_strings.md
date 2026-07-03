# Arrays, Slices, and UTF-8 Strings

Design and implementation plan for adding length-carrying buffers to W:
fixed stack/global arrays, heap arrays, slices, bounds-check options, and a
first-class UTF-8 string type.

**Status: MVP implemented.**

Implemented MVP:

- `T[N]` local fixed arrays with inline storage and descriptor headers.
- `T[]` slices represented as typed descriptor pointers.
- `new T[n]` heap arrays.
- `.length`, `.data`, indexing, and sub-slicing for new buffer types.
- `--bounds=on|off|trap` with inline traps for new buffer indexing.
- `string` UTF-8 descriptors, `s"..."` literals, `c"..."` legacy C strings,
  and `lib/utf8.w`.

Still deferred: global/struct fixed arrays, generic typed vectors, full
compiler-source migration from `"..."` to `string`, escape analysis, and
grapheme-cluster semantics.

## Problem statement

Today W has pointer indexing (`p[i]`) and library containers, but no
language-level buffer type. String literals are `char*` pointers to
null-terminated bytes, `structures/string.w` is a growable builder struct, and
UTF-8 is not represented as an invariant anywhere. Large programs therefore
fall back to raw pointers plus manual lengths, or to `array_list`, which stores
only word-sized elements.

The goal is to make the common cases direct and type-aware:

```
int[4] stack_values
stack_values[0] = 10

int[] heap_values = new int[n]
heap_values[i] = i * 2

int[] window = heap_values[start:end]
print_int("items: ", window.length)

string label = s"cafe\xcc\x81"
print_string(label)
```

## Scope

- **Fixed arrays**: `T[N]` storage with compile-time length, usable for stack
  locals first, then globals and struct fields.
- **Slices**: `T[]` two-word descriptors (`data`, `length`) with typed element
  metadata and no ownership by default.
- **Heap arrays**: `new T[n]` allocates contiguous storage and returns a
  `T[]` slice descriptor.
- **Bounds checks**: compiler option controlling checks for arrays, slices, and
  strings; legacy raw pointer indexing stays unchecked unless explicitly
  opted in later.
- **Strings**: first-class `string` as an immutable UTF-8 byte slice with
  length, validation helpers, codepoint iteration helpers, and explicit C
  string interop.
- **Deferred**: generics, growable typed vectors, grapheme-cluster semantics,
  borrow checking, automatic lifetime management, and changing every existing
  `"..."` literal in the compiler source at once.

## Bootstrap constraint

The committed seed compiler `./w` must compile the current compiler sources.
All compiler changes must therefore be written using syntax the old seed
already understands. New array/slice/string syntax may be used in tests and
library modules compiled by `bin/wv2`, but not in `compiler/`, `grammar/`, or
`code_generator/` until after `make verify` passes and a later `make update`
promotes the new seed.

This also means raw `"..."` literals cannot immediately change from `char*` to
`string`: the compiler, REPL, debugger, and library code currently rely on
`char*` literals throughout the self-hosting import graph.

## Core design: descriptors, not naked pointers

Add three related type kinds:

| source type | runtime shape | owns data? | length meaning |
|---|---|---|---|
| `T[N]` | descriptor + inline payload | yes, storage object | elements |
| `T[]` | descriptor value | no, view | elements |
| `string` | descriptor value | no, immutable view | bytes |

Descriptor layout is two target words:

```
offset 0             data pointer
offset __word_size__ length
```

For `T[N]`, the descriptor is stored immediately before the inline payload.
The compiler initializes `data` to the payload address and `length` to `N`.
The array expression's value is the descriptor address, so fixed arrays can
decay to slices by copying the two descriptor words.

`T[]` and `string` are true aggregate values. They must be copyable, passable,
and eventually returnable without pretending that one machine word carries the
whole value.

## Surface syntax

### Types

Extend `grammar/type_name.w` after pointer parsing:

```
int[16]      # fixed array of 16 ints
char[]       # slice of chars
point*[8]    # fixed array of point pointers
byte[]       # byte slice
string       # UTF-8 string descriptor
```

MVP restrictions:

- `N` in `T[N]` is a positive integer literal or simple compile-time constant.
- Nested arrays (`int[4][5]`) and arrays of slices are deferred until the first
  type-kind implementation is stable.
- `T[]*` and pointers to fixed arrays are deferred unless a test case needs
  them for bootstrap compatibility.

### Indexing and slicing

Extend `grammar/postfix_expr.w`:

```
buffer[i]        # element lvalue for T[N] / T[]; byte lvalue for string
buffer[start:end]# T[] slice, or string byte-range slice
buffer[:end]
buffer[start:]
buffer[:]
buffer.length    # pseudo-field: element count for arrays/slices, bytes for string
buffer.data      # pseudo-field: raw data pointer for interop
```

`string[i]` indexes bytes, not Unicode codepoints. Codepoint iteration is a
library operation because UTF-8 codepoint lookup by ordinal is O(n).

### Allocation

Extend `grammar/unary_expression.w`:

```
int[] values = new int[n]
byte[] buf = new byte[capacity]
```

`new T[n]` allocates a descriptor plus `n * sizeof(T)` bytes, zeroes the
payload in the MVP, and returns a `T[]` descriptor value. `free_array(slice)`
can free heap arrays by subtracting the descriptor header from `slice.data`;
borrowed slices must not be passed to `free_array`.

### Literals

Add a staged literal story:

- `s"..."` creates a `string` descriptor and validates the bytes as UTF-8.
- `c"..."` creates a legacy null-terminated `char*`.
- Existing `"..."` remains `char*` until the compiler and standard library are
  migrated.
- After a seed update, flip `"..."` to `string` only if the migration cost is
  acceptable; keep `c"..."` permanently for FFI and syscall paths.

String literal bytes remain null-terminated in emitted storage so `cstr(s)` can
return a stable `char*` when the string has no interior NUL.

## Milestone 1 - Type table kinds and metadata

Update `compiler/type_table.w` without changing existing source syntax:

- Add `type_kind`: scalar, pointer, struct, fixed array, slice, string, and
  value pseudo-type.
- Add metadata helpers:
  - `type_element_type(t)`
  - `type_array_length(t)`
  - `type_is_array(t)`
  - `type_is_slice(t)`
  - `type_is_string(t)`
  - `type_is_buffer(t)`
- Keep existing struct field offsets intact by appending metadata after the
  current field table, or migrate all field access through helpers in one
  patch.
- Register `string` in `push_basic_types()` only after renaming or otherwise
  resolving the current `structures/string.w` struct-name collision.
- Teach `types_compatible()`:
  - fixed array `T[N]` can initialize or pass to `T[]`;
  - `T[]` requires the same element type;
  - `string` does not silently convert to `char*`;
  - `byte[]` and `string` interop requires explicit helpers.

## Milestone 2 - Aggregate copy and return semantics

The existing convention handles one-word values well, and struct parameters by
value are already copied at call sites. Slices and strings need a general
aggregate path:

- Add `type_is_aggregate_value(t)` for structs, slices, strings, and eventually
  fixed arrays when copied explicitly.
- Add `copy_value(dst, src, type)` that copies `type_get_size(type)` bytes.
- Use it in:
  - local initialization in `grammar/variable_declaration.w`,
  - assignment in `grammar/expression.w`,
  - call argument pushing in `grammar/postfix_expr.w`,
  - constructor field initialization in `grammar/unary_expression.w`.
- Add aggregate returns with a hidden destination pointer for return types
  larger than one word. Direct calls reserve a temporary destination, pass it
  as hidden argument 0, and leave `eax` pointing at that destination. This
  should also unlock future struct return-by-value work.

This milestone is the safety rail: arrays, slices, and strings should not be
special-cased into every grammar rule if a common aggregate helper can do the
copy.

## Milestone 3 - Fixed stack arrays

Implement `T[N] name` for locals first:

- Parse array suffixes in `type_name()`.
- Reserve `2 * word_size + N * sizeof(T)` bytes on the stack.
- Emit descriptor initialization after reserving storage:
  - `name.data = &payload`
  - `name.length = N`
- Extend postfix indexing to:
  - evaluate the base descriptor once,
  - evaluate the index once,
  - optionally bounds-check,
  - compute `data + index * sizeof(T)`,
  - return an lvalue of `T`.
- Add `.length` and `.data` pseudo-fields for fixed arrays.

Struct fields and globals come after locals because they need layout and data
emission decisions:

- Struct field arrays increase containing struct size by descriptor + payload.
- Global fixed arrays need descriptor words initialized to the emitted payload
  address on both ELF32 and ELF64.

## Milestone 4 - Slices and range syntax

Implement `T[]` descriptor values and slicing syntax:

- `array[:]` copies the source descriptor.
- `array[start:end]` builds a descriptor with adjusted data pointer and length.
- Missing bounds default to `0` and `.length`.
- Slicing a `T[]` returns `T[]`; slicing `T[N]` returns `T[]`.
- Assigning a fixed array to a slice copies only the descriptor, not payload.
- Mutating through a slice mutates the original data.

Lifetime rule for the MVP: slices are borrowed views. Returning a slice of a
local fixed array compiles with a warning once escape detection exists; before
then it is documented as undefined behavior, like returning a pointer to a
local today.

## Milestone 5 - Heap arrays

Add `new T[n]`:

- Evaluate `n` once.
- Reject negative lengths when bounds checks are enabled.
- Compute allocation size with overflow checks where practical:
  `2 * word_size + n * sizeof(T)`.
- Call `malloc`, set descriptor fields, zero payload, and return a `T[]`
  descriptor.
- Add `lib/array.w` helpers:
  - `array_free(T[] view)` shape via byte-level implementation first,
  - `array_clone`,
  - `array_copy`,
  - `array_fill_zero`.

Because W has no generics, the first library helpers can operate on `byte[]`
plus element size, while compiler-generated `new T[n]` remains typed.

## Milestone 6 - Bounds-check options

Add a compiler option in `compiler/compiler.w`:

```
w --bounds=on file.w
w --bounds=off file.w
w --bounds=trap file.w
```

Recommended defaults:

- `on` for debug/test builds and for `make tests`.
- `trap` as the implementation mode for `on`: failed checks branch to an
  inline trap sequence that works without importing `lib.lib`.
- `off` removes generated checks but keeps type-aware scaling.

Checks apply to:

- `T[N][i]`
- `T[][i]`
- `string[i]`
- slice ranges (`start <= end`, `end <= length`)

Checks do not apply to legacy raw pointer `p[i]` in the MVP, preserving current
systems-programming behavior and avoiding unexpected codegen in old programs.

## Milestone 7 - UTF-8 string type and library

Add `string` as a first-class immutable UTF-8 descriptor:

- `s"..."` literals emit:
  - descriptor (`data`, byte length),
  - UTF-8 bytes,
  - trailing NUL for C interop.
- Source escapes:
  - keep existing `\n`, `\t`, `\r`, `\0`, `\xHH`;
  - add `\uXXXX` and `\UXXXXXXXX`, encoded as UTF-8;
  - reject surrogate halves and codepoints above `U+10FFFF`.
- Validate literal bytes at compile time.
- Add `lib/utf8.w`:
  - `utf8_validate(string s)`
  - `utf8_codepoint_count(string s)`
  - `utf8_next(string s, int byte_index)`
  - `utf8_encode(byte[] out, int codepoint)`
  - `string_equals`, `string_starts_with`, `string_ends_with`
  - `cstr(string s)` for strings without interior NUL.
- Rename the current growable `structures/string.w` type to
  `string_builder` or move it behind builder-specific names before reserving
  `string` as a builtin.

Do not make `string[i]` return codepoints. Random byte indexing is predictable
and cheap; codepoint iteration is explicit and can later plug into the
`for x in <container>` plan in `docs/projects/iteration.md`.

## Milestone 8 - Tooling integration

- **REPL**: echo `string` with quotes and escaped invalid display bytes; echo
  `T[]` as `<slice data=... length=...>`.
- **Debugger**: teach local/global printing to decode fixed arrays, slices, and
  strings from descriptors. Keep byte previews bounded, like current `char*`
  previews.
- **Warnings**:
  - `string` to `char*` requires `cstr`.
  - raw pointer to `T[]` requires explicit slice construction.
  - returning a slice of a local array warns once enough local-origin metadata
    exists.
- **Docs**: update `README.md`, `docs/todo.txt`, and `docs/mvp.txt` after the
  feature is implemented.

## Milestone 9 - Tests and verification

Add focused tests before using the new syntax in compiler sources:

- `tests/array_test.w`
  - stack arrays of `char`, `int`, fixed-width ints, floats, and structs;
  - `.length`, `.data`, assignment through indexing;
  - nested scopes and stack addressing;
  - x64 element scaling.
- `tests/slice_test.w`
  - full slices, sub-slices, omitted range bounds;
  - mutation through a slice aliases the source;
  - slice parameters and aggregate returns;
  - heap arrays from `new T[n]`.
- `tests/bounds_test.w`
  - passing in-bounds cases;
  - failing generated binaries under `--bounds=on`;
  - same source under `--bounds=off` where safe to run.
- `tests/string_utf8_test.w`
  - `s"..."` literal byte lengths;
  - `\u`/`\U` encoding;
  - invalid UTF-8 and invalid codepoint compile errors;
  - `cstr`, equality, starts/ends, codepoint iteration.
- Extend `warning_test` for the new conversion warnings.
- Run `make verify`, `make tests`, and `make verify_x64` before any seed
  update. Only after the fixpoint is stable should `make update` promote a seed
  that understands the new syntax.

## Known MVP limitations

- `T[]` is a borrowed descriptor; it does not own memory unless it came from
  `new T[n]` and is freed with the matching helper.
- `string` is immutable by convention; mutable construction goes through
  `string_builder` or `byte[]` plus validation.
- `string.length` is byte length. Codepoint count is explicit and O(n).
- Legacy `"..."` remains `char*` until a separate migration flips it.
- Bounds checks initially cover only new buffer types, not raw pointers.
- No generics: typed heap-array helpers are compiler syntax plus byte-level
  library routines, not reusable generic functions.
- Escape analysis is deferred; returning views of local arrays is documented
  as undefined until warnings land.
