/*

struct_declaration identifier :
	type_name identifier
	...

*/
# Forward declaration: defhash_note is defined in compiler/compiler.w,
# which compiles after grammar/.
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset);


int struct_declaration():
	int current_symbol
	int num_fields = 0
	int type_index = 0
	int defhash_start = token_start_offset
	# parent_expression()
	if (accept(c"struct")):
		int start_tab_level = tab_level
		# 'struct name[T, ...]:' declares a generic struct: record the
		# span and skip it; instantiations re-parse it (grammar/generic.w).
		# Left out of defhash on purpose (docs/projects/build_system_next.md
		# 4a): the span defhash_note would need is the unexpanded generic
		# body, which this branch never reaches per-instantiation.
		if (nextc == '['):
			generic_register_struct()
			return 1
		if (verbosity >= 1):
			print_int(c"start_tab_level: ", start_tab_level)
			print_string(c"struct accepted name: ", token)
			println2(c"")

		char* defhash_name = strclone(token)
		int defhash_line = diag_token_line
		int defhash_column = diag_token_column
		# emit struct type with token name; size starts at 0 and grows per
		# field. A repeated name (REPL redefinition) reuses and resets the
		# existing record in place instead of pushing an unreachable
		# duplicate — see type_reset_for_redefinition.
		type_index = type_lookup(token)
		if (type_index < 0):
			type_index = type_push_size(strclone(token), 0)
		else:
			type_reset_for_redefinition(type_index, 0)
		type_set_decl_location(type_index, decl_file_index(), diag_token_line, diag_token_column)
		current_symbol = sym_declare_global(token, type_index, 1)
		# type_print_all()

		get_token()
		# print_string("token_colon: ", token)
		expect(c":")
		while(tab_level > start_tab_level):
			if (verbosity >= 1):
				print2(c"type_token: ")
				print2(token)
			int field_type = type_name()
			if (verbosity >= 1):
				print_int0(c"[", field_type)
				println2(c"]")

			type_add_arg(type_index, strclone(token), field_type)
			if (verbosity >= 1):
				print_int(c"num_fields: ", num_fields)
				print_string(c"field: ", token)
				print_error(c"\x0a")

			get_token()
			num_fields = num_fields + 1
			pointer_indirection = 0

		defhash_note(defhash_name, c"struct", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)
		return 1

	return 0

