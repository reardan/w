# Built-in Hash Maps and Sets

Design and implementation notes for Python-like hash maps and sets in W.

## Goals

The MVP adds typed, heap-backed hash containers:

```
map[char*, int] counts = new map[char*, int]
counts["red"] = 3
if ("red" in counts):
	print_int("red: ", counts["red"])

set[int] seen = set[int]{1, 2, 3}
if (2 in seen):
	println("seen")
```

Maps and sets are reference values. Assigning a map variable copies the
container pointer, not the entries.

## Syntax

- `map[K, V]` is a map from key type `K` to value type `V`.
- `set[K]` is a set of keys of type `K`.
- `new map[K, V]` and `new set[K]` allocate empty containers.
- `map[K, V]{k: v, ...}` and `set[K]{v, ...}` allocate and populate literals.
- `m[k]` returns the value for `k`; missing keys are an error.
- `m[k] = v` inserts or overwrites.
- `k in m` and `k in s` test membership and return `bool`.
- `.length` returns the number of live entries.
- `for K k in m` iterates map keys; values are read with `m[k]`.
- `for K k in s` iterates set members.

Bare contextual literals (`map[char*, int] m = {"a": 1}`), `for k, v in m`,
and small static literal tables are deferred.

## Runtime layout

The runtime uses open addressing with linear probing, power-of-two capacity,
and growth before the table reaches 75% load. Slot states are:

- `0`: empty
- `1`: live
- `2`: tombstone

The first implementation stores word-sized key and value payloads in parallel
arrays. Smaller scalar values occupy the low bits of a word. Larger aggregate
values should be added by extending the value array to byte-addressed storage
and copying `type_get_size(V)` bytes at set/get boundaries.

## Keys and ownership

MVP key kinds:

- word identity: integers, bools, and non-string pointers
- `char*`: hash and compare bytes with `strcmp`; clone on insert
- `string`: hash and compare descriptor contents; clone descriptor and bytes

The table owns cloned string keys and frees them with the container. Word
identity keys are stored as-is.

## Compiler integration

The compiler type table owns the static type metadata:

- `type_kind_map`
- `type_kind_set`
- key type
- value type for maps

Parser and codegen hooks lower syntax directly to runtime helper calls. W is a
single-pass compiler, so map indexing is represented as a short-lived pending
pseudo-lvalue: read contexts call the get helper, while assignment contexts call
the set helper.

The compiler source must remain buildable by the committed seed compiler. New
map/set syntax is allowed in tests and runtime consumers after `bin/wv2` is
built, but not in `compiler/`, `grammar/`, or `code_generator/` sources before
a seed update.

## Deferred work

- Full aggregate value copying for values larger than one word.
- Contextual bare literals.
- Rich pseudo-methods such as `get`, `get_default`, `discard`, and `clear`.
- Pair iteration after W has tuple or multiple loop-variable support.
- Migrating compiler symbol/type tables to built-in maps.
