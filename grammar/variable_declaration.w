int ast_local_declaration(statement_ast* node, char* name);
void emit_inferred_local_storage(int type);
void emit_typed_local_storage(int type, int has_initializer);


# Import-alias support lives in grammar/import_statement.w, which is
# compiled after this file; see the definition there.
int import_alias_type_ahead(int require_call);


# Storage type a 'name := expression' local declares for an initializer
# expression type. Value pseudo-types map back to their declarable
# storage types (the generic-inference rule); untyped constants default
# to int (the word-sized type, so the same source infers the same
# storage on every target); bare function names and void expressions
# have no storage type, and the diagnostics name the variable.
int inferred_storage_type(char* name, int got):
	if (got == 3): return type_lookup(c"int")
	if (got == 4): error3(c"cannot infer a type for '", name, c"' from a bare function name")
	int t = generic_infer_declarable(type_real(got))
	t = type_unqualified(t)
	if ((type_get_size(t) == 0) & (type_num_args(t) == 0)):
		error3(c"cannot infer a type for '", name, c"' from a void expression")
	return t


# Safer ':=' (issue #360): ':=' always declares a NEW variable, so a
# name still visible as a local or parameter is a redeclaration -- in
# practice the writer meant '=' (the assignment), or wanted an explicit
# typed declaration for a deliberate shadow. Locals in closed blocks do
# not trigger this: scope exit truncates the symbol table, so only live
# bindings are found. Globals stay silently shadowable, matching typed
# declarations.
void inferred_redeclaration_check(char* name):
	int existing = sym_lookup(name)
	if (existing < 0): return;
	int visibility = table[existing + 1]
	if ((visibility == 'L') || (visibility == 'A')):
		sym_note_related(existing, c"'", name, c"' is declared here")
		error3(c"':=' redeclares '", name, c"'; use '=' to assign, or a typed declaration to shadow")


/*
name := expression

declares a local variable whose type is inferred from the initializer
(docs/projects/golf_ergonomics.md). The tokenizer has one character of
lookahead, so a cheap gate (identifier followed by ':' or whitespace)
guards a one-token scan-ahead that uses the save/seek/restore trick
from grammar/generic.w; statements that do not continue with ':='
rewind and reparse normally. Returns 1 when a declaration was parsed.
*/
int inferred_declaration():
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0): return 0
	# ':=' can only follow directly (nextc is its ':') or after blanks
	if ((nextc != ':') && (nextc != ' ') && (nextc != 9)): return 0
	statement_ast node
	node.kind = ast_stmt_declaration
	node.source_file = file
	node.line = diag_token_line
	node.column = diag_token_column
	node.start_offset = token_start_offset
	char* name = strclone(token)
	char* save = generic_reparse_save()
	get_token()
	if (peek(c":=") == 0):
		free(name)
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)
	get_token() /* consume ':=' */
	inferred_redeclaration_check(name)
	if (ast_expressions_mode >= 2):
		node.inferred = 1
		node.declared_type = -1
		ast_local_declaration(&node, name)
		free(name)
		return 1
	int got = expression()
	got = promote(got)
	int type = inferred_storage_type(name, got)
	# Unlike 'type name = expr' the symbol is declared after the
	# initializer, so the initializer cannot reference the new name and
	# the recorded slot index needs no post-expression fixup.
	sym_declare(name, type, 'L', stack_pos, 1)
	sym_note_inferred_location(table_pos - symbol_data_size, node.line, node.column)
	lint_track_local(table_pos - symbol_data_size)
	free(name)
	pointer_indirection = 0
	emit_inferred_local_storage(type)
	return 1


int variable_declaration():
	# type-name identifier ('alias.TypeName' counts as a type name:
	# import_alias_type_ahead only claims a member that names a type
	# declared in the aliased module, so 'alias.value' stays an
	# expression statement)
	if (peek(c"const") | (peek(c"map") & (nextc == '[')) | (peek(c"set") & (nextc == '[')) | (peek(c"list") & (nextc == '[')) | (type_lookup(token) >= 0) | generic_type_starts_here() | (import_alias_type_ahead(0) >= 0) | gpu_qualifier_ahead()):
		# println2("variable_declaration()")
		statement_ast node
		node.kind = ast_stmt_declaration
		node.source_file = file
		node.line = diag_token_line
		node.column = diag_token_column
		node.start_offset = token_start_offset
		int type = typed_identifier()
		lint_track_local(last_declared_symbol)
		lint_check_shadow()
		if (ast_expressions_mode >= 2):
			node.inferred = 0
			node.declared_type = type
			return ast_local_declaration(&node, 0)
		int has_initializer = 0
		int type2 = -1
		# = expression
		if (accept(c"=")):
			has_initializer = 1
			if (type_is_array(type)): error(c"fixed array initializer is not implemented")
			type2 = expression()
			type2 = promote(type2)
			coerce_checked(type, type2, c"initialization")
			# Level 1: this is a per-declaration developer trace like its
			# siblings (promote(), sym_declare(), ...), not part of the
			# user-facing -v level 0 output (which -v now reaches).
			if (verbosity >= 1):
				print2(c"variable declaration = expression() right side type: ")
				type_print(type2)
		save_int(table + last_declared_symbol + 2, stack_pos)
		pointer_indirection = 0

		emit_typed_local_storage(type, has_initializer)
		return type
	return -1


