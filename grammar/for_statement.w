/*
for type-name identifier in range args : { statement }

range forms (parentheses optional):
	range end
	range(end)
	range(start, end)
	range(start, end, step)

All range arguments are evaluated once, up front, into hidden stack slots.

for type-name identifier in expression : { statement }

Container iteration via the cursor protocol (docs/projects/iteration.md):
the iterable must be a pointer to a struct type T whose module provides

	int T_iter_begin(c)        # first cursor value
	int T_iter_done(c, cur)    # 1 when cur is past the end
	int T_iter_next(c, cur)    # cursor after cur
	int T_iter_value(c, cur)   # element at cur

The container expression is evaluated exactly once into a hidden stack
slot and the cursor lives in a second one, mirroring the range lowering:

	container = expression
	cursor = T_iter_begin(container)
	cond: if T_iter_done(container, cursor): exit
	x = T_iter_value(container, cursor)
	body
	step: cursor = T_iter_next(container, cursor)   # continue lands here
	jmp cond
*/


void ivopt_range_step();   /* compiler/ivopt.w (unit O7) */


# Load the iterator function's address into eax: directly for an
# ordinary symbol, through the generic instantiation's backpatch chain
# (grammar/generic.w) when the container is generic and the
# instantiation's body has not been compiled yet. The instantiation was
# interned by for_iter_generic_require, so the lookup cannot miss.
void for_iter_callee(char* fn_name, int t):
	if (t >= 0):
		sym_emit_value(t, fn_name)
		return;
	int inst = generic_inst_lookup(fn_name)
	if (inst < 0): error2(fn_name, c" is not defined")
	generic_inst_emit_callee(inst)


# Emit a call to fn_name(container) or, when cursor_slot is nonzero,
# fn_name(container, cursor). The operands live in hidden stack slots
# identified by their stack_pos anchors; the result is left in eax.
void for_iter_call(char* fn_name, int container_slot, int cursor_slot):
	int s = stack_pos
	# A direct call (unit A4) records the callee instead of parking it
	int t = sym_lookup(fn_name)
	if (direct_callee_ok(t)): direct_call_record(s, 1, t)
	else if ((t < 0) && direct_generic_ok()):
		int inst = generic_inst_lookup(fn_name)
		if (inst < 0): error2(fn_name, c" is not defined")
		direct_call_record(s, 2, inst)
	else:
		for_iter_callee(fn_name, t)
		push_slot()
		direct_call_record(s, 0, 0)
	push_slot_copy(container_slot)
	if (cursor_slot != 0): push_slot_copy(cursor_slot)
	rt_call_end(s)


void for_iter_error_prefix(char* container_name, char* fn_name):
	diag_part(c"type '")
	diag_part(container_name)
	diag_part(c"' is not iterable: ")
	diag_part(fn_name)


void for_iter_require(char* container_name, char* fn_name, int expected_args, int container_type):
	int symbol = sym_lookup(fn_name)
	if (symbol < 0):
		for_iter_error_prefix(container_name, fn_name)
		error(c" not found")
	if (load_int(table + symbol + 10) != 2):
		for_iter_error_prefix(container_name, fn_name)
		error(c" is not a function")
	if (sym_num_args(symbol) != expected_args):
		for_iter_error_prefix(container_name, fn_name)
		error(c" has wrong arity")

	int return_type = load_int(table + symbol + 6)
	if ((type_get_size(return_type) == 0) | (type_stack_words(return_type) != 1)):
		for_iter_error_prefix(container_name, fn_name)
		error(c" must return a word-sized value")

	int param_type = sym_param_type(symbol, 0)
	if (type_unqualified(type_safe_target(param_type)) != type_unqualified(type_safe_target(container_type))):
		for_iter_error_prefix(container_name, fn_name)
		error(c" first parameter must match the iterable type")

	if (expected_args == 2):
		param_type = sym_param_type(symbol, 1)
		if (type_unqualified(param_type) != type_lookup(c"int")):
			for_iter_error_prefix(container_name, fn_name)
			error(c" second parameter must be int")


/*
Generic containers. An instantiated generic struct's type name is
'name$arg' (grammar/generic.w mangling), so the symbol the cursor
protocol would need ('name$arg_iter_begin') can never exist. Instead a
generic container provides the protocol as generic FUNCTIONS —
heap_iter_begin[T](heap[T]* h) and friends — and the loop resolves
each one to the instantiation with the container's own type argument
('heap$int' iterates through 'heap_iter_begin$int'). The bodies are
compiled by the end-of-compilation drain like any other instantiation;
call sites emitted before that go through the backpatch chain
(for_iter_callee). The instance metadata retains every type argument, avoiding ambiguous
splitting of nested or multi-parameter mangled suffixes.
*/


# Index of the first '$' in an instantiated generic struct's name, -1
# for ordinary (non-generic) type names.
int for_iter_generic_split(char* name):
	int i = 0
	while (name[i]):
		if (name[i] == '$'):
			return i
		i = i + 1
	return -1


# Recover the type argument from the container's mangled name: the text
# after the '$' is one canonical type name with one '*' per pointer
# level ('heap$int' -> int, 'deque$char*' -> char*, 'box$pair$int' ->
# the instantiated 'pair$int'). Returns the type index, -1 when the
# name is not in the type table.
int for_iter_generic_arg(char* container_name, int dollar):
	char* arg_name = strclone(container_name + dollar + 1)
	int n = 0
	while (arg_name[n]): n = n + 1
	int stars = 0
	while ((n > 0) && (arg_name[n - 1] == '*')):
		n = n - 1
		arg_name[n] = 0
		stars = stars + 1
	int arg_type = type_lookup(arg_name)
	free(arg_name)
	if (arg_type < 0): return -1
	while (stars > 0):
		arg_type = type_get_next_pointer(arg_type)
		stars = stars - 1
	return arg_type


