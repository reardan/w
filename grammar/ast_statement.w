# Statement grammar builds resolved nodes and visits child statements
# in source order. Backend phases consume their payloads and control
# targets; body traversal remains incremental, without retained child lists.

# S2.2a: under --ast-emit-retained, a simple, expression or return/yield
# statement is parsed completely before any of its code is emitted: the
# parse records the statement's walk (its node, its expression's retained
# group and each emission step at the lexer state it ran in, see
# code_generator/retained_emit.w), and retained_emit_statement emits it
# once the terminator is consumed. A statement that cannot start a walk
# (the mode is off, or no retained statement node owns it) is emitted
# during its parse as before.

# The statement terminator. Accepting ';' lexes the next token, and a
# missing terminator is an error; both print, so the steps recorded so far
# are emitted first, where the streaming emitter had emitted them.
void ast_statement_walk_terminator(int walk):
	if ((peek(c";") == 0) && (token_newline || (token[0] == 0))): return
	retained_walk_drain(walk)
	expect_or_newline(c";")


# Lexing the token after a prepared root prints an indentation warning when
# a line between them starts with a space, an end-of-file warning when the
# source ends without a newline, and an error for an unterminated literal.
# Returns 0 only when the raw bytes up to the newline after that token show
# none of these can happen; anything not visible in the read window is
# reported as possible.
int ast_statement_lex_may_print(expression_ast* tree):
	if (tree.whole_expression == 0): return 0
	if ((file < 0) || (file >= GETCHAR_MAX_FD) || (nextc < 0)): return 1
	int window_start = getchar_kernel_pos[file] - getchar_limit[file]
	int window_end = getchar_kernel_pos[file]
	int start = byte_offset - 1
	int end = tree.end_offset
	if ((start < window_start) || (start > end) || (end + 1 >= window_end)): return 1
	char* bytes = cast(char*, getchar_buf_addr[file] - window_start)
	for at in range(start, end):
		if ((bytes[at] == 10) && (bytes[at + 1] == ' ')): return 1
	for at in range(end, end + 2):
		int c = bytes[at]
		if ((c == '"') || (c == 39) || (c == '`')): return 1
	for at in range(end, window_end):
		if (bytes[at] == 10): return 0
	return 1


# Record a prepared expression child and lex the token after it, as
# ast_statement_finish_expression does, without lowering it: the walk lowers
# it at the point recorded here, then replays the root's end warnings at the
# token after it.
void ast_statement_walk_expression(int walk, statement_ast* node):
	expression_ast* tree = node.expression_tree
	retained_walk_expression(walk, tree, node.expression_root)
	node.expression_tree = retained_walks[walk].tree
	retained_walk_phase(walk, ast_walk_expression)
	if (ast_statement_lex_may_print(tree)): retained_walk_drain(walk)
	if (tree.whole_expression):
		token_start_offset = tree.final_token_offset
		get_token()
	retained_walk_phase(walk, ast_walk_expression_end)


int ast_statement_simple(int* jumps):
	if (ast_expressions_mode < 2): return 0
	int kind = 0
	if (peek(c"pass")): kind = ast_stmt_pass
	else if (peek(c"debugger")): kind = ast_stmt_debugger
	else if (peek(c"break")): kind = ast_stmt_break
	else if (peek(c"continue")): kind = ast_stmt_continue
	if (kind == 0): return 0
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = kind
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset + token_i
	node.target = 0
	node.unwind_slots = 0
	node.valid_jump = 1
	if (kind == ast_stmt_break):
		*jumps = 1
		node.valid_jump = (loop_depth != 0) || (switch_depth != 0)
		if (break_in_switch): flow_switch_break = 1
		else: flow_loop_break = 1
		if (break_in_switch):
			node.target = switch_break_chain
			node.unwind_slots = stack_pos - switch_stack_pos
		else:
			node.target = loop_break_chain
			node.unwind_slots = stack_pos - loop_stack_pos
	else if (kind == ast_stmt_continue):
		*jumps = 1
		node.valid_jump = loop_depth != 0
		node.target = loop_continue_chain
		node.unwind_slots = stack_pos - loop_stack_pos
	get_token()
	# The debugger marker historically precedes terminator diagnostics;
	# branch validation historically follows them. Preserve both orders.
	int walk = retained_walk_begin(cast(int, emit_statement_ast_walk), node)
	if (walk >= 0):
		if (kind == ast_stmt_debugger): retained_walk_phase(walk, ast_walk_simple)
		ast_statement_walk_terminator(walk)
		if (kind != ast_stmt_debugger): retained_walk_phase(walk, ast_walk_simple)
		retained_emit_statement(retained_walks[walk].node)
		return 1
	if (kind == ast_stmt_debugger): emit_simple_statement_ast(node)
	expect_or_newline(c";")
	if (kind != ast_stmt_debugger): emit_simple_statement_ast(node)
	return 1


