/*
Compiler lowering for the built-in typed list[T] container.

new list[T], list[T]{...} literals, l[index], the push/pop pseudo-methods
and .length lower to the __w_list_* runtime helpers in structures/w_list.w
(auto-imported into every program). l[index] calls __w_list_addr and
leaves the element's ADDRESS in eax, so element reads and writes flow
through the normal lvalue machinery with the element type's own width; no
pending-lvalue state is needed, unlike map indexing.

The call emission reuses the callee-first stack layout helpers from
grammar/hash_builtin.w (hash_push_stack_slot, hash_call_finish).
*/
int expression();
int inferred_storage_type(char* name, int got); /* defined in variable_declaration */
void for_iter_call(char* fn_name, int container_slot, int cursor_slot); /* defined in for_statement */
int parse_call_suffix(int callee_type, int s, int expected_args, int callee_sym, int signature_type, char* callee_name, int declared_return, int passed_args, int has_return_buffer, int w_variadic_fixed); /* defined in postfix_expr */
void check_call_argument(int callee, int signature_type, char* callee_name, int arg_index, int arg_type); /* defined in postfix_expr */
void push_call_argument(int arg_type); /* defined in postfix_expr */


int list_literal_type


# Bytes per element slot. Struct slots round up to a word multiple so W's
# word-granular struct copies stay inside the element's storage.
int list_element_slot_size(int element_type):
	if (type_num_args(element_type) > 0):
		return type_stack_words(element_type) << word_size_log2
	return type_get_size(element_type)


void list_emit_new_container(int type):
	sym_get_value(c"__w_list_new")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(list_element_slot_size(type_list_element_type(type)))
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)


# l[start:end] / l[start:] / l[:end] / l[:]: the ':' has been consumed
# and the start value sits at start_slot (0 when the start was omitted).
# Parses the optional end bound and lowers to
# __w_list_slice(list, start, end, has_end), which copies the selected
# range into a NEW list of the same element type (Python-style copy
# semantics; a view would dangle when the source reallocs on push).
# Negative bounds count from the end; the runtime traps when the
# normalized range is not 0 <= start <= end <= length.
int list_slice_suffix(int element_type, int base_stack, int list_slot, int start_slot):
	int has_end = 0
	if (peek(c"]")):
		# l[start:]: the omitted end means the list's length
		mov_eax_int(0)
	else:
		promote(expression())
		has_end = 1
	expect(c"]")
	push_eax()
	stack_pos = stack_pos + 1
	int end_slot = stack_pos
	sym_get_value(c"__w_list_slice")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(start_slot)
	hash_push_stack_slot(end_slot)
	mov_eax_int(has_end)
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_get_list(type_canonical(element_type)))


