# Map default-value factory / nested auto-vivification (issue #327)

Design pass for issue #327, a narrowed respawn of #152. This is a
**design-only** document: it lays out the current state, the three
candidate surfaces the issue names, a recommendation, and a test/
diagnostics plan. No implementation lands here.

## Recap: what's already shipped, what's still missing

#152 asked for Python's `defaultdict`. Its triage (read in full while
writing this doc) split it into two halves and closed the first:

- **`defaultdict(int)` — the counter use case — fully shipped.**
  `m.add(key[, delta])` accumulates from zero for missing keys (#179/
  #182), `m.get(k, default)` reads without inserting, `m.keys()`/
  `m.values()` give insertion-order `list[K]`/`list[V]` snapshots
  (#187).
- **`defaultdict(defaultdict(int))` — the nested/factory case — still
  missing.** Indexing a missing key cannot *materialize* a default
  value (a freshly-constructed inner map, in the nested example); `m[k]`
  on a missing key traps by design, and that trap is documented
  (`docs/projects/hash_maps_sets.md`: "`m[k]` returns the value for
  `k`; missing keys are an error") and tested (`container_trap_test`,
  covering `tests/map_trap_fixture.w` / `tests/map_trap_int_key_fixture.w`).

This doc is scoped to the second half only: a **default-value factory**,
called per missing key, whose result both satisfies the read and gets
stored back into the map (auto-vivification) — as opposed to a **default
value**, which #152's triage already distinguished as a separate, easier
question that `m.get(k, default)` mostly answers today (it does not
insert; see below).

## 1. Current state

### How `m[k]` get/set/trap lowers

W is single-pass with no AST (see `docs/projects/hash_maps_sets.md`).
When the parser sees `m[` on a map-typed expression, `postfix_expr()`
(`grammar/postfix_expr.w:492-514`) does *not* immediately decide
read-vs-write: it evaluates the map pointer and key into two parked
stack slots (`hash_index_map_slot`, `hash_index_key_slot`) and sets a
global flag, `hash_index_pending = 1`. This "pending pseudo-lvalue" is
resolved later in `expression()` (`grammar/expression.w:127-139`), which
looks at what follows the closing `]`:

- `=` → `hash_finish_pending_assignment()` (`grammar/hash_builtin.w:88-124`):
  parses the rhs, then calls `__w_map_set` (or `__w_map_set_bytes` for
  struct values) with the parked map/key slots plus the new value.
- a compound-assign operator (`+=`, `-=`, ...) → `hash_finish_pending_compound()`
  (`grammar/hash_builtin.w:131-181`): loads the current value via
  `__w_map_get` (the **same trapping call as a plain read** — see the
  comment at `grammar/hash_builtin.w:127-130`, and confirmed by probe
  below), applies the op via the scalar `compound_assign_apply`, and
  stores back via `__w_map_set`.
- anything else (a plain read) → `hash_finish_pending_read()`
  (`grammar/hash_builtin.w:63-85`): calls `__w_map_get` (or
  `__w_map_get_addr` for struct values).

Both `__w_map_get` and `__w_map_get_addr`
(`structures/hash_table.w:354-368`) probe the slot and, if it's not
live, call `__w_map_missing_key()` (`structures/hash_table.w:100-110`),
which prints `map key not found: <key>`, a stack trace, and calls
`exit(1)`. There is no way to reach a map read without going through one
of these two functions or the explicitly-defaulting `__w_map_get_or*`
family — the trap is the only path for a bare `m[k]` or `m[k] op= v`.

Verified live (not just by reading the source): compiling and running

```w
map[char*, map[char*, int]] outer = new map[char*, map[char*, int]]
map[char*, int] inner = new map[char*, int]
inner[c"a"] = 1
outer[c"x"] = inner
print_int("inner a: ", outer[c"x"][c"a"])   # inner a: 1
int y = outer[c"missing"][c"a"]             # traps
```

compiles cleanly (no warnings — nested map *types* are fully legal and
type-check today) and the last line traps exactly as the #152 triage
comment described:

```
map key not found: missing
stack trace (most recent call first):
  at __w_map_missing_key (structures/hash_table.w:109)
  at __w_map_get (structures/hash_table.w:357)
  at main (...:10)
```

So: **map-of-map is fully expressible as a type today** (`type_get_map`
canonicalizes and dedupes by `(key_type, value_type)` regardless of what
`value_type` is), it's just that nothing ever constructs the inner map
for you.

### How `m.add` lowers

`hash_map_add_suffix()` (`grammar/hash_builtin.w`) rejects struct and
float16 value types up front (`"map add requires an integer or float
value type"` / `"map add does not support float16 values"`, pinned by
`tests/map_add_error_fixture.w` / `tests/map_add_float16_error_fixture.w`
in `build.base.json`). Integer values lower to `__w_map_add(map, key,
delta)` (`structures/hash_table.w`), which does
`slot[0] = slot[0] + delta` on the (zero-initialized-on-allocation)
value slot after `__w_map_insert_slot` finds-or-inserts it — no trap,
because it never reads through `__w_map_get`. Float values (float32
everywhere, float64 on x64; issue #189, decided 2026-07) lower in the
grammar to `__w_map_get_or(map, key, 0)` + a float add + `__w_map_set`
— see `docs/projects/hash_maps_sets.md`, "Accumulation (`m.add`)".

### How `m.get(k, default)` lowers

`hash_get_suffix()` (`grammar/hash_builtin.w:331-385`) branches on
whether a second argument was parsed. With no default it's the same as
`m[k]` (`__w_map_get` / `__w_map_get_addr`, traps). With a default it
calls `__w_map_get_or` (scalars) or `__w_map_get_or_addr` (structs)
(`structures/hash_table.w:372-386`), which probe the slot and return the
default **without ever calling `__w_map_insert_slot`** — confirmed by
reading the function bodies: neither touches `table.states`,
`table.count`, or the insertion-order chain. So today's `.get(k,
default)` is Go's `v, ok := m[k]` (read-only), not Python's auto-vivifying
`d[k]` — the #152 triage's framing, verified against the current source
rather than taken on faith.

### How value types are tracked

`compiler/type_table.w` stores one type record per distinct
`(key_type, value_type)` pair for maps (`type_kind_map()` = 10;
`type_push_map` / `type_lookup_map`, `compiler/type_table.w:281-293,
655-662`), deduplicated by `type_canonical` key/value. Field offsets
(word-indexed into the flat type record):

| offset | field | notes |
|---|---|---|
| 204 | key type | container types reuse this field name for both maps and sets |
| 205 | kind | `type_kind_map()`/`type_kind_set()`/`type_kind_list()` |
| 206 | value type (maps only) | `-1` for sets/lists |
| 207 | unused (`-1`) | see "declaration-site annotation" below |

`type_is_map`/`type_is_set`/`type_is_list` (`compiler/type_table.w:498-508`)
just compare `type_get_kind()` against the three container kind
constants, so **checking whether a map's *value type* is itself a
container is a one-line, already-exposed check**
(`type_is_map(value_type) | type_is_set(value_type) |
type_is_list(value_type)`) — no new type-table plumbing needed for that
part. Struct-ness is a separate, already-distinct check
(`type_num_args(value_type) > 0`; container type records always have
`num_args == 0`, set at `type_push_map`/`_set`/`_list` time), so a
"value type is a nested container" test can never collide with the
existing "value type is a struct" branch that `hash_finish_pending_read`/
`hash_get_suffix` already use to pick the `_addr`-returning helpers.

Field 207 is unused on every container kind today (verified by reading
`type_push_map`/`type_push_set`/`type_push_list`) — it's a free word per
type record that a declaration-site design (see below) could repurpose
without growing `type_size()`, *if* what it needs to store is another
type-table index (a function-signature type for the factory) rather
than a runtime value (an actual function pointer, which varies per
container instance, not per type, and belongs on the `__w_hash_table`
struct instead — see Surface A below).

### `new`/literal construction has no notion of a factory today

`new map[K, V]` and `new set[K]` lower via `hash_emit_new_container()`
(`grammar/hash_builtin.w:43-60`) to `__w_map_new(key_kind, value_size)` /
`__w_set_new(key_kind)`; there is no argument list. Probed directly:
`new map[char*, int](5)` is a **parse error** today (`"';' expected,
found '('"`) — `unary_expression.w:230-241` returns immediately after
`hash_emit_new_container()` without checking for a trailing `(`, even
though `tests/parser_generator/w.pg`'s `new_tail` rule
(`new_tail = LPAREN arg_list RPAREN | LBRACK expression RBRACK |`) is
generic across all `new type_ref` forms and would already accept the
tokens — the coverage grammar is looser than the real compiler here, a
gap worth noting for whoever picks this up (not itself a #327 blocker,
but means a `new map[K, V](factory)` surface needs a
`tests/parser_generator/w.pg` conformance check, not just an
`unary_expression.w` change, if the fixture parser is expected to accept
the same programs the real compiler does).

## 2. The three candidate surfaces

### Surface A — declaration-site factory: `map[K, V] m = map_default(...)`

**Syntax.** The issue's own phrasing is closest to a call-like
expression that produces a specially-flagged map, e.g.

```w
map[char*, int] counts = map_default[char*, int](0)
map[char*, map[char*, int]] nested = map_default[char*, map[char*, int]](fn_new_inner)
```

or, reusing the existing `new` spelling instead of inventing a second
constructor keyword:

```w
map[char*, int] counts = new map[char*, int](0)
map[char*, map[char*, int]] nested = new map[char*, map[char*, int]](fn_new_inner)
```

The `new map[K, V](...)` spelling is more consistent with how W already
treats `new type-name(args)` for structs (field-initializer args) and
avoids adding a second container-construction keyword next to
`map`/`set`/`list`/`new`. The argument would be one of:

- a scalar/struct **default value**, for `V` that is a plain scalar or
  struct (Go-like: every missing key reads as the same stored value,
  copied out — not a factory in the "construct fresh" sense, but cheap
  and covers the common `defaultdict(int)`-with-non-zero-default case
  without a callback).
- a **factory function pointer**, `fn() -> V`, for `V` that needs
  fresh-per-key construction (nested maps, or any struct/pointer default
  that must not alias between keys).

The two forms are not the same feature — a stored scalar default vs. a
per-call factory — and the type checker would need to accept either
(coerce the argument to `V`, or to `fn() -> V`, and record which). This
mirrors Python's own API wart: `defaultdict(0)` is actually a type
error in Python (the argument must be zero-arg-callable or `None`) —
`defaultdict(int)` works because `int()` is a callable returning `0`.
W's version would likely be cleaner by accepting a genuine value
directly for the scalar/struct case, since W already distinguishes
"value" from "function pointer" at the type level and doesn't need
Python's callable-or-nothing convention.

**Lowering.** `hash_emit_new_container()` would need a second code path:
after allocating the table, stash either the coerced default's word
value or the factory's code address in one new field on
`__w_hash_table` (a nullable `default_kind`/`default_value` pair, or
just a nullable `int default_factory` where the caller wraps a stored
scalar in a trivial thunk — the latter is simpler runtime, more
compiler-side bookkeeping). `hash_finish_pending_read()` and
`hash_finish_pending_compound()` would check the table's default state
at the call site (a new runtime helper, e.g. `__w_map_get_or_vivify`,
replacing the plain `__w_map_get` call when `hash_index_map_type`'s
container was constructed with a factory) instead of trapping.

**Runtime support needed.** A new field on `__w_hash_table`
(`structures/hash_table.w:50-61`) — this is a **seed-graph runtime
struct**, so any new field changes its layout everywhere it's allocated
(`__w_hash_table_new`, `__w_hash_table_grow`) and must use only
seed-era syntax (function pointers via `fn(...)  -> T` and indirect
calls already exist in the seed language, so this is not itself a
syntax risk — see `type_is_function_signature` already in
`compiler/type_table.w`, and calling a value in `eax` is exactly what
`hash_call_finish()` already does for every builtin dispatch). A new
`__w_map_get_or_vivify(table, key)` that finds-or-inserts (like
`__w_map_add`, not like `__w_map_get`), and on a fresh slot invokes the
stored factory pointer (or copies the stored default) before returning
the slot's value/address.

**Opt-in.** Automatic and unambiguous: only maps *constructed* with the
new `(...)` argument get vivifying reads; every existing `new map[K, V]`
/ `map[K, V]{...}` call site is untouched syntactically and traps exactly
as before. This is the surface with the cleanest opt-in story of the
three, because the decision is made once, at construction, and threads
through the table's own state rather than needing a per-call-site
marker.

**Non-container value types.** Works identically for scalar defaults
(stored value, no factory needed — `map_default[char*, int](0)`) and for
struct/pointer/container defaults (factory required to avoid aliasing on
struct-by-value copies, or worse, on pointer/container values where a
stored default would mean every missing key vivifies to the *same*
nested map instance). The design should probably **require** a factory
(reject a bare value) for pointer and container value types specifically
to head off that aliasing footgun, and allow either form for scalars and
by-value structs.

**Interaction with `.add` / `m[k] += x`.** `.add` stays integer-only
per its existing contract (see §3 below on #189) and is orthogonal —
nothing about a default factory changes what `.add` accepts. Compound
assignment (`m[k] += x`) on a defaulted map becomes meaningful for the
first time on a fresh key: today it traps unconditionally on a missing
key (`grammar/hash_builtin.w:127-130`); on a factory-backed map it would
vivify the default via `__w_map_get_or_vivify`, then apply the op, same
as reading first with a plain `m[k]` would.

### Surface B — pseudo-method: `m.setdefault(k)` / `m.setdefault(k, factory-or-value)`

**Syntax.** Modeled directly on Python's `dict.setdefault(key, default)`:
returns the existing value if `k` is present, otherwise inserts and
returns a newly-constructed default. Two shapes are plausible:

```w
int x = m.setdefault(c"a", 0)                 # per-call scalar default
map[char*, int]* inner = outer.setdefault(c"x", new_inner_map_fn)
```

or, mirroring `.add`'s "delta defaults to 1" convention
(`grammar/hash_builtin.w:264-271`), a zero-arg form that only works when
`V`'s zero value is well-defined (ints, floats, pointers-as-null) and
requires the two-arg form otherwise.

**Lowering.** This is the *cheapest* of the three surfaces to add,
because `.get`/`.add`/`.remove`/`.keys`/`.values` already establish the
pattern: `setdefault` is one more `peek(c"setdefault")` branch in
`postfix_expr.w`'s map/set dot-dispatch (`grammar/postfix_expr.w:664-694`),
a new `hash_set_default_suffix()` in `grammar/hash_builtin.w` parallel to
`hash_get_suffix()`, and **no `tests/parser_generator/w.pg` change** —
confirmed by reading `tests/parser_generator/w.pg:236-240`:
`postfix_tail` already includes a generic `DOT name_token` alternative
that every existing pseudo-method rides on, so a new method name needs
no grammar-generator update, only the fixture-parser's dictionary of
"known" dispatches staying loose (it already is; `name_token` is
unconstrained).

**Runtime support needed.** `__w_map_set_default(table, key, value)` /
`__w_map_set_default_bytes` (struct values) — parallel to `__w_map_add`,
using `__w_map_insert_slot`'s find-or-insert and writing the default
only when the slot was freshly claimed (mirrors `__w_map_get_or`'s
"was it live before" check, but *does* insert, unlike `.get`). A
factory-argument form needs the same indirect-call plumbing as Surface
A's `__w_map_get_or_vivify`, just invoked from the pseudo-method instead
of gated on construction-time state.

**Opt-in.** Per call site, not per container: `m[k]` keeps trapping
unconditionally forever; only an explicit `.setdefault(...)` call
vivifies. This is arguably the *safest* opt-in of the three — it can
never change the behavior of existing `m[k]`/`m[k] op= v` code, because
it's a distinct method name, not a modifier on indexing. The cost is
ergonomic: `outer.setdefault(c"x", ...)[c"a"] += 1` is close to but not
`outer[c"x"][c"a"] += 1` — the nested nice-to-have Python syntax the
issue's example leads with doesn't fall out of this surface for free;
callers write the `setdefault` call explicitly at every level of
nesting.

**Non-container value types.** Same value-vs-factory split as Surface A;
same aliasing argument for requiring a factory on pointer/container
values.

**Interaction with `.add` / `m[k] += x`.** No change to either — both
keep their current, non-defaulting behavior. `m.setdefault(k)` is
additive, not a modifier on the existing pseudo-methods.

### Surface C — compiler-lowered auto-vivification for map-of-map/list value types only

**Syntax.** None — no new tokens. `outer[a][b] += 1` on a
`map[K1, map[K2, V]]` (or `map[K, list[T]]`, `map[K, set[T]]`) would, by
the mere *shape* of the declared value type, auto-construct a fresh
empty container on a missing outer key instead of trapping.

**Lowering.** `hash_finish_pending_read()` (and the compound-assignment
path) would check `type_is_map(value_type) | type_is_set(value_type) |
type_is_list(value_type)` — already a one-line, zero-new-type-table-state
check per §1 above — and, when true, call a vivifying get instead of
`__w_map_get`. `type_get_map`/`type_get_set`/`type_get_list` already
canonicalize container types by structure, so the compiler knows
`value_type`'s exact shape (key kind, element size) at the call site and
can synthesize the "construct empty container of this exact type" call
inline, the same way `hash_emit_new_container`/`list_emit_new_container`
already do for an explicit `new map[K, V]` — no factory function pointer
is needed anywhere, because "empty container of a statically-known
container type" is always constructible.

**Runtime support needed.** A vivifying get that, on a missing key,
calls the *already-existing* `__w_map_new`/`__w_set_new`/`__w_list_new`
with the value type's key-kind/element-size (compile-time constants
baked into the call, exactly like `hash_emit_new_container` bakes them
in for `new map[K, V]` today) and stores the result before returning it.
No new struct fields, no function-pointer storage — the smallest runtime
footprint of the three surfaces.

**Opt-in — the hard part.** This is the surface the issue explicitly
flags as needing to be opt-in ("auto-vivification must be opt-in so
existing trap semantics stay"), and it's the one candidate here where
opt-in is *not* naturally per-container or per-call-site — it's
per-*type-shape*. Options within this option:
- Blanket: any `map[K, V]` where `V` is itself a container **always**
  auto-vivifies on read. This silently changes the trap contract for
  every nested-map declaration in existing programs (there are none in
  `tests/` today, confirmed by grep, so no test would break — but a
  real consumer program could exist outside this repo). This is *not*
  opt-in in the sense the issue asks for; it's a blanket behavior change
  gated only by the value type's shape, which the issue's own phrasing
  ("for map-of-map/list value types only") seems to accept as the
  *scope* limiter but not necessarily as the *opt-in* mechanism.
  Combining Surface C's lowering with Surface A's construction-time flag
  (auto-vivify container-shaped values only on maps built via
  `map_default[K, V](...)`/`new map[K, V](...)`) resolves this: the
  shape check narrows *which* factory is synthesized automatically
  (no explicit factory function needed for container-shaped V), while
  the construction-time flag still gates *whether* vivification happens
  at all. Read alone, Surface C is really "a special case of Surface A
  where the compiler synthesizes the factory for you" rather than an
  independent third mechanism.
- A declaration-site keyword or qualifier scoped to this one case only
  (e.g. a contextual `map[K, V] auto` local flag) — smaller surface
  than full Surface A, but introduces syntax for a feature that Surface
  A's general mechanism already subsumes, so it is hard to justify
  keeping both.

**Non-container value types.** Explicitly out of scope by the issue's
own framing ("for map-of-map/list value types only") — a `map[char*,
int]` would keep trapping under this surface alone, which is exactly
why #152's triage separated the counter case (already solved) from this
one.

**Interaction with `.add` / `m[k] += x`.** `m[a][b] += 1` is the
issue's own motivating example, and it composes cleanly under this
surface: `outer[a]` auto-vivifies the inner map on a missing outer key
(read path, since the inner `[b] += 1` needs a real map to operate on
before its own compound-assignment logic runs), then the inner `[b] +=
1` traps or not per the inner map's own defaulting state — if the inner
maps are *not* separately defaulted, `outer[a][b] += 1` on a brand-new
`a` still traps on `b`, because auto-vivifying the outer slot only
constructs an *empty* inner map, and `+=` on an empty map's missing key
is `m[k] op= v`'s existing, unconditional trap. Getting `defaultdict(
defaultdict(int))`'s full nested behavior (`m[a][b] += 1` on a
completely fresh `a`) requires *both* levels to be defaulting — which
argues for Surface A/C being expressed recursively (the inner map's own
type, if declared via `map_default[...]`, carries its own defaulting
state that a freshly-vivified inner map should inherit) rather than a
single flag that only applies one level deep.

## 3. Recommendation

**Land Surface A (declaration-site factory via `new map[K, V](...)` /
a `map_default[K, V](...)` constructor) as the general mechanism, with
Surface C folded in as a special case of it** (when the argument is
omitted and the value type is itself a container, synthesize the empty
constructor automatically rather than requiring `new
map[K1, map[K2, V]](new_inner_factory)` boilerplate for every nested
level). Do not land Surface B (`setdefault`) as a separate mechanism —
implement it, if wanted at all, as a thin pseudo-method wrapper over the
same runtime vivify-or-insert helper Surface A needs anyway, once
Surface A exists.

Rationale:

- **Opt-in clarity.** Surface A is the only one of the three whose
  opt-in story doesn't require new syntax scoped narrowly to a special
  case (Surface C alone) or accept a mismatch between the issue's
  "for map-of-map/list value types only" scoping and its "must be
  opt-in" requirement (see §2's discussion of Surface C in isolation).
  Gating on construction-time state, not value-type shape, is also more
  consistent with how W already treats containers as reference values
  with their own identity and behavior (`docs/projects/hash_maps_sets.md`:
  "Maps and sets are reference values") — a defaulting map is a
  different *kind* of map instance, not a different *type*, matching
  how `.add`/`.get(k, default)` are already per-call/per-instance
  choices rather than type-level ones.
- **Composability with the issue's own motivating example.**
  `m[a][b] += 1` on a truly fresh `defaultdict(defaultdict(int))` needs
  recursive defaulting (§2, Surface C's last paragraph) — only a
  mechanism that attaches defaulting *state* to a map value (Surface A)
  can carry that state through nested construction. A pure syntax-free
  shape check (bare Surface C) cannot express "the newly-vivified inner
  map is itself defaulting to `int` zero" without inventing a way to
  say so, which just reintroduces Surface A's constructor argument by
  another name.
- **Implementation cost in the single-pass compiler.** All three
  surfaces are cheap in compiler terms — this is not a token-range
  re-parse or monomorphization problem (`docs/projects/typed_containers.md`'s
  "Decision" section explains why W avoided that path for containers
  generally; defaulting doesn't reopen it, since `V`'s factory is a
  plain `fn() -> V` value, not a type parameter). Surface A's marginal
  cost over Surface C is one new `__w_hash_table` field and one branch
  in `hash_emit_new_container`; Surface C's "shape only" version saves
  that field but buys a harder opt-in problem it can't cleanly solve
  alone. Surface B is cheapest per-feature but solves less (no `m[a][b]
  += 1` sugar) and duplicates Surface A's runtime helper if both ship.
- **Seed-closure impact.** `structures/hash_table.w` and
  `grammar/hash_builtin.w` are both in the seed import graph
  (`w.w` → `grammar.w` → `grammar/hash_builtin.w`;
  `structures/hash_table.w` is auto-imported into every program per
  `docs/projects/hash_maps_sets.md`). Any of the three surfaces adds
  code there and therefore must use only seed-era syntax until the next
  `SEEDS` bump (per CLAUDE.md's "Seed constraint"). None of the three
  needs syntax newer than what's already compiled by the seed today —
  function-pointer types (`fn(...) -> T`), indirect calls, and the
  existing `__w_hash_table`/`hash_index_*` machinery are all pre-existing
  — so this is a *sizing* concern (a new struct field changes every
  `__w_hash_table` allocation site, three of them, all in the same
  file) rather than a *feasibility* one. Surface A is the design with
  the most seed-graph surface area of the three (new field + two new
  runtime functions + one new grammar branch); that is the cost of
  being the general mechanism, and it is still small relative to what
  `list[T]`/`map[K, V]` themselves added.
- **Python-familiarity vs. W's explicitness bias.** W has consistently
  chosen an explicit, slightly more verbose surface over Python's
  implicit one at every prior decision in this subsystem: `.get(k,
  default)` is opt-in per call rather than a container-wide default
  (unlike `dict.get`'s own default-per-call design, which W actually
  matches), `.add(key, delta)` is a named pseudo-method rather than
  `m[key] += 1` auto-defaulting (explicitly ruled out — see #179's
  "A true defaultdict-style per-map default value is out of scope
  here"), and struct/array value types are rejected outright rather than
  silently doing something surprising with them
  (`tests/map_value_array_error_fixture.w`). A construction-time,
  explicitly-requested factory (Surface A) continues that pattern: `m[k]`
  keeps meaning exactly what it means today for every map that wasn't
  explicitly built to default, and the defaulting behavior is visible at
  the one line that constructs the map, not implicit in indexing syntax
  everyone already uses.

## 4. Test plan

New/updated `tests/` targets, alongside existing fixture files with the
same construction pattern (`tests/map_add_error_fixture.w`,
`tests/compound_assign_map_error_fixture.w`):

- `tests/map_default_builtin_test.w` (or a new section of
  `tests/map_set_builtin_test.w`): scalar default construction and read
  (`map_default[char*, int](0)` or the chosen syntax), confirms a
  defaulted read **does** insert (unlike today's `.get(k, default)`) —
  a positive counterpart to `test_map_get_with_default()`
  (`tests/map_set_builtin_test.w:239-245`) that also asserts `.length`
  grew and the key now appears in `.keys()`.
- Nested map auto-vivification: `map[char*, map[char*, int]]` built with
  a factory, `outer[a][b] += 1` on a fresh `a` producing `1`, a second
  `outer[a][c] += 1` on the same `a` not re-vivifying (existing inner
  map reused) — the recursive-defaulting scenario from §2/§3 needs its
  own explicit assertion since it's the crux of the "genuinely missing"
  half of #152.
- Struct/pointer default via factory: confirms the factory is invoked
  fresh per key (two missing keys' vivified structs must not alias —
  mutating one must not affect the other), extending the existing
  struct-value coverage pattern in `test_map_get_struct_default()`
  (`tests/map_set_builtin_test.w:262-275`).
- Interaction with `m.add`: a defaulted map's `.add` behavior is
  unchanged (still integer-only, still its own zero-from-scratch path,
  not routed through the new vivify helper) — a regression test that
  `.add` on a defaulted map still rejects float/struct values exactly
  like `tests/map_add_error_fixture.w` does today.
- Interaction with compound assignment: `m[missing_key] += 1` on a
  defaulted `map[K, int]` succeeds and inserts (positive test); on a
  **non**-defaulted map it still traps exactly as today — a regression
  test reusing `tests/map_trap_fixture.w`'s pattern to nail down that
  ordinary maps are provably unaffected.
- `s.setdefault`-equivalent for sets, if Surface B ships at all: `s.add`
  already covers idempotent insert, so a set-specific defaulting method
  likely isn't needed — worth an explicit note in the PR rather than a
  silent gap.

## 5. Diagnostics plan

New/changed diagnostic text needs a fixture in the same commit per
CLAUDE.md's frozen-message rule (`warning_test`, the `type_system_*_test`
family, and per-fixture `# expect_stderr:`/`# reject_stderr:` directives
or `build.base.json` `expect_stderr` entries, per the existing
`map_add_error_fixture.w` / `map_value_array_error_fixture.w` pattern).
Anticipated new diagnostics:

- Rejecting a bare scalar default for a pointer/container value type
  (the aliasing footgun in §2): something like `"map default for a
  container or pointer value type must be a factory function, not a
  value"` — needs its own fixture, parallel to
  `tests/map_add_error_fixture.w`.
- A factory whose return type doesn't match `V` — likely falls out of
  existing `coerce`/`types_compatible_with_expression` machinery and
  its `warn_type_mismatch` calls (same pattern every other
  `hash_builtin.w` suffix uses, e.g. `c"map get default"` at
  `grammar/hash_builtin.w:358`) rather than needing a bespoke message —
  worth confirming during implementation rather than assuming a new
  string.
- If Surface A reuses `new map[K, V](...)` syntax: the existing parse
  error path (`"';' expected, found '('"`) needs to change to actually
  parse the argument list for map/set specifically, which changes
  behavior at a currently-erroring call site — not a frozen message
  today (it's a generic parser error, not one of the fixture-pinned
  ones), but worth a quick grep of `tests/` for any fixture that
  currently *expects* `new map[...](...)` to fail, so as not to
  silently flip an existing regression test's expectation.

## 6. Open questions for the maintainer

1. **Constructor spelling.** `new map[K, V](...)` (reuses `new`, extends
   `new_tail` which `w.pg` already models generically) vs. a distinct
   `map_default[K, V](...)` constructor (issue's own phrasing, avoids
   overloading `new`'s existing "struct field initializer" argument
   convention with a different meaning for containers). This doc leans
   `new map[K, V](...)` for surface-count minimization but has no strong
   evidence either way.
2. **Does a defaulted read insert the key?** #152's design-notes comment
   flagged this explicitly (Python does; Go's zero-value idiom doesn't).
   This doc assumes yes (matching Python, and matching `.add`'s existing
   insert-on-touch behavior) — confirm that's the intended semantics
   before implementation, since it's directly observable via
   `.keys()`/`.length` and easy to pin the wrong way in a first test.
3. **Recursive defaulting for nested factories.** Should
   `map_default[K1, map[K2, V]](inner_factory)` require `inner_factory`
   to itself return a *defaulting* inner map (so `outer[a][b] += 1`
   fully works on a fresh `a`), or is a plain `new map[K2, V]` factory
   acceptable, leaving the caller to write `outer[a] = new_map();
   outer[a][b] = 0` boilerplate for the innermost level? The issue's own
   motivating example (`m[a][b] += 1`) only fully works under the
   former; scoping this out would be a real ergonomics gap worth flagging
   back to the issue before committing to a factory signature.
4. **Does `.add` ever need to interact with a default value**, e.g.
   `counts.add(key)` on a map defaulted to a non-zero value — should the
   accumulation start from the default instead of zero? This doc assumes
   no (the two mechanisms stay orthogonal — `.add` always starts from
   the zero-initialized slot, defaulting only affects trapping reads),
   but it's worth the maintainer confirming, since it's the one place
   the two landed/proposed features touch.
