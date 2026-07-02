# Returns the identifier's type index, or -1 when the token is not an identifier.
int identifier():
	if (('a' <= token[0]) & (token[0] <= 'z')):
		strcpy(last_identifier, token)
		return sym_get_value(token)
	return -1
