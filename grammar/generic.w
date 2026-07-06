/*
Generics with explicit instantiation (docs/projects/generics.md).

A generic definition ('T max[T](T a, T b):' or 'struct pair[T]:') is not
compiled where it appears. Instead its source span (file path + byte
offset, from the tokenizer's token_start_offset) is recorded in a
registry and the definition's tokens are skipped. Each explicit
instantiation ('max[int](...)' / 'pair[int]') re-parses the recorded
span with a substitution table binding the type parameters to the type
arguments, producing an ordinary monomorphic function or struct under a
mangled name ('max$int', 'pair$int'). '$' cannot appear in a source
identifier, so mangled names can never collide with user symbols.

Struct instantiations only fill the type table (no code is emitted), so
they run eagerly, nested inside whatever parse triggered them - the same
save/restore trick compile_save() uses for imports, but re-opening the
recorded file at the recorded offset. Function instantiations emit code,
which cannot be interleaved with the function currently being compiled,
so call sites emit a mov-imm backpatch chain (the json_codec pattern)
and the bodies are compiled at a top-level boundary by
generic_finish_instantiations(), after all user files.

This file is compiled by the committed seed: only seed-understood
syntax here.
*/

# Defined later in the grammar / compiler; the single-pass compiler
# needs the declarations up front.
int type_name();
int type_name_array_suffix(int type);
void function_definition(int current_symbol);
int import_alias_lookup(char* name);


/*
Definition registry: one record per generic definition.
layout (32 bytes per entry):
	0: char* name
	4: int kind (0 function, 1 struct)
	8: char* file (path to reopen for the re-parse)
	12: int offset (byte offset of the span start)
	16: int line (0-based, for diagnostics during the re-parse)
	20: int column (0-based)
	24: int param_count
	28: char** param_names
For functions the span starts at the return type; for structs it starts
at the struct's name (after the 'struct' keyword).
*/
char* generic_defs
int generic_def_count


int generic_def_stride():
	return 32


int generic_def_max():
	return 500


int generic_max_params():
	return 8


char* generic_def_entry(int def):
	return generic_defs + def * generic_def_stride()


char* generic_def_name(int def):
	return cast(char*, load_int(generic_def_entry(def)))


int generic_def_kind(int def):
	return load_int(generic_def_entry(def) + 4)


char* generic_def_file(int def):
	return cast(char*, load_int(generic_def_entry(def) + 8))


int generic_def_offset(int def):
	return load_int(generic_def_entry(def) + 12)


int generic_def_line(int def):
	return load_int(generic_def_entry(def) + 16)


int generic_def_column(int def):
	return load_int(generic_def_entry(def) + 20)


int generic_def_param_count(int def):
	return load_int(generic_def_entry(def) + 24)


char* generic_def_param_name(int def, int i):
	int names = load_int(generic_def_entry(def) + 28)
	return cast(char*, load_int(names + (i << 2)))


# Registered generic of the given kind (0 function, 1 struct) with this
# name, or -1. Functions and structs live in separate namespaces, like
# the symbol table and the type table do.
int generic_def_lookup(char* name, int kind):
	int i = 0
	while (i < generic_def_count):
		if (generic_def_kind(i) == kind):
			if (strcmp(generic_def_name(i), name) == 0):
				return i
		i = i + 1
	return -1


int generic_def_add(char* name, int kind, char* file_path, int offset, int line, int column, int param_count, int param_names):
	if (generic_def_lookup(name, kind) >= 0):
		diag_part(c"generic '")
		diag_part(name)
		error(c"' redefined")
	if (generic_defs == 0):
		generic_defs = malloc(generic_def_max() * generic_def_stride())
	assert1(generic_def_count < generic_def_max())
	char* e = generic_defs + generic_def_count * generic_def_stride()
	save_int(e, cast(int, name))
	save_int(e + 4, kind)
	save_int(e + 8, cast(int, file_path))
	save_int(e + 12, offset)
	save_int(e + 16, line)
	save_int(e + 20, column)
	save_int(e + 24, param_count)
	save_int(e + 28, param_names)
	generic_def_count = generic_def_count + 1
	return generic_def_count - 1


/*
Function instantiation registry / queue.
layout (28 bytes per entry):
	0: char* mangled name
	4: int def (definition registry index)
	8: int* type argument indices
	12: int arg_count
	16: int chain (head of the call-site mov-imm backpatch chain, 0 none)
	20: int signature (function-signature type index, -1 until parsed)
	24: int done (1 once the body has been compiled)
*/
char* generic_insts
int generic_inst_count


