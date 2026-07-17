# Iteration & Generators Design: `for x in <container>` and `yield`

Status: both halves are implemented. Design 3 (the cursor/iterator
function convention) is the iteration protocol: `for x in <container>`
compiles in `grammar/for_statement.w` via the cursor lowering below, the
four `_iter_*` functions exist for `array_list`, `linked_list` and
`hash_map` (keys), and user-defined containers work by defining the same
four functions (`tests/for_container_test.w`, `./wbuild for_container_test`).
Steps 3-4 of the recommendation at the bottom are done.

Generators (steps 1-2 and 5) are implemented as stackful coroutines
(model A): `generator int counter(int n)` declarations parse in
`grammar/program.w` + `grammar/generator_decl.w`, `yield` in
`grammar/statement.w`, the runtime (`gen_next`/`gen_value`/`gen_done`/
`gen_free` plus the `generator_iter_*` cursor adapters) lives in
`lib/generator.w`, and the `gen_switch` context-switch stub is emitted
by `code_generator/x86_asm.w` and `x64_asm.w` (both targets work).
Implementation decisions: 64KB mmap'd generator stacks (not the 4MB
thread stack); programs must `import lib.generator` before declaring or
calling a generator (compile error otherwise — no auto-import);
`return <value>` inside a generator body is a compile error, plain
`return` finishes the generator; the exhausted body's stack is
munmap'd automatically by `gen_next`, `gen_free` releases an abandoned
generator; break-cleanup option (b) shipped — `for` over a generator
emits `gen_free` on the normal-exit and break edges, and `return`
(plus `?` error propagation) out of the loop body frees every
enclosing generator loop's suspended generator too, via the
`for_cleanup` registry in `grammar/for_statement.w`: each generator
loop registers its hidden container slot while its body parses, and
the function-exit paths in `grammar/statement.w` walk the registry
(innermost loop first, before deferred statements, with the pending
return value saved around the calls) before unwinding — including
`return` inside a generator body that is itself iterating another
generator. Hand-driven `while gen_next(g)` consumption still requires
an explicit `gen_free`. Parameters and yield values must be
word-sized. Tests: `tests/generator_test.w` (`./wbuild generator_test`,
`./wbuild generator_64_test`) and `tests/generator_return_free_test.w`
(early-exit cleanup, leak-asserted against `/proc/self/statm`). The
generators half is kept here because the two features share their
consumption syntax, their cleanup problems, and one loop lowering.