int ast_expression_prepare_at(expression_ast* tree, int group_offset, int whole);
void ast_expression_finish_prepared(expression_ast* tree);


void ast_statement_finish_expression(statement_ast* node):
	if (node.expression_root < 0): return
	ast_expression_finish_prepared(node.expression_tree)
	ast_roots_emitted = ast_roots_emitted + 1



int ast_statement_value(int* jumps):
	if (ast_expressions_mode < 2): return 0
	int kind = 0
	if (peek(c"return")): kind = ast_stmt_return
	else if (peek(c"yield")): kind = ast_stmt_yield
	if (kind == 0): return 0
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = kind
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.end_offset = token_start_offset + token_i
	node.generator = in_generator_body
	node.expression_tree = 0
	node.expression_root = -1
	get_token()
	int has_value = 1
	if (kind == ast_stmt_return):
		*jumps = 1
		flow_saw_return = 1
		if (in_gpu_for_body): error(c"'return' is not supported in 'gpu for'")
		has_value = (peek(c";") == 0) && (token_newline == 0) && (token[0] != 0)
		if (has_value && in_generator_body): error(c"generators cannot return a value; use yield")
	else if (in_generator_body == 0): error(c"'yield' outside of a generator body")
	expression_ast tree
	if (has_value):
		increment_statement_context = 0
		expression_lhs_readonly = 0
		int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
		if (root < 0):
			# The expression probe restored its entry state. Existing
			# tails retain diagnostic fallback and required-mode errors.
			if (kind == ast_stmt_return): return_statement_tail(node.line - 1, node.line, node.column)
			else: yield_statement_tail()
			return 1
		node.expression_tree = &tree
		node.expression_root = root
		node.end_offset = tree.end_offset
	node.declared_type = 0
	if (has_value): node.declared_type = load_int(table + current_function_symbol + 6)
	int walk = retained_walk_begin(cast(int, emit_statement_ast_walk), node)
	if (walk >= 0):
		if (has_value):
			ast_statement_walk_expression(walk, node)
			retained_walk_phase(walk, ast_walk_value)
		ast_statement_walk_terminator(walk)
		retained_walk_phase(walk, ast_walk_exit)
		retained_emit_statement(retained_walks[walk].node)
		return 1
	emit_statement_ast_expression(node)
	ast_statement_finish_expression(node)
	emit_statement_ast_value(node)
	expect_or_newline(c";")
	emit_statement_ast_exit(node)
	return 1


# Prefix increment has its earlier dispatch position. All other expression
# statements arrive here only after declarations, labels and special forms
# have had their normal precedence in the statement dispatcher.
int ast_statement_expression(int prefix_only):
	if (ast_expressions_mode < 2): return 0
	if (prefix_only && (increment_op() == 0)): return 0
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_expression
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	increment_statement_context = 0
	expression_lhs_readonly = 0
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 2)
	if (root < 0): return 0
	node.expression_tree = &tree
	node.expression_root = root
	node.end_offset = tree.end_offset
	int walk = retained_walk_begin(cast(int, emit_statement_ast_walk), node)
	if (walk >= 0):
		ast_statement_walk_expression(walk, node)
		ast_expression_statements_emitted = ast_expression_statements_emitted + 1
		ast_statement_walk_terminator(walk)
		retained_emit_statement(retained_walks[walk].node)
		return 1
	emit_statement_ast_expression(node)
	ast_statement_finish_expression(node)
	ast_expression_statements_emitted = ast_expression_statements_emitted + 1
	expect_or_newline(c";")
	return 1