int generic_inst_stride():
	return 28


int generic_inst_max():
	return 2000


char* generic_inst_entry(int inst):
	return generic_insts + inst * generic_inst_stride()


char* generic_inst_mangled(int inst):
	return cast(char*, load_int(generic_inst_entry(inst)))


int generic_inst_def(int inst):
	return load_int(generic_inst_entry(inst) + 4)


int generic_inst_args(int inst):
	return load_int(generic_inst_entry(inst) + 8)


int generic_inst_arg_count(int inst):
	return load_int(generic_inst_entry(inst) + 12)


int generic_inst_chain(int inst):
	return load_int(generic_inst_entry(inst) + 16)


void generic_inst_set_chain(int inst, int head):
	save_int(generic_inst_entry(inst) + 16, head)


int generic_inst_done(int inst):
	return load_int(generic_inst_entry(inst) + 24)


void generic_inst_set_done(int inst):
	save_int(generic_inst_entry(inst) + 24, 1)


int generic_inst_lookup(char* mangled):
	int i = 0
	while (i < generic_inst_count):
		if (strcmp(generic_inst_mangled(i), mangled) == 0):
			return i
		i = i + 1
	return -1


# Find or create the instantiation record for a mangled name. Takes
# ownership of 'mangled' and 'args' when a new record is created;
# frees them when the record already exists.
int generic_inst_intern(int def, int args, int arg_count, char* mangled):
	int existing = generic_inst_lookup(mangled)
	if (existing >= 0):
		free(mangled)
		free(cast(char*, args))
		return existing
	if (generic_insts == 0):
		generic_insts = malloc(generic_inst_max() * generic_inst_stride())
	assert1(generic_inst_count < generic_inst_max())
	char* e = generic_insts + generic_inst_count * generic_inst_stride()
	save_int(e, cast(int, mangled))
	save_int(e + 4, def)
	save_int(e + 8, args)
	save_int(e + 12, arg_count)
	save_int(e + 16, 0)
	save_int(e + 20, -1)
	save_int(e + 24, 0)
	generic_inst_count = generic_inst_count + 1
	return generic_inst_count - 1


/*
Active type-parameter substitution: consulted by type_name() before the
normal type lookup. A block is 'int count' followed by count pairs of
(char* name, int type index). 0 means no substitution is active.
Instantiations swap in their own block and restore the previous one, so
nested instantiation (a generic struct used inside another generic's
body) sees the correct bindings.
*/
char* generic_subst_block


int generic_subst_lookup(char* name):
	if (generic_subst_block == 0):
		return -1
	int n = load_int(generic_subst_block)
	int i = 0
	while (i < n):
		if (strcmp(name, cast(char*, load_int(generic_subst_block + 4 + (i << 3)))) == 0):
			return load_int(generic_subst_block + 8 + (i << 3))
		i = i + 1
	return -1


char* generic_subst_make(int def, int args, int arg_count):
	char* block = malloc(4 + (arg_count << 3))
	save_int(block, arg_count)
	int i = 0
	while (i < arg_count):
		save_int(block + 4 + (i << 3), cast(int, generic_def_param_name(def, i)))
		save_int(block + 8 + (i << 3), load_int(args + (i << 2)))
		i = i + 1
	return block


# Install a new substitution block, returning the previous one so the
# caller can restore it (and free the new one) when done.
char* generic_subst_swap(char* block):
	char* old = generic_subst_block
	generic_subst_block = block
	return old


# 1 when the current token starts a type only the generics machinery
# knows: a bound type parameter, or a generic struct instantiation
# 'name[' (the '[' must follow directly, like map[/set[/list[).
int generic_type_starts_here():
	if (generic_subst_lookup(token) >= 0):
		return 1
	if (nextc == '['):
		if (generic_def_lookup(token, 1) >= 0):
			return 1
	return 0


