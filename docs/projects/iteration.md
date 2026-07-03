# Iteration Design: `for x in <container>`

Status: design / brainstorm. Nothing here is implemented; this document
exists so a later change can extend `for` beyond `range` with a protocol
that eventually covers `array_list`, `linked_list`, `hash_map`, and
user-defined containers — not just the easy array case.

Supersedes the iteration notes at the bottom of `docs/for_notes.txt`
(manual range struct, "generator functions", "store generator stack in
parent function"); those ideas are folded into designs 4 and 5 below.

## Problem statement

Today `for` is hard-wired to `range`: `grammar/for_statement.w` does
`expect("in")` then `expect("range")`, evaluates 1-3 range arguments into
hidden stack slots, and emits a compare/increment loop against them.

We want:

```
for int x in my_list:
	print_int("x: ", x)
```

Constraints that shape every design:

- **Single-pass compiler, no AST.** Code is emitted while parsing; the
  iterable expression is seen exactly once, before the body. Whatever
  state the loop needs must be evaluated up front into hidden stack
  slots, exactly like the range arguments are today.
- **No generics.** Every container stores word-sized values (`int` or a
  pointer held in one). The loop variable's declared type cannot be
  checked against an element type the container does not carry.
- **No methods.** There is only struct field access (`postfix_expr.w`
  computes field offsets) and free functions in modules. Any "protocol"
  is either a field-shape convention or a function-name convention.
- **Three container shapes with incompatible access patterns:**

| container | length | element access | natural cursor |
|---|---|---|---|
| `array_list` | `.length` field | `.items[i]`, O(1) | index |
| `linked_list` | `.length` field | `linked_list_get` walks from head, O(n) | node pointer |
| `hash_map` | `.count` field | sparse: slot `i` may be empty | bucket index (skip empties) |

## Candidate designs

### 1. Duck-typed fields (`length` + `items`)

The compiler requires the iterable's struct type to have `length` and
`items` fields and lowers to an index loop:

```
# for int x in list:            lowers to roughly
# hidden: [list_ptr][index=0]
# cond:   index < list.length
# body:   x = list.items[index]
# step:   index = index + 1
```

- Codegen is a small variation of the existing range loop; the type
  table already answers "does this struct have field F" via
  `type_get_arg`.
- **Locked to arrays.** `linked_list` has no `items`; `hash_map.keys` is
  sparse, so indexing it directly yields empty slots. Both would only
  work by materializing a temporary `array_list` copy, which allocates
  and is O(n) extra memory per loop.
- Verdict: fine as a first cut, dead end as *the* protocol.

### 2. Index/get function convention

The compiler name-mangles the iterable's struct type name into calls:
`<type>_length(c)` and `<type>_get(c, i)`. `array_list_get` and
`linked_list_get` already exist with exactly this shape.

- Works today for `array_list` and `linked_list` with zero new library
  code, and symbol lookup by constructed name is easy
  (`sym_get_value(strjoin(type_name, "_get"))`).
- **O(n^2) for linked_list**: `linked_list_get` walks from the head on
  every step.
- **hash_map does not fit**: there is no dense index. A
  `hash_map_get_index(map, i)` would have to skip empty buckets on every
  call — another O(n^2) — or the map would need a separate dense key
  array maintained on insert (memory cost, and `hash_map_grow`
  reshuffles slots).
- Verdict: attractive shortcut that punishes exactly the containers we
  most want to add later.

### 3. Cursor/iterator function convention (preferred)

Each container module provides four functions named after its struct
type. The cursor is a single word whose meaning is private to the
container:

```
int  <type>_iter_begin(c)         # first cursor value
int  <type>_iter_done(c, cur)     # 1 when cur is past the end
int  <type>_iter_next(c, cur)     # cursor after cur
int  <type>_iter_value(c, cur)    # element at cur
```

Per container:

- `array_list`: cursor is the index. begin=0, done=`cur >= length`,
  next=`cur + 1`, value=`items[cur]`.
- `linked_list`: cursor is the node pointer. begin=`head`, done=
  `cur == 0`, next=`cur.next`, value=`cur.data`. O(1) per step — fixes
  the O(n^2) problem design 2 has.
- `hash_map`: cursor is the bucket index. begin=first non-empty bucket,
  next=scan forward to the next non-empty bucket, done=`cur >= capacity`,
  value=`keys[cur]` (see the key/value question below). Whole-loop cost
  is O(capacity), the best possible without extra bookkeeping.
- `range` itself could be re-expressed as a cursor (`begin=start`,
  `next=cur+step`), though keeping the existing inline lowering is
  faster and costs nothing.

Lowering (single pass, mirrors the range loop's hidden-slot pattern):

```
# for int x in expr:
#   hidden slots: [x][container][cursor]
#   container = expr                        (evaluated once)
#   cursor = <type>_iter_begin(container)
# cond:
#   if <type>_iter_done(container, cursor): exit
#   x = <type>_iter_value(container, cursor)
#   ...body...
# step (continue lands here):
#   cursor = <type>_iter_next(container, cursor)
#   jmp cond
```

The parser knows the iterable's static type from `expression()`, so it
can resolve all four symbols at compile time with the existing
undefined-symbol backpatching (`'U'` symbols) when the container module
is imported later in the file. A missing function becomes a clear
compile error: `"type 'foo' is not iterable: foo_iter_begin not found"`.

- O(n) for all three containers, no allocation, no new runtime
  machinery, cursor lives in one hidden stack slot so `break`'s existing
  unwinding (`be_pop` down to `loop_stack_pos`) keeps working.
- User-defined containers become iterable by defining four small
  functions — no compiler change.
- Cost: four functions per container (~20 lines each), and the compiler
  must build mangled names, which needs care around `strjoin`/`free` in
  the parser hot path.
- Limitation: the iterable must be a named struct pointer type. Raw
  `int*` buffers stay with `for i in range(n)`.

### 4. Iterator struct with function pointers

A `struct iterator { int state; int* next_fn; int* done_fn; ... }`
returned by `<type>_iter(c)`; the loop calls through the function
pointers. This is the runtime-dispatch version of design 3.

- Most general: the loop codegen would not need the static type at all,
  and one compiled loop could iterate anything.
- But: W function-pointer typing is weak (indirect calls skip arity and
  type checks in `postfix_expr.w`), struct values cannot be returned by
  value (`docs/todo.txt` limitation), so the iterator must be heap
  allocated and freed — including on `break`, which currently only pops
  stack words and would leak the iterator. Indirect calls also cost more
  per element.
- Verdict: strictly more machinery than design 3 for a benefit
  (heterogeneous dispatch) W's static-typing style does not need yet.

### 5. Generator-based iteration

Containers expose generator functions (`array_list_values(l)`,
`hash_map_keys(m)`, `hash_map_values(m)`), and `for x in <expr>` where
the expression evaluates to a generator object lowers to a resume loop:

```
# g = expr
# loop: gen_next(g); if g.done: exit; x = g.value; ...body...
```

- The most Python-like end state: one loop syntax consumes containers,
  generators, and any user function containing `yield`. Iteration logic
  is written once per container as a straight-line function instead of
  four cursor callbacks.
- Depends on the coroutine machinery from the generators project
  (fresh stack per generator via `stack_create`-style mmap, context
  switch stubs in `code_generator/x86_asm.w`). Each loop pays a stack
  allocation and two context switches per element.
- Early `break` must free the suspended generator's stack — same
  cleanup problem as design 4, worse because the resource is an mmap.
- Verdict: right long-term *addition*, wrong *foundation*: containers
  should stay iterable without paying coroutine overhead.

## Cross-cutting questions

- **hash_map keys vs values.** W has no tuples, so `for k, v in map`
  needs either two loop variables (grammar change: parse an optional
  second `typed_identifier` after a comma) or a decision that `for k in
  map` yields keys and the body calls `hash_map_get(map, k)` (an extra
  probe per element). The cursor design has a third option: expose
  `hash_map_iter_value_at(map, cur)` alongside key access so both are
  O(1) at the current bucket. Leaning: keys-only first; two-variable
  syntax later without breaking anything.
- **Loop variable typing.** Containers store words, so `for int x in
  list` cannot be checked deeper than "word-sized". When the language
  gains generics or element-type metadata on the container struct, the
  cursor protocol can grow a `<type>_iter_value` return-type check; the
  syntax does not change.
- **break/continue cleanup.** Designs 1-3 keep all loop state in hidden
  stack slots, so the existing `loop_stack_pos` unwinding just works.
  Designs 4-5 hold heap/mmap resources and need a cleanup hook on every
  exit edge — a strong argument for 1-3 as the base protocol.
- **Mutation during iteration.** `array_list_push` may `realloc`
  `items`, and `hash_map_set` may grow and reshuffle buckets while a
  loop is walking them. Every design here has this problem; document
  "do not mutate while iterating" rather than paying for versioned
  cursors.
- **Nested loops over the same container.** Cursors are per-loop stack
  slots, so nesting works in designs 1-3 without aliasing issues.
- **Does `range` fold into the protocol?** It could (design 3), but the
  current inline lowering is already optimal and heavily tested; keep it
  special-cased.

## Recommendation

Adopt **design 3 (cursor/iterator function convention)** as the
iteration protocol, staged:

1. `for_statement.w`: keep `expect("range")` fast path; otherwise parse
   `expression()` as the iterable and emit the cursor loop above.
   Implement `array_list_iter_*` first (index cursor) with tests
   mirroring `tests/range_test.w` (basic, empty, break/continue,
   nested).
2. Add `linked_list_iter_*` (node cursor) and `hash_map_iter_*`
   (bucket-scan cursor, keys first) plus tests.
3. When generators land, extend the same `for` lowering to accept
   generator objects (design 5) as a second iterable kind, and revisit
   two-variable `for k, v in map`.

Design 1 is acceptable as a temporary shortcut only if step 1 proves
harder than expected, but the mangled-name lookup in step 1 is the same
work either way, so there is little reason to stop at fields.
