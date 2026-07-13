# Engineering math baseline

Plan and conventions for the first batch of numerics work aimed at
engineering/CFD workloads. This PR covers the library-only baseline:
transcendental math, float64 parity for the fmath surface, and a seeded
PRNG suitable for numeric code. Compiler-level work (threads/parallel_for,
multi-dimensional arrays, SIMD builtins, the PTX emitter of
docs/projects/cuda.md Stage 2) is explicitly out of scope here and staged
behind this baseline; domain libraries (sparse solvers, meshes, VTK
writers, BLAS/MPI bindings) are planned for a separate downstream
repository that imports this one, so nothing in this repo may depend on
them.

## Why library-only first

Everything in this batch sits outside the seed's import closure
(`bin/wv2 deps w.w` lists neither lib/fmath.w nor lib/stats.w), so none
of it is constrained by the pinned seed's syntax, none of it can disturb
the self-host fixpoint, and all of it is exercised by ordinary test
targets. That makes it the cheapest place to start and the foundation the
compiler-level work will be tested against.

## Scope

1. **float32 transcendentals in lib/fmath.w** — exp/log/pow/trig family,
   pure W, every target. The de facto blocker for any numeric program
   today (libs/standard/distributed's failure detector had to work around
   the missing exp).
2. **lib/fmath64.w** — the existing fmath surface (bit casts, NaN test,
   fabs/ffloor/fmod/fsqrt) ported to float64 for 64-bit-word targets,
   following the lib/float64_format.w precedent (float64 modules live in
   lib/ but are importable only where float64 compiles; it is a compile
   error on the default 32-bit target).
3. **float64 transcendentals in lib/fmath64.w** — same surface as (1) at
   double precision; lands after (1) fixes the algorithms and (2) fixes
   the module conventions.
4. **lib/rand.w** — seeded, deterministic, non-cryptographic PRNG with
   uniform float outputs for numeric code (Monte Carlo, jittered
   initialization). Distinct from libs/standard/crypto (CSPRNG) and from
   libs/standard/distributed/prng.w (protocol replay); rand_ prefix to
   keep the flat global namespace conflict-free.
5. **Gaussian sampling** in lib/rand.w (Box-Muller over (1)) and doc
   inventory updates.

## Dependency and conflict map

- (1), (2), (4) are mutually independent: disjoint files, disjoint name
  prefixes (f*, *64, rand_*). They proceed in parallel.
- (3) depends on (1) for algorithms/accuracy policy and on (2) because it
  edits the module (2) creates.
- (5) depends on (1) (Box-Muller needs flog/fsqrt/fcos ... fsin) and on
  (4) (edits lib/rand.w).
- build.base.json is a serialization point: only the float64 tests need
  hand-written targets (x64-only tests have no wbuildgen directive — the
  `# wbuild: x64` flag adds a twin, it cannot suppress the 32-bit
  target). Exactly one workstream per wave touches build.base.json.
- build.json is GENERATED: nobody edits it; `./wbuild manifest` runs once
  at integration, after all file moves are final.
- Diagnostic fixtures, w.pg, and everything under compiler/ grammar/
  code_generator/ are untouched by design.

## Accuracy and testing policy

- Tests assert golden IEEE bit patterns computed from glibc's libm by a
  throwaway C generator (same spirit as float_reference_test's diff
  against cc -O0 -fno-fast-math), with an explicit ulp tolerance per
  function rather than bit equality — pure-W polynomial implementations
  are not correctly rounded and should not pretend to be.
- Target: <= 4 ulp on the primary domains; each function's header
  comment states its measured bound and its edge-case contract.
- NaN propagation must be tested through fis_nan/f64is_nan bit tests:
  the compiler defines nan == nan as true (docs/projects/float.md), so
  x != x cannot detect NaN in W.
- Trig argument reduction beyond the float32-representable multiples of
  pi/2 degrades; the implementation documents its valid range instead of
  carrying a Payne-Hanek reduction at this stage.

## Explicit non-goals (this PR)

- No libm c_import wrapper module: `c_import "libm.so.6"` already works
  where dynamic linking is acceptable (tests/x64_c_import_float_test.w);
  pure-W keeps static binaries and non-Linux targets covered.
- No float64 stats twin yet — it wants a decision on list[float64]
  support first.
- No threads, no ndarray, no SIMD, no PTX: staged after this baseline.
