# Differential fixture for tests/wllvm_test.w: float16/bfloat16 storage,
# rounding, overflow and NaN payloads, on x86-64 (F16C) and AArch64
# (fcvt). Every result is printed as bits; the exit status is a checksum.
# Not a standalone test (no wbuild directive).
import lib.lib


int half_bits(float16 x):
	return load_int16(cast(char*, &x)) & 65535


int brain_bits(bfloat16 x):
	return load_int16(cast(char*, &x)) & 65535


float16 half_twice(float16 x):
	return x + x


float16 to_half(float32 x):
	return x


bfloat16 to_brain(float32 x):
	return x


float32 from_bits(int bits):
	int32 word = bits
	return *cast(float32*, &word)


int main():
	int sum = 0
	list[float32] inputs = list[float32]{1.0006, 0.333333, 65504.0, 65520.0, -0.0, 0.00000006, 1.00390625, 3.0e38}
	for x in inputs:
		float16 h = to_half(x)
		bfloat16 b = to_brain(x)
		float32 h_back = h
		float32 b_back = b
		println(f"{half_bits(h)} {half_bits(half_twice(h))} {brain_bits(b)} {h_back} {b_back}")
		sum = sum + half_bits(h) + brain_bits(b)
	# NaN payloads: quiet and signaling, both signs.
	list[int] nans = list[int]{0x7fc00001, 0x7f800001, 0x7fa00000, 0x7f900100}
	for bits in nans:
		float32 x = from_bits(bits)
		float32 negative = from_bits(bits | (1 << 31))
		println(f"{half_bits(to_half(x))} {brain_bits(to_brain(x))} {half_bits(to_half(negative))} {brain_bits(to_brain(negative))}")
		sum = sum + half_bits(to_half(x)) + brain_bits(to_brain(negative))
	inputs.free()
	nans.free()
	return sum % 251
