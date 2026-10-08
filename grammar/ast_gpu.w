# GPU headers own prepared expression children. Dimensions leave their
# value in the accumulator so syntax checks can precede the slot push.
#
# S2.2e: under --ast-emit-retained, a launch statement and a gpu for
# header are parsed before their code is emitted: the parse records the
# emission steps as phases of the statement's walk (emit_gpu_walk_ast,
# code_generator/gpu_ast.w; see code_generator/retained_emit.w) and
# retained_emit_statement emits them. A launch is walked once its argument
# list and arity check are parsed; a gpu for's range operands and its
# host-side tail (captures and the runtime call) are walked, while the
# outlined kernel's prologue and guard are emitted before its body parses
# (device mode, the capture table and the loop variable's slot are state
# the body's parse reads) and its epilogue before the host resolves the
# captures. The parse drains the phases recorded so far before any step
# that may print, so diagnostics keep their streaming order: before a
# value is prepared (preparing replays warnings and decodes literals),
# before a token is lexed unless ast_gpu_lex_may_print rules it out, and
# before every parse error. Without a walk (the mode is off, or no
# retained statement node owns the statement) each step is emitted during
# the parse as before.

# 0 only when the raw bytes from the lookahead character to the end of its
# line show that lexing the next token cannot print: the next token starts
# on this line, and the line holds no literal, comment or continuation
# opener, control or non-ASCII byte that could make the lexer warn or
# fail. Anything not visible in the read window is reported as possible.
int ast_gpu_lex_may_print():
	if ((file < 0) || (file >= GETCHAR_MAX_FD) || (nextc < 0)): return 1
	int window_start = getchar_kernel_pos[file] - getchar_limit[file]
	int window_end = getchar_kernel_pos[file]
	int start = byte_offset - 1
	if (start < window_start): return 1
	char* bytes = cast(char*, getchar_buf_addr[file] - window_start)
	int seen = 0
	for at in range(start, window_end):
		int c = bytes[at]
		if (c == 10): return seen == 0
		if ((c == '"') || (c == 39) || (c == '`') || (c == '#') || (c == '/') || (c == 92)): return 1
		if ((c < 32) && (c != 9)): return 1
		if (c > 126): return 1
		if ((c != ' ') && (c != 9)): seen = 1
	return 1


# accept(s) for a statement that may have a walk with pending phases.
int ast_gpu_walk_accept(int walk, char* s):
	if (peek(s) == 0): return 0
	if ((walk >= 0) && ast_gpu_lex_may_print()): retained_walk_drain(walk)
	get_token()
	return 1


void ast_gpu_walk_expect(int walk, char* s):
	if (ast_gpu_walk_accept(walk, s)): return
	if (walk >= 0): retained_walk_drain(walk)
	expect(s)


void ast_gpu_walk_error(int walk, char* message):
	if (walk >= 0): retained_walk_drain(walk)
	error(message)


# One header value into owner.value. The parse arena is only temporary;
# the walk owns the expression view used by lowering.
void ast_gpu_value(gpu_statement_ast* owner, int walk, expression_ast* tree, int type, int kernel_sym, char* name, int index):
	if (walk >= 0): retained_walk_drain(walk)
	statement_ast* node = owner.value
	node.kind = ast_stmt_gpu_dimension
	if (kernel_sym >= 0): node.kind = ast_stmt_gpu_argument
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.declared_type = type
	node.binding = kernel_sym
	node.callee_name = retained_parse_name(name)
	node.argument_index = index
	node.expression_tree = 0
	node.expression_root = -1
	increment_statement_context = 0
	expression_lhs_readonly = 0
	int root = ast_expression_prepare_at(tree, token_start_offset, 1)
	if (root < 0):
		node.expression_type = expression()
		node.end_offset = token_start_offset
	else:
		node.expression_tree = tree
		node.expression_root = root
		node.end_offset = tree.end_offset
		if (walk >= 0):
			# ast_statement_walk_expression's steps, with this family's phases
			retained_walk_expression(walk, tree, root)
			node.expression_tree = retained_walks[walk].tree
			retained_walk_phase(walk, ast_gpu_walk_expression)
			if (ast_statement_lex_may_print(tree)): retained_walk_drain(walk)
			if (tree.whole_expression):
				token_start_offset = tree.final_token_offset
				get_token()
			retained_walk_phase(walk, ast_gpu_walk_expression_end)
		else:
			emit_statement_ast_expression(node)
			ast_statement_finish_expression(node)
	if (walk >= 0): retained_walk_phase(walk, ast_gpu_walk_value)
	else: emit_gpu_value_ast(node)


