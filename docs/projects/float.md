# Floating point: float32, float64, float16 and bfloat16

W supports full float32/float64 arithmetic and two 16-bit storage formats.
This document describes the current contract for issue #17; the original
implementation milestones have been replaced by the supported behavior.

## Target support

| Target | float32 / float | float64 | float16 storage | bfloat16 storage |
| --- | --- | --- | --- | --- |
| x86 (default 32-bit) | yes | compile error | F16C | integer conversion |
| x64 Linux, win64 | yes | yes | F16C | integer conversion |
| arm64 Linux, arm64_darwin, arm64_android | yes | yes | native scalar conversion | integer conversion |
| wasm32 | yes | compile error | software conversion | integer conversion |
| gpu (PTX kernel bodies) | yes | yes | native PTX conversion | integer conversion |

The float64 gate is the target word size, not its instruction set. The
32-bit diagnostic still says "float64 requires the x64 target".

On x86/x64/win64, float16 requires an **F16C-capable CPU** (Ivy Bridge/Zen or
newer); there is no runtime feature check or software fallback on these
backends. ARM64 uses the base scalar half/single conversion instructions,
not the optional half-precision arithmetic extension. Wasm needs no
half-precision extension. Bfloat16 requires no AVX512_BF16, ARM BF16, or
native PTX bfloat instruction support.

## Storage and computation

`float16` is IEEE binary16: 1 sign bit, 5 exponent bits, 10 fraction bits.
`bfloat16` has 1 sign bit, 8 exponent bits, and 7 fraction bits, sharing
float32's exponent range at lower precision. Both occupy two bytes in
arrays and structs.

Loading either format widens it to a float32 value. Arithmetic and
comparisons then follow the usual float32/float64 promotion rules;
storing to a 16-bit destination narrows it again. W function parameters
and returns, typed function pointers, aliases, fields, and array elements
use the same conversions. Returned half values are widened before they
participate in an expression, including a direct assignment to float32.

```w
float16 half_identity(float16 x): return x

int main():
	float16 h = 1.5
	float32 exact = half_identity(h)   # 1.5, not the half bits read as float32
	bfloat16 compact = exact
	float32 restored = compact
	return cast(int, restored) - 1
```

Inputs first convert to float32; the subsequent store uses round-to-nearest,
ties-to-even in the default floating-point environment. A float64 input can
therefore double-round near a midpoint (see the semantic differences below).
Float16 narrowing explicitly selects nearest-even on x86
and PTX; Wasm and bfloat16 conversions implement it with integer logic.
ARM64's native float16 conversion follows FPCR, so foreign code that
changes FPCR also changes those conversions, as it does ordinary ARM64
floating arithmetic. The supported default is nearest-even with gradual
underflow, without flush-to-zero or default-NaN mode.

Signed zero, infinities, subnormals, and overflow to signed infinity are
supported. Bfloat16 narrowing preserves the available sign/payload bits
and quiets NaNs without rounding a NaN into infinity. Native float16 NaN
payload behavior is backend-specific; portable code should test the NaN
class rather than require an x86 payload on a GPU.

These are storage types, not native 16-bit arithmetic or tensor-core APIs.
By-value 16-bit `extern` parameters/returns are rejected: use a float32 C
wrapper or a pointer to explicitly agreed raw storage. C float/double ABI
support remains available. JSON codec fields and map `.add` accumulation
continue to reject the 16-bit types explicitly.

## Literals, libraries and tools

- Decimal literals support exponent forms (`1e5`, `1.5e-3`, `2E+10`).
  Integer-only bignum parsing produces exact float32 or float64 bits. Bare
  literals are float64 on 8-byte-word targets and float32 on 4-byte ones.
- Arithmetic (`+ - * /`), comparisons, unary minus, compound assignment,
  int/float and float-width coercions work at declarations, assignments,
  arguments, returns, and constructor fields. `%` on floats is an error.
- Imported C float/double calls use the target ABI, including float32 to
  float64 promotion for variadic arguments. See `code_generator/ffi.w`.
- `lib/float_text.w` parses correctly rounded decimal text and formats
  shortest round-trip or fixed-precision strings from raw bits. Public
  helpers include `parse_float`, `parse_float64`, `ftoa`, `f64toa`,
  `ftoa_fixed`, and `f64toa_fixed`; printing, f-strings and JSON use them.
- `lib/fmath.w` and `lib/fmath64.w` provide bit casts, classification,
  rounding, roots, exp/log/pow and trigonometric functions, with measured
  ulp bounds against glibc goldens.
- The REPL echoes both 16-bit types as numeric values in text and JSON
  mode. `wdbg` and `wdbg64` print typed float locals/globals/fields as
  numeric text followed by storage bits. Structured `inspect` values
  have numeric `value` and hexadecimal `bits` strings, including `nan`,
  `inf`, and signed zero. Float64 inspection requires `wdbg64`.
  Untyped register/stack dumps remain raw bits; `f` still means `frame`.

