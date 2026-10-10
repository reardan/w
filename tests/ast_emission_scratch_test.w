# wbuild: x64
import lib.testing
import repl.core


int scratch_target


type scratch_callback = fn() -> int


# An invalid propagation operand models a backend-only diagnostic after
# the work array was acquired. The retained view is repaired on recovery,
# without touching the scratch pool or emitter depth bookkeeping.
int scratch_recover(expression_ast* tree, int root, int fault):
	repl_checkpoint()
	int before_op = tree.op[fault]
	int before_left = tree.left[fault]
	repl_recovery = 1
	if (repl_setjmp(repl_jump_buffer)):
		repl_recovery = 0
		repl_rollback()
		tree.op[fault] = before_op
		tree.left[fault] = before_left
		be_notes_reset()
		# Recovery really skipped release and the root's final restore.
		assert1(ast_emission_scratch_depth > 0)
		assert1(ast_expression_emit_depth > 0)
		assert1(ast_expression_root_owner != 0)
		return 1
	current_function_symbol = -1
	tree.op[fault] = ast_propagate
	tree.left[fault] = 0
	emit_expression_ast_root(tree, root)
	repl_recovery = 0
	return 0


void scratch_fail_then_run(expression_ast* tree, int root, int fault, int wanted):
	assert_equal(1, scratch_recover(tree, root, fault))
	# The public root entry resets the depth abandoned by longjmp; no
	# test-side depth repair is allowed before this successful emission.
	int start = codepos
	emit_expression_ast_root(tree, root)
	assert_equal(0, ast_expression_emit_depth)
	promote(tree.result_type[root])
	ret()
	scratch_callback* run = cast(scratch_callback*, code + start)
	assert_equal(wanted, run())
	codepos = start
	be_notes_reset()


void test_emission_scratch_reused_after_diagnostic_recovery():
	repl_init()
	filename = c"tests/ast_emission_scratch_test.w"
	diag_token_line = 1
	diag_token_column = 1
	tokenizer_set_token_text(c"scratch", 7)
	ast_expressions_mode = 2
	expression_ast tree
	expression_ast_bind(&tree)
	tree.count = 0
	int first = expression_ast_add(&tree, 0, -1, -1)
	tree.value[first] = 1
	int root = first
	for i in range(100):
		int rhs = expression_ast_add(&tree, 0, -1, -1)
		tree.value[rhs] = 1
		root = expression_ast_add(&tree, '+', root, rhs)
	# Turn this into a detached view after building it. Emission must
	# acquire its own scratch and never index the parse-slab table.
	tree.slab = -1
	int slabs = 0
	for i in range(9):
		scratch_fail_then_run(&tree, root, tree.right[root], 101)
		if (i == 0): slabs = ast_emission_scratch_total
		else: assert_equal(slabs, ast_emission_scratch_total)
	expression_ast_bind(&tree)
	tree.count = 0
	int lhs = expression_ast_add(&tree, 0, -1, -1)
	tree.value[lhs] = cast(int, &scratch_target)
	tree.result_type[lhs] = type_lookup(c"int")
	int rhs = expression_ast_add(&tree, 0, -1, -1)
	tree.value[rhs] = 42
	int pair = expression_ast_add(&tree, 'T', lhs, rhs)
	root = expression_ast_add(&tree, 'A', pair, -1)
	tree.result_type[root] = type_value(tree.result_type[lhs])
	tree.slab = -1
	for i in range(9):
		scratch_fail_then_run(&tree, root, rhs, 42)
		if (i == 0): slabs = ast_emission_scratch_total
		else: assert_equal(slabs, ast_emission_scratch_total)
	assert_equal(42, scratch_target)
