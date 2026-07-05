/*

struct_declaration identifier :
	type_name identifier
	...

*/
int struct_declaration():
	int current_symbol
	int num_fields = 0
	int type_index = 0
	# parent_expression()
	if (accept(c"struct")):
		int start_tab_level = tab_level
		if (verbosity >= 1):
			print_int(c"start_tab_level: ", start_tab_level)
			print_string(c"struct accepted name: ", token)
			println2(c"")

		# emit struct type with token name; size starts at 0 and grows per field
		type_index = type_push_size(strclone(token), 0)
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

		return 1

	return 0

