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
# Forward declaration: defhash_note is defined in compiler/compiler.w,
# which compiles after grammar/.
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset);


# Compile-time constant expressions: global initializers, parameter
# defaults and enum values. The C integer-constant-expression subset
#
#   or    := xor ('|' xor)*          xor   := and ('^' and)*
#   and   := shift ('&' shift)*      shift := add (('<<' | '>>') add)*
#   add   := mul (('+' | '-') mul)*  mul   := unary (('*' | '/' | '%') unary)*
#   unary := ('-' | '+' | '~') unary | primary
#   primary := int literal (decimal, hex, binary) | char literal
#            | true | false | enum constant | const-qualified global
#            | sizeof(T) | __word_size__ | '(' or ')'
#
# folds in 32-bit signed arithmetic (the int-literal convention, so a
# 32- and a 64-bit-hosted compiler agree): a result that does not fit,
# a shift count outside 0..31 and division by zero are errors. A
# binary operator on a new line ends the expression (the next
# declaration or script statement starts there). const_what/const_name
# name the construct in diagnostics.
char* const_what
char* const_name
int const_paren_depth


void const_error_prefix():
	diag_part(const_what)
	if (const_name):
		diag_part(c" '")
		diag_part(const_name)
		diag_part(c"'")


void const_error(char* why):
	const_error_prefix()
	diag_part(c": ")
	error(why)


# 32-bit two's-complement range check on a 64-bit host (always true on
# a 32-bit host, where the sign checks below catch the wrap).
int const_fits32(int v):
	return (v >= -2147483647 - 1) && (v <= 2147483647)


int const_checked(int v, int overflowed):
	if (overflowed || (const_fits32(v) == 0)):
		const_error(c"constant expression overflows 32 bits")
	return v


# The int32 stored at a defined enum constant's or const global's
# address (the enum declaration and write_global_initial_value put
# them there), or error when the symbol is neither.
int const_symbol_value(int t):
	int is_object = 0
	if (t >= 0):
		is_object = (table[t + 1] == 'D') && (load_int(table + t + 10) == 1)
	if (is_object):
		int type = load_int(table + t + 6)
		int addr = load_int(table + t + 2)
		if (type_get_kind(type) == type_kind_enum):
			# in the code stream on the native targets, in the data
			# segment on wasm (enum_declaration.w)
			if (target_isa == 2):
				return load_int32(data + (addr - data_offset))
			return load_int32(code + addr - code_offset)
		int t_real = type_unqualified(type)
		if (type_is_const(type) && (value_class(t_real) == VC_INT)):
			char* p = code + addr - code_offset
			if (data_split):
				p = data + (addr - data_offset)
			int size = type_get_size(t_real)
			if (size == 1):
				if (type_is_unsigned_fixed(t_real)):
					return p[0] & 255
				return p[0]
			if (size == 2):
				int v = (p[0] & 255) | (p[1] << 8)
				if (type_is_unsigned_fixed(t_real)):
					return v & 65535
				return v
			return load_int32(p)
	const_error_prefix()
	diag_part(c" must be a compile-time constant, got '")
	diag_part(token)
	error(c"'")
	return 0


int const_or();


int const_primary():
	int value = 0
	if (accept(c"(")):
		const_paren_depth = const_paren_depth + 1
		value = const_or()
		const_paren_depth = const_paren_depth - 1
		if (peek(c")") == 0):
			const_error(c"')' expected in constant expression")
	else if (accept(c"sizeof")):
		expect(c"(")
		value = type_get_size(type_name())
		if (peek(c")") == 0):
			const_error(c"')' expected after sizeof type")
	else if (peek(c"__word_size__")):
		value = word_size
	else if (peek(c"true")):
		value = 1
	else if (peek(c"false")):
		value = 0
	# char literal e.g. 'c', '\n' or '\x41'; grammar/string_literal.w
	# decodes and validates the token
	else if (token[0] == 39):
		value = char_literal_value()
	else if ((token[0] == '0') && ((token[1] == 'x') || (token[1] == 'b'))):
		int_literal_width_check()
		if (token[1] == 'x'):
			value = from_hex(token + 2)
		else:
			int i = 2
			while (token[i]):
				value = (value << 1) + token[i] - '0'
				i = i + 1
		value = int_literal_wrap32(value)
	else if (('0' <= token[0]) && (token[0] <= '9')):
		int_literal_decimal_check()
		value = int_literal_wrap32(atoi(token))
	else:
		value = const_symbol_value(sym_lookup(token))
	get_token()
	return value


