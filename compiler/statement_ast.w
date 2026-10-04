# Simple statement nodes are built before backend emission. Source spans
# and resolved control targets belong to the node; the emitter does not
# parse tokens or consult the current loop/switch binding.
const int ast_stmt_pass = 1
const int ast_stmt_debugger = 2
const int ast_stmt_break = 3
const int ast_stmt_continue = 4


struct statement_ast:
	int kind
	int source_file
	int line
	int column
	int start_offset
	int end_offset
	int target
	int unwind_slots
	int valid_jump


int ast_simple_statements_emitted
int ast_debugger_statements_emitted