Supersedes the iteration notes at the bottom of `docs/for_notes.txt`
(manual range struct, "generator functions", "store generator stack in
parent function"); those ideas are folded into designs 4 and 5 and the
generators part below.

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
- Depends on the coroutine machinery from the generators half of this
  document (fresh stack per generator via `stack_create`-style mmap,
  context switch stubs in `code_generator/x86_asm.w`). Each loop pays a
  stack allocation and two context switches per element.
- Early `break` must free the suspended generator's stack — same
  cleanup problem as design 4, worse because the resource is an mmap.
- Verdict: right long-term *addition*, wrong *foundation*: containers
  should stay iterable without paying coroutine overhead. But see
  "Generators as cursor implementors" below — with the cursor protocol
  as the base, generators plug into the same `for` lowering without a
  second loop shape in the compiler.

## Generators (`yield`)

The other half of this design. A generator is a function whose body can
suspend at `yield expr`, hand a value to its consumer, and resume where
it left off:

```
generator int counter(int n):
	int i = 0
	while (i < n):
		yield i
		i = i + 1
```

### Why the declaration must be marked

The compiler is single-pass: by the time it could discover a `yield`
inside the body, the function's call convention and prologue are already
emitted. Python infers generator-ness from the presence of `yield`; W
cannot. So the property is declared up front — `generator int name(args)`
— parsed in `grammar/program.w` where `type_name identifier (` is parsed
today. Calling a generator function then *creates* a generator object
instead of running the body; only resuming runs body code.

### Execution models considered

- **A. Stackful coroutine (recommended).** Each generator object owns a
  private stack (mmap, like the existing `stack_create` stub used by
  `thread_create` in `code_generator/x86_asm.w`). `yield` and resume are
  a context switch: save esp on one side, restore on the other, jmp.
  This is the only model that lets `yield` appear at arbitrary depth in
  loops and nested blocks with zero control-flow analysis — the machine
  stack *is* the saved state, which is exactly what a no-AST single-pass
  compiler can afford.
- **B. State-machine transform (rejected).** Compile the body into a
  resumable switch over saved locals (what C# / Rust / Python bytecode
  effectively do). Requires knowing every local and every suspension
  point before emitting code — a second pass and an AST that W does not
  have. The seed compiler could not bootstrap it incrementally either.
- **C. Callback inversion (rejected).** `array_list_each(l, f)` taking a
  function pointer per element. No new machinery, but the body of the
  loop stops being a block in the caller (no access to caller locals —
  W has no closures), and `break`/early-exit needs an out-of-band
  protocol. Not really a generator at all.

### Generator object and stubs

A fixed-layout heap struct, allocated by the generator *call*:

```
struct generator:
	int resume_esp     # suspended stack pointer (generator side)
	int caller_esp     # stack pointer to switch back to (consumer side)
	int value          # last yielded word
	int done           # 1 once the body returned / fell off the end
	int stack_base     # mmap base, freed when done (munmap)
```

Runtime pieces, all ordinary W plus small asm stubs (in the spirit of
`repl_setjmp`/`repl_longjmp`, and bootstrap-safe because the compiler
itself never uses generators — the seed only compiles the stub-emitting
code):

- `gen_switch(int* save_esp_here, int restore_esp)` — push
  callee-saved registers, store esp through the first argument, load the
  second into esp, pop registers, ret. One stub serves both directions
  (yield and resume are symmetric).
- Generator call lowering: allocate the object, `stack_create()` a
  fresh stack, seed its top with a small trampoline frame that calls the
  body with the declared arguments copied over, and return the object
  pointer *without running the body* (first resume starts it).
- `yield expr` (new statement in `grammar/statement.w`, only legal
  inside a `generator` body): store eax into `g.value`, then
  `gen_switch(&g.resume_esp, g.caller_esp)`.
- Body return / falling off the end: set `g.done = 1`, switch back to
  the caller permanently. The epilogue frees the generator stack —
  which requires an `munmap` wrapper in `lib/linux.w` (syscall 91), the
  one OS piece missing today.
- The generator needs a way to reach its own object from inside the
  body; simplest is a hidden extra argument (the object pointer) pushed
  by the trampoline frame, addressed like a normal parameter.

### Consumption

Explicit helpers first — usable from a plain `while` loop, no grammar
change beyond `generator`/`yield` themselves:

```
int gen_next(generator* g)    # switch into the body; returns !g.done
int gen_value(generator* g)   # last yielded value
int gen_done(generator* g)    # 1 when finished
void gen_free(generator* g)   # munmap the stack + free the object
                              # (for abandoning a generator early)

generator* g = counter(5)
while (gen_next(g)):
	print_int("got: ", gen_value(g))
```

### Generators as cursor implementors

This is where the two halves meet, and the reason to build them
together. The cursor protocol (design 3) asks for four functions named
after the iterable's struct type. The `generator` struct is a named
struct type — so the library can provide, once:

```
int generator_iter_begin(generator* g):   return gen_next(g)
int generator_iter_done(generator* g, int cur):   return cur == 0
int generator_iter_next(generator* g, int cur):   return gen_next(g)
int generator_iter_value(generator* g, int cur):  return gen_value(g)
```

and `for int x in counter(5):` compiles through the *same* cursor
lowering as `for int x in my_list:` — the compiler never learns what a
generator is beyond "a struct type with `_iter_*` functions". One loop
shape in `for_statement.w` covers containers and coroutines; that is
the payoff of choosing design 3 as the foundation.

(The cursor word is unused by generators — the object carries its own
state — which is fine: the protocol treats the cursor as opaque, and
here "opaque" means "ignored, the continuation lives in `resume_esp`".)

### Generator-specific questions

- **Early exit / leaks.** `break` out of `for x in counter(5):` leaves a
  suspended generator holding a 4MB mapping. Options: (a) accept the
  leak and require explicit `gen_free` when breaking (document it); (b)
  have the `for` lowering track that its iterable was a generator and
  emit `gen_free` on the break/exit edges — doable, since break already
  patches a jump chain per loop (`loop_break_chain`); (c) shrink the
  cost instead: allocate small generator stacks (64KB) so leaks are
  cheap. Leaning: (b) for `for` loops, (a) for hand-driven `while`
  consumption. Landed as (b) plus a registry for the exits the loop's
  own edges cannot see: `return` and `?` walk the enclosing generator
  loops' hidden container slots (`for_cleanup` in
  `grammar/for_statement.w`) and free each one before the frame
  unwinds; (a) remains the rule for `while gen_next(g)` consumers.
