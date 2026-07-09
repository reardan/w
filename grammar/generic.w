/*
Generics with explicit instantiation (docs/projects/generics.md).

A generic definition ('T max[T](T a, T b):' or 'struct pair[T]:') is not
compiled where it appears. Instead its source span (file path + byte
offset, from the tokenizer's token_start_offset) is recorded in a
registry and the definition's tokens are skipped. Each instantiation -
explicit ('max[int](...)' / 'pair[int]') or inferred from the argument
types ('max(3, 5)', see the inference block below) - re-parses the
recorded span with a substitution table binding the type parameters to
the type arguments, producing an ordinary monomorphic function or
struct under a mangled name ('max$int', 'pair$int'). '$' cannot appear
in a source identifier, so mangled names can never collide with user
symbols.

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
int expression();
void push_call_argument(int arg_type);
void coerce_call_argument(int param_type, int arg_type);
void check_call_argument(int callee, int signature_type, char* callee_name, int arg_index, int arg_type);


# Definition registry: one record per generic definition. For functions
# the span starts at the return type; for structs it starts at the
# struct's name (after the 'struct' keyword). Lazily created, so the
# count reads through a helper that tolerates the null list.
struct generic_def_record:
	char* name
	int kind          # 0 function, 1 struct
	char* file        # path to reopen for the re-parse
	int offset        # byte offset of the span start
	int line          # 0-based, for diagnostics during the re-parse
	int column        # 0-based
	int param_count
	int param_names   # char** vector of param_count names


list[generic_def_record] generic_defs


int generic_def_count():
	if (cast(int, generic_defs) == 0):
		return 0
	return generic_defs.length


int generic_max_params():
	return 8


char* generic_def_name(int def):
	return generic_defs[def].name


int generic_def_kind(int def):
	return generic_defs[def].kind


char* generic_def_file(int def):
	return generic_defs[def].file


int generic_def_offset(int def):
	return generic_defs[def].offset


int generic_def_line(int def):
	return generic_defs[def].line


int generic_def_column(int def):
	return generic_defs[def].column


int generic_def_param_count(int def):
	return generic_defs[def].param_count


char* generic_def_param_name(int def, int i):
	int names = generic_defs[def].param_names
	return cast(char*, load_ptr(names + i * __word_size__))


# Registered generic of the given kind (0 function, 1 struct) with this
# name, or -1. Functions and structs live in separate namespaces, like
# the symbol table and the type table do.
int generic_def_lookup(char* name, int kind):
	int i = 0
	while (i < generic_def_count()):
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
	if (cast(int, generic_defs) == 0):
		generic_defs = new list[generic_def_record]
	generic_def_record rec
	rec.name = name
	rec.kind = kind
	rec.file = file_path
	rec.offset = offset
	rec.line = line
	rec.column = column
	rec.param_count = param_count
	rec.param_names = param_names
	generic_defs.push(rec)
	return generic_defs.length - 1


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


# Seven pointer-sized slots: mangled*, def, args*, arg_count, head,
# sig, done (same uniform-word-slot scheme as generic_def_stride).
int generic_inst_stride():
	return 7 * __word_size__


int generic_inst_max():
	return 2000


char* generic_inst_entry(int inst):
	return generic_insts + inst * generic_inst_stride()


char* generic_inst_mangled(int inst):
	return cast(char*, load_ptr(generic_inst_entry(inst)))


int generic_inst_def(int inst):
	return load_ptr(generic_inst_entry(inst) + __word_size__)


int generic_inst_args(int inst):
	return load_ptr(generic_inst_entry(inst) + 2 * __word_size__)


int generic_inst_arg_count(int inst):
	return load_ptr(generic_inst_entry(inst) + 3 * __word_size__)


int generic_inst_chain(int inst):
	return load_ptr(generic_inst_entry(inst) + 4 * __word_size__)


void generic_inst_set_chain(int inst, int head):
	save_ptr(generic_inst_entry(inst) + 4 * __word_size__, head)


int generic_inst_done(int inst):
	return load_ptr(generic_inst_entry(inst) + 6 * __word_size__)


void generic_inst_set_done(int inst):
	save_ptr(generic_inst_entry(inst) + 6 * __word_size__, 1)


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
	save_ptr(e, cast(int, mangled))
	save_ptr(e + __word_size__, def)
	save_ptr(e + 2 * __word_size__, args)
	save_ptr(e + 3 * __word_size__, arg_count)
	save_ptr(e + 4 * __word_size__, 0)
	save_ptr(e + 5 * __word_size__, -1)
	save_ptr(e + 6 * __word_size__, 0)
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
	int n = load_ptr(generic_subst_block)
	int i = 0
	while (i < n):
		if (strcmp(name, cast(char*, load_ptr(generic_subst_block + __word_size__ + i * 2 * __word_size__))) == 0):
			return load_ptr(generic_subst_block + 2 * __word_size__ + i * 2 * __word_size__)
		i = i + 1
	return -1


char* generic_subst_make(int def, int args, int arg_count):
	char* block = malloc(__word_size__ + arg_count * 2 * __word_size__)
	save_ptr(block, arg_count)
	int i = 0
	while (i < arg_count):
		save_ptr(block + __word_size__ + i * 2 * __word_size__, cast(int, generic_def_param_name(def, i)))
		save_ptr(block + 2 * __word_size__ + i * 2 * __word_size__, load_ptr(args + i * __word_size__))
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
	char* s = malloc(14 * __word_size__)
	save_ptr(s, cast(int, filename))
	save_ptr(s + __word_size__, file)
	save_ptr(s + 2 * __word_size__, nextc)
	save_ptr(s + 3 * __word_size__, line_number)
	save_ptr(s + 4 * __word_size__, column_number)
	save_ptr(s + 5 * __word_size__, tab_level)
	save_ptr(s + 6 * __word_size__, token_newline)
	save_ptr(s + 7 * __word_size__, byte_offset)
	save_ptr(s + 8 * __word_size__, diag_token_line)
	save_ptr(s + 9 * __word_size__, diag_token_column)
	save_ptr(s + 10 * __word_size__, token_start_offset)
	save_ptr(s + 11 * __word_size__, cast(int, strclone(token)))
	save_ptr(s + 12 * __word_size__, pointer_indirection)
	save_ptr(s + 13 * __word_size__, token_i)
	return s


void generic_reparse_restore(char* s):
	filename = cast(char*, load_ptr(s))
	file = load_ptr(s + __word_size__)
	nextc = load_ptr(s + 2 * __word_size__)
	line_number = load_ptr(s + 3 * __word_size__)
	column_number = load_ptr(s + 4 * __word_size__)
	tab_level = load_ptr(s + 5 * __word_size__)
	token_newline = load_ptr(s + 6 * __word_size__)
	byte_offset = load_ptr(s + 7 * __word_size__)
	diag_token_line = load_ptr(s + 8 * __word_size__)
	diag_token_column = load_ptr(s + 9 * __word_size__)
	token_start_offset = load_ptr(s + 10 * __word_size__)
	char* saved_token = cast(char*, load_ptr(s + 11 * __word_size__))
	int n = strlen(saved_token)
	if (token_size <= n + 1):
		int x = (n + 10) << 1
		token = realloc(token, token_size, x)
		token_size = x
	strcpy(token, saved_token)
	token_i = load_ptr(s + 13 * __word_size__)
	pointer_indirection = load_ptr(s + 12 * __word_size__)
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
	getchar_reset(file)
	getchar_seek(file, generic_def_offset(def))
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
		char* arg_name = generic_mangle_arg(load_ptr(args + i * __word_size__))
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
		save_ptr(params_out + n * __word_size__, cast(int, strclone(token)))
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
		save_ptr(args_out + n * __word_size__, type_name())
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
	int params = cast(int, malloc(generic_max_params() * __word_size__))
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
	int args = cast(int, malloc(generic_max_params() * __word_size__))
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


# Lookahead for a generic function definition whose return type is a
# generic struct instantiation ('wresult[T]* new_ok[T](T value):').
# The plain scan cannot claim these: the return type itself starts with
# "name[", which normally is a type position for type_name(). Peek past
# the bracketed argument list and the pointer stars; when "name[" (a
# generic definition header) follows, register and skip the definition
# like generic_declaration_scan() does. Otherwise rewind the tokenizer
# (the seek trick generic_declaration_scan_repl uses) so type_name()
# parses the return type from its first token.
int generic_declaration_scan_generic_return():
	if (generic_def_lookup(token, 1) < 0):
		return 0
	int first_offset = token_start_offset
	int first_line = diag_token_line
	int first_column = diag_token_column
	char* save = generic_reparse_save()
	get_token()
	# Skip the balanced '[...]' type-argument list; the arguments may
	# reference not-yet-bound type parameters, so only brackets matter.
	if (peek(c"[")):
		int depth = 1
		get_token()
		while ((depth > 0) & (token[0] != 0)):
			if (peek(c"[")):
				depth = depth + 1
			if (peek(c"]")):
				depth = depth - 1
			get_token()
	while (accept(c"*")) {}
	int c1 = token[0]
	int name_is_ident = (('a' <= c1) & (c1 <= 'z')) | (('A' <= c1) & (c1 <= 'Z')) | (c1 == '_')
	if (name_is_ident & (nextc == '[')):
		# generic function definition: register and skip
		char* fname = strclone(token)
		get_token()
		int params = cast(int, malloc(generic_max_params() * __word_size__))
		int n = generic_parse_param_names(params)
		if (peek(c"(") == 0):
			diag_part(c"'(' expected after the type parameter list of generic '")
			diag_part(fname)
			error(c"'")
		generic_def_add(fname, 0, strclone(filename), first_offset, first_line - 1, first_column - 1, n, params)
		free(cast(char*, load_ptr(save + 11 * __word_size__)))
		free(save)
		generic_skip_definition()
		return 1
	# Not a definition (e.g. 'wresult[int]* f(...)'): rewind, so the
	# normal type_name() path parses the generic struct return type.
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	return 0


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
		return generic_declaration_scan_generic_return()
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
		int params = cast(int, malloc(generic_max_params() * __word_size__))
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
		diag_part(c"unknown type name: '")
		diag_part(first)
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
	int sig = load_ptr(generic_inst_entry(inst) + 5 * __word_size__)
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
	char* param_types = malloc(10 * __word_size__)
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
			save_ptr(param_types + param_count * __word_size__, param_type)
		param_count = param_count + 1
		accept(c",")
	close(file)
	free(generic_subst_swap(old_subst))
	generic_reparse_restore(save)
	char* sig_name = strjoin(generic_inst_mangled(inst), c" sig")
	sig = type_push_function(sig_name, return_type, param_count, cast(int, param_types))
	free(param_types)
	save_ptr(generic_inst_entry(inst) + 5 * __word_size__, sig)
	return sig


/*
Type-argument inference (docs/projects/generics.md). When a registered
generic FUNCTION name is followed directly by '(' instead of '[', the
type arguments are inferred from the call's argument types.

The definition's parameter SHAPES are extracted once per definition by
a header-only nested re-parse (the generic_inst_signature() walk) with
every type parameter bound to a distinct word-sized PLACEHOLDER type
instead of a concrete one. Each parameter then classifies as:
- a type-parameter reference with a pointer depth ('T' = depth 0,
	'T**' = depth 2): the placeholder (or a pointer chain over it) is
	the parameter's type;
- a concrete type (no placeholder involved): checked and coerced like
	an ordinary call argument;
- opaque: the type mentions a placeholder in a position v1 cannot
	invert ('list[T]', 'T[]', 'pair[T]*', 'const T*'). Opaque shapes
	constrain nothing; they are checked against the instantiated
	signature after the type arguments are known.
Placeholder names start with '@', which cannot appear in a source
identifier or in any compiler-generated type name, so any type whose
name mentions '@' provably depends on a placeholder.

Arguments are parsed left to right. A type-parameter shape strips its
pointer depth from the argument's promoted type and binds the type
parameter: the first binding wins and a conflicting later binding is a
compile error. Untyped constants (integer/char literals, '&'
addresses) bind 'int' when the parameter is still unbound and are
coerced to the existing binding otherwise, so 'max(1.5, 2)' works like
'max[float32](1.5, 2)'. Every type parameter must end up bound, else a
compile error suggests the explicit 'name[T](...)' syntax. Once bound,
the call proceeds exactly like an explicit instantiation: mangle,
intern, signature, emit, backpatch, drain.

Because the arguments are parsed (and pushed) before the callee is
known, the callee's mov-imm slot is emitted after them and the call
site cannot push a struct return buffer below the arguments: inferred
calls whose instantiation returns a struct by value are rejected with
a hint to use explicit type arguments (forward calls have the same
restriction, for the same reason). Inference also requires the
definition to appear before the call: an unregistered name followed by
'(' is an ordinary unknown symbol.
*/