# The generic counterpart of for_iter_require: resolve one
# cursor-protocol function for an instantiated generic container
# ('heap$int' + "begin" -> 'heap_iter_begin$int'), interning the
# instantiation when its body has not been compiled yet, and mirror
# for_iter_require's signature checks against the instantiation's
# signature. Returns the mangled symbol name (caller frees).
char* for_iter_generic_require(char* container_name, char* what, int expected_args, int container_type):
	int dollar = for_iter_generic_split(container_name)
	char* base = strclone(container_name)
	base[dollar] = 0
	char* prefix = strjoin(base, c"_iter_")
	char* fn_base = strjoin(prefix, what)
	free(prefix)
	free(base)
	int def = generic_def_lookup(fn_base, 0)
	if (def < 0):
		for_iter_error_prefix(container_name, fn_base)
		error(c" not found")
	int args = cast(int, malloc(generic_max_params * __word_size__))
	int record = type_unqualified(type_lookup_previous_pointer(type_safe_target(container_type)))
	# The specialization's base name precedes its first '$'.
	char* struct_name = strclone(container_name)
	struct_name[dollar] = 0
	int struct_def = generic_def_lookup(struct_name, 1)
	free(struct_name)
	int count = -1
	if (struct_def >= 0): count = generic_struct_instance_lookup(record, struct_def, cast(int*, args))
	if ((count < 1) || (generic_def_param_count(def) != count)):
		for_iter_error_prefix(container_name, fn_base)
		if (count == 1): error(c" must take exactly one type parameter")
		error(c" must take the container's type parameters")
	char* mangled = generic_mangle(fn_base, args, count)
	free(fn_base)
	if (sym_lookup(mangled) >= 0):
		free(cast(char*, args))
		for_iter_require(container_name, mangled, expected_args, container_type)
		return mangled
	int inst = generic_inst_intern(def, args, count, strclone(mangled))
	int sig = generic_inst_signature(inst)
	if (type_function_param_count(sig) != expected_args):
		for_iter_error_prefix(container_name, mangled)
		error(c" has wrong arity")
	int return_type = type_function_return(sig)
	if ((type_get_size(return_type) == 0) | (type_stack_words(return_type) != 1)):
		for_iter_error_prefix(container_name, mangled)
		error(c" must return a word-sized value")
	if (type_unqualified(type_safe_target(type_function_param_type(sig, 0))) != type_unqualified(type_safe_target(container_type))):
		for_iter_error_prefix(container_name, mangled)
		error(c" first parameter must match the iterable type")
	if (expected_args == 2):
		if (type_unqualified(type_function_param_type(sig, 1)) != type_lookup(c"int")):
			for_iter_error_prefix(container_name, mangled)
			error(c" second parameter must be int")
	return mangled


# Loop-variable type for an inferred 'for x in <generic container>':
# the declared return type of the container's '<base>_iter_value'
# instantiation when one resolves; int otherwise (for_iter_require
# reports the real error for a non-iterable type).
int for_iter_generic_value_type(int container_type):
	char* base = strclone(type_get_name(type_safe_target(container_type)))
	base[for_iter_generic_split(base)] = 0
	char* value_name = strjoin(base, c"_iter_value")
	free(base)
	int definition = generic_def_lookup(value_name, 0)
	free(value_name)
	if (definition < 0): return type_lookup(c"int")
	char* name = for_iter_generic_require(type_get_name(type_safe_target(container_type)), c"value", 2, container_type)
	int symbol = sym_lookup(name)
	int result
	if (symbol >= 0): result = load_int(table + symbol + 6)
	else: result = type_function_return(generic_inst_signature(generic_inst_lookup(name)))
	free(name)
	return result


void for_iter_require_struct_pointer(int container_type):
	if (type_get_pointer_level(container_type) != 1):
		diag_part(c"type '")
		print_error_type(container_type)
		error2(c"' is not iterable: ", c"expected a pointer to a container struct")
	int base_type = type_lookup_previous_pointer(container_type)
	if ((base_type < 0) | (type_num_args(base_type) == 0)):
		diag_part(c"type '")
		print_error_type(container_type)
		error2(c"' is not iterable: ", c"expected a pointer to a container struct")


# The "in range" body of for_statement; "for", the loop variable and
# "in range" have already been consumed. for_var anchors the loop
# variable's stack slot.
void ast_for_range_loop(int for_var, int for_tab_level);
int ast_iteration_value(int store_slot);


# Store the accumulator into the loop variable anchored at slot: its
# register when it is register-resident (R2b), else its stack word.
void for_store_loop_var(int slot):
	int reg = regalloc_slot_register(slot - 1)
	if (reg != 0): mov_reg_eax(reg)
	else:
		regalloc_slot_assert(slot - 1)
		store_stack_var((stack_pos - slot) << word_size_log2)


# The range loop's test, 'loop var < end' as a setl comparison for the
# discard branch that follows: be_br_zero_discard to the exit at a
# top-tested head, be_br_nonzero_discard back to the body at the bottom
# of a rotated loop (grammar/loop_rotate.w). The hidden end word is in
# its loop register (R3) when the loop owns one.
void for_range_test(int for_var, int end_slot):
	int for_reg = regalloc_slot_register(for_var - 1)
	int end_reg = regalloc_hidden_register(end_slot)
	if (for_reg != 0):
		mov_eax_reg(for_reg)
		push_slot()
	else: push_slot_copy(for_var)
	if (end_reg != 0): mov_eax_reg(end_reg)
	else: load_slot(end_slot)
	pop_ebx()
	alu_cmp_set(0x9c) /* setl: loop var < end */
	stack_pos = stack_pos - 1


# The cursor loop's test. Returns 1 when the accumulator (or the flags
# of the setl it leaves current) is nonzero while the loop CONTINUES
# (the index form, 'cursor < length'), 0 when nonzero means it is DONE
# (done_fn's result); the caller branches accordingly.
int for_cursor_test(char* done_fn, int container_slot, int cursor_slot):
	if (done_fn != 0):
		for_iter_call(done_fn, container_slot, cursor_slot)
		return 0
	push_slot_copy(cursor_slot)
	load_slot(container_slot)
	add_eax_int32(word_size)
	promote_eax()
	pop_ebx_slot()
	alu_cmp_set(0x9c) /* setl: cursor < length */
	return 1


