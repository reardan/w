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
	print_error("type '")
	print_error(container_name)
	print_error("' is not iterable: ")
	print_error(fn_name)


void for_iter_require(char* container_name, char* fn_name, int expected_args, int container_type):
	int symbol = sym_lookup(fn_name)
	if (symbol < 0):
		for_iter_error_prefix(container_name, fn_name)
		error(" not found")
	if (load_int(table + symbol + 10) != 2):
		for_iter_error_prefix(container_name, fn_name)
		error(" is not a function")
	if (sym_num_args(symbol) != expected_args):
		for_iter_error_prefix(container_name, fn_name)
		error(" has wrong arity")

	int return_type = load_int(table + symbol + 6)
	if ((type_get_size(return_type) == 0) | (type_stack_words(return_type) != 1)):
		for_iter_error_prefix(container_name, fn_name)
		error(" must return a word-sized value")

	int param_type = sym_param_type(symbol, 0)
	if (type_unqualified(param_type) != type_unqualified(container_type)):
		for_iter_error_prefix(container_name, fn_name)
		error(" first parameter must match the iterable type")

	if (expected_args == 2):
		param_type = sym_param_type(symbol, 1)
		if (type_unqualified(param_type) != type_lookup("int")):
			for_iter_error_prefix(container_name, fn_name)
			error(" second parameter must be int")


void for_iter_require_struct_pointer(int container_type):
	if (type_get_pointer_level(container_type) != 1):
		print_error("type '")
		print_error_type(container_type)
		print_error("' is not iterable: ")
		error("expected a pointer to a container struct")
	int base_type = type_lookup_previous_pointer(container_type)
	if ((base_type < 0) | (type_num_args(base_type) == 0)):
		print_error("type '")
		print_error_type(container_type)
		print_error("' is not iterable: ")
		error("expected a pointer to a container struct")


# The "in range" body of for_statement; "for", the loop variable and
# "in range" have already been consumed. for_var anchors the loop
# variable's stack slot.
void for_range_loop(int for_var, int for_tab_level):
	int p1
	int p2

	int has_parens = accept("(")
	int num_range_args = 1
	promote(expression())
	push_eax()
	stack_pos = stack_pos + 1
	while (accept(",")):
		promote(expression())
		push_eax()
		stack_pos = stack_pos + 1
		num_range_args = num_range_args + 1
	if (has_parens):
		expect(")")
	if (num_range_args > 3):
		error("range() takes 1-3 arguments")

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
	loop_break_chain = 0
	loop_continue_chain = 0
	loop_stack_pos = stack_pos
	loop_depth = loop_depth + 1

	# condition: loop var < end
	p1 = codepos
	mov_eax_esp_plus((stack_pos - for_var) << word_size_log2)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - end_slot) << word_size_log2)
	pop_ebx()
	alu_cmp_set(0x9c) /* setl: loop var < end */
	stack_pos = stack_pos - 1
	jmp_zero_int32(1337010)
	p2 = codepos

	/* ':' scoping + child scope statements */
	enclosing_tab_level = for_tab_level
	statement()

	/* increment: by 1, or by the step argument */
	int increment_target = codepos
	if (num_range_args == 3):
		mov_eax_esp_plus((stack_pos - (for_var + 3)) << word_size_log2)
		add_dword_esp_plus_eax((stack_pos - for_var) << word_size_log2)
	else:
		inc_dword_esp_plus((stack_pos - for_var) << word_size_log2)

	/* jmp back to condition */
	jmp_int32(1337011)
	save_int32(code + codepos - 4, p1 - codepos)

	/* save jmp to here if condition failed */
	save_int32(code + p2 - 4, codepos - p2)

	# break exits here; continue runs the increment first
	patch_jump_chain(loop_break_chain, codepos)
	patch_jump_chain(loop_continue_chain, increment_target)

	loop_break_chain = outer_break
	loop_continue_chain = outer_continue
	loop_stack_pos = outer_stack
	loop_depth = loop_depth - 1

	# Discard the hidden range slots (the loop variable itself stays)
	be_pop(num_range_args)
	stack_pos = stack_pos - num_range_args