/*
Nested re-parse machinery: saves the complete tokenizer position so a
recorded definition span can be parsed in the middle of another parse,
exactly like compile_save() does for imports - except the "imported"
text is a span of an already-seen file, re-opened on a fresh fd and
seek()ed to the recorded offset. The outer parse's lookahead (nextc)
and current token are restored verbatim afterwards, so the outer parse
resumes as if nothing happened.
save block layout: 14 ints (56 bytes).
*/
char* generic_reparse_save():
	char* s = malloc(56)
	save_int(s, cast(int, filename))
	save_int(s + 4, file)
	save_int(s + 8, nextc)
	save_int(s + 12, line_number)
	save_int(s + 16, column_number)
	save_int(s + 20, tab_level)
	save_int(s + 24, token_newline)
	save_int(s + 28, byte_offset)
	save_int(s + 32, diag_token_line)
	save_int(s + 36, diag_token_column)
	save_int(s + 40, token_start_offset)
	save_int(s + 44, cast(int, strclone(token)))
	save_int(s + 48, pointer_indirection)
	save_int(s + 52, token_i)
	return s


void generic_reparse_restore(char* s):
	filename = cast(char*, load_int(s))
	file = load_int(s + 4)
	nextc = load_int(s + 8)
	line_number = load_int(s + 12)
	column_number = load_int(s + 16)
	tab_level = load_int(s + 20)
	token_newline = load_int(s + 24)
	byte_offset = load_int(s + 28)
	diag_token_line = load_int(s + 32)
	diag_token_column = load_int(s + 36)
	token_start_offset = load_int(s + 40)
	char* saved_token = cast(char*, load_int(s + 44))
	int n = strlen(saved_token)
	if (token_size <= n + 1):
		int x = (n + 10) << 1
		token = realloc(token, token_size, x)
		token_size = x
	strcpy(token, saved_token)
	token_i = load_int(s + 52)
	pointer_indirection = load_int(s + 48)
	free(saved_token)
	free(s)


# Open the definition's file, seek to the span start and prime the
# tokenizer: afterwards the span's first token is current.
void generic_reparse_start(int def):
	char* path = generic_def_file(def)
	file = open(path, 0, 511)
	if (file < 0):
		diag_part(c"cannot reopen generic definition file '")
		diag_part(path)
		error(c"'")
	filename = path
	seek(file, generic_def_offset(def), 0)
	byte_offset = generic_def_offset(def)
	line_number = generic_def_line(def)
	column_number = generic_def_column(def)
	tab_level = 0
	token_newline = 0
	# nextc = 0 keeps get_character() from counting the outer parse's
	# stale lookahead character into the new position
	nextc = 0
	nextc = get_character()
	get_token()


/*
Name mangling: base '$' arg1 '$' arg2 ... where each arg is the
canonical type's name with one '*' per pointer level. '$' is not a
valid identifier character, so no user symbol can collide; nested
generic arguments ('pair$int') stay unambiguous because their names
already went through the same scheme.
*/
char* generic_mangle_arg(int arg_type):
	int t = type_canonical(arg_type)
	char* name = strclone(type_get_name(t))
	int stars = type_get_pointer_level(t)
	while (stars > 0):
		char* with_star = strjoin(name, c"*")
		free(name)
		name = with_star
		stars = stars - 1
	return name


char* generic_mangle(char* base, int args, int arg_count):
	char* name = strclone(base)
	int i = 0
	while (i < arg_count):
		char* with_sep = strjoin(name, c"$")
		free(name)
		char* arg_name = generic_mangle_arg(load_int(args + (i << 2)))
		name = strjoin(with_sep, arg_name)
		free(with_sep)
		free(arg_name)
		i = i + 1
	return name


# Parse the '[T, U]' type-parameter list of a definition into an array
# of name clones (capacity generic_max_params()). Returns the count;
# the closing ']' is consumed.
int generic_parse_param_names(int params_out):
	expect(c"[")
	int n = 0
	int more = 1
	while (more):
		int c0 = token[0]
		int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
		if (is_ident == 0):
			diag_part(c"type parameter name expected, found '")
			diag_part(token)
			error(c"'")
		if (n >= generic_max_params()):
			error(c"too many type parameters")
		save_int(params_out + (n << 2), cast(int, strclone(token)))
		n = n + 1
		get_token()
		more = accept(c",")
	expect(c"]")
	return n


