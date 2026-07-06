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
	while (accept(c")") == 0):
		param_count = param_count + 1
		number_of_args = number_of_args + 1
		int type = type_name()
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

		accept(c",") /* ignore trailing comma */

	# Record the arity for call-site checks (definitions overwrite
	# whatever an earlier prototype recorded)
	save_int(table + current_symbol + 22, param_count)

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
