/*
 * program:
 *     declaration
 *     declaration program
 *
 * declaration:
 *     type-name identifier ;
 *     type-name identifier ( parameter-list ) ;
 *     type-name identifier ( parameter-list ) statement
 *
 * parameter-list:
 *     parameter-declaration
 *     parameter-list, parameter-declaration
 *
 * parameter-declaration:
 *     type-name identifier-opt
 */
# Parse the compile-time constant after '=' in a parameter declaration:
# an integer literal (decimal or hex, optionally negated), a char literal,
# or a named enum constant (whose int32 value was already emitted into the
# image at the constant's address). Anything else is rejected.
int parse_constant_default():
	int negative = 0
	int value = 0
	if (accept(c"-")):
		negative = 1
	# char literal e.g. 'c', '\n' or '\x41'; grammar/string_literal.w
	# decodes and validates the token
	if (token[0] == 39):
		value = char_literal_value()
	else if ((token[0] == '0') & (token[1] == 'x')):
		int_literal_width_check()
		value = from_hex(token + 2)
	else if (('0' <= token[0]) & (token[0] <= '9')):
		value = atoi(token)
	else:
		# A named enum constant: a defined global object of an enum type.
		# Its value is the int32 the enum declaration emitted at its address
		# — in the code stream on the native targets, in the data segment
		# on wasm (enum_declaration.w).
		int t = sym_lookup(token)
		int is_enum_constant = 0
		if (t >= 0):
			if ((table[t + 1] == 'D') & (load_int(table + t + 10) == 1)):
				if (type_get_kind(load_int(table + t + 6)) == type_kind_enum):
					is_enum_constant = 1
		if (is_enum_constant == 0):
			diag_part(c"default value for parameter must be a compile-time constant, got '")
			diag_part(token)
			error(c"'")
		if (target_isa == 2):
			value = load_int32(data + (load_int(table + t + 2) - data_offset))
		else:
			value = load_int32(code + load_int(table + t + 2) - code_offset)
	get_token()
	if ((peek(c",") == 0) & (peek(c")") == 0)):
		error(c"default value for parameter must be a single compile-time constant")
	if (negative):
		value = 0 - value
	return value


