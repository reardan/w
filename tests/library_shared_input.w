# Compiled independently, with no main. The test consumer sees only
# extern declarations and the shared artifact, never this source.
# wbuild: library=shared_fixture kind=shared arch=x64
int shared_counter = 10
char* shared_message


int shared_private_add(int a, int b):
	return a + b


export int shared_add(int a, int b):
	return shared_private_add(a, b)


export int shared_sum8(int a, int b, int c, int d, int e, int f, int g, int h):
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8


export int shared_bump(int by):
	shared_counter += by
	return shared_counter


export char* shared_text():
	if (shared_message == 0): shared_message = c"shared library"
	return shared_message


export float32 shared_scale32(float32 value, int factor):
	return value * cast(float32, factor)


export float64 shared_scale64(float64 value, int factor, float64 offset):
	return value * cast(float64, factor) + offset


export float64 shared_sum9(float64 a, float64 b, float64 c, float64 d, float64 e, float64 f, float64 g, float64 h, float64 i):
	return a + b + c + d + e + f + g + h + i


export int shared_pointer(int* value, int by):
	*value += by
	return *value