void ast_gpu_dimension_slot(gpu_statement_ast* node, int walk):
	if (walk >= 0): retained_walk_phase(walk, ast_gpu_walk_slot)
	else: emit_gpu_dimension_slot_ast(node)


void ast_gpu_capture_value(char* name):
	statement_ast local_node
	statement_ast* node = cast(statement_ast*, retained_parse_record(&local_node, sizeof(statement_ast)))
	node.kind = ast_stmt_gpu_capture
	node.callee_name = retained_parse_name(name)
	node.binding = sym_lookup(name)
	if (node.binding < 0): sym_not_found_error(name)
	emit_gpu_capture_value_ast(node)


int ast_launch_statement():
	if (peek(c"launch") == 0): return 0
	gpu_statement_ast local_node
	gpu_statement_ast* node = cast(gpu_statement_ast*, retained_parse_record(&local_node, sizeof(gpu_statement_ast)))
	node.kind = ast_gpu_launch
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.header_slots = 0
	char* save = generic_reparse_save()
	get_token()
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0):
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)

	if (target_isa == 3): error(c"'launch' is not supported in gpu code")
	gpu_target_check()
	if (sym_lookup(c"__w_gpu_launch_raw") < 0): error(c"gpu code requires 'import lib.cuda'")
	node.kernel_symbol = sym_lookup(token)
	int is_kernel = 0
	if (node.kernel_symbol >= 0): is_kernel = sym_is_kernel(node.kernel_symbol)
	if (is_kernel == 0): error3(c"'", token, c"' is not a kernel")
	node.kernel_name = retained_parse_name(token)
	if (ast_retain_mode == 0): node.kernel_name = strclone(token)
	get_token()

	node.base_stack = stack_pos
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	expression_ast tree
	node.value = value
	int walk = retained_walk_begin(cast(int, emit_gpu_walk_ast), cast(statement_ast*, node))
	ast_gpu_walk_expect(walk, c"[")
	node.integer_type = type_lookup(c"int")
	ast_gpu_value(node, walk, &tree, node.integer_type, -1, 0, 0)
	ast_gpu_dimension_slot(node, walk) /* grid */
	ast_gpu_walk_expect(walk, c",")
	ast_gpu_value(node, walk, &tree, node.integer_type, -1, 0, 0)
	ast_gpu_dimension_slot(node, walk) /* block */
	ast_gpu_walk_expect(walk, c"]")

	ast_gpu_walk_expect(walk, c"(")
	node.argument_count = 0
	if (ast_gpu_walk_accept(walk, c")") == 0):
		ast_gpu_value(node, walk, &tree, sym_param_type(node.kernel_symbol, node.argument_count), node.kernel_symbol, node.kernel_name, node.argument_count)
		node.argument_count = node.argument_count + 1
		while (ast_gpu_walk_accept(walk, c",")):
			ast_gpu_value(node, walk, &tree, sym_param_type(node.kernel_symbol, node.argument_count), node.kernel_symbol, node.kernel_name, node.argument_count)
			node.argument_count = node.argument_count + 1
		ast_gpu_walk_expect(walk, c")")

	# The launch path passes exactly one 8-byte cell per declared
	# parameter: a count mismatch would feed the kernel garbage cells.
	int expected_args = sym_num_args(node.kernel_symbol)
	if (node.argument_count != expected_args):
		if (walk >= 0): retained_walk_drain(walk)
		diag_part(c"kernel '")
		diag_part(node.kernel_name)
		diag_part(c"' expects ")
		error3(itoa(expected_args), c" arguments, got ", itoa(node.argument_count))

	node.end_offset = token_start_offset
	if (walk >= 0):
		retained_walk_phase(walk, ast_gpu_walk_launch)
		retained_emit_statement(retained_walks[walk].node)
	else: emit_gpu_launch_ast(node)
	if (ast_retain_mode == 0): free(node.kernel_name)
	return 1