# Parses "parameter-list ) [; | body]" for the function symbol at table
# offset current_symbol; the opening "(" has already been consumed.
# Shared by program() and the REPL's entry dispatcher.
void function_definition(int current_symbol):
	table[current_symbol + 10] = 2 /* store function type */
	int n = table_pos
	# number_of_args counts stack WORDS (struct values span several);
	# param_count counts declared parameters for arity checks.
	number_of_args = 0
	int declared_return_type = load_int(table + current_symbol + 6)
	if (type_num_args(declared_return_type) > 0):
		number_of_args = 1
	int param_count = 0
	int saw_default = 0
	int is_w_variadic = 0
	int function_start = codepos /* keep track of start for length comp */
	while (accept(c")") == 0):
		if (is_w_variadic):
			error(c"variadic parameter must be the last parameter")
		param_count = param_count + 1
		number_of_args = number_of_args + 1
		int type = type_name()
		# "T... name" declares a W variadic function: the callee sees the
		# trailing arguments as a T[] slice parameter.
		if (accept(c".")):
			expect(c".")
			expect(c".")
			if (saw_default):
				error(c"a variadic parameter cannot follow parameters with default values")
			if (param_count > sym_max_param_slots()):
				error(c"variadic functions support at most 10 parameters")
			int elem = type_unqualified(type)
			if ((type_num_args(elem) > 0) | type_is_array(elem) | type_is_slice(elem) |
					type_is_map(elem) | type_is_set(elem) | type_is_list(elem) |
					(type_get_size(elem) != word_size)):
				error(c"variadic parameter element type must be word-sized")
			if (type_is_var(elem)):
				error(c"variadic parameter element type cannot be var")
			type = type_get_slice(type)
			is_w_variadic = 1
		if (type_is_array(type)):
			error(c"fixed array parameter is not implemented; use T[] instead")
		# Record the declared type so call sites can check arguments
		if (param_count <= sym_max_param_slots()):
			save_int(table + current_symbol + 22 + (param_count << 2), type)
		/* this seems stupid, you could just have (typename) with no identifier */
		if (peek(c")") == 0):
			sym_declare(token, type, 'A', number_of_args, 1)
			pointer_indirection = 0
			get_token()

		# A by-value aggregate occupies several stack words; later
		# parameters address past all of them
		int arg_words = type_stack_words(type)
		if (arg_words > 1):
			number_of_args = number_of_args + arg_words - 1

		# "= constant" records a default; call sites push it for missing
		# trailing arguments. Once one parameter has a default, all that
		# follow must too.
		if (accept(c"=")):
			if (is_w_variadic):
				error(c"a variadic parameter cannot have a default value")
			if (type_is_var(type_unqualified(type))):
				error(c"default values are not supported on var parameters")
			if (param_count > sym_max_param_slots()):
				error(c"default values are only supported on the first 10 parameters")
			int default_value = parse_constant_default()
			if (saw_default == 0):
				# This declaration's defaults replace any recorded earlier
				# (a definition overrides its prototype)
				sym_clear_param_defaults(current_symbol)
			saw_default = 1
			sym_set_param_default(current_symbol, param_count - 1, default_value)
		else if (saw_default):
			error(c"parameter without a default follows a parameter with a default")

		accept(c",") /* ignore trailing comma */

	# Record the arity for call-site checks (definitions overwrite
	# whatever an earlier prototype recorded)
	save_int(table + current_symbol + 22, param_count)
	if (is_w_variadic):
		sym_set_w_variadic(current_symbol, param_count - 1)
	else:
		sym_set_w_variadic(current_symbol, -1)

	if (accept(c";") == 0):
		be_function_define(current_symbol, last_global_declaration)
		# On arm64 sign and push the return address (x30) onto the W stack
		# so the callee has the same [return-slot | args] layout the x86
		# backend relies on; emits nothing on the x86 family. On wasm this
		# opens the function's size-prefixed code-section unit.
		be_function_prologue()
		current_function_symbol = current_symbol
		enclosing_tab_level = 0
		# Record the argument word count for the debugger's
		# runtime argument addressing
		debug_func_note(function_start, number_of_args)
		# Fall-through defers are emitted when the body block closes,
		# while its locals are still in scope: arm the flag statement()
		# consumes when it opens the body block.
		defer_reset()
		defer_function_body_pending = 1
		statement()
		defer_reset()
		ret()
		be_function_epilogue()
		# Store length to symbol table:
		save_int(table + current_symbol + 14, codepos - function_start)

	table_pos = n


void emit_global_type_storage(int type);
void emit_global_storage(int type);
void emit_data_global_storage(int type, int base_vaddr);


int global_storage_size(int type):
	int bytes = word_size
	int declared_size = type_get_size(type)
	if ((type_num_args(type) > 0) | (declared_size > word_size)):
		bytes = declared_size
	return ((bytes + word_size - 1) >> word_size_log2) << word_size_log2


# Define a mutable global variable's symbol and reserve its storage. With
# the W^X split active (data_split, set for the arm64 file target), storage
# goes into the RW data segment so the executable image stays read-execute;
# otherwise it stays inline in the single image, as before. Read-only
# globals (enum constants, string/JSON blobs) keep using the code segment.
void define_global_variable(int current_symbol, int decl_type):
	if (data_split == 0):
		sym_define_global(current_symbol)
		emit_global_storage(decl_type)
		return
	# Reserve the whole record up front so the symbol's address is the data
	# segment vaddr of its first byte, then fill in the fields.
	int bytes = global_storage_size(decl_type)
	int base_vaddr = emit_data_zeros(bytes)
	sym_define_global_at(current_symbol, base_vaddr)
	emit_data_global_storage(decl_type, base_vaddr)


# Initialize array descriptors inside an already-zeroed data-segment record
# at virtual address `vaddr`. Mirrors emit_global_type_storage's recursion:
# a fixed array gets its {data-pointer, length} header (the payload sits
# right after it), and a struct recurses into each field at its layout
# offset. Scalars stay zero. base_vaddr - data_offset maps a vaddr back to
# the data buffer.
void emit_data_global_storage(int type, int vaddr):
	if (type_is_array(type)):
		save_i(data + (vaddr - data_offset), vaddr + 2 * word_size, word_size)
		save_i(data + (vaddr - data_offset + word_size), type_get_array_length(type), word_size)
		# The header's data pointer is an absolute vaddr in the RW data
		# segment: record it so the entry stub slides it under PIE
		# (data_split only runs for the arm64 targets).
		rebase_note(vaddr)
	else if (type_num_args(type) > 0):
		int i = 0
		while (i < type_num_args(type)):
			emit_data_global_storage(type_get_field_type_at(type, i), vaddr + type_get_field_offset_at(type, i))
			i = i + 1


