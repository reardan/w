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

Next TestFloat-based expansion:

- Add generated case files for `f32_add`, `f32_sub`, `f32_mul`, `f32_div`,
  `f64_add`, `f64_sub`, `f64_mul`, `f64_div`, `i32_to_f32`, `i32_to_f64`,
  `f32_to_i32`, and `f64_to_i32`.
- Start with deterministic pattern cases and boundary values so they remain
  reviewable in git.
- Add a slower optional target for large generated/random TestFloat batches once
  the compiler can consume compact case tables efficiently.
- Track known MVP semantic differences explicitly: exception flags are not
  implemented, NaN comparison semantics are currently simplified, and alternate
  rounding modes are not exposed.
