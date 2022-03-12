int identifier():
	if (('a' <= token[0]) & (token[0] <= 'z')):
		sym_get_value(token)
		strcpy(last_identifier, token)
		return 1
	return 0