int const_unary():
	if (accept(c"-")):
		int v = const_unary()
		return const_checked(0 - v, (v != 0) && (v == 0 - v))
	if (accept(c"+")):
		return const_unary()
	if (accept(c"~")):
		return ~const_unary()
	return const_primary()


# 1 when the current token is binary operator op and continues the
# expression (not the start of the next line outside parentheses).
int const_binary(char* op):
	if (token_newline && (const_paren_depth == 0)):
		return 0
	return accept(op)


int const_min32():
	return -2147483647 - 1


int const_mul():
	int a = const_unary()
	while (1):
		int b
		if (const_binary(c"*")):
			b = const_unary()
			int r = a * b
			# r / a never runs as MIN / -1, which traps on a 32-bit host
			int overflowed = 0
			if (a != 0):
				if (((a == -1) && (b == const_min32())) || ((b == -1) && (a == const_min32()))):
					overflowed = 1
				else:
					overflowed = r / a != b
			a = const_checked(r, overflowed)
		else if (const_binary(c"/")):
			b = const_unary()
			if (b == 0):
				const_error(c"division by zero in constant expression")
			a = const_checked(a / b, (a == const_min32()) && (b == -1))
		else if (const_binary(c"%")):
			b = const_unary()
			if (b == 0):
				const_error(c"division by zero in constant expression")
			if (b == -1):
				a = 0
			else:
				a = a % b
		else:
			return a


int const_add():
	int a = const_mul()
	while (1):
		int b
		int r
		if (const_binary(c"+")):
			b = const_mul()
			r = a + b
			a = const_checked(r, ((a ^ r) & (b ^ r)) < 0)
		else if (const_binary(c"-")):
			b = const_mul()
			r = a - b
			a = const_checked(r, ((a ^ b) & (a ^ r)) < 0)
		else:
			return a


int const_shift_count():
	int n = const_add()
	if ((n < 0) || (n > 31)):
		const_error(c"shift count must be 0..31 in a constant expression")
	return n


int const_shift():
	int a = const_add()
	while (1):
		int n
		if (const_binary(c"<<")):
			n = const_shift_count()
			int r = a << n
			a = const_checked(r, (r >> n) != a)
		else if (const_binary(c">>")):
			n = const_shift_count()
			a = a >> n
		else:
			return a


int const_and():
	int a = const_shift()
	while (const_binary(c"&")):
		a = a & const_shift()
	return a


int const_xor():
	int a = const_and()
	while (const_binary(c"^")):
		a = a ^ const_and()
	return a


int const_or():
	int a = const_xor()
	while (const_binary(c"|")):
		a = a | const_xor()
	return a


# Parse and fold the constant expression at the current token; `what`
# (and `name`, when nonzero) name the construct in diagnostics. Leaves
# the token after the expression current.
int parse_constant_literal(char* what, char* name):
	char* outer_what = const_what
	char* outer_name = const_name
	int outer_depth = const_paren_depth
	const_what = what
	const_name = name
	const_paren_depth = 0
	int value = const_or()
	const_what = outer_what
	const_name = outer_name
	const_paren_depth = outer_depth
	return value


# Parse the compile-time constant after '=' in a parameter declaration.
int parse_constant_default():
	int value = parse_constant_literal(c"default value for parameter", 0)
	if ((peek(c",") == 0) & (peek(c")") == 0)):
		error(c"default value for parameter must be a single compile-time constant")
	return value