int ast_gpu_for_statement():
	if (peek(c"gpu") == 0): return 0
	gpu_statement_ast local_node
	gpu_statement_ast* node = cast(gpu_statement_ast*, retained_parse_record(&local_node, sizeof(gpu_statement_ast)))
	node.kind = ast_gpu_for
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	node.header_slots = 0
	char* save = generic_reparse_save()
	get_token()
	if (peek(c"for") == 0):
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)

	if (target_isa == 3): error(c"'gpu for' cannot nest inside gpu code")
	gpu_target_check()
	if (sym_lookup(c"__w_gpu_launch") < 0): error(c"gpu code requires 'import lib.cuda'")

	int gpu_for_tab_level = tab_level
	get_token() /* consume 'for' */

	# Loop variable: 'int name' (one thread index per iteration)
	node.integer_type = type_lookup(c"int")
	int type = type_name()
	if (type_unqualified(type) != node.integer_type): error(c"'gpu for' loop variable must be an int")
	node.variable_name = retained_parse_name(token)
	if (ast_retain_mode == 0): node.variable_name = strclone(token)
	get_token()
	expect(c"in")
	if (accept(c"range") == 0): error(c"'gpu for' supports only range iteration")

	# The range operands, evaluated in host mode into hidden slots that
	# double as the leading capture cells: range(end) pushes just the
	# bound (capture slot 0); range(start, end) pushes start then end
	# (slots 0 and 1, parse order). The device guard reloads the bound
	# from its slot; a step argument is not supported.
	node.base_stack = stack_pos
	statement_ast local_value
	statement_ast* value = cast(statement_ast*, retained_parse_record(&local_value, sizeof(statement_ast)))
	expression_ast tree
	node.value = value
	node.capture_bindings = 0
	int walk = retained_walk_begin(cast(int, emit_gpu_walk_ast), cast(statement_ast*, node))
	int has_parens = ast_gpu_walk_accept(walk, c"(")
	node.has_start = 0
	ast_gpu_value(node, walk, &tree, node.integer_type, -1, 0, 0)
	ast_gpu_dimension_slot(node, walk)
	if (ast_gpu_walk_accept(walk, c",")):
		node.has_start = 1
		ast_gpu_value(node, walk, &tree, node.integer_type, -1, 0, 0)
		if (ast_gpu_walk_accept(walk, c",")): ast_gpu_walk_error(walk, c"'gpu for' supports only range(end) and range(start, end)")
		ast_gpu_dimension_slot(node, walk)
	if (has_parens): ast_gpu_walk_expect(walk, c")")

	# Device side: outline the body into a fresh kernel. Device mode, the
	# capture table and the loop variable's slot are read by the body's
	# parse, so a walk emits the kernel's prologue before it.
	node.symbol_base = table_pos
	char* kernel_name = gpu_for_kernel_name()
	node.kernel_name = retained_parse_name(kernel_name)
	if (ast_retain_mode): free(kernel_name)
	node.launch_name = retained_parse_name(node.kernel_name)
	if (ast_retain_mode == 0): node.launch_name = strclone(node.kernel_name)
	if (walk >= 0):
		retained_walk_phase(walk, ast_gpu_walk_device_begin)
		retained_walk_drain(walk)
	else: emit_gpu_for_device_begin_ast(node)
	sym_declare(node.variable_name, node.integer_type, 'L', stack_pos, 1)
	pointer_indirection = 0
	# Compiler-inserted guard: threads past the bound do nothing
	if (walk >= 0):
		retained_walk_phase(walk, ast_gpu_walk_loop_variable)
		retained_walk_phase(walk, ast_gpu_walk_guard)
		retained_walk_drain(walk)
	else:
		emit_gpu_loop_variable_ast(node)
		emit_gpu_for_guard_ast(node)
	if (ast_retain_mode == 0):
		free(node.variable_name)
		node.variable_name = 0

	enclosing_tab_level = gpu_for_tab_level
	statement()

	# The kernel closes, leaving device mode, before the host side
	# resolves the captures.
	if (walk >= 0):
		retained_walk_phase(walk, ast_gpu_walk_device_end)
		retained_walk_drain(walk)
	else: emit_gpu_for_device_end_ast(node)
	table_pos = node.symbol_base

	# Host side: push the remaining captures' current values (slot
	# order; the range operands already sit at node.base_stack+1..), then launch.
	int k = 1 + node.has_start
	if (walk >= 0):
		node.capture_bindings = cast(int*, retained_arena_alloc((node.capture_count + 1) * __word_size__))
		node.capture_names = cast(char**, retained_arena_alloc((node.capture_count + 1) * __word_size__))
		while (k < node.capture_count):
			char* name = gpu_capture_name(k)
			int binding = sym_lookup(name)
			if (binding < 0):
				retained_walk_drain(walk)
				sym_not_found_error(name)
			node.capture_bindings[k] = binding
			node.capture_names[k] = retained_parse_name(name)
			retained_walk_phase(walk, ast_gpu_walk_capture + (k << 8))
			k = k + 1
	else:
		while (k < node.capture_count):
			ast_gpu_capture_value(gpu_capture_name(k))
			k = k + 1
	node.end_offset = token_start_offset
	if (walk >= 0):
		retained_walk_phase(walk, ast_gpu_walk_for_launch)
		retained_emit_statement(retained_walks[walk].node)
	else: emit_gpu_for_launch_ast(node)
	if (ast_retain_mode == 0): free(node.launch_name)
	return 1
