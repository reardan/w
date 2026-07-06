import lib.lib


# Explicit-state deterministic PRNG.
#
# This is not Python-compatible MT19937. It is a small 32-bit LCG using
# Numerical Recipes constants; state updates intentionally wrap modulo 2^32.
# random_range exits when stop <= start. random_float uses 31 random bits and
# returns a float32 in [0.0, 1.0].

struct random_state:
	uint32 value


random_state* random_new(uint32 seed):
	random_state* state = new random_state()
	state.value = seed
	return state


uint32 random_u32(random_state* state):
	state.value = state.value * cast(uint32, 1664525) + cast(uint32, 1013904223)
	return state.value


int random_range(random_state* state, int start, int stop):
	if (stop <= start):
		exit(1)
	int width = stop - start
	int offset = cast(int, random_u32(state) & cast(uint32, 0x7fffffff)) % width
	return start + offset


float32 random_float(random_state* state):
	int positive = cast(int, random_u32(state) & cast(uint32, 0x7fffffff))
	return positive / 2147483647.0


void random_shuffle(random_state* state, int* values, int length):
	int i = length - 1
	while (i > 0):
		int j = random_range(state, 0, i + 1)
		int tmp = values[i]
		values[i] = values[j]
		values[j] = tmp
		i = i - 1
