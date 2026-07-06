/*
 * program:
 *     declaration
 *     declaration program
 *
 * declaration:
 *     type-name identifier ;
 *     type-name identifier ( parameter-list ) ;
 *     type-name identifier ( parameter-list ) statement
 *
 * parameter-list:
 *     parameter-declaration
 *     parameter-list, parameter-declaration
 *
 * parameter-declaration:
 *     type-name identifier-opt
 */
# Parse the compile-time constant after '=' in a parameter declaration:
# an integer literal (decimal or hex, optionally negated), a char literal,
# or a named enum constant (whose int32 value was already emitted into the
# image at the constant's address). Anything else is rejected.
int parse_constant_default():
	int negative = 0
	int value = 0
	if (accept(c"-")):
		negative = 1
	# char literal e.g. 'c'
	if ((token[0] == 39) & (token[1] != 0) & (token[1] != 92) &
			(token[2] == 39) & (token[3] == 0)):
		value = token[1]
	# escaped char literal e.g. '\n'
	else if ((token[0] == 39) & (token[1] == 92) &
			(token[3] == 39) & (token[4] == 0)):
		int c = token[2]
		if (c == 'n'):
			c = 10
		else if (c == 't'):
			c = 9
		else if (c == 'r'):
			c = 13
		else if (c == '0'):
			c = 0
		value = c
	else if ((token[0] == '0') & (token[1] == 'x')):
		value = from_hex(token + 2)
	else if (('0' <= token[0]) & (token[0] <= '9')):
		value = atoi(token)
	else:
		# A named enum constant: a defined global object of an enum type.
		# Its value is the int32 the enum declaration emitted at its address.
		int t = sym_lookup(token)
		int is_enum_constant = 0
		if (t >= 0):
			if ((table[t + 1] == 'D') & (load_int(table + t + 10) == 1)):
				if (type_get_kind(load_int(table + t + 6)) == type_kind_enum):
					is_enum_constant = 1
		if (is_enum_constant == 0):
			diag_part(c"default value for parameter must be a compile-time constant, got '")
			diag_part(token)
			error(c"'")
		value = load_int32(code + load_int(table + t + 2) - code_offset)
	get_token()
	if ((peek(c",") == 0) & (peek(c")") == 0)):
		error(c"default value for parameter must be a single compile-time constant")
	if (negative):
		value = 0 - value
	return value


# Parses "parameter-list ) [; | body]" for the function symbol at table
# offset current_symbol; the opening "(" has already been consumed.
# Shared by program() and the REPL's entry dispatcher.
void function_definition(int current_symbol):
	table[current_symbol + 10] = 2 /* store function type */
	int n = table_pos
	# number_of_args counts stack WORDS (struct values span several);
	# param_count counts declared parameters for arity checks.
	number_of_args = 0
	int declared_return_type = load_int(table + current_symbol + 6)
	if (type_num_args(declared_return_type) > 0):
		number_of_args = 1
	int param_count = 0
	int saw_default = 0
	int is_w_variadic = 0
	int function_start = codepos /* keep track of start for length comp */
	while (accept(c")") == 0):
		if (is_w_variadic):
			error(c"variadic parameter must be the last parameter")
		param_count = param_count + 1
		number_of_args = number_of_args + 1
		int type = type_name()
		# "T... name" declares a W variadic function: the callee sees the
		# trailing arguments as a T[] slice parameter.
		if (accept(c".")):
			expect(c".")
			expect(c".")
			if (saw_default):
				error(c"a variadic parameter cannot follow parameters with default values")
			if (param_count > sym_max_param_slots()):
				error(c"variadic functions support at most 10 parameters")
			int elem = type_unqualified(type)
			if ((type_num_args(elem) > 0) | type_is_array(elem) | type_is_slice(elem) |
					type_is_map(elem) | type_is_set(elem) | type_is_list(elem) |
					(type_get_size(elem) != word_size)):
				error(c"variadic parameter element type must be word-sized")
			if (type_is_var(elem)):
				error(c"variadic parameter element type cannot be var")
			type = type_get_slice(type)
			is_w_variadic = 1
		if (type_is_array(type)):
			error(c"fixed array parameter is not implemented; use T[] instead")
		# Record the declared type so call sites can check arguments
		if (param_count <= sym_max_param_slots()):
			save_int(table + current_symbol + 22 + (param_count << 2), type)
		/* this seems stupid, you could just have (typename) with no identifier */
		if (peek(c")") == 0):
			sym_declare(token, type, 'A', number_of_args, 1)
			pointer_indirection = 0
			get_token()

		# A by-value aggregate occupies several stack words; later
		# parameters address past all of them
		int arg_words = type_stack_words(type)
		if (arg_words > 1):
			number_of_args = number_of_args + arg_words - 1

		# "= constant" records a default; call sites push it for missing
		# trailing arguments. Once one parameter has a default, all that
		# follow must too.
		if (accept(c"=")):
			if (is_w_variadic):
				error(c"a variadic parameter cannot have a default value")
			if (type_is_var(type_unqualified(type))):
				error(c"default values are not supported on var parameters")
			if (param_count > sym_max_param_slots()):
				error(c"default values are only supported on the first 10 parameters")
			int default_value = parse_constant_default()
			if (saw_default == 0):
				# This declaration's defaults replace any recorded earlier
				# (a definition overrides its prototype)
				sym_clear_param_defaults(current_symbol)
			saw_default = 1
			sym_set_param_default(current_symbol, param_count - 1, default_value)
		else if (saw_default):
			error(c"parameter without a default follows a parameter with a default")

		accept(c",") /* ignore trailing comma */

	# Record the arity for call-site checks (definitions overwrite
	# whatever an earlier prototype recorded)
	save_int(table + current_symbol + 22, param_count)
	if (is_w_variadic):
		sym_set_w_variadic(current_symbol, param_count - 1)
	else:
		sym_set_w_variadic(current_symbol, -1)

	if (accept(c";") == 0):
		sym_define_global(current_symbol)
		current_function_symbol = current_symbol
		enclosing_tab_level = 0
		# Record the argument word count for the debugger's
		# runtime argument addressing
		debug_func_note(function_start, number_of_args)
		statement()
		ret()
		# Store length to symbol table:
		save_int(table + current_symbol + 14, codepos - function_start)

	table_pos = n