void emit_global_storage(int type):
	int bytes = global_storage_size(type)
	int start = codepos
	emit_global_type_storage(type)
	emit_zeros(bytes - (codepos - start))


void emit_global_type_storage(int type):
	if (type_is_array(type)):
		emit_target_word(code_offset + codepos + 2 * word_size)
		emit_target_word(type_get_array_length(type))
		emit_zeros(type_get_size(type) - 2 * word_size)
	else if (type_num_args(type) > 0):
		int i = 0
		while (i < type_num_args(type)):
			emit_global_type_storage(type_get_field_type_at(type, i))
			i = i + 1
	else:
		emit_zeros(type_get_size(type))


# 1 when the current top-level token cannot open a declaration, so it
# must begin script mode's implicit main (docs/projects/golf_ergonomics.md).
# Everything a declaration can start with stays on the declaration path:
# type names (including const/container/generic-struct types), generator
# definitions and the 'name name' / 'name* name' shape of a definition
# whose return type is not yet known (generic type parameters like
# 'T identity[T](T x)'). Statement keywords, calls, assignments and
# 'name :=' declarations all fall through to script mode.
int script_statement_starts_here():
	if (peek(c"const")):
		return 0
	if (peek(c"map") & (nextc == '[')):
		return 0
	if (peek(c"set") & (nextc == '[')):
		return 0
	if (peek(c"list") & (nextc == '[')):
		return 0
	if (type_lookup(token) >= 0):
		return 0
	if (generic_type_starts_here()):
		return 0
	if (peek(c"generator") & (nextc != '*')):
		return 0
	# Statement keywords are never declaration starts
	if (peek(c"if") | peek(c"while") | peek(c"for") | peek(c"switch") |
			peek(c"return") | peek(c"break") | peek(c"continue") | peek(c"yield") |
			peek(c"pass") | peek(c"debugger") | peek(c"defer")):
		return 1
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		return 1
	# 'name name' or 'name * name' is the shape of a declaration whose
	# type this pass cannot know yet (a generic definition's return type
	# parameter); no statement juxtaposes two identifiers, so scan one
	# step ahead with the reparse save/seek/restore trick.
	char* save = generic_reparse_save()
	get_token()
	while (accept(c"*")) {}
	int c1 = token[0]
	int next_is_ident = (('a' <= c1) & (c1 <= 'z')) | (('A' <= c1) & (c1 <= 'Z')) | (c1 == '_')
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	if (next_is_ident):
		return 0
	return 1


# 1 for tokens that always open a declaration; script mode rejects them
# after the first top-level statement with a clear error instead of the
# confusing expression-parse failure they would produce.
int script_declaration_keyword():
	if (peek(c"import") | peek(c"struct") | peek(c"union") | peek(c"enum")):
		return 1
	if (peek(c"extern") | peek(c"c_lib") | peek(c"c_import")):
		return 1
	if (peek(c"generator") & (nextc != '*')):
		return 1
	return 0


# 1 when the upcoming statement has the 'type stars name (' shape of a
# function definition, which cannot appear after the first top-level
# statement; the scan-ahead gives it a clear diagnostic instead of the
# statement parser's confusing "';' expected, found '('".
int script_function_definition_ahead():
	if ((peek(c"const") | (type_lookup(token) >= 0) | generic_type_starts_here()) == 0):
		return 0
	char* save = generic_reparse_save()
	get_token()
	while (accept(c"*")) {}
	int c1 = token[0]
	int next_is_ident = (('a' <= c1) & (c1 <= 'z')) | (('A' <= c1) & (c1 <= 'Z')) | (c1 == '_')
	int is_definition = 0
	if (next_is_ident):
		if (nextc == '('):
			is_definition = 1
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	return is_definition


