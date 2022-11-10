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
			number_of_args = 0
			function_start = codepos /* keep track of start for length comp */
			while (accept(")") == 0):
				number_of_args = number_of_args + 1
				int type = type_name()
				/* this seems stupid, you could just have (typename) with no identifier */
				if (peek(")") == 0):
					sym_declare(token, type, 'A', number_of_args, 1)
					pointer_indirection = 0
					get_token()

				accept(",") /* ignore trailing comma */

			if (accept(";") == 0):
				sym_define_global(current_symbol)
				statement()
				ret()
				# Store length to symbol table:
				save_int(table + current_symbol + 14, codepos - function_start)

			table_pos = n

		else:
			/*error(8)*/
			sym_define_global(current_symbol)
			emit_zeros(word_size)
