# Resolved function boundaries. Bodies are visited incrementally with
# statement nodes while these records keep their entry/exit state alive.
const int ast_function_native = 1
const int ast_function_script = 2
const int ast_function_generator = 3
const int ast_function_kernel = 4

struct function_ast:
	int kind
	int binding
	int source_file
	int start_offset
	int end_offset
	int code_start
	int argument_words
	int parameter_count
	int frame_words
	int outer_label_base
	int outer_pending_base
	char* name
	# Set by ast_record_scalar_function; the ordinary incremental path
	# continues to use the boundary fields above.
	function_body_ast* owned_body

struct function_parameter_ast:
	int index
	int declared_type
	int binding
	int slot

int ast_functions_emitted
int ast_scripts_emitted
int ast_generators_emitted
int ast_kernels_emitted
int ast_kernel_parameters_emitted
