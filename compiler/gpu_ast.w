# Specialized GPU statement state. Header children are lowered before
# outlining or launching; names follow the existing kernel/launch ownership.
const int ast_gpu_launch = 1
const int ast_gpu_for = 2

# S2.2e: phases of a launch or gpu for statement's walk (emit_gpu_walk_ast,
# code_generator/gpu_ast.w), in the order the streaming emitter ran them.
# A capture phase carries its capture slot in the bits above the low byte.
const int ast_gpu_walk_expression = 1
const int ast_gpu_walk_expression_end = 2
const int ast_gpu_walk_value = 3
const int ast_gpu_walk_slot = 4
const int ast_gpu_walk_launch = 5
const int ast_gpu_walk_device_begin = 6
const int ast_gpu_walk_loop_variable = 7
const int ast_gpu_walk_guard = 8
const int ast_gpu_walk_device_end = 9
const int ast_gpu_walk_capture = 10
const int ast_gpu_walk_for_launch = 11


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
	# The owned header value being walked. The temporary expression parser
	# is passed separately and is never stored in the launch record.
	statement_ast* value
	# A walked gpu for's capture bindings, by capture slot.
	int* capture_bindings
	char** capture_names


int ast_gpu_launches_emitted
int ast_gpu_fors_emitted
int ast_gpu_values_emitted
int ast_gpu_captures_emitted
