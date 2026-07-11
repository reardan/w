/*
for type-name identifier in range args :
	{ statement }

range forms (parentheses optional):
	range end
	range(end)
	range(start, end)
	range(start, end, step)

All range arguments are evaluated once, up front, into hidden stack slots.

for type-name identifier in expression :
	{ statement }

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


# Emit a call to fn_name(container) or, when cursor_slot is nonzero,
# fn_name(container, cursor). The operands live in hidden stack slots
# identified by their stack_pos anchors; the result is left in eax.
void for_iter_call(char* fn_name, int container_slot, int cursor_slot):
	sym_get_value(fn_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - container_slot) << word_size_log2)
	push_eax()
	stack_pos = stack_pos + 1
	if (cursor_slot != 0):
		mov_eax_esp_plus((stack_pos - cursor_slot) << word_size_log2)
		push_eax()
		stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - s - 1) << word_size_log2)
	call_eax()
	be_pop(stack_pos - s)
	stack_pos = s


void for_iter_error_prefix(char* container_name, char* fn_name):
	print_error(str_from_cstr(c"type '"))
	print_error(str_from_cstr(container_name))
	print_error(str_from_cstr(c"' is not iterable: "))
	print_error(str_from_cstr(fn_name))


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
	if (type_unqualified(param_type) != type_unqualified(container_type)):
		for_iter_error_prefix(container_name, fn_name)
		error(c" first parameter must match the iterable type")

	if (expected_args == 2):
		param_type = sym_param_type(symbol, 1)
		if (type_unqualified(param_type) != type_lookup(c"int")):
			for_iter_error_prefix(container_name, fn_name)
			error(c" second parameter must be int")


void for_iter_require_struct_pointer(int container_type):
	if (type_get_pointer_level(container_type) != 1):
		print_error(str_from_cstr(c"type '"))
		print_error_type(container_type)
		print_error(str_from_cstr(c"' is not iterable: "))
		error(c"expected a pointer to a container struct")
	int base_type = type_lookup_previous_pointer(container_type)
	if ((base_type < 0) | (type_num_args(base_type) == 0)):
		print_error(str_from_cstr(c"type '"))
		print_error_type(container_type)
		print_error(str_from_cstr(c"' is not iterable: "))
		error(c"expected a pointer to a container struct")


# The "in range" body of for_statement; "for", the loop variable and
# "in range" have already been consumed. for_var anchors the loop
# variable's stack slot.
void for_range_loop(int for_var, int for_tab_level):
	int has_parens = accept(c"(")
	int num_range_args = 1
	promote(expression())
	push_eax()
	stack_pos = stack_pos + 1
	while (accept(c",")):
		promote(expression())
		push_eax()
		stack_pos = stack_pos + 1
		num_range_args = num_range_args + 1
	if (has_parens):
		expect(c")")
	if (num_range_args > 3):
		error(c"range() takes 1-3 arguments")

	# With 2+ arguments the first one is the start: copy it into the loop var
	int end_slot = for_var + 1
	if (num_range_args >= 2):
		end_slot = for_var + 2
		mov_eax_esp_plus((stack_pos - (for_var + 1)) << word_size_log2)
		store_stack_var((stack_pos - for_var) << word_size_log2)

	# Enter a new loop context for break/continue
	int outer_break = loop_break_chain
	int outer_continue = loop_continue_chain
	int outer_stack = loop_stack_pos
	int outer_in_switch = break_in_switch
	# Exit region: the failed condition and 'break' land after the loop.
	# Loop region: the back edge re-tests the condition.
	loop_break_chain = be_ctrl_block()
	int h_top = be_ctrl_loop()
	loop_stack_pos = stack_pos
	break_in_switch = 0
	loop_depth = loop_depth + 1

	# condition: loop var < end
	mov_eax_esp_plus((stack_pos - for_var) << word_size_log2)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - end_slot) << word_size_log2)
	pop_ebx()
	alu_cmp_set(0x9c) /* setl: loop var < end */
	stack_pos = stack_pos - 1
	be_br_zero(loop_break_chain)

	# Continue region: 'continue' in the body runs the increment first
	loop_continue_chain = be_ctrl_block()

	/* ':' scoping + child scope statements */
	enclosing_tab_level = for_tab_level
	statement()

	/* increment: by 1, or by the step argument */
	be_ctrl_end(loop_continue_chain)
	if (num_range_args == 3):
		mov_eax_esp_plus((stack_pos - (for_var + 3)) << word_size_log2)
		add_dword_esp_plus_eax((stack_pos - for_var) << word_size_log2)
	else:
		inc_dword_esp_plus((stack_pos - for_var) << word_size_log2)

	/* jmp back to condition */
	be_br(h_top)
	be_ctrl_end(h_top)

	# break exits here; continue ran the increment first
	be_ctrl_end(loop_break_chain)

	loop_break_chain = outer_break
	loop_continue_chain = outer_continue
	loop_stack_pos = outer_stack
	break_in_switch = outer_in_switch
	loop_depth = loop_depth - 1

	# Discard the hidden range slots (the loop variable itself stays)
	be_pop(num_range_args)
	stack_pos = stack_pos - num_range_args


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
	if (cast(int, for_cleanups) == 0):
		return 0
	return for_cleanups.length


