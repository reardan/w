int type_alias_declaration():
	if (accept(c"type")):
		char* alias_name = strclone(token)
		get_token()
		expect(c"=")
		int target = -1
		if (accept(c"fn")):
			expect(c"(")
			char* params = malloc(40)
			int param_count = 0
			if (accept(c")") == 0):
				int param_type = type_name()
				save_int(params + (param_count << 2), param_type)
				param_count = param_count + 1
				while (accept(c",")):
					param_type = type_name()
					save_int(params + (param_count << 2), param_type)
					param_count = param_count + 1
				expect(c")")
			expect(c"-")
			expect(c">")
			int return_type = type_name()
			target = type_push_function(alias_name, return_type, param_count, cast(int, params))
			free(params)
		else:
			target = type_name()
			type_push_alias(alias_name, target)
		pointer_indirection = 0
		expect_or_newline(c";")
		return 1
	return 0