# A conditional branch owns its expression and resolved failure target.
# Enclosing if/while bodies still use their streaming scope dispatcher.
# S2.2b: under an if/while walk (control_ast_guard_pending), the condition
# is parsed, and the token after it lexed, before the header's phases are
# emitted (ast_statement_walk_expression emits them before that lex when
# it cannot rule out a lexer diagnostic). They are emitted here, before
# the lint and condition state the lowering reads is reset (and before
# statement_guard's constant-true check, which reads the 'true' tokens the
# lowering replays); the branch target is read from the region the
# header's begin phase opened.
void ast_statement_guard(int target, int outer_condition):
	control_ast_walk* control = control_ast_guard_pending
	control_ast_guard_pending = 0
	int walk = -1
	if (control != 0): walk = control.walk
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_guard
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.target = target
	node.expression_tree = 0
	node.expression_root = -1
	lint_condition_begin()
	increment_statement_context = 0
	expression_lhs_readonly = 0
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	# C3.5: the optimizer pass reads the condition before the walk emits
	# any of the arm (compiler/ast_opt.w, --ast-opt).
	if (control != 0): ast_opt_guard(control, &tree, root)
	if (walk >= 0): retained_walks[walk].statement = node
	if (root < 0):
		# The streaming grammar emits as it parses: the header's
		# recorded phases come first.
		if (walk >= 0): retained_walk_drain(walk)
		promote(expression())
		node.end_offset = token_start_offset
	else:
		node.expression_tree = &tree
		node.expression_root = root
		node.end_offset = tree.end_offset
		if (walk >= 0):
			ast_statement_walk_expression(walk, node)
			retained_walk_phase(walk, ast_walk_guard_value)
		else:
			emit_statement_ast_expression(node)
			ast_statement_finish_expression(node)
			emit_guard_ast_value(node)
	if (walk >= 0):
		retained_walk_phase(walk, ast_walk_guard_branch)
		retained_walk_drain(walk)
		retained_walks[walk].statement = 0
		lint_condition_end()
		condition_context = outer_condition
		return
	lint_condition_end()
	condition_context = outer_condition
	emit_guard_ast_branch(node)


# S2.2c: control headers (switch here, for loops in grammar/ast_loop.w)
# under a walk. A header is parsed before its code is emitted: each
# emission step is recorded as a phase of the statement's walk and emitted
# by it (emit_switch_ast_walk, emit_loop_ast_walk). With no walk open
# (walk < 0) the same steps run in place, as before.
#
# What may not move past a pending phase:
# - a step that may print (an error, or a lex that may warn), since the
#   phases may print too: the walk is drained first (ast_walk_settle,
#   ast_walk_lex);
# - the next header value's preparation, which commits types, symbols and
#   literal notes the pending lowering would otherwise follow, and may
#   print: values are walked one at a time;
# - the body, whose parse reads the stack depth and the break and
#   continue context the header's phases set up.