void for_range_loop(int for_var, int for_tab_level):
	if (ast_expressions_mode >= 2):
		ast_for_range_loop(for_var, for_tab_level)
		return
	# The bottom test of a rotated loop belongs to the header's line
	int header_line = diag_token_line
	int has_parens = accept(c"(")
	int num_range_args = 1
	promote(expression())
	int first_slot = push_slot()
	int second_slot = 0
	int third_slot = 0
	while (accept(c",")):
		promote(expression())
		int slot = push_slot()
		num_range_args = num_range_args + 1
		if (num_range_args == 2): second_slot = slot
		else if (num_range_args == 3): third_slot = slot
	if (has_parens): expect(c")")
	if (num_range_args > 3): error(c"range() takes 1-3 arguments")

	# With 2+ arguments the first one is the start: copy it into the loop var
	int end_slot = first_slot
	# A register-resident loop variable (R2b): its stack word is never
	# written, the register is.
	int for_reg = regalloc_slot_register(for_var - 1)
	if (num_range_args >= 2):
		end_slot = second_slot
		load_slot(first_slot)
		if (for_reg != 0): mov_reg_eax(for_reg)
		else:
			regalloc_slot_assert(for_var - 1)
			store_stack_var((stack_pos - for_var) << word_size_log2)
	elif (for_reg != 0):
		mov_eax_int(0)
		mov_reg_eax(for_reg)

	# Enter a new loop context for break/continue. The loop may own
	# caller-saved registers from here (R3): the loop variable itself
	# (re-read: loop_enter may have given it one) and the hidden end and
	# step words, loaded ahead of the loop region. O7: this loop's
	# increment steps pointers its variable drives (compiler/ivopt.w).
	ivopt_range_ok = num_range_args < 3
	int* outer = loop_enter()
	ivopt_range_ok = 0
	for_reg = regalloc_slot_register(for_var - 1)
	regalloc_loop_hidden(end_slot)
	int step_reg = 0
	if (num_range_args == 3): step_reg = regalloc_loop_hidden(third_slot)
	# A rotated loop (grammar/loop_rotate.w) enters at the bottom test
	int entry = -1
	if (loop_rotate_on()): entry = be_loop_entry()
	# Loop region: the back edge re-tests the condition at a top-tested
	# head, or starts the body of a rotated loop.
	profile_use_loop_align()   # P2: --profile-use pads a hot head to 16 bytes
	int h_top = be_ctrl_loop()
	profile_loop_head()   # P1: --profile-generate

	# condition: loop var < end
	if (entry < 0):
		for_range_test(for_var, end_slot)
		be_br_zero_discard(loop_break_chain)

	# Continue region: 'continue' in the body runs the increment first
	loop_continue_chain = be_ctrl_block()

	/* ':' scoping + child scope statements */
	enclosing_tab_level = for_tab_level
	statement()

	/* increment: by 1, or by the step argument */
	be_ctrl_end(loop_continue_chain)
	if (num_range_args == 3):
		if (step_reg != 0): mov_eax_reg(step_reg)
		else: load_slot(third_slot)
		if (for_reg != 0): add_reg_eax(for_reg)
		else:
			regalloc_slot_assert(for_var - 1)
			add_dword_esp_plus_eax((stack_pos - for_var) << word_size_log2)
	elif (for_reg != 0): add_reg_int8(for_reg, 1)
	else:
		regalloc_slot_assert(for_var - 1)
		inc_dword_esp_plus((stack_pos - for_var) << word_size_log2)
	if (ivopt_live && (num_range_args < 3)): ivopt_range_step()   # O7: compiler/ivopt.w

	if (entry >= 0):
		# the bottom test: back to the body while loop var < end
		be_loop_entry_land(entry)
		debug_line_note_at(header_line, stack_pos)
		for_range_test(for_var, end_slot)
		be_br_nonzero_discard(h_top)
	else:
		/* jmp back to condition */
		be_br(h_top)
	be_ctrl_end(h_top)

	# break exits here; continue ran the increment first
	be_ctrl_end(loop_break_chain)

	loop_leave(outer)

	# Discard the hidden range slots (the loop variable itself stays)
	drop_slots(num_range_args)


/*
Exit-cleanup registry: one record per enclosing for-in loop whose
iterable owns a resource every exit edge must release (today: loops
over a generator call gen_free). break and continue stay inside the
loop machinery, so the loop's own exit edges cover them, but 'return'
(and '?' error propagation, grammar/statement.w) leave the function
without passing those edges; statement.w walks this registry and emits
each free call before unwinding the frame. for_cursor_loop pushes on
body entry and pops on body exit, so the registry always holds exactly
the loops enclosing the statement being parsed. The REPL and the
debugger's evaluator roll a failed parse back with
for_cleanup_truncate, like defer_spans (grammar/defer.w).
*/
struct for_cleanup_record:
	char* free_fn      # runtime function: free_fn(container)
	int container_slot # stack_pos anchor of the hidden container slot


list[for_cleanup_record] for_cleanups


int for_cleanup_count():
	if (cast(int, for_cleanups) == 0): return 0
	return for_cleanups.length


# Discards every record past the first n without touching the backing
# capacity (the defer_truncate trick — list[T]'s '.length' is read-only
# at the language level).
void for_cleanup_truncate(int n):
	if (cast(int, for_cleanups) == 0): return;
	__w_list* raw = cast(__w_list*, for_cleanups)
	raw.length = n


void for_cleanup_push(char* free_fn, int container_slot):
	if (cast(int, for_cleanups) == 0): for_cleanups = new list[for_cleanup_record]
	for_cleanup_record rec
	rec.free_fn = free_fn
	rec.container_slot = container_slot
	for_cleanups.push(rec)


# Emit the free call of every registered cleanup, innermost loop first,
# at the current code position. Clobbers eax (for_iter_call); exits
# carrying a live return value go through for_cleanup_emit_returning.
void for_cleanup_emit_all():
	int i = for_cleanup_count()
	while (i > 0):
		i = i - 1
		for_iter_call(for_cleanups[i].free_fn, for_cleanups[i].container_slot, 0)