- **Stack size.** `stack_create` maps 4MB like threads. Generators
  yielding scalars need far less; a size parameter (or a second
  `stack_create_sized` stub) keeps hundreds of live generators viable.
- **Nested generators.** A generator that consumes another generator
  works naturally with stackful coroutines (each has its own stack);
  `yield from` style delegation is just a `while gen_next(inner): yield
  gen_value(inner)` loop, no special support needed for the MVP.
- **Threads.** `caller_esp`/`resume_esp` make a generator single-consumer;
  resuming one generator from two threads is undefined. Fine to document
  and ignore until the threading modules are in better shape.
- **REPL.** Generators created on REPL lines run in the same in-process
  buffer as everything else; nothing extra needed, but `gen_free`
  discipline matters more in a long-lived process.

## Shared concepts (why one design doc)

| concern | containers (cursor) | generators |
|---|---|---|
| consumption syntax | `for x in c:` | same, via `generator_iter_*` |
| loop lowering | one cursor loop in `for_statement.w` | reused as-is |
| state location | hidden stack slot (cursor word) | private stack + object |
| `break` cleanup | nothing to do (stack slots pop) | must free stack (question above) |
| element typing | word-sized, unchecked | word-sized, unchecked (`g.value`) |
| mutation hazards | do not mutate while iterating | body and consumer interleave by design |
| user extension | write four `_iter_*` functions | write a `generator` function |

The protocol decision (design 3) is what makes the generator work
additive instead of a fork: without it, generators would need their own
`for` lowering (the design-5 resume loop) and the compiler would carry
two iteration shapes forever.

## Cross-cutting questions

- **hash_map keys vs values.** Landed: `for K k, V v in m` parses an
  optional second `typed_identifier` after a comma
  (`grammar/for_statement.w`), and the map cursor exposes value-at-cursor
  access so both key and value are read in one probe per bucket. Tested
  in `tests/map_set_builtin_test.w`.
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
iteration protocol and **stackful coroutines (model A)** for generators,
built as one staged effort so generators land as cursor implementors
rather than a second iteration mechanism:

1. **Runtime plumbing** (no grammar changes): `munmap` wrapper in
   `lib/linux.w`, `gen_switch` context-switch stub, generator object
   struct + `gen_next`/`gen_value`/`gen_done`/`gen_free` in a new
   `lib/generator.w`. Testable with a hand-built generator (assembled
   trampoline) before any syntax exists.
2. **`generator` + `yield` syntax**: declaration marker in
   `grammar/program.w`, `yield` statement in `grammar/statement.w`
   (compile error outside a generator body), call lowering that
   allocates the object instead of running the body. Tests drive
   generators with the explicit `while gen_next(g)` loop — no `for`
   changes yet. Bootstrap-safe: compiler sources never use the new
   keywords.
3. **Cursor protocol in `for`**: `for_statement.w` keeps the
   `expect("range")` fast path; otherwise parses `expression()` and
   emits the cursor loop. `array_list_iter_*` first (index cursor),
   tests mirroring `tests/range_test.w` (basic, empty, break/continue,
   nested).
4. **Containers**: `linked_list_iter_*` (node cursor) and
   `hash_map_iter_*` (bucket-scan cursor, keys first) plus tests.
5. **Unification**: `generator_iter_*` in `lib/generator.w` makes
   `for int x in counter(5):` work through the existing lowering;
   decide the break-cleanup question (leaning: emit `gen_free` on the
   loop's exit edges when the iterable's static type is `generator`).
   Two-variable `for k, v in map` landed alongside this (see
   "Cross-cutting questions" above).

Steps 1-2 and 3-4 are independent and can land in either order; step 5
needs both. Design 1 is acceptable as a temporary shortcut only if step
3 proves harder than expected, but the mangled-name lookup is the same
work either way, so there is little reason to stop at fields.
