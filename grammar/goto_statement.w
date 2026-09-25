/*
 * goto-statement:
 *     goto identifier ;
 * labeled-statement:
 *     identifier :                  (on a line of its own)
 *
 * A label is an ordinary statement, so it is indented like the
 * statements around it (a C-style label at column 0 would close the
 * function body's tab-scoped block).
 *
 * Function-scoped labels and unconditional jumps (issue #435), for code
 * translated from C (SQLite, Lua, ...). Labels live in their own
 * namespace, are visible throughout the enclosing function body (before
 * or after the goto, in or out of blocks) and must be unique per
 * function; a goto naming a label the function never defines is an
 * error when the body closes.
 *
 * The W stack model: locals live on the machine stack (the x28 data
 * stack on arm64) and stack_pos counts their words at every statement
 * boundary, so a jump must leave the stack as deep as the code at its
 * target expects. A goto out of a block pops the locals it leaves (like
 * 'break'); a goto into a block, or forward over a declaration, reserves
 * the target's extra slots uninitialized -- C's indeterminate-value
 * rule, and the reason C++ forbids such jumps over initializers.
 *
 * Backward gotos branch straight to the recorded label. Forward gotos
 * are recorded pending with their stack depth and resolved when the
 * label is defined: a goto at the label's depth is patched to it
 * directly; any other gets a small adjust-and-jump stub emitted just
 * before the label behind a jump that skips the stubs on fall-through.
 *
 * Native targets only (x86, x64, arm64, win64): the wasm backend lowers
 * control flow through the grammar's structured-region protocol
 * (be_ctrl_* in code_generator/x86.w), which an arbitrary jump cannot
 * be expressed in, and gpu code has no host frame. Jumps skip 'defer'
 * statements (they run at function exit, as with any other path) and do
 * not free the suspended generator of a for-in loop they leave, which
 * only 'break' and 'return' do.
 */

# Labels of every function body currently being compiled: one stack,
# with goto_label_base marking where the innermost body's labels start
# (a generic instantiated mid-body compiles its own body on top).
char** goto_label_names
int* goto_label_pos      # codepos of the label, or -1 while undefined
int* goto_label_stack    # stack_pos at the label (valid once defined)
int goto_label_count
int goto_label_capacity
int goto_label_base

# Forward gotos awaiting their label: label index (-1 once resolved),
# branch site (codepos just past the jump), stack_pos at the goto.
int* goto_pending_label
int* goto_pending_site
int* goto_pending_stack
int goto_pending_count
int goto_pending_capacity
int goto_pending_base


void goto_reserve():
	if (goto_label_capacity == 0):
		goto_label_capacity = 16
		goto_label_names = cast(char**, malloc(goto_label_capacity * __word_size__))
		goto_label_pos = cast(int*, malloc(goto_label_capacity * __word_size__))
		goto_label_stack = cast(int*, malloc(goto_label_capacity * __word_size__))
	if (goto_label_count >= goto_label_capacity):
		int old = goto_label_capacity * __word_size__
		goto_label_capacity = goto_label_capacity * 2
		int x = goto_label_capacity * __word_size__
		goto_label_names = cast(char**, realloc(cast(void*, goto_label_names), old, x))
		goto_label_pos = cast(int*, realloc(goto_label_pos, old, x))
		goto_label_stack = cast(int*, realloc(goto_label_stack, old, x))
	if (goto_pending_capacity == 0):
		goto_pending_capacity = 16
		goto_pending_label = cast(int*, malloc(goto_pending_capacity * __word_size__))
		goto_pending_site = cast(int*, malloc(goto_pending_capacity * __word_size__))
		goto_pending_stack = cast(int*, malloc(goto_pending_capacity * __word_size__))
	if (goto_pending_count >= goto_pending_capacity):
		int old_p = goto_pending_capacity * __word_size__
		goto_pending_capacity = goto_pending_capacity * 2
		int y = goto_pending_capacity * __word_size__
		goto_pending_label = cast(int*, realloc(goto_pending_label, old_p, y))
		goto_pending_site = cast(int*, realloc(goto_pending_site, old_p, y))
		goto_pending_stack = cast(int*, realloc(goto_pending_stack, old_p, y))


# Open a function body's label scope. Callers save goto_label_base and
# goto_pending_base first and hand them back to goto_scope_end.
void goto_scope_begin():
	goto_label_base = goto_label_count
	goto_pending_base = goto_pending_count