# Placeholder type indices for shape extraction, one per type-parameter
# slot, created on demand and shared by every definition.
char* generic_infer_placeholders

# Cached shape blocks, indexed by definition (0 = not cached yet):
# 'int param_count', then two ints (a, b) per parameter:
#	a >= 0: type-parameter index a, b = pointer depth
#	a == -1: concrete type, b = the type index
#	a == -2: opaque (constrains nothing at parse time)
list[int] generic_infer_shapes_cache


# Parameters recorded per definition and arguments recorded per call;
# anything past the limit is treated as opaque/unchecked (the parsed
# signature only records 10 parameter types anyway).
int generic_infer_max_args():
	return 16


int generic_infer_placeholder(int i):
	if (generic_infer_placeholders == 0):
		generic_infer_placeholders = malloc(generic_max_params() * __word_size__)
		int j = 0
		while (j < generic_max_params()):
			save_ptr(generic_infer_placeholders + j * __word_size__, -1)
			j = j + 1
	int t = load_ptr(generic_infer_placeholders + i * __word_size__)
	if (t < 0):
		char* index_name = itoa(i)
		t = type_push_size(strjoin(c"@", index_name), word_size)
		free(index_name)
		save_ptr(generic_infer_placeholders + i * __word_size__, t)
	return t


