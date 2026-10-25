# Differential fixture for tests/wllvm_test.w: floats and f-strings built
# by the native x64 backend and by bin/wllvm must print the same text and
# exit with the same status. Not a standalone test (no wbuild directive).
import lib.fmath64
import lib.float64_format


struct sample:
	float32 narrow
	float64 wide
	int count


float64 scale
float32 bias


float64 twice(float64 x):
	return x * 2.0


float32 half(float32 x):
	return x / 2.0


float64 mean(float64* values, int n):
	float64 total = 0
	for i in range(n): total += values[i]
	return total / n


int bits(float64 f):
	return float64_bits(f)


int show(float64 f):
	char* text = f64toa(f)
	println(text)
	return cast(int, f)


int main():
	scale = 2.5
	bias = 0.25
	float64 a = 1.5
	float32 b = 0.5
	a = a + b
	a += 1.0
	a *= scale
	int whole = cast(int, a)
	println(f"a={a} whole={whole} b={b} bias={bias}")
	float64 negative = -a
	println(f"negative={negative} truncated={cast(int, negative)}")
	float32 m = -1.5
	println(f"m={m} as int={cast(int, m)} narrow={cast(int8, 300.7)}")
	float64 big = 1.0e30
	println(f"big={big} saturates={cast(int, big)}")
	int k = 3
	k += 1.5
	float64 counter = 1.5
	counter++
	counter--
	counter++
	println(f"k={k} counter={counter}")
	float64 zero = 0.0
	float64 nan = zero / zero
	float64 pinf = 1.0 / zero
	float64 ninf = -1.0 / zero
	println(f"nan==nan {nan == nan} nan!=nan {nan != nan} nan<1 {nan < 1.0} nan>=1 {nan >= 1.0}")
	println(f"inf {pinf} {ninf} nan bits {bits(nan)} inf-inf {bits(pinf - pinf)} {bits(nan + 1.0)}")
	println(f"-0 bits {bits(-zero)} -0==0 {-zero == zero} 0*-1 {bits(zero * -1.0)}")
	# NaN propagation: which operand's payload survives, and how a
	# signaling NaN is quieted, is the target's rule (SSE: the first NaN
	# operand; AArch64: a signaling NaN first).
	float64 quiet_nan = float64_from_bits((0x7ff80000 << 32) + 5)
	float64 signaling_nan = float64_from_bits((0x7ff00000 << 32) + 9)
	println(f"nan pick {bits(quiet_nan + signaling_nan)} {bits(signaling_nan + quiet_nan)} {bits(quiet_nan * 2.0)} {bits(3.0 - signaling_nan)}")
	println(f"compare {1.0 < 2.0} {2.0 <= 2.0} {3.0 > 2.0} {2.0 >= 3.0} {b == 0.5} {b != 0.5}")
	float32 third = 1.0 / 3.0
	float64 widened = third
	println(f"third={third} widened={widened} back={cast(float32, widened)} half={half(3.0)}")
	println(f"int mixes {7 / 2.0} {7 + b} {cast(float64, 7) / 2} {cast(float32, 1 << 40)}")
	float64[4] table
	for i in range(4): table[i] = twice(cast(float64, i) + 0.25)
	println(f"mean={mean(&table[0], 4)}")
	sample s
	s.narrow = 2.75
	s.wide = s.narrow * 4
	s.count = cast(int, s.wide)
	sample* heap = new sample()
	heap.narrow = 1.25
	heap.wide = -6.5
	println(f"fields {s.narrow} {s.wide} {s.count} {heap.narrow + heap.wide}")
	float64 chosen = (whole > 5) ? b : 2.5
	println(f"chosen={chosen} sqrt={fsqrt64(2.0)} floor={ffloor64(-2.5)}")
	int i = 255
	char* c = c"hi"
	string text = "str"
	char letter = 'A'
	bool flag = true
	println(f"specs [{i:>8x}] [{a:.3f}] [{b:8.2f}] [{c:<5}] [{text:^7}] [{i:}] [{i:08d}] [{whole - i: =6}] [{a:*^12.1f}]")
	println(f"kinds {letter} {flag} {i:X} {i:o} {i:b} {65:c} {{braces}} tab\tend")
	char* raw = f"n={whole}"
	println(raw)
	int total = show(a) + show(negative) + show(widened * 100.0)
	return (total & 63) + 1
