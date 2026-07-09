# Linux-inspired improvements: kernel idioms, atomics, lockless structures

Status: design doc, nothing implemented. Combines two design sessions: a
survey of streams/events/interfaces (which produced the ops-struct vtable
pattern below, verified against `bin/wv2`) and a review of Linux kernel
data structures and APIs worth porting. Items are ordered by
value-to-effort within three tiers: pure library work buildable today,
work gated on atomics support in the compiler, and Linux API wrappers.

## Current state (verified against the tree)

- Everything is single-threaded by design: cooperative tasks
  (`lib/task.w`) over a poll(2) loop (`lib/event_loop.w`). The
  multi-thread prerequisites and their absence are already catalogued in
  `docs/projects/async.md` ("Non-goals").
- `sys_clone` and `thread_exit` wrappers exist in
  `lib/__arch__/x86/syscalls.w` and `x64/syscalls.w`, but there is no
  futex wrapper and no atomic operations anywhere in the language or
  code generators. `tests/threading_test.w` spin-waits on a shared
  global — itself a data race.
- The containers (`structures/linked_list.w`, `hash_table.w`,
  `array_list.w`) are classic non-intrusive single-threaded structures.
  `linked_list` heap-allocates a node per element and carries only a
  word payload.
- Typed function pointers (`type cb = fn(int, int) -> int`) exist and
  are already the callback mechanism in `lib/event_loop.w` and
  `lib/json_rpc.w`.
- There is **no `offsetof` or `sizeof` builtin**. (An earlier note
  claimed `offsetof` existed based on `tests/directory_test.w`; that
  occurrence is inside a comment quoting the getdents man page.)
  However, the classic null-base-pointer trick works today and is
  enough to express `container_of` — verified:

```
int job_link_offset():
	job* base = cast(job*, 0)
	return cast(int, &base.link_next)

job* back = cast(job*, cast(char*, link) - job_link_offset())
```

  A constant-folded `offsetof(type, field)` / `sizeof(type)` builtin
  would still be a nice small compiler feature (type sizes are known at
  compile time via `type_get_size`), but nothing below is blocked on it.

## Tier 1: pure library work, buildable today

### Intrusive lists (`list_head` + `container_of`)

The single highest-value kernel idiom for W. The kernel style embeds the
link in the user's struct instead of allocating a node per element:

```
struct list_head:
	list_head* next
	list_head* prev

struct job:
	int priority
	list_head queue_link
	list_head owner_link   # one object on multiple lists
```

Benefits over `structures/linked_list.w`: zero per-node allocation, one
object can sit on multiple lists simultaneously, and O(1) unlink when
you already hold the node. It is a doubly-linked circular list — about
ten tiny functions (`list_init`, `list_add`, `list_add_tail`,
`list_del`, `list_empty`, `list_for_each`-style cursors for the `for`
protocol) — plus `container_of` as pointer arithmetic over the field
offset. The `hlist` variant (single head pointer, doubly-linked
entries) then gives cheap chained hash buckets.

Proposed home: `structures/intrusive_list.w` (a new file, so no seed
constraint — see "Repo-specific constraints" below).

### Ops-structs as vtables (`file_operations` style)

The kernel's "poor man's interface": a struct of typed function pointers
plus a context pointer. W expresses this today with no compiler changes;
the pattern was verified end-to-end (dynamic dispatch, heterogeneous
`list[shape*]`, mutation through the interface — all passing under
`bin/wv2`):

```
type shape_area_fn = fn(void*) -> int

struct shape_vtable:
	shape_area_fn* area
	shape_scale_fn* scale

struct shape:              # base view: vtable pointer first
	shape_vtable* vt

struct rect:               # concrete type: same first field
	shape_vtable* vt
	int w
	int h

int shape_area(shape* self):
	return self.vt.area(cast(void*, self))
```

Two layouts both work:

- **Embedded vtable pointer** (C++/COM style, above): one-word handles;
  each concrete struct pays a hidden-field slot and opts in at
  definition time.
- **Fat pointer** (Go/Rust style): the interface value is a two-word
  `{void* data, shape_vtable* vt}` pair; concrete structs are untouched
  and can satisfy many interfaces retroactively.

The existing struct-method sugar composes: `s.area()` on a `shape*`
lowers to `shape_area(s)` (`docs/projects/struct_methods.md`), which
dispatches through the vtable — callers get virtual-call syntax today.
`lib/event_loop.w` already does the pattern ad hoc with individual
callbacks; formalizing it as a convention (a `foo_ops*` field, or a
fat-pointer pair, plus `container_of` for downcasting) gets polymorphism
without language work.

What hand-rolling costs, and what a future `interface` feature would
fix: nothing checks that a concrete type actually implements the
interface (a wrong `cast` jumps to garbage); impl functions must take
`void*` and cast to the receiver; vtables are wired manually in
constructors because function addresses cannot appear in global
initializers. A language-level design that fits W: **structural
conformance** over the existing `{type}_{method}` naming (Go's model —
`rect` implements `shape` if `rect_area(rect*) -> int` etc. exist),
compiler-emitted static vtables, fat-pointer interface values, and
slot-offset indirect calls in `grammar/postfix_expr.w` where the
indirect-call type checking already lives. Because W is a whole-program
compiler, all vtables can be emitted statically — Go's ergonomics
without its runtime itab caching. For reference, the design space in
other languages: C++ embeds a hidden vptr (multiple inheritance forces
thunks); Go uses structural fat pointers with lazily cached itabs; Rust
uses explicit `impl` + `dyn` fat pointers, dispatching statically via
monomorphization unless `dyn` is requested; JVM/.NET interface dispatch
needs itable searches/inline caches because embedded-pointer layouts
handle multiple interfaces poorly — another point for fat pointers.