# 1 unless the raw source bytes show that lexing the next token cannot
# print: no line before it starts with a space (the indentation warning),
# it is not a literal, a comment opener or non-ASCII (unterminated-literal
# and identifier errors), and a newline follows it inside the read window
# (the end-of-file warning).
int ast_walk_lex_may_print():
	if ((file < 0) || (file >= GETCHAR_MAX_FD) || (nextc < 0)): return 1
	int window_start = getchar_kernel_pos[file] - getchar_limit[file]
	int window_end = getchar_kernel_pos[file]
	int at = byte_offset - 1
	if ((at < window_start) || (at >= window_end)): return 1
	char* bytes = cast(char*, getchar_buf_addr[file] - window_start)
	if ((bytes[at] & 255) != nextc): return 1
	while (at < window_end):
		int c = bytes[at] & 255
		if (c == 10):
			if ((at + 1 < window_end) && (bytes[at + 1] == ' ')): return 1
			at = at + 1
		else if ((c == ' ') || (c == 9)): at = at + 1
		else if (c == '#'):
			while ((at < window_end) && (bytes[at] != 10)): at = at + 1
		else: break
	if (at >= window_end): return 1
	int first = bytes[at] & 255
	if ((first == '"') || (first == 39) || (first == '`') || (first == '/')): return 1
	for k in range(at, window_end):
		int c = bytes[k] & 255
		if (c == 10): return 0
		if ((c == '"') || (c >= 128)): return 1
	return 1


# Emit the phases recorded so far before a parse step that may print or
# that reads what they set up.
void ast_walk_settle(int walk):
	if (walk >= 0): retained_walk_drain(walk)


# Before lexing the next token.
void ast_walk_lex(int walk):
	if ((walk >= 0) && ast_walk_lex_may_print()): retained_walk_drain(walk)


int ast_walk_accept(int walk, char* s):
	if (peek(s) == 0): return 0
	ast_walk_lex(walk)
	get_token()
	return 1


void ast_walk_expect(int walk, char* s):
	if (peek(s) == 0): ast_walk_settle(walk)
	else: ast_walk_lex(walk)
	expect(s)


# A header value: the switch selector, a case value, a range argument or
# an iterable. The caller drains the walk first (no pending phase may still
# read node, and the preparation must follow the previous value's
# lowering) and sets node.kind. Under a walk, the value's
# lowering (lower_phase) and the end-of-root warnings at the token after it
# (end_phase) are recorded, and that token is lexed now; otherwise the
# value is lowered in place. A value the expression probe declines is
# parsed by the streaming grammar, which emits as it parses.
void ast_walk_header_value(int walk, statement_ast* node, expression_ast* tree, int lower_phase, int end_phase):
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.expression_tree = 0
	node.expression_root = -1
	increment_statement_context = 0
	expression_lhs_readonly = 0
	int root = ast_expression_prepare_at(tree, token_start_offset, 1)
	if (root < 0):
		node.expression_type = expression()
		node.end_offset = token_start_offset
		return
	node.expression_tree = tree
	node.expression_root = root
	node.end_offset = tree.end_offset
	if (walk < 0):
		emit_statement_ast_expression(node)
		ast_statement_finish_expression(node)
		return
	retained_walk_expression(walk, tree, root)
	node.expression_tree = retained_walks[walk].tree
	retained_walk_phase(walk, lower_phase)
	if (ast_statement_lex_may_print(tree)): retained_walk_drain(walk)
	if (tree.whole_expression):
		token_start_offset = tree.final_token_offset
		get_token()
	retained_walk_phase(walk, end_phase)


void ast_switch_step(int walk, switch_ast_walk* record, int phase):
	if (walk >= 0): retained_walk_phase(walk, phase)
	else: emit_switch_ast_phase(record, 0, phase)


# The scrutinee is evaluated exactly once, into a hidden stack slot.
void ast_switch_selector(int walk, switch_ast_walk* record, expression_ast* tree):
	ast_walk_settle(walk)
	record.value.kind = ast_stmt_switch_value
	ast_walk_header_value(walk, record.value, tree, switch_walk_value, switch_walk_value_end)
	ast_switch_step(walk, record, switch_walk_selector)