## Implementation

Float values travel through W's integer evaluation pipeline as raw bits.
The accumulator and existing stack slots hold float32 or float64 words;
backend floating registers are temporary operands inside each operation.
This preserves the ordinary W calling convention. Narrow call results
still contain storage bits, so value promotion must widen them just as
it widens a memory load.

- `compiler/type_table.w`: format types, float kind, narrow-storage kind.
- `grammar/promote.w`: loads, raw call-result widening, and store coercions;
  `grammar/ast_expression.w` mirrors these result types for retained code.
- `code_generator/sse.w`: arithmetic and float16 target dispatch.
- `code_generator/wasm_half.w`: Wasm binary16 conversion.
- `code_generator/bfloat.w`: portable bfloat16 conversion emitters.
- `grammar/float_literal.w` and `compiler/bignum.w`: literal parsing.
- `debugger/locals.w`, `debugger/inspect.w`: formatting stored bits without
  executing debuggee code or requiring F16C merely to inspect a value.

Compiler modules stay compatible with the pinned seed. The compiler's
conversion emitters and debugger formatting do not use the new bfloat16
syntax in their own implementation.

## Tests and remaining extensions

The ordinary `./wbuild tests` suite includes float32/float64 literals,
arithmetic, C-reference differential tests, ABI tests, math libraries,
text conversion, and deterministic TestFloat-inspired edge vectors.
`float16_test` and `bfloat16_test` (with x64 twins) check bit patterns,
rounding, exceptional values, storage, and function-result conversions.
`debug_float_test` checks numeric text and raw bits in both debuggers;
the REPL fixtures cover text and JSON echoes.

Cross-backend tests compile the narrow formats for ARM64, Wasm and PTX.
Runtime qualification uses an ARM64 runner/emulator, Node/WASI, or CUDA
where available; GPU emit checks also run without a GPU. The older
float32/float64 conformance vectors intentionally pin several x86-specific
results, so they are not a cross-backend oracle.

Larger generated/random TestFloat batches remain an optional extension,
as described in [float_testing.md](float_testing.md). Native half/bfloat
arithmetic, tensor-core operations, a 16-bit C ABI, and changes to the
existing IEEE semantic differences below are separate work.

## Known MVP semantic differences (documented, not blocking)

Verified empirically (issue #17 conformance expansion) against this
compiler's SSE-based float32/float64 codegen (`code_generator/sse.w`) by
the TestFloat-derived vector suites `tests/float_conformance_test.w`
(float32, x86 + x64) and `tests/x64_float64_conformance_test.w`
(float64, x64); see `docs/projects/float_testing.md` for the design
rationale behind hand-picking vectors instead of vendoring TestFloat.
Everything in this list describes the x86 family (default 32-bit target,
x64, win64); "Target differences" below says where arm64, wasm and gpu
behave differently.

- **NaN comparisons diverge from IEEE-754 in both directions on the x86
  family.**
  `ucomiss`/`ucomisd` report "unordered" with ZF=1, the same flag
  combination as "equal", and the compiler's `==`/`!=` lowering only
  checks ZF (not the parity flag hardware also sets to distinguish the
  two cases). So `nan == nan` is true (IEEE: false) *and* `nan != nan`
  is false (IEEE: true). `<`, `<=`, `>`, `>=` are unaffected, since IEEE
  also defines those as false for unordered operands — which is what a
  ZF/CF-only check happens to produce anyway. `-0.0` is truthy in
  conditions, since truthiness tests the raw bit pattern (`test eax,
  eax`) rather than comparing against `0.0`.
- **Both-NaN arithmetic payload selection is not pinned.** When both
  operands of `+ - * /` are NaN, which one's payload survives is
  implementation-defined per the Intel SDM; this backend observably
  keeps the left/dest operand's payload today (`code_generator/sse.w`
  loads the left operand into `xmm0`, the instruction's implicit
  destination), but that is not an IEEE guarantee across vendors, so
  code should not depend on it (the conformance tests only assert
  is-NaN for this case). Single-NaN-operand arithmetic (only one side
  is NaN) always propagates that operand, quieted if signaling, with
  its payload otherwise intact — that part IS hardware-guaranteed and
  is asserted bit-exactly. The classic invalid operations (`0/0`,
  `inf - inf`, `inf * 0`) always produce the fixed x86 "QNaN
  floating-point indefinite" pattern (`0xffc00000` for float32,
  `0xfff8000000000000` for float64), independent of vendor.
- **Division by zero returns a signed infinity, never traps** (no
  floating-point exceptions are implemented anywhere in this MVP):
  `1.0 / 0.0` is `+inf`, `1.0 / -0.0` is `-inf`, matching IEEE-754's
  default non-trapping behavior — but there is no way to opt into
  trapping or to read sticky exception flags.