### Intrusive red-black tree

W has hash maps but no ordered container at all. The kernel's intrusive
rbtree (`rb_node` embedded in the user struct, caller-supplied
comparison at insert sites) is the workhorse behind its timers, the CFS
scheduler, and VMA lookup. Here it would back sorted maps/sets,
range queries, and eventually the event-loop timer queue —
`lib/event_loop.w` currently keeps timers in an `array_list` and scans;
fine at today's scale, wrong shape once timer counts grow.

### Bitmaps, bitops, and ID allocation (`idr`/`ida`)

Small utilities that show up everywhere once they exist: find-first-set
and find-next-zero over word arrays (`lib/bitmap.w`), and integer ID
allocation with reuse (ida) for handle tables, fd-like registries, and
allocators. Pure library code, trivially testable.

## Tier 2: gated on atomics (compiler work first)

"Lockless" anything needs atomic instructions, and W currently emits
none. Since the repo owns all backends, this is direct instruction
emission — `lock cmpxchg` / `lock xadd` / `xchg` on x86/x64, LSE
atomics or ll/sc pairs plus barriers on arm64 — exposed as compiler
builtins with function-call syntax:

```
int atomic_cas(int* addr, int expected, int desired)   # returns old value
int atomic_add(int* addr, int delta)                   # returns new value
int atomic_xchg(int* addr, int value)                  # returns old value
int atomic_load(int* addr)
void atomic_store(int* addr, int value)
void fence()
```

Builtin-as-function-call keeps the grammar untouched (no
`tests/parser_generator/w.pg` change needed) but the recognition lives
in seed-compiled code, so the builtins themselves must be implemented
without new syntax until a `./wbuild update`.

That plus a `sys_futex` wrapper (currently absent from all three
`lib/__arch__/*/syscalls.w`) gives the glibc/musl-style userspace mutex
and condvar. Realistically the atomics bundle only pays off together
with an actual threading runtime on top of `sys_clone` (stacks, join,
some TLS story, and the thread-safe-allocator problem — today
`lib/memory.w` is a global free list with racy `brk` growth). Worth
noting: `docs/projects/async.md` deliberately shaped the task/loop API
so a multi-threaded scheduler could slot underneath without changing
task code.

Once atomics exist, the kernel's genuinely simple lockless structures,
in order:

### `llist` — lock-less NULL-terminated singly-linked list

Multi-producer push is one CAS loop; the consumer steals the entire
list with a single `xchg` and processes it privately (reversing if
order matters). About 30 lines, and it is what the kernel actually uses
for cross-CPU deferred work (`irq_work`, vfree deferral). Ideal first
lockless structure: no ABA problem on the push path, no reclamation
problem because the consumer owns everything it stole.

### `kfifo`-style SPSC ring buffer

Single-producer single-consumer ring over a power-of-two buffer needs
only atomic load/store and barriers — no CAS at all. Perfect for a
thread-pool work queue or a cross-thread log channel.

### Explicit non-goals: lockless hash maps and RCU

RCU needs quiescent-state tracking machinery that is a project in
itself, and even the kernel mostly protects hash tables with per-bucket
spinlocks rather than lockless designs. A futex mutex per bucket gets
~95% of the benefit with none of the reclamation hazards. Revisit only
if profiling a real multi-threaded workload demands it.

## Tier 3: Linux API wrappers

- **epoll**, and eventually **io_uring**, are already called out in
  `docs/projects/async.md` as invisible backend swaps inside
  `lib/event_loop.w` (poll(2) is O(n) per iteration but n is small
  today).
- **timerfd / eventfd / signalfd / pidfd** deserve to join that list:
  they turn timers, cross-task wakeups, signals, and child-process exit
  into ordinary pollable fds, which simplifies the event loop (timers
  stop being a special-cased `array_list`; `lib/process.w` waiting
  stops needing poll-timeout loops) and composes with tasks for free.
- **io_uring** is the most interesting long-term: completion-based,
  batches syscalls, a natural fit for the task runtime. But its mmap'd
  submission/completion rings require memory barriers — so it, too,
  lands after the atomics builtins.

## Repo-specific constraints

- `structures/hash_table.w` and `structures/w_list.w` are auto-imported
  into every program and compiled by the committed seed, so changes to
  them cannot use new language syntax until a `./wbuild update`. Everything
  proposed here lands in **new files** (`structures/intrusive_list.w`,
  `structures/rbtree.w`, `lib/bitmap.w`, `lib/atomic.w`, ...) which
  have no such restriction — though anything the compiler itself would
  consume must stay seed-compatible.
- Atomics builtins touch `grammar/` + `code_generator/` (seed-compiled);
  keeping them function-call-shaped avoids grammar and `w.pg` changes.
- New containers should implement the four-function cursor protocol
  (`<type>_iter_begin/done/next/value`, `docs/projects/iteration.md`)
  so `for x in ...` works over them.

## Suggested sequencing

1. `structures/intrusive_list.w` (`list_head` + `container_of` +
   `hlist`) — pure library, immediately useful across the compiler and
   stdlib, commits to nothing on the threading front.
2. Formalize the ops-struct/vtable convention (doc + one or two
   adopters, e.g. a pluggable `wstream` backend or event-loop source);
   revisit a language-level `interface` once the pattern's boilerplate
   is measured in practice.
3. `structures/rbtree.w`, then port the event-loop timer queue to it.
4. `lib/bitmap.w` + ida.
5. The atomics bundle (builtins on all three backends + `sys_futex` +
   futex mutex/condvar + `llist` + SPSC ring) as one project, when
   multi-threading is actually on the table.
6. timerfd/eventfd/signalfd/pidfd wrappers; epoll swap; io_uring last.