# Close the innermost body's label scope: every goto must have found its
# label, then the outer scope's bases come back.
void goto_scope_end(int outer_label_base, int outer_pending_base):
	int i = goto_pending_base
	while (i < goto_pending_count):
		int label = goto_pending_label[i]
		if (label >= 0):
			diag_part(c"goto to undefined label '")
			diag_part(goto_label_names[label])
			error(c"'")
		i = i + 1
	i = goto_label_base
	while (i < goto_label_count):
		free(goto_label_names[i])
		i = i + 1
	goto_label_count = goto_label_base
	goto_pending_count = goto_pending_base
	goto_label_base = outer_label_base
	goto_pending_base = outer_pending_base


int goto_label_find(char* name):
	int i = goto_label_base
	while (i < goto_label_count):
		if (strcmp(goto_label_names[i], name) == 0):
			return i
		i = i + 1
	return -1


int goto_label_intern(char* name):
	int found = goto_label_find(name)
	if (found >= 0):
		return found
	goto_reserve()
	goto_label_names[goto_label_count] = strclone(name)
	goto_label_pos[goto_label_count] = -1
	goto_label_stack[goto_label_count] = 0
	goto_label_count = goto_label_count + 1
	return goto_label_count - 1


void goto_check_target():
	if ((target_isa == 2) || (target_isa == 3) || in_gpu_for_body):
		error(c"'goto' and labels are only supported on native targets (not wasm or gpu code)")


# Move the machine stack from depth `from` words to depth `to`: pop the
# locals being left, or reserve (uninitialized) the ones being entered.
void goto_adjust_stack(int from, int to):
	if (from != to):
		be_pop(from - to)


int goto_name_is_ident(char* s):
	int c0 = s[0]
	return (('a' <= c0) && (c0 <= 'z')) || (('A' <= c0) && (c0 <= 'Z')) || (c0 == '_')


# goto identifier ;
int goto_statement():
	if (accept(c"goto") == 0):
		return 0
	goto_check_target()
	if (goto_name_is_ident(token) == 0):
		error(c"label name expected after 'goto'")
	int label = goto_label_intern(token)
	get_token()
	expect_or_newline(c";")
	if (goto_label_pos[label] >= 0):
		# Backward: the label's depth is known
		goto_adjust_stack(stack_pos, goto_label_stack[label])
		jmp_int32(0)
		be_branch_patch(codepos, goto_label_pos[label])
		return 1
	jmp_int32(0)
	goto_reserve()
	goto_pending_label[goto_pending_count] = label
	goto_pending_site[goto_pending_count] = codepos
	goto_pending_stack[goto_pending_count] = stack_pos
	goto_pending_count = goto_pending_count + 1
	return 1


# identifier ':' at statement start. Called after every keyword form and
# after inferred_declaration (which owns 'name :='), so the only thing an
# identifier directly followed by ':' can still be is a label.
int labeled_statement():
	if (goto_name_is_ident(token) == 0):
		return 0
	if (nextc != ':'):
		return 0
	char* name = strclone(token)
	char* save = generic_reparse_save()
	get_token()
	if (peek(c":") == 0):
		free(name)
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)
	get_token() /* consume ':' */
	goto_check_target()
	int label = goto_label_intern(name)
	if (goto_label_pos[label] >= 0):
		diag_part(c"duplicate label '")
		diag_part(name)
		error(c"'")
	free(name)
	# A jump lands here: no constant/compare fold may reach back across it
	be_cmp_note_reset()
	be_imm_note_reset()
	# Forward gotos at another depth get an adjust-and-jump stub, placed
	# before the label behind a jump that skips them on fall-through
	int skip = 0
	int i = goto_pending_base
	while (i < goto_pending_count):
		if ((goto_pending_label[i] == label) && (goto_pending_stack[i] != stack_pos)):
			if (skip == 0):
				jmp_int32(0)
				skip = codepos
			be_branch_patch(goto_pending_site[i], codepos)
			goto_adjust_stack(goto_pending_stack[i], stack_pos)
			jmp_int32(0)
			# The stub's own jump is resolved to the label below
			goto_pending_site[i] = codepos
		i = i + 1
	if (skip):
		be_branch_patch(skip, codepos)
	goto_label_pos[label] = codepos
	goto_label_stack[label] = stack_pos
	i = goto_pending_base
	while (i < goto_pending_count):
		if (goto_pending_label[i] == label):
			be_branch_patch(goto_pending_site[i], codepos)
			goto_pending_label[i] = -1
		i = i + 1
	return 1
