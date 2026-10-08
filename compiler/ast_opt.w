# C3.5 (#110): the optional AST optimizer pass, off by default (--ast-opt).
# docs/projects/optimization.md §6 and ast_migration.md describe it.
#
# Where it runs. Every compile emits from the retained forest (S2.5), one
# statement or control header at a time: an if/elif arm or a while loop is
# a statement walk (code_generator/retained_emit.w) whose header, the
# keyword and its condition, is parsed completely before any of its code
# is emitted, and whose later steps (the jump past the else arms, the back
# edge, the region ends) are phases emitted once the body has been parsed.
# "Between body parse and emission" therefore means: between the parse of
# a header (or a body) and the walk phase that emits it. The pass hooks
# there, at two call sites:
#
# - ast_opt_guard (grammar/ast_statement.w, ast_statement_guard): the
#   condition of an if, elif or while arm has been parsed into its tree
#   and nothing of it has been emitted. The pass folds the tree to a
#   constant when every node is a literal or an operator over literals
#   and records the result on the arm (ast_opt_arm).
# - ast_opt_guard_phase / ast_opt_condition_start
#   (code_generator/statement_ast.w, emit_guard_ast_walk): the arm's
#   phases. A folded arm's branch is rewritten: no branch when the
#   condition is true, an unconditional jump when it is false. The arm
#   the condition kills (the body of 'if 0' or 'while 0', the elif and
#   else arms after 'if 1') is a dead region: it is still parsed and
#   emitted by its own walks, so every diagnostic, symbol and type fact is
#   what the default compile produces, and then its bytes are taken back
#   when the phase that ends it runs, if nothing outside the region can
#   refer to them.
#
# Two rewrites that the emission-time peepholes (code_generator/x86.w,
# optimization.md §1.3 and the constant fold) cannot make: they see one
# instruction window at a time, so they can fold 'mov eax,8; cmp eax,8'
# into nothing only if they know the branch after it, and never know
# where the arm it skips ends.
#
# The condition is still lowered, so its warnings, literal checks and
# lint state are exactly the default compile's; only its bytes are
# discarded (peep_rollback) before the rewritten branch is emitted. The
# retained forest is not modified: 'w tree --json' is the same with and
# without the pass.
#
# A dead region is discarded only when its emission left no trace outside
# its own bytes (ast_opt_region_close): no address slot (calls, globals,
# strings and descriptors, backpatch chains), no rebase note or data
# bytes, no goto label or pending goto in the region, no PGO loop-head
# alignment, the stack depth and the control-region stack as they were.
# Branches the region threaded into enclosing regions are dropped by
# restoring those regions' chain heads, and the DWARF line rows, local
# variable records, lexical blocks and frame-teardown notes it added are
# truncated. Otherwise the region is kept (it is unreachable, never
# wrong). x86 and x64 Linux ELF only, and not under --profile-generate or
# --coverage, whose counters record code positions.

int ast_opt_mode
int ast_opt_conditions_folded
int ast_opt_regions_removed
int ast_opt_regions_kept
int ast_opt_bytes_removed

# A dead region's snapshot, taken where its bytes start.
struct ast_opt_region:
	int start
	int ctrl_pos
	int* ctrl_heads
	int stack_depth
	int addr_slots
	int rebases
	int data_pos
	int calls
	int aligned_loops
	int lines
	int last_line
	int last_file
	int last_stack
	int locals
	int events
	int blocks
	int leaves
	int funcs
	int open_blocks
	int* block_flags

# A folded arm: the condition's value, where its bytes start once the
# walk lowers it, and the dead region the arm has open. key is the arm's
# if/elif statement_ast or while loop_ast address.
struct ast_opt_arm:
	int key
	ast_opt_arm* next
	int fold
	int cond_start
	int cond_ctrl_pos
	int cond_stack_depth
	int cond_addr_slots
	ast_opt_region* region