# Discards every record past the first n without touching the backing
# capacity (the defer_truncate trick — list[T]'s '.length' is read-only
# at the language level).
void for_cleanup_truncate(int n):
	if (cast(int, for_cleanups) == 0):
		return;
	__w_list* raw = cast(__w_list*, for_cleanups)
	raw.length = n


void for_cleanup_push(char* free_fn, int container_slot):
	if (cast(int, for_cleanups) == 0):
		for_cleanups = new list[for_cleanup_record]
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
	if (for_cleanup_count() == 0):
		return;
	push_eax()
	stack_pos = stack_pos + 1
	for_cleanup_emit_all()
	pop_eax()
	stack_pos = stack_pos - 1


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
void for_cursor_loop(int for_var, int for_tab_level, int loop_var_type,
		char* begin_fn, char* done_fn, char* value_fn, char* next_fn, char* free_fn,
		int element_type, int value_coerce_type,
		int value_var, int value_var_type, char* value2_fn, int value2_coerce_type):
	# hidden slot: the container pointer
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos

	# hidden slot: the cursor
	if (begin_fn != 0):
		for_iter_call(begin_fn, container_slot, 0)
	else:
		mov_eax_int(0)
	push_eax()
	stack_pos = stack_pos + 1
	int cursor_slot = stack_pos

	# Enter a new loop context for break/continue
	int outer_break = loop_break_chain
	int outer_continue = loop_continue_chain
	int outer_stack = loop_stack_pos
	int outer_in_switch = break_in_switch
	# Exit region: the done-check and 'break' land after the loop (where
	# free_fn releases the container). Loop region: the back edge re-tests.
	loop_break_chain = be_ctrl_block()
	int h_top = be_ctrl_loop()
	loop_stack_pos = stack_pos
	break_in_switch = 0
	loop_depth = loop_depth + 1

	# condition: exit once done_fn(container, cursor) is true, or once
	# the index cursor reaches the length word
	if (done_fn != 0):
		for_iter_call(done_fn, container_slot, cursor_slot)
		be_br_nonzero(loop_break_chain)
	else:
		mov_eax_esp_plus((stack_pos - cursor_slot) << word_size_log2)
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_esp_plus((stack_pos - container_slot) << word_size_log2)
		add_eax_int32(word_size)
		promote_eax()
		pop_ebx()
		stack_pos = stack_pos - 1
		alu_cmp_set(0x9c) /* setl: cursor < length */
		be_br_zero(loop_break_chain)

	# Continue region: 'continue' in the body advances the cursor first
	loop_continue_chain = be_ctrl_block()

	# loop var = value_fn(container, cursor), or the slice element at
	# data + cursor * element_size
	int extracted_type = value_coerce_type
	if (value_fn != 0):
		for_iter_call(value_fn, container_slot, cursor_slot)
	else:
		mov_eax_esp_plus((stack_pos - container_slot) << word_size_log2)
		promote_eax() /* the descriptor's data pointer */
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_esp_plus((stack_pos - cursor_slot) << word_size_log2)
		int element_size = type_get_size(element_type)
		if (element_size > 1):
			imul_eax_int32(element_size)
		pop_ebx()
		stack_pos = stack_pos - 1
		alu_add()
		extracted_type = promote(element_type)
	if (extracted_type != -1):
		coerce(loop_var_type, extracted_type)
	store_stack_var((stack_pos - for_var) << word_size_log2)

	if (value_var != 0):
		for_iter_call(value2_fn, container_slot, cursor_slot)
		coerce(value_var_type, value2_coerce_type)
		store_stack_var((stack_pos - value_var) << word_size_log2)

	# While the body parses, 'return' (grammar/statement.w) must know
	# about this loop's live resource so it can free it before leaving
	# the function; the record is popped once the body is done
	if (free_fn != 0):
		for_cleanup_push(free_fn, container_slot)

	/* ':' scoping + child scope statements */
	enclosing_tab_level = for_tab_level
	statement()

	if (free_fn != 0):
		for_cleanup_truncate(for_cleanup_count() - 1)

	# step (continue lands here): cursor = next_fn(container, cursor),
	# or an in-place index increment
	be_ctrl_end(loop_continue_chain)
	if (next_fn != 0):
		for_iter_call(next_fn, container_slot, cursor_slot)
		store_stack_var((stack_pos - cursor_slot) << word_size_log2)
	else:
		inc_dword_esp_plus((stack_pos - cursor_slot) << word_size_log2)

	/* jmp back to condition */
	be_br(h_top)
	be_ctrl_end(h_top)

	# Both exit edges (done and break) land here: release the container
	# before falling through
	be_ctrl_end(loop_break_chain)
	if (free_fn != 0):
		for_iter_call(free_fn, container_slot, 0)

	loop_break_chain = outer_break
	loop_continue_chain = outer_continue
	loop_stack_pos = outer_stack
	break_in_switch = outer_in_switch
	loop_depth = loop_depth - 1

	# Discard the hidden container and cursor slots (the loop variable stays)
	be_pop(2)
	stack_pos = stack_pos - 2