# Function-exit path with the pending return value in eax: save it
# around the free calls so they cannot clobber it, mirroring
# defer_emit_returning (grammar/defer.w).
void for_cleanup_emit_returning():
	if (for_cleanup_count() == 0): return;
	push_slot()
	for_cleanup_emit_all()
	pop_eax_slot()


# Freeze an inline checked descriptor by value. Its address may refer to a
# mutable local, a field, or a temporary call result; the iterator retains
# its own data/length pair even when another expression overwrites that home.
# kind 2 reads an audited WOwnedBuffer[T] descriptor instead: its element
# array (T**) is the fourth word and its length the second.
void for_capture_slice(int kind):
	int original = push_slot()
	if (kind == 2): add_eax_int32(3 * word_size)
	promote_eax()
	push_slot()
	load_slot(original)
	add_eax_int32(word_size)
	promote_eax()
	store_stack_var(word_size)
	lea_eax_esp_plus(0)


# Emit the cursor-loop scaffold shared by every for-in container shape:
# hidden container and cursor slots, break/continue context, done-check,
# loop-variable extraction, body, advance, back-jump, chain patching.
# The variation points are data; each runtime helper is called by name
# through for_iter_call, and 0 selects the index-based fallback:
#   begin_fn   cursor init, begin_fn(container); 0 = index starting at 0
#   done_fn    exit test, done_fn(container, cursor) nonzero ends the
#              loop; 0 = keep going while cursor < the word at
#              container + word_size (slice length / string byte count)
#   value_fn   loop-variable accessor, value_fn(container, cursor);
#              0 = load the slice element at data + cursor * element size
#   next_fn    advance, next_fn(container, cursor) yields the new cursor;
#              0 = increment the cursor slot in place
#   free_fn    free_fn(container) on both exit edges (done and break),
#              e.g. gen_free for generator loops; 0 = nothing
#   element_type        slice element type, read only when value_fn == 0
#   value_coerce_type   source type coerced into the loop variable;
#                       -1 = store the extracted value uncoerced
#   value_var / value_var_type / value2_fn / value2_coerce_type
#              second loop variable ("for K k, V v in map"): stack-slot
#              anchor, declared type, accessor, and coercion source.
#              value_var == 0 = no second variable.
void ast_for_cursor_loop(int for_var, int for_tab_level, int loop_var_type,
		char* begin_fn, char* done_fn, char* value_fn, char* next_fn, char* free_fn,
		int element_type, int value_coerce_type,
		int value_var, int value_var_type, char* value2_fn, int value2_coerce_type, int capture_slice);


void for_cursor_loop(int for_var, int for_tab_level, int loop_var_type,
		char* begin_fn, char* done_fn, char* value_fn, char* next_fn, char* free_fn,
		int element_type, int value_coerce_type,
		int value_var, int value_var_type, char* value2_fn, int value2_coerce_type, int capture_slice):
	if (ast_expressions_mode >= 2):
		ast_for_cursor_loop(for_var, for_tab_level, loop_var_type,
			begin_fn, done_fn, value_fn, next_fn, free_fn,
			element_type, value_coerce_type, value_var, value_var_type, value2_fn, value2_coerce_type, capture_slice)
		return
	# The bottom test of a rotated loop belongs to the header's line
	int header_line = diag_token_line
	if (capture_slice): for_capture_slice(capture_slice)
	# hidden slot: the container pointer
	int container_slot = push_slot()

	# hidden slot: the cursor
	if (begin_fn != 0): for_iter_call(begin_fn, container_slot, 0)
	else: mov_eax_int(0)
	int cursor_slot = push_slot()

	# Enter a new loop context for break/continue
	# The exit region is where free_fn releases the container.
	int* outer = loop_enter()
	# A rotated loop (grammar/loop_rotate.w) enters at the bottom test
	int entry = -1
	if (loop_rotate_on()): entry = be_loop_entry()
	# Loop region: the back edge re-tests at a top-tested head, or
	# starts the body of a rotated loop.
	profile_use_loop_align()   # P2: --profile-use pads a hot head to 16 bytes
	int h_top = be_ctrl_loop()
	profile_loop_head()   # P1: --profile-generate

	# condition: exit once done_fn(container, cursor) is true, or once
	# the index cursor reaches the length word
	if (entry < 0):
		if (for_cursor_test(done_fn, container_slot, cursor_slot)): be_br_zero_discard(loop_break_chain)
		else: be_br_nonzero_discard(loop_break_chain)

	# Continue region: 'continue' in the body advances the cursor first
	loop_continue_chain = be_ctrl_block()

	# loop var = value_fn(container, cursor), or the slice element at
	# data + cursor * element_size
	int extracted_type = value_coerce_type
	if (value_fn != 0): for_iter_call(value_fn, container_slot, cursor_slot)
	else:
		load_slot(container_slot)
		promote_eax() /* the descriptor's data pointer */
		push_slot()
		load_slot(cursor_slot)
		int element_size = type_get_size(element_type)
		if (element_size > 1): imul_eax_int32(element_size)
		pop_ebx_slot()
		alu_add()
		if (capture_slice == 2):
			# Load the stored element pointer; its checked borrow never moves it.
			promote(element_type)
			extracted_type = loop_var_type
		else if (capture_slice && (type_safe_kind(loop_var_type) >= 2)): extracted_type = loop_var_type
		else: extracted_type = promote(element_type)
	if (extracted_type != -1): coerce(loop_var_type, extracted_type)
	for_store_loop_var(for_var)

	if (value_var != 0):
		for_iter_call(value2_fn, container_slot, cursor_slot)
		coerce(value_var_type, value2_coerce_type)
		for_store_loop_var(value_var)

	# While the body parses, 'return' (grammar/statement.w) must know
	# about this loop's live resource so it can free it before leaving
	# the function; the record is popped once the body is done
	if (free_fn != 0): for_cleanup_push(free_fn, container_slot)

	/* ':' scoping + child scope statements */
	enclosing_tab_level = for_tab_level
	statement()

	if (free_fn != 0): for_cleanup_truncate(for_cleanup_count() - 1)

	# step (continue lands here): cursor = next_fn(container, cursor),
	# or an in-place index increment
	be_ctrl_end(loop_continue_chain)
	if (next_fn != 0):
		for_iter_call(next_fn, container_slot, cursor_slot)
		store_stack_var((stack_pos - cursor_slot) << word_size_log2)
	else: inc_dword_esp_plus((stack_pos - cursor_slot) << word_size_log2)

	if (entry >= 0):
		# the bottom test: back to the body while not done
		be_loop_entry_land(entry)
		debug_line_note_at(header_line, stack_pos)
		if (for_cursor_test(done_fn, container_slot, cursor_slot)): be_br_nonzero_discard(h_top)
		else: be_br_zero_discard(h_top)
	else:
		/* jmp back to condition */
		be_br(h_top)
	be_ctrl_end(h_top)

	# Both exit edges (done and break) land here: release the container
	# before falling through
	be_ctrl_end(loop_break_chain)
	if (free_fn != 0): for_iter_call(free_fn, container_slot, 0)

	loop_leave(outer)

	# Discard the hidden container and cursor slots (the loop variable stays)
	drop_slots(2 + (capture_slice != 0) * 2)


