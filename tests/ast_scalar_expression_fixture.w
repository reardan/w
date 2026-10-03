# Differential fixture: scalar AST calls preserve left-to-right evaluation,
# argument coercion, forward patches, and pointer element widths.
int ast_order
float32 ast_float_global


int ast_tick(int n):
	ast_order = ast_order * 10 + n
	return n


int ast_pair(int a, int b): return a * 10 + b
int ast_zero(): return 7
int ast_forward(int a);
int ast_use_forward(int a): return (ast_forward(a) + 1)
int ast_forward(int a): return a * 2
float32 ast_float_call(float32 a, float32 b): return (a + b)
int16* ast_pointer_call(int16* p, int n): return (p + n)
bool ast_bool_call(bool b): return b
int ast_default(int a = 5): return a
T ast_inferred[T](T a): return a


int main():
	ast_float_global = 1.25
	int16[3] values
	values[0] = 100
	values[1] = 200
	values[2] = 300
	int16* p = cast(int16*, values)
	if *(p + 2) != 200: return 1
	if ((2 + p)[1] != 300): return 2
	int16* q = (p + 4)
	if ((q - p) != 4): return 3
	if *(q - 2) != 200: return 4
	if (*(ast_pointer_call(p, 2)) != 200): return 5
	if ((ast_pair(ast_tick(1), ast_tick(2)) + ast_tick(3)) != 15): return 6
	if ast_order != 123: return 7
	if ((ast_zero() + ast_use_forward(20)) != 48): return 8
	if ((ast_default() + ast_inferred(37)) != 42): return 9
	if ((ast_bool_call(true)) != true): return 10
	float32 x = 1.5
	float32 y = 2.25
	if ((x + y * 2) != 6.0): return 11
	if ((-x + +y) != 0.75): return 12
	if ((x / 2 + ast_float_global) != 2.0): return 13
	if ((ast_float_call(x, y) + 2) != 5.75): return 14
	if ((ast_float_call(1, 2.5)) != 3.5): return 15
	if ((1.25e+1 - 5e-1) != 12.0): return 16
	if ((-0.0) != 0.0): return 17
	if ((!!x) != true): return 18
	if ((1 + ast_pair(2, ast_pair(3, 4)) * 2) != 109): return 19
	float32 negative_zero = (-0.0)
	uint32* zero_bits = &negative_zero
	if *zero_bits != (1 << 31): return 20
	# Decimal conversion must agree across 32/64-bit compiler hosts.
	float32 rounded = (1.000000059604644775390625)
	if rounded != 1.0: return 21
	float32 tiny = (1.401298464324817e-45)
	uint32* tiny_bits = &tiny
	if *tiny_bits != 1: return 22
	return 0
