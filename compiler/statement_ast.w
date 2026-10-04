# Statement nodes are built before backend emission. Source spans
# and resolved control targets belong to the node; the emitter does not
# parse tokens or consult the current loop/switch binding.
const int ast_stmt_pass = 1
const int ast_stmt_debugger = 2
const int ast_stmt_break = 3
const int ast_stmt_continue = 4
const int ast_stmt_return = 5
const int ast_stmt_yield = 6
const int ast_stmt_expression = 7
const int ast_stmt_goto = 8
const int ast_stmt_label = 9
const int ast_stmt_raw_asm = 10


struct statement_ast:
	int kind
	int source_file
	int line
	int column
	int start_offset
	int end_offset
	int target
	int unwind_slots
	int stack_depth
	int valid_jump
	expression_ast* expression_tree
	int expression_root
	int declared_type
	int generator
	char* literal_bytes
	int literal_length


int ast_simple_statements_emitted
int ast_debugger_statements_emitted

int ast_return_statements_emitted
int ast_yield_statements_emitted

int ast_expression_statements_emitted

int ast_goto_statements_emitted

int ast_raw_statements_emitted
