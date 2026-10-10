# Reusable, unbound deferred-call syntax. These nodes contain source names
# and argument edges, never symbol-table offsets or registration-time slots.
# Binding happens at each exit, after the entire tree has passed a pure
# eligibility check. Unsupported expressions keep the ordinary defer path.
struct defer_syntax_node:
	int kind                  # 0 decimal integer, 1 name, 2 call
	char* name
	int value
	int offset
	defer_syntax_node* arguments
	defer_syntax_node* next_argument
	defer_syntax_node* allocated_next


struct defer_syntax_tree:
	defer_syntax_node* root
	defer_syntax_node* allocated
	int end_offset
	int final_offset


void defer_tree_free(int address):
	if (address == 0): return
	defer_syntax_tree* tree = cast(defer_syntax_tree*, address)
	defer_syntax_node* node = tree.allocated
	while (node):
		defer_syntax_node* next = node.allocated_next
		if (node.name): free(node.name)
		free(node)
		node = next
	free(tree)


# The lexer is already skipping this deferred line at registration. Parse
# its small supported grammar as it advances once, without looking up any
# name or type. A decline may consume a prefix: the caller skips the rest.
defer_syntax_node* defer_tree_parse(defer_syntax_tree* tree, int depth):
	if ((depth > 96) || token_newline || (token[0] == 0)): return 0
	int kind = -1
	int value = 0
	if ((token[0] >= '0') && (token[0] <= '9')):
		kind = 0
		# Leave alternate bases, suffixes, large values and leading-zero
		# spellings to int_literal_value and its existing diagnostics.
		if ((token[0] == '0') && token[1]): return 0
		for i in range(strlen(token)):
			int digit = token[i] - '0'
			if ((digit < 0) || (digit > 9)): return 0
			if ((value > 214748364) || ((value == 214748364) && (digit > 7))): return 0
			value = value * 10 + digit
	else if (is_ident_start_byte(token[0])):
		kind = 1
		for i in range(strlen(token)):
			if ((token[i] & 255) >= 128): return 0
	if (kind < 0): return 0
	# The pinned seed does not zero a bare heap aggregate: initialize
	# every link before publishing it to the capture cleanup chain.
	defer_syntax_node* node = new defer_syntax_node()
	node.name = 0
	node.arguments = 0
	node.next_argument = 0
	node.kind = kind
	node.value = value
	node.offset = token_start_offset
	node.allocated_next = tree.allocated
	tree.allocated = node
	if (kind): node.name = strclone(token)
	tree.final_offset = token_start_offset
	tree.end_offset = token_start_offset + strlen(token)
	get_token()
	if ((kind == 0) || token_newline || (peek(c"(") == 0)): return node
	node.kind = 2
	get_token()
	defer_syntax_node* tail = 0
	while ((token_newline == 0) && (peek(c")") == 0)):
		defer_syntax_node* argument = defer_tree_parse(tree, depth + 1)
		if (argument == 0): return 0
		if (tail): tail.next_argument = argument
		else: node.arguments = argument
		tail = argument
		if (token_newline || (peek(c",") == 0)): break
		get_token()
		if (peek(c")")): return 0
	if (token_newline || (peek(c")") == 0)): return 0
	tree.final_offset = token_start_offset
	tree.end_offset = token_start_offset + 1
	get_token()
	return node


int defer_tree_capture():
	if ((ast_expressions_mode < 2) || lint_mode || check_imports_mode):
		defer_skip_statement()
		return 0
	defer_syntax_tree* tree = new defer_syntax_tree()
	tree.root = 0
	tree.allocated = 0
	tree.end_offset = 0
	tree.final_offset = 0
	# Error recovery truncates the registry and releases this pending
	# capture too, even if get_token reports a malformed source token.
	defer_tree_pending = cast(int, tree)
	int warnings = warning_count
	tree.root = defer_tree_parse(tree, 0)
	int complete = token_newline || (token[0] == 0)
	if ((tree.root == 0) || (complete == 0) || (warnings != warning_count)):
		defer_skip_statement()
		defer_tree_free(cast(int, tree))
		defer_tree_pending = 0
		return 0
	defer_tree_pending = 0
	defer_tree_captures = defer_tree_captures + 1
	return cast(int, tree)


