char *last_identifier

# Declared return type of the most recently compiled call (-1 when the
# callee is unknown) and the code position right after its cleanup. Only
# the REPL reads these, to avoid echoing a void call's garbage result.
# Declared here (before grammar/generic.w) because both the ordinary
# call paths in postfix_expr.w and the inferred generic call path in
# generic.w record them.
int last_call_return_type
int last_call_end

# Nonzero while the controlling expression of an if or while statement is
# being parsed. bitwise_and_expr/bitwise_or_expr use it to warn when '&'
# or '|' joins two bool operands in a condition, where the non-short-
# circuiting evaluation is a recurring footgun. Declared here (before the
# expression ladder) so both the setters and the readers see it.
int condition_context

# Nonzero while the operand of a cast(T, ...) is being parsed. cast() is
# the documented escape hatch for conversions the checks would reject;
# int_literal() extends that to the bit-31 literal warning, so
# cast(int, 0xffffffff) spells "this bit pattern is intentional".
int cast_context


void var_coerce(int want, int got);


# Print a type's name followed by its pointer stars, e.g. "char**"
void print_error_type(int type_index):
	type_index = type_real(type_index)
	diag_part(type_get_name(type_index))
	for int i in range(type_get_pointer_level(type_index)):
		diag_part(c"*")


# Warn that 'got' does not convert to 'want'; context names the construct
# (assignment, initialization, return, ...)
void warn_type_mismatch(char* context, int want, int got):
	diag_part(c"warning: ")
	diag_part(context)
	diag_part(c" type mismatch: expected '")
	print_error_type(want)
	diag_part(c"', got '")
	print_error_type(got)
	warning(c"'")


int function_signature_matches_symbol(int signature_type, char* function_name):
	int symbol = sym_lookup(function_name)
	if (symbol < 0):
		return 0
	if (load_int(table + symbol + 10) != 2):
		return 0
	if (type_unqualified(type_function_return(signature_type)) != type_unqualified(load_int(table + symbol + 6))):
		return 0
	int expected_args = type_function_param_count(signature_type)
	if (sym_num_args(symbol) != expected_args):
		return 0
	int i = 0
	while (i < expected_args):
		if (type_unqualified(type_function_param_type(signature_type, i)) != type_unqualified(sym_param_type(symbol, i))):
			return 0
		i = i + 1
	return 1


int types_compatible_with_expression(int want, int got):
	if (got == 4):
		int signature_type = type_function_pointer_signature(want)
		if (signature_type >= 0):
			return function_signature_matches_symbol(signature_type, last_identifier)
	if (type_decays_to_pointer(want, got)):
		return 1
	return types_compatible(want, got)


void coerce_cstr_to_string():
	push_eax()
	stack_pos = stack_pos + 1
	sym_get_value(c"str_from_cstr")
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(word_size)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(word_size)
	call_eax()
	be_pop(2)
	stack_pos = stack_pos - 2
	be_pop(1)
	stack_pos = stack_pos - 1


void coerce_cstr_to_string_call_arg():
	coerce_cstr_to_string()


/*
Convert the lvalue address in eax into an rvalue, sized by its type.

Expression types follow one convention: a real type index means eax holds
the ADDRESS of a value of that type; "constant" (3) and "function" (4)
mean eax already holds the value. Structs are used by address, so they
are never loaded either.
*/
int promote(int type):
	if (hash_index_pending):
		return hash_finish_pending_read()
	if (verbosity >= 1):
		print2(itoa(line_number))
		print2(c": promote(")
		print2(itoa(type))
		print2(c"=")
		print2(type_get_name(type))
		print2(c", '")
		print2(last_identifier)
		println2(c"')")

	if (type_is_value(type)):
		return type_real(type)
	if (type == 3): /* constant: already a value */
		return type
	if (type == 4): /* function: its address is its value */
		return type
	if (type == float32_value_type):
		return type
	if (type == float64_value_type):
		return type
	if (type == string_value_type):
		return type
	if (type == var_value_type):
		return type
	if (type_is_array(type)):
		return type_get_slice_value(type_get_element_type(type))
	if (type_num_args(type) > 0): /* struct: keep the address */
		return type
	if (type_get_kind(type) == type_kind_slice()):
		promote_eax()
		return type_get_slice_value(type_get_element_type(type))
	if (type == string_type):
		promote_eax()
		return string_value_type
	if (type == var_type):
		promote_eax()
		return var_value_type
	if (type_get_pointer_level(type) > 0):
		promote_eax()
		return type

	int size = type_get_size(type)
	int unsigned_fixed = type_is_unsigned_fixed(type)
	if (size == 1):
		if (unsigned_fixed):
			promote_uint8_eax()
		else:
			promote_int8_eax()
	else if (size == 2):
		if (type == float16_type):
			promote_uint16_eax()
			movd_xmm0_eax()
			vcvtph2ps_xmm0()
			movd_eax_xmm0()
			return float32_value_type
		else if (unsigned_fixed):
			promote_uint16_eax()
		else:
			promote_int16_eax()
	else if (size == 4):
		if (unsigned_fixed):
			promote_uint32_eax()
		else:
			promote_int32_eax()
	else if (size >= 4):
		promote_eax()
	/* size 0 (void): nothing to load */
	if (type_float_kind(type) == 1):
		return float32_value_type
	if (type_float_kind(type) == 2):
		return float64_value_type
	return type


