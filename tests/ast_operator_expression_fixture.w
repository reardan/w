struct ast_operator_pair:
	int x
	int y

ast_operator_pair operator+(ast_operator_pair a, ast_operator_pair b):
	return ast_operator_pair(a.x + b.x, a.y + b.y)
ast_operator_pair operator-(ast_operator_pair a, ast_operator_pair b):
	return ast_operator_pair(a.x - b.x, a.y - b.y)
int operator*(ast_operator_pair a, ast_operator_pair b): return a.x * b.x + a.y * b.y
ast_operator_pair operator*(ast_operator_pair a, float32 scale):
	return ast_operator_pair(cast(int, a.x * scale), cast(int, a.y * scale))
ast_operator_pair operator*(float32 scale, ast_operator_pair a): return a * scale
bool operator/(ast_operator_pair a, ast_operator_pair b): return a.x < b.x
ast_operator_pair operator%(ast_operator_pair a, ast_operator_pair b):
	return ast_operator_pair(a.x % b.x, a.y % b.y)
ast_operator_pair operator+(ast_operator_pair a, int[] values):
	return ast_operator_pair(a.x + values[0], a.y + values[1])
ast_operator_pair operator+(int[] values, ast_operator_pair a): return a + values
int ast_operator_pair_total(ast_operator_pair* self): return self.x + self.y

int ast_operator_order
ast_operator_pair ast_operator_mark(int value):
	ast_operator_order = ast_operator_order * 10 + value
	return ast_operator_pair(value, value + 1)

int main():
	ast_operator_pair a = ast_operator_pair(2, 3)
	ast_operator_pair b = ast_operator_pair(4, 5)
	if ((a + b).x != 6): return 1
	if ((a + b + a).y != 11): return 2
	if (a * b != 23): return 3
	if ((a + b) * (b - a) != 28): return 4
	if ((a * 2.5).x != 5 || (2.5 * a).y != 7): return 5
	if ((b % a).x != 0 || (b % a).y != 2): return 6
	if ((a + b).total() != 14): return 7
	if ((a / b) & true): pass
	else: return 8
	int[2] values
	values[0] = 7
	values[1] = 8
	if ((a + values).x != 9 || (values + a).y != 11): return 9
	if ((ast_operator_mark(1) + ast_operator_mark(2)).total() != 8): return 10
	if (ast_operator_order != 12): return 11
	return 0
