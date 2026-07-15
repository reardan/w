# Multi-dimensional arrays (ndarray)

Design doc for dense multi-dimensional arrays, the first compiler-era
follow-up staged by docs/projects/engineering_math_baseline.md. The
recommendation is a library-only v1 (`lib/ndarray.w` + `lib/ndarray64.w`)
built directly on the `T[]` slice descriptors of
docs/projects/arrays_slices_strings.md, with grammar-level indexing sugar
explicitly deferred. This layout is the substrate everything downstream
assumes: the sparse/dense solvers and meshes planned for the separate
downstream repo, file I/O, the threads/parallel_for work being built in
parallel with this doc, and the SIMD/PTX work of docs/projects/cuda.md
Stage 2.

Status: design only, nothing implemented.

## Motivation and scope

Solver and CFD workloads need, in v1:

- dense rank-1..4 arrays (1D-3D space plus a component axis) of
  float32, float64 and int, contiguous in memory;
- O(1) element access with a checked default and an honest unchecked
  path for hot loops;
- row views for kernel inner loops and leading-axis subranges for
  domain decomposition;
- a layout that `parallel_for(start, end, fn, nthreads)` can chunk
  without aliasing surprises, and that a future PTX kernel or SIMD
  loop can consume as a raw pointer plus scalar extents.

Deferred (see Explicit non-goals): broadcasting, lazy evaluation,
general strided views, dynamic rank, growable arrays, operator
arithmetic, GPU execution. Sparse formats and meshes are downstream-repo
material and must not be depended on here
(docs/projects/engineering_math_baseline.md).

## Descriptor design

Do not add a new compiler descriptor kind. The two-word `{data, length}`
slice descriptor of docs/projects/arrays_slices_strings.md already owns
the flat buffer story (allocation, bounds traps, `.length`/`.data`,
decay); an ndarray is that buffer plus shape metadata, and shape
metadata is an ordinary struct:

```w
struct ndf:
	float[] data   # flat backing buffer; length = n0*n1*n2*n3
	int rank       # 1..4
	int n0         # extents; unused trailing axes hold 1
	int n1
	int n2
	int n3
	int s0         # element strides; row-major at construction
	int s1
	int s2
	int s3
```

Slice-typed struct fields compile and run today (verified against
`bin/wv2`: field assignment from `new float[n]`, indexing, `.data`,
sub-slicing all work), so nothing here waits on compiler work.

Decisions folded into that shape:

- **Scalar per-axis fields, not `int[4] shape`.** Fixed-array struct
  fields carry descriptor headers pointing into the enclosing struct;
  they are legal but excluded from `list[T]` elements and need
  descriptor fixups on every by-value copy
  (docs/projects/typed_containers.md). Scalar fields keep `ndf` a plain
  word-struct: copyable, list-storable, and trivially readable by the
  debugger and future kernel-launch glue.
- **Fixed small rank (<= 4), not dynamic rank.** Dynamic rank needs a
  heap-allocated extents buffer per array and a loop in every accessor.
  CFD v1 needs at most 3 space axes plus a component axis. Rank is
  still stored, so rank-generic utilities (fill, copy, I/O) can loop
  `0..rank`; only the accessor surface is per-rank.
- **Row-major, C order, last axis stride 1.** Matches how W programs
  index pointers today, makes leading-axis chunks contiguous for
  parallel_for, and is the layout PTX kernels and SIMD loops want.
- **Strides stored even though v1 only constructs row-major.** They
  cost four words and buy the later view/transpose story without a
  struct change. `s3` is 1 and `s0 = n1*n2*n3` at construction.
- **Alignment**: `new T[n]` payloads get whatever `lib/memory.w`'s
  malloc gives (blocks round to 8 bytes); v1 promises nothing more.
  All allocation goes through the constructors, so a later aligned
  mode is one change: over-allocate and take an aligned sub-slice
  (`buf[k : k + len]`), which preserves descriptor and bounds
  semantics. See SIMD/PTX compatibility.

Arrays pass by pointer (`ndf*`) in the accessor surface, like
`stats_acc*` in lib/stats.w; by-value `ndf` copies are cheap descriptor
copies (views over the same buffer) and are allowed but not the
convention.

## Element types