# Records the constant after a parameter's '=' (already consumed) as the
# default of parameter param_count (1-based) of the function at
# current_symbol; returns the new saw_default (1). The first default of
# a declaration replaces any recorded earlier (a definition overrides
# its prototype).
int param_default_record(int current_symbol, int param_count, int saw_default):
	if (param_count > sym_max_param_slots):
		error(c"default values are only supported on the first 10 parameters")
	int default_value = parse_constant_default()
	if (saw_default == 0):
		sym_clear_param_defaults(current_symbol)
	sym_set_param_default(current_symbol, param_count - 1, default_value)
	return 1


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
			if (param_count > sym_max_param_slots):
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
		if (param_count <= sym_max_param_slots):
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
			saw_default = param_default_record(current_symbol, param_count, saw_default)
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
		# backend relies on. On x86/x64 push ebp ; mov ebp,esp to keep the
		# frame-pointer chain lib/stack_trace.w walks. On wasm this opens
		# the function's size-prefixed code-section unit.
		be_function_prologue()
		# x86/x64: the saved frame pointer is one more word on the W stack
		int frame_words = be_frame_words()
		stack_pos = stack_pos + frame_words
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
		int outer_label_base = goto_label_base
		int outer_pending_base = goto_pending_base
		goto_scope_begin()
		statement()
		goto_scope_end(outer_label_base, outer_pending_base)
		defer_reset()
		be_return_bare()
		be_function_epilogue()
		stack_pos = stack_pos - frame_words
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
# the W^X split active (data_split, set for every file target), storage
# goes into the RW data segment so the executable image stays read-execute;
# otherwise (the in-process REPL/wdbg path) it stays inline in the single
# executed buffer, as before. Read-only globals (enum constants,
# string/JSON blobs) keep using the code segment.
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
		# segment: record it so the entry stub slides it under PIE. Only
		# the arm64 writers emit the table; for the fixed-base x86/x64/
		# win64 splits the note is a harmless no-op (nothing walks it).
		rebase_note(vaddr)
	else if (type_num_args(type) > 0):
		int i = 0
		while (i < type_num_args(type)):
			emit_data_global_storage(type_get_field_type_at(type, i), vaddr + type_get_field_offset_at(type, i))
			i = i + 1


# Store a top-level declaration's constant initializer into the storage
# define_global_variable just reserved. The symbol's recorded address is
# a vaddr in whichever segment holds it — the data segment under the W^X
# split, the code image otherwise (the same two cases
# parse_constant_literal reads an enum constant back from).
void write_global_initial_value(int current_symbol, int type, int value):
	int addr = load_int(table + current_symbol + 2)
	int bytes = word_size
	int declared_size = type_get_size(type)
	if ((type_get_pointer_level(type) == 0) & (declared_size > 0) & (declared_size < word_size)):
		bytes = declared_size
	if (data_split):
		save_i(data + (addr - data_offset), value, bytes)
	else:
		save_i(code + (addr - code_offset), value, bytes)


# Reject value shapes whose storage is not a single scalar word: their
# initializer would have to run code (descriptors, element copies), which
# a top-level declaration has no place to run.
void global_initializer_check_type(char* name, int type):
	int t = type_canonical(type)
	int ok = 1
	if (type_num_args(t) > 0):
		ok = 0
	if (type_is_array(t) | type_is_slice(t)):
		ok = 0
	if (type_is_map(t) | type_is_set(t) | type_is_list(t)):
		ok = 0
	if (type_is_string(t)):
		ok = 0
	if (type_float_kind(t)):
		ok = 0
	if (ok):
		return;
	diag_part(c"cannot initialize global '")
	diag_part(name)
	error_type(c"' of type '", type, c"' at its declaration; assign it inside a function")


