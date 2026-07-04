char *last_identifier


# Print a type's name followed by its pointer stars, e.g. "char**"
void print_error_type(int type_index):
	type_index = type_real(type_index)
	print_error(type_get_name(type_index))
	for int i in range(type_get_pointer_level(type_index)):
		print_error("*")


# Warn that 'got' does not convert to 'want'; context names the construct
# (assignment, initialization, return, ...)
void warn_type_mismatch(char* context, int want, int got):
	print_error("warning: ")
	print_error(context)
	print_error(" type mismatch: expected '")
	print_error_type(want)
	print_error("', got '")
	print_error_type(got)
	warning("'")


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
	return types_compatible(want, got)



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
		print2(": promote(")
		print2(itoa(type))
		print2("=")
		print2(type_get_name(type))
		print2(", '")
		print2(last_identifier)
		println2("')")

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
	if (type_get_pointer_level(type) > 0):
		promote_eax()
		return type

	int size = type_get_size(type)
	if (size == 1):
		promote_int8_eax()
	else if (size == 2):
		if (type == float16_type):
			promote_uint16_eax()
			movd_xmm0_eax()
			vcvtph2ps_xmm0()
			movd_eax_xmm0()
			return float32_value_type
		else:
			promote_int16_eax()
	else if (size == 4):
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
	if ((want == bool_type) & (got != bool_type)):
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
	if (want_kind == got_kind):
		if ((want == float16_type) & (got != float16_type)):
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
			error("float64 requires the x64 target")
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


void coerce_explicit(int want, int got):
	coerce(want, got)
