int ast_intrinsic_sequence

int ast_intrinsic_mark(int value):
	ast_intrinsic_sequence = ast_intrinsic_sequence * 10 + value
	return value

int* ast_intrinsic_output(int* output):
	ast_intrinsic_sequence = ast_intrinsic_sequence * 10 + 3
	return output

int ast_intrinsic_check():
	int mask = ((1 << 30) * 4) - 1
	if (mul_hi(mask, mask) != mask - 1): return 1
	if (mul_hi(65536, 65536) != 1): return 2
	int high = -1
	if (mul_wide(ast_intrinsic_mark(1), ast_intrinsic_mark(2), ast_intrinsic_output(&high)) != 2): return 3
	if (high != 0 || ast_intrinsic_sequence != 123): return 4
	if (mul_wide(mask, mask, &high) != 1 || high != mask - 1): return 5
	int carry = -1
	if (add_carry(mask, 2, &carry) != 1 || carry != 1): return 6
	if (add_carry(3, 4, &carry) != 7 || carry != 0): return 7
	if (shr(-1, 1) != 2147483647 || shr(16, 34) != 4): return 8
	if (rotl(1, 33) != 2 || rotr(2, 33) != 1): return 9
	if (rotr(1, 1) != (1 << 31)): return 10
	if (popcount(-1) != 32 || popcount(0x1234) != 5): return 11
	if (clz(0) != 32 || ctz(0) != 32 || clz(1) != 31 || ctz(16) != 4): return 12
	if (popcount(rotl(3, 17)) != 2): return 13
	if (mul_hi(65536.0, 65536) != 1): return 14
	return 0

int shr(int value, int shift):
	return value + shift + 10

int main():
	int result = ast_intrinsic_check()
	if (result): return result
	if (shr(1, 2) != 13): return 15
	return 0
