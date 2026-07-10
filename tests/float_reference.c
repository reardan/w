#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint32_t f32_bits(float f) {
	union {
		float f;
		uint32_t u;
	} v;
	v.f = f;
	return v.u;
}

static uint64_t f64_bits(double d) {
	union {
		double d;
		uint64_t u;
	} v;
	v.d = d;
	return v.u;
}

static void line32(const char *name, uint32_t bits) {
	printf("%s 0x%08x\n", name, bits);
}

static void line64(const char *name, uint64_t bits) {
	printf("%s 0x%08x 0x%08x\n", name, (uint32_t)bits, (uint32_t)(bits >> 32));
}

static void f32_reference(void) {
	volatile float one = 1.0f;
	volatile float one_half = 1.5f;
	volatile float two = 2.0f;
	volatile float two_quarter = 2.25f;
	volatile float three_quarter = 3.75f;
	volatile float tiny = 1.0e-45f;

	line32("f32.literal.0.1", f32_bits(0.1f));
	line32("f32.literal.min_subnormal", f32_bits(tiny));
	line32("f32.literal.2_24_plus_1", f32_bits(16777217.0f));
	line32("f32.literal.2_24_plus_3", f32_bits(16777219.0f));
	line32("f32.literal.flt_max_shortest", f32_bits(3.4028235e38f));
	line32("f32.add", f32_bits(one_half + two_quarter));
	line32("f32.sub", f32_bits(5.5f - two));
	line32("f32.mul", f32_bits(one_half * two));
	line32("f32.div", f32_bits(7.0f / two));
	line32("f32.negzero", f32_bits(-0.0f));
	line32("f32.from_int", f32_bits((float)3));
	line32("f32.trunc", (uint32_t)(int)three_quarter);
	line32("f32.lt", one_half < two);
	line32("f32.ge", two >= two);
	line32("f32.eq", 3.0f == 3.0f);
}

static void f64_reference(void) {
	volatile double one = 1.0;
	volatile double one_half = 1.5;
	volatile double two = 2.0;
	volatile double two_quarter = 2.25;
	volatile double three_quarter = 3.75;
	volatile double tiny = 5.0e-324;

	line64("f64.literal.0.1", f64_bits(0.1));
	line64("f64.literal.min_subnormal", f64_bits(tiny));
	line64("f64.literal.2_53_plus_1", f64_bits(9007199254740993.0));
	line64("f64.literal.2_53_plus_3", f64_bits(9007199254740995.0));
	line64("f64.literal.dbl_max_shortest", f64_bits(1.7976931348623157e308));
	line64("f64.add", f64_bits(one_half + two_quarter));
	line64("f64.sub", f64_bits(5.5 - two));
	line64("f64.mul", f64_bits(one_half * two));
	line64("f64.div", f64_bits(7.0 / two));
	line64("f64.negzero", f64_bits(-0.0));
	line64("f64.from_int", f64_bits((double)3));
	line32("f64.trunc", (uint32_t)(int)three_quarter);
	line32("f64.lt", one_half < two);
	line32("f64.ge", two >= two);
	line32("f64.eq", 3.0 == 3.0);
}

int main(int argc, char **argv) {
	if (argc == 2 && strcmp(argv[1], "f64") == 0) {
		f64_reference();
	} else {
		f32_reference();
	}
	return 0;
}