# Parse the '[' type ',' type ... of an instantiation. The closing ']'
# is left as the current token (callers differ in whether it should be
# consumed). Returns the argument count.
int generic_parse_type_args(int args_out, int def):
	expect(c"[")
	int n = 0
	int more = 1
	while (more):
		if (n >= generic_max_params()):
			error(c"too many type arguments")
		save_int(args_out + (n << 2), type_name())
		n = n + 1
		more = accept(c",")
	if (peek(c"]") == 0):
		diag_part(c"']' expected in type argument list, found '")
		diag_part(token)
		error(c"'")
	if (n != generic_def_param_count(def)):
		diag_part(c"wrong number of type arguments for generic '")
		diag_part(generic_def_name(def))
		diag_part(c"': expected ")
		diag_part(itoa(generic_def_param_count(def)))
		diag_part(c", got ")
		error(itoa(n))
	return n


# Skip a captured definition: the rest of the current (header) line,
# then every following line indented past the top level. Strings and
# comments are already opaque to get_token(), so skipping token by
# token is safe.
void generic_skip_definition():
	while ((token_newline == 0) & (token[0] != 0)):
		get_token()
	while ((tab_level > 0) & (token[0] != 0)):
		get_token()


/*
Struct definitions: capture. Called from struct_declaration() with the
struct's name as the current token and '[' as the next character.
*/
void generic_register_struct():
	char* name = strclone(token)
	int offset = token_start_offset
	int line = diag_token_line - 1
	int column = diag_token_column - 1
	get_token()
	int params = cast(int, malloc(generic_max_params() << 2))
	int n = generic_parse_param_names(params)
	expect(c":")
	generic_def_add(name, 1, strclone(filename), offset, line, column, n, params)
	# skip the field lines; they are re-parsed per instantiation
	while ((tab_level > 0) & (token[0] != 0)):
		get_token()


# Instantiate a generic struct: re-parse its field list with the type
# parameters bound, filling a fresh type-table record under the mangled
# name. Struct parsing emits no code, so this is safe mid-parse. No
# symbol-table entry is created: type_lookup() is what matters for
# types, and a global symbol declared mid-function would be dropped by
# function_definition's scope truncation anyway.
int generic_instantiate_struct(int def, int args, int arg_count, char* mangled):
	char* save = generic_reparse_save()
	char* old_subst = generic_subst_swap(generic_subst_make(def, args, arg_count))
	generic_reparse_start(def)
	# span starts at the struct's name; the instance uses the mangled name
	int type_index = type_push_size(mangled, 0)
	type_set_decl_location(type_index, decl_file_index(), diag_token_line, diag_token_column)
	get_token()
	expect(c"[")
	while (peek(c"]") == 0):
		get_token()
	expect(c"]")
	expect(c":")
	while ((tab_level > 0) & (token[0] != 0)):
		int field_type = type_name()
		type_add_arg(type_index, strclone(token), field_type)
		get_token()
		pointer_indirection = 0
	close(file)
	free(generic_subst_swap(old_subst))
	generic_reparse_restore(save)
	return type_index


# Type position 'name[args]' for a registered generic struct: called
# from type_name() with the generic's name as the current token.
# Consumes through the closing ']' and returns the instantiated
# (or cached) type index.
int generic_struct_type():
	int def = generic_def_lookup(token, 1)
	get_token()
	int args = cast(int, malloc(generic_max_params() << 2))
	int arg_count = generic_parse_type_args(args, def)
	char* mangled = generic_mangle(generic_def_name(def), args, arg_count)
	int type = type_lookup(mangled)
	if (type < 0):
		type = generic_instantiate_struct(def, args, arg_count, mangled)
	else:
		free(mangled)
	free(cast(char*, args))
	get_token() /* consume the ']' */
	return type


/*
Function definitions: capture. program() calls this at the start of a
top-level declaration; see the return contract below.

generic_scanned_type: -1 when the scan did not consume anything and the
normal type_name() path should run; otherwise the already-parsed return
type of a non-generic declaration whose name is now the current token.
*/
int generic_scanned_type