# 'int x = 5' at file scope: a global declaration carrying a compile-time
# constant initializer, stored straight into the global's reserved bytes
# (the C model — no init code runs before main). This exists so a REPL
# session's own spelling round-trips: ':save' writes the entries verbatim
# and the saved file has to compile standalone (docs/projects/repl.md).
# Non-constant initializers are rejected here with a diagnostic naming
# the global, instead of the bare "valid primary expression" parse error
# the '=' used to produce.
void global_initializer(char* name, int current_symbol, int decl_type):
	global_initializer_check_type(name, decl_type)
	int value = parse_constant_literal(c"initializer for global", name)
	write_global_initial_value(current_symbol, decl_type, value)


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
	# 'alias.TypeName name' opens a declaration through the qualified
	# type spelling (grammar/import_statement.w)
	if (import_alias_type_ahead(0) >= 0):
		return 0
	if (peek(c"generator") & (nextc != '*')):
		return 0
	# Statement keywords are never declaration starts
	if (peek(c"if") | peek(c"while") | peek(c"for") | peek(c"switch") |
			peek(c"return") | peek(c"break") | peek(c"continue") | peek(c"yield") |
			peek(c"pass") | peek(c"debugger") | peek(c"defer")):
		return 1
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
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
	int next_is_ident = is_ident_start_byte(c1)
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
	# 'message Name:' (grammar/protobuf_builtin.w), unless shadowed
	if (peek(c"message") & (nextc == ' ')):
		if ((type_lookup(token) < 0) & (sym_lookup(token) < 0)):
			return 1
	if (peek(c"generator") & (nextc != '*')):
		return 1
	# 'kernel name(...)' is a declaration unless a user type or symbol
	# named 'kernel' shadows the marker (e.g. 'kernel = 5' assigning to
	# a global of that name stays a statement).
	if (peek(c"kernel")):
		if ((type_lookup(token) < 0) & (sym_lookup(token) < 0)):
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
	int next_is_ident = is_ident_start_byte(c1)
	int is_definition = 0
	if (next_is_ident):
		if (nextc == '('):
			is_definition = 1
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	return is_definition


# An 'export'-marked definition on the wasm target: derive the wasm
# signature classes from the declared parameter and return types (the
# extern-statement conventions: word-sized scalars and pointers are i32,
# float32 is f32) and register the function for the module's export
# section, where it becomes a host-callable real-signature export
# (code_generator/wasm_module.w). The native targets have no
# per-function export surface, so the marker is a no-op there.
void export_function_note(int t, char* name, int ret_type):
	if (target_isa != 2):
		return;
	if (sym_w_variadic_fixed_args(t) >= 0):
		error(c"cannot export a variadic function")
	int n = sym_num_args(t)
	if (n > sym_max_param_slots):
		error(c"exported functions support at most 10 parameters")
	if ((type_num_args(ret_type) > 0) & (type_get_pointer_level(ret_type) == 0)):
		error(c"cannot export a function returning a struct by value")
	int ret_kind = 1
	if (ffi_type_class(ret_type) == 1):
		ret_kind = 2
	if (type_get_pointer_level(ret_type) == 0):
		if (strcmp(type_get_name(ret_type), c"void") == 0):
			ret_kind = 0
	char* classes = malloc(n + 1)
	int i = 0
	while (i < n):
		int ptype = sym_param_type(t, i)
		if (type_stack_words(ptype) != 1):
			error(c"exported function parameters must be single words")
		classes[i] = 0
		if (ffi_type_class(ptype) == 1):
			classes[i] = 1
		i = i + 1
	wasm_export_add(t, name, n, classes, ret_kind)
	free(classes)


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
	stack_pos = stack_pos + be_frame_words()
	current_function_symbol = current_symbol
	enclosing_tab_level = 0
	debug_func_note(function_start, number_of_args)
	defer_reset()
	int outer_label_base = goto_label_base
	int outer_pending_base = goto_pending_base
	goto_scope_begin()
	while (token[0] != 0):
		if (script_declaration_keyword()):
			error(c"declarations must come before the first top-level statement")
		if (script_function_definition_ahead()):
			error(c"declarations must come before the first top-level statement")
		statement()
	goto_scope_end(outer_label_base, outer_pending_base)
	# Fall-through exit: run deferred statements, then return 0
	defer_emit_all()
	defer_reset()
	if (be_frame_words()):
		mov_eax_int(0)
		be_return(stack_pos)
	else:
		be_pop(stack_pos)
		mov_eax_int(0)
		ret()
	stack_pos = 0
	be_function_epilogue()
	save_int(table + current_symbol + 14, codepos - function_start)
	table_pos = n