# l[index]: '[' has been consumed and the list lvalue or value is in eax.
# Evaluates the index, calls __w_list_addr(list, index) and returns the
# element type with the element's address in eax (a normal lvalue). A ':'
# in place of (or after) the index hands off to list_slice_suffix.
int list_index_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	# promote before anchoring base_stack: finishing a pending map read
	# (e.g. table[key][0]) pops the read's hidden stack slots
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	if (accept(c":")):
		# l[:end] / l[:]: the omitted start is 0
		mov_eax_int(0)
		push_eax()
		stack_pos = stack_pos + 1
		return list_slice_suffix(element_type, base_stack, list_slot, stack_pos)
	promote(expression())
	push_eax()
	stack_pos = stack_pos + 1
	int index_slot = stack_pos
	if (accept(c":")):
		return list_slice_suffix(element_type, base_stack, list_slot, index_slot)
	expect(c"]")
	sym_get_value(c"__w_list_addr")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(index_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return element_type


# Element comparison kind for sort/count/index: 1 signed word compare,
# 2 char* contents (the map/set key rule). Aggregates, strings, floats
# and containers have no built-in ordering and are rejected.
int list_scalar_kind(int element_type, char* what):
	int t = type_unqualified(element_type)
	if ((type_num_args(t) > 0) | type_is_string(t) | (type_float_kind(t) != 0) |
			type_is_map(t) | type_is_set(t) | type_is_list(t) |
			type_is_array(t) | type_is_slice(t)):
		diag_part(c"list ")
		diag_part(what)
		diag_part(c" requires int-like or char* elements, got '")
		print_error_type(element_type)
		error(c"'")
	return hash_key_kind_for_type(t)


# map/filter/reduce pass elements to the callback as word values, so
# aggregate elements (copied by address) are out.
void list_require_scalar_elements(int element_type, char* what):
	int t = type_unqualified(element_type)
	if ((type_num_args(t) > 0) | type_is_string(t) |
			type_is_array(t) | type_is_slice(t)):
		diag_part(c"list ")
		diag_part(what)
		diag_part(c" requires scalar elements, got '")
		print_error_type(element_type)
		error(c"'")


# Callback arguments must be a named function (type 4) or a value
# holding a function address (fn alias pointers included).
void list_check_callback(int got, char* what):
	if (got == 4):
		return;
	if (type_get_pointer_level(type_real(got)) > 0):
		return;
	diag_part(c"list ")
	diag_part(what)
	diag_part(c" expects a function, got '")
	print_error_type(got)
	error(c"'")


# Declared return type of the callback just parsed (type in got, its
# address in eax): a named function's symbol-table return type, or the
# fn signature's return type for typed pointers. Unknown callees (plain
# int*/asm stubs) default to int.
int list_callback_return_type(int got):
	if (got == 4):
		int callee = sym_lookup(last_identifier)
		if (callee >= 0):
			int declared = load_int(table + callee + 6)
			if ((declared >= 0) && (declared != 4)):
				return type_unqualified(declared)
		return type_lookup(c"int")
	int sig = type_function_pointer_signature(type_real(got))
	if (sig >= 0):
		return type_unqualified(type_function_return(sig))
	return type_lookup(c"int")


/*
Container pseudo-method engine (list, map and set).

Every table-driven method lowers to helper(container, args..., [extra])
with the callee-first stack layout: the container is parked in a hidden
slot, each argument is parsed into its own slot, then the helper is
called with the slots re-pushed. list_method/hash_method map a method
name to one cm_call row; only the shapes that genuinely differ (index
and slice, m.get, m.add, map defaults) keep hand-written lowerings.

Argument kinds (arg1/arg2):
  0 none
  1 value: coerced to 'want', mismatches warned as ctx; a struct source
    for struct elements selects bytes_helper
  2 index: any promoted expression
  3 callback: a named function or fn pointer, checked as ctx
  4 map callback: 3, plus the result element type fixes the returned
    list and the trailing slot-size word
  5 reduce init: the result type is the init's storage type
Result kinds: 0 void, 1 element value, 2 list of element, 3 int, 4 bool.
extra is a trailing constant word (sort kind, slot size), -1 for none.
*/

# Out-parameters of the kind-4/5 argument parsers, read back by cm_call
# right after the argument that set them (before any later argument
# can clobber them through a nested method call).
int cm_out_extra
int cm_out_result


# Parses one argument of kind 'kind' and parks it in a new stack slot;
# returns the slot's anchor.
int cm_arg(int kind, int want, char* ctx):
	int got = promote(expression())
	if (kind == 1):
		coerce(want, got)
		if (types_compatible_with_expression(want, got) == 0):
			warn_type_mismatch(ctx, want, got)
		cm_out_extra = type_num_args(type_real(got)) > 0
	else if (kind == 3):
		list_check_callback(got, ctx)
	else if (kind == 4):
		list_check_callback(got, ctx)
		int result_element = list_callback_return_type(got)
		list_require_scalar_elements(result_element, c"map result")
		if (type_get_size(result_element) == 0):
			error(c"list map callback must return a value")
		cm_out_extra = list_element_slot_size(result_element)
		cm_out_result = type_value(type_get_list(type_canonical(result_element)))
	else if (kind == 5):
		int result_type = inferred_storage_type(c"reduce init", got)
		if (type_num_args(result_type) > 0):
			error(c"list reduce init must be a scalar value")
		cm_out_result = type_value(result_type)
	push_eax()
	stack_pos = stack_pos + 1
	return stack_pos


int cm_result_type(int result, int element_type):
	if (result == 1):
		return type_value(element_type)
	if (result == 2):
		return type_value(type_get_list(type_canonical(element_type)))
	if (result == 3):
		return type_value(type_lookup(c"int"))
	if (result == 4):
		return type_value(bool_type)
	return type_value(type_lookup(c"void"))


# The method name has been consumed and the container (value or
# lvalue) is in eax. 'want' is the element (or key) type: the kind-1
# coercion target and the result-kind base.
int cm_call(int type, char* helper, char* bytes_helper, int want, char* ctx, int arg1, int arg2, int extra, int result):
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos
	# kind-4/5 arguments fix the result type themselves (value types are
	# negative, so the flag is separate)
	int result_type = 0
	int has_result_type = 0
	expect(c"(")
	int slot1 = 0
	int slot2 = 0
	if (arg1 != 0):
		slot1 = cm_arg(arg1, want, ctx)
		if ((arg1 == 1) && (bytes_helper != 0) && (type_num_args(want) > 0) && cm_out_extra):
			helper = bytes_helper
		if (arg1 == 4):
			extra = cm_out_extra
			result_type = cm_out_result
			has_result_type = 1
	if (arg2 != 0):
		expect(c",")
		slot2 = cm_arg(arg2, want, ctx)
		if ((arg2 == 1) && (bytes_helper != 0) && (type_num_args(want) > 0) && cm_out_extra):
			helper = bytes_helper
		if (arg2 == 5):
			result_type = cm_out_result
			has_result_type = 1
	expect(c")")
	sym_get_value(helper)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	if (slot1 != 0):
		hash_push_stack_slot(slot1)
	if (slot2 != 0):
		hash_push_stack_slot(slot2)
	if (extra >= 0):
		mov_eax_int(extra)
		push_eax()
		stack_pos = stack_pos + 1
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	if (has_result_type):
		return result_type
	return cm_result_type(result, want)


/*
it-expressions: l.map(it * 2), l.filter(it % 2 == 0), l.sort_by(it.age)
...: a method argument that mentions the identifier 'it' is an
expression evaluated once per element, compiled as an INLINE loop in
the current function, so the enclosing function's locals stay visible
and no closure is needed. 'it' is a hidden local bound to each element
(struct elements as element pointers, the for-in rule); outside these
arguments 'it' stays an ordinary identifier, and a user variable named
'it' in scope keeps the argument an ordinary value/callback.

Every form shares one loop: the expression's values are collected into
a "keys" list (created lazily, since its element type is only known
once the expression has been parsed), then a runtime helper combines
the source list with its keys:
  map(e)                  the keys themselves: list of e's type
  filter(p)               elements whose key is nonzero
  count(p) / any(p) / all(p) / index(p)   __w_list_truth modes 0-3
  sum(e) / min(e) / max(e)                aggregate of the keys
  sort_by(k) / sorted_by(k)               stable sort by key (int-like
                                          or char* keys, like sort)
  min_by(k) / max_by(k)   the first element with the smallest/largest
                          key, as an lvalue like l[i]
Every element is evaluated (no short-circuit in any/all/index).
*/
int list_it_active


int list_it_mode(char* name):
	char* names = c"map filter count any all index sum min max sort_by sorted_by min_by max_by "
	int mode = 0
	int i = 0
	while (names[i] != 0):
		int j = 0
		while ((name[j] != 0) && (names[i + j] == name[j])):
			j = j + 1
		if ((name[j] == 0) && (names[i + j] == ' ')):
			return mode
		while (names[i] != ' '):
			i = i + 1
		i = i + 1
		mode = mode + 1
	return 0 - 1


# Whether the argument list after the current method name mentions 'it'
# as a free name: a token scan to the matching ')' that rewinds with the
# ':=' lookahead trick. Member names ('x.it') do not count; f-string
# embedded expressions do.
int list_it_argument():
	if ((nextc != '(') || (list_it_mode(token) < 0)):
		return 0
	int sym = sym_lookup(c"it")
	if ((sym >= 0) && (sym != list_it_active)):
		return 0
	int serial = token_serial
	char* save = generic_reparse_save()
	char* open = malloc(64)
	int depth = 0
	int found = 0
	int after_dot = 0
	get_token()
	while ((found == 0) && (token[0] != 0) && (depth < 64)):
		get_token()
		int n = strlen(token)
		if (peek(c")") | peek(c"]") | peek(c"}")):
			if (depth == 0):
				break
			depth = depth - 1
			if (open[depth] == 'T'):
				get_token_template_chunk()
				n = strlen(token)
				if ((n > 0) && (token[n - 1] == '{')):
					open[depth] = 'T'
					depth = depth + 1
		else if (peek(c"(") | peek(c"[") | peek(c"{")):
			open[depth] = token[0]
			depth = depth + 1
		else if (peek(c"it") && (after_dot == 0)):
			found = 1
		else if ((token[0] == 'f') && (token[1] == '"') && (token[n - 1] == '{')):
			open[depth] = 'T'
			depth = depth + 1
		after_dot = peek(c".")
	free(open)
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	token_serial = serial
	return found


# helper(slot_a[, slot_b][, constant]) with the result in eax; absent
# slots are 0, an absent constant is -1.
void list_it_call(char* helper, int slot_a, int slot_b, int constant):
	sym_get_value(helper)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(slot_a)
	if (slot_b != 0):
		hash_push_stack_slot(slot_b)
	if (constant >= 0):
		mov_eax_int(constant)
		push_eax()
		stack_pos = stack_pos + 1
	hash_call_finish(s)


void list_it_reject(char* method, char* what, int got):
	diag_part(c"list ")
	diag_part(method)
	diag_part(what)
	print_error_type(got)
	error(c"'")


# The method name is the current token and list_it_argument() said its
# argument is an it-expression.
int list_it_method(int type):
	char* method = strclone(token)
	int mode = list_it_mode(method)
	get_token()
	int element_type = type_list_element_type(type_unqualified(type))
	int it_type = element_type
	char* value_fn = c"__w_list_iter_value"
	if (type_num_args(type_unqualified(element_type)) > 0):
		it_type = type_get_next_pointer(element_type)
		value_fn = c"__w_list_addr"
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	mov_eax_int(0)
	push_eax()
	stack_pos = stack_pos + 1
	int cursor_slot = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int keys_slot = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int it_slot = stack_pos
	int table_mark = table_pos
	int outer_active = list_it_active
	pointer_indirection = 0
	sym_declare(c"it", it_type, 'L', it_slot - 1, 1)
	list_it_active = table_pos - symbol_data_size()
	expect(c"(")

	# for each element: it = element; keys.push(expression)
	int exit = be_ctrl_block()
	int top = be_ctrl_loop()
	mov_eax_esp_plus((stack_pos - cursor_slot) << word_size_log2)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus((stack_pos - list_slot) << word_size_log2)
	add_eax_int32(word_size)
	promote_eax()
	pop_ebx()
	stack_pos = stack_pos - 1
	alu_cmp_set(0x9c) /* setl: cursor < length */
	be_br_zero_discard(exit)
	for_iter_call(value_fn, list_slot, cursor_slot)
	store_stack_var((stack_pos - it_slot) << word_size_log2)
	int got = promote(expression())
	int key_type = inferred_storage_type(method, got)
	if ((type_num_args(key_type) > 0) | type_is_array(key_type) | type_is_slice(key_type)):
		list_it_reject(method, c" expression must be a scalar value, got '", got)
	int key_size = list_element_slot_size(key_type)
	push_eax()
	stack_pos = stack_pos + 1
	list_it_call(c"__w_list_push_lazy", keys_slot, stack_pos, key_size)
	store_stack_var((stack_pos - keys_slot) << word_size_log2)
	be_pop(1)
	stack_pos = stack_pos - 1
	inc_dword_esp_plus((stack_pos - cursor_slot) << word_size_log2)
	be_br(top)
	be_ctrl_end(top)
	be_ctrl_end(exit)
	expect(c")")
	table_pos = table_mark
	list_it_active = outer_active
	list_it_call(c"__w_list_or_new", keys_slot, 0, key_size)
	store_stack_var((stack_pos - keys_slot) << word_size_log2)

	int result = type_value(type_get_list(type_canonical(key_type)))
	if ((mode >= 1) && (mode <= 5)):
		# filter / count / any / all / index test the keys' truthiness
		if ((type_float_kind(key_type) != 0) | type_is_string(key_type) | type_is_map(key_type) | type_is_set(key_type) | type_is_list(key_type)):
			list_it_reject(method, c" condition must be an int-like or pointer value, got '", got)
		if (mode == 1):
			list_it_call(c"__w_list_filter_keys", list_slot, keys_slot, -1)
			result = type_value(type_get_list(type_canonical(element_type)))
		else:
			list_it_call(c"__w_list_truth", keys_slot, 0, mode - 2)
			result = type_value(type_lookup(c"int"))
			if ((mode == 3) || (mode == 4)):
				result = type_value(bool_type)
	else if (mode >= 6):
		char* what = strclone(method)
		if (mode >= 9):
			free(what)
			what = strjoin(method, c" key")
		int kind = list_scalar_kind(key_type, what)
		free(what)
		if ((mode <= 8) && (kind != 1)):
			diag_part(c"list ")
			diag_part(method)
			error(c" requires int-like elements")
		if (mode <= 8):
			char* helper = strjoin(c"__w_list_", method)
			list_it_call(helper, keys_slot, 0, -1)
			free(helper)
			result = type_value(type_lookup(c"int"))
			if (mode != 6):
				result = type_value(key_type)
		else if (mode == 9):
			list_it_call(c"__w_list_sort_keys", list_slot, keys_slot, kind)
			result = type_value(type_lookup(c"void"))
		else if (mode == 10):
			list_it_call(c"__w_list_sorted_keys", list_slot, keys_slot, kind)
			result = type_value(type_get_list(type_canonical(element_type)))
		else:
			list_it_call(c"__w_list_best_key", keys_slot, 0, kind | ((mode - 11) << 2))
			push_eax()
			stack_pos = stack_pos + 1
			list_it_call(c"__w_list_addr", list_slot, stack_pos, -1)
			result = element_type
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	free(method)
	return result


/*
Uniform call syntax (golf ergonomics wave 5): x.f(args) calls the free
function f(x, args) when nothing else claims the member -- a struct's
field or T_f method, a built-in list/map/set pseudo-method -- so it is
only reached where '.f(' used to be an error and never changes the
meaning of a program that compiled before. f must be a plain function
(not a local fn pointer, generator or C variadic) with at least one
parameter; a struct receiver additionally needs f's first parameter
to be a pointer to the struct (the receiver is passed by address, like
the method sugar's &p).
*/
int ufcs_callee(char* name):
	int callee = sym_lookup(name)
	if (callee < 0):
		return 0 - 1
	if ((table[callee + 1] == 'L') || (table[callee + 1] == 'A')):
		return 0 - 1
	if ((sym_num_args(callee) < 1) || sym_is_generator(callee) || (sym_variadic_fixed_args(callee) >= 0)):
		return 0 - 1
	return callee


int ufcs_struct_receiver(char* name, int struct_type):
	int callee = ufcs_callee(name)
	if (callee < 0):
		return 0
	int param = sym_param_type(callee, 0)
	if ((param < 0) || (type_get_pointer_level(param) != 1)):
		return 0
	return type_canonical(type_lookup_previous_pointer(param)) == type_canonical(struct_type)


# The function name is the current token with '(' next; the receiver
# (value or lvalue) is in eax. Emits f(receiver, args...) exactly like
# the struct method sugar with the receiver as the hidden first argument.
int ufcs_call(int type):
	type = promote(type)
	char* name = strclone(token)
	get_token()
	int callee = sym_lookup(name)
	int expected_args = sym_num_args(callee)
	int declared_return = load_int(table + callee + 6)
	int has_return_buffer = 0
	if (declared_return >= 0):
		if (type_num_args(declared_return) > 0):
			int words = (type_get_size(declared_return) + word_size - 1) >> word_size_log2
			int j = 0
			while (j < words):
				push_eax()
				j = j + 1
			stack_pos = stack_pos + words
			has_return_buffer = 1
	push_eax()
	stack_pos = stack_pos + 1
	sym_get_value(name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	if (has_return_buffer):
		lea_eax_esp_plus(2 << word_size_log2)
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_esp_plus(2 << word_size_log2)
	else:
		mov_eax_esp_plus(1 << word_size_log2)
	check_call_argument(callee, 0 - 1, name, 0, type)
	int param_type = sym_param_type(callee, 0)
	if (param_type >= 0):
		coerce(param_type, type)
	push_call_argument(type)
	expect(c"(")
	int result = parse_call_suffix(4, s, expected_args, callee, 0 - 1, name, declared_return, 1, has_return_buffer, sym_w_variadic_fixed_args(callee))
	be_pop(1)
	stack_pos = stack_pos - 1
	if (has_return_buffer):
		lea_eax_esp_plus(0)
		result = type_value(declared_return)
	return result


# list[T] pseudo-methods; the method name is the current token.
#   push/insert/remove/pop/clear/free   stack and deque operations
#   sort/sorted, sort_by/sorted_by      in place / new list; int-like
#                                       elements compare as signed words,
#                                       char* by contents, comparators
#                                       return negative/zero/positive
#   map/filter/reduce                   callbacks over scalar elements
#   sum/min/max                         int-like aggregations
#   reverse, reversed                   in place / new list, any element
#   count(x), index(x)                  index is -1 when absent
# Struct elements travel by address: push/insert copy bytes, pop and
# the comparators see element addresses.
int list_method(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	int aggregate = type_num_args(type_unqualified(element_type)) > 0
	if (list_it_argument()):
		return list_it_method(type)
	if (accept(c"push")):
		return cm_call(type, c"__w_list_push", c"__w_list_push_bytes", element_type, c"list push", 1, 0, -1, 0)
	if (accept(c"pop")):
		if (type_num_args(element_type) > 0):
			return cm_call(type, c"__w_list_pop_addr", 0, element_type, 0, 0, 0, -1, 1)
		return cm_call(type, c"__w_list_pop", 0, element_type, 0, 0, 0, -1, 1)
	if (accept(c"insert")):
		return cm_call(type, c"__w_list_insert", c"__w_list_insert_bytes", element_type, c"list insert", 2, 1, -1, 0)
	if (accept(c"remove")):
		return cm_call(type, c"__w_list_remove", 0, element_type, 0, 2, 0, -1, 0)
	if (accept(c"clear")):
		return cm_call(type, c"__w_list_clear", 0, element_type, 0, 0, 0, -1, 0)
	if (accept(c"free")):
		# Element POINTERS are not chased (lib/container.w's list_free[T]
		# contract); use after free is caller error
		return cm_call(type, c"__w_list_free", 0, element_type, 0, 0, 0, -1, 0)
	if (accept(c"sort")):
		return cm_call(type, c"__w_list_sort", 0, element_type, 0, 0, 0, list_scalar_kind(element_type, c"sort"), 0)
	if (accept(c"sorted")):
		return cm_call(type, c"__w_list_sorted", 0, element_type, 0, 0, 0, list_scalar_kind(element_type, c"sorted"), 2)
	if (accept(c"sort_by")):
		if (aggregate):
			return cm_call(type, c"__w_list_sort_by_addr", 0, element_type, c"sort_by", 3, 0, -1, 0)
		return cm_call(type, c"__w_list_sort_by", 0, element_type, c"sort_by", 3, 0, -1, 0)
	if (accept(c"sorted_by")):
		if (aggregate):
			return cm_call(type, c"__w_list_sorted_by_addr", 0, element_type, c"sorted_by", 3, 0, -1, 2)
		return cm_call(type, c"__w_list_sorted_by", 0, element_type, c"sorted_by", 3, 0, -1, 2)
	if (accept(c"map")):
		list_require_scalar_elements(element_type, c"map")
		return cm_call(type, c"__w_list_map", 0, element_type, c"map", 4, 0, -1, 0)
	if (accept(c"filter")):
		list_require_scalar_elements(element_type, c"filter")
		return cm_call(type, c"__w_list_filter", 0, element_type, c"filter", 3, 0, -1, 2)
	if (accept(c"reduce")):
		list_require_scalar_elements(element_type, c"reduce")
		return cm_call(type, c"__w_list_reduce", 0, element_type, c"reduce", 3, 5, -1, 0)
	if (peek(c"sum") | peek(c"min") | peek(c"max")):
		char* what = strclone(token)
		get_token()
		if (list_scalar_kind(element_type, what) != 1):
			diag_part(c"list ")
			diag_part(what)
			error(c" requires int-like elements")
		char* helper = strjoin(c"__w_list_", what)
		int result = 1
		if (what[1] == 'u'):
			result = 3
		int got = cm_call(type, helper, 0, element_type, 0, 0, 0, -1, result)
		free(helper)
		free(what)
		return got
	if (accept(c"reverse")):
		return cm_call(type, c"__w_list_reverse", 0, element_type, 0, 0, 0, -1, 0)
	if (accept(c"reversed")):
		return cm_call(type, c"__w_list_reversed", 0, element_type, 0, 0, 0, -1, 2)
	if (accept(c"count")):
		return cm_call(type, c"__w_list_count", 0, element_type, c"list count", 1, 0, list_scalar_kind(element_type, c"list count"), 3)
	if (accept(c"index")):
		return cm_call(type, c"__w_list_index", 0, element_type, c"list index", 1, 0, list_scalar_kind(element_type, c"list index"), 3)
	if ((nextc == '(') && (ufcs_callee(token) >= 0)):
		return ufcs_call(type)
	diag_part(c"list field '")
	diag_part(token)
	error(c"' not found")
	return 0


void list_literal_parse_entry(int container_type, int container_slot):
	int base_stack = stack_pos
	int element_type = type_list_element_type(container_type)
	int got_type = expression()
	got_type = promote(got_type)
	coerce(element_type, got_type)
	if (types_compatible_with_expression(element_type, got_type) == 0):
		warn_type_mismatch(c"list literal element", element_type, got_type)
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	if ((type_num_args(element_type) > 0) & (type_num_args(type_real(got_type)) > 0)):
		sym_get_value(c"__w_list_push_bytes")
	else:
		sym_get_value(c"__w_list_push")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


int list_typed_literal():
	if ((peek(c"list") & (nextc == '[')) == 0):
		return 0
	int container_type = type_name()
	expect(c"{")
	list_emit_new_container(container_type)
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos
	if (peek(c"}") == 0):
		list_literal_parse_entry(container_type, container_slot)
		while (accept(c",")):
			if (peek(c"}")):
				break
			list_literal_parse_entry(container_type, container_slot)
	if (peek(c"}") == 0):
		error(c"'}' expected in list literal")
	pop_eax()
	stack_pos = stack_pos - 1
	list_literal_type = type_value(container_type)
	return 1
