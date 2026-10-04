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
const int ast_stmt_declaration = 11
const int ast_stmt_guard = 12
const int ast_stmt_switch_value = 13
const int ast_stmt_switch_case = 14
const int ast_stmt_range_argument = 15
const int ast_stmt_iterable = 16
const int ast_stmt_if = 17
const int ast_stmt_switch = 18
const int ast_stmt_brace_block = 19
const int ast_stmt_indent_block = 20
const int ast_stmt_deferred_expression = 21
const int ast_stmt_gpu_dimension = 22
const int ast_stmt_gpu_argument = 23
const int ast_stmt_gpu_capture = 24


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
	int expression_type
	int declared_type
	int generator
	char* literal_bytes
	int literal_length
	int binding
	int inferred
	int has_initializer
	int branch_nonzero
	int alternate_target
	int body_target
	int function_body
	char* callee_name
	int argument_index


int ast_simple_statements_emitted
int ast_debugger_statements_emitted

int ast_return_statements_emitted
int ast_yield_statements_emitted

int ast_expression_statements_emitted

int ast_goto_statements_emitted

int ast_raw_statements_emitted

int ast_declarations_emitted

int ast_guards_emitted

int ast_switch_values_emitted
int ast_switch_cases_emitted

int ast_if_regions_emitted
int ast_switch_regions_emitted
int ast_blocks_emitted

int ast_deferred_expressions_emitted