void for_hash_container_loop(int for_var, int for_tab_level, int loop_var_type, int container_type):
	int p1
	int p2
	int key_type = type_set_key_type(container_type)
	if (type_is_map(container_type)):
		key_type = type_map_key_type(container_type)
	if (types_compatible_with_expression(loop_var_type, key_type) == 0):
		warn_type_mismatch("for loop variable", loop_var_type, key_type)

	# hidden slot: the container pointer
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos

	# hidden slot: cursor = iter_begin(container)
	for_iter_call("__w_map_iter_begin", container_slot, 0)
	push_eax()
	stack_pos = stack_pos + 1
	int cursor_slot = stack_pos

	int outer_break = loop_break_chain
	int outer_continue = loop_continue_chain
	int outer_stack = loop_stack_pos
	loop_break_chain = 0
	loop_continue_chain = 0
	loop_stack_pos = stack_pos
	loop_depth = loop_depth + 1

	p1 = codepos
	for_iter_call("__w_map_iter_done", container_slot, cursor_slot)
	jmp_nonzero_int32(1337014)
	p2 = codepos

	for_iter_call("__w_map_iter_key", container_slot, cursor_slot)
	coerce(loop_var_type, key_type)
	store_stack_var((stack_pos - for_var) << word_size_log2)

	enclosing_tab_level = for_tab_level
	statement()

	int increment_target = codepos
	for_iter_call("__w_map_iter_next", container_slot, cursor_slot)
	store_stack_var((stack_pos - cursor_slot) << word_size_log2)

	jmp_int32(1337015)
	save_int32(code + codepos - 4, p1 - codepos)

	save_int32(code + p2 - 4, codepos - p2)
	patch_jump_chain(loop_break_chain, codepos)
	patch_jump_chain(loop_continue_chain, increment_target)

	loop_break_chain = outer_break
	loop_continue_chain = outer_continue
	loop_stack_pos = outer_stack
	loop_depth = loop_depth - 1

	be_pop(2)
	stack_pos = stack_pos - 2


# The "in <container>" body of for_statement; "for", the loop variable
# and "in" have already been consumed. Emits the cursor-protocol loop
# described in the header comment.
void for_container_loop(int for_var, int for_tab_level, int loop_var_type):
	int p1
	int p2

	# The iterable is evaluated exactly once, before the body
	int container_type = promote(expression())
	container_type = type_unqualified(container_type)
	if (type_is_map(container_type) | type_is_set(container_type)):
		for_hash_container_loop(for_var, for_tab_level, loop_var_type, container_type)
		return;
	for_iter_require_struct_pointer(container_type)

	char* container_name = type_get_name(container_type)
	char* iter_prefix = strjoin(container_name, "_iter_")
	char* begin_name = strjoin(iter_prefix, "begin")
	char* done_name = strjoin(iter_prefix, "done")
	char* next_name = strjoin(iter_prefix, "next")
	char* value_name = strjoin(iter_prefix, "value")
	free(iter_prefix)
	for_iter_require(container_name, begin_name, 1, container_type)
	for_iter_require(container_name, done_name, 2, container_type)
	for_iter_require(container_name, next_name, 2, container_type)
	for_iter_require(container_name, value_name, 2, container_type)

	# hidden slot: the container pointer
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos

	# hidden slot: cursor = T_iter_begin(container)
	for_iter_call(begin_name, container_slot, 0)
	push_eax()
	stack_pos = stack_pos + 1
	int cursor_slot = stack_pos

	# Enter a new loop context for break/continue
	int outer_break = loop_break_chain
	int outer_continue = loop_continue_chain
	int outer_stack = loop_stack_pos
	loop_break_chain = 0
	loop_continue_chain = 0
	loop_stack_pos = stack_pos
	loop_depth = loop_depth + 1

	# condition: exit once T_iter_done(container, cursor) is true
	p1 = codepos
	for_iter_call(done_name, container_slot, cursor_slot)
	jmp_nonzero_int32(1337012)
	p2 = codepos

	# loop var = T_iter_value(container, cursor)
	for_iter_call(value_name, container_slot, cursor_slot)
	store_stack_var((stack_pos - for_var) << word_size_log2)

	/* ':' scoping + child scope statements */
	enclosing_tab_level = for_tab_level
	statement()

	# step (continue lands here): cursor = T_iter_next(container, cursor)
	int increment_target = codepos
	for_iter_call(next_name, container_slot, cursor_slot)
	store_stack_var((stack_pos - cursor_slot) << word_size_log2)

	/* jmp back to condition */
	jmp_int32(1337013)
	save_int32(code + codepos - 4, p1 - codepos)

	/* save jmp to here once the iterator is done */
	save_int32(code + p2 - 4, codepos - p2)

	# break exits here; continue advances the cursor first
	patch_jump_chain(loop_break_chain, codepos)
	patch_jump_chain(loop_continue_chain, increment_target)

	loop_break_chain = outer_break
	loop_continue_chain = outer_continue
	loop_stack_pos = outer_stack
	loop_depth = loop_depth - 1

	# Discard the hidden container and cursor slots (the loop variable stays)
	be_pop(2)
	stack_pos = stack_pos - 2

	free(begin_name)
	free(done_name)
	free(next_name)
	free(value_name)


int for_statement():
	if (accept("for") == 0):
		return 0

	int for_tab_level = tab_level

	mov_eax_int(0) /* default start value for the loop variable */
	int type = variable_declaration()
	if (type < 0):
		error("type not found in for_statement loop variable")
	if (type_stack_words(type) != 1):
		error("for loop variable must be a word-sized type")
	int for_var = stack_pos

	expect("in")
	if (accept("range")):
		for_range_loop(for_var, for_tab_level)
	else:
		for_container_loop(for_var, for_tab_level, type)

	return 1