# One case value: compare it with the scrutinee and branch to the body
# when it matches and more values follow, past the case when it does not
# match and is the last. Returns 1 when another value follows.
int ast_switch_case_value(int walk, switch_ast_walk* record, expression_ast* tree):
	ast_walk_settle(walk)
	statement_ast* value = record.value
	value.kind = ast_stmt_switch_case
	ast_switch_step(walk, record, switch_walk_case_begin)
	record.case_start = switch_case_start()
	record.case_line = line_number
	ast_walk_header_value(walk, value, tree, switch_walk_value, switch_walk_value_end)
	ast_switch_step(walk, record, switch_walk_case_note)
	ast_switch_step(walk, record, switch_walk_case_compare)
	value.branch_nonzero = ast_walk_accept(walk, c",")
	ast_switch_step(walk, record, switch_walk_case_branch)
	return value.branch_nonzero


# The value hooks of the streaming switch rule (grammar/switch_statement.w);
# ast_switch_statement walks its values itself.
int ast_statement_switch_value():
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	switch_ast_walk local_record
	switch_ast_walk* record = cast(switch_ast_walk*, retained_parse_record(&local_record, sizeof(switch_ast_walk)))
	record.node = node
	record.value = value
	expression_ast tree
	ast_switch_selector(-1, record, &tree)
	return node.declared_type


int ast_statement_switch_case(int type, int slot, int body_target, int next_target):
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.declared_type = type
	node.stack_depth = slot
	node.body_target = body_target
	node.alternate_target = next_target
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	switch_ast_walk local_record
	switch_ast_walk* record = cast(switch_ast_walk*, retained_parse_record(&local_record, sizeof(switch_ast_walk)))
	record.node = node
	record.value = value
	expression_ast tree
	return ast_switch_case_value(-1, record, &tree)


# One if or elif arm; walk is the chain's walk record, or -1 when the
# chain is emitted during its parse. The then-arm's exit phase stays
# pending across the 'elif'/'else' lex (it cannot print); every body is
# preceded by a drain, an elif arm drains the enclosing arm's phases
# before it swaps its node in, and each arm drains before it returns.
void ast_if_statement_arm(int walk, control_ast_walk* control):
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_if
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	int if_tab_level = tab_level
	int outer_condition = condition_context
	condition_context = 1
	statement_ast* outer_arm = 0
	if (walk >= 0):
		# The enclosing arm's then-exit acts on its own node.
		retained_walk_drain(walk)
		outer_arm = control.statement
		control.statement = node
		retained_walk_phase(walk, ast_walk_if_begin)
		control_ast_guard_pending = control
	else: emit_if_ast_begin(node)
	statement_guard(node.alternate_target, outer_condition)
	enclosing_tab_level = if_tab_level
	if (walk >= 0): retained_walk_drain(walk)
	statement()
	# Fall-through bookkeeping mirrors if_statement_tail
	# (grammar/statement.w, grammar/type_check.w)
	int arms_terminate = flow_terminates
	int has_else = 0
	if (walk >= 0): retained_walk_phase(walk, ast_walk_if_then_end)
	else: emit_if_ast_then_end(node)
	if (peek(c"elif") && (tab_level == if_tab_level)):
		if (coverage_generate_mode):
			if (walk >= 0): retained_walk_drain(walk)
			profile_coverage_line()
		get_token()
		stmt_nesting_depth = stmt_nesting_depth + 1
		if (stmt_nesting_depth > 200): error(c"statement nesting too deep")
		ast_if_statement_arm(walk, control)
		stmt_nesting_depth = stmt_nesting_depth - 1
		has_else = 1
		arms_terminate = arms_terminate && flow_terminates
	else if (peek(c"else")):
		if (tab_level == if_tab_level):
			get_token()
			enclosing_tab_level = if_tab_level
			if (walk >= 0): retained_walk_drain(walk)
			statement()
			has_else = 1
			arms_terminate = arms_terminate && flow_terminates
	node.end_offset = token_start_offset
	if (walk >= 0):
		retained_walk_phase(walk, ast_walk_if_end)
		retained_walk_drain(walk)
		control.statement = outer_arm
	else: emit_if_ast_end(node)
	flow_terminates = has_else && arms_terminate