# A rotated while loop's dead-body region (grammar/loop_rotate.w, unit A7
# of codegen_gap_plan.md): the loop enters by a jump to its bottom test,
# so the body is emitted before the condition is parsed and the fold is
# known. Under the pass every rotated while opens a region at its begin
# phase, keyed like an arm; the branch phase adopts it when the condition
# folded to 0 and drops it otherwise.
struct ast_opt_loop:
	int key
	ast_opt_loop* next
	ast_opt_region* region

ast_opt_loop* ast_opt_loops

# The folded arms whose phases have not all run, innermost first (they
# nest like the arms). The parse hook removes any record with the arm's
# key before it adds one, so a record left behind by an arm that never
# finished (an error unwound its frame) is never read by a later arm at
# the same address. An arm that is not folded has no record and costs
# one empty-list check per phase.
ast_opt_arm* ast_opt_arms

# Set by ast_opt_eval when the tree is not a constant it can fold.
int ast_opt_eval_failed


void ast_opt_reset():
	ast_opt_mode = 0
	ast_opt_conditions_folded = 0
	ast_opt_regions_removed = 0
	ast_opt_regions_kept = 0
	ast_opt_bytes_removed = 0
	ast_opt_arms = 0
	ast_opt_loops = 0


void ast_opt_stats_dump():
	if (ast_opt_mode == 0): return
	print_error(c"AST optimizer folded conditions: ")
	print_error(itoa(ast_opt_conditions_folded))
	print_error(c"\nAST optimizer dead regions removed: ")
	print_error(itoa(ast_opt_regions_removed))
	print_error(c"\nAST optimizer dead regions kept: ")
	print_error(itoa(ast_opt_regions_kept))
	print_error(c"\nAST optimizer dead bytes removed: ")
	print_error(itoa(ast_opt_bytes_removed))
	print_error(c"\n")


# --- constant conditions --------------------------------------------------

# Folded values stay within +-2^30 at every step, so the result is the
# same on a 32-bit and a 64-bit host and target, and equals what the
# lowered instructions compute.
const int ast_opt_limit = 1073741824


int ast_opt_checked(int v):
	if ((v < 0 - ast_opt_limit) || (v > ast_opt_limit)): ast_opt_eval_failed = 1
	if (ast_opt_eval_failed): return 0
	return v


