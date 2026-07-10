int expression_lhs_readonly

int extern_max_params();
int ffi_type_class(int type);
int ffi_push_promoted_float32();
void emit_ffi_call_inline(int n, char* classes, int ret_class, int got_vaddr);
int generator_call_suffix(int callee_sym, char* callee_name, int expected_args); /* defined in generator_decl */
int result_propagate_suffix(int type); /* defined in statement */
int result_propagate_struct(int type); /* defined in statement */


int buffer_element_type(int type):
	if (type_is_string(type)):
		return type_lookup(c"char")
	if (type_is_array(type) | type_is_slice(type)):
		return type_get_element_type(type)
	return type_lookup(c"char")


int buffer_result_type(int type):
	if (type_is_string(type)):
		return string_value_type
	return type_get_slice_value(buffer_element_type(type))


# Emit the bounds-trap block: call helper_name(ebx, eax) — the offending
# index in ebx, the length/limit it violated in eax (issue #228). Reached
# only on the trap path, so register state and the machine stack are
# disposable (the helper prints its one-line diagnostic and exits) and
# stack_pos stays untouched. The helpers live in structures/w_list.w, which
# every program auto-imports — but bounds-checked code can compile BEFORE
# the runtime defines them (the auto-imported runtime itself and anything
# it imports), so a missing symbol is declared as an undefined global here
# and the later definition patches the reference chain, like any forward
# reference.
void bounds_trap_call(char* helper_name):
	if (sym_lookup(helper_name) < 0):
		sym_declare_global(helper_name, 4, 2)
	push_ebx()
	push_eax()
	sym_get_value(helper_name)
	call_eax()


void buffer_bounds_check():
	if (bounds_mode == 0):
		return;
	# eax = index, stack top = the buffer descriptor. Load the length
	# first so the trap block can report both values; the descriptor is
	# valid whatever the index is.
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(word_size)
	add_eax_int32(word_size)
	promote_eax()
	pop_ebx()
	stack_pos = stack_pos - 1
	# ebx = index, eax = length: trap unless 0 <= index < length
	int negative_site = bounds_branch_ebx_negative()
	int in_bounds_site = bounds_skip_ebx_less_eax()
	be_branch_patch(negative_site, codepos)
	bounds_trap_call(c"__w_bounds_trap")
	be_branch_patch(in_bounds_site, codepos)
	mov_eax_ebx()


void buffer_range_bounds_check():
	if (bounds_mode == 0):
		return;
	# stack top before this helper: end, start, descriptor. Every failing
	# branch lands on one shared trap block with ebx = the offending bound
	# and eax = the limit it violated (the length, or the end bound for
	# the start <= end check).
	mov_eax_esp_plus(2 * word_size)
	add_eax_int32(word_size)
	promote_eax()
	mov_ebx_esp_plus(word_size)
	int start_negative_site = bounds_branch_ebx_negative()
	mov_ebx_esp_plus(0)
	int end_negative_site = bounds_branch_ebx_negative()
	int end_fits_site = bounds_branch_ebx_greater_eax()
	mov_eax_esp_plus(0)
	mov_ebx_esp_plus(word_size)
	int ordered_site = bounds_skip_ebx_less_equal_eax()
	be_branch_patch(start_negative_site, codepos)
	be_branch_patch(end_negative_site, codepos)
	be_branch_patch(end_fits_site, codepos)
	bounds_trap_call(c"__w_bounds_trap")
	be_branch_patch(ordered_site, codepos)


void buffer_push_range_descriptor(int base_type, int start_was_omitted):
	int element_type = buffer_element_type(base_type)
	int element_size = type_get_size(element_type)
	# stack top before this helper: end, start, descriptor
	sym_get_value(c"malloc")
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(2 * word_size)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(word_size)
	call_eax()
	be_pop(2)
	stack_pos = stack_pos - 2

	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(2 * word_size)
	mov_ebx_esp_plus(word_size)
	alu_sub()
	mov_ebx_esp()
	add_ebx_int32(word_size)
	store_ebx_word()

	mov_eax_esp_plus(2 * word_size)
	if (element_size > 1):
		imul_eax_int32(element_size)
	mov_ebx_esp_plus(3 * word_size)
	promote_ebx()
	alu_add()
	mov_ebx_esp()
	store_ebx_word()

	pop_eax()
	stack_pos = stack_pos - 1
	be_pop(3)
	stack_pos = stack_pos - 3


