type ast_small = int16

enum ast_choice:
	AST_FIRST = 7
	AST_SECOND = 11

int ast_named_global
const int AST_NAMED_CONSTANT = 13


int ast_typed_args(int8 a, uint8 b, int16 c, uint16 d, int32 e, bool enabled):
	return ((a + b) + (c + d) + (e * 2) + (!!enabled))


int ast_typed_stack(int left, int right):
	return (left * 3 + right / 2 - left % right)


T ast_typed_twice[T](T n): return (n + n)


int main():
	int x = 5
	if 1: (x) = 9
	if 1: ((x)) += 3
	if x != 12: return 1
	int* address = &(x)
	*address = 20
	if ((x) != 20): return 2
	ast_named_global = 29
	if ((ast_named_global + AST_NAMED_CONSTANT) != 42): return 3
	if ((AST_FIRST + AST_SECOND) != 18): return 4
	if (1):
		int x = 41
		if ((x + 1) != 42): return 5
	# Resolve x immediately after the nested scope exits, before another
	# declaration/lookup has synchronized the symbol index.
	if ((x + 22) != 42): return 6
	ast_small small = -123
	int8 signed_byte = -7
	uint8 unsigned_byte = 250
	uint16 unsigned_half = 60000
	if ((small + signed_byte + unsigned_byte) != 120): return 7
	if ((unsigned_half + unsigned_byte) != 60250): return 8
	if ((-unsigned_byte) != -250): return 9
	if ((~signed_byte) != 6): return 10
	if ((+small) != -123): return 11
	bool enabled = true
	if ((!enabled) != false): return 12
	if ((!!enabled) != true): return 13
	if ((!!false) != false): return 14
	if ((!!(x - 20)) != false): return 15
	if ast_typed_args(-3, 250, -1000, 60000, -70000, true) != -80752: return 16
	if ast_typed_stack(7, 4) != 20: return 17
	if ast_typed_twice[int](21) != 42: return 18
	uint32 high = cast(uint32, 0x80000000)
	if __word_size__ == 8:
		if ((high + 7) != ((1 << 31) + 7)): return 19
	else:
		if ((high + 7) != (-2147483647 + 6)): return 20
	if ((__word_size__ + 1) != __word_size__ + 1): return 21
	if ((__target_isa__) != __target_isa__): return 22
	return 0
