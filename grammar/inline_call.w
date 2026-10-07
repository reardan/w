# Inlining of small leaf callees, the call-site side (unit A5,
# docs/projects/codegen_gap_plan.md §2.4; the record and the decision
# are compiler/inline_table.w). A call whose begin side recorded kind 4
# (grammar/stack_slot.w) has pushed its arguments like any call: one
# word per parameter, parameter i in the slot s + 1 + i above the base
# s. finish_call (grammar/postfix_expr.w) then asks inline_emit_call to
# emit the callee's body in place of the `call rel32`:
#
# - the parameters are bound as fresh 'L' locals over those slots, in a
#   scope opened here and truncated afterwards (table_pos), so the body
#   addresses them exactly as it would its own locals ([esp+disp], no
#   register: compiler/regalloc_scan.w's regalloc_declare keeps its
#   hands off while inline_depth is set);
# - the lexer is primed on the record's private copy of the body's
#   bytes through a /dev/null descriptor whose window is that copy
#   (the getchar window of lib/lib.w: lookahead rewinds inside the body
#   seek within it, and the end of the copy is the end of the stream),
#   with the outer lexer state saved around it like a generic re-parse
#   (generic_reparse_save, grammar/generic.w);
# - the body is parsed by statement() with the streaming grammar (the
#   retained emitter hands over to it as well, so both emitters produce
#   the same bytes), as the function body of the callee: a 'return'
#   lowers to a jump to a region closed after the body (inline_return,
#   called by grammar/statement.w), unwinding the body's own block
#   locals first; the value stays in the accumulator, where the call's
#   result would be;
# - what the body must not do to the caller is held off: no line notes
#   (the bytes belong to the call site's line, code_generator/dwarf.w),
#   no local notes, no lint, no deferred statements or generator
#   cleanups of the caller on its 'return', no register promotion, no
#   retained-tree nodes (the AST modes are off for the duration), and
#   the caller's flow facts (grammar/type_check.w) are restored;
# - the emitter's notes stop at the site: a pending condition chain
#   (grammar/cond_branch.w) is materialized before the body, whose
#   value use it would be anyway, the discard mark (positional, in the
#   caller's file) is cleared so no body token can match it, and the
#   addressing and load notes of code_generator/x86.w (every one ends
#   at codepos or is void) are reset on both sides of the body, so no
#   fold reaches across the site in either direction.
#
# A trailing 'return' whose jump would land on the next instruction is
# removed again (the common 'return expr' at the end of the body).
#
# The call record stays a record: finish_call pops the arguments after
# the body exactly as after a call, and sets the call's result type.

int statement();
void expect_or_newline(char* s);


# The bodies being emitted in place, innermost last.
struct inline_frame:
	int record         # compiler/inline_table.w record index
	int sym            # the callee's symbol
	int region         # be_ctrl_block every 'return' jumps to
	int base           # stack_pos at the body's start (the parameters are below)
	int tail_jump      # codepos right after the last return's jump, -1 none
	# the window the previous frame (or nothing) had on the descriptor
	int saved_buf
	int saved_pos
	int saved_limit
	int saved_kernel_pos

list[int] inline_frames   # inline_frame* each
int inline_fd             # the /dev/null descriptor, 0 until opened, -1 failed


inline_frame* inline_frame_top():
	return cast(inline_frame*, inline_frames[inline_frames.length - 1])


# The decision, with the grammar's context (grammar/statement.w's
# in_generator_body, grammar/gpu_builtin.w's in_gpu_for_body,
# grammar/while_statement.w's loop_depth: a body being emitted in
# place holds no loop, so inside one the depth is still the caller's).
int inline_call_site_ok(int sym):
	if (inline_fd < 0): return 0
	if (inline_fd == 0):
		inline_fd = open(c"/dev/null", 0, 511)
		if ((inline_fd < 0) || (inline_fd >= GETCHAR_MAX_FD)):
			if (inline_fd >= 0): close(inline_fd)
			inline_fd = -1
			return 0
	return inline_site_ok(sym, current_function_symbol, in_generator_body, in_gpu_for_body, loop_depth)