# S2.2b: under --ast-emit-retained the whole chain is one statement walk
# (emit_guard_ast_walk): each arm's header, 'if'/'elif' and its condition,
# is parsed before its phases are emitted.
void ast_if_statement_tail():
	int walk = retained_walk_begin(cast(int, emit_guard_ast_walk), 0)
	if (walk < 0):
		ast_if_statement_arm(-1, 0)
		return
	control_ast_walk local_control
	control_ast_walk* control = cast(control_ast_walk*, retained_parse_record(&local_control, sizeof(control_ast_walk)))
	control.statement = 0
	control.loop = 0
	control.outer = 0
	control_ast_walk_attach(walk, control)
	ast_if_statement_arm(walk, control)
	retained_emit_statement(retained_walks[walk].node)


# S2.2b: under --ast-emit-retained a block is a statement walk
# (emit_block_ast_walk): its opening token is lexed before the scope is
# opened, and the body's statements are walked by their own families. The
# deferred statements are emitted before the unused-local lint, which may
# print; the scope end and unwind are emitted after the body is parsed.
int ast_statement_block():
	if (ast_expressions_mode < 2): return 0
	int kind = 0
	if (peek(c"{")): kind = ast_stmt_brace_block
	else if (peek(c":")): kind = ast_stmt_indent_block
	if (kind == 0): return 0
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = kind
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	int block_tab_level = enclosing_tab_level
	get_token()
	node.binding = table_pos
	int walk = retained_walk_begin(cast(int, emit_block_ast_walk), node)
	if (walk >= 0): retained_walk_phase(walk, ast_walk_block_begin)
	else:
		node.stack_depth = stack_pos
		dwarf_block_begin()
	int start_tab_level = tab_level
	if ((walk < 0) && (kind == ast_stmt_indent_block)): print_int_v1(c"starting stack_pos: ", stack_pos)
	node.function_body = defer_function_body_pending
	defer_function_body_pending = 0
	if (walk >= 0): retained_walk_drain(walk)
	# Fall-through bookkeeping mirrors statement_impl's block loops
	# (grammar/statement.w, grammar/type_check.w)
	int terminates = 0
	if (kind == ast_stmt_brace_block):
		int after_jump = 0
		while (accept(c"}") == 0):
			lint_unreachable_check(after_jump)
			if ((nextc == ':') && is_ident_start_byte(token[0])): terminates = 0
			statement()
			after_jump = lint_last_stmt_jumps
			if (flow_terminates): terminates = 1
	else:
		int same_line = 0
		if (token_newline == 0):
			same_line = 1
			if (token[0] != 0):
				statement()
				terminates = flow_terminates
		if ((same_line == 0) && (start_tab_level > block_tab_level)):
			int after_jump = 0
			while (start_tab_level <= tab_level):
				lint_unreachable_check(after_jump)
				if ((nextc == ':') && is_ident_start_byte(token[0])): terminates = 0
				statement()
				after_jump = lint_last_stmt_jumps
				if (flow_terminates): terminates = 1
	node.end_offset = token_start_offset
	if (walk >= 0):
		retained_walk_phase(walk, ast_walk_block_deferred)
		retained_walk_drain(walk)
		lint_scope_exit(node.binding)
		table_pos = node.binding
		retained_walk_phase(walk, ast_walk_block_end)
		retained_emit_statement(retained_walks[walk].node)
		flow_terminates = terminates
		return 1
	emit_block_ast_deferred(node)
	lint_scope_exit(node.binding)
	dwarf_block_end()
	table_pos = node.binding
	if (kind == ast_stmt_indent_block): print_int_v1(c"ending stack_pos: ", stack_pos)
	emit_block_ast_end(node)
	flow_terminates = terminates
	return 1


