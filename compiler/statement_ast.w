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

# S2.2a: phases of a simple, expression or return/yield statement's walk
# (emit_statement_ast_walk, code_generator/statement_ast.w), in the order
# the streaming emitter ran them.
const int ast_walk_simple = 1
const int ast_walk_expression = 2
const int ast_walk_expression_end = 3
const int ast_walk_value = 4
const int ast_walk_exit = 5


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
	int control_kind
	void* control_record


# Grammar nodes and family records must survive the frame that built them.
# The retained session owns them, including rollback after a failed REPL
# entry. Streaming callers use their local fallback. Initialize explicitly:
# the pinned seed does not zero aggregate locals or `new` allocations.
void* retained_parse_record(void* fallback, int size):
	void* record = fallback
	if (ast_retain_mode): record = retained_arena_alloc(size)
	int* words = cast(int*, record)
	for i in range(size / __word_size__): words[i] = 0
	return record


# Names passed by a caller may be in a stack buffer or freed after parsing.
char* retained_parse_name(char* name):
	if ((name == 0) || (ast_retain_mode == 0)): return name
	return retained_intern(name)


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


# Scope and jump layout are analysis facts. These helpers take an explicit
# semantic depth and never consult or modify backend stack/control state.
void ast_block_layout(statement_ast* node, int depth):
	node.stack_depth = depth


void ast_jump_layout(statement_ast* node, int depth, int target_depth, int target, int valid):
	node.stack_depth = depth
	node.target = target
	node.valid_jump = valid
	node.unwind_slots = depth - target_depth


# Semantic layout belongs to the retained lexical tree, never a process
# global. Each statement changes its own cursor and publishes it only after
# success. Existing retained checkpoints therefore also roll layout back.
# PTX outlining and streaming inline expansions retain their original path.
int ast_body_layout_owner():
	if ((ast_retain_mode == 0) || (ast_expressions_mode < 2) || (target_isa == 3)): return -1
	if (retained_parent < 0): return -1
	if (retained_record_at(retained_parent).layout_active != 1): return -1
	return retained_parent


void ast_body_layout_begin(int id, int depth):
	if ((id < 0) || (target_isa == 3)): return
	retained_record* record = retained_record_at(id)
	record.layout_active = 1
	record.layout_depth = depth


void ast_body_statement_begin(int id):
	if ((id < 0) || (target_isa == 3)): return
	retained_record* record = retained_record_at(id)
	if (record.parent < 0): return
	retained_record* parent = retained_record_at(record.parent)
	if (parent.layout_active == 1): ast_body_layout_begin(id, parent.layout_depth)


int ast_body_depth():
	int owner = ast_body_layout_owner()
	if (owner < 0): return stack_pos
	return retained_record_at(owner).layout_depth


void ast_body_set_depth(int depth):
	int owner = ast_body_layout_owner()
	if (owner >= 0): retained_record_at(owner).layout_depth = depth


void ast_body_reserve(int words):
	int owner = ast_body_layout_owner()
	if (owner >= 0):
		retained_record* record = retained_record_at(owner)
		record.layout_depth = record.layout_depth + words


# Some expression forms keep aggregate result/descriptor buffers alive
# beyond the root. Their sizes and argument compaction are still decided
# during lowering. Mark this statement explicitly unsupported rather than
# pretending its backend depth was independently analyzed. Suspension is
# published only on success, exactly like an ordinary depth update.
void ast_body_layout_suspend():
	int owner = ast_body_layout_owner()
	if (owner >= 0): retained_record_at(owner).layout_active = -1


void ast_body_expression_layout(expression_ast* tree):
	if (ast_body_layout_owner() < 0): return
	for i in range(tree.count):
		int type = type_real(tree.result_type[i])
		if ((type >= 0) && (type_num_args(type) > 0)):
			ast_body_layout_suspend()
			return
		# Stack descriptors for slices and non-heap aggregate literals.
		if ((tree.op[i] == 'Z') || (tree.op[i] == 'D')):
			ast_body_layout_suspend()
			return


void ast_body_statement_end(int id):
	if ((id < 0) || (target_isa == 3)): return
	retained_record* record = retained_record_at(id)
	if (record.layout_active == 0): return
	if (record.layout_active < 0):
		if (record.parent >= 0):
			retained_record* suspended_parent = retained_record_at(record.parent)
			if (suspended_parent.layout_active == 1): suspended_parent.layout_active = -1
		return
	# The live emitter is still incremental. Check its layout against the
	# independently advanced cursor at this statement boundary.
	assert1(record.layout_depth == stack_pos)
	if (record.parent < 0): return
	retained_record* parent = retained_record_at(record.parent)
	if (parent.layout_active == 1): parent.layout_depth = record.layout_depth