# Prime the lexer at the record's body: the descriptor's window becomes
# the body copy, at file offsets rec.offset .. rec.offset + rec.length.
void inline_window_open(inline_frame* frame, inline_record* rec):
	int fd = inline_fd
	frame.saved_buf = getchar_buf_addr[fd]
	frame.saved_pos = getchar_pos[fd]
	frame.saved_limit = getchar_limit[fd]
	frame.saved_kernel_pos = getchar_kernel_pos[fd]
	getchar_buf_addr[fd] = cast(int, rec.text)
	getchar_limit[fd] = rec.length
	getchar_kernel_pos[fd] = rec.offset + rec.length
	getchar_pos[fd] = 0
	getchar_generation[fd] = getchar_generation[fd] + 1
	file = fd
	filename = rec.file
	byte_offset = rec.offset
	line_number = rec.line
	column_number = rec.column
	tab_level = 0
	token_newline = 0
	# nextc = 0 keeps get_character() from counting the outer parse's
	# stale lookahead character into the new position
	nextc = 0
	nextc = get_character()
	get_token()


void inline_window_close(inline_frame* frame):
	int fd = inline_fd
	getchar_buf_addr[fd] = frame.saved_buf
	getchar_pos[fd] = frame.saved_pos
	getchar_limit[fd] = frame.saved_limit
	getchar_kernel_pos[fd] = frame.saved_kernel_pos
	getchar_generation[fd] = getchar_generation[fd] + 1


# 'return' inside a body being emitted in place (grammar/statement.w):
# the value is in the accumulator; unwind the body's block locals and
# jump to the body's end.
void inline_return():
	inline_frame* frame = inline_frame_top()
	if (stack_pos > frame.base): be_pop(stack_pos - frame.base)
	be_br(frame.region)
	frame.tail_jump = codepos


