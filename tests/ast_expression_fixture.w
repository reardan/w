# Shared with the differential test: this source exercises AST islands
# inside streaming expressions, including calls, casts and pointer offsets.
int ast_identity(int n): return n


int main():
	int answer = (2 + 3 * 4 - (-8 / 2) + 17 % 5)
	if answer != 20: return 1
	if ((20 - 5 - 3) != 12): return 2
	if ((120 / 6 / 2) != 10): return 3
	if ((-17 % 5) != -2): return 4
	if ((+ +2 - - -3) != -1): return 5
	if (((2 + 3) * (4 + 5)) != 45): return 6
	if ((0x2a + 0b11 - 1) != 44): return 7
	if cast(int, (0xffffffff + 2)) != 1: return 8
	int wide = (65536 * 65536)
	if __word_size__ == 4 && wide != 0: return 9
	if __word_size__ == 8 && wide != (1 << 32): return 10
	if ast_identity((6 * 7)) != 42: return 11
	int* ptr = &answer
	if *(ptr + (4 - 4)) != 20: return 12
	int side = 0
	if (0 && (1 / 0)): return 13
	if ((1 || (1 / 0)) == 0): return 14
	if (((side += 1) + (3 * 7)) != 22): return 15
	if side != 1: return 16
	if ((1.5 + 2.5) != 4.0): return 17
	if ((answer + 22) != 42): return 18
	if ((2 /* keep the legacy comment path */ + 3) != 5): return 19
	if ((2 +
		3) != 5): return 20
	return 0