# 1 when the type's name mentions a placeholder ('@' cannot appear in
# any user or compiler-generated type name).
int generic_infer_mentions_placeholder(int t):
	char* name = type_get_name(type_real(t))
	int i = 0
	while (name[i] != 0):
		if (name[i] == '@'):
			return 1
		i = i + 1
	return 0


# Classify one parsed parameter type into the shape block (see the
# layout on generic_infer_shapes_cache). Pointer records store the base
# type's name, so a pointer chain over placeholder i still has name
# '@i' with a nonzero pointer level.
void generic_infer_store_shape(char* block, int slot, int param_type, int def):
	char* e = block + __word_size__ + slot * 2 * __word_size__
	int u = type_unqualified(param_type)
	char* name = type_get_name(u)
	int n = generic_def_param_count(def)
	int i = 0
	while (i < n):
		if (strcmp(name, type_get_name(generic_infer_placeholder(i))) == 0):
			save_ptr(e, i)
			save_ptr(e + __word_size__, type_get_pointer_level(u))
			return;
		i = i + 1
	if (generic_infer_mentions_placeholder(u)):
		save_ptr(e, -2)
		save_ptr(e + __word_size__, 0)
		return;
	save_ptr(e, -1)
	save_ptr(e + __word_size__, param_type)


# The parameter shapes of a definition, extracted once and cached: a
# header-only nested re-parse (exactly generic_inst_signature's walk)
# with the type parameters bound to placeholders instead of concrete
# types. Safe mid-parse: headers emit no code.
char* generic_infer_shapes(int def):
	if (cast(int, generic_infer_shapes_cache) == 0):
		generic_infer_shapes_cache = new list[int]
	while (generic_infer_shapes_cache.length <= def):
		generic_infer_shapes_cache.push(0)
	char* cached = cast(char*, generic_infer_shapes_cache[def])
	if (cached != 0):
		return cached
	int n = generic_def_param_count(def)
	int placeholder_args = cast(int, malloc(generic_max_params() * __word_size__))
	int i = 0
	while (i < n):
		save_ptr(placeholder_args + i * __word_size__, generic_infer_placeholder(i))
		i = i + 1
	char* save = generic_reparse_save()
	char* old_subst = generic_subst_swap(generic_subst_make(def, placeholder_args, n))
	generic_reparse_start(def)
	type_name() /* the return type; only the parameters matter here */
	get_token() /* the definition's own name */
	expect(c"[")
	while (peek(c"]") == 0):
		get_token()
	expect(c"]")
	expect(c"(")
	char* block = malloc(__word_size__ + generic_infer_max_args() * 2 * __word_size__)
	int count = 0
	while (accept(c")") == 0):
		int param_type = type_name()
		if (peek(c".")):
			error(c"variadic parameters are not supported in generic functions")
		if ((peek(c")") == 0) & (peek(c",") == 0) & (peek(c"=") == 0)):
			get_token() /* the parameter's name */
		if (peek(c"=")):
			error(c"default parameter values are not supported in generic functions")
		if (count < generic_infer_max_args()):
			generic_infer_store_shape(block, count, param_type, def)
		count = count + 1
		accept(c",")
	save_ptr(block, count)
	close(file)
	free(generic_subst_swap(old_subst))
	generic_reparse_restore(save)
	free(cast(char*, placeholder_args))
	generic_infer_shapes_cache[def] = cast(int, block)
	return block


