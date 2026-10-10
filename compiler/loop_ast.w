# Resolved loop lowering state. Slot anchors and iterator helpers are
# fixed before the body is traversed; backend visitors fill control handles.
# Retained loops own their helper names independently of the for rule.
const int ast_loop_range = 1
const int ast_loop_cursor = 2
const int ast_loop_while = 3


struct loop_ast:
	int kind
	int source_file
	char* source_name   # the file name of line, owned by the record (0: no location)
	int line
	int column
	int start_offset
	int end_offset
	int variable_slot
	int variable_type
	int argument_count
	int start_slot
	int end_slot
	int step_slot
	int container_slot
	int cursor_slot
	int element_type
	int value_coerce_type
	int value_var
	int value_var_type
	int value2_coerce_type
	int layout_ready
	int entry_depth
	int body_depth
	int cleanup_slots
	int top_target
	int break_target
	int continue_target
	int rotated         # bottom-tested (grammar/loop_rotate.w); a while decides before its begin phase
	int entry_site      # the rotated loop's entry jump (be_loop_entry), -1 when top-tested
	char* begin_fn
	char* done_fn
	char* value_fn
	char* next_fn
	char* free_fn
	char* value2_fn


# Compute permanent loop slots independently of the backend's stack. An
# analysis cursor can supply depth before the header is lowered. Suspended
# cursors supply the compatibility depth after persistent header buffers
# have been lowered; ordinary balanced temporaries do not affect the layout.
void ast_loop_layout(loop_ast* node, int depth):
	node.entry_depth = depth
	node.body_depth = depth
	node.cleanup_slots = 0
	if (node.kind == ast_loop_range):
		node.cleanup_slots = node.argument_count
		node.body_depth = depth + node.argument_count
		node.start_slot = depth + 1
		node.end_slot = depth + 1
		if (node.argument_count >= 2): node.end_slot = depth + 2
		node.step_slot = depth + 3
	else if (node.kind == ast_loop_cursor):
		node.cleanup_slots = 2
		node.container_slot = depth + 1
		node.cursor_slot = depth + 2
		node.body_depth = depth + 2
	node.layout_ready = 1


int ast_range_loops_emitted
int ast_cursor_loops_emitted
int ast_iteration_values_emitted

int ast_while_loops_emitted
