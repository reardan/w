struct ast_pointer_new:
	int number

# Neither pointer level has been declared before these casts.
int ast_pointer_read(int address): return ((*cast(ast_pointer_new*, address)).number)
int ast_pointer_read_indirect(int address): return ((**cast(ast_pointer_new**, address)).number)

int main():
	ast_pointer_new value
	value.number = 42
	if ((ast_pointer_read(&value)) != 42): return 1
	ast_pointer_new* pointer = &value
	if ((ast_pointer_read_indirect(&pointer)) != 42): return 2
	return 0