# The value of node id of a prepared condition tree, or ast_opt_eval_failed
# set. Literal values are decoded when the tree is prepared (its replay), so
# they are final here. Nodes: integer, char and bool literals,
# __word_size__ and __target_isa__; unary + - ~ ! !!; binary + - * / % & | ^
# << >>; comparisons; && and || chains; ?:. Anything else (a name, a call,
# a cast, a float) is not a constant to this pass.
int ast_opt_eval(expression_ast* tree, int id, int depth):
	if (ast_opt_eval_failed): return 0
	if ((id < 0) || (id >= tree.count) || (depth > 100)):
		ast_opt_eval_failed = 1
		return 0
	int op = tree.op[id]
	if ((op == 0) || (op == 'c') || (op == 'h')): return ast_opt_checked(tree.value[id])
	if ((op == 'p') || (op == 'n') || (op == '~') || (op == '!') || (op == 'b')):
		int v = ast_opt_eval(tree, tree.left[id], depth + 1)
		if (ast_opt_eval_failed): return 0
		if (op == 'n'): return ast_opt_checked(0 - v)
		if (op == '~'): return ast_opt_checked(~v)
		if (op == '!'): return v == 0
		if (op == 'b'): return v != 0
		return v
	if ((op == 'a') || (op == 'o')):
		# One node per chain: the first operand, then next_arg siblings.
		# Every operand must be a constant, short-circuited or not.
		int result = op == 'a'
		int child = tree.left[id]
		int count = 0
		while (child >= 0):
			int v = ast_opt_eval(tree, child, depth + 1)
			if (ast_opt_eval_failed): return 0
			if ((op == 'a') && (v == 0)): result = 0
			if ((op == 'o') && (v != 0)): result = 1
			child = tree.next_arg[child]
			count = count + 1
			if (count > 4096):
				ast_opt_eval_failed = 1
				return 0
		return result
	if (op == '?'):
		int condition = ast_opt_eval(tree, tree.left[id], depth + 1)
		int yes = ast_opt_eval(tree, tree.right[id], depth + 1)
		int no = ast_opt_eval(tree, tree.high[id], depth + 1)
		if (ast_opt_eval_failed): return 0
		if (condition): return yes
		return no
	int is_binary = (op == '+') || (op == '-') || (op == '*') || (op == '/') || (op == '%')
	is_binary = is_binary || (op == '&') || (op == '|') || (op == '^') || (op == 'L') || (op == 'R')
	int is_compare = (op == 0x94) || (op == 0x95) || (op == 0x9c) || (op == 0x9d) || (op == 0x9e) || (op == 0x9f)
	if ((is_binary || is_compare) == 0):
		ast_opt_eval_failed = 1
		return 0
	int left = tree.left[id]
	int right = tree.right[id]
	int a = ast_opt_eval(tree, left, depth + 1)
	int b = ast_opt_eval(tree, right, depth + 1)
	if (ast_opt_eval_failed): return 0
	# An unsigned operand type compares and shifts unsigned; leave it.
	if (unsigned_word_operand(tree.result_type[left], tree.result_type[right]) >= 0):
		ast_opt_eval_failed = 1
		return 0
	if (op == 0x94): return a == b
	if (op == 0x95): return a != b
	if (op == 0x9c): return a < b
	if (op == 0x9d): return a >= b
	if (op == 0x9e): return a <= b
	if (op == 0x9f): return a > b
	if (op == '+'): return ast_opt_checked(a + b)
	if (op == '-'): return ast_opt_checked(a - b)
	if (op == '*'):
		# |a|, |b| <= 2^30: check the product's size before forming it
		if ((a != 0) && (b != 0)):
			int ma = a
			int mb = b
			if (ma < 0): ma = 0 - ma
			if (mb < 0): mb = 0 - mb
			if (ma > ast_opt_limit / mb):
				ast_opt_eval_failed = 1
				return 0
		return ast_opt_checked(a * b)
	if ((op == '/') || (op == '%')):
		if (b == 0):
			ast_opt_eval_failed = 1
			return 0
		if (op == '/'): return ast_opt_checked(a / b)
		return ast_opt_checked(a % b)
	if (op == '&'): return ast_opt_checked(a & b)
	if (op == '|'): return ast_opt_checked(a | b)
	if (op == '^'): return ast_opt_checked(a ^ b)
	# Shifts: counts the target would not mask, results in range.
	if ((b < 0) || (b > 30)):
		ast_opt_eval_failed = 1
		return 0
	if (op == 'L'):
		if ((a > (ast_opt_limit >> b)) || (a < 0 - (ast_opt_limit >> b))):
			ast_opt_eval_failed = 1
			return 0
		return ast_opt_checked(a << b)
	return ast_opt_checked(a >> b)


int ast_opt_arm_key(control_ast_walk* control):
	if (control.loop != 0): return cast(int, control.loop)
	return cast(int, control.statement)


ast_opt_arm* ast_opt_arm_of(control_ast_walk* control):
	if (ast_opt_arms == 0): return 0
	int key = ast_opt_arm_key(control)
	ast_opt_arm* arm = ast_opt_arms
	while (arm != 0):
		if (arm.key == key): return arm
		arm = arm.next
	return 0


void ast_opt_arm_unlink(int key):
	ast_opt_arm* previous = 0
	ast_opt_arm* arm = ast_opt_arms
	while (arm != 0):
		ast_opt_arm* next = arm.next
		if (arm.key == key):
			if (previous == 0): ast_opt_arms = next
			else: previous.next = next
			free(cast(void*, arm))
		else: previous = arm
		arm = next


void ast_opt_arm_drop(control_ast_walk* control):
	if (ast_opt_arms != 0): ast_opt_arm_unlink(ast_opt_arm_key(control))


# The pass rewrites code on x86 and x64 Linux ELF only, and not under
# --profile-generate or --coverage, whose counters record code positions.
int ast_opt_rewrites():
	return (target_isa == 0) && (target_os == 0) && (profile_generate_mode == 0) && (coverage_generate_mode == 0)


