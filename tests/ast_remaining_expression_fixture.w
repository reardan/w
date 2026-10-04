int ast_selected

int ast_choose(int n):
	ast_selected = n
	return n

int main():
	int a = 3
	int b = 5
	if ((a | b ^ a & b) != 7): return 1
	if ((a << 2 + 1) != 24): return 2
	if ((-32 >> 2) != -8): return 3
	if ((a << b >> 2) != 24): return 4
	if ((cast(int, 0xffffffff) & 255) != 255): return 5
	if ((cast(int, cast(float32, a) + 0.5)) != 3): return 6
	if ((true ? ast_choose(7) : ast_choose(8)) != 7): return 7
	if ast_selected != 7: return 8
	if ((false ? ast_choose(9) : ast_choose(10)) != 10): return 9
	if ast_selected != 10: return 10
	if ((false ? 1 : true ? 2 : 3) != 2): return 11
	if ((true ? false ? 4 : 5 : 6) != 5): return 12
	float32 x = 1.5
	if ((false ? x : 2.5) != 2.5): return 13
	int* p = &a
	int* q = &b
	if (*(true ? p : q) != 3): return 14
	if ((cast(int*, p))[0] != 3): return 15
	int bool_bits = (a < b & b > a)
	if bool_bits != 1: return 16
	if ((a & b && a ^ b || a | b) != true): return 17
	return 0