# value_var is 0 for the one-variable form; otherwise it anchors the
# stack slot of the value loop variable in "for K key, V value in map".
void for_hash_container_loop(int for_var, int for_tab_level, int loop_var_type, int container_type, int value_var, int value_var_type):
	int key_type = type_set_key_type(container_type)
	if (type_is_map(container_type)):
		key_type = type_map_key_type(container_type)
	if (types_compatible_with_expression(loop_var_type, key_type) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, key_type)

	char* value_call = c"__w_map_iter_value"
	int loop_value_type = -1
	if (value_var != 0):
		if (type_is_map(container_type) == 0):
			error(c"sets have no values: use one loop variable")
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
			value_var, value_var_type, value_call, loop_value_type)


void for_list_loop(int for_var, int for_tab_level, int loop_var_type, int container_type):
	int element_type = type_list_element_type(container_type)
	# Struct elements cannot fit in the word-sized loop variable, so the
	# loop yields each element's address instead: for point* p in l
	char* value_call = c"__w_list_iter_value"
	int loop_value_type = element_type
	if (type_num_args(element_type) > 0):
		value_call = c"__w_list_addr"
		loop_value_type = type_get_next_pointer(element_type)
	if (types_compatible_with_expression(loop_var_type, loop_value_type) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, loop_value_type)

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			c"__w_list_iter_begin", c"__w_list_iter_done", value_call, c"__w_list_iter_next", 0,
			-1, loop_value_type,
			0, -1, 0, -1)


# Iterate a slice (T[] descriptor): hidden slots hold the descriptor
# pointer and the running element index; each pass loads the element at
# data + index * element_size into the loop variable. Fixed arrays reach
# this path too, because promote() decays them to slice values.
void for_slice_loop(int for_var, int for_tab_level, int loop_var_type, int container_type):
	int element_type = type_unqualified(type_get_element_type(container_type))
	if (type_num_args(element_type) > 0):
		error(c"slice iteration requires scalar or pointer elements")
	if (types_compatible_with_expression(loop_var_type, element_type) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, element_type)

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			0, 0, 0, 0, 0,
			element_type, -1,
			0, -1, 0, -1)


