int enum_declaration():
	if (accept(c"enum")):
		int start_tab_level = tab_level
		int type_index = type_lookup(token)
		if (type_index < 0):
			type_index = type_push_size(strclone(token), 4)
		else:
			type_reset_for_redefinition(type_index, 4)
		type_set_decl_location(type_index, decl_file_index(), diag_token_line, diag_token_column)
		type_set_kind(type_index, type_kind_enum)
		sym_declare_global(token, type_index, 1)
		get_token()
		expect(c":")
		int value = 0
		while(tab_level > start_tab_level):
			char* value_name = strclone(token)
			int value_line = diag_token_line
			int value_column = diag_token_column
			get_token()
			if (accept(c"=")):
				if ((token[0] == '0') & (token[1] == 'x')):
					int_literal_width_check(8)
					value = from_hex(token + 2)
				else:
					int_literal_decimal_check()
					value = atoi(token)
				get_token()
			int current_symbol = sym_declare_global(value_name, type_index, 1)
			sym_set_decl_location(current_symbol, decl_file_index(), value_line, value_column)
			# The constant's int32 lives at the symbol's address
			# (identifier.w loads it like a global). Inline in the code
			# stream, except on wasm, where code is not addressable
			# memory (and stray bytes between the size-prefixed function
			# units would corrupt the code section): there it goes into
			# the data segment.
			if (target_isa == 2):
				sym_define_global_at(current_symbol, data_offset + datapos)
				emit_data_word(value)
			else:
				sym_define_global(current_symbol)
				emit_int32(value)
			value = value + 1
			pointer_indirection = 0
		return 1
	return 0