# Emit the body of record r in place of the call based at s whose
# passed_args arguments are pushed (finish_call). A call the record's
# parameters do not match word for word (an arity warning was issued)
# is emitted as the direct call it would have been.
void inline_emit_call(int r, int s, int passed_args):
	inline_record* rec = inline_record_at(r)
	if ((passed_args != rec.param_count) || (stack_pos != s + rec.param_count)):
		sym_emit_call(rec.sym, direct_callee_name(rec.sym))
		return;
	inline_sites_inlined = inline_sites_inlined + 1
	rec.sites = rec.sites + 1
	# An inlined body counts as a call for grammar/binary_op.w's
	# operand_is_pure: it may have the side effects of one
	emitted_call_count = emitted_call_count + 1
	if (verbosity >= 2):
		print_error(rec.name)
		print_error(c": inlined\x0a")

	# --- the state the body would disturb
	# A pending condition chain (grammar/cond_branch.w) is the site's
	# value use, never the body's: materialize it now (emit() would at
	# the body's first byte), and keep the caller's discard mark from
	# matching a body token
	cond_pending_materialize()
	int saved_discard = cond_discard_mark
	int saved_ast_discard = ast_cond_discard
	cond_discard_mark = 0
	ast_cond_discard = 0
	# No addressing, load or comparison note of the site survives into
	# the body (its first statement would reset them; explicit here)
	be_notes_reset()
	int n = table_pos
	char* save = generic_reparse_save()
	int saved_serial = token_serial
	int saved_true_serial = flow_true_serial
	int saved_function = current_function_symbol
	int saved_tab = enclosing_tab_level
	int saved_defer_pending = defer_function_body_pending
	int saved_saw_return = flow_saw_return
	int saved_terminates = flow_terminates
	int saved_loop_break = flow_loop_break
	int saved_switch_break = flow_switch_break
	int saved_guard_true = flow_guard_true
	int saved_jumps = lint_last_stmt_jumps
	int saved_condition = condition_context
	int saved_lhs_readonly = expression_lhs_readonly
	int saved_increment = increment_statement_context
	int saved_ast_mode = ast_expressions_mode
	int saved_retain = ast_retain_mode
	int saved_emit_retained = ast_emit_retained_mode
	int saved_indirection = pointer_indirection
	char* saved_identifier = strclone(last_identifier)
	# A declaration's initializer is where a call sits most often: the
	# body's own declarations must not become "the last declared"
	int saved_declared = last_declared_symbol
	int saved_declared_offset = sym_last_declared_offset
	int saved_declared_line = sym_last_declared_line
	int saved_declared_column = sym_last_declared_column

	# --- the body's scope: the parameters over the argument slots
	inline_depth = inline_depth + 1
	if (inline_open_syms == 0): inline_open_syms = new list[int]
	inline_open_syms.push(rec.sym)
	ast_expressions_mode = 0
	ast_retain_mode = 0
	ast_emit_retained_mode = 0
	pointer_indirection = 0
	int* types = rec.param_types
	char** names = rec.param_names
	for i in range(rec.param_count): sym_declare(names[i], types[i], 'L', s + i, 1)

	inline_frame* frame = new inline_frame()
	frame.record = r
	frame.sym = rec.sym
	frame.base = stack_pos
	frame.tail_jump = -1
	if (inline_frames == 0): inline_frames = new list[int]
	inline_frames.push(cast(int, frame))
	inline_window_open(frame, rec)
	current_function_symbol = rec.sym
	enclosing_tab_level = 0
	defer_function_body_pending = 0
	flow_saw_return = 0
	condition_context = 0
	expression_lhs_readonly = 0
	increment_statement_context = 0
	frame.region = be_ctrl_block()
	statement()
	if (stack_pos != frame.base): error(c"internal error: inlined body left the stack unbalanced (compile with --no-inline and report this)")
	if (cond_pending): error(c"internal error: inlined body left a condition chain pending (compile with --no-inline and report this)")
	# A jump to the very next instruction: unlink it from the region's
	# chain and drop it
	if (frame.tail_jump == codepos):
		int previous = be_branch_link_get(codepos)
		ctrl_val_stack[frame.region] = previous
		peep_rollback(codepos - 5)
	be_ctrl_end(frame.region)
	# ... and none of the body's survives into the site
	be_notes_reset()
	inline_window_close(frame)
	inline_frames.pop()
	free(cast(char*, frame))
	inline_open_syms.pop()
	inline_depth = inline_depth - 1

	# --- back to the call site
	table_pos = n
	generic_reparse_restore(save)
	token_serial = saved_serial
	flow_true_serial = saved_true_serial
	current_function_symbol = saved_function
	enclosing_tab_level = saved_tab
	defer_function_body_pending = saved_defer_pending
	flow_saw_return = saved_saw_return
	flow_terminates = saved_terminates
	flow_loop_break = saved_loop_break
	flow_switch_break = saved_switch_break
	flow_guard_true = saved_guard_true
	lint_last_stmt_jumps = saved_jumps
	condition_context = saved_condition
	expression_lhs_readonly = saved_lhs_readonly
	increment_statement_context = saved_increment
	ast_expressions_mode = saved_ast_mode
	ast_retain_mode = saved_retain
	ast_emit_retained_mode = saved_emit_retained
	pointer_indirection = saved_indirection
	strcpy(last_identifier, saved_identifier)
	free(saved_identifier)
	last_declared_symbol = saved_declared
	sym_last_declared_offset = saved_declared_offset
	sym_last_declared_line = saved_declared_line
	sym_last_declared_column = saved_declared_column
	cond_discard_mark = saved_discard
	ast_cond_discard = saved_ast_discard