# value_var is 0 for the one-variable form; otherwise it anchors the
# stack slot of the value loop variable in "for K key, V value in map".
void for_hash_container_loop(int for_var, int for_tab_level, int loop_var_type, int container_type, int value_var, int value_var_type):
	int key_type = type_set_key_type(container_type)
	if (type_is_map(container_type)): key_type = type_map_key_type(container_type)
	if (types_compatible_with_expression(loop_var_type, key_type) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, key_type)

	char* value_call = c"__w_map_iter_value"
	int loop_value_type = -1
	if (value_var != 0):
		if (type_is_map(container_type) == 0): error(c"sets have no values: use one loop variable")
		loop_value_type = type_map_value_type(container_type)
		# Struct values cannot fit the word-sized loop variable; yield
		# each stored value's address instead: for K k, point* p in m
		if (type_num_args(loop_value_type) > 0):
			value_call = c"__w_map_iter_value_addr"
			loop_value_type = type_get_next_pointer(loop_value_type)
		if (types_compatible_with_expression(value_var_type, loop_value_type) == 0):
			warn_type_mismatch(c"for loop value variable", value_var_type, loop_value_type)

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			c"__w_map_iter_begin", c"__w_map_iter_done", c"__w_map_iter_key", c"__w_map_iter_next", 0,
			-1, key_type,
			value_var, value_var_type, value_call, loop_value_type, 0)


# value_var is 0 for the one-variable form; otherwise "for i, x in l"
# binds the element index to the first variable and the element to the
# second (issue #360) — the list counterpart of the map key/value form.
# The cursor already is the element index, so the first variable reads
# it through __w_list_iter_index.
void for_list_loop(int for_var, int for_tab_level, int loop_var_type, int container_type, int value_var, int value_var_type):
	int element_type = type_list_element_type(container_type)
	# Struct elements cannot fit in the word-sized loop variable, so the
	# loop yields each element's address instead: for point* p in l
	char* value_call = c"__w_list_iter_value"
	int loop_value_type = element_type
	if (type_num_args(element_type) > 0):
		value_call = c"__w_list_addr"
		loop_value_type = type_get_next_pointer(element_type)

	if (value_var != 0):
		if (types_compatible_with_expression(loop_var_type, type_lookup(c"int")) == 0):
			warn_type_mismatch(c"for loop variable", loop_var_type, type_lookup(c"int"))
		if (types_compatible_with_expression(value_var_type, loop_value_type) == 0):
			warn_type_mismatch(c"for loop value variable", value_var_type, loop_value_type)
		for_cursor_loop(for_var, for_tab_level, loop_var_type,
				c"__w_list_iter_begin", c"__w_list_iter_done", c"__w_list_iter_index", c"__w_list_iter_next", 0,
				-1, type_lookup(c"int"),
				value_var, value_var_type, value_call, loop_value_type, 0)
		return;

	if (types_compatible_with_expression(loop_var_type, loop_value_type) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, loop_value_type)

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			c"__w_list_iter_begin", c"__w_list_iter_done", value_call, c"__w_list_iter_next", 0,
			-1, loop_value_type,
			0, -1, 0, -1, 0)


# Iterate a slice (T[] descriptor): hidden slots hold the descriptor
# pointer and the running element index; each pass loads the element at
# data + index * element_size into the loop variable. Fixed arrays reach
# this path too, because promote() decays them to slice values.
void for_slice_loop(int for_var, int for_tab_level, int loop_var_type, int container_type):
	int element_type = type_unqualified(type_get_element_type(container_type))
	int yielded_type = element_type
	int reference = type_safe_kind(loop_var_type)
	if ((type_num_args(element_type) > 0) || (type_is_safe_slice(container_type) && (reference >= 2))):
		if (type_is_safe_slice(container_type) == 0): error(c"slice iteration requires scalar or pointer elements")
		if ((reference < 2) || (reference > 3) || (type_get_pointer_level(loop_var_type) != 1)):
			error(c"safe: record slice iteration requires a shared reference variable or an exclusive reference to a mutable slice")
		if ((reference == 3) && (type_safe_kind(container_type) != 3)):
			error(c"safe: shared slice iteration requires a shared reference variable")
		yielded_type = type_get_safe(type_get_next_pointer(element_type), reference)
	if (types_compatible_with_expression(loop_var_type, yielded_type) == 0):
		if (type_is_safe_slice(container_type) && ((type_num_args(element_type) > 0) || (reference >= 2))): error(c"safe: incompatible record slice iteration variable type")
		warn_type_mismatch(c"for loop variable", loop_var_type, yielded_type)

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			0, 0, 0, 0, 0,
			element_type, -1,
			0, -1, 0, -1, type_is_safe_slice(container_type))