int generic_declaration_scan():
	generic_scanned_type = -1
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		return 0
	# const/container types (and generic struct types, handled by
	# type_name) cannot start a generic function definition
	if (peek(c"const") | peek(c"map") | peek(c"set") | peek(c"list")):
		return 0
	if (nextc == '['):
		return 0
	# scan ahead: type '*'* name, generic when '[' follows the name
	char* first = strclone(token)
	int first_offset = token_start_offset
	int first_line = diag_token_line
	int first_column = diag_token_column
	get_token()
	int stars = 0
	while (accept(c"*")):
		stars = stars + 1
	int c1 = token[0]
	int name_is_ident = (('a' <= c1) & (c1 <= 'z')) | (('A' <= c1) & (c1 <= 'Z')) | (c1 == '_')
	if (name_is_ident & (nextc == '[')):
		# generic function definition: register and skip
		char* fname = strclone(token)
		get_token()
		int params = cast(int, malloc(generic_max_params() << 2))
		int n = generic_parse_param_names(params)
		if (peek(c"(") == 0):
			diag_part(c"'(' expected after the type parameter list of generic '")
			diag_part(fname)
			error(c"'")
		generic_def_add(fname, 0, strclone(filename), first_offset, first_line - 1, first_column - 1, n, params)
		free(first)
		generic_skip_definition()
		return 1

	# Not generic: rebuild the type from the scanned parts, mirroring
	# type_name()'s identifier branch, and leave the declared name as
	# the current token (as if type_name() had just returned).
	pointer_indirection = 0
	int type = type_lookup(first)
	if (type < 0):
		print_error(c"unknown type name: '")
		print_error(first)
		error(c"'")
	int checked_type = type_unqualified(type)
	if ((checked_type == float64_type) & (word_size != 8)):
		error(c"float64 requires the x64 target")
	if (((checked_type == int64_type) | (checked_type == uint64_type)) & (word_size != 8)):
		error(c"int64 requires the x64 target")
	char* base_name = type_get_name(type)
	while (pointer_indirection < stars):
		pointer_indirection = pointer_indirection + 1
		int pointer_type = type_lookup_pointer(base_name, pointer_indirection)
		if (pointer_type < 0):
			pointer_type = type_push_pointer(base_name, word_size, pointer_indirection)
		type = pointer_type
	type = type_name_array_suffix(type)
	generic_scanned_type = type
	free(first)
	return 0


/*
Function instantiation: signature. Parsed once per instantiation via a
nested re-parse of the definition header with the substitution active,
into a function-signature type record (the same kind function pointers
use), so call sites get return-type information and argument checks
before the body itself is compiled at the drain.
*/
int generic_inst_signature(int inst):
	int sig = load_int(generic_inst_entry(inst) + 20)
	if (sig >= 0):
		return sig
	int def = generic_inst_def(inst)
	char* save = generic_reparse_save()
	char* old_subst = generic_subst_swap(generic_subst_make(def, generic_inst_args(inst), generic_inst_arg_count(inst)))
	generic_reparse_start(def)
	int return_type = type_name()
	get_token() /* the definition's own name */
	expect(c"[")
	while (peek(c"]") == 0):
		get_token()
	expect(c"]")
	expect(c"(")
	char* param_types = malloc(40)
	int param_count = 0
	while (accept(c")") == 0):
		int param_type = type_name()
		if (peek(c".")):
			error(c"variadic parameters are not supported in generic functions")
		if ((peek(c")") == 0) & (peek(c",") == 0) & (peek(c"=") == 0)):
			get_token() /* the parameter's name */
		if (peek(c"=")):
			error(c"default parameter values are not supported in generic functions")
		if (param_count < 10):
			save_int(param_types + (param_count << 2), param_type)
		param_count = param_count + 1
		accept(c",")
	close(file)
	free(generic_subst_swap(old_subst))
	generic_reparse_restore(save)
	char* sig_name = strjoin(generic_inst_mangled(inst), c" sig")
	sig = type_push_function(sig_name, return_type, param_count, cast(int, param_types))
	free(param_types)
	save_int(generic_inst_entry(inst) + 20, sig)
	return sig


/*
Call sites. When primary_expr() sees a registered generic function
name, generic_call_expr() parses the '[type-args]', interns the
instantiation and leaves the callee's address in eax:
- already instantiated: an ordinary direct symbol reference;
- not yet: a mov-imm slot linked into the instantiation's backpatch
	chain (patched at the drain), plus the parsed signature in
	generic_pending_call_signature so postfix_expr's call path can check
	arguments and handle the return type. 0 means no pending signature
	(type index 0 is 'void', never a function signature).
*/
int generic_pending_call_signature
char* generic_pending_call_name


int generic_call_ready():
	if (generic_def_count == 0):
		return 0
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		return 0
	return generic_def_lookup(token, 0) >= 0


