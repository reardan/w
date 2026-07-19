# Import-alias support lives in grammar/import_statement.w, which is
# compiled after this file; see the definitions there.
int import_alias_lookup(char* name);
int import_alias_member(int alias_index);
void import_warn_unqualified(char* name);
void import_warn_transitive(char* name);


# Returns the identifier's type index, or -1 when the token is not an identifier.
int identifier():
	int c = token[0]
	if ((('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z')) || (c == '_')):
		# Qualified access through an import alias: alias.member. The dot
		# must follow immediately, and the alias shadows any symbol with
		# the same name in this position.
		if (nextc == '.'):
			int alias_index = import_alias_lookup(token)
			if (alias_index >= 0):
				return import_alias_member(alias_index)
		import_warn_unqualified(token)
		import_warn_transitive(token)
		strcpy(last_identifier, token)
		return sym_get_value(token)
	return -1