# The element type T of an audited WOwnedBuffer[T] (lib/safe_owned_vector.w)
# reached through a non-optional checked pointer, else -1. The safety pass
# separately requires the resolved runtime to be the pinned one.
int for_owned_storage_element(int container_type):
	int kind = type_get_kind(type_unqualified(container_type))
	int optional = (kind == type_kind_optown) || (kind == type_kind_optref) || (kind == type_kind_optrefmut)
	if (((kind < type_kind_own) || (kind > type_kind_refmut)) && (optional == 0)): return -1
	int pointer = type_safe_target(container_type)
	if (type_get_pointer_level(pointer) != 1): return -1
	int record = type_unqualified(type_lookup_previous_pointer(pointer))
	if (record < 0): return -1
	if (starts_with(type_get_name(record), c"WOwnedBuffer$") == 0): return -1
	if (ends_with(debug_file_name(type_decl_file_index(record)), c"/lib/safe_owned_vector.w") == 0): return -1
	type_rec* layout = type_record(record)
	if (layout.num_fields != 5): return -1
	int items = layout.field_types[3]
	if (type_get_pointer_level(items) != 2): return -1
	if (optional): error(c"safe: owned-storage iteration requires a present container; test and bind the optional owner first")
	return type_lookup_previous_pointer(type_lookup_previous_pointer(items))


# Iterate owned storage: each element is lent shared or exclusively without
# transferring ownership. The receiver must admit that borrow. Its array and
# length are captured once, like a slice descriptor.
void for_owned_storage_loop(int for_var, int for_tab_level, int loop_var_type, int element, int container_type):
	int reference = type_safe_kind(loop_var_type)
	if ((reference < 2) || (reference > 3) || (type_get_pointer_level(loop_var_type) != 1)):
		error(c"safe: owned-storage iteration requires a shared reference variable")
	if ((reference == 3) && (type_safe_kind(container_type) == 2)):
		error(c"safe: owned-storage iteration requires a shared reference variable through a shared container")
	int yielded = type_get_safe(type_get_next_pointer(element), reference)
	if (types_compatible_with_expression(loop_var_type, yielded) == 0):
		error(c"safe: incompatible owned-storage iteration variable type")
	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			0, 0, 0, 0, 0,
			type_get_next_pointer(element), -1,
			0, -1, 0, -1, 2)


void for_string_loop(int for_var, int for_tab_level, int loop_var_type):
	int decode_symbol = sym_lookup(c"utf8_decode")
	int next_symbol = sym_lookup(c"utf8_next")
	if ((decode_symbol < 0) || (next_symbol < 0)):
		error(c"string iteration requires import lib.utf8")
	if (types_compatible_with_expression(loop_var_type, type_lookup(c"int")) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, type_lookup(c"int"))

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			0, 0, c"utf8_decode", c"utf8_next", 0,
			-1, type_lookup(c"int"),
			0, -1, 0, -1, 0)


# Inferred loop variable, first half: 'for name in ...' with the type
# omitted (docs/projects/golf_ergonomics.md). Consume the identifier and
# reserve the variable's stack slot (eax holds the 0 default), but defer
# the symbol declaration until the range/container fixes its type -- the
# ':=' precedent, so the iterable expression cannot reference the new
# name. Returns the cloned name; msg is the non-identifier diagnostic.
char* for_infer_name(char* msg):
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0): error(msg)
	char* name = strclone(token)
	get_token()
	ast_body_reserve(1)
	push_slot()
	return name


# Inferred loop variable, second half: declare the deferred name with
# the type the container fixed, anchored to the slot for_infer_name
# reserved (slot is the stack_pos anchor recorded after the push, so the
# declared value is slot - 1, matching variable_declaration's layout).
void for_infer_declare(char* name, int slot, int type):
	pointer_indirection = 0
	sym_declare(name, type, 'L', slot - 1, 1)
	# A promoted loop variable (R2b) is live from here: the loop writes
	# its register before the first body iteration reads it
	regalloc_store_declared(sym_probe(name))
	lint_mark_loop_variable()
	free(name)


# Loop-variable type for 'for name in container' with the type omitted:
# maps and sets yield their key type, lists their element type (struct
# elements as element pointers, matching for_list_loop), slices their
# element type, strings int code points. A custom cursor-protocol
# container yields its value accessor's declared return type when one
# is in scope; otherwise int (for_iter_require reports the real error).
# Checked hash wrappers retain opaque identity, with their key/value shape
# recovered from audited fields rather than splitting generic mangled names.
int for_checked_hash_kind(int container_type):
	if (type_safe_kind(container_type) == 0): return 0
	int pointer = type_safe_target(container_type)
	if (type_get_pointer_level(pointer) != 1): return 0
	int record = type_unqualified(type_lookup_previous_pointer(pointer))
	char* name = type_get_name(record)
	char* path = debug_file_name(type_decl_file_index(record))
	int result = 0
	if (ends_with(path, c"/lib/safe_hash.w")):
		if (starts_with(name, c"WMap$")): result = 1
		if (starts_with(name, c"WSet$")): result = 2
	if (ends_with(path, c"/lib/safe_keyed_map.w") && starts_with(name, c"WKeyedMap$")): result = 3
	int kind = type_get_kind(type_unqualified(container_type))
	if (result && ((kind == type_kind_optown) || (kind == type_kind_optref) || (kind == type_kind_optrefmut))):
		error(c"safe: hash iteration requires a present container")
	return result


int for_checked_hash_type(int container_type, int value):
	int kind = for_checked_hash_kind(container_type)
	int record = type_unqualified(type_lookup_previous_pointer(type_safe_target(container_type)))
	type_rec* layout = type_record(record)
	int result
	if (kind == 3):
		result = type_lookup_previous_pointer(layout.field_types[4])
		if (value == 0): result = type_lookup_previous_pointer(type_lookup_previous_pointer(layout.field_types[3]))
	else:
		int table = layout.field_types[0]
		if (kind == 2): return type_set_key_type(table)
		result = type_map_key_type(table)
		if (value): result = type_map_value_type(table)
	if (value || (kind == 3)): result = type_get_safe(type_get_next_pointer(result), 2)
	return result


