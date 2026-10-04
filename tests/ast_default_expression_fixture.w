int ast_default_order
int ast_default_mark(int n):
	ast_default_order = ast_default_order * 10 + n
	return n
int ast_default_sum(int a = 3, int b = 4): return a * 10 + b
float32 ast_default_float(float32 n = 2): return n * 3
bool ast_default_bool(bool b = 7): return b
int ast_default_pointer(int* p = 0): return p == 0
char ast_default_char(char c = 'x'): return c
int ast_default_negative(int n = -5): return n
int ast_default_proto(int n = 42);
int ast_default_proto(int n): return n

int main():
	if ((ast_default_sum()) != 34): return 1
	if ((ast_default_sum(9)) != 94): return 2
	if ((ast_default_sum(ast_default_mark(1), ast_default_mark(2))) != 12): return 3
	if (ast_default_order != 12): return 4
	if ((ast_default_float()) != 6.0): return 5
	if ((ast_default_bool()) != true): return 6
	if ((ast_default_pointer()) != 1): return 7
	if ((ast_default_char()) != 'x'): return 8
	if ((ast_default_negative()) != -5): return 9
	if (((ast_default_proto)()) != 42): return 10
	return 0