# The parse hook: the arm's condition tree (root < 0 when the streaming
# grammar parsed it) before any of the arm's phases are emitted.
void ast_opt_guard(control_ast_walk* control, expression_ast* tree, int root):
	if (ast_opt_mode == 0): return
	int key = ast_opt_arm_key(control)
	if (ast_opt_arms != 0): ast_opt_arm_unlink(key)
	if ((root < 0) || (ast_opt_rewrites() == 0)): return
	ast_opt_eval_failed = 0
	int value = ast_opt_eval(tree, root, 0)
	if (ast_opt_eval_failed): return
	ast_opt_arm* arm = cast(ast_opt_arm*, malloc(sizeof(ast_opt_arm)))
	arm.key = key
	arm.fold = value != 0
	arm.cond_start = -1
	arm.region = 0
	arm.next = ast_opt_arms
	ast_opt_arms = arm


# --- dead regions -----------------------------------------------------------

ast_opt_region* ast_opt_region_open():
	dwarf_notes_ensure()
	ast_opt_region* region = cast(ast_opt_region*, malloc(sizeof(ast_opt_region)))
	region.start = codepos
	region.ctrl_pos = ctrl_stack_pos
	region.ctrl_heads = cast(int*, malloc((ctrl_stack_pos + 1) * __word_size__))
	for i in range(ctrl_stack_pos): region.ctrl_heads[i] = ctrl_val_stack[i]
	region.stack_depth = stack_pos
	region.addr_slots = be_addr_slot_writes
	region.rebases = rebase_count
	region.data_pos = datapos
	region.calls = emitted_call_count
	region.aligned_loops = profile_use_loops_aligned
	region.lines = debug_line_count
	if (debug_line_count > 0):
		int last = (debug_line_count - 1) * 4
		region.last_line = load_int(debug_line_lines + last)
		region.last_file = load_int(debug_line_file_indexes + last)
		region.last_stack = load_int(debug_line_stack_pos + last)
	region.locals = debug_local_count
	region.events = dwarf_events.length
	region.blocks = dwarf_blocks.length
	region.leaves = dwarf_leaves.length
	region.funcs = dwarf_funcs.length
	region.open_blocks = dwarf_block_stack.length
	region.block_flags = cast(int*, malloc((dwarf_block_stack.length + 1) * __word_size__))
	for i in range(dwarf_block_stack.length): region.block_flags[i] = dwarf_blocks[dwarf_block_stack[i] * 3 + 2]
	return region


void ast_opt_region_free(ast_opt_region* region):
	free(cast(void*, region.ctrl_heads))
	free(cast(void*, region.block_flags))
	free(cast(void*, region))


# 1 when nothing outside [region.start, codepos) can refer to the bytes
# emitted since the region opened.
int ast_opt_region_contained(ast_opt_region* region):
	if (codepos < region.start): return 0
	if (stack_pos != region.stack_depth): return 0
	if (be_addr_slot_writes != region.addr_slots): return 0
	if (rebase_count != region.rebases): return 0
	if (datapos != region.data_pos): return 0
	if (emitted_call_count != region.calls): return 0
	if (profile_use_loops_aligned != region.aligned_loops): return 0
	if (dwarf_funcs.length != region.funcs): return 0
	if (dwarf_block_stack.length != region.open_blocks): return 0
	if ((debug_line_count < region.lines) || (debug_local_count < region.locals)): return 0
	# Regions opened inside must be closed; one closed inside (an if arm's
	# alternate) must have had no branch into it.
	if (ctrl_stack_pos > region.ctrl_pos): return 0
	for i in range(ctrl_stack_pos, region.ctrl_pos):
		if ((ctrl_kind_stack[i] != 0) || (region.ctrl_heads[i] != 0)): return 0
	# A label placed in the region, or a goto in it still waiting for
	# its label, would keep a code position inside it.
	for i in range(goto_label_base, goto_label_count):
		if (goto_label_pos[i] >= region.start): return 0
	for i in range(goto_pending_base, goto_pending_count):
		if ((goto_pending_label[i] >= 0) && (goto_pending_site[i] >= region.start)): return 0
	return 1


