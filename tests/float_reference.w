import lib.lib


void print_line32(char* name, int bits):
	print(name)
	print(" ")
	print(hex(bits))
	println("")


int f32_bits(float f):
	char* p = &f
	return load_i(p, 4)


int trunc_float(float f):
	return f


int main(int argc, int argv):
	float one = 1.0
	float one_half = 1.5
	float two = 2.0
	float two_quarter = 2.25
	float three_quarter = 3.75
	float tiny = 1.0e-45

	print_line32("f32.literal.0.1", f32_bits(0.1))
	print_line32("f32.literal.min_subnormal", f32_bits(tiny))
	print_line32("f32.add", f32_bits(one_half + two_quarter))
	print_line32("f32.sub", f32_bits(5.5 - two))
	print_line32("f32.mul", f32_bits(one_half * two))
	print_line32("f32.div", f32_bits(7.0 / two))
	print_line32("f32.negzero", f32_bits(-0.0))
	print_line32("f32.from_int", f32_bits(3))
	print_line32("f32.trunc", trunc_float(three_quarter))
	print_line32("f32.lt", one_half < two)
	print_line32("f32.ge", two >= two)
	print_line32("f32.eq", 3.0 == 3.0)
	return 0
