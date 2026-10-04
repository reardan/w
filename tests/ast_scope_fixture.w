int ast_scope_trace


void ast_scope_mark(int value):
	ast_scope_trace = ast_scope_trace * 10 + value


void ast_scope_run():
	defer ast_scope_mark(3)
	{
		int value = 4
		ast_scope_mark(value)
	}
	if (true):
		int value = 5
		ast_scope_mark(value)
	else: pass


int main():
	ast_scope_run()
	if (ast_scope_trace != 453): return 1
	int count = 0
	while (count < 2):
		switch count:
			case 0: count += 1
			default: count += 1
	if (count != 2): return 2
	return 0
