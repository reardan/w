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


# Load the iterator function's address into eax: directly for an
# ordinary symbol, through the generic instantiation's backpatch chain
# (grammar/generic.w) when the container is generic and the
# instantiation's body has not been compiled yet. The instantiation was
# interned by for_iter_generic_require, so the lookup cannot miss.
void for_iter_callee(char* fn_name):
	if (sym_lookup(fn_name) >= 0):
		sym_get_value(fn_name)
		return;
	int inst = generic_inst_lookup(fn_name)
	if (inst < 0):
		diag_part(fn_name)
		error(c" is not defined")
	generic_inst_emit_callee(inst)


# Emit a call to fn_name(container) or, when cursor_slot is nonzero,
# fn_name(container, cursor). The operands live in hidden stack slots
# identified by their stack_pos anchors; the result is left in eax.
void for_iter_call(char* fn_name, int container_slot, int cursor_slot):
	for_iter_callee(fn_name)
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
	if (type_unqualified(param_type) != type_unqualified(container_type)):
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
(for_iter_callee). One type parameter only: a multi-parameter mangled
suffix cannot be split back into its type arguments unambiguously.
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
	while (arg_name[n]):
		n = n + 1
	int stars = 0
	while ((n > 0) && (arg_name[n - 1] == '*')):
		n = n - 1
		arg_name[n] = 0
		stars = stars + 1
	int arg_type = type_lookup(arg_name)
	free(arg_name)
	if (arg_type < 0):
		return -1
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
	if (generic_def_param_count(def) != 1):
		for_iter_error_prefix(container_name, fn_base)
		error(c" must take exactly one type parameter")
	int arg_type = for_iter_generic_arg(container_name, dollar)
	if (arg_type < 0):
		for_iter_error_prefix(container_name, fn_base)
		error(c" has an unknown type argument")
	char* with_sep = strjoin(fn_base, c"$")
	char* mangled = strjoin(with_sep, container_name + dollar + 1)
	free(with_sep)
	free(fn_base)
	if (sym_lookup(mangled) >= 0):
		# already compiled (a later loop after the drain, e.g. the REPL):
		# the ordinary symbol checks apply
		for_iter_require(container_name, mangled, expected_args, container_type)
		return mangled
	char* args = malloc(generic_max_params() * __word_size__)
	save_ptr(args, arg_type)
	int inst = generic_inst_intern(def, cast(int, args), 1, strclone(mangled))
	int sig = generic_inst_signature(inst)
	if (type_function_param_count(sig) != expected_args):
		for_iter_error_prefix(container_name, mangled)
		error(c" has wrong arity")
	int return_type = type_function_return(sig)
	if ((type_get_size(return_type) == 0) | (type_stack_words(return_type) != 1)):
		for_iter_error_prefix(container_name, mangled)
		error(c" must return a word-sized value")
	if (type_unqualified(type_function_param_type(sig, 0)) != type_unqualified(container_type)):
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
	char* container_name = type_get_name(container_type)
	int dollar = for_iter_generic_split(container_name)
	char* base = strclone(container_name)
	base[dollar] = 0
	char* fn_base = strjoin(base, c"_iter_value")
	free(base)
	int def = generic_def_lookup(fn_base, 0)
	if ((def < 0) || (generic_def_param_count(def) != 1)):
		free(fn_base)
		return type_lookup(c"int")
	int arg_type = for_iter_generic_arg(container_name, dollar)
	if (arg_type < 0):
		free(fn_base)
		return type_lookup(c"int")
	char* with_sep = strjoin(fn_base, c"$")
	char* mangled = strjoin(with_sep, container_name + dollar + 1)
	free(with_sep)
	free(fn_base)
	int symbol = sym_lookup(mangled)
	if (symbol >= 0):
		free(mangled)
		if (load_int(table + symbol + 10) == 2):
			return load_int(table + symbol + 6)
		return type_lookup(c"int")
	char* args = malloc(generic_max_params() * __word_size__)
	save_ptr(args, arg_type)
	int inst = generic_inst_intern(def, cast(int, args), 1, mangled)
	return type_unqualified(type_function_return(generic_inst_signature(inst)))


void for_iter_require_struct_pointer(int container_type):
	if (type_get_pointer_level(container_type) != 1):
		diag_part(c"type '")
		print_error_type(container_type)
		diag_part(c"' is not iterable: ")
		error(c"expected a pointer to a container struct")
	int base_type = type_lookup_previous_pointer(container_type)
	if ((base_type < 0) | (type_num_args(base_type) == 0)):
		diag_part(c"type '")
		print_error_type(container_type)
		diag_part(c"' is not iterable: ")
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
	be_br_zero_discard(loop_break_chain)

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
		be_br_nonzero_discard(loop_break_chain)
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
		be_br_zero_discard(loop_break_chain)

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
				value_var, value_var_type, value_call, loop_value_type)
		return;

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
	if ((decode_symbol < 0) || (next_symbol < 0)):
		error(c"string iteration requires import lib.utf8")
	if (types_compatible_with_expression(loop_var_type, type_lookup(c"int")) == 0):
		warn_type_mismatch(c"for loop variable", loop_var_type, type_lookup(c"int"))

	for_cursor_loop(for_var, for_tab_level, loop_var_type,
			0, 0, c"utf8_decode", c"utf8_next", 0,
			-1, type_lookup(c"int"),
			0, -1, 0, -1)