void for_checked_hash_loop(int for_var, int for_tab_level, int loop_type, int container_type, int value_var, int value_type):
	int kind = for_checked_hash_kind(container_type)
	int key = for_checked_hash_type(container_type, 0)
	if ((type_safe_kind(loop_type) != type_safe_kind(key)) || (types_compatible_with_expression(loop_type, key) == 0)): error(c"safe: incompatible hash iteration key type")
	int value = -1
	if (value_var):
		if (kind == 2): error(c"sets have no values: use one loop variable")
		value = for_checked_hash_type(container_type, 1)
		if ((type_get_kind(type_unqualified(value_type)) != type_kind_ref) || (types_compatible_with_expression(value_type, value) == 0)): error(c"safe: hash iteration values require a matching shared reference")
	char* begin = c"__w_checked_hash_iter_begin"
	char* done = c"__w_checked_hash_iter_done"
	char* next = c"__w_checked_hash_iter_next"
	char* key_fn = c"__w_checked_hash_iter_key"
	char* value_fn = c"__w_checked_hash_iter_value"
	if (kind == 3):
		begin = c"__w_keyed_map_iter_begin"
		done = c"__w_keyed_map_iter_done"
		next = c"__w_keyed_map_iter_next"
		key_fn = c"__w_keyed_map_iter_key"
		if (value_var): value_fn = for_iter_generic_require(type_get_name(type_safe_target(container_type)), c"value", 2, container_type)
	for_cursor_loop(for_var, for_tab_level, loop_type, begin, done, key_fn, next, 0,
		-1, key, value_var, value_type, value_fn, value, 0)
	if ((kind == 3) && value_var): free(value_fn)


# Implicit calls keep the exact resolved binding, or the pending generic's
# mangled identity, so checked validation cannot be bypassed by a raw helper.
void for_checked_protocol_note(char* begin, char* done, char* next, char* value, int container_type):
	if (retained_parent < 0): return
	retained_iteration* contract = cast(retained_iteration*, retained_arena_alloc(sizeof(retained_iteration)))
	contract.bindings = cast(int*, retained_arena_alloc(4 * __word_size__))
	contract.names = cast(char**, retained_arena_alloc(4 * __word_size__))
	char*[4] names
	names[0] = begin
	names[1] = done
	names[2] = next
	names[3] = value
	for i in range(4):
		contract.names[i] = retained_intern(names[i])
		int symbol = sym_lookup(names[i])
		contract.bindings[i] = -1
		int parameter
		if (symbol >= 0):
			contract.bindings[i] = retained_binding_note(symbol, retained_parent)
			parameter = sym_param_type(symbol, 0)
		else: parameter = type_function_param_type(generic_inst_signature(generic_inst_lookup(names[i])), 0)
		if (type_safe_kind(parameter)):
			if (type_safe_kind(container_type) == 0): error(c"safe: iterator requires a checked container; bind allocations to a named owner first")
			retained_record_at(retained_parent).semantic_type = retained_type_note(parameter)
	retained_record_at(retained_parent).iteration = contract


int for_infer_var_type(int container_type):
	if (for_checked_hash_kind(container_type)): return for_checked_hash_type(container_type, 0)
	int stored = for_owned_storage_element(container_type)
	if (stored >= 0): return type_get_safe(type_get_next_pointer(stored), 2)
	if (type_is_map(container_type)): return type_map_key_type(container_type)
	if (type_is_set(container_type)): return type_set_key_type(container_type)
	if (type_is_list(container_type)):
		int element_type = type_list_element_type(container_type)
		if (type_num_args(element_type) > 0): return type_get_next_pointer(element_type)
		return element_type
	if (type_is_slice(container_type)):
		int element_type = type_unqualified(type_get_element_type(container_type))
		if (type_is_safe_slice(container_type) && (type_num_args(element_type) > 0)):
			return type_get_safe(type_get_next_pointer(element_type), type_safe_kind(container_type))
		return element_type
	if (type_is_string(container_type)): return type_lookup(c"int")
	if (type_get_pointer_level(container_type) == 1):
		if (for_iter_generic_split(type_get_name(type_safe_target(container_type))) >= 0):
			return for_iter_generic_value_type(container_type)
		char* value_name = strjoin(type_get_name(type_safe_target(container_type)), c"_iter_value")
		int symbol = sym_lookup(value_name)
		free(value_name)
		if (symbol >= 0):
			if (load_int(table + symbol + 10) == 2): return load_int(table + symbol + 6)
	return type_lookup(c"int")