# Take back the bytes emitted since the region opened, and every record of
# them, when they are contained. Returns 1 when the region was removed.
int ast_opt_region_close(ast_opt_arm* arm):
	ast_opt_region* region = arm.region
	if (region == 0): return 0
	arm.region = 0
	if (ast_opt_region_contained(region) == 0):
		ast_opt_regions_kept = ast_opt_regions_kept + 1
		ast_opt_region_free(region)
		return 0
	ast_opt_bytes_removed = ast_opt_bytes_removed + codepos - region.start
	ast_opt_regions_removed = ast_opt_regions_removed + 1
	peep_rollback(region.start)
	be_notes_reset()
	if (const_note_codepos > region.start): const_note_codepos = -1
	if (last_call_end > region.start): last_call_end = 0
	# Branches the region threaded into enclosing regions' chains (break,
	# continue's block twins, the arm's own jump) go with its bytes.
	for i in range(ctrl_stack_pos):
		if (ctrl_kind_stack[i] == 0): ctrl_val_stack[i] = region.ctrl_heads[i]
	# DWARF and wdbg records of the removed code.
	debug_line_count = region.lines
	if (region.lines > 0):
		int last = (region.lines - 1) * 4
		save_int(debug_line_lines + last, region.last_line)
		save_int(debug_line_file_indexes + last, region.last_file)
		save_int(debug_line_stack_pos + last, region.last_stack)
	debug_local_count = region.locals
	while (dwarf_events.length > region.events): dwarf_events.pop()
	while (dwarf_blocks.length > region.blocks): dwarf_blocks.pop()
	while (dwarf_leaves.length > region.leaves): dwarf_leaves.pop()
	for i in range(dwarf_block_stack.length): dwarf_blocks[dwarf_block_stack[i] * 3 + 2] = region.block_flags[i]
	ast_opt_region_free(region)
	return 1


# Remove and return the region a rotated loop opened at its begin phase,
# 0 when it opened none.
ast_opt_region* ast_opt_loop_take(control_ast_walk* control):
	if ((ast_opt_loops == 0) || (control.loop == 0)): return 0
	int key = ast_opt_arm_key(control)
	ast_opt_region* region = 0
	ast_opt_loop* previous = 0
	ast_opt_loop* record = ast_opt_loops
	while (record != 0):
		ast_opt_loop* next = record.next
		if (record.key == key):
			if (previous == 0): ast_opt_loops = next
			else: previous.next = next
			if (region != 0): ast_opt_region_free(region)
			region = record.region
			free(cast(void*, record))
		else: previous = record
		record = next
	return region


void ast_opt_loop_drop(control_ast_walk* control):
	ast_opt_region* region = ast_opt_loop_take(control)
	if (region != 0): ast_opt_region_free(region)


# --- the walk hooks -----------------------------------------------------------

# A while loop's begin phase has run (emit_while_loop_ast_begin): a rotated
# loop's body starts here, so this is where a dead body's region opens. A
# record left by a loop that never reached its end phase (an error unwound
# its frame) is replaced, as an arm's is.
void ast_opt_while_begin(control_ast_walk* control):
	if (ast_opt_mode == 0): return
	if ((control.loop == 0) || (control.loop.entry_site < 0)): return
	ast_opt_loop_drop(control)
	if (ast_opt_rewrites() == 0): return
	ast_opt_loop* record = cast(ast_opt_loop*, malloc(sizeof(ast_opt_loop)))
	record.key = ast_opt_arm_key(control)
	record.region = ast_opt_region_open()
	record.next = ast_opt_loops
	ast_opt_loops = record


# The condition's lowering is about to run: where its bytes start.
void ast_opt_condition_start(control_ast_walk* control):
	if (ast_opt_mode == 0): return
	ast_opt_arm* arm = ast_opt_arm_of(control)
	if (arm == 0): return
	arm.cond_start = codepos
	arm.cond_ctrl_pos = ctrl_stack_pos
	arm.cond_stack_depth = stack_pos
	arm.cond_addr_slots = be_addr_slot_writes


