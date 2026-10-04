# Specialized GPU statement state. Header children are lowered before
# outlining or launching; names follow the existing kernel/launch ownership.
const int ast_gpu_launch = 1
const int ast_gpu_for = 2


struct gpu_statement_ast:
	int kind
	int source_file
	int line
	int column
	int start_offset
	int end_offset
	int kernel_symbol
	int integer_type
	int base_stack
	int argument_count
	int header_slots
	int has_start
	int symbol_base
	int variable_slot
	int guard_target
	int capture_count
	char* kernel_name
	char* launch_name
	char* variable_name


int ast_gpu_launches_emitted
int ast_gpu_fors_emitted
int ast_gpu_values_emitted
int ast_gpu_captures_emitted