float32 everywhere; float64 only on 64-bit-word targets, where it is a
compile error on the default 32-bit target (docs/projects/float.md);
int for index maps and connectivity.

W now has real generics (docs/projects/generics.md), so a generic
`struct nd[T]` is *possible* — but a poor fit here:

- every accessor parameter is `nd[T]*`, an opaque shape for call-site
  inference, so every hot-loop call site writes
  `nd_at2[float](a, i, j)` in full;
- method-call sugar (`a.at2(i, j)`) does not compose with generic
  functions;
- each instantiation is a span re-parse per docs/projects/generics.md,
  paid in every consumer.

The established precedent is per-type modules with prefix discipline:
lib/fmath.w vs lib/fmath64.w, lib/float64_format.w. Recommendation:

- `lib/ndarray.w` — `ndf` (float32) and `ndi` (int), every target;
- `lib/ndarray64.w` — `ndf64` (float64), 64-bit-word targets only,
  importable only from code already gated to those targets, exactly
  like lib/fmath64.w.

Prefixes `ndf_`/`ndi_`/`ndf64_` keep the flat global namespace
conflict-free. The float64 module inherits lib/fmath64.w's warning
about wide hex literals: masks over 32 significant bits must be built
at runtime.

## Construction and allocation

```w
ndf u = ndf_new2(ny, nx)          # rank 2; rank-1/3/4 twins
ndf_fill(&u, 0.0)                 # explicit refill; new arrays start zero
```

`ndf_newN` computes the extent product, allocates `new float[n]`, and
fills in extents and row-major strides. `new T[n]` zeroes its payload
(docs/projects/arrays_slices_strings.md, Milestone 5), so zero-init is
inherited rather than reimplemented. Extents must be positive and the
extent product must not overflow the word-sized int — both are fatal
asserts, matching lib/stats.w's domain-error policy (a silent garbage
descriptor is indistinguishable from a real one).

Freeing: heap slices have no landed free helper (the `array_free`
family in docs/projects/arrays_slices_strings.md Milestone 5 remains
unimplemented), so v1 ndarrays are allocate-and-keep, which matches
solver lifetimes. An `ndf_free` lands together with the slice-level
helper, not ahead of it.

## Indexing

Two candidate surfaces, compared honestly:

**(a) Library accessors (recommended for v1).** Per-rank functions,
reachable through method sugar (`docs/projects/struct_methods.md`),
verified working against `bin/wv2`:

```w
float ndf_at2(ndf* a, int i, int j):
	int ok = i >= 0 && i < a.n0 && j >= 0 && j < a.n1
	asserts(c"ndf_at2: index out of range", ok)
	return a.data[i * a.s0 + j]

u.set2(i, j, u.at2(i, j) + dt * r)   # ndf_set2(&u, ...) via sugar
```

Cost: a call per access unless the loop hoists a pointer (see Bounds
policy); ergonomics are `u.at2(i, j)`, not `u[i, j]`. Zero compiler
work, works on every target today.

**(b) Grammar support for `a[i, j]`.** The comma is currently a syntax
error inside index brackets, so the surface is free — but the cost is
the full compiler-change bill: `grammar/postfix_expr.w` sits in the
seed's import closure, so the implementation may not use any post-seed
syntax; `tests/parser_generator/w.pg` needs the new index-list rule or
`parser_generator_w_test` fails on first use; and the change gates on
`./wbuild verify` / `verify_x64` / `verify_arm64` plus diagnostics
fixtures. Worse, syntax alone is not enough: `ndf` is a library struct,
so `a[i, j]` needs a semantic vehicle — either `operator[]`
overloading, which docs/projects/operator_overloading.md v1 explicitly
excludes (only binary `+ - * / %` on struct values landed), or
promoting ndarray to a built-in closed-set container like `list[T]`
(docs/projects/typed_containers.md), a much larger feature.

**Recommendation: library-first.** Ship (a) now; revisit (b) only when
the operator-overloading staging reaches `[]` or downstream demand
justifies a built-in `ndarray[T]`. The accessor names (`at2`/`set2`)
stay stable either way, so consumers migrate mechanically if sugar
lands later.

## Views and slicing

v1 supports exactly the views that are contiguous under row-major:

- `ndf_row(a, i)` returns the `float[]` row slice of a rank-2 array
  (`a.data[i * a.s0 : i * a.s0 + a.n1]`) — the inner-loop workhorse;
