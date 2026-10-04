int ast_void_sequence

void ast_void_action():
	ast_void_sequence = ast_void_sequence + 1

int ast_void_consume(int ignored):
	return ast_void_sequence

int ast_void_generic[T](T value):
	return ast_void_sequence

type ast_void_function = fn() -> void

void main():
	ast_void_function* action = ast_void_action
	if (ast_void_consume(ast_void_action()) != 1): exit(1)
	if (ast_void_consume(action()) != 2): exit(2)
	if (ast_void_generic[int](ast_void_action()) != 3): exit(3)
	if (ast_void_sequence != 3): exit(4)
	exit(0)