# The generic's name is the current token; leaves the closing ']'
# current (primary_expr's trailing get_token consumes it). Returns the
# expression type (4: function, its address is its value).
int generic_call_expr():
	int def = generic_def_lookup(token, 0)
	if (nextc != '['):
		diag_part(c"generic function '")
		diag_part(token)
		diag_part(c"' requires explicit type arguments, e.g. '")
		diag_part(token)
		error(c"[int](...)'")
	get_token()
	int args = cast(int, malloc(generic_max_params() << 2))
	int arg_count = generic_parse_type_args(args, def)
	char* mangled = generic_mangle(generic_def_name(def), args, arg_count)
	int t = sym_lookup(mangled)
	if (t >= 0):
		# already instantiated: an ordinary direct reference
		strcpy(last_identifier, mangled)
		int type = sym_get_value(mangled)
		free(mangled)
		free(cast(char*, args))
		return type
	int inst = generic_inst_intern(def, args, arg_count, mangled)
	generic_pending_call_signature = generic_inst_signature(inst)
	generic_pending_call_name = generic_inst_mangled(inst)
	# call target: a mov-imm slot on the instantiation's backpatch chain
	emit(5, c"\xb8....") /* mov $n,%eax */
	int head = generic_inst_chain(inst)
	if (head == 0):
		head = code_offset
	save_int(code + codepos - 4, head)
	generic_inst_set_chain(inst, codepos + code_offset - 4)
	return 4


# Compile one queued function instantiation: re-parse the definition
# with the substitution active, declaring and defining the mangled
# symbol through the ordinary function_definition() path, then patch
# the call sites emitted before the body existed.
void generic_instantiate_function(int inst):
	int def = generic_inst_def(inst)
	char* save = generic_reparse_save()
	char* old_subst = generic_subst_swap(generic_subst_make(def, generic_inst_args(inst), generic_inst_arg_count(inst)))
	generic_reparse_start(def)
	int decl_type = type_name()
	int current_symbol = sym_declare_global(generic_inst_mangled(inst), decl_type, 1)
	get_token() /* the definition's own name; the instance is the mangled one */
	expect(c"[")
	while (peek(c"]") == 0):
		get_token()
	expect(c"]")
	expect(c"(")
	function_definition(current_symbol)
	if (table[current_symbol + 1] != 'D'):
		diag_part(c"generic function '")
		diag_part(generic_def_name(def))
		error(c"' has no body")
	int address = load_int(table + current_symbol + 2)
	close(file)
	free(generic_subst_swap(old_subst))
	generic_reparse_restore(save)
	# patch the pre-definition call sites (json_codec chain encoding)
	int head = generic_inst_chain(inst)
	int p = 0
	if (head != 0):
		p = head - code_offset
	while (p):
		int next = load_int(code + p) - code_offset
		save_int(code + p, address)
		p = next


/*
Forward calls: 'fwd[int](x)' where the generic's definition appears
later in the file (or a later file). The name is not registered yet, so
the call is recorded speculatively: type arguments and a private
backpatch chain, resolved at the drain once every definition has been
seen. No signature exists at the call site, so these calls skip the
argument checks (like calls to asm runtime stubs) and cannot return
structs by value (checked at resolve time).
layout (24 bytes per entry):
	0: char* name
	4: int* type argument indices
	8: int arg_count
	12: int chain head
	16: char* file of the first call site (for the error message)
	20: int line of the first call site
*/
char* generic_forwards
int generic_forward_count


int generic_forward_stride():
	return 24


int generic_forward_max():
	return 2000


char* generic_forward_entry(int f):
	return generic_forwards + f * generic_forward_stride()


# An unknown identifier directly followed by '[' in expression position:
# only worth trying as a forward generic call when nothing else can
# claim the name.
int generic_forward_call_ready():
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		return 0
	if (nextc != '['):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	if (type_lookup(token) >= 0):
		return 0
	if (import_alias_lookup(token) >= 0):
		return 0
	return 1


