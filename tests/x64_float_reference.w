import lib.lib


void print_line32(char* name, int bits):
	print(name)
	print(c" ")
	print(hex(bits))
	println(c"")


void print_line64(char* name, float64 f):
	char* p = &f
	print(name)
	print(c" ")
	print(hex(load_int32(p)))
	print(c" ")
	print(hex(load_int32(p + 4)))
	println(c"")


int trunc_float64(float64 f):
	return f


int main(int argc, int argv):
	float64 one = 1.0
	float64 one_half = 1.5
	float64 two = 2.0
	float64 two_quarter = 2.25
	float64 three_quarter = 3.75
	float64 tiny = 5.0e-324

	print_line64(c"f64.literal.0.1", 0.1)
	print_line64(c"f64.literal.min_subnormal", tiny)
	print_line64(c"f64.add", one_half + two_quarter)
	print_line64(c"f64.sub", 5.5 - two)
	print_line64(c"f64.mul", one_half * two)
	print_line64(c"f64.div", 7.0 / two)
	print_line64(c"f64.negzero", -0.0)
	print_line64(c"f64.from_int", 3)
	print_line32(c"f64.trunc", trunc_float64(three_quarter))
	print_line32(c"f64.lt", one_half < two)
	print_line32(c"f64.ge", two >= two)
	print_line32(c"f64.eq", 3.0 == 3.0)
	return 0