void generic_infer_error_prefix(int def):
	diag_part(c"generic function '")
	diag_part(generic_def_name(def))
	diag_part(c"': ")


# The declarable type an explicit '[T]' list would have named for an
# argument's promoted expression type (value pseudo-types map back to
# their storage types).
int generic_infer_declarable(int t):
	if (t == string_value_type):
		return string_type
	if (t == var_value_type):
		return var_type
	if (t == float32_value_type):
		return float32_type
	if (t == float64_value_type):
		return float64_type
	if (type_get_kind(t) == type_kind_slice_value()):
		return type_get_slice(type_get_element_type(t))
	return t


void generic_infer_pointer_error(int def, int param, int arg_type, int arg_index):
	generic_infer_error_prefix(def)
	diag_part(c"cannot infer type parameter '")
	diag_part(generic_def_param_name(def, param))
	diag_part(c"' from argument ")
	diag_part(itoa(arg_index + 1))
	diag_part(c": expected a pointer, got '")
	print_error_type(arg_type)
	error(c"'")


# Bind type parameter 'param' from an argument of the promoted type
# 'arg_type' against a 'T'-with-pointer-depth shape.
void generic_infer_bind(int def, char* bound, int param, int depth, int arg_type, int arg_index):
	int existing = load_ptr(bound + param * __word_size__)
	if ((arg_type == 3) & (depth == 0)):
		# untyped constant: bind 'int' when unbound, else coerce the
		# value in eax to the existing binding (e.g. int -> float)
		if (existing < 0):
			save_ptr(bound + param * __word_size__, type_lookup(c"int"))
		else:
			coerce(existing, arg_type)
		return;
	if (arg_type == 4):
		generic_infer_error_prefix(def)
		diag_part(c"cannot infer type parameter '")
		diag_part(generic_def_param_name(def, param))
		diag_part(c"' from argument ")
		diag_part(itoa(arg_index + 1))
		error(c": a bare function name has no value type; use explicit type arguments")
	int stripped = generic_infer_declarable(arg_type)
	int level = 0
	while (level < depth):
		if (type_get_pointer_level(stripped) == 0):
			generic_infer_pointer_error(def, param, arg_type, arg_index)
		stripped = type_lookup_previous_pointer(stripped)
		if (stripped < 0):
			generic_infer_pointer_error(def, param, arg_type, arg_index)
		level = level + 1
	stripped = type_unqualified(stripped)
	if (existing < 0):
		save_ptr(bound + param * __word_size__, stripped)
		return;
	if (existing != stripped):
		generic_infer_error_prefix(def)
		diag_part(c"conflicting types inferred for type parameter '")
		diag_part(generic_def_param_name(def, param))
		diag_part(c"': '")
		print_error_type(existing)
		diag_part(c"' vs '")
		print_error_type(stripped)
		error(c"'")


