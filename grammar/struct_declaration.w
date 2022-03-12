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
	if (accept("struct")):
		int start_tab_level = tab_level
		if (verbosity >= 1):
			print_int("start_tab_level: ", start_tab_level)
			print_string("struct accepted name: ", token)
			println2("")
		current_symbol = sym_declare_global(token, 5, 1)

		# emit struct type with token name
		type_index = type_push(strclone(token))
		type_print_all()

		get_token()
		# print_string("token_colon: ", token)
		expect(":")
		while(tab_level > start_tab_level):
			if (verbosity >= 1):
				print2("type_token: ")
				print2(token)
			int field_type = type_name()
			if (verbosity >= 1):
				print_int0("[", field_type)
				println2("]")

			current_symbol = sym_declare_global(token, field_type, 1)
			type_add_arg(type_index, strclone(token), field_type)
			if (verbosity >= 1):
				print_int("num_fields: ", num_fields)
				print_string("field: ", token)
				print_error("\x0a")

			get_token()
			num_fields = num_fields + 1
			pointer_indirection = 0

		return 1

	return 0