# The (still unknown) generic's name is the current token; leaves the
# closing ']' current, like generic_call_expr().
int generic_forward_call_expr():
	if (generic_forwards == 0):
		generic_forwards = malloc(generic_forward_max() * generic_forward_stride())
	assert1(generic_forward_count < generic_forward_max())
	char* name = strclone(token)
	char* call_file = strclone(filename)
	int call_line = diag_token_line
	get_token()
	expect(c"[")
	int args = cast(int, malloc(generic_max_params() << 2))
	int arg_count = 0
	int more = 1
	while (more):
		if (arg_count >= generic_max_params()):
			error(c"too many type arguments")
		save_int(args + (arg_count << 2), type_name())
		arg_count = arg_count + 1
		more = accept(c",")
	if (peek(c"]") == 0):
		diag_part(c"']' expected in type argument list, found '")
		diag_part(token)
		error(c"'")
	# a chain slot for this call; merged into the instantiation's chain
	# once the definition is known
	emit(5, c"\xb8....") /* mov $n,%eax */
	save_int(code + codepos - 4, code_offset)
	char* e = generic_forwards + generic_forward_count * generic_forward_stride()
	save_int(e, cast(int, name))
	save_int(e + 4, args)
	save_int(e + 8, arg_count)
	save_int(e + 12, codepos + code_offset - 4)
	save_int(e + 16, cast(int, call_file))
	save_int(e + 20, call_line)
	generic_forward_count = generic_forward_count + 1
	# keep postfix_expr's callee lookup from matching a stale identifier
	strcpy(last_identifier, c"$forward generic call$")
	return 4


void generic_forward_error(int f, char* message):
	diag_part(c"generic function '")
	diag_part(cast(char*, load_int(generic_forward_entry(f))))
	diag_part(c"' ")
	diag_part(message)
	diag_part(c" (called at ")
	diag_part(cast(char*, load_int(generic_forward_entry(f) + 16)))
	diag_part(c":")
	diag_part(itoa(load_int(generic_forward_entry(f) + 20)))
	error(c")")


# Append the forward record's chain to the instantiation's chain: walk
# the forward chain to its terminating slot (which stores code_offset)
# and point it at the instantiation's current head.
void generic_forward_merge_chain(int f, int inst):
	int head = load_int(generic_forward_entry(f) + 12)
	int inst_head = generic_inst_chain(inst)
	if (inst_head != 0):
		int p = head - code_offset
		int v = load_int(code + p)
		while (v != code_offset):
			p = v - code_offset
			v = load_int(code + p)
		save_int(code + p, inst_head)
	generic_inst_set_chain(inst, head)


void generic_resolve_forward(int f):
	char* e = generic_forward_entry(f)
	char* name = cast(char*, load_int(e))
	int args = load_int(e + 4)
	int arg_count = load_int(e + 8)
	int def = generic_def_lookup(name, 0)
	if (def < 0):
		generic_forward_error(f, c"is not defined")
	if (arg_count != generic_def_param_count(def)):
		generic_forward_error(f, c"called with the wrong number of type arguments")
	char* mangled = generic_mangle(name, args, arg_count)
	int t = sym_lookup(mangled)
	if (t >= 0):
		if (table[t + 1] == 'D'):
			# already compiled: patch this record's chain directly
			int address = load_int(table + t + 2)
			int p = load_int(e + 12) - code_offset
			while (p):
				int next = load_int(code + p) - code_offset
				save_int(code + p, address)
				p = next
			free(mangled)
			free(cast(char*, args))
			return;
	int inst = generic_inst_intern(def, args, arg_count, mangled)
	# The call site had no signature, so it pushed no return buffer:
	# reject instantiations that would return a struct by value.
	int return_type = type_function_return(generic_inst_signature(inst))
	if (return_type >= 0):
		if ((type_num_args(return_type) > 0) & (type_get_pointer_level(return_type) == 0)):
			generic_forward_error(f, c"returns a struct by value, so it must be defined before the call")
	generic_forward_merge_chain(f, inst)


# Drain cursors: global so repeated drains (the REPL drains once per
# entry; link_impl drains again after the runtime imports) resume where
# the previous drain stopped instead of re-resolving patched records.
int generic_forwards_resolved
int generic_insts_compiled


# Drain at a top-level boundary (end of compilation for the batch
# compiler; end of an entry for the REPL). Forward call sites resolve
# first (every definition has been registered by now), then queued
# bodies compile; bodies may request further instantiations, which land
# at the end of the queue and are picked up by the outer loop.
void generic_finish_instantiations():
	int progress = 1
	while (progress):
		progress = 0
		while (generic_forwards_resolved < generic_forward_count):
			generic_resolve_forward(generic_forwards_resolved)
			generic_forwards_resolved = generic_forwards_resolved + 1
			progress = 1
		while (generic_insts_compiled < generic_inst_count):
			if (generic_inst_done(generic_insts_compiled) == 0):
				generic_inst_set_done(generic_insts_compiled)
				generic_instantiate_function(generic_insts_compiled)
				progress = 1
			generic_insts_compiled = generic_insts_compiled + 1