# A concrete (non-generic) parameter shape: the same check and coercion
# an ordinary call argument gets (check_call_argument's message).
void generic_infer_check_concrete(int def, int param_type, int arg_index, int arg_type):
	if (types_compatible_with_expression(param_type, arg_type) == 0):
		diag_part(c"warning: function '")
		diag_part(generic_def_name(def))
		diag_part(c"' argument ")
		diag_part(itoa(arg_index + 1))
		diag_part(c" type mismatch: expected '")
		print_error_type(param_type)
		diag_part(c"', got '")
		print_error_type(arg_type)
		warning(c"'")
	coerce_call_argument(param_type, arg_type)


# Inferred call 'max(3, 5)': the generic's name is the current token
# and '(' follows directly. The callee is unknown until the arguments
# have been parsed, so postfix_expr's callee-first stack layout does
# not apply: this parses the whole call itself (arguments pushed left
# to right, then the callee loaded into eax and called) and leaves the
# closing ')' as the current token for primary_expr's trailing
# get_token(). Returns the call's value type.
int generic_call_infer_expr(int def):
	char* shapes = generic_infer_shapes(def)
	int shape_count = load_ptr(shapes)
	int n = generic_def_param_count(def)
	char* bound = malloc(n * __word_size__)
	int i = 0
	while (i < n):
		save_ptr(bound + i * __word_size__, -1)
		i = i + 1
	# per argument: promoted type + a flag for the post-binding check
	char* arg_records = malloc(generic_infer_max_args() * 2 * __word_size__)
	int s = stack_pos
	int passed = 0
	get_token()
	expect(c"(")
	if (peek(c")") == 0):
		int more = 1
		while (more):
			int shape_kind = -2
			int shape_data = 0
			if ((passed < shape_count) & (passed < generic_infer_max_args())):
				shape_kind = load_ptr(shapes + __word_size__ + passed * 2 * __word_size__)
				shape_data = load_ptr(shapes + 2 * __word_size__ + passed * 2 * __word_size__)
			int arg_type = expression()
			arg_type = promote(arg_type)
			int needs_check = 0
			if (shape_kind >= 0):
				generic_infer_bind(def, bound, shape_kind, shape_data, arg_type, passed)
			else if (shape_kind == -1):
				generic_infer_check_concrete(def, shape_data, passed, arg_type)
			else:
				needs_check = 1
			if (passed < generic_infer_max_args()):
				save_ptr(arg_records + passed * 2 * __word_size__, arg_type)
				save_ptr(arg_records + __word_size__ + passed * 2 * __word_size__, needs_check)
			push_call_argument(arg_type)
			passed = passed + 1
			more = accept(c",")
	if (peek(c")") == 0):
		diag_part(c"')' expected in call to generic '")
		diag_part(generic_def_name(def))
		error(c"'")
	i = 0
	while (i < n):
		if (load_ptr(bound + i * __word_size__) < 0):
			generic_infer_error_prefix(def)
			diag_part(c"cannot infer type argument '")
			diag_part(generic_def_param_name(def, i))
			diag_part(c"'; use explicit type arguments, e.g. '")
			diag_part(generic_def_name(def))
			error(c"[int](...)'")
		i = i + 1
	int args = cast(int, malloc(generic_max_params() * __word_size__))
	i = 0
	while (i < n):
		save_ptr(args + i * __word_size__, load_ptr(bound + i * __word_size__))
		i = i + 1
	free(bound)
	char* mangled = generic_mangle(generic_def_name(def), args, n)
	int inst = generic_inst_intern(def, args, n, mangled)
	int sig = generic_inst_signature(inst)
	int return_type = type_function_return(sig)
	if (return_type >= 0):
		if ((type_num_args(return_type) > 0) & (type_get_pointer_level(return_type) == 0)):
			# the arguments are already on the stack, so no return
			# buffer can be pushed below them (the explicit syntax
			# pushes it before the arguments)
			generic_infer_error_prefix(def)
			diag_part(c"inferred call returns a struct by value; use explicit type arguments, e.g. '")
			diag_part(generic_def_name(def))
			error(c"[int](...)'")
	int expected = type_function_param_count(sig)
	if (passed != expected):
		diag_part(c"warning: function '")
		diag_part(generic_inst_mangled(inst))
		diag_part(c"' expects ")
		diag_part(itoa(expected))
		diag_part(c" arguments, got ")
		warning(itoa(passed))
	# opaque-shape arguments get their check against the now-concrete
	# signature (type-parameter shapes match by construction; concrete
	# shapes were checked while parsing)
	i = 0
	while ((i < passed) & (i < generic_infer_max_args())):
		if (load_ptr(arg_records + __word_size__ + i * 2 * __word_size__)):
			check_call_argument(-1, sig, generic_inst_mangled(inst), i, load_ptr(arg_records + i * 2 * __word_size__))
		i = i + 1
	free(arg_records)
	# callee: a direct reference when the instantiation's symbol exists
	# (already compiled, or being compiled right now at the drain);
	# otherwise a mov-imm slot on the instantiation's backpatch chain,
	# exactly like the explicit path
	if (sym_lookup(generic_inst_mangled(inst)) >= 0):
		sym_get_value(generic_inst_mangled(inst))
	else:
		be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
		int head = generic_inst_chain(inst)
		if (head == 0):
			head = code_offset
		be_addr_slot_write(codepos - 4, head)
		generic_inst_set_chain(inst, codepos + code_offset - 4)
		# pac=full: sign the chain-materialized callee like sym_get_value
		# does (after the chain bookkeeping above)
		be_code_ptr_sign()
	call_eax()
	be_pop(stack_pos - s)
	stack_pos = s
	last_call_return_type = return_type
	last_call_end = codepos
	return type_value(return_type)


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
	if (generic_def_count() == 0):
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
	if (nextc == '('):
		# no '[type-args]' list: infer the type arguments from the
		# call's argument types
		return generic_call_infer_expr(def)
	if (nextc != '['):
		diag_part(c"generic function '")
		diag_part(token)
		diag_part(c"' requires explicit type arguments, e.g. '")
		diag_part(token)
		error(c"[int](...)'")
	get_token()
	int args = cast(int, malloc(generic_max_params() * __word_size__))
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
	be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
	int head = generic_inst_chain(inst)
	if (head == 0):
		head = code_offset
	be_addr_slot_write(codepos - 4, head)
	generic_inst_set_chain(inst, codepos + code_offset - 4)
	# pac=full: sign the chain-materialized callee like sym_get_value does
	be_code_ptr_sign()
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
		int next = be_addr_slot_read(p) - code_offset
		be_addr_slot_write(p, address)
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


