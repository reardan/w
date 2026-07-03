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
void program():
	int current_symbol
	int function_start
	while (token[0]):
		# First handle imports
		while (import_statement() ) {}

		# Next handle struct declarations
		while(struct_declaration()):
			print_int("struct_declaration=1, current_symbol=", current_symbol)

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
			table[current_symbol + 10] = 2 /* store function type */
			int n = table_pos
			# number_of_args counts stack WORDS (struct values span several);
			# param_count counts declared parameters for arity checks.
			number_of_args = 0
			int param_count = 0
			function_start = codepos /* keep track of start for length comp */
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
				statement()
				ret()
				# Store length to symbol table:
				save_int(table + current_symbol + 14, codepos - function_start)

			table_pos = n

		else:
			/*error(8)*/
			sym_define_global(current_symbol)
			emit_zeros(word_size)