# Warn when a call argument's type conflicts with the callee's declared
# parameter type. callee is the callee's symbol table offset (< 0 when the
# callee is unknown, e.g. calls through pointers); arg_index is 0-based.
void check_call_argument(int callee, int signature_type, char* callee_name, int arg_index, int arg_type):
	int param_type = -1
	if (signature_type >= 0):
		param_type = type_function_param_type(signature_type, arg_index)
	else if (callee >= 0):
		param_type = sym_param_type(callee, arg_index)
	if (param_type < 0):
		return;
	if (types_compatible_with_expression(param_type, arg_type) == 0):
		diag_part(c"warning: function '")
		diag_part(callee_name)
		diag_part(c"' argument ")
		diag_part(itoa(arg_index + 1))
		diag_part(c" type mismatch: expected '")
		print_error_type(param_type)
		diag_part(c"', got '")
		print_error_type(arg_type)
		warning(c"'")


void init_array_field_descriptors(int type);
void coerce_cstr_to_string_call_arg();


void coerce_call_argument(int param_type, int arg_type):
	if (type_is_string(param_type) & type_is_char_pointer(arg_type)):
		coerce_cstr_to_string_call_arg()
	else:
		coerce(param_type, arg_type)


# Push a call argument onto the stack. Struct values are copied word by
# word, highest field offset first so field 0 lands at the lowest address
# (the layout parameter access expects); everything else is the one word
# in eax. Structs always take the copy path: even for a struct that fits
# in a single word (e.g. two float32 fields on x64), eax holds the
# struct's address (promote keeps structs as addresses), never its bytes.
#
# leaked_words counts stack words the argument's own expression left
# behind (a struct-returning call parks its return buffer on the stack).
# The callee addresses its parameters as one contiguous block, so the
# freshly pushed words slide down over the leak and the gap is popped.
void push_call_argument_compact(int arg_type, int leaked_words):
	int is_struct = 0
	int arg_words = 1
	if (type_num_args(arg_type) > 0):
		is_struct = 1
		arg_words = (type_get_size(arg_type) + word_size - 1) >> word_size_log2
	if (is_struct == 0):
		push_eax()
	else:
		int j = arg_words - 1
		while (j >= 0):
			push_eax_plus(j << word_size_log2)
			j = j - 1
	stack_pos = stack_pos + arg_words
	if (leaked_words > 0):
		# Slide highest word first: the regions overlap when the leak is
		# smaller than the argument.
		int i = arg_words - 1
		while (i >= 0):
			mov_eax_esp_plus(i << word_size_log2)
			store_stack_var((i + leaked_words) << word_size_log2)
			i = i - 1
		be_pop(leaked_words)
		stack_pos = stack_pos - leaked_words
	if (is_struct):
		if (type_has_array_field(arg_type)):
			lea_eax_esp_plus(0)
			init_array_field_descriptors(arg_type)


void push_call_argument(int arg_type):
	push_call_argument_compact(arg_type, 0)


# One fixed (declared) argument of a call: check it against the declared
# parameter type, coerce, and push it. An argument expression that is
# itself a struct-returning call leaves its return buffer on the stack;
# push_call_argument_compact slides the pushed argument down over that
# leak so the callee's parameter block stays contiguous.
void parse_fixed_call_argument(int callee_sym, int signature_type, char* callee_name, int arg_index):
	int entry_stack_pos = stack_pos
	int arg_type = expression()
	arg_type = promote(arg_type)
	check_call_argument(callee_sym, signature_type, callee_name, arg_index, arg_type)
	if ((callee_sym >= 0) | (signature_type >= 0)):
		int param_type = -1
		if (callee_sym >= 0):
			param_type = sym_param_type(callee_sym, arg_index)
		if (signature_type >= 0):
			param_type = type_function_param_type(signature_type, arg_index)
		if (param_type >= 0):
			coerce_call_argument(param_type, arg_type)
	push_call_argument_compact(arg_type, stack_pos - entry_stack_pos)