# Six pointer-sized slots: name*, args*, arg_count, patch-chain head,
# call_file*, call_line (same uniform-word-slot scheme as
# generic_def_stride).
int generic_forward_stride():
	return 6 * __word_size__


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
	int args = cast(int, malloc(generic_max_params() * __word_size__))
	int arg_count = 0
	int more = 1
	while (more):
		if (arg_count >= generic_max_params()):
			error(c"too many type arguments")
		save_ptr(args + arg_count * __word_size__, type_name())
		arg_count = arg_count + 1
		more = accept(c",")
	if (peek(c"]") == 0):
		diag_part(c"']' expected in type argument list, found '")
		diag_part(token)
		error(c"'")
	# a chain slot for this call; merged into the instantiation's chain
	# once the definition is known
	be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
	be_addr_slot_write(codepos - 4, code_offset)
	char* e = generic_forwards + generic_forward_count * generic_forward_stride()
	save_ptr(e, cast(int, name))
	save_ptr(e + __word_size__, args)
	save_ptr(e + 2 * __word_size__, arg_count)
	save_ptr(e + 3 * __word_size__, codepos + code_offset - 4)
	save_ptr(e + 4 * __word_size__, cast(int, call_file))
	save_ptr(e + 5 * __word_size__, call_line)
	generic_forward_count = generic_forward_count + 1
	# pac=full: sign the chain-materialized callee like sym_get_value does
	# (after the slot position was recorded in the forward entry above)
	be_code_ptr_sign()
	# keep postfix_expr's callee lookup from matching a stale identifier
	strcpy(last_identifier, c"$forward generic call$")
	return 4