void coerce(int want, int got):
	want = type_canonical(want)
	got = type_canonical(got)
	if (type_is_var(type_unqualified(want)) | type_is_var(type_unqualified(got))):
		var_coerce(type_unqualified(want), type_unqualified(got))
		return;
	if ((want == bool_type) && (got != bool_type)):
		promote(got)
		alu_test_set(0x95) /* setne */
		return;
	int want_kind = type_float_kind(want)
	int got_kind = type_float_kind(got)
	if (want == 3):
		return;


	if (want == 4):
		return;
	if (got == 4):
		return;
	if (type_decays_to_pointer(want, got)):
		# Array-to-pointer decay: eax holds the descriptor's address, and
		# the descriptor's first word is the data pointer.
		promote_eax()
		return;
	if (type_is_string(want)):
		if (type_is_char_pointer(got)):
			coerce_cstr_to_string()
		return;
	if (want_kind == got_kind):
		if ((want == float16_type) && (got != float16_type)):
			movd_xmm0_eax()
			vcvtps2ph_xmm0()
			movd_eax_xmm0()
		return;

	if (want_kind == 1):
		if (got_kind == 2):
			movq_xmm0_rax()
			cvtsd2ss_xmm0()
			movd_eax_xmm0()
		else:
			cvtsi2ss_xmm0_eax()
			movd_eax_xmm0()
		if (want == float16_type):
			movd_xmm0_eax()
			vcvtps2ph_xmm0()
			movd_eax_xmm0()
		return;

	if (want_kind == 2):
		if (word_size != 8):
			error(c"float64 requires the x64 target")
		if (got_kind == 1):
			movd_xmm0_eax()
			cvtss2sd_xmm0()
			movq_rax_xmm0()
		else:
			cvtsi2sd_xmm0_rax()
			movq_rax_xmm0()
		return;

	if ((got_kind == 1) & (type_get_pointer_level(want) == 0)):
		movd_xmm0_eax()
		cvttss2si_eax_xmm0()
		return;
	if ((got_kind == 2) & (type_get_pointer_level(want) == 0)):
		movq_xmm0_rax()
		cvttsd2si_rax_xmm0()


# Conversions requested with cast(T, x). Casts silence the compatibility
# warnings but still reject conversions that cannot round-trip: address-sized
# values (pointers, function addresses and decayed array/slice values) only
# fit in word-sized integers. cast(T, arr) decays like every other pointer
# context: cast(int, arr) equals cast(int, arr.data), matching
# cast(char*, arr) — the descriptor's own address has no cast() spelling.
void coerce_explicit(int want, int got):
	int want_real = type_unqualified(want)
	int got_real = type_unqualified(got)
	int got_address_sized = type_get_pointer_level(got_real) > 0
	if (got_real == 4):
		got_address_sized = 1
	int got_decays = type_get_kind(got_real) == type_kind_slice_value()
	if (got_decays):
		got_address_sized = 1
	if (got_address_sized & (type_get_pointer_level(want_real) == 0)):
		if ((type_num_args(want_real) == 0) & (type_float_kind(want_real) == 0)):
			int want_size = type_get_size(want_real)
			if ((want_size > 0) && (want_size < word_size)):
				error(c"cannot cast an address to a sub-word integer")
			if (got_decays & (type_get_kind(want_real) == 0)):
				# Word-sized integer target: decay to the data pointer,
				# the same value coerce() produces for pointer targets
				promote_eax()
	coerce(want, got)
