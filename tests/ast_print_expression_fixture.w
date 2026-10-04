enum ast_print_color:
	AST_PRINT_RED = 7

int ast_print_calls

int ast_print_next():
	ast_print_calls = ast_print_calls + 1
	return ast_print_calls

int main():
	if 1: (print(42))
	if 1: (println())
	if 1: (println(c"hello"))
	if 1: (println(s"héllo"))
	if 1: (println("world"))
	char letter = 'A'
	if 1: (println(letter))
	if 1: (println('A'))
	if 1: (println(true))
	float32 fraction = 1.5
	if 1: (println(fraction))
	ast_print_color color = AST_PRINT_RED
	if 1: (println(color))
	if 1: (println(ast_print_next() + ast_print_next()))
	println(ast_print_next())
	if (ast_print_calls != 3): return 1
	return 0
