int type_alias_declaration():
	if (accept("type")):
		char* alias_name = strclone(token)
		get_token()
		expect("=")
		int target = -1
		if (accept("fn")):
			expect("(")
			int params = cast(int, malloc(40))
			int param_count = 0
			if (accept(")") == 0):
				int param_type = type_name()
				save_int(params + (param_count << 2), param_type)
				param_count = param_count + 1
				while (accept(",")):
					param_type = type_name()
					save_int(params + (param_count << 2), param_type)
					param_count = param_count + 1
				expect(")")
			expect("-")
			expect(">")
			int return_type = type_name()
			target = type_push_function(alias_name, return_type, param_count, params)
			free(cast(void*, params))
		else:
			target = type_name()
			type_push_alias(alias_name, target)
		pointer_indirection = 0
		expect_or_newline(";")
		return 1
	return 0
