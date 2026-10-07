# Branch-on-flags for &&, || and ! in condition context (unit A6 of
# docs/projects/codegen_gap_plan.md, §2.6; the mechanism extends #427's
# comparison-branch fusion, docs/projects/optimization.md §1.3).
#
# In value context 'a && b' materializes a 0/1 word: each operand is
# booleanized, a zero operand short-circuits to the final 'test; setne;
# movzx' with its value in the accumulator (grammar/logical_and_expr.w).
# In a CONDITION -- the header of if/elif/while, the condition of a '?:'
# that is itself in a condition, the operand of '!' in one, and the
# parenthesized sub-chains of all of those -- nothing reads that word:
# the only consumer is a branch. So a chain parsed in condition context
# emits one branch per operand straight to where the condition's
# consumer wants control to go, on the comparison's flags when the
# operand was a comparison (be_br_zero_discard's fusion), and never
# booleanizes. The regions those branches target stay open on the
# control stack until the consumer resolves them; that is the PENDING
# state below.
#
# Discard position. The guard arms cond_discard_mark with the offset of
# the condition's first token. logical_or_expr / logical_and_expr /
# conditional_expr / the '!' operator / a '(' group entered AT that
# token take the condition path (and re-arm the mark for each operand
# of their own that is again in discard position: the next && / ||
# operand, the token after '!' or '('). Anything that starts later --
# a call argument, an index, a ternary arm, the right side of '+' --
# never matches, so its value form is untouched. The mark is positional
# so no grammar path has to clear it: a nested expression at a later
# offset simply cannot match.
#
# Pending state. When a chain in discard position finishes, its last
# operand's value is still unpromoted (cond_pending_type), the branches
# of the earlier operands target tagged regions above cond_pending_base
# (tag 1: taken when the chain is false, tag 2: when it is true), and
# cond_negate records a '!' around the whole. The consumer
# (cond_branch_consume) promotes the last operand, branches on it, and
# then merges or ends each region by its tag. A value consumer that
# meets a pending chain -- '(a || b) == c' inside a condition, '!x' as
# an operand of '+' -- gets cond_pending_materialize, which turns the
# pending state into the 0/1 word the value form would have produced:
# promote() runs it first thing, and so does emit() itself
# (code_generator/code_emitter.w), since any emission while the chain
# is pending can only be a value use of it. That keeps the design
# closed: a consumer nobody listed cannot read the accumulator as the
# chain's value, because the first byte it emits materializes the value.
#
# x86/x64 only, on by default, --no-cond-branch (and -O0) keeps the
# value form everywhere; the other ISAs never arm the mark and emit as
# before. tests/cond_branch_test.w pins the shapes, regalloc_diff_test
# compares every test program with and without the flag.

int cond_discard_mark     # offset + 1 of the token a discard-position operand starts at; 0 = none
int cond_pending_base     # ctrl_stack_pos below the pending chain's regions
int cond_pending_type     # the pending chain's last operand, unpromoted
int cond_negate           # the pending chain is negated ('!' around it)
int cond_boolean          # the pending chain's value is 0/1 of its operand ('!!' around it): materializing must booleanize even without branch sites
# The retained tree's discard flag: set right before a tree root (or a
# chain operand, '!' operand or '?:' condition inside it) is emitted,
# consumed by emit_expression_ast (code_generator/expression_ast.w).
int ast_cond_discard

int compound_assign_op();


int cond_branch_on():
	return (target_isa == 0) && (cond_branch_disabled == 0)


# The token about to be parsed starts a discard-position operand.
void cond_discard_arm():
	if (cond_branch_on()): cond_discard_mark = token_start_offset + 1


# The current token is the one the mark names.
int cond_discard_match():
	if (cond_discard_mark == 0): return 0
	return (cond_discard_mark == token_start_offset + 1) && cond_branch_on()


void cond_discard_clear():
	cond_discard_mark = 0


# True when the token after the operand just parsed makes it an
# assignment target, so a parked container element must stay parked.
int cond_assignment_follows():
	if (peek(c"=")): return 1
	return compound_assign_op() != 0


# A chain in discard position has parsed its last operand (type, unless
# the operand itself left a pending note): leave the whole chain, whose
# regions start at base, pending for the consumer. Returns the operand's
# type as the chain's value type: a parked element read finished here
# is a value now, and a caller that reports the operand's own type (a
# chain without operators) must not report the unfinished one, or a
# value consumer would load it a second time.
int cond_chain_finish(int base, int type):
	if (cond_pending == 0):
		# A parked map/ndarray element read is the operand's value;
		# finish it here unless an assignment follows (grammar/
		# expression.w owns that case and releases the chain first)
		if (hash_index_pending || nd_index_pending):
			if (cond_assignment_follows() == 0):
				type = hash_finalize_pending_read_if_needed(type)
				type = nd_finalize_pending_read_if_needed(type)
		cond_pending_type = type
		cond_negate = 0
		cond_boolean = 0
	cond_pending = 1
	cond_pending_base = base
	return type