# The "in <container>" body of for_statement; "for", the loop variable(s)
# and "in" have already been consumed. Emits the cursor-protocol loop
# described in the header comment. value_var is 0 unless a second loop
# variable was declared: maps bind key and value ("for K key, V value
# in map"), lists bind index and element ("for i, x in l", issue #360);
# other containers reject it. infer_name/infer_name2 carry the deferred
# names of loop variables declared without a type (0 for the typed
# form): they are declared here, right after the container expression
# fixes their types.
void for_container_loop(int for_var, int for_tab_level, int loop_var_type, int value_var, int value_var_type, char* infer_name, char* infer_name2):
	# for i, x in enumerate(l): explicit index+element sugar in the
	# iterable position (issue #360), equivalent to 'for i, x in l'.
	# The prelude resolve rule applies: only a bare 'enumerate(' with no
	# user symbol or generic of that name is claimed. Lists are the only
	# enumerable shape and the two-variable form is required (W has no
	# tuples for a one-variable form to bind).
	int is_enumerate = 0
	if (peek(c"enumerate") && (nextc == '(')):
		if ((sym_lookup(token) < 0) && (generic_def_lookup(token, 0) < 0)):
			is_enumerate = 1
			get_token()
			expect(c"(")
	# The iterable is evaluated exactly once, before the body
	int container_type
	if (ast_expressions_mode >= 2): container_type = ast_iteration_value(0)
	else: container_type = promote(expression())
	container_type = type_unqualified(container_type)
	# A checked iterable also makes a loop with only scalar variables checked.
	# This matters when its generic call was lowered before a retained root
	# became available: the safety pass must reject missing analysis.
	if ((retained_parent >= 0) && type_safe_kind(container_type)):
		retained_record_at(retained_parent).semantic_type = retained_type_note(container_type)
	if (is_enumerate):
		expect(c")")
		if (type_is_list(container_type) == 0):
			error_type(c"enumerate requires a list, got '", container_type, c"'")
		if (value_var == 0):
			error(c"enumerate requires two loop variables: for i, x in enumerate(l)")
	if (infer_name != 0):
		loop_var_type = for_infer_var_type(container_type)
		# Two-variable list iteration binds the element index first
		if (type_is_list(container_type) && (value_var != 0)): loop_var_type = type_lookup(c"int")
		for_infer_declare(infer_name, for_var, loop_var_type)
	if (infer_name2 != 0):
		int inferred_value_type = type_lookup(c"int")
		if (type_is_map(container_type)):
			inferred_value_type = type_map_value_type(container_type)
			# Struct values yield each stored value's address, matching
			# for_hash_container_loop's __w_map_iter_value_addr path
			if (type_num_args(inferred_value_type) > 0):
				inferred_value_type = type_get_next_pointer(inferred_value_type)
		if (type_is_list(container_type)):
			inferred_value_type = type_list_element_type(container_type)
			# Struct elements yield element addresses, matching
			# for_list_loop's __w_list_addr path
			if (type_num_args(inferred_value_type) > 0):
				inferred_value_type = type_get_next_pointer(inferred_value_type)
		if (for_checked_hash_kind(container_type)): inferred_value_type = for_checked_hash_type(container_type, 1)
		value_var_type = inferred_value_type
		for_infer_declare(infer_name2, value_var, inferred_value_type)
	if (for_checked_hash_kind(container_type)):
		for_checked_hash_loop(for_var, for_tab_level, loop_var_type, container_type, value_var, value_var_type)
		return
	if (type_is_map(container_type) | type_is_set(container_type)):
		for_hash_container_loop(for_var, for_tab_level, loop_var_type, container_type, value_var, value_var_type)
		return;
	if (type_is_list(container_type)):
		for_list_loop(for_var, for_tab_level, loop_var_type, container_type, value_var, value_var_type)
		return;
	if (value_var != 0): error(c"only maps and lists support two loop variables")
	if (type_is_slice(container_type)):
		for_slice_loop(for_var, for_tab_level, loop_var_type, container_type)
		return;
	if (type_is_string(container_type)):
		for_string_loop(for_var, for_tab_level, loop_var_type)
		return;
	int stored = for_owned_storage_element(container_type)
	if (stored >= 0):
		for_owned_storage_loop(for_var, for_tab_level, loop_var_type, stored, container_type)
		return;
	for_iter_require_struct_pointer(container_type)

	char* container_name = type_get_name(type_safe_target(container_type))
	# Generator iterables get gen_free on the loop's exit edges (normal
	# exit and break) so a broken-out-of loop does not leak the
	# suspended generator's stack. 'return' (and '?') bypass those edges;
	# they free through the for_cleanup registry above instead.
	char* free_name = 0
	if (strcmp(container_name, c"generator") == 0): free_name = c"gen_free"
	char* begin_name = 0
	char* done_name = 0
	char* next_name = 0
	char* value_name = 0
	if (for_iter_generic_split(container_name) >= 0):
		# Instantiated generic container 'name$arg': the protocol
		# functions are the generic 'name_iter_*' functions
		# instantiated with the container's own type argument
		begin_name = for_iter_generic_require(container_name, c"begin", 1, container_type)
		done_name = for_iter_generic_require(container_name, c"done", 2, container_type)
		next_name = for_iter_generic_require(container_name, c"next", 2, container_type)
		value_name = for_iter_generic_require(container_name, c"value", 2, container_type)
	else:
		char* iter_prefix = strjoin(container_name, c"_iter_")
		begin_name = strjoin(iter_prefix, c"begin")
		done_name = strjoin(iter_prefix, c"done")
		next_name = strjoin(iter_prefix, c"next")
		value_name = strjoin(iter_prefix, c"value")
		free(iter_prefix)
		for_iter_require(container_name, begin_name, 1, container_type)
		for_iter_require(container_name, done_name, 2, container_type)
		for_iter_require(container_name, next_name, 2, container_type)
		for_iter_require(container_name, value_name, 2, container_type)

	for_checked_protocol_note(begin_name, done_name, next_name, value_name, container_type)

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			begin_name, done_name, value_name, next_name, free_name,
			-1, -1,
			0, -1, 0, -1, 0)

	free(begin_name)
	free(done_name)
	free(next_name)
	free(value_name)


int for_statement():
	if (accept(c"for") == 0): return 0

	int for_tab_level = tab_level

	mov_eax_int(0) /* default start value for the loop variable */
	char* infer_name = 0
	char* infer_name2 = 0
	lint_for_header = 1
	int type = variable_declaration()
	lint_for_header = 0
	if (type < 0):
		# No type: 'for name in ...' infers the loop variable's type
		# from the range/container (docs/projects/golf_ergonomics.md)
		infer_name = for_infer_name(c"type not found in for_statement loop variable")
		type = type_lookup(c"int")
	else if (type_stack_words(type) != 1): error(c"for loop variable must be a word-sized type")
	int for_var = ast_body_depth()

	# Optional second loop variable: for K key, V value in map
	int value_var = 0
	int value_type = -1
	if (accept(c",")):
		mov_eax_int(0)
		lint_for_header = 1
		value_type = variable_declaration()
		lint_for_header = 0
		if (value_type < 0):
			infer_name2 = for_infer_name(c"type not found in for_statement value variable")
			value_type = type_lookup(c"int")
		else if (type_stack_words(value_type) != 1):
			error(c"for loop value variable must be a word-sized type")
		value_var = ast_body_depth()

	expect(c"in")
	if (accept(c"range")):
		if (retained_parent >= 0): retained_record_at(retained_parent).name = retained_intern(c"for range")
		if (value_var != 0): error(c"range iteration takes one loop variable")
		# An inferred range loop variable is always int
		if (infer_name != 0): for_infer_declare(infer_name, for_var, type_lookup(c"int"))
		for_range_loop(for_var, for_tab_level)
	else:
		for_container_loop(for_var, for_tab_level, type, value_var, value_type, infer_name, infer_name2)

	return 1
