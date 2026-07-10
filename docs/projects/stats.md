# Statistics Library (`lib/stats.w`)

Design and implementation plan for descriptive statistics in the W stdlib:
batch functions over `list[float]`, a streaming accumulator, and order
statistics (median/quantiles/mode), all portable to every target.

Status: **implemented** (`lib/stats.w`, `stats_test`/`stats_64_test`).
The Phase 0 spike results are recorded under Phasing; the float64 tier
and the other Follow-ups remain open.

Motivation: nothing statistics-adjacent exists in the tree. `lib/math.w` is
integer-only (`min`/`max`/`abs`/`sign`/`gcd`/`pow`), the built-in list
aggregations `l.sum()`/`l.min()`/`l.max()` and `l.sort()` reject float
elements at compile time (`grammar/list_builtin.w`), and float math lives
in `lib/fmath.w` (`fsqrt`, `fabs`, bit casts — Phase 0.5, issue #186). Any program that wants a
mean or a standard deviation hand-rolls a loop, usually with the naive
(catastrophically cancelling) variance formula. An earlier sketch exists at
`libs/standard/plans/03_numeric_data.md` (Python-`statistics` port over
`float64*` + length); this design supersedes it — see Follow-ups.

## Scope

In for the MVP:

- Batch descriptive statistics over `list[float]`: sum, mean, min, max,
  variance, stddev.
- A streaming accumulator (`stats_acc`): add samples one at a time, merge
  two accumulators, query count/mean/min/max/variance/stddev at any point.
- Order statistics: sort helpers plus median, quantile (type-7), mode.
- Float utilities the above need — bit casts, `fis_nan`, `fabs`,
  `fsqrt` — imported from `lib.fmath` (landed as Phase 0.5, issue #186).

Out (deferred to Follow-ups): a `float64` tier, covariance/correlation/
regression, histograms and frequency counters, NaN-skipping variants,
`wresult`-based checked variants, quickselect.

Three decisions shape everything:

- **float32-only public API.** `float64` is a compile error on the default
  32-bit target (`grammar/type_name.w:101`), so a float64 API would exclude
  `bin/wv2 file.w` and most of `./wbuild tests`. `graphics/math.w` faced
  the same fork and chose float32 for portability; stats follows. `float`
  (the float32 alias) is used in signatures. A `stats64_` x64-only tier can
  layer on later without touching this API.
- **`stats_` prefix.** Imports merge into one flat global namespace and
  `lib/math.w` already owns `min`/`max`/`abs` unprefixed; `gfx_` and the
  old plan's `stats_` set the precedent. The prefix also makes struct
  method sugar resolve naturally (`a.add(x)` → `stats_acc_add(&a, x)`).
- **Built-in `list[float]`, not pointer + length.** `list[float32]` is
  tested (`tests/list_builtin_test.w:112`), `l[i]` is a real lvalue, and
  `list[T]` is what consumers already hold. Slice variants can come later.

## `lib/stats.w`

```
struct stats_acc:
	int count
	float mean
	float m2
	float min
	float max
```

Fields are the read API for stored state — struct field lookup shadows
method sugar (`docs/projects/struct_methods.md`), so an accessor function
named after a field would be unreachable as a method. Functions exist only
for actions and derived quantities:

**Float utilities** (`import lib.fmath` — extracted from
`graphics/math.w` as Phase 0.5, issue #186; no private copies):

- `int float_bits(float f)` / `float float_from_bits(int b)` —
  reinterpret casts via pointer.
- `int fis_nan(float f)` — bit test (exponent all ones, mantissa
  nonzero). Required because the compiler defines `nan == nan` as true
  (`docs/projects/float.md`), so `f != f` cannot detect NaN.
- `float fabs(float f)` — sign-bit clear.
- `float fsqrt(float f)` — Newton-Raphson with the exponent-halving
  seed; 0.0 for `f <= 0.0`.

**Accumulator** (Welford; O(1) memory, single pass):

- `void stats_acc_init(stats_acc* a)` — zero all fields; works for stack
  values (`stats_acc a` then `a.init()`).
- `void stats_acc_add(stats_acc* a, float x)` — Welford update of
  mean/m2, min/max tracking.
- `void stats_acc_merge(stats_acc* a, stats_acc* b)` — Chan parallel
  combine of b into a; makes accumulators from chunks/streams composable.
- `float stats_acc_variance(stats_acc* a, int ddof)` — m2 / (count -
  ddof), clamped at 0.0; asserts `count > ddof`.
- `float stats_acc_stddev(stats_acc* a, int ddof)` — sqrt of the above.

Count, mean, min and max are read straight off the fields.

**Batch aggregates** (loop over `l[i]`; the built-ins reject floats):

- `float stats_sum(list[float] xs)` — Neumaier compensated summation
  (same cost as Kahan, strictly better); empty list sums to 0.0.
- `float stats_mean(list[float] xs)` — Neumaier sum / length; asserts
  nonempty.
- `float stats_min(list[float] xs)` / `stats_max` — assert nonempty
  (precedent: `__w_list_min` asserts, `structures/w_list.w:333`).
- `float stats_variance(list[float] xs, int ddof = 0)` — corrected
  two-pass (Chan/Golub/LeVeque): mean first, then sum of squared
  deviations minus the compensation term; asserts `length > ddof`.
  Int-literal defaults are legal and coerce to int params
  (`docs/projects/default_args_variadics.md`).
- `float stats_stddev(list[float] xs, int ddof = 0)`.

**Order statistics** (own sort; `l.sort()` rejects floats and the
`__w_list_*` insertion sorts are O(n^2)):

- `void stats_sort(list[float] xs)` — in-place heapsort over `l[i]`
  lvalues: O(n log n), no allocation, no recursion, terminates by index
  arithmetic even if NaN comparisons are incoherent.
- `list[float] stats_sorted(list[float] xs)` — sorted copy; caller frees
  with `list_free[float]` (`lib/container.w`).
- `float stats_quantile_sorted(list[float] xs, float q)` — Hyndman-Fan
  type 7 (linear interpolation, matches numpy/Python defaults) over an
  already-sorted list; asserts `0.0 <= q <= 1.0` and nonempty.
- `float stats_quantile(list[float] xs, float q)` — sorts a copy, then
  the above.
- `float stats_median(list[float] xs)` — `stats_quantile(xs, 0.5)`.
- `float stats_mode(list[float] xs)` — longest equal run in a sorted
  copy; smallest value wins ties (documented). Avoids float map keys,
  which would be raw-bit compared (`grammar/hash_builtin.w`).

Usage:

```
import lib.stats

void demo():
	list[float] xs = list[float]{2.5, 1.0, 4.0, 1.0}
	float m = stats_mean(xs)
	float s = stats_stddev(xs, 1)
	float med = stats_median(xs)

	stats_acc a
	a.init()
	a.add(2.5)
	a.add(1.0)
	float running = a.mean
```

Public surface is ~20 symbols. The implementation deliberately uses zero
repo-untested features on the critical path: indexed loops rather than
`for x in xs` over float lists, its own heapsort rather than the untested
float `sort_by`, no float map/set keys, no float varargs (unportable by
word size), no generics in the public API (inference does not bind through
`list[T]` shapes, so generic entry points would force explicit type args).

## Error and NaN policy

- Domain errors are fatal: `asserts(c"stats: mean of empty list", ...)`
  style messages, exit(1). Precedent: `__w_list_min`. Silent sentinels are
  wrong for numerics (`mean(empty) == 0.0` is indistinguishable from a real
  zero mean), and `wresult[float]` variants can layer on later for callers
  that want recoverable errors.
- Empty `stats_sum` is 0.0 (additive identity), not an error.
- NaN inputs are garbage-in/garbage-out, documented per function.
  `stats_is_nan` is provided so callers can pre-filter. The compiler's
  simplified semantics (`nan == nan` true, `-0.0` truthy) make in-band NaN
  handling fragile; Phase 0 pins the one behavior we depend on.

## Constraints and notes

- `lib/stats.w` is a leaf module outside `w.w`'s transitive import graph:
  the seed-syntax constraint does not apply, and current features (typed
  lists, generics like `list_free[T]`, defaults) are fair game. If a
  seed-compiled file ever imports it, that changes.
- No new syntax, so `tests/parser_generator/w.pg` needs no change — but
  `parser_generator_w_test` will parse the new files, and `./wbuild`
  builds are effectively `--strict`, so both files must be warning-free
  (`./bin/wv2 check --json lib/stats.w`).
- `%` on floats is a compile error; nothing here needs it.
- `to_json`/`from_json` reject float fields, so `stats_acc` has no JSON
  round-trip; serialize via bits if ever needed.
- Struct method sugar works (`a.add(x)`), but defaults are honored on
  direct calls only — whether `a.variance()` picks up `ddof = 0` through
  the sugar is a Phase 0 check; if not, the accumulator variants simply
  take ddof explicitly (they do anyway, see above).

## Phasing

**Phase 0.5 — shared float helpers (done, issue #186).** `lib/fmath.w`
provides `float_bits`/`float_from_bits`/`fis_nan`/`fabs`/`fsqrt` (plus
`ffloor`/`fmod2`), tested by `fmath_test`/`fmath_64_test`;
`graphics/math.w` delegates to it. `lib/stats.w` imports `lib.fmath`
instead of carrying private copies.

**Phase 0 — throwaway spike, both targets (done).** Pin the four
undocumented or untested behaviors the design leans on, before any real
code. Results, identical on x86 and x64:

1. NaN ordering for `<`/`>`/`<=`/`>=` (float.md documents only `==`):
   **all false in both directions** (IEEE-unordered), so a NaN never
   replaces a running min/max and heapsort places it arbitrarily —
   consistent with the GIGO policy.
2. `l[i] = f` float STORE round-trips bit-exactly (the repo only tested
   float list reads, `tests/list_builtin_test.w:112-118`).
3. `for float x in xs` binds correctly (the module still uses indexed
   loops for symmetry with the stores).
4. `int ddof = 0` defaults work through a direct call AND through method
   sugar (`a.variance()`).

One non-spike gotcha found during implementation: `&` does not
short-circuit, so a guarded index like
`(child + 1 < n) & (xs[child] < xs[child + 1])` still evaluates the
out-of-bounds load and trips the list bounds trap — the heapsort sift
uses `&&`.

**Phase 1 — core module + wiring (done).** `stats_acc` and batch aggregates
(float utilities come from `lib.fmath`, Phase 0.5). Colocated `lib/stats_test.w` (the dominant convention —
`lib/format_test.w`, `lib/time_test.w`, ...): `import lib.testing`,
zero-arg `test_*` functions, no `main`, file-local `assert_near` (0.0001
tolerance, per `graphics/math_test.w:8`) and `assert_float_bits` for
exact cases. Wiring quartet in the same commit:

- `build.json`: `stats_test` target (`deps: ["wv2"]`, compile
  `lib/stats_test.w`, run) — copy the `format_test` shape.
- `tests` umbrella target: add `"stats_test"` to deps.
- `tools/test_map.w`: `wtest_targets.push(c"stats_test")` in
  `wtest_init_targets()` AND an `else if` branch for `lib/stats.w` in
  `wtest_map_lib()` — the fallback maps unlisted lib files to `lib_test`
  (`tools/test_map.w:225`), which would silently skip stats.

Must-have tests: Neumaier vs naive sum on a cancellation series; the
1e6-offset variance set (fails the naive formula, passes corrected
two-pass); Welford vs batch variance agreement; merge-of-halves equals
whole-stream accumulator; one-element edge cases. The fatal assert paths
(empty mean, count <= ddof, q outside [0, 1]) exit(1) and so cannot run
inside the test binary; they are exercised only by reading the guards.

**Phase 2 — order statistics + 64-bit twin (done).** Heapsort, sorted/quantile/
median/mode. Add `stats_64_test` (`bin/wv2 x64 lib/stats_test.w ...`) to
`tests_x64`, the gate that bare float literals (float64 by default on
x64) narrow correctly through the float32 API. Tests: sort on
sorted/reverse/duplicate/single inputs; quantile endpoints q=0/0.5/1;
even/odd median; mode tie-break.

**Phase 3 — docs and bookkeeping (done).** Flip this doc's Status line, update
the `stats` line in `docs/todo.txt`, add the `docs/done.txt` entry, and
note in `libs/standard/plans/03_numeric_data.md` that the statistics
portion landed as `lib/stats.w` (its "lib/math.w only has min and max"
claim is already stale). Run the full gate: `./wbuild tests`.

## Tests

`lib/stats_test.w` (Phase 1) and its `stats_64_test` twin (Phase 2) as
above. `git diff --name-only HEAD | ./bin/wtest changed` must map
`lib/stats.w` edits to `stats_test` once the `test_map.w` entry lands —
that mapping is itself the regression check for the wiring. No compiler
changes anywhere in the plan, so `./wbuild verify` is not implicated, but
`./wbuild tests` is the pre-merge gate.

## Follow-ups

- `stats64_*` float64 tier for x64 (double-precision accumulation): the
  API mirrors this module; blocked on a `list[float64]` spike — the
  instantiation should be legal on x64 but has zero in-repo usage today.
- Two-variable accumulator (`stats_acc2`): covariance, correlation,
  simple linear regression via paired Welford comoment + Chan merge.
- Histogram / frequency counter (quantize to int keys; float map keys are
  raw-bit compared and stay out of bounds).
- `wresult[float]` checked variants for recoverable empty-input handling.
- Quickselect for single-quantile queries without a full sort.
- NaN-skipping variants (`stats_mean_finite`, ...).
- Consider a shared `assert_near` in `lib/assert.w` — file-local is the
  current precedent (`graphics/math_test.w`, `lib/fmath_test.w`). The
  shared float math module itself landed as `lib/fmath.w` (issue #186).
