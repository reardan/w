import lib.memory

struct ast_allocation_pair:
	char tag
	int value

struct ast_allocation_buffer:
	int count
	int[3] values

union ast_allocation_union:
	char small
	int32 big

int main():
	if ((sizeof(ast_allocation_pair)) != 1 + __word_size__): return 1
	if ((sizeof(ast_allocation_union)) != 4): return 2
	if ((sizeof(ast_allocation_pair**)) != __word_size__): return 3
	if ((sizeof(int16) + sizeof(char)) != 3): return 4
	ast_allocation_pair* pair = (new ast_allocation_pair)
	pair.tag = 'x'
	pair.value = 42
	if (pair.value != 42): return 5
	free(pair)
	ast_allocation_buffer* buffer = (new ast_allocation_buffer())
	if (buffer.count != 0): return 6
	if (buffer.values.length != 3): return 7
	for i in range(3):
		if (buffer.values[i] != 0): return 8
	buffer.values[2] = 42
	if ((buffer.values[2]) != 42): return 9
	free(buffer)
	int* integer = (new int())
	*integer = 7
	if (*integer != 7): return 10
	free(integer)
	char* context = malloc(3 * __word_size__)
	if ((repl_setjmp(context)) != 0): return 11
	free(context)
	return 0