# One phase of a folded arm's walk (emit_guard_ast_walk). Returns 1 when
# the phase was emitted here, 0 to emit it as usual (after any region
# bookkeeping done here).
int ast_opt_guard_phase(control_ast_walk* control, statement_ast* guard, int phase):
	if (ast_opt_mode == 0): return 0
	ast_opt_arm* arm = ast_opt_arm_of(control)
	if (arm == 0):
		# A rotated loop whose condition did not fold keeps its body
		if (phase == ast_walk_while_end): ast_opt_loop_drop(control)
		return 0
	if (phase == ast_walk_guard_value):
		emit_guard_ast_value(guard)
		# A constant chain in discard position (grammar/cond_branch.w)
		# is pending: its branch sites are all in the condition's bytes,
		# which go below, so its regions go with them.
		if (cond_pending): cond_pending_discard()
		# The lowered constant left nothing else behind; if it did, the
		# arm is emitted as usual.
		int clean = (arm.cond_start >= 0) && (arm.cond_ctrl_pos == ctrl_stack_pos) && (arm.cond_stack_depth == stack_pos) && (arm.cond_addr_slots == be_addr_slot_writes)
		if (clean == 0):
			ast_opt_arm_drop(control)
			return 1
		peep_rollback(arm.cond_start)
		be_notes_reset()
		if (const_note_codepos > arm.cond_start): const_note_codepos = -1
		return 1
	if (phase == ast_walk_guard_branch):
		if ((control.loop != 0) && (control.loop.entry_site >= 0)):
			# A rotated loop's bottom test: the branch is the back edge,
			# taken when the condition is true. 'while 1' is one jump to
			# the body (what the default compile's constant fold emits
			# too); 'while 0' falls through to the exit, and the body
			# emitted before it is the dead region opened at the begin
			# phase, closed at the end phase.
			guard.target = control.loop.top_target
			ast_opt_conditions_folded = ast_opt_conditions_folded + 1
			ast_opt_region* body = ast_opt_loop_take(control)
			if (arm.fold): be_br(guard.target)
			if (arm.fold == 0): arm.region = body
			elif (body != 0): ast_opt_region_free(body)
			return 1
		if (control.loop != 0): guard.target = control.loop.break_target
		else: guard.target = control.statement.alternate_target
		ast_opt_conditions_folded = ast_opt_conditions_folded + 1
		if (arm.fold == 0):
			# The body is dead: jump past it, and take the jump back too
			# if the body goes.
			arm.region = ast_opt_region_open()
			be_br(guard.target)
		return 1
	if (phase == ast_walk_if_then_end):
		if (arm.fold == 0):
			if (ast_opt_region_close(arm)):
				# Nothing of the arm is left to jump past the else arms.
				be_ctrl_end(control.statement.alternate_target)
				return 1
			return 0
		# 'if 1': the jump past the else arms and the arms themselves
		# are dead.
		arm.region = ast_opt_region_open()
		return 0
	if (phase == ast_walk_if_end):
		if (arm.fold): ast_opt_region_close(arm)
		ast_opt_arm_drop(control)
		return 0
	if (phase == ast_walk_while_end):
		if (control.loop.entry_site >= 0):
			# The rotated loop's entry jump was resolved to the bottom
			# test; a removed body leaves it pointing past the bytes
			# that follow, so it is re-resolved to the next instruction.
			if ((arm.fold == 0) && ast_opt_region_close(arm)): be_branch_patch(control.loop.entry_site, codepos)
			ast_opt_arm_drop(control)
			return 0
		int removed = (arm.fold == 0) && ast_opt_region_close(arm)
		ast_opt_arm_drop(control)
		if (removed == 0): return 0
		# 'while 0' without its body: no back edge to emit.
		be_ctrl_end(control.loop.top_target)
		be_ctrl_end(control.loop.break_target)
		ast_while_loops_emitted = ast_while_loops_emitted + 1
		return 1
	return 0