# '!' (toggle) or '!!' (no toggle) around the operand just parsed, whose
# regions, if it was a chain, start at base.
void cond_negate_pending(int base, int type, int toggle):
	if (cond_pending):
		cond_boolean = 1
		if (toggle):
			cond_negate = cond_negate ^ 1
			int i = base
			while (i < ctrl_stack_pos):
				if (ctrl_tag_stack[i]): ctrl_tag_stack[i] = 3 - ctrl_tag_stack[i]
				i = i + 1
		if (base < cond_pending_base): cond_pending_base = base
		return
	# A '!' operand is never an assignment target: a parked element
	# read is finished now
	if (hash_index_pending || nd_index_pending):
		type = hash_finalize_pending_read_if_needed(type)
		type = nd_finalize_pending_read_if_needed(type)
	cond_pending = 1
	cond_pending_base = base
	cond_pending_type = type
	cond_negate = toggle
	cond_boolean = 1


# Resolve the pending regions above base after the consumer's own branch
# to h: the regions whose branches agree with it (on_true: taken when
# the chain is true) are handed to h, the others land here, where the
# consumer falls through. Empty regions are dropped; nothing landed.
void cond_regions_resolve(int base, int h, int on_true):
	while (ctrl_stack_pos > base):
		int top = ctrl_stack_pos - 1
		int tag = ctrl_tag_stack[top]
		if (ctrl_val_stack[top] == 0): ctrl_stack_pos = top
		else if (tag == 0): error(c"internal error: untagged region inside a pending condition chain")
		else if ((tag == 2) == on_true): be_ctrl_merge(top, h)
		else: be_ctrl_end(top)


# Branch to region h when the condition is true (on_true) or false. With
# a pending chain this promotes its last operand, branches on it in the
# chain's own polarity and resolves its regions; otherwise the caller
# has already promoted the value in the accumulator.
void cond_branch_consume(int h, int on_true):
	if (cond_pending == 0):
		if (on_true): be_br_nonzero_discard(h)
		else: be_br_zero_discard(h)
		return
	int base = cond_pending_base
	int negate = cond_negate
	int type = cond_pending_type
	cond_pending = 0
	cond_negate = 0
	promote(type)
	if (on_true ^ negate): be_br_nonzero_discard(h)
	else: be_br_zero_discard(h)
	cond_regions_resolve(base, h, on_true)


# One operand of a chain, parsed with result type: branch on it to h.
void cond_operand_branch(int type, int h, int on_true):
	if (cond_pending == 0): promote(type)
	cond_branch_consume(h, on_true)


# A value consumer met a pending chain: produce the 0/1 word the value
# form would have. A chain without operators, '!' or '!!' (the usual
# '(x)' group) has nothing to produce: its empty regions are dropped and
# the operand stays as it was, an lvalue included. Otherwise the last
# operand is booleanized, and the regions with branches land on pads
# that load 0 (taken when the chain is false) or 1 (true).
void cond_pending_materialize():
	if (cond_pending == 0): return
	cond_pending = 0
	int base = cond_pending_base
	int negate = cond_negate
	cond_negate = 0
	int sites = 0
	int i = base
	while (i < ctrl_stack_pos):
		if (ctrl_val_stack[i] != 0): sites = 1
		i = i + 1
	if ((sites == 0) && (negate == 0) && (cond_boolean == 0)):
		ctrl_stack_pos = base
		return
	promote(cond_pending_type)
	if (negate): alu_test_set(0x94) /* sete */
	else: alu_test_set(0x95) /* setne */
	if (sites == 0):
		ctrl_stack_pos = base
		return
	jmp_int32(0)
	int skip = codepos
	# One region per tag: merge each upper region into the lowest one
	# with its tag, so at most two pads follow
	while (ctrl_stack_pos > base):
		int top = ctrl_stack_pos - 1
		int lowest = -1
		i = base
		while ((i < top) && (lowest < 0)):
			if (ctrl_tag_stack[i] == ctrl_tag_stack[top]): lowest = i
			i = i + 1
		if (lowest < 0): break
		be_ctrl_merge(top, lowest)
	int second = 0
	int first = 1
	while (ctrl_stack_pos > base):
		int top = ctrl_stack_pos - 1
		if (ctrl_val_stack[top] == 0):
			ctrl_stack_pos = top
			continue
		if (first == 0):
			jmp_int32(0)
			second = codepos
		int value = ctrl_tag_stack[top] == 2
		be_ctrl_end(top)
		mov_eax_int(value)
		first = 0
	be_branch_patch(skip, codepos)
	if (second): be_branch_patch(second, codepos)
	be_notes_reset()
