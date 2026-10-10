# Owned syntax for a complete tile region. All allocations use the retained
# session arena, including streaming callers; no backend state lives here.
const int tile_literal = 1
const int tile_reference = 2
const int tile_binary = 3
const int tile_unary = 4
const int tile_index = 5
const int tile_load = 6
const int tile_dot = 7
const int tile_declare = 8
const int tile_assign = 9
const int tile_if = 10
const int tile_for = 11
const int tile_store = 12
const int tile_program_id = 13
const int tile_zero = 14
const int tile_binding_capture = 1
const int tile_binding_local = 2
const int tile_binding_index = 3
const int tile_binding_loop = 4

struct tile_binding:
	int declared_type
	int id
	int active
	int initialized
	char* name
	int kind
	int type
	int host_symbol
	int capture_slot
	int scope
	int rank
	int rows
	int cols
	int uniform
	int storage_slot
	tile_binding* next

struct tile_node:
	int retained_id
	char* source_file
	int masked
	int effect_order
	int kind
	int op
	int value
	int type
	int rank
	int rows
	int cols
	int uniform
	int line
	int column
	int start
	int end
	char* name
	tile_binding* binding
	tile_node* left
	tile_node* right
	tile_node* third
	tile_node* next
	tile_node* body
	tile_node* otherwise
	tile_node* args

struct tile_program:
	int matrix_mode
	int shared_bytes
	int effect_count
	int analyzed
	int width
	int capture_count
	int binding_count
	int scope
	int retained_owner
	char* kernel_name
	char* source_file
	tile_binding* bindings
	tile_binding* bindings_tail
	tile_binding* tile_binding
	tile_node* bound
	tile_node* body

# Stable binary operation codes use ASCII for arithmetic, and these for
# comparisons/logical operators. Source spellings remain in node.name.
const int tile_op_eq = 256
const int tile_op_ne = 257
const int tile_op_le = 258
const int tile_op_ge = 259
const int tile_op_and = 260
const int tile_op_or = 261

void tile_error_at(tile_node* node, char* message):
	if (node != 0):
		if (node.source_file != 0): filename = node.source_file
		if (node.name != 0): tokenizer_set_token_text(node.name, strlen(node.name))
		line_number = node.line - 1
		column_number = node.column - 1
		diag_token_line = node.line
		diag_token_column = node.column
		token_start_offset = node.start
	error(message)