int ast_switch_statement():
	if (peek(c"switch") == 0): return 0
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_switch
	node.unwind_slots = 1
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	get_token()

	int switch_tab_level = tab_level

	# S2.2c: under --ast-emit-retained the switch is walked from its record;
	# its phases are drained before each case body, whose parse reads the
	# scrutinee slot and the break region.
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	expression_ast tree
	switch_ast_walk local_record
	switch_ast_walk* record = cast(switch_ast_walk*, retained_parse_record(&local_record, sizeof(switch_ast_walk)))
	record.node = node
	record.value = value
	int walk = retained_walk_begin(cast(int, emit_switch_ast_walk), cast(statement_ast*, record))

	# The scrutinee is evaluated exactly once, into a hidden stack slot
	ast_switch_selector(walk, record, &tree)

	ast_walk_expect(walk, c":")
	if ((token_newline == 0) && (token[0] != 0)):
		ast_walk_settle(walk)
		error(c"switch body must start on a new line")

	# Enter a new break context: 'break' in a case body exits the switch.
	# One region serves both exits — each body's implicit break and every
	# explicit 'break' branch to the switch end.
	record.outer_chain = switch_break_chain
	record.outer_stack = switch_stack_pos
	record.outer_in_switch = break_in_switch
	ast_switch_step(walk, record, switch_walk_region)
	ast_switch_step(walk, record, switch_walk_enter)

	int seen_default = 0
	# Fall-through bookkeeping and duplicate-case values mirror
	# switch_statement (grammar/switch_statement.w)
	int outer_seen_base = switch_seen_base
	switch_seen_base = switch_seen_count
	int outer_switch_break = flow_switch_break
	flow_switch_break = 0
	int every_case_terminates = 1

	while ((tab_level > switch_tab_level) && (token[0] != 0)):
		int label_tab_level = tab_level
		if (seen_default):
			ast_walk_settle(walk)
			error(c"'default' must be the last clause in a switch")

		# Region for jumps past this case while its values do not match
		ast_switch_step(walk, record, switch_walk_case_region)
		if (ast_walk_accept(walk, c"case")):
			# Multi-value case: any matching value jumps to the body
			ast_switch_step(walk, record, switch_walk_match_region)
			int more = 1
			while (more): more = ast_switch_case_value(walk, record, &tree)
			ast_switch_step(walk, record, switch_walk_match_end)
		else if (ast_walk_accept(walk, c"default")): seen_default = 1
		else:
			ast_walk_settle(walk)
			error(c"'case' or 'default' expected in switch body")

		# The body is an ordinary ':' block scoped to the label's line
		ast_walk_settle(walk)
		enclosing_tab_level = label_tab_level
		statement()
		if (flow_terminates == 0): every_case_terminates = 0

		# Implicit break: leave the switch after the body (no fallthrough)
		ast_switch_step(walk, record, switch_walk_case_end)

	# No-match fallthrough, each body's exit jump, and 'break' all land
	# here, before the scrutinee slot is discarded
	node.end_offset = token_start_offset
	ast_switch_step(walk, record, switch_walk_region_end)

	ast_switch_step(walk, record, switch_walk_leave)
	switch_seen_count = switch_seen_base
	switch_seen_base = outer_seen_base
	int switch_terminates = seen_default && every_case_terminates && (flow_switch_break == 0)
	flow_switch_break = outer_switch_break

	# Discard the hidden scrutinee slot
	ast_switch_step(walk, record, switch_walk_cleanup)
	if (walk >= 0): retained_emit_statement(retained_walks[walk].node)
	flow_terminates = switch_terminates

	return 1


# Build at the exit site: bindings and temporary stack depth intentionally
# differ from registration. Deferred expressions retain value-expression
# syntax; statement-only increments and parallel stores stay disallowed.
int ast_deferred_expression():
	if (ast_expressions_mode < 2): return 0
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_deferred_expression
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	increment_statement_context = 0
	expression_lhs_readonly = 0
	expression_ast tree
	int root = ast_expression_prepare_at(&tree, token_start_offset, 1)
	if (root < 0): return 0
	node.expression_tree = &tree
	node.expression_root = root
	node.end_offset = tree.end_offset
	emit_statement_ast_expression(node)
	ast_statement_finish_expression(node)
	ast_deferred_expressions_emitted = ast_deferred_expressions_emitted + 1
	return 1
