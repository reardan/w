/*
structures.json_float64_impl: the float64-typed helpers behind
structures/json.w on 8-byte-word targets.

structures/json.w compiles for every target, and float64 is a compile
error where the word is 4 bytes (docs/projects/float.md), so json.w
itself never spells the type: every float64-typed operation lives here,
bound through the reserved __arch__ import segment. The
structures/__arch__/<arch>/json_float64.w twins import this file on the
8-byte-word targets and define bits-degrade-to-zero stubs on x86/wasm,
the same split lib/__arch__/x64/repl_echo_float64.w and its x86 twin
use.

The interface passes float64 values as their raw IEEE-754 bit pattern
in an int ("bits"), which is exactly word-sized on every target that
imports this file. Decimal text conversion needs no float64 type at
all: json.w parses and prints the bits directly through
lib/float_text.w (correctly rounded parsing, shortest round-trip
printing). What remains here are the conversions between the float64
bits and json.w's float32 / int values.
*/
import lib.lib
import structures.string


# Reinterpret helpers, private copies rather than an import of
# lib.fmath64: imports merge into one flat namespace, and pulling the
# whole f*64 math surface into every structures.json consumer would
# collide with programs that import lib.fmath64 themselves.
int json_f64_bits(float64 f):
	int* p = cast(int*, &f)
	return *p


float64 json_f64_value(int bits):
	float64 f
	int* p = cast(int*, &f)
	*p = bits
	return f


# float32 reinterpret for the saturation check below. json.w owns the
# name json_float_bits, so this private copy is prefixed like the rest
# of the module.
int json_f64_float32_bits(float f):
	int32* p = cast(int32*, &f)
	return *p


int json_f64_exp_field(int bits):
	return (bits >> 52) & 0x7ff


int json_f64_is_finite(int bits):
	return json_f64_exp_field(bits) != 0x7ff


# Widen json.w's float32 float_value mirror to float64 bits (exact).
int json_f64_from_float32(float f):
	float64 wide = f
	return json_f64_bits(wide)


# int -> float64 bits, for decoding a JSON integer into a float64 slot.
int json_f64_from_int(int v):
	float64 f = v
	return json_f64_bits(f)


# Narrow float64 bits to the float32 mirror json.w keeps in
# float_value. Finite values too large for float32 saturate to the
# largest finite float32 instead of the infinity IEEE narrowing gives,
# matching json.w's float32 parse contract; small values flush through
# the float32 denormals naturally, and non-finite input keeps its
# non-finite float32 image (json_append_float spells it null).
float json_f64_to_float32(int bits):
	float64 f = json_f64_value(bits)
	float narrow = f
	if (json_f64_is_finite(bits)):
		if ((json_f64_float32_bits(narrow) & 0x7f800000) == 0x7f800000):
			narrow = 3.40282346e38
			if (f < 0.0): narrow = -3.40282346e38
	return narrow
