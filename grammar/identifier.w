# Import-alias support lives in grammar/import_statement.w, which is
# compiled after this file; see the definitions there.
int import_alias_lookup(char* name);
int import_alias_member(int alias_index);
void import_warn_unqualified(char* name);
void import_warn_transitive(char* name);


# The identifier's value: a function that may be called directly (unit
# A4, grammar/stack_slot.w) is only noted -- the call suffix emits the
# call, and primary_expr materializes the address when no '(' follows.
# Anything else emits its address or value now.
# The resolved twin, for callers that already looked the name up: one
# lookup per identifier (compile-time symbol traffic is what
# tools/wbench.w guards). t may be -1.
int identifier_value_at(int t, char* name):
	if (target_isa == 3): return gpu_sym_get_value(name)
	if (direct_callee_ok(t)):
		direct_callee_note(1, t)
		return 4 /* function */
	if (t < 0): sym_not_found_error(name)
	return sym_emit_value(t, name)


int identifier_value(char* name):
	# Device bodies use a separate symbol/stack model (sym_get_value)
	if (target_isa == 3): return gpu_sym_get_value(name)
	return identifier_value_at(sym_lookup(name), name)


# Returns the identifier's type index, or -1 when the token is not an identifier.
int identifier():
	int c = token[0]
	if (is_ident_start_byte(c)):
		# Qualified access through an import alias: alias.member. The dot
		# must follow immediately, and the alias shadows any symbol with
		# the same name in this position.
		if (nextc == '.'):
			int alias_index = import_alias_lookup(token)
			if (alias_index >= 0): return import_alias_member(alias_index)
		import_warn_unqualified(token)
		import_warn_transitive(token)
		strcpy(last_identifier, token)
		return identifier_value(token)
	return -1