- `ndf_sub(a, i0, i1)` returns an `ndf` whose `data` is the leading-
  axis subrange `a.data[i0 * a.s0 : i1 * a.s0]` with `n0 = i1 - i0`
  and unchanged trailing extents/strides — domain decomposition
  without copies;
- `ndf_is_contiguous(a)` checks strides against the row-major product,
  as the precondition for kernels and I/O.

Views borrow the buffer under the same rules as slices
(docs/projects/arrays_slices_strings.md): no ownership, writes alias
the source, lifetime is the backing array's. General strided views
(column views, transposes, step slices) are deferred; the stride
fields make them expressible later without changing the struct, and a
transpose in v1 is an explicit copy.

## Bounds policy

Three tiers, consistent with the existing machinery:

1. **Default accessors are per-axis checked.** `at2`/`set2` assert
   each index against its extent (fatal assert, lib/stats.w
   precedent). The flat slice trap alone cannot catch a wrapped column
   index (`j >= n1` with `i*s0 + j` still inside the buffer), and a
   library cannot see `--bounds`, so its checks are unconditional.
2. **Slice-level access follows `--bounds`.** Code that indexes
   `a.data` or a row slice directly gets the standard inline traps, on
   by default and removed by `--bounds=off`
   (`compiler/compiler.w`), like every other buffer access.
3. **Hot loops hoist a raw pointer.** Raw pointer indexing is
   unchecked by design (docs/projects/arrays_slices_strings.md keeps
   legacy `p[i]` outside the bounds machinery):

```w
float* p = u.data.data      # validate shape once, then run unchecked
int i = row * u.s0
while (i < (row + 1) * u.s0):
	p[i] = p[i] * scale
	i = i + 1
```

This is the documented unchecked story — explicit at the use site, no
new compiler flags, and exactly what the PTX/SIMD lowering will do
anyway.

## Interaction with parallel_for

The threads workstream (in flight; today only the x86 `thread_create`
hand-emitted in `code_generator/x86_asm.w` exists) is assumed to land a
`parallel_for(start, end, fn, nthreads)`-shaped chunked-range
primitive. The ndarray contract with it:

- **Chunk the leading axis.** A worker owning rows `[i0, i1)` of a
  row-major array owns the disjoint contiguous byte range
  `[i0 * s0, i1 * s0)` — good locality, and no two workers write the
  same element by construction. `ndf_sub` expresses a worker's block
  as a first-class value.
- **Aliasing rule: no concurrent writers to the same element.**
  Read-only sharing of inputs is fine; distinct output rows are fine;
  anything else is on the caller. Word-sized elements at natural
  alignment do not tear, so disjoint-element writes need no locks.
  Adjacent blocks can share a boundary cache line — a performance
  effect, not a correctness one.
- **Reductions are two-phase.** Each worker accumulates into its own
  slot of a `float[nthreads]` scratch array; the caller combines
  serially. No atomics in v1.
- **Context via pointer.** W has no closures; the body function takes
  a `void*` context carrying the `ndf*`s, following the
  `type event_fd_cb = fn(int, int, void*) -> void` callback precedent
  in lib/event_loop.w.

## SIMD/PTX compatibility

Layout guarantees that keep docs/projects/cuda.md Stage 2 and future
SIMD builtins implementable without redesign:

1. The payload is one flat, contiguous, row-major buffer; metadata
   never lives in it. A kernel launch is `(a.data.data, n0, n1, ...)`
   — raw `T*` plus scalar extents, exactly the `cuLaunchKernel`
   parameter shape, with no hidden headers to translate.
2. Constructed arrays always have innermost stride 1;
   `ndf_is_contiguous` is the device/vector precondition, and strided
   views stay host-side.
3. All allocation flows through the constructors, so 16/32/64-byte
   alignment for SSE/AVX builtins (or a device-visible allocator) is
   one localized change.