# One trailing argument of a call to a W variadic function: checked and
# coerced against the variadic parameter's element type, then pushed as a
# hidden stack slot of the argument buffer (element types are word-sized).
void parse_variadic_element_argument(char* callee_name, int element_type, int arg_index):
	int arg_type = expression()
	arg_type = promote(arg_type)
	if (types_compatible_with_expression(element_type, arg_type) == 0):
		diag_part(c"warning: function '")
		diag_part(callee_name)
		diag_part(c"' argument ")
		diag_part(itoa(arg_index + 1))
		diag_part(c" type mismatch: expected '")
		print_error_type(element_type)
		diag_part(c"', got '")
		print_error_type(arg_type)
		warning(c"'")
	coerce_call_argument(element_type, arg_type)
	push_eax()
	stack_pos = stack_pos + 1


# Parse arguments for a call whose callee address has already been pushed.
# passed_args lets callers account for hidden arguments, such as a method
# receiver. callee_type is 4 for direct functions, and a pointer type for
# indirect calls through function-pointer values. w_variadic_fixed is the
# number of fixed parameters of a W variadic callee, or -1 (see the
# variadic lowering notes in docs/projects/default_args_variadics.md).
int parse_call_suffix(int callee_type, int s, int expected_args, int callee_sym, int signature_type, char* callee_name, int declared_return, int passed_args, int has_return_buffer, int w_variadic_fixed):
	int variadic_element_type = -1
	int variadic_values = 0
	int fixed_words_end = -1
	if (w_variadic_fixed >= 0):
		variadic_element_type = type_get_element_type(type_unqualified(sym_param_type(callee_sym, w_variadic_fixed)))
	if (accept(c")") == 0):
		int more_args = 1
		while (more_args):
			if ((w_variadic_fixed >= 0) & (passed_args >= w_variadic_fixed)):
				if (variadic_values == 0):
					fixed_words_end = stack_pos
				parse_variadic_element_argument(callee_name, variadic_element_type, passed_args)
				variadic_values = variadic_values + 1
			else:
				parse_fixed_call_argument(callee_sym, signature_type, callee_name, passed_args)
			passed_args = passed_args + 1
			more_args = accept(c",")

		expect(c")")

	if (w_variadic_fixed >= 0):
		if (passed_args - variadic_values < w_variadic_fixed):
			diag_part(c"warning: function '")
			diag_part(callee_name)
			diag_part(c"' expects at least ")
			diag_part(itoa(w_variadic_fixed))
			diag_part(c" arguments, got ")
			warning(itoa(passed_args - variadic_values))
		if (fixed_words_end < 0):
			fixed_words_end = stack_pos
		# The variadic values were pushed left to right, so they sit in
		# reverse order in memory; reverse them in place so the first
		# value lands at the lowest address (ordinary slice layout).
		int i = 0
		while ((i << 1) < (variadic_values - 1)):
			mov_eax_esp_plus(i << word_size_log2)
			mov_ebx_esp_plus((variadic_values - 1 - i) << word_size_log2)
			store_stack_var((variadic_values - 1 - i) << word_size_log2)
			store_ebx_stack_var(i << word_size_log2)
			i = i + 1
		# Push the {data, length} slice descriptor just below the values
		mov_eax_int(variadic_values)
		push_eax()
		stack_pos = stack_pos + 1
		lea_eax_esp_plus(word_size)
		push_eax()
		stack_pos = stack_pos + 1
		int descriptor_slot = stack_pos
		# The values and descriptor sit between the fixed arguments and
		# the slice argument, but the callee addresses its parameters as
		# one contiguous block above the return address: re-push copies
		# of the fixed argument words so the block it sees is contiguous.
		int fixed_words = fixed_words_end - s - 1
		int j = 1
		while (j <= fixed_words):
			mov_eax_esp_plus((stack_pos - (s + 1 + j)) << word_size_log2)
			push_eax()
			stack_pos = stack_pos + 1
			j = j + 1
		# The variadic slice parameter: a pointer to the descriptor
		lea_eax_esp_plus((stack_pos - descriptor_slot) << word_size_log2)
		push_eax()
		stack_pos = stack_pos + 1

	# Missing trailing arguments whose parameters all carry defaults are
	# filled in with the recorded constants (direct calls only: indirect
	# calls have no symbol to read the defaults from).
	if ((w_variadic_fixed < 0) & (callee_sym >= 0) & (expected_args > passed_args)):
		int missing_all_defaulted = 1
		int check_index = passed_args
		while (check_index < expected_args):
			if (sym_param_has_default(callee_sym, check_index) == 0):
				missing_all_defaulted = 0
			check_index = check_index + 1
		if (missing_all_defaulted):
			while (passed_args < expected_args):
				mov_eax_int(sym_param_default(callee_sym, passed_args))
				int default_param_type = sym_param_type(callee_sym, passed_args)
				if (default_param_type >= 0):
					coerce(default_param_type, 3)
				push_call_argument(3)
				passed_args = passed_args + 1

	if ((expected_args >= 0) & (w_variadic_fixed < 0)):
		if (passed_args != expected_args):
			# Asm runtime stubs that record an arity (syscall, syscall7)
			# load their arguments from fixed stack slots, so a call with
			# the wrong argument count silently reads garbage words: reject
			# it outright instead of warning.
			int callee_is_stub = 0
			if (callee_sym >= 0):
				callee_is_stub = sym_is_asm_stub(callee_sym)
			if (callee_is_stub):
				diag_part(c"function '")
			else:
				diag_part(c"warning: function '")
			diag_part(callee_name)
			diag_part(c"' expects ")
			diag_part(itoa(expected_args))
			diag_part(c" arguments, got ")
			if (callee_is_stub):
				error(itoa(passed_args))
			else:
				warning(itoa(passed_args))
	if (callee_name != 0):
		free(callee_name)

	mov_eax_esp_plus((stack_pos - s - 1) << word_size_log2)

	# A function's address is its value; other callees hold a pointer
	if (callee_type != 4):
		promote(callee_type)
	call_eax()
	be_pop(stack_pos - s)
	stack_pos = s
	int type = 3  # call results are plain values
	last_call_return_type = declared_return
	last_call_end = codepos
	if (has_return_buffer):
		lea_eax_esp_plus(0)
		type = type_value(declared_return)
	else if (declared_return >= 0):
		type = type_value(declared_return)
	return type


