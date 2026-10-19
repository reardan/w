import lib.lib

struct DebugDouble:
	float64 value

int main():
	float64 wide = 1.2345678901234567
	float64 negative_zero
	float64 infinity
	float64 subnormal
	float64 nan
	save_word(cast(char*, &negative_zero), 1 << 63)
	save_word(cast(char*, &infinity), 0x7ff << 52)
	save_word(cast(char*, &subnormal), 1)
	save_word(cast(char*, &nan), (0x7ff << 52) | (1 << 51))
	DebugDouble pair
	pair.value = wide
	debugger
	return 0
