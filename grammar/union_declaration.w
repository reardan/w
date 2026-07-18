# Forward declaration: defhash_note is defined in compiler/compiler.w,
# which compiles after grammar/.
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset);


int union_declaration():
	int defhash_start = token_start_offset
	if (accept(c"union")):
		int start_tab_level = tab_level
		char* defhash_name = strclone(token)
		int defhash_line = diag_token_line
		int defhash_column = diag_token_column
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
		defhash_note(defhash_name, c"union", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)
		return 1
	return 0
