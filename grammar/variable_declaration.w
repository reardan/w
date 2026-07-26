# Storage type a 'name := expression' local declares for an initializer
# expression type. Value pseudo-types map back to their declarable
# storage types (the generic-inference rule); untyped constants default
# to int (the word-sized type, so the same source infers the same
# storage on every target); bare function names and void expressions
# have no storage type, and the diagnostics name the variable.
int inferred_storage_type(char* name, int got):
	if (got == 3):
		return type_lookup(c"int")
	if (got == 4):
		diag_part(c"cannot infer a type for '")
		diag_part(name)
		error(c"' from a bare function name")
	int t = generic_infer_declarable(type_real(got))
	t = type_unqualified(t)
	if ((type_get_size(t) == 0) & (type_num_args(t) == 0)):
		diag_part(c"cannot infer a type for '")
		diag_part(name)
		error(c"' from a void expression")
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
	if (existing < 0):
		return;
	int visibility = table[existing + 1]
	if ((visibility == 'L') || (visibility == 'A')):
		diag_part(c"':=' redeclares '")
		diag_part(name)
		error(c"'; use '=' to assign, or a typed declaration to shadow")


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
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		return 0
	# ':=' can only follow directly (nextc is its ':') or after blanks
	if ((nextc != ':') && (nextc != ' ') && (nextc != 9)):
		return 0
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
	int got = expression()
	got = promote(got)
	int type = inferred_storage_type(name, got)
	# Unlike 'type name = expr' the symbol is declared after the
	# initializer, so the initializer cannot reference the new name and
	# the recorded slot index needs no post-expression fixup.
	sym_declare(name, type, 'L', stack_pos, 1)
	free(name)
	pointer_indirection = 0
	int size = type_stack_words(type)
	if ((type_num_args(type) > 0) & (type_is_array(type) == 0)):
		# Struct value: eax holds its address; copy the words
		int j = size - 1
		while (j >= 0):
			push_eax_plus(j << word_size_log2)
			j = j - 1
		stack_pos = stack_pos + size
		if (type_has_array_field(type)):
			lea_eax_esp_plus(0)
			init_array_field_descriptors(type)
		return 1
	int i = 0
	while (i < size):
		push_eax()
		i = i + 1
	stack_pos = stack_pos + size
	return 1


int variable_declaration():
	# type-name identifier
	if (peek(c"const") | (peek(c"map") & (nextc == '[')) | (peek(c"set") & (nextc == '[')) | (peek(c"list") & (nextc == '[')) | (type_lookup(token) >= 0) | generic_type_starts_here()):
		# println2("variable_declaration()")
		int type = typed_identifier()
		int has_initializer = 0
		int type2 = -1
		# = expression
		if (accept(c"=")):
			has_initializer = 1
			if (type_is_array(type)):
				error(c"fixed array initializer is not implemented")
			type2 = expression()
			type2 = promote(type2)
			coerce(type, type2)
			if (types_compatible_with_expression(type, type2) == 0):
				warn_type_mismatch(c"initialization", type, type2)
			# Level 1: this is a per-declaration developer trace like its
			# siblings (promote(), sym_declare(), ...), not part of the
			# user-facing -v level 0 output (which -v now reaches).
			if (verbosity >= 1):
				print2(c"variable declaration = expression() right side type: ")
				type_print(type2)
		save_int(table + last_declared_symbol + 2, stack_pos)
		pointer_indirection = 0

		# Reserve enough words for aggregate storage, else 1 word.
		int size = type_stack_words(type)
		int num_args = type_num_args(type)
		if ((num_args > 0) & (type_is_array(type) == 0)):
			if (has_initializer):
				int j = size - 1
				while (j >= 0):
					push_eax_plus(j << word_size_log2)
					j = j - 1
				stack_pos = stack_pos + size
				if (type_has_array_field(type)):
					lea_eax_esp_plus(0)
					init_array_field_descriptors(type)
				return type
		if (type_is_array(type) | type_has_array_field(type)):
			mov_eax_int(0)
		int i = 0
		while (i < size):
			push_eax()
			i = i + 1
		stack_pos = stack_pos + size
		if (type_is_array(type)):
			lea_eax_esp_plus(2 * word_size)
			store_stack_var(0)
			mov_eax_int(type_get_array_length(type))
			store_stack_var(word_size)
		else if (type_has_array_field(type)):
			lea_eax_esp_plus(0)
			init_array_field_descriptors(type)
		return type
	return -1


