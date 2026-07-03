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
	int function_start = codepos /* keep track of start for length comp */
	while (accept(")") == 0):
		param_count = param_count + 1
		number_of_args = number_of_args + 1
		int type = type_name()
		# Record the declared type so call sites can check arguments
		if (param_count <= sym_max_param_slots()):
			save_int(table + current_symbol + 22 + (param_count << 2), type)
		/* this seems stupid, you could just have (typename) with no identifier */
		if (peek(")") == 0):
			sym_declare(token, type, 'A', number_of_args, 1)
			pointer_indirection = 0
			get_token()

		# A by-value struct occupies several stack words; later
		# parameters address past all of them
		if (type_num_args(type) > 0):
			int struct_words = (type_get_size(type) + word_size - 1) >> word_size_log2
			number_of_args = number_of_args + struct_words - 1

		accept(",") /* ignore trailing comma */

	# Record the arity for call-site checks (definitions overwrite
	# whatever an earlier prototype recorded)
	save_int(table + current_symbol + 22, param_count)

	if (accept(";") == 0):
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


void program():
	int current_symbol
	while (token[0]):
		# First handle imports
		while (import_statement() ) {}

		# Type aliases must be available before structs and declarations
		while(type_alias_declaration()) {}

		# Next handle struct declarations
		while(struct_declaration()):
			print_int_v1("struct_declaration=1", 1)

		# Shared-library declarations (c_lib / extern)
		while (extern_statement()) {}

		# Imports/structs may have consumed the rest of the file
		if (token[0] == 0):
			return;

		# Now global variables + functions
		# TODO: variables THEN functions, not both
		current_symbol = sym_declare_global(token, type_name(), 1)
		get_token()
		if (accept(";")):
			sym_define_global(current_symbol)
			emit_zeros(word_size)

		else if (accept("(")):
			function_definition(current_symbol)

		else:
			/*error(8)*/
			sym_define_global(current_symbol)
			emit_zeros(word_size)
