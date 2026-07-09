int union_declaration():
	if (accept(c"union")):
		int start_tab_level = tab_level
		int type_index = type_lookup(token)
		if (type_index < 0):
			type_index = type_push_size(strclone(token), 0)
		else:
			type_reset_for_redefinition(type_index, 0)
		type_set_decl_location(type_index, decl_file_index(), diag_token_line, diag_token_column)
		type_set_kind(type_index, type_kind_union)
		sym_declare_global(token, type_index, 1)
		get_token()
		expect(c":")
		while(tab_level > start_tab_level):
			int field_type = type_name()
			if (type_has_array_field(field_type)):
				error(c"fixed array fields are not implemented in unions")
			type_add_arg(type_index, strclone(token), field_type)
			get_token()
			pointer_indirection = 0
		return 1
	return 0
