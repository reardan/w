int ast_deferred_trace


void ast_deferred_mark(int value):
	ast_deferred_trace = ast_deferred_trace * 10 + value


void ast_deferred_shadow(int early):
	int value = 1
	defer ast_deferred_mark(value)
	value = 2
	if (early): return
	int value = 3
	return


void ast_deferred_future():
	defer ast_deferred_mark(later)
	int later = 4


int ast_deferred_identity(int value):
	return value


void ast_deferred_order():
	defer ast_deferred_mark(ast_deferred_identity(5))
	defer ast_deferred_mark(6)


int ast_deferred_value():
	int value = 7
	defer ast_deferred_mark(value)
	return 99


int main():
	ast_deferred_shadow(1)
	ast_deferred_shadow(0)
	ast_deferred_future()
	ast_deferred_order()
	if (ast_deferred_value() != 99): return 1
	if (ast_deferred_trace != 234657): return 2
	return 0