- **Bare decimal float literals change width across targets, and that
  width sticks unless something coerces it back down.** An untyped literal like `1.0` is float64 on 8-byte-word targets
  (x64, win64, arm64) but float32 on the default target and wasm ("literal type follows the target, like C's
  double-by-default"). `coerce()` narrows a float64 result back to a
  variable's declared float32 width at assignment, declaration, return
  and call-argument sites — but comparison operators are
  not a coerce() site. So for a `float a`, an inline expression like
  `(a + 1.0) == a` can evaluate *differently* on the default target
  (the literal stays float32, no widening, ties-to-even rounds the sum
  back to `a` at the 2^24 boundary, so this is true) than on x64 (the
  literal is float64, `a` widens up to compare against the unrounded
  float64 sum, so this is false) — for byte-identical source. This
  matches what equivalent C code does under the usual arithmetic
  conversions (`float` mixed with an untyped `1.0` double literal
  promotes the comparison to `double`), so it is not unique to W, but
  it is easy to trip over by assuming a `float`-typed variable pins
  every expression it appears in to float32 on every target. Store
  literal-derived intermediates into an explicitly `float32`-typed
  variable first if cross-target-identical comparison semantics
  matter — see `test_float32_rounding_at_precision_boundary` in
  `tests/float_conformance_test.w` for a worked example and a longer
  explanation in its header comment.
- **The truncating int conversion has no software range check, and its
  overflow sentinel overlaps a legitimate result.** `cvttss2si`/
  `cvttsd2si` truncate toward zero; when the source magnitude (or a
  NaN) doesn't fit the destination width, the hardware substitutes the
  "integer indefinite" sentinel (`INT_MIN`'s bit pattern — all zero but
  the sign bit) instead of trapping, and the compiler adds no
  additional check. Because `INT_MIN` is itself a legitimate, exactly-
  representable float value in range for the conversion (e.g. float32
  `-2147483648.0` on the default 32-bit target, or float64
  `-9223372036854775808.0` on x64), there is no way to tell an
  overflowed conversion apart from a genuine boundary result by
  inspecting the returned bits alone. The overflow threshold is also
  target-word-size-dependent for float32: ~2^31 on the default 32-bit
  target (4-byte `int`), ~2^63 on x64 (8-byte `int`, REX.W `cvttss2si`
  -> `rax`) — the identical float32 source value can convert cleanly on
  one target and overflow on the other.
- Calls through untyped function pointers lose float return-type
  information (the result is treated as an int at coerce sites).
- On 8-byte-word targets, a literal stored into a `float32` goes decimal→float64→float32;
  double rounding differs from direct decimal→float32 only in pathological
  halfway cases.
- `float*` and `float32*` are distinct pointer types, so mixing them warns.
- On the x86 family, `float16` requires an F16C-capable CPU (Ivy Bridge/Zen or newer, 2012+);
  there is no software fallback, and no runtime feature check is emitted.
  (`vcvtph2ps`/`vcvtps2ph`, `code_generator/sse.w` — hardware
  instructions, not a software conversion routine, so this is a hard
  requirement, not just a performance note; see also the README.md
  floating-point bullet.)
- No hex-float syntax or `.5`-style literals without a leading digit.
- On 64-bit-word targets, a float64 stored in either 16-bit format first
  narrows to float32. This storage-oriented conversion can double-round
  a value extremely close to a halfway boundary. Use explicit float32
  intermediates when comparing targets.

### Target differences

arm64, wasm and gpu share the design above but not every x86 quirk.
The x86, arm64 and wasm columns were checked by compiling the same probe
program for each target and running it (arm64 under qemu, wasm under node's
WASI). The gpu column is read from the PTX `ptx.w` emits (`setp.<cc>` with
the ordered condition names, `cvt.rzi`) and the PTX ISA's definition of
those instructions, not from a run:

| Behavior | x86 family | arm64 | wasm | gpu |
| --- | --- | --- | --- | --- |
| `nan == nan` / `nan != nan` | true / false | false / true | false / true | false / false |
| `<`, `<=`, `>`, `>=` with a NaN | false | false | false | false |
| float -> int out of range | `INT_MIN` sentinel | saturates | saturates | saturates |
| NaN -> int | `INT_MIN` sentinel | 0 | 0 | 0 |
| invalid op (`0/0`) result | `0xffc00000` | `0x7fc00000` | host-dependent | not checked |

So arm64 and wasm follow IEEE-754 for NaN comparisons. arm64 gets there by
mapping the `>`/`>=` lowering to the signed `gt`/`ge` conditions, which read
an unordered `fcmp` as false (`float_nan_compare_test`); before that fix every
ordered comparison with a NaN was true on arm64. The gpu target's `!=` uses
PTX's ordered `ne`, so `nan != nan` is false there. The float->int saturation
comes from `fcvtzs` on arm64 and `i32.trunc_sat_f32_s` on wasm. The default
NaN differs in sign: x86 produces the negative "QNaN floating-point
indefinite", arm64 the positive default NaN, and the wasm spec leaves the
sign and payload of a generated NaN to the host, so the conformance vectors
that pin these bits only run on x86 and x64.