void generic_forward_error(int f, char* message):
	diag_part(c"generic function '")
	diag_part(cast(char*, load_ptr(generic_forward_entry(f))))
	diag_part(c"' ")
	diag_part(message)
	diag_part(c" (called at ")
	diag_part(cast(char*, load_ptr(generic_forward_entry(f) + 4 * __word_size__)))
	diag_part(c":")
	diag_part(itoa(load_ptr(generic_forward_entry(f) + 5 * __word_size__)))
	error(c")")


# Append the forward record's chain to the instantiation's chain: walk
# the forward chain to its terminating slot (which stores code_offset)
# and point it at the instantiation's current head.
void generic_forward_merge_chain(int f, int inst):
	int head = load_ptr(generic_forward_entry(f) + 3 * __word_size__)
	int inst_head = generic_inst_chain(inst)
	if (inst_head != 0):
		int p = head - code_offset
		int v = be_addr_slot_read(p)
		while (v != code_offset):
			p = v - code_offset
			v = be_addr_slot_read(p)
		be_addr_slot_write(p, inst_head)
	generic_inst_set_chain(inst, head)


void generic_resolve_forward(int f):
	char* e = generic_forward_entry(f)
	char* name = cast(char*, load_ptr(e))
	int args = load_ptr(e + __word_size__)
	int arg_count = load_ptr(e + 2 * __word_size__)
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
			int p = load_ptr(e + 3 * __word_size__) - code_offset
			while (p):
				int next = be_addr_slot_read(p) - code_offset
				be_addr_slot_write(p, address)
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


# Tentative scan for the REPL: like generic_declaration_scan(), but
# non-committal. The REPL dispatches on the first token only, so a
# definition like 'T max[T](T a, T b):' is indistinguishable from an
# expression until the second token. This peeks ahead and rewinds the
# tokenizer (the staged entry file supports seek) unless the lookahead
# really is a generic definition, in which case the committed scan runs
# and registers it. Returns 1 when a definition was captured.
int generic_declaration_scan_repl():
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		return 0
	if (peek(c"const") | peek(c"map") | peek(c"set") | peek(c"list")):
		return 0
	if (nextc == '['):
		return 0
	char* save = generic_reparse_save()
	get_token()
	while (accept(c"*")) {}
	int c1 = token[0]
	int name_is_ident = (('a' <= c1) & (c1 <= 'z')) | (('A' <= c1) & (c1 <= 'Z')) | (c1 == '_')
	int is_generic = name_is_ident & (nextc == '[')
	# rewind: byte_offset (save offset 28) counts consumed bytes, so it
	# is exactly the fd position the saved lookahead expects
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	if (is_generic):
		return generic_declaration_scan()
	return 0


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