# One argument of a direct call to a variadic C import. Fixed arguments
# follow the declared parameter types; the variadic tail gets the C
# default argument promotions (float32 widens to float64). Returns the
# argument's ABI class (see ffi_type_class).
int parse_variadic_call_argument(int callee_sym, char* callee_name, int passed_args, int fixed_args):
	int arg_type = expression()
	arg_type = promote(arg_type)
	if (type_num_args(type_real(arg_type)) > 0):
		error(c"struct arguments are not supported in variadic C calls")
	if (passed_args < fixed_args):
		check_call_argument(callee_sym, -1, callee_name, passed_args, arg_type)
		int param_type = sym_param_type(callee_sym, passed_args)
		int arg_class = type_float_kind(arg_type)
		if (param_type >= 0):
			coerce_call_argument(param_type, arg_type)
			arg_class = ffi_type_class(param_type)
		push_eax()
		stack_pos = stack_pos + 1
		return arg_class
	# Variadic tail: C default argument promotions
	if (type_get_kind(type_unqualified(arg_type)) == type_kind_slice_value()):
		# Arrays and slices decay unconditionally in a C variadic tail,
		# exactly like C: load the descriptor's first word so the callee
		# receives the data pointer, not the descriptor's address.
		promote_eax()
		push_eax()
		stack_pos = stack_pos + 1
		return 0
	int kind = type_float_kind(arg_type)
	if (kind == 1):
		# The promoted float64 spans two 32-bit stack words on x86
		stack_pos = stack_pos + ffi_push_promoted_float32()
		return 2
	push_eax()
	stack_pos = stack_pos + 1
	if (kind == 2):
		return 2
	return 0