4. Element types are exactly the PTX-mappable set: float32/`.f32`,
   float64/`.f64`, int (docs/projects/float.md's 1:1 type mapping).

Nothing in v1 commits to array-of-struct layouts, ownership headers in
the payload, or non-contiguous defaults that a GPU or SIMD backend
would have to undo.

## Staging plan

1. **`lib/ndarray.w` — float32 + int core.** `ndf`/`ndi` rank 1-4:
   constructors, `at`/`set` per rank, `fill`, `row`, `sub`,
   `is_contiguous`, plus the shape asserts. Test:
   `tests/ndarray_test.w` (lib/assert.w style) with a `# wbuild: x64`
   twin, then `./wbuild manifest` — never hand-edit build.json.
   Library-only: no verify gate, no w.pg change, no fixtures
   (`parser_generator_w_test` passes untouched because no new syntax
   exists).
2. **`lib/ndarray64.w` — float64 twin.** Mirrors the module per the
   lib/fmath64.w conventions. x64-only tests have no wbuildgen
   directive, so `tests/x64_ndarray64_test.w` gets a hand-written
   target in build.base.json (the serialization point —
   docs/projects/engineering_math_baseline.md), modeled on
   `x64_fmath64_test`.
3. **parallel_for integration.** After the threads primitive lands: a
   leading-axis-chunked axpy/Jacobi test asserting bit-identical
   results against the serial loop, plus the two-phase reduction
   pattern. Ordinary test targets; gated on the primitive's target
   coverage (threading is x86-only today, docs/todo.txt).
4. **Aligned allocation.** When the SIMD-builtins design exists: an
   aligned constructor mode via over-allocate + aligned sub-slice, and
   an alignment predicate next to `ndf_is_contiguous`. Library-only.
5. **Grammar sugar `a[i, j]` (conditional).** Only if operator
   overloading's `[]` stage or a built-in `ndarray[T]` is justified:
   seed-closure implementation in `grammar/postfix_expr.w`, w.pg
   index-list rule, diagnostics fixtures, and the full
   `./wbuild verify` / `verify_x64` / `verify_arm64` cycle.

Stages 1-4 sit entirely outside the seed's import closure
(`bin/wv2 deps w.w` lists nothing under lib/ndarray*), so none of them
can disturb the self-host fixpoint.

## Dependency and conflict map

- Stage 1 depends only on landed features (slices, slice struct
  fields, method sugar, float32) and can start now; it is independent
  of the threads workstream.
- Stage 2 depends on Stage 1 and touches build.base.json — coordinate
  with any other workstream editing it in the same wave.
- Stage 3 depends on Stage 1 and on threads/parallel_for landing; its
  test plan, not its design, is blocked.
- Stage 4 depends on a SIMD-builtins design that does not exist yet;
  the constructor funnel is the only forward commitment.
- Stage 5 is blocked on docs/projects/operator_overloading.md staging
  (which excludes `[]` in v1) or a typed-containers-style builtin
  decision; it conflicts with nothing landed.
- The downstream solver/mesh repo consumes the Stage 1-3 surface;
  nothing in this repo may depend on it
  (docs/projects/engineering_math_baseline.md).
- compiler/, grammar/, code_generator/, w.pg and all diagnostic
  fixtures are untouched through Stage 4 by design.

## Explicit non-goals (v1)

- **No broadcasting.** Implicit shape extension hides copies and
  aliasing, and breaks the flat-index contract kernels rely on; CFD
  kernels write loops anyway.
- **No lazy evaluation / expression templates.** The single-pass,
  no-AST compiler has nowhere to build an expression graph; every
  operation is an eager loop.
- **No operator arithmetic on arrays** (`u + v` via
  docs/projects/operator_overloading.md). Mechanically possible, but
  each use would silently allocate a full result array; solvers want
  explicit in-place forms (`ndf_add_into`). Revisit for small
  fixed-size types downstream, not for `ndf`.
- **No general strided views.** Stride fields reserve the room; v1
  helpers construct only contiguous views so the kernel precondition
  stays trivial.
- **No dynamic rank.** Rank <= 4 covers the target workloads; dynamic
  rank taxes every accessor for a need that has not appeared.
- **No growable arrays.** Extents are fixed at construction; growable
  is `list[T]`'s job (docs/projects/typed_containers.md).
- **No GPU execution and no SIMD emission.** This doc only guarantees
  a layout that docs/projects/cuda.md Stage 2 and SIMD builtins can
  consume unchanged.
- **No file I/O formats.** VTK and friends are downstream-repo
  material; `data`/`.length` plus the extent fields are the entire
  serialization surface they need.
