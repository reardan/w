# Resolved loop lowering state. Slot anchors and iterator helpers are
# fixed before the body is traversed; backend visitors fill control handles.
# Retained loops own their helper names independently of the for rule.
const int ast_loop_range = 1
const int ast_loop_cursor = 2
const int ast_loop_while = 3


struct loop_ast:
	int kind
	int source_file
	int line
	int column
	int start_offset
	int end_offset
	int variable_slot
	int variable_type
	int argument_count
	int end_slot
	int container_slot
	int cursor_slot
	int element_type
	int value_coerce_type
	int value_var
	int value_var_type
	int value2_coerce_type
	int top_target
	int break_target
	int continue_target
	char* begin_fn
	char* done_fn
	char* value_fn
	char* next_fn
	char* free_fn
	char* value2_fn


int ast_range_loops_emitted
int ast_cursor_loops_emitted
int ast_iteration_values_emitted

int ast_while_loops_emitted