/*
Script mode: top-level statements compile into an implicit

	int main():

so tiny programs need no entry-point boilerplate. The first top-level
token that cannot start a declaration opens the function; every
remaining token in the file must belong to a statement (v1 keeps the
single-pass emitter simple: declarations must come before the first
top-level statement). The implicit main plugs into the normal entry
chain: lib.lib's _main calls it when the prelude or an import pulled
lib.lib in, and the ELF entry's direct 'main' fallback covers programs
that never imported anything.
*/
void script_main():
	int int_type = type_lookup(c"int")
	int current_symbol = sym_declare_global(c"main", int_type, 2)
	int n = table_pos
	number_of_args = 0
	int function_start = codepos
	save_int(table + current_symbol + 22, 0) /* param_count */
	sym_set_w_variadic(current_symbol, -1)
	be_function_define(current_symbol, c"main")
	be_function_prologue()
	current_function_symbol = current_symbol
	enclosing_tab_level = 0
	debug_func_note(function_start, number_of_args)
	defer_reset()
	while (token[0] != 0):
		if (script_declaration_keyword()):
			error(c"declarations must come before the first top-level statement")
		if (script_function_definition_ahead()):
			error(c"declarations must come before the first top-level statement")
		statement()
	# Fall-through exit: run deferred statements, then return 0
	defer_emit_all()
	defer_reset()
	be_pop(stack_pos)
	stack_pos = 0
	mov_eax_int(0)
	ret()
	be_function_epilogue()
	save_int(table + current_symbol + 14, codepos - function_start)
	table_pos = n


void program():
	int current_symbol
	while (token[0]):
		# First handle imports
		while (import_statement() ) {}
		while (c_import_statement()) {}

		# Type aliases must be available before structs and declarations.
		# Aliases and aggregates may appear in any order (e.g. a type alias
		# right after a struct), so keep dispatching until none make progress.
		int parsed_declaration = 1
		while (parsed_declaration):
			parsed_declaration = 0
			while(type_alias_declaration()):
				parsed_declaration = 1
			while(struct_declaration()):
				parsed_declaration = 1
				print_int_v1(c"struct_declaration=1", 1)
			while(union_declaration()):
				parsed_declaration = 1
				print_int_v1(c"union_declaration=1", 1)
			while(enum_declaration()):
				parsed_declaration = 1
				print_int_v1(c"enum_declaration=1", 1)

		# Shared-library declarations (c_lib / extern)
		while (extern_statement()) {}

		# Imports/structs may have consumed the rest of the file
		if (token[0] == 0):
			return;

		# Script mode: a token that cannot start a declaration begins
		# the implicit main; it consumes the rest of the file
		if (script_statement_starts_here()):
			script_main()
			return;

		# 'defer' is only meaningful inside a function body
		if (peek(c"defer")):
			error(c"'defer' outside of a function")

		# generator declarations: "generator type-name identifier (".
		# "generator*" is the struct type in a variable declaration, so
		# only a bare 'generator' token marks a declaration.
		if (peek(c"generator")):
			if (nextc != '*'):
				generator_declaration()
				continue;

		# Generic function definitions ('T max[T](T a, T b):'): the scan
		# looks ahead past the return type for 'name[', capturing and
		# skipping the definition when it matches. When it does not, the
		# scanned tokens are rebuilt into generic_scanned_type and the
		# declared name is the current token (see grammar/generic.w).
		if (generic_declaration_scan()):
			continue;

		# Now global variables + functions
		# TODO: variables THEN functions, not both
		int decl_type = generic_scanned_type
		if (decl_type < 0):
			decl_type = type_name()
		# 'operator' is a contextual keyword: followed by an operator
		# token it defines an overload (grammar/operator_overload.w);
		# otherwise it stays an ordinary declared name.
		if (peek(c"operator")):
			get_token()
			if (operator_definition_starts_here()):
				operator_definition(decl_type)
				continue;
			current_symbol = sym_declare_global(c"operator", decl_type, 1)
		else:
			current_symbol = sym_declare_global(token, decl_type, 1)
			get_token()
		if (accept(c";")):
			define_global_variable(current_symbol, decl_type)

		else if (accept(c"(")):
			function_definition(current_symbol)

		else:
			/*error(8)*/
			define_global_variable(current_symbol, decl_type)
