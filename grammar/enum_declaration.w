int enum_declaration():
	if (accept(c"enum")):
		int start_tab_level = tab_level
		int type_index = type_push_size(strclone(token), 4)
		type_set_kind(type_index, type_kind_enum)
		sym_declare_global(token, type_index, 1)
		get_token()
		expect(c":")
		int value = 0
		while(tab_level > start_tab_level):
			char* value_name = strclone(token)
			get_token()
			if (accept(c"=")):
				if ((token[0] == '0') & (token[1] == 'x')):
					value = from_hex(token + 2)
				else:
					value = atoi(token)
				get_token()
			int current_symbol = sym_declare_global(value_name, type_index, 1)
			sym_define_global(current_symbol)
			emit_int32(value)
			value = value + 1
			pointer_indirection = 0
		return 1
	return 0
