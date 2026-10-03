# Production AST island: parenthesized scalar expressions. Each
# attempt owns this bounded arena on its stack; unsupported syntax and
# REPL error recovery cannot leave allocated nodes or compiler state behind.
# Node IDs are arena indices, -1 is failure. Literal nodes carry their
# source byte offset until the committed diagnostic/decoding pass fills value.
# result_type retains the streaming type convention (lvalue, value or
# untyped constant); symbol records and their name offsets remain valid
# only for this parse/emit operation, never across declarations/REPL entries.
# Float literals store two 32-bit halves for host-independent decoding.
# Call nodes use left for the first argument and next_arg links on argument
# roots; those links do not change a nested call's own argument list.
struct expression_ast:
	int count
	int end_offset
	int[128] op
	int[128] left
	int[128] right
	int[128] offset
	int[128] value
	int[128] result_type
	int[128] high
	int[128] next_arg
	int[128] symbol


int ast_expressions_mode
int ast_expressions_emitted


int expression_ast_add(expression_ast* tree, int op, int left, int right):
	if (tree.count == 128): return -1
	int id = tree.count
	tree.count = id + 1
	tree.op[id] = op
	tree.left[id] = left
	tree.right[id] = right
	tree.offset[id] = token_start_offset
	tree.result_type[id] = 3
	tree.symbol[id] = -1
	tree.next_arg[id] = -1
	return id