void for_string_loop(int for_var, int for_tab_level, int loop_var_type):
	int decode_symbol = sym_lookup(c"utf8_decode")
	int next_symbol = sym_lookup(c"utf8_next")
	if ((decode_symbol < 0) | (next_symbol < 0)):
		error(c"string iteration requires import lib.utf8")
	if (types_compatible_with_expression(loop_var_type, type_lookup(c"int")) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, type_lookup(c"int"))

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			0, 0, c"utf8_decode", c"utf8_next", 0,
			-1, type_lookup(c"int"),
			0, -1, 0, -1)


# The "in <container>" body of for_statement; "for", the loop variable(s)
# and "in" have already been consumed. Emits the cursor-protocol loop
# described in the header comment. value_var is 0 unless a second loop
# variable was declared ("for K key, V value in map"), which only maps
# support.
void for_container_loop(int for_var, int for_tab_level, int loop_var_type, int value_var, int value_var_type):
	# The iterable is evaluated exactly once, before the body
	int container_type = promote(expression())
	container_type = type_unqualified(container_type)
	if (type_is_map(container_type) | type_is_set(container_type)):
		for_hash_container_loop(for_var, for_tab_level, loop_var_type, container_type, value_var, value_var_type)
		return;
	if (value_var != 0):
		error(c"only maps support two loop variables")
	if (type_is_list(container_type)):
		for_list_loop(for_var, for_tab_level, loop_var_type, container_type)
		return;
	if (type_is_slice(container_type)):
		for_slice_loop(for_var, for_tab_level, loop_var_type, container_type)
		return;
	if (type_is_string(container_type)):
		for_string_loop(for_var, for_tab_level, loop_var_type)
		return;
	for_iter_require_struct_pointer(container_type)

	char* container_name = type_get_name(container_type)
	# Generator iterables get gen_free on the loop's exit edges (normal
	# exit and break) so a broken-out-of loop does not leak the
	# suspended generator's stack. 'return' (and '?') bypass those edges;
	# they free through the for_cleanup registry above instead.
	char* free_name = 0
	if (strcmp(container_name, c"generator") == 0):
		free_name = c"gen_free"
	char* iter_prefix = strjoin(container_name, c"_iter_")
	char* begin_name = strjoin(iter_prefix, c"begin")
	char* done_name = strjoin(iter_prefix, c"done")
	char* next_name = strjoin(iter_prefix, c"next")
	char* value_name = strjoin(iter_prefix, c"value")
	free(iter_prefix)
	for_iter_require(container_name, begin_name, 1, container_type)
	for_iter_require(container_name, done_name, 2, container_type)
	for_iter_require(container_name, next_name, 2, container_type)
	for_iter_require(container_name, value_name, 2, container_type)

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			begin_name, done_name, value_name, next_name, free_name,
			-1, -1,
			0, -1, 0, -1)

	free(begin_name)
	free(done_name)
	free(next_name)
	free(value_name)


int for_statement():
	if (accept(c"for") == 0):
		return 0

	int for_tab_level = tab_level

	mov_eax_int(0) /* default start value for the loop variable */
	int type = variable_declaration()
	if (type < 0):
		error(c"type not found in for_statement loop variable")
	if (type_stack_words(type) != 1):
		error(c"for loop variable must be a word-sized type")
	int for_var = stack_pos

	# Optional second loop variable: for K key, V value in map
	int value_var = 0
	int value_type = -1
	if (accept(c",")):
		mov_eax_int(0)
		value_type = variable_declaration()
		if (value_type < 0):
			error(c"type not found in for_statement value variable")
		if (type_stack_words(value_type) != 1):
			error(c"for loop value variable must be a word-sized type")
		value_var = stack_pos

	expect(c"in")
	if (accept(c"range")):
		if (value_var != 0):
			error(c"range iteration takes one loop variable")
		for_range_loop(for_var, for_tab_level)
	else:
		for_container_loop(for_var, for_tab_level, type, value_var, value_type)

	return 1
