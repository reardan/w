# Owned syntax for a complete tile region. All allocations use the retained
# session arena, including streaming callers; no backend state lives here.
char* tile_owned_zero(int size):
	char* bytes = retained_arena_alloc(size)
	for i in range(size): bytes[i] = 0
	return bytes


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

# Layout and resource assignments are retained with their syntax owner. They
# describe logical threads and buffers, never backend registers or stack slots.
const int tile_sync_stage_ready = 1
const int tile_sync_reuse_ready = 2
const int tile_sync_block = 1

struct tile_shared_buffer:
	int id
	int offset_bytes
	int size_bytes
	int alignment
	int element_stride
	int row_stride

struct tile_sync_point:
	int phase
	int barrier_id
	int scope

# A dot multiplies an m-by-k tile by a k-by-n tile. Each thread holds a
# strided fragment of every operand and of the result (see tile_plan.w).
struct tile_dot_plan:
	tile_node* node
	int id
	tile_shared_buffer* left
	tile_shared_buffer* right
	int m_extent
	int k_extent
	int n_extent
	int fused
	tile_sync_point* stage_ready
	tile_sync_point* reuse_ready
	tile_dot_plan* next

struct tile_lowering_plan:
	int threads
	int logical_width
	int lane_passes
	int lane_stride
	int matrix_rows
	int matrix_cols
	int row_shift
	int col_mask
	int element_shift
	int shared_bytes
	int dot_count
	tile_dot_plan* dots
	tile_dot_plan* dots_tail

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
	tile_lowering_plan* plan
	int plan_generation

# Rank-two tiles have static dimensions from this set. A 16-by-16 thread
# grid covers every shape, so a thread holds (rows/16)*(cols/16) elements.
int tile_dimension_supported(int value):
	return (value == 16) || (value == 32) || (value == 64) || (value == 128)


# Shared staging rows are padded by 16 words when their width is a multiple
# of 32 words, so the two tile rows a warp touches fall in disjoint banks.
int tile_shared_row_words(int cols):
	if (cols % 32 == 0): return cols + 16
	return cols


# All dots reuse one shared region: the left operand at offset zero and the
# right operand after it. Every dot ends with a block barrier, so the next
# dot cannot overwrite operands another thread is still reading.
int tile_dot_shared_bytes(int m, int k, int n):
	return (m * tile_shared_row_words(k) + k * tile_shared_row_words(n)) * 4


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
