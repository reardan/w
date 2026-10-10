# Shared by static PIE, dynamic PIE and exported-library structural checks.
import lib.lib
import lib.assert
import lib.utf8

int[3] android_items

export int android_sum10(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j):
	return a + b + c + d + e + f + g + h + i + j

export float32 android_float(float32 a, int b):
	return a * cast(float32, b)

export float64 android_double(float64 a, float64 b, float64 c, float64 d, float64 e, float64 f, float64 g, float64 h, float64 i):
	return a + b + c + d + e + f + g + h + i

export int android_relocated():
	android_items[2] = 42
	string s = "Android PIE"
	assert_strings_equal(c"Android PIE", cstr(s))
	return android_items[2]

int main():
	assert_equal(42, android_relocated())
	println(c"Android PIE OK")
	return 0
