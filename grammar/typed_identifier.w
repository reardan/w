int typed_identifier():
	int type = type_name()
	sym_declare(token, type, 'L', stack_pos, 1)
	get_token()
	return type