# Inferred loop variable, first half: 'for name in ...' with the type
# omitted (docs/projects/golf_ergonomics.md). Consume the identifier and
# reserve the variable's stack slot (eax holds the 0 default), but defer
# the symbol declaration until the range/container fixes its type -- the
# ':=' precedent, so the iterable expression cannot reference the new
# name. Returns the cloned name; msg is the non-identifier diagnostic.
char* for_infer_name(char* msg):
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		error(msg)
	char* name = strclone(token)
	get_token()
	push_eax()
	stack_pos = stack_pos + 1
	return name


# Inferred loop variable, second half: declare the deferred name with
# the type the container fixed, anchored to the slot for_infer_name
# reserved (slot is the stack_pos anchor recorded after the push, so the
# declared value is slot - 1, matching variable_declaration's layout).
void for_infer_declare(char* name, int slot, int type):
	pointer_indirection = 0
	sym_declare(name, type, 'L', slot - 1, 1)
	free(name)


# Loop-variable type for 'for name in container' with the type omitted:
# maps and sets yield their key type, lists their element type (struct
# elements as element pointers, matching for_list_loop), slices their
# element type, strings int code points. A custom cursor-protocol
# container yields its value accessor's declared return type when one
# is in scope; otherwise int (for_iter_require reports the real error).
int for_infer_var_type(int container_type):
	if (type_is_map(container_type)):
		return type_map_key_type(container_type)
	if (type_is_set(container_type)):
		return type_set_key_type(container_type)
	if (type_is_list(container_type)):
		int element_type = type_list_element_type(container_type)
		if (type_num_args(element_type) > 0):
			return type_get_next_pointer(element_type)
		return element_type
	if (type_is_slice(container_type)):
		return type_unqualified(type_get_element_type(container_type))
	if (type_is_string(container_type)):
		return type_lookup(c"int")
	if (type_get_pointer_level(container_type) == 1):
		if (for_iter_generic_split(type_get_name(container_type)) >= 0):
			return for_iter_generic_value_type(container_type)
		char* value_name = strjoin(type_get_name(container_type), c"_iter_value")
		int symbol = sym_lookup(value_name)
		free(value_name)
		if (symbol >= 0):
			if (load_int(table + symbol + 10) == 2):
				return load_int(table + symbol + 6)
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
	int container_type = promote(expression())
	container_type = type_unqualified(container_type)
	if (is_enumerate):
		expect(c")")
		if (type_is_list(container_type) == 0):
			diag_part(c"enumerate requires a list, got '")
			print_error_type(container_type)
			error(c"'")
		if (value_var == 0):
			error(c"enumerate requires two loop variables: for i, x in enumerate(l)")
	if (infer_name != 0):
		loop_var_type = for_infer_var_type(container_type)
		# Two-variable list iteration binds the element index first
		if (type_is_list(container_type) && (value_var != 0)):
			loop_var_type = type_lookup(c"int")
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
		value_var_type = inferred_value_type
		for_infer_declare(infer_name2, value_var, inferred_value_type)
	if (type_is_map(container_type) | type_is_set(container_type)):
		for_hash_container_loop(for_var, for_tab_level, loop_var_type, container_type, value_var, value_var_type)
		return;
	if (type_is_list(container_type)):
		for_list_loop(for_var, for_tab_level, loop_var_type, container_type, value_var, value_var_type)
		return;
	if (value_var != 0):
		error(c"only maps and lists support two loop variables")
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
	char* infer_name = 0
	char* infer_name2 = 0
	int type = variable_declaration()
	if (type < 0):
		# No type: 'for name in ...' infers the loop variable's type
		# from the range/container (docs/projects/golf_ergonomics.md)
		infer_name = for_infer_name(c"type not found in for_statement loop variable")
		type = type_lookup(c"int")
	else if (type_stack_words(type) != 1):
		error(c"for loop variable must be a word-sized type")
	int for_var = stack_pos

	# Optional second loop variable: for K key, V value in map
	int value_var = 0
	int value_type = -1
	if (accept(c",")):
		mov_eax_int(0)
		value_type = variable_declaration()
		if (value_type < 0):
			infer_name2 = for_infer_name(c"type not found in for_statement value variable")
			value_type = type_lookup(c"int")
		else if (type_stack_words(value_type) != 1):
			error(c"for loop value variable must be a word-sized type")
		value_var = stack_pos

	expect(c"in")
	if (accept(c"range")):
		if (value_var != 0):
			error(c"range iteration takes one loop variable")
		# An inferred range loop variable is always int
		if (infer_name != 0):
			for_infer_declare(infer_name, for_var, type_lookup(c"int"))
		for_range_loop(for_var, for_tab_level)
	else:
		for_container_loop(for_var, for_tab_level, type, value_var, value_type, infer_name, infer_name2)

	return 1