# 1 when a thread_local of this type would need storage initialized at
# startup: a fixed array's {data, length} header points into the
# variable's own storage, which differs per thread. Scalars, pointers and
# structs of them are all-zero at startup, which is what a fresh TLS
# block holds.
int thread_local_type_needs_init(int type):
	if (type_is_array(type)):
		return 1
	int i = 0
	while (i < type_num_args(type)):
		if (thread_local_type_needs_init(type_get_field_type_at(type, i))):
			return 1
		i = i + 1
	return 0


# 'thread_local type name' at top level (docs/projects/thread_local.md):
# every thread gets its own zero-initialized copy. The variable's
# symbol value is its byte offset in the per-thread TLS block (word 0 is
# the block's self pointer); sym_get_value turns it into an address
# through gs (x64) / fs (x86), the register libc leaves alone. The main thread's block lives in the data
# segment and is installed by the entry thunk elf_finish_entry_patch
# emits; lib/thread.w installs one per spawned thread.
void thread_local_declaration():
	if ((target_isa != 0) || (target_os != 0)):
		error(c"thread_local is only supported on the x86 and x64 Linux targets")
	if (data_split == 0):
		error(c"thread_local is not supported in the REPL or debugger")
	int start = token_start_offset
	int decl_type = type_name()
	if (thread_local_type_needs_init(decl_type)):
		error(c"thread_local fixed arrays are not supported; use a pointer")
	char* name = strclone(token)
	int line = diag_token_line
	int column = diag_token_column
	int current_symbol = sym_declare_global(token, decl_type, 1)
	get_token()
	if (peek(c"(")):
		error(c"thread_local applies to variables, not functions")
	if (peek(c"=")):
		error(c"thread_local variables cannot have an initializer; they start zeroed")
	accept(c";")
	if (tls_size == 0):
		tls_size = word_size  /* word 0: the block's self pointer */
	int offset = tls_size
	tls_size = tls_size + global_storage_size(decl_type)
	sym_define_global_at(current_symbol, offset)
	sym_set_thread_local(current_symbol)
	defhash_note(name, c"global", decl_file_index(), line, column, start, token_start_offset)


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
			while(message_declaration()):
				parsed_declaration = 1

		# Shared-library declarations (c_lib / extern). Anything may follow
		# an extern block, so go around again: a type alias or struct right
		# after the last extern would otherwise reach the function/global
		# declaration parser below ("unknown type name: 'type'").
		int parsed_extern = 0
		while (extern_statement()):
			parsed_extern = 1
		if (parsed_extern):
			continue

		# Imports/structs may have consumed the rest of the file
		if (token[0] == 0):
			return;

		# 'export' marks the next function definition as a host-callable
		# module export with its real typed signature on the wasm target
		# (export_function_note above); the native targets accept and
		# ignore the marker, so one source compiles everywhere. Contextual
		# like 'kernel': a type or symbol named 'export' keeps the
		# identifier meaning.
		int export_pending = 0
		if (peek(c"export")):
			if ((type_lookup(token) < 0) & (sym_lookup(token) < 0)):
				get_token()
				export_pending = 1
				if ((peek(c"const") | (type_lookup(token) >= 0)) == 0):
					error(c"'export' must be followed by a function definition")

		# Script mode: a token that cannot start a declaration begins
		# the implicit main; it consumes the rest of the file
		if (script_statement_starts_here()):
			script_main()
			return;

		# 'defer' is only meaningful inside a function body
		if (peek(c"defer")):
			error(c"'defer' outside of a function")

		# 'thread_local type name': contextual like 'kernel', so a type
		# or symbol named thread_local keeps the identifier meaning.
		if (peek(c"thread_local")):
			if ((type_lookup(token) < 0) & (sym_lookup(token) < 0)):
				get_token()
				thread_local_declaration()
				continue;

		# generator declarations: "generator type-name identifier (".
		# "generator*" is the struct type in a variable declaration, so
		# only a bare 'generator' token marks a declaration.
		if (peek(c"generator")):
			if (nextc != '*'):
				generator_declaration()
				continue;

		# Captured here, before the generic scan-ahead, so it is the true
		# start of the declaration in both of generic_declaration_scan's
		# outcomes: a real generic (which 'continue's below, never
		# reaching defhash_note) or a plain declaration whose return type
		# it already scanned into generic_scanned_type (in which case
		# token itself has moved on to the declared name, so capturing
		# this any later would miss the return-type tokens).
		int defhash_start = token_start_offset
		# kernel declarations: "kernel identifier (" (implicit void
		# return). A user type or symbol named 'kernel' shadows the
		# marker, like the limb-intrinsic shadowing rule. Like generics,
		# kernel declarations 'continue' without reaching defhash_note.
		if (peek(c"kernel")):
			if ((type_lookup(token) < 0) & (sym_lookup(token) < 0)):
				kernel_declaration()
				continue;

		# Generic function definitions ('T max[T](T a, T b):'): the scan
		# looks ahead past the return type for 'name[', capturing and
		# skipping the definition when it matches. When it does not, the
		# scanned tokens are rebuilt into generic_scanned_type and the
		# declared name is the current token (see grammar/generic.w).
		if (generic_declaration_scan()):
			if (export_pending):
				error(c"'export' is not supported on generic functions")
			continue;

		# Now global variables + functions
		# TODO: variables THEN functions, not both
		int decl_type = generic_scanned_type
		if (decl_type < 0):
			decl_type = type_name()
		# defhash (docs/projects/build_system_next.md 4a): name/line/column
		# of the plain declaration below; the 'operator' overload branch
		# sets its own (wave plan C task 4f) since the real declared
		# symbol name, "operator", is shared by every overload in the
		# file and cannot be the recorded defhash name -- see
		# operator_definition's synthetic name (grammar/operator_overload.w).
		char* defhash_name = 0
		int defhash_line = 0
		int defhash_column = 0
		# 'operator' is a contextual keyword: followed by an operator
		# token it defines an overload (grammar/operator_overload.w);
		# otherwise it stays an ordinary declared name.
		if (peek(c"operator")):
			defhash_line = diag_token_line
			defhash_column = diag_token_column
			get_token()
			if (operator_definition_starts_here()):
				if (export_pending):
					error(c"'export' is not supported on operator overloads")
				char* defhash_op_name = operator_definition(decl_type)
				defhash_note(defhash_op_name, c"operator", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)
				continue;
			current_symbol = sym_declare_global(c"operator", decl_type, 1)
		else:
			defhash_name = strclone(token)
			defhash_line = diag_token_line
			defhash_column = diag_token_column
			current_symbol = sym_declare_global(token, decl_type, 1)
			get_token()
		if (accept(c";")):
			if (export_pending):
				error(c"only functions can be exported")
			define_global_variable(current_symbol, decl_type)
			if (defhash_name != 0):
				defhash_note(defhash_name, c"global", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)

		else if (accept(c"(")):
			function_definition(current_symbol)
			if (export_pending):
				char* export_name = defhash_name
				if (export_name == 0):
					export_name = c"operator"
				export_function_note(current_symbol, export_name, decl_type)
			if (defhash_name != 0):
				defhash_note(defhash_name, c"function", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)

		else if (accept(c"=")):
			if (export_pending):
				error(c"only functions can be exported")
			define_global_variable(current_symbol, decl_type)
			# defhash_name is 0 only on the 'operator' branch above,
			# which declared that literal name
			char* init_name = defhash_name
			if (init_name == 0):
				init_name = c"operator"
			global_initializer(init_name, current_symbol, decl_type)
			if (defhash_name != 0):
				defhash_note(defhash_name, c"global", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)

		else:
			/*error(8)*/
			if (export_pending):
				error(c"only functions can be exported")
			define_global_variable(current_symbol, decl_type)
			if (defhash_name != 0):
				defhash_note(defhash_name, c"global", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)
