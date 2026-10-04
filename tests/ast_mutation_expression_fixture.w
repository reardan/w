int ast_store_trace

void ast_store(int* p, int value):
	*p = value
	ast_store_trace = ast_store_trace + 1

int ast_store_pair(int a, int b): return a * 10 + b

int main():
	int a = 1
	int b = 2
	a = b = 3
	if a != 3 || b != 3: return 1
	if ((a += b *= 2) != 9): return 2
	if b != 6: return 3
	a -= 1
	a *= 4
	a /= 2
	a %= 5
	if a != 1: return 4
	a <<= 3
	a >>= 1
	a |= 3
	a &= 6
	a ^= 2
	if a != 4: return 5
	int* p = &a
	*p = 7
	p[0] += 2
	if a != 9: return 6
	if ((ast_store_pair(a = 2, b = a + 1)) != 23): return 7
	if ((true ? a = 11 : 12) != 11): return 8
	if a != 11: return 9
	if ((false && (a = 99)) != false): return 10
	if a != 11: return 11
	float32 x = 1.25
	x += 2
	x *= 2
	x /= 2
	x -= 1.25
	if x != 2.0: return 12
	bool yes = false
	yes = true
	if !yes: return 13
	ast_store(p, 42)
	if a != 42 || ast_store_trace != 1: return 14
	if 1: (ast_store(p, 43))
	if a != 43 || ast_store_trace != 2: return 15
	return 0
