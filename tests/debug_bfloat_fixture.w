import lib.lib

type DebugBrain = bfloat16

struct DebugBrainPair:
	bfloat16 value

int main():
	bfloat16 brain = 1.5
	const DebugBrain aliased = -2.5
	bfloat16 negative_zero
	bfloat16 subnormal
	bfloat16 infinity
	bfloat16 nan
	save_int16(cast(char*, &negative_zero), 0x8000)
	save_int16(cast(char*, &subnormal), 1)
	save_int16(cast(char*, &infinity), 0x7f80)
	save_int16(cast(char*, &nan), 0x7fc1)
	DebugBrainPair pair
	pair.value = brain
	debugger
	return 0