# Only word-sized integers and pointers have no aggregate, floating,
# dynamic or container conversion protocol. Parameter types must agree
# exactly; diagnostics for every other conversion use the ordinary path.
int defer_tree_scalar(int type):
	if ((type == 3) || (type == 4) || (type < 0)): return 0
	int real = type_unqualified(type)
	if (type_is_array(real) || type_is_slice(real) || type_is_var(real)): return 0
	if (type_is_map(real) || type_is_set(real) || type_is_list(real) || type_is_string(real)): return 0
	if (type_get_pointer_level(real)): return 1
	return (type_num_args(real) == 0) && (type_float_kind(real) == 0) && (type_get_size(real) == word_size) && (type_get_kind(real) != type_kind_function)


int defer_tree_bind(expression_ast* bound, defer_syntax_node* node):
	if (node.kind == 0):
		int literal = expression_ast_add(bound, 0, -1, -1)
		bound.value[literal] = node.value
		bound.offset[literal] = node.offset
		return literal
	int sym = sym_probe(node.name)
	if (sym < 0): return -1
	int visibility = sym_decl_visibility(sym)
	if ((visibility != 'L') && (visibility != 'A') && (visibility != 'D') && (visibility != 'U')): return -1
	int is_call = load_int(table + sym + 10) == 2
	int type = load_int(table + sym + 6)
	if (is_call != (node.kind == 2)): return -1
	if (is_call):
		if (sym_is_generator(sym) || sym_is_kernel(sym) || sym_is_asm_stub(sym)): return -1
		if ((sym_variadic_fixed_args(sym) >= 0) || (sym_w_variadic_fixed_args(sym) >= 0)): return -1
		if ((type != 0) && (defer_tree_scalar(type) == 0)): return -1
	else if (defer_tree_scalar(type) == 0): return -1
	int op = 'v'
	if (is_call): op = 'C'
	int id = expression_ast_add(bound, op, -1, -1)
	bound.symbol[id] = sym
	bound.value[id] = sym - strlen(node.name)
	bound.offset[id] = node.offset
	bound.result_type[id] = type
	if (is_call):
		bound.high[id] = type
		bound.result_type[id] = type_value(type)
		int count = 0
		int tail = -1
		defer_syntax_node* child = node.arguments
		while (child):
			int argument = defer_tree_bind(bound, child)
			if (argument < 0): return -1
			int want = sym_param_type(sym, count)
			int got = ast_expression_promoted_type(bound.result_type[argument])
			if (defer_tree_scalar(want) == 0): return -1
			if (got == 3):
				if (type_unqualified(want) != type_lookup(c"int")): return -1
			else if (type_unqualified(want) != type_unqualified(got)): return -1
			if (tail < 0): bound.left[id] = argument
			else: bound.next_arg[tail] = argument
			tail = argument
			count = count + 1
			child = child.next_argument
		if (count != sym_num_args(sym)): return -1
	return id


int defer_tree_emit(int index):
	if ((defer_spans[index].tree == 0) || (ast_expressions_mode < 2)): return 0
	if (lint_mode || check_imports_mode || (target_isa == 3)): return 0
	if (import_alias_count != import_alias_base): return 0
	defer_syntax_tree* syntax = cast(defer_syntax_tree*, defer_spans[index].tree)
	expression_ast bound
	expression_ast_bind(&bound)
	bound.count = 0
	bound.text_used = 0
	bound.types_base = type_count()
	bound.types_count = 0
	bound.pending_buffer_types = 0
	bound.it_binding = -1
	bound.lint_group_depth = 0
	bound.lint_depth_bias = 0
	bound.type_names_used = 0
	bound.readonly = 0
	bound.whole_expression = 1
	bound.cast_depth = 0
	bound.end_offset = syntax.end_offset
	bound.final_token_offset = syntax.final_offset
	int root = defer_tree_bind(&bound, syntax.root)
	if (root < 0): return 0
	# No effects until every exit-site symbol and argument is eligible.
	for id in range(bound.count):
		if ((bound.op[id] == 'v') || (bound.op[id] == 'C')): sym_lookup(table + bound.value[id])
	ast_expression_capture_stack_bindings(&bound)
	char* saved = generic_reparse_save()
	filename = defer_spans[index].file
	token_start_offset = defer_spans[index].offset
	diag_token_line = defer_spans[index].line + 1
	diag_token_column = defer_spans[index].column + 1
	increment_statement_context = 0
	expression_lhs_readonly = 0
	emit_prepared_expression_ast(&bound, root)
	generic_reparse_restore(saved)
	ast_expressions_emitted = ast_expressions_emitted + 1
	ast_roots_emitted = ast_roots_emitted + 1
	ast_deferred_expressions_emitted = ast_deferred_expressions_emitted + 1
	defer_tree_emissions = defer_tree_emissions + 1
	return 1
