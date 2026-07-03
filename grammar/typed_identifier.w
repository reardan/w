int last_declared_symbol


int typed_identifier():
	int type = type_name()
	sym_declare(token, type, 'L', stack_pos, 1)
	last_declared_symbol = table_pos - symbol_data_size()
	get_token()
	return type