# Direct call of a variadic C import: parse the arguments, then emit the
# platform C ABI conversion inline. No per-function stub can cover these
# calls because the float argument classes differ per call site (on x64
# they select xmm registers and set al).
int parse_variadic_call_suffix(int s, int callee_sym, char* callee_name, int declared_return, int fixed_args):
	char* arg_classes = malloc(extern_max_params())
	int passed_args = 0
	if (accept(c")") == 0):
		arg_classes[passed_args] = parse_variadic_call_argument(callee_sym, callee_name, passed_args, fixed_args)
		passed_args = passed_args + 1
		while (accept(c",")):
			if (passed_args >= extern_max_params()):
				error(c"too many arguments in variadic call")
			arg_classes[passed_args] = parse_variadic_call_argument(callee_sym, callee_name, passed_args, fixed_args)
			passed_args = passed_args + 1
		expect(c")")

	if (passed_args < fixed_args):
		diag_part(c"warning: function '")
		diag_part(callee_name)
		diag_part(c"' expects at least ")
		diag_part(itoa(fixed_args))
		diag_part(c" arguments, got ")
		warning(itoa(passed_args))
	if (callee_name != 0):
		free(callee_name)

	emit_ffi_call_inline(passed_args, arg_classes, ffi_type_class(declared_return), sym_got_vaddr(callee_sym))
	free(arg_classes)
	be_pop(stack_pos - s)
	stack_pos = s
	int type = 3  # call results are plain values
	last_call_return_type = declared_return
	last_call_end = codepos
	if (declared_return >= 0):
		type = type_value(declared_return)
	return type


/*
postfix-expr:
	primary-expr
	postfix-expr [ expression ]
	postfix-expr ( expression-list-opt )
	postfix-expr . identifier

 */
