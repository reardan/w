# Floating-point reference testing

This project now has two layers of floating-point regression coverage:

1. **Local C differential smoke tests** (`./wbuild float_reference_test`): compile
   `tests/float_reference.c` with the host C compiler, compile matching W
   programs, and diff their raw bit-pattern output. This keeps the everyday
   suite fast and validates W against the platform's IEEE implementation for
   representative literals, arithmetic, comparisons, and int conversions.
2. **External conformance model**: Berkeley TestFloat Release 3 is the upstream
   suite to base fuller coverage on:
   `http://www.jhauser.us/arithmetic/TestFloat.html`.

## Why Berkeley TestFloat

Berkeley TestFloat is designed to test a floating-point implementation by
comparing it with TestFloat's own software floating-point implementation. Its
generated cases combine simple patterns with weighted random inputs and cover
carry propagation, rounding, conversions, underflow, overflow, invalid
operations, subnormal inputs, positive and negative zero, infinities, and NaNs.

Release 3 uses a permissive University of California license. If we vendor any
source or generated assets from TestFloat, keep its copyright, conditions, and
disclaimer with the copied material. For now we do not vendor TestFloat code;
we only use it as the design basis for the W test plan.

## Mapping to W coverage

Current local C-reference target:

- `f32.literal.*`, `f64.literal.*`: exact bit patterns for decimal literals,
  including `0.1` and minimum subnormals.
- `*.add`, `*.sub`, `*.mul`, `*.div`: scalar arithmetic.
- `*.lt`, `*.ge`, `*.eq`: comparison lowering.
- `*.from_int`, `*.trunc`: int/float coercions.
- `*.negzero`: unary sign-bit handling.

Edge-case conformance expansion (issue #17, landed):

- `tests/float_conformance_test.w` (float32, x86 + x64 — a `# wbuild: x64`
  twin, since float32 is available on both targets) and
  `tests/x64_float64_conformance_test.w` (float64, x64-only) add
  hand-picked deterministic vectors covering NaN propagation through
  `+ - * /` (including the x86 QNaN "floating-point indefinite" pattern
  for invalid operations), signed-zero arithmetic and division-by-zero
  signed infinities, subnormal arithmetic (gradual underflow both into
  and out of the normal range), rounding at the exact-integer precision
  boundary (2^24 for float32, 2^53 for float64), exact-comparison
  semantics (including the NaN divergence below), and int<->float
  conversion edges around the truncating-conversion overflow threshold
  (2^31/2^63 depending on target word size). These are boundary values
  and simple bit patterns picked by hand, not vendored or randomly
  generated TestFloat cases — see "Why Berkeley TestFloat" above for why
  the upstream suite itself stays unvendored.
- Every semantic divergence these vectors surfaced from strict IEEE-754
  is written up in `docs/projects/float.md`'s "Known MVP semantic
  differences" section: NaN comparisons diverge in *both* directions
  (`==` true, `!=` false — the original "NaN comparison semantics are
  currently simplified" note undersold it), both-NaN-operand payload
  selection is unpinned (implementation-defined per the Intel SDM),
  division by zero is a non-trapping signed infinity (confirmed, not
  just "no exception flags"), the truncating int conversion has no
  range check and its overflow sentinel is bit-identical to a
  legitimate boundary result, and — the one genuinely surprising
  finding — a bare decimal float literal changes width by target
  (float64 on x64, float32 elsewhere) and an inline comparison
  involving one is not coerced back down, so identical source can
  compare differently across targets. Alternate rounding modes remain
  unexposed, as originally noted.

Still open for a future pass:

- Generated case files for `f32_add`, `f32_sub`, `f32_mul`, `f32_div`,
  `f64_add`, `f64_sub`, `f64_mul`, `f64_div`, `i32_to_f32`, `i32_to_f64`,
  `f32_to_i32`, and `f64_to_i32` at TestFloat's scale (weighted-random
  batches), rather than the hand-picked vectors above.
- A slower optional target for large generated/random TestFloat batches
  once the compiler can consume compact case tables efficiently.
