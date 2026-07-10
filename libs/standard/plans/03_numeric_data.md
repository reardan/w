# Plan: numeric and data algorithms

## Target area

Base code directory: `libs/standard/numeric/` and `libs/standard/collections/`

Suggested modules:

- `libs.standard.numeric.math`
- `libs.standard.numeric.random`
- `libs.standard.numeric.statistics`
- `libs.standard.numeric.fractions`
- `libs.standard.numeric.decimal`
- `libs.standard.collections.heapq`
- `libs.standard.collections.bisect`
- `libs.standard.collections.deque`
- `libs.standard.collections.counter`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Modules/mathmodule.c` - `math` API behavior and domain errors.
- `Modules/cmathmodule.c` - only as future reference if complex numbers arrive.
- `Lib/random.py` and `Modules/_randommodule.c` - Mersenne Twister API.
- `Lib/statistics.py` - pure Python statistics algorithms.
- `Lib/fractions.py` - rational normalization and arithmetic.
- `Lib/decimal.py` and `Modules/_decimal/` - decimal contexts and rounding.
- `Lib/heapq.py` and `Modules/_heapqmodule.c` - heap operations.
- `Lib/bisect.py` and `Modules/_bisectmodule.c` - binary search helpers.
- `Lib/collections/` and `Modules/_collectionsmodule.c` - deque and Counter.

## Current W starting point

- `lib/math.w` only has `min` and `max`.
- The compiler supports integer types, float32, and x64 float64.
- `compiler/bignum.w` exists for compiler internals, not a public numeric API.
- Built-in `list[T]`, `map[K,V]`, and `set[K]` exist.

## Goals

1. Add a practical `math` module for W float/int programs.
2. Add deterministic pseudo-random generation with explicit seeding.
3. Add statistics helpers that work over integer and float arrays/lists.
4. Add small algorithmic containers: heap, bisect, deque, counter.
5. Stage exact arithmetic (`fractions`, `decimal`) after integer foundations.

## Non-goals for MVP

- No NumPy-style arrays or vectorization.
- No complex numbers until the language has a complex type or clear struct ABI.
- No cryptographic random in `random`; that belongs in `crypto.secrets`.
- No full Python `decimal` context in the first numeric pass.

## API sketch

`numeric/math.w`

- Constants: `MATH_PI`, `MATH_E`, `MATH_TAU`, `MATH_INF`, `MATH_NAN` if target supports them.
- Predicates: `math_isfinite`, `math_isinf`, `math_isnan`.
- Integer helpers: `math_gcd`, `math_lcm`, `math_isqrt`, `math_comb`, `math_perm`.
- Float helpers: `math_floor`, `math_ceil`, `math_trunc`, `math_fabs`,
  `math_sqrt`, `math_pow`, `math_sin`, `math_cos`, `math_tan`, `math_log`,
  `math_exp`.

`numeric/random.w`

- `random_state* random_new(uint32 seed)`
- `uint32 random_u32(random_state* state)`
- `int random_range(random_state* state, int start, int stop)`
- `float random_float(random_state* state)`
- `void random_shuffle(random_state* state, int* values, int length)`

`numeric/statistics.w`

- `float64 stats_mean_int(int* values, int length)`
- `float64 stats_mean_float(float64* values, int length)`
- `float64 stats_median_int(int* values, int length)`
- `float64 stats_variance_int(int* values, int length)`

`collections/heapq.w`

- `void heap_push(list[int] heap, int value)`
- `int heap_pop(list[int] heap)`
- `void heapify(list[int] heap)`

`collections/bisect.w`

- `int bisect_left_int(int* values, int length, int x)`
- `int bisect_right_int(int* values, int length, int x)`

## Implementation phases

### Phase 1: integer algorithms

- Implement `gcd`, `lcm`, `isqrt`, `comb`, `perm`.
- Keep overflow behavior explicit: return 0 plus error status where needed or
  document word-sized wrapping.
- Tests: zero, negatives, large values, symmetry, Python sample cases.

### Phase 2: heap and bisect

- Implement int-only APIs first because W lacks generics for standalone helper
  functions beyond built-in containers.
- Later add typed variants or macro/codegen patterns if the language supports it.
- Tests: heap invariant after every push/pop, duplicate values, empty errors,
  left/right insertion points.

### Phase 3: random

- Port MT19937 from `_randommodule.c` or choose PCG/Xoroshiro if implementation
  simplicity wins. If not MT19937, document incompatibility with Python seeds.
- API must require an explicit `random_state*`; avoid hidden global state.
- Tests: deterministic sequence for fixed seed, range boundaries, shuffle keeps
  all elements.

### Phase 4: float math

- Prefer C library `extern` wrappers for transcendental functions initially.
- Add pure W fallbacks only for simple functions (`fabs`, `floor`, `ceil`) if
  reliable across x86/x64.
- Tests: known values, domain errors, NaN/Inf behavior where supported.

### Phase 5: statistics

**Landed as `lib/stats.w`** (design: `docs/projects/stats.md`), which
supersedes this phase: float32 over built-in `list[float]` rather than
`float64*` + length, `stats_`-prefixed, with a Welford/Chan streaming
accumulator, Neumaier sum, corrected two-pass variance, heapsort order
statistics and type-7 quantiles. A `float64` tier remains a follow-up
there.

- Port algorithms from `statistics.py`, especially numerically stable variance.
- For MVP, accept arrays and list values separately.
- Tests: empty input errors, one-item variance, even/odd median, negative values.

### Phase 6: fractions and decimal

- `fractions`: struct with normalized numerator/denominator, gcd reduction,
  add/sub/mul/div/compare/stringify.
- `decimal`: start with fixed scale decimal, not full Python context.
- Tests: normalization signs, zero denominator, exact arithmetic examples.

## Compatibility notes from Python

- Python ints are arbitrary precision. W ints are fixed width, so overflow policy
  must be visible in every API.
- Python `random.Random` uses MT19937 and exposes many distributions. W should
  start with uniform primitives and add distributions later.
- Python `decimal` is a large standards-compliant subsystem. Treat full context,
  signals, traps, and rounding modes as a separate project.

## Acceptance criteria

- Core integer algorithms and heap/bisect pass deterministic tests.
- Random sequences are reproducible for a fixed seed.
- Statistics functions return results matching Python for documented examples
  within chosen float tolerance.
- Every numeric API documents overflow, allocation, and target restrictions.