int postfix_expr():
	int type = primary_expr()
	# A pending generic instantiation from primary_expr: consume the
	# signature immediately so nested expressions cannot pick it up.
	int generic_sig = generic_pending_call_signature
	char* generic_callee = generic_pending_call_name
	generic_pending_call_signature = 0
	generic_pending_call_name = 0
	while (1):
		if (accept(c"[")):
			expression_lhs_readonly = 0
			if (type_is_map(type)):
				int map_type = type_unqualified(type)
				hash_index_base_stack = stack_pos
				type = promote(type)
				push_eax()
				stack_pos = stack_pos + 1
				hash_index_map_slot = stack_pos
				int want_key_type = type_map_key_type(map_type)
				int got_key_type = expression()
				got_key_type = promote(got_key_type)
				coerce(want_key_type, got_key_type)
				if (types_compatible_with_expression(want_key_type, got_key_type) == 0):
					warn_type_mismatch(c"map key", want_key_type, got_key_type)
				push_eax()
				stack_pos = stack_pos + 1
				hash_index_key_slot = stack_pos
				expect(c"]")
				hash_index_map_type = map_type
				hash_index_pending = 1
				type = type_map_value_type(map_type)
			else if (type_is_list(type)):
				type = list_index_suffix(type)
			else if (type_is_buffer(type)):
				type = promote(type)
				if (accept(c":")):
					push_eax()
					stack_pos = stack_pos + 1
					mov_eax_int(0)
					push_eax()
					stack_pos = stack_pos + 1
					if (accept(c"]")):
						mov_eax_esp_plus(word_size)
						add_eax_int32(word_size)
						promote_eax()
					else:
						promote(expression())
						expect(c"]")
					push_eax()
					stack_pos = stack_pos + 1
					buffer_range_bounds_check()
					buffer_push_range_descriptor(type, 1)
					type = buffer_result_type(type)
					expression_lhs_readonly = 1
				else:
					push_eax()
					stack_pos = stack_pos + 1
					int element_type = buffer_element_type(type)
					int element_size = type_get_size(element_type)
					promote(expression())
					if (accept(c":")):
						push_eax()
						stack_pos = stack_pos + 1
						if (accept(c"]")):
							mov_eax_esp_plus(word_size)
							add_eax_int32(word_size)
							promote_eax()
						else:
							promote(expression())
							expect(c"]")
						push_eax()
						stack_pos = stack_pos + 1
						buffer_range_bounds_check()
						buffer_push_range_descriptor(type, 0)
						type = buffer_result_type(type)
						expression_lhs_readonly = 1
					else:
						buffer_bounds_check()
						if (element_size > 1):
							imul_eax_int32(element_size)
						pop_ebx()
						promote_ebx()
						alu_add()
						stack_pos = stack_pos - 1
						expect(c"]")
						type = element_type
						expression_lhs_readonly = 0
			else:
				binary1(type) /* load the base pointer and push it */
				# The element type drives both index scaling and the load width
				int element_type = 2 /* char: byte elements by default */
				if (type_get_pointer_level(type) > 0):
					int previous_type = type_lookup_previous_pointer(type)
					if (previous_type >= 0):
						element_type = previous_type
				int element_size = type_get_size(element_type)
				promote(expression())
				if (element_size > 1):
					imul_eax_int32(element_size)
				pop_ebx()
				alu_add()
				stack_pos = stack_pos - 1
				expect(c"]")
				type = element_type
				expression_lhs_readonly = 0

		else if (accept(c"(")):
			# Remember the callee's declared arity now; parsing the arguments
			# below overwrites last_identifier.
			int expected_args = -1
			int callee_sym = -1
			int signature_type = -1
			char* callee_name = 0
			int declared_return = -1
			int variadic_fixed = -1
			int w_variadic_fixed = -1
			if (type == 4):
				if (generic_sig > 0):
					# A not-yet-compiled generic instantiation: the parsed
					# signature drives the argument checks and return type
					signature_type = generic_sig
					declared_return = type_function_return(generic_sig)
					expected_args = type_function_param_count(generic_sig)
					callee_name = strclone(generic_callee)
					generic_sig = 0
				else:
					int callee = sym_lookup(last_identifier)
					if (callee >= 0):
						declared_return = load_int(table + callee + 6)
						# asm runtime stubs are declared with the 'function'
						# pseudo-type: their call results are untyped words
						if (declared_return == 4):
							declared_return = -1
						expected_args = sym_num_args(callee)
						if (expected_args >= 0):
							callee_sym = callee
							callee_name = strclone(last_identifier)
							variadic_fixed = sym_variadic_fixed_args(callee)
							w_variadic_fixed = sym_w_variadic_fixed_args(callee)
			else if (type_get_pointer_level(type) > 0):
				int base_type = type_lookup_previous_pointer(type)
				if ((base_type >= 0) & (type_is_function_signature(base_type))):
					signature_type = base_type
					declared_return = type_function_return(base_type)
					expected_args = type_function_param_count(base_type)
					callee_name = strclone(c"function pointer")

			int callee_is_generator = 0
			if (callee_sym >= 0):
				callee_is_generator = sym_is_generator(callee_sym)

			if (callee_is_generator):
				# Calling a generator creates the generator object
				# instead of running the body; the result is generator*
				type = generator_call_suffix(callee_sym, callee_name, expected_args)
			else if (variadic_fixed >= 0):
				# Direct call of a variadic C import: the callee is reached
				# through its GOT slot, so its address in eax is not pushed.
				type = parse_variadic_call_suffix(stack_pos, callee_sym, callee_name, declared_return, variadic_fixed)
			else:
				int has_return_buffer = 0
				int s = stack_pos
				if (declared_return >= 0):
					if (type_num_args(declared_return) > 0):
						int words = (type_get_size(declared_return) + word_size - 1) >> word_size_log2
						int j = 0
						while (j < words):
							push_eax()
							j = j + 1
						stack_pos = stack_pos + words
						s = stack_pos
						has_return_buffer = 1
				push_eax()
				stack_pos = stack_pos + 1
				if (has_return_buffer):
					lea_eax_esp_plus(word_size)
					push_eax()
					stack_pos = stack_pos + 1
				type = parse_call_suffix(type, s, expected_args, callee_sym, signature_type, callee_name, declared_return, 0, has_return_buffer, w_variadic_fixed)

		else if (accept(c".")):
			expression_lhs_readonly = 0
			if (type_is_map(type) | type_is_set(type)):
				if (peek(c"length")):
					get_token()
					type = promote(type)
					add_eax_int32(word_size)
					type = type_lookup(c"int")
					expression_lhs_readonly = 1
				else if (peek(c"remove")):
					get_token()
					type = hash_remove_suffix(type)
				else if (peek(c"add") & type_is_set(type)):
					get_token()
					type = hash_set_add_suffix(type)
				else if (peek(c"add") & type_is_map(type)):
					get_token()
					type = hash_map_add_suffix(type)
				else if (peek(c"keys")):
					get_token()
					type = hash_keys_suffix(type)
				else if (peek(c"values") & type_is_map(type)):
					get_token()
					type = hash_values_suffix(type)
				else if (peek(c"get") & type_is_map(type)):
					get_token()
					type = hash_get_suffix(type)
				else:
					print2(c"hash container field '")
					print2(token)
					error(c"' not found")
			else if (type_is_list(type)):
				if (peek(c"length")):
					get_token()
					type = promote(type)
					add_eax_int32(word_size)
					type = type_lookup(c"int")
					expression_lhs_readonly = 1
				else if (peek(c"push")):
					get_token()
					type = list_push_suffix(type)
				else if (peek(c"pop")):
					get_token()
					type = list_pop_suffix(type)
				else if (peek(c"insert")):
					get_token()
					type = list_insert_suffix(type)
				else if (peek(c"remove")):
					get_token()
					type = list_remove_suffix(type)
				else if (peek(c"clear")):
					get_token()
					type = list_clear_suffix(type)
				else if (peek(c"sort")):
					get_token()
					type = list_sort_suffix(type)
				else if (peek(c"sort_by")):
					get_token()
					type = list_sort_by_suffix(type)
				else if (peek(c"map")):
					get_token()
					type = list_map_suffix(type)
				else if (peek(c"filter")):
					get_token()
					type = list_filter_suffix(type)
				else if (peek(c"reduce")):
					get_token()
					type = list_reduce_suffix(type)
				else if (peek(c"sum")):
					get_token()
					type = list_aggregate_suffix(type, c"__w_list_sum", c"sum", type_lookup(c"int"))
				else if (peek(c"min")):
					get_token()
					type = list_aggregate_suffix(type, c"__w_list_min", c"min", type_list_element_type(type_unqualified(type)))
				else if (peek(c"max")):
					get_token()
					type = list_aggregate_suffix(type, c"__w_list_max", c"max", type_list_element_type(type_unqualified(type)))
				else if (peek(c"reverse")):
					get_token()
					type = list_reverse_suffix(type)
				else if (peek(c"count")):
					get_token()
					type = list_scan_suffix(type, c"__w_list_count", c"list count")
				else if (peek(c"index")):
					get_token()
					type = list_scan_suffix(type, c"__w_list_index", c"list index")
				else:
					diag_part(c"list field '")
					diag_part(token)
					error(c"' not found")
			else if (type_is_buffer(type)):
				if (peek(c"length")):
					get_token()
					type = promote(type)
					add_eax_int32(word_size)
					type = type_lookup(c"int")
					expression_lhs_readonly = 1
				else if (peek(c"data")):
					get_token()
					type = promote(type)
					int element_type = buffer_element_type(type)
					type = type_get_next_pointer(element_type)
					expression_lhs_readonly = 1
				else:
					print2(c"buffer field '")
					print2(token)
					error(c"' not found")
			else:
				# A pending map read whose value is a struct must emit the
				# get call now so eax holds the stored struct's address.
				type = hash_finalize_pending_read_if_needed(type)
				int receiver_struct_value_words = 0
				int receiver_was_value = type_is_value(type)
				if (receiver_was_value):
					int receiver_real_type = type_real(type)
					if (type_num_args(receiver_real_type) > 0):
						receiver_struct_value_words = (type_get_size(receiver_real_type) + word_size - 1) >> word_size_log2
					type = promote(type)

				# Struct pointers are loaded first so fields work through them
				if (type_get_pointer_level(type) > 0):
					int element = type_lookup_previous_pointer(type)
					if (element >= 0):
						if (type_num_args(element) > 0):
							if (receiver_was_value == 0):
								promote(type)
							type = element

				# For structures, find offset of field name
				int num_args = type_num_args(type)
				if (num_args > 0):
					char* member_name = strclone(token)
					int arg = type_get_arg(type, member_name)
					get_token()

					if (arg >= 0):
						# Return right side field type instead of struct pointer
						add_eax_int32(type_get_field_offset(type, member_name))

						# Use child type insted of struct type:
						type = type_get_field_type(type, member_name)
						if (type < 0):
							print_int0(c"child field not found: '", type)
							error(c"")
						if (verbosity >= 1):
							print2(itoa(line_number))
							print_string0(c": using child type: ", type_get_name(type))
							print_int(c": ", type)
						if (receiver_struct_value_words > 0):
							if (type_num_args(type) == 0):
								type = promote(type)
								be_pop(receiver_struct_value_words)
								stack_pos = stack_pos - receiver_struct_value_words
								type = type_value(type)
					else if (peek(c"(")):
						char* prefix = strjoin(type_get_name(type), c"_")
						char* method_symbol = strjoin(prefix, member_name)
						free(prefix)
						int callee = sym_lookup(method_symbol)
						if (callee < 0):
							print_error(c"struct method '")
							print_error(type_get_name(type))
							print_error(c".")
							print_error(member_name)
							print_error(c"' not found; expected function '")
							print_error(method_symbol)
							error(c"'")

						int expected_args = sym_num_args(callee)
						int callee_sym = -1
						int signature_type = -1
						char* callee_name = 0
						int w_variadic_fixed = -1
						if (expected_args >= 0):
							callee_sym = callee
							callee_name = strclone(method_symbol)
							w_variadic_fixed = sym_w_variadic_fixed_args(callee)
						int declared_return = load_int(table + callee + 6)

						int has_return_buffer = 0
						int return_words = 0
						if (declared_return >= 0):
							if (type_num_args(declared_return) > 0):
								return_words = (type_get_size(declared_return) + word_size - 1) >> word_size_log2
								int j = 0
								while (j < return_words):
									push_eax()
									j = j + 1
								stack_pos = stack_pos + return_words
								has_return_buffer = 1

						# Save the receiver address while resolving the method
						# symbol, then push it as the hidden first source argument.
						push_eax()
						stack_pos = stack_pos + 1
						sym_get_value(method_symbol)
						int s = stack_pos
						push_eax()
						stack_pos = stack_pos + 1
						if (has_return_buffer):
							lea_eax_esp_plus(2 << word_size_log2)
							push_eax()
							stack_pos = stack_pos + 1
						if (has_return_buffer):
							mov_eax_esp_plus(2 << word_size_log2)
						else:
							mov_eax_esp_plus(1 << word_size_log2)

						int receiver_type = type_lookup_next_pointer(type)
						check_call_argument(callee_sym, signature_type, callee_name, 0, receiver_type)
						if (callee_sym >= 0):
							int param_type = sym_param_type(callee_sym, 0)
							if (param_type >= 0):
								coerce(param_type, receiver_type)
						push_call_argument(receiver_type)

						accept(c"(")
						type = parse_call_suffix(4, s, expected_args, callee_sym, signature_type, callee_name, declared_return, 1, has_return_buffer, w_variadic_fixed)
						be_pop(1)
						stack_pos = stack_pos - 1
						if (has_return_buffer):
							lea_eax_esp_plus(0)
							type = type_value(declared_return)
						free(method_symbol)
					else:
						print2(c"struct field '")
						print2(member_name)
						error(c"' not found")
					free(member_name)

				else:
					# cc500 heritage: '.member' on a non-struct expression
					# used to be silently ignored, so a typo'd field or a
					# method chained onto a non-struct result (for example
					# an int- or void-returning call) compiled into a call
					# through a garbage receiver and crashed at runtime.
					diag_part(c"member '")
					diag_part(token)
					diag_part(c"' on non-struct type '")
					print_error_type(type)
					error(c"'")

		# expr? : unwrap a wresult[T]* or propagate the error to the
		# caller (see result_propagate_suffix in grammar/statement.w).
		# Only a wresult operand claims the '?' here; any other type
		# leaves it for the conditional expression layer
		# (grammar/conditional_expr.w).
		else if (peek(c"?") & (result_propagate_struct(type_real(type)) >= 0)):
			get_token()
			expression_lhs_readonly = 0
			type = result_propagate_suffix(type)

		else:
			return type
