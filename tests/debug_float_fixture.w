import lib.lib

type DebugHalf = float16

struct DebugFloats:
	float16 half
	float32 single

float32 debug_float_global

int main():
	debug_float_global = 1.25
	float32 single = -2.5
	float16 half = 1.5
	const DebugHalf aliased = -2.5
	float16 largest = 65504.0
	DebugHalf negative_subnormal
	float16 negative_zero
	float16 subnormal
	float16 infinity
	float16 nan
	save_int16(cast(char*, &negative_zero), 0x8000)
	save_int16(cast(char*, &subnormal), 1)
	save_int16(cast(char*, &negative_subnormal), 0x8001)
	save_int16(cast(char*, &infinity), 0x7c00)
	save_int16(cast(char*, &nan), 0x7e01)
	DebugFloats pair
	pair.half = half
	pair.single = single
	float16* pointer = &half
	debugger
	return 0
