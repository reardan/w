# First production AST island: parenthesized integer arithmetic. Each
# attempt owns this bounded arena on its stack; unsupported syntax and
# REPL error recovery cannot leave allocated nodes or compiler state behind.
# Node IDs are arena indices, -1 is failure. Literal nodes carry their
# source byte offset until the committed diagnostic/decoding pass fills value.
struct expression_ast:
	int count
	int end_offset
	int[128] op
	int[128] left
	int[128] right
	int[128] offset
	int[128] value


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
	return id