void emit_global_type_storage(int type);


int global_storage_size(int type):
	int bytes = word_size
	int declared_size = type_get_size(type)
	if ((type_num_args(type) > 0) | (declared_size > word_size)):
		bytes = declared_size
	return ((bytes + word_size - 1) >> word_size_log2) << word_size_log2


void emit_global_storage(int type):
	int bytes = global_storage_size(type)
	int start = codepos
	emit_global_type_storage(type)
	emit_zeros(bytes - (codepos - start))


void emit_global_type_storage(int type):
	if (type_is_array(type)):
		emit_target_word(code_offset + codepos + 2 * word_size)
		emit_target_word(type_get_array_length(type))
		emit_zeros(type_get_size(type) - 2 * word_size)
	else if (type_num_args(type) > 0):
		int i = 0
		while (i < type_num_args(type)):
			emit_global_type_storage(type_get_field_type_at(type, i))
			i = i + 1
	else:
		emit_zeros(type_get_size(type))


void program():
	int current_symbol
	while (token[0]):
		# First handle imports
		while (import_statement() ) {}
		while (c_import_statement()) {}

		# Type aliases must be available before structs and declarations.
		# Aliases and aggregates may appear in any order (e.g. a type alias
		# right after a struct), so keep dispatching until none make progress.
		int parsed_declaration = 1
		while (parsed_declaration):
			parsed_declaration = 0
			while(type_alias_declaration()):
				parsed_declaration = 1
			while(struct_declaration()):
				parsed_declaration = 1
				print_int_v1(c"struct_declaration=1", 1)
			while(union_declaration()):
				parsed_declaration = 1
				print_int_v1(c"union_declaration=1", 1)
			while(enum_declaration()):
				parsed_declaration = 1
				print_int_v1(c"enum_declaration=1", 1)

		# Shared-library declarations (c_lib / extern)
		while (extern_statement()) {}

		# Imports/structs may have consumed the rest of the file
		if (token[0] == 0):
			return;

		# generator declarations: "generator type-name identifier (".
		# "generator*" is the struct type in a variable declaration, so
		# only a bare 'generator' token marks a declaration.
		if (peek(c"generator")):
			if (nextc != '*'):
				generator_declaration()
				continue;

		# Now global variables + functions
		# TODO: variables THEN functions, not both
		int decl_type = type_name()
		current_symbol = sym_declare_global(token, decl_type, 1)
		get_token()
		if (accept(c";")):
			sym_define_global(current_symbol)
			emit_global_storage(decl_type)

		else if (accept(c"(")):
			function_definition(current_symbol)

		else:
			/*error(8)*/
			sym_define_global(current_symbol)
			emit_global_storage(decl_type)
