# Forward declaration: defhash_note is defined in compiler/compiler.w,
# which compiles after grammar/ (see compiler/tokenizer.w's defhash_mode
# comment for why the flag itself needs no such declaration).
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset);


int type_alias_declaration():
	int defhash_start = token_start_offset
	if (accept(c"type")):
		char* alias_name = strclone(token)
		# Capture the alias name's position before parsing the target moves
		# the current token
		int alias_file = decl_file_index()
		int alias_line = diag_token_line
		int alias_column = diag_token_column
		get_token()
		expect(c"=")
		int target = -1
		if (accept(c"fn")):
			expect(c"(")
			char* params = malloc(10 * __word_size__)
			int param_count = 0
			if (accept(c")") == 0):
				int param_type = type_name()
				save_ptr(params + param_count * __word_size__, param_type)
				param_count = param_count + 1
				while (accept(c",")):
					param_type = type_name()
					save_ptr(params + param_count * __word_size__, param_type)
					param_count = param_count + 1
				expect(c")")
			expect(c"-")
			expect(c">")
			int return_type = type_name()
			target = type_push_function(alias_name, return_type, param_count, cast(int, params))
			type_set_decl_location(target, alias_file, alias_line, alias_column)
			free(params)
		else:
			target = type_name()
			type_set_decl_location(type_push_alias(alias_name, target), alias_file, alias_line, alias_column)
		pointer_indirection = 0
		expect_or_newline(c";")
		defhash_note(alias_name, c"alias", alias_file, alias_line, alias_column, defhash_start, token_start_offset)
		return 1
	return 0
