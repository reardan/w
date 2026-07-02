# Returns the identifier's type index, or -1 when the token is not an identifier.
int identifier():
	int c = token[0]
	if ((('a' <= c) & (c <= 'z')) | (('A' <= c) & (c <= 'Z')) | (c == '_')):
		strcpy(last_identifier, token)
		return sym_get_value(token)
	return -1
