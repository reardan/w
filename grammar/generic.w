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

Under --ast-emit-retained (S2.3) no instantiation reopens and seeks the
file: struct field lists, instantiation signatures and inference shapes
are built by walking retained type trees under the substitution (the
"Retained type trees" block below), and what is still re-parsed - every
function body, and a header or field list the trees cannot express - is
re-lexed from the retained source bytes (generic_reparse_open,
code_generator/retained_emit.w).

defhash coverage (wave plan C task 4f, compiler/compiler.w's defhash_main
doc comment): the three registration points below
(generic_register_struct, generic_declaration_scan,
generic_declaration_scan_generic_return) each call defhash_note() with
the SAME [offset, end) span already recorded here for re-parsing, so 'w
defhash' hashes exactly the tokens an instantiation would re-parse -- an
instantiation-only change elsewhere never touches this span, and a
reformat/comment-only edit to the definition itself leaves the hash
unchanged, same as any other kind. The recorded 'name' is the BASE
identifier with no '[T]' (a generic's name, like any definition's, does
not change when the compiler emits a differently-mangled instantiation);
'kind' is 'generic_function'/'generic_struct' rather than plain
'function'/'struct' so a defhash consumer can tell a generic definition
apart from a same-named non-generic one in the sibling namespace (the
struct/function namespaces are separate, so a name collision across them
is otherwise unremarkable) and let the wtest_defhash_risky_text textual
fallback in tools/test_map.w be retired now that this has landed.

This file is compiled by the committed seed: only seed-understood
syntax here.
*/

# Defined later in the grammar / compiler; the single-pass compiler
# needs the declarations up front.
int type_name();
int gpu_qualifier_ahead();   /* grammar/type_name.w */
int type_name_array_suffix(int type);
void function_definition(int current_symbol);
int import_alias_lookup(char* name);
int expression();
void push_call_argument(int arg_type);
void coerce_call_argument(int param_type, int arg_type);
void check_call_argument(int callee, int signature_type, char* callee_name, int arg_index, int arg_type);
# Forward declaration: defhash_note is defined in compiler/compiler.w,
# which compiles after grammar/.
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset);
# S2.3: retained instantiation (code_generator/retained_emit.w, compiled
# after grammar/).
int retained_emit_generic_enabled();
int retained_source_reparse_begin(char* path, int source, int offset, int line, int column, int follow);
void retained_source_reparse_close(int fd);


# A captured generic struct field: its unbound type tree and its name, in
# declaration order (S2.3).
struct generic_field_ast:
	generic_type_ast* type
	char* name
	generic_field_ast* next


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
	generic_signature_ast* signature_ast
	# S2.3: retained source version holding the span (-1 when not
	# retaining), the offset of the top-level token after a function's
	# span (-1 when the definition ends the file), the struct's captured
	# field list, and whether the captured field list / signature may
	# replace a re-parse (nothing was printed while their tokens were
	# lexed, so a re-parse would print nothing either).
	int source
	int follow
	generic_field_ast* fields
	int fields_captured
	int header_captured


list[generic_def_record] generic_defs


int generic_def_count():
	if (cast(int, generic_defs) == 0): return 0
	return generic_defs.length


const int generic_max_params = 8


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
	int previous = generic_def_lookup(name, kind)
	if (previous >= 0):
		# --json related note (C3.2): the first definition; the record's
		# line/column are 0-based
		if (diag_json):
			char* lead = strjoin(c"previous definition of generic '", name)
			char* note = strjoin(lead, c"' is here")
			diag_related_add(generic_defs[previous].file, generic_defs[previous].line + 1, generic_defs[previous].column + 1, note)
			free(lead)
			free(note)
		error3(c"generic '", name, c"' redefined")
	if (cast(int, generic_defs) == 0): generic_defs = new list[generic_def_record]
	generic_def_record rec
	rec.name = name
	rec.kind = kind
	rec.file = file_path
	rec.offset = offset
	rec.line = line
	rec.column = column
	rec.param_count = param_count
	rec.param_names = param_names
	rec.signature_ast = 0
	rec.source = -1
	if (ast_retain_mode): rec.source = retained_source_find(file_path)
	rec.follow = -1
	rec.fields = 0
	rec.fields_captured = 0
	rec.header_captured = 0
	generic_defs.push(rec)
	return generic_defs.length - 1


# Function instantiation registry / queue. Field access replaces the
# old hand-packed 7-word-slot blob; records are only ever addressed
# through their index, so list growth cannot invalidate anything.
struct generic_inst_record:
	char* mangled     # mangled name ('max$int')
	int def           # definition registry index
	int args          # int* vector of type argument indices
	int arg_count
	int chain         # head of the call-site mov-imm backpatch chain, 0 none
	int signature     # function-signature type index, -1 until parsed
	int done          # 1 once the body has been compiled


list[generic_inst_record] generic_insts


int generic_inst_count():
	if (cast(int, generic_insts) == 0): return 0
	return generic_insts.length


char* generic_inst_mangled(int inst):
	return generic_insts[inst].mangled


int generic_inst_def(int inst):
	return generic_insts[inst].def


int generic_inst_args(int inst):
	return generic_insts[inst].args


int generic_inst_arg_count(int inst):
	return generic_insts[inst].arg_count


int generic_inst_chain(int inst):
	return generic_insts[inst].chain


void generic_inst_set_chain(int inst, int head):
	generic_insts[inst].chain = head


int generic_inst_done(int inst):
	return generic_insts[inst].done


void generic_inst_set_done(int inst):
	generic_insts[inst].done = 1


int generic_inst_lookup(char* mangled):
	int i = 0
	while (i < generic_inst_count()):
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
	if (cast(int, generic_insts) == 0): generic_insts = new list[generic_inst_record]
	generic_inst_record rec
	rec.mangled = mangled
	rec.def = def
	rec.args = args
	rec.arg_count = arg_count
	rec.chain = 0
	rec.signature = -1
	rec.done = 0
	generic_insts.push(rec)
	return generic_insts.length - 1


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
	if (generic_subst_block == 0): return -1
	int n = load_ptr(generic_subst_block)
	for i in range(n):
		if (strcmp(name, cast(char*, load_ptr(generic_subst_block + __word_size__ + i * 2 * __word_size__))) == 0):
			return load_ptr(generic_subst_block + 2 * __word_size__ + i * 2 * __word_size__)
	return -1


char* generic_subst_make(int def, int args, int arg_count):
	char* block = cast(char*, malloc(__word_size__ + arg_count * 2 * __word_size__))
	save_ptr(block, arg_count)
	for i in range(arg_count):
		save_ptr(block + __word_size__ + i * 2 * __word_size__, cast(int, generic_def_param_name(def, i)))
		save_ptr(block + 2 * __word_size__ + i * 2 * __word_size__, load_ptr(args + i * __word_size__))
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
	if (generic_subst_lookup(token) >= 0): return 1
	if (nextc == '['):
		if (generic_def_lookup(token, 1) >= 0): return 1
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
	char* s = cast(char*, malloc(14 * __word_size__))
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


# --stats (S2.3): re-parses that reopened a definition's file and seeked
# to its span, and types or signatures built from retained type trees
# instead of a re-parse.
int generic_source_seeks
int generic_tree_types


# Prime the tokenizer at the span start: afterwards the span's first token
# is current. The retained source version serves the span when it can
# (retained_source_reparse_begin; follow as documented there); otherwise
# open the definition's file and seek to it.
void generic_reparse_open(int def, int follow):
	char* path = generic_def_file(def)
	if (retained_source_reparse_begin(path, generic_defs[def].source, generic_def_offset(def), generic_def_line(def), generic_def_column(def), follow)): return
	generic_source_seeks = generic_source_seeks + 1
	file = open(path, 0, 511)
	if (file < 0): error3(c"cannot reopen generic definition file '", path, c"'")
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


# A header or field list: type names only, no expression.
void generic_reparse_start(int def):
	generic_reparse_open(def, -2)


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
	for i in range(arg_count):
		char* with_sep = strjoin(name, c"$")
		free(name)
		char* arg_name = generic_mangle_arg(load_ptr(args + i * __word_size__))
		name = strjoin(with_sep, arg_name)
		free(with_sep)
		free(arg_name)
	return name


# Parse the '[T, U]' type-parameter list of a definition into an array
# of name clones (capacity generic_max_params). Returns the count;
# the closing ']' is consumed.
int generic_parse_param_names(int params_out):
	expect(c"[")
	int n = 0
	int more = 1
	while (more):
		int c0 = token[0]
		int is_ident = is_ident_start_byte(c0)
		if (is_ident == 0): error3(c"type parameter name expected, found '", token, c"'")
		if (n >= generic_max_params): error(c"too many type parameters")
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
		if (n >= generic_max_params): error(c"too many type arguments")
		save_ptr(args_out + n * __word_size__, type_name())
		n = n + 1
		more = accept(c",")
	if (peek(c"]") == 0): error3(c"']' expected in type argument list, found '", token, c"'")
	if (n != generic_def_param_count(def)):
		diag_part(c"wrong number of type arguments for generic '")
		diag_part(generic_def_name(def))
		diag_part(c"': expected ")
		error3(itoa(generic_def_param_count(def)), c", got ", itoa(n))
	return n


# Skip a captured definition: the rest of the current (header) line,
# then every following line indented past the top level. Strings and
# comments are already opaque to get_token(), so skipping token by
# token is safe.
void generic_skip_definition():
	while ((token_newline == 0) && (token[0] != 0)): get_token()
	while ((tab_level > 0) && (token[0] != 0)): get_token()


/*
Retained type trees (S2.3, --ast-emit-retained). A generic struct's field
list is captured as unbound type trees while its definition is skipped,
and a function's header already is (generic_signature_ast, tasks 38/45/46).
An instantiation then builds its struct type, its signature or its
inference shapes by walking those trees under the substitution, making
exactly the type-table calls type_name() would make for the same tokens,
in the same order, instead of re-parsing the span.

The walk must not fail where a re-parse would report an error, or the
diagnostic would be lost. So a tree is first checked without side effects
(generic_tree_valid): every name resolves, a generic struct application
has the definition's arity, the container storage rules hold, and no shape
is one type_name() would read differently (a bound parameter applied to
arguments, a generic struct's name as a slice element). A tree that fails
the check, or a span whose lexing printed anything, is re-parsed as before
(from the retained source, see generic_reparse_open).
*/

int generic_instantiate_struct(int def, int args, int arg_count, char* mangled);


# One token of a captured field type. The skip that the capture replaces
# never consumes a top-level token, so neither does the capture.
int generic_field_advance():
	if ((tab_level == 0) || (token[0] == 0)): return 0
	get_token()
	return 1


int generic_field_accept(char* spelling):
	if (peek(spelling) == 0): return 0
	return generic_field_advance()


# generic_type_ast_capture_at for a field line: the same shapes, consuming
# exactly the tokens type_name() would, but never a top-level token.
generic_type_ast* generic_field_capture(int depth):
	if (depth > 32): return 0
	if ((tab_level == 0) || (is_ident_start_byte(token[0]) == 0)): return 0
	if (peek(c"const") || peek(c"gpu")): return 0
	int container = 0
	if (nextc == '['):
		container = 3
		if (peek(c"map")): container = 2
		if (peek(c"set") || peek(c"list")): container = 1
	generic_type_ast* node = generic_type_ast_new(token, 0)
	generic_field_advance()
	if (container):
		if (generic_field_accept(c"[") == 0):
			generic_type_ast_free(node)
			return 0
		if ((container == 3) && generic_field_accept(c"]")):
			node = generic_type_ast_slice(node)
		else:
			node.first = generic_field_capture(depth + 1)
			if (node.first == 0):
				generic_type_ast_free(node)
				return 0
			if (container == 2):
				if (generic_field_accept(c",") == 0):
					generic_type_ast_free(node)
					return 0
				node.second = generic_field_capture(depth + 1)
				if (node.second == 0):
					generic_type_ast_free(node)
					return 0
			if (container == 3):
				node.application = 1
				generic_type_ast* tail = node.first
				int count = 1
				while (generic_field_accept(c",")):
					if (count == generic_max_params):
						generic_type_ast_free(node)
						return 0
					tail.next = generic_field_capture(depth + 1)
					if (tail.next == 0):
						generic_type_ast_free(node)
						return 0
					tail = tail.next
					count = count + 1
			if (generic_field_accept(c"]") == 0):
				generic_type_ast_free(node)
				return 0
	if (node.application != 2):
		while (generic_field_accept(c"*")): node.stars = node.stars + 1
	while (generic_field_accept(c"[")):
		if (generic_field_accept(c"]") == 0):
			generic_type_ast_free(node)
			return 0
		node = generic_type_ast_slice(node)
	return node


void generic_field_list_free(generic_field_ast* field):
	while (field != 0):
		generic_field_ast* next = field.next
		generic_type_ast_free(field.type)
		free(field.name)
		free(cast(char*, field))
		field = next


# The field lines of a generic struct, current token the first field's
# type: skip them like the plain skip does, and capture each 'type name'
# pair into the definition when the mode allows it.
void generic_capture_fields(int def):
	int capturing = retained_emit_generic_enabled()
	int warnings = warning_count
	generic_field_ast* tail = 0
	while ((tab_level > 0) && (token[0] != 0)):
		if (capturing == 0):
			get_token()
		else:
			generic_type_ast* type = generic_field_capture(0)
			# the field's name: an identifier on a field line ('alias.T'
			# leaves its '.' here, which type_name() would have read)
			if ((type == 0) || (tab_level == 0) || (is_ident_start_byte(token[0]) == 0)):
				generic_type_ast_free(type)
				capturing = 0
			else:
				generic_field_ast* field = new generic_field_ast
				field.type = type
				field.name = strclone(token)
				field.next = 0
				if (tail == 0): generic_defs[def].fields = field
				else: tail.next = field
				tail = field
				get_token()
	if (capturing && (warning_count == warnings)):
		generic_defs[def].fields_captured = 1
	else:
		generic_field_list_free(generic_defs[def].fields)
		generic_defs[def].fields = 0


int generic_tree_is_name(generic_type_ast* node, char* name):
	return strcmp(node.name, name) == 0


# list_element_type_check (is_list) or map_value_type_check without the
# error: 1 when the type may be stored.
int generic_tree_storage_ok(int element_type, int is_list):
	int checked = type_unqualified(element_type)
	if (type_is_array(checked)): return 0
	if (is_list && (type_get_size(checked) <= 0)): return 0
	if (type_has_array_field(checked)): return 0
	if ((type_num_args(checked) == 0) && (type_stack_words(checked) != 1)): return 0
	return 1


# 1 when walking node under the active substitution makes exactly the
# calls type_name() would make for its tokens, none of which reports an
# error. storage: 0 none, 1 a list element, 2 a map value. Pure: looks
# types up, never creates one.
int generic_tree_valid(generic_type_ast* node, int storage):
	if (node == 0): return 0
	if (node.application == 2):
		generic_type_ast* element = node.first
		# 'name[]' with name a generic struct: type_name() reads an
		# application there
		if ((element.application == 0) && (element.first == 0) && (element.stars == 0)):
			if ((generic_subst_lookup(element.name) < 0) && (generic_def_lookup(element.name, 1) >= 0)): return 0
		# a slice is one word and never an array: storable anywhere
		return generic_tree_valid(element, 0)
	if (node.application == 1):
		if (generic_subst_lookup(node.name) >= 0): return 0
		int def = generic_def_lookup(node.name, 1)
		if (def < 0): return 0
		int count = 0
		generic_type_ast* arg = node.first
		while (arg != 0):
			if (generic_tree_valid(arg, 0) == 0): return 0
			count = count + 1
			arg = arg.next
		if (count != generic_def_param_count(def)): return 0
		# a struct value's storage is known only once it is instantiated
		if (storage && (node.stars == 0)): return 0
		return 1
	if (node.first != 0):
		# map/set/list: one word, storable anywhere
		if (generic_tree_is_name(node, c"map")):
			if (generic_tree_valid(node.first, 0) == 0): return 0
			return generic_tree_valid(node.second, 2)
		if (generic_tree_is_name(node, c"list")): return generic_tree_valid(node.first, 1)
		return generic_tree_valid(node.first, 0)
	int type = generic_subst_lookup(node.name)
	if (type < 0):
		type = type_lookup(node.name)
		if (type < 0): return 0
		int checked = type_unqualified(type)
		if ((word_size != 8) && ((checked == float64_type) || (checked == int64_type) || (checked == uint64_type))): return 0
	if (storage && (node.stars == 0)): return generic_tree_storage_ok(type, storage == 1)
	return 1


# Build the type a tree names under the active substitution: the calls
# type_name() makes for the same tokens, in the same order (container and
# struct arguments first, then the pointer levels, then slices). The tree
# must have passed generic_tree_valid.
int generic_tree_resolve(generic_type_ast* node):
	if (node.application == 2):
		int element = generic_tree_resolve(node.first)
		int slice_type = type_lookup_slice(element)
		if (slice_type < 0): slice_type = type_push_slice(element)
		return slice_type
	int type = -1
	if (node.application == 1):
		int def = generic_def_lookup(node.name, 1)
		int args = cast(int, malloc(generic_max_params * __word_size__))
		int count = 0
		generic_type_ast* arg = node.first
		while (arg != 0):
			save_ptr(args + count * __word_size__, generic_tree_resolve(arg))
			count = count + 1
			arg = arg.next
		char* mangled = generic_mangle(generic_def_name(def), args, count)
		type = type_lookup(mangled)
		if (type < 0): type = generic_instantiate_struct(def, args, count, mangled)
		else: free(mangled)
		free(cast(char*, args))
	else if (node.first != 0):
		if (generic_tree_is_name(node, c"map")):
			int key_type = generic_tree_resolve(node.first)
			int value_type = generic_tree_resolve(node.second)
			type = type_get_map(key_type, value_type)
		else if (generic_tree_is_name(node, c"set")):
			type = type_get_set(generic_tree_resolve(node.first))
		else:
			type = type_get_list(generic_tree_resolve(node.first))
	else:
		type = generic_subst_lookup(node.name)
		if (type < 0): type = type_lookup(node.name)
	char* base_name = type_get_name(type)
	for i in range(node.stars):
		int next_level = type_get_pointer_level(type) + 1
		int pointer_type = type_lookup_pointer(base_name, next_level)
		if (pointer_type < 0): pointer_type = type_push_pointer(base_name, word_size, next_level)
		type = pointer_type
	return type


# decl_file_index() as a re-parse of the definition would compute it.
int generic_def_file_index(int def):
	char* saved = filename
	filename = generic_def_file(def)
	int index = decl_file_index()
	filename = saved
	return index


# 1 when the struct's captured fields may be walked under the active
# substitution.
int generic_struct_tree_ready(int def):
	if ((retained_emit_generic_enabled() == 0) || (generic_defs[def].fields_captured == 0)): return 0
	generic_field_ast* field = generic_defs[def].fields
	while (field != 0):
		if (generic_tree_valid(field.type, 0) == 0): return 0
		field = field.next
	return 1


# 1 when the function's captured header may be walked under the active
# substitution.
int generic_header_tree_ready(int def):
	if ((retained_emit_generic_enabled() == 0) || (generic_defs[def].header_captured == 0)): return 0
	generic_signature_ast* signature = generic_defs[def].signature_ast
	if (signature == 0): return 0
	if (generic_tree_valid(signature.result, 0) == 0): return 0
	generic_type_ast* parameter = signature.parameters
	while (parameter != 0):
		if (generic_tree_valid(parameter, 0) == 0): return 0
		parameter = parameter.next
	return 1


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
	int params = cast(int, malloc(generic_max_params * __word_size__))
	int n = generic_parse_param_names(params)
	expect(c":")
	int def = generic_def_add(name, 1, strclone(filename), offset, line, column, n, params)
	# skip the field lines; they are re-parsed per instantiation, or
	# captured for a retained walk
	generic_capture_fields(def)
	# defhash coverage (wave plan C task 4f): hash exactly the span just
	# registered above, so a reformat/comment-only edit leaves the hash
	# unchanged and a real field-list edit changes it.
	defhash_note(name, c"generic_struct", decl_file_index(), line + 1, column + 1, offset, token_start_offset)


# Instantiate a generic struct: re-parse its field list with the type
# parameters bound, filling a fresh type-table record under the mangled
# name. Struct parsing emits no code, so this is safe mid-parse. No
# symbol-table entry is created: type_lookup() is what matters for
# types, and a global symbol declared mid-function would be dropped by
# function_definition's scope truncation anyway.
int generic_instantiate_struct(int def, int args, int arg_count, char* mangled):
	char* old_subst = generic_subst_swap(generic_subst_make(def, args, arg_count))
	if (generic_struct_tree_ready(def)):
		# S2.3: the same record from the captured fields
		int tree_index = type_push_size(mangled, 0)
		type_set_decl_location(tree_index, generic_def_file_index(def), generic_def_line(def) + 1, generic_def_column(def) + 1)
		generic_field_ast* field = generic_defs[def].fields
		while (field != 0):
			int tree_field_type = generic_tree_resolve(field.type)
			type_add_arg(tree_index, strclone(field.name), tree_field_type)
			field = field.next
		free(generic_subst_swap(old_subst))
		generic_tree_types = generic_tree_types + 1
		return tree_index
	char* save = generic_reparse_save()
	generic_reparse_start(def)
	# span starts at the struct's name; the instance uses the mangled name
	int type_index = type_push_size(mangled, 0)
	type_set_decl_location(type_index, decl_file_index(), diag_token_line, diag_token_column)
	get_token()
	expect(c"[")
	while (peek(c"]") == 0): get_token()
	expect(c"]")
	expect(c":")
	while ((tab_level > 0) && (token[0] != 0)):
		int field_type = type_name()
		type_add_arg(type_index, strclone(token), field_type)
		get_token()
		pointer_indirection = 0
	retained_source_reparse_close(file)
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
	int args = cast(int, malloc(generic_max_params * __word_size__))
	int arg_count = generic_parse_type_args(args, def)
	char* mangled = generic_mangle(generic_def_name(def), args, arg_count)
	int type = type_lookup(mangled)
	if (type < 0): type = generic_instantiate_struct(def, args, arg_count, mangled)
	else: free(mangled)
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


# A generic function definition 'T name[params](...) ...' whose type
# started at first_offset (line/column first_line/first_column), with
# the name as the current token: register it and skip its body.
# warning_count when the current declaration's scan started (S2.3).
int generic_scan_warnings


void generic_register_definition(int first_offset, int first_line, int first_column, generic_type_ast* result):
	char* fname = strclone(token)
	get_token()
	int params = cast(int, malloc(generic_max_params * __word_size__))
	int n = generic_parse_param_names(params)
	if (peek(c"(") == 0):
		error3(c"'(' expected after the type parameter list of generic '", fname, c"'")
	int def = generic_def_add(fname, 0, strclone(filename), first_offset, first_line - 1, first_column - 1, n, params)
	generic_defs[def].signature_ast = generic_signature_ast_capture_result(result)
	# S2.3: a header whose lexing printed nothing may be walked instead
	# of re-parsed (a re-parse would print it again)
	if (warning_count == generic_scan_warnings): generic_defs[def].header_captured = 1
	generic_skip_definition()
	if (token[0] != 0): generic_defs[def].follow = token_start_offset
	# defhash coverage (wave plan C task 4f): same span the definition
	# registry just recorded (first_offset..the skip's end).
	defhash_note(fname, c"generic_function", decl_file_index(), first_line, first_column, first_offset, token_start_offset)


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
	if (generic_def_lookup(token, 1) < 0): return 0
	int first_offset = token_start_offset
	int first_line = diag_token_line
	int first_column = diag_token_column
	char* save = generic_reparse_save()
	generic_type_ast* result = generic_type_ast_capture_return()
	int c1 = token[0]
	int name_is_ident = is_ident_start_byte(c1)
	if (name_is_ident & (nextc == '[')):
		free(cast(char*, load_ptr(save + 11 * __word_size__)))
		free(save)
		generic_register_definition(first_offset, first_line, first_column, result)
		return 1
	# Not a definition (e.g. 'wresult[int]* f(...)'): rewind, so the
	# normal type_name() path parses the generic struct return type.
	generic_type_ast_free(result)
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	return 0


int generic_declaration_scan():
	generic_scanned_type = -1
	generic_scan_warnings = warning_count
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0): return 0
	# const/container types (and generic struct types, handled by
	# type_name) cannot start a generic function definition; neither can
	# a 'gpu'-qualified pointer type (grammar/type_name.w)
	if (peek(c"const") | peek(c"map") | peek(c"set") | peek(c"list")): return 0
	if (gpu_qualifier_ahead()): return 0
	# An import alias's qualified type ('alias.T name') is never a
	# generic definition; leave it for type_name()'s alias branch
	if (nextc == '.'):
		if (import_alias_lookup(token) >= 0): return 0
	if (nextc == '['): return generic_declaration_scan_generic_return()
	# scan ahead: type '*'* name, generic when '[' follows the name
	char* first = strclone(token)
	int first_offset = token_start_offset
	int first_line = diag_token_line
	int first_column = diag_token_column
	get_token()
	int stars = 0
	while (accept(c"*")): stars = stars + 1
	int c1 = token[0]
	int name_is_ident = is_ident_start_byte(c1)
	if (name_is_ident & (nextc == '[')):
		generic_register_definition(first_offset, first_line, first_column, generic_type_ast_new(first, stars))
		free(first)
		return 1

	# Not generic: rebuild the type from the scanned parts, mirroring
	# type_name()'s identifier branch, and leave the declared name as
	# the current token (as if type_name() had just returned).
	pointer_indirection = 0
	int type = type_lookup(first)
	if (type < 0):
		type_suggest_names(first)
		error3(c"unknown type name: '", first, c"'")
	int checked_type = type_unqualified(type)
	if ((checked_type == float64_type) && (word_size != 8)):
		error(c"float64 requires the x64 target")
	if (((checked_type == int64_type) || (checked_type == uint64_type)) && (word_size != 8)):
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
	int sig = generic_insts[inst].signature
	if (sig >= 0):
		return sig
	int def = generic_inst_def(inst)
	char* old_subst = generic_subst_swap(generic_subst_make(def, generic_inst_args(inst), generic_inst_arg_count(inst)))
	char* param_types = cast(char*, malloc(10 * __word_size__))
	int param_count = 0
	int return_type = -1
	if (generic_header_tree_ready(def)):
		# S2.3: walk the captured header under the substitution
		generic_signature_ast* signature = generic_defs[def].signature_ast
		return_type = generic_tree_resolve(signature.result)
		generic_type_ast* parameter = signature.parameters
		while (parameter != 0):
			int tree_param_type = generic_tree_resolve(parameter)
			if (param_count < 10): save_ptr(param_types + param_count * __word_size__, tree_param_type)
			param_count = param_count + 1
			parameter = parameter.next
		generic_tree_types = generic_tree_types + 1
	else:
		char* save = generic_reparse_save()
		generic_reparse_start(def)
		return_type = type_name()
		get_token() /* the definition's own name */
		expect(c"[")
		while (peek(c"]") == 0): get_token()
		expect(c"]")
		expect(c"(")
		while (accept(c")") == 0):
			int param_type = type_name()
			if (peek(c".")): error(c"variadic parameters are not supported in generic functions")
			if ((peek(c")") == 0) & (peek(c",") == 0) & (peek(c"=") == 0)):
				get_token() /* the parameter's name */
			if (peek(c"=")): error(c"default parameter values are not supported in generic functions")
			if (param_count < 10): save_ptr(param_types + param_count * __word_size__, param_type)
			param_count = param_count + 1
			accept(c",")
		retained_source_reparse_close(file)
		generic_reparse_restore(save)
	free(generic_subst_swap(old_subst))
	char* sig_name = strjoin(generic_inst_mangled(inst), c" sig")
	sig = type_push_function(sig_name, return_type, param_count, cast(int, param_types))
	free(param_types)
	generic_insts[inst].signature = sig
	return sig


# Emit the instantiation's future address into eax: a mov-imm slot
# (adrp+add pair on arm64) linked into the instantiation's backpatch
# chain, patched by generic_instantiate_function() once the body is
# compiled at the drain (the json_codec chain encoding). Used by every
# call site emitted before the body exists — explicit, inferred, and
# the cursor-protocol calls for_statement.w emits for generic
# containers.
void generic_inst_emit_callee(int inst):
	generic_inst_set_chain(inst, addr_chain_link(generic_inst_chain(inst)))


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
const int generic_infer_max_args = 16


int generic_infer_placeholder(int i):
	if (generic_infer_placeholders == 0):
		generic_infer_placeholders = cast(char*, malloc(generic_max_params * __word_size__))
		int j = 0
		while (j < generic_max_params):
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
		if (name[i] == '@'): return 1
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
	for i in range(n):
		if (strcmp(name, type_get_name(generic_infer_placeholder(i))) == 0):
			save_ptr(e, i)
			save_ptr(e + __word_size__, type_get_pointer_level(u))
			return;
	if (generic_infer_mentions_placeholder(u)):
		save_ptr(e, -2)
		save_ptr(e + __word_size__, 0)
		return;
	save_ptr(e, -1)
	save_ptr(e + __word_size__, param_type)


# Classify captured syntax without placeholder records or type interning.
# Composite types containing a parameter are opaque: another argument must
# bind that parameter before the instantiated signature can check them.
# -3 means unsupported syntax or a concrete derived type not yet registered.
int generic_infer_ast_shape(int def, generic_type_ast* node, int* data):
	if ((node == 0) || (node.application == 1)): return -3
	int type = -1
	if (node.first != 0):
		int first = 0
		int second = 0
		int first_kind = generic_infer_ast_shape(def, node.first, &first)
		if (first_kind == -3): return -3
		int second_kind = -1
		int kind = type_kind_list
		if (node.application == 2): kind = type_kind_slice
		else if (strcmp(node.name, c"set") == 0): kind = type_kind_set
		else if (strcmp(node.name, c"map") == 0):
			kind = type_kind_map
			second_kind = generic_infer_ast_shape(def, node.second, &second)
			if (second_kind == -3): return -3
		else if (strcmp(node.name, c"list") != 0): return -3
		# Concrete children retain the declaration's storage checks even
		# when a different child makes the complete shape opaque.
		int checked = -1
		if ((kind == type_kind_list) && (first_kind == -1)): checked = type_unqualified(first)
		if ((kind == type_kind_map) && (second_kind == -1)): checked = type_unqualified(second)
		if (checked >= 0):
			if (type_is_array(checked) || type_has_array_field(checked)): return -3
			if ((kind == type_kind_list) && (type_get_size(checked) <= 0)): return -3
			if ((type_num_args(checked) == 0) && (type_stack_words(checked) != 1)): return -3
		if ((first_kind != -1) || (second_kind != -1)):
			*data = 0
			return -2
		if (kind == type_kind_slice): type = type_lookup_slice(first)
		else if (kind == type_kind_map): type = type_lookup_map(first, second)
		else if (kind == type_kind_set): type = type_lookup_set(first)
		else: type = type_lookup_list(first)
	else:
		for i in range(generic_def_param_count(def)):
			if (strcmp(node.name, generic_def_param_name(def, i)) == 0):
				*data = node.stars
				return i
		type = type_lookup(node.name)
	if (type < 0): return -3
	int base = type_unqualified(type)
	if ((word_size != 8) && ((base == float64_type) || (base == int64_type) || (base == uint64_type))): return -3
	for i in range(node.stars):
		type = type_lookup_next_pointer(type)
		if (type < 0): return -3
	*data = type
	return -1


# Return an ordinary shape block without re-opening the declaration or
# adding placeholder types. Validate the entire captured header first so
# unsupported signatures keep their original diagnostics and fallback.
char* generic_infer_ast_shapes(int def):
	generic_signature_ast* signature = generic_defs[def].signature_ast
	if (signature == 0): return 0
	int data = 0
	if (generic_infer_ast_shape(def, signature.result, &data) == -3): return 0
	int[16] kinds
	int[16] types
	int count = 0
	generic_type_ast* parameter = signature.parameters
	while (parameter != 0):
		int kind = generic_infer_ast_shape(def, parameter, &data)
		if (kind == -3): return 0
		if (count < generic_infer_max_args):
			kinds[count] = kind
			types[count] = data
		count = count + 1
		parameter = parameter.next
	char* block = cast(char*, malloc(__word_size__ + generic_infer_max_args * 2 * __word_size__))
	save_ptr(block, count)
	for i in range(count):
		if (i == generic_infer_max_args): break
		save_ptr(block + __word_size__ + i * 2 * __word_size__, kinds[i])
		save_ptr(block + 2 * __word_size__ + i * 2 * __word_size__, types[i])
	return block


# Parameter shapes are extracted once and cached. Simple captured
# signatures use the syntax AST; other headers retain the nested reparse
# with placeholder types. Safe mid-parse: neither path emits code.
char* generic_infer_shapes(int def):
	if (cast(int, generic_infer_shapes_cache) == 0): generic_infer_shapes_cache = new list[int]
	while (generic_infer_shapes_cache.length <= def): generic_infer_shapes_cache.push(0)
	char* cached = cast(char*, generic_infer_shapes_cache[def])
	if (cached != 0):
		return cached
	char* captured = generic_infer_ast_shapes(def)
	if (captured != 0):
		generic_infer_shapes_cache[def] = cast(int, captured)
		return captured
	int n = generic_def_param_count(def)
	int placeholder_args = cast(int, malloc(generic_max_params * __word_size__))
	for i in range(n): save_ptr(placeholder_args + i * __word_size__, generic_infer_placeholder(i))
	char* old_subst = generic_subst_swap(generic_subst_make(def, placeholder_args, n))
	char* block = cast(char*, malloc(__word_size__ + generic_infer_max_args * 2 * __word_size__))
	int count = 0
	if (generic_header_tree_ready(def)):
		# S2.3: the placeholder walk of the captured header
		generic_signature_ast* signature = generic_defs[def].signature_ast
		generic_tree_resolve(signature.result)
		generic_type_ast* parameter = signature.parameters
		while (parameter != 0):
			int tree_param_type = generic_tree_resolve(parameter)
			if (count < generic_infer_max_args):
				generic_infer_store_shape(block, count, tree_param_type, def)
			count = count + 1
			parameter = parameter.next
		generic_tree_types = generic_tree_types + 1
	else:
		char* save = generic_reparse_save()
		generic_reparse_start(def)
		type_name() /* the return type; only the parameters matter here */
		get_token() /* the definition's own name */
		expect(c"[")
		while (peek(c"]") == 0): get_token()
		expect(c"]")
		expect(c"(")
		while (accept(c")") == 0):
			int param_type = type_name()
			if (peek(c".")): error(c"variadic parameters are not supported in generic functions")
			if ((peek(c")") == 0) & (peek(c",") == 0) & (peek(c"=") == 0)):
				get_token() /* the parameter's name */
			if (peek(c"=")): error(c"default parameter values are not supported in generic functions")
			if (count < generic_infer_max_args):
				generic_infer_store_shape(block, count, param_type, def)
			count = count + 1
			accept(c",")
		retained_source_reparse_close(file)
		generic_reparse_restore(save)
	save_ptr(block, count)
	free(generic_subst_swap(old_subst))
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
	if ((t == string_value_type) || (t == string_literal_type)):
		return string_type
	if (t == var_value_type):
		return var_type
	if (t == float32_value_type):
		return float32_type
	if (t == float64_value_type):
		return float64_type
	if (type_get_kind(t) == type_kind_slice_value): return type_get_slice(type_get_element_type(t))
	return t


void generic_infer_pointer_error(int def, int param, int arg_type, int arg_index):
	generic_infer_error_prefix(def)
	diag_part(c"cannot infer type parameter '")
	diag_part(generic_def_param_name(def, param))
	diag_part(c"' from argument ")
	diag_part(itoa(arg_index + 1))
	error_type(c": expected a pointer, got '", arg_type, c"'")


# Bind type parameter 'param' from an argument of the promoted type
# 'arg_type' against a 'T'-with-pointer-depth shape.
void generic_infer_bind(int def, char* bound, int param, int depth, int arg_type, int arg_index):
	int existing = load_ptr(bound + param * __word_size__)
	if ((arg_type == 3) && (depth == 0)):
		# untyped constant: bind 'int' when unbound, else coerce the
		# value in eax to the existing binding (e.g. int -> float)
		if (existing < 0): save_ptr(bound + param * __word_size__, type_lookup(c"int"))
		else: coerce(existing, arg_type)
		return;
	if (arg_type == 4):
		generic_infer_error_prefix(def)
		diag_part(c"cannot infer type parameter '")
		diag_part(generic_def_param_name(def, param))
		error3(c"' from argument ", itoa(arg_index + 1), c": a bare function name has no value type; use explicit type arguments")
	int stripped = generic_infer_declarable(arg_type)
	for level in range(depth):
		if (type_get_pointer_level(stripped) == 0):
			generic_infer_pointer_error(def, param, arg_type, arg_index)
		stripped = type_lookup_previous_pointer(stripped)
		if (stripped < 0): generic_infer_pointer_error(def, param, arg_type, arg_index)
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
		error_type(c"' vs '", stripped, c"'")


# A concrete (non-generic) parameter shape: the same check and coercion
# an ordinary call argument gets (check_call_argument's message).
void generic_infer_check_concrete(int def, int param_type, int arg_index, int arg_type):
	if (types_compatible_with_expression(param_type, arg_type) == 0):
		gpu_domain_check_argument(generic_def_name(def), arg_index, param_type, arg_type)
		diag_part(c"warning: function '")
		diag_part(generic_def_name(def))
		diag_part(c"' argument ")
		diag_part(itoa(arg_index + 1))
		diag_expected_got(c" type mismatch: expected '", param_type, arg_type)
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
	char* bound = cast(char*, malloc(n * __word_size__))
	int i = 0
	while (i < n):
		save_ptr(bound + i * __word_size__, -1)
		i = i + 1
	# per argument: promoted type + a flag for the post-binding check
	char* arg_records = cast(char*, malloc(generic_infer_max_args * 2 * __word_size__))
	int s = stack_pos
	int passed = 0
	get_token()
	expect(c"(")
	if (peek(c")") == 0):
		int more = 1
		while (more):
			int shape_kind = -2
			int shape_data = 0
			if ((passed < shape_count) && (passed < generic_infer_max_args)):
				shape_kind = load_ptr(shapes + __word_size__ + passed * 2 * __word_size__)
				shape_data = load_ptr(shapes + 2 * __word_size__ + passed * 2 * __word_size__)
			int arg_type = expression()
			arg_type = promote(arg_type)
			int needs_check = 0
			if (shape_kind >= 0):
				generic_infer_bind(def, bound, shape_kind, shape_data, arg_type, passed)
			else if (shape_kind == -1):
				generic_infer_check_concrete(def, shape_data, passed, arg_type)
			else: needs_check = 1
			if (passed < generic_infer_max_args):
				save_ptr(arg_records + passed * 2 * __word_size__, arg_type)
				save_ptr(arg_records + __word_size__ + passed * 2 * __word_size__, needs_check)
			push_call_argument(arg_type)
			passed = passed + 1
			more = accept(c",")
	if (peek(c")") == 0): error3(c"')' expected in call to generic '", generic_def_name(def), c"'")
	i = 0
	while (i < n):
		if (load_ptr(bound + i * __word_size__) < 0):
			generic_infer_error_prefix(def)
			diag_part(c"cannot infer type argument '")
			diag_part(generic_def_param_name(def, i))
			error3(c"'; use explicit type arguments, e.g. '", generic_def_name(def), c"[int](...)'")
		i = i + 1
	int args = cast(int, malloc(generic_max_params * __word_size__))
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
			error3(c"inferred call returns a struct by value; use explicit type arguments, e.g. '", generic_def_name(def), c"[int](...)'")
	int expected = type_function_param_count(sig)
	if (passed != expected):
		diag_part(c"function '")
		diag_part(generic_inst_mangled(inst))
		diag_part(c"' expects ")
		type_error3(itoa(expected), c" arguments, got ", itoa(passed))
	# opaque-shape arguments get their check against the now-concrete
	# signature (type-parameter shapes match by construction; concrete
	# shapes were checked while parsing)
	i = 0
	while ((i < passed) && (i < generic_infer_max_args)):
		if (load_ptr(arg_records + __word_size__ + i * 2 * __word_size__)):
			check_call_argument(-1, sig, generic_inst_mangled(inst), i, load_ptr(arg_records + i * 2 * __word_size__))
		i = i + 1
	free(arg_records)
	# callee: a direct reference when the instantiation's symbol exists
	# (already compiled, or being compiled right now at the drain);
	# otherwise a mov-imm slot on the instantiation's backpatch chain,
	# exactly like the explicit path
	if (sym_lookup(generic_inst_mangled(inst)) >= 0): sym_get_value(generic_inst_mangled(inst))
	else: generic_inst_emit_callee(inst)
	call_eax()
	pop_to(s)
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
	if (generic_def_count() == 0): return 0
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0): return 0
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
		error3(c"' requires explicit type arguments, e.g. '", token, c"[int](...)'")
	get_token()
	int args = cast(int, malloc(generic_max_params * __word_size__))
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
	generic_inst_emit_callee(inst)
	return 4


# Compile one queued function instantiation: re-parse the definition
# with the substitution active, declaring and defining the mangled
# symbol through the ordinary function_definition() path, then patch
# the call sites emitted before the body existed.
void generic_instantiate_function(int inst):
	int def = generic_inst_def(inst)
	char* save = generic_reparse_save()
	char* old_subst = generic_subst_swap(generic_subst_make(def, generic_inst_args(inst), generic_inst_arg_count(inst)))
	generic_reparse_open(def, generic_defs[def].follow)
	int decl_type = type_name()
	int current_symbol = sym_declare_global(generic_inst_mangled(inst), decl_type, 1)
	get_token() /* the definition's own name; the instance is the mangled one */
	expect(c"[")
	while (peek(c"]") == 0): get_token()
	expect(c"]")
	expect(c"(")
	profile_use_definition_start = generic_def_offset(def)   # P2: --profile-use
	function_definition(current_symbol)
	if (table[current_symbol + 1] != 'D'):
		error3(c"generic function '", generic_def_name(def), c"' has no body")
	int address = load_int(table + current_symbol + 2)
	retained_source_reparse_close(file)
	free(generic_subst_swap(old_subst))
	generic_reparse_restore(save)
	# patch the pre-definition call sites (json_codec chain encoding)
	addr_chain_patch(generic_inst_chain(inst), address)


# Forward calls: 'fwd[int](x)' where the generic's definition appears
# later in the file (or a later file). The name is not registered yet,
# so the call is recorded speculatively: type arguments and a private
# backpatch chain, resolved at the drain once every definition has been
# seen. No signature exists at the call site, so these calls skip the
# argument checks (like calls to asm runtime stubs) and cannot return
# structs by value (checked at resolve time).
struct generic_forward_record:
	char* name
	int args          # int* vector of type argument indices
	int arg_count
	int chain         # patch-chain head
	char* call_file   # first call site, for the error message
	int call_line


list[generic_forward_record] generic_forwards


int generic_forward_count():
	if (cast(int, generic_forwards) == 0): return 0
	return generic_forwards.length


# An unknown identifier directly followed by '[' in expression position:
# only worth trying as a forward generic call when nothing else can
# claim the name.
int generic_forward_call_ready():
	int c0 = token[0]
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0): return 0
	if (nextc != '['): return 0
	if (sym_lookup(token) >= 0): return 0
	if (type_lookup(token) >= 0): return 0
	if (import_alias_lookup(token) >= 0): return 0
	return 1


# The (still unknown) generic's name is the current token; leaves the
# closing ']' current, like generic_call_expr().
int generic_forward_call_expr():
	if (cast(int, generic_forwards) == 0): generic_forwards = new list[generic_forward_record]
	char* name = strclone(token)
	char* call_file = strclone(filename)
	int call_line = diag_token_line
	get_token()
	expect(c"[")
	int args = cast(int, malloc(generic_max_params * __word_size__))
	int arg_count = 0
	int more = 1
	while (more):
		if (arg_count >= generic_max_params): error(c"too many type arguments")
		save_ptr(args + arg_count * __word_size__, type_name())
		arg_count = arg_count + 1
		more = accept(c",")
	if (peek(c"]") == 0): error3(c"']' expected in type argument list, found '", token, c"'")
	# a chain slot for this call; merged into the instantiation's chain
	# once the definition is known
	generic_forward_record rec
	rec.name = name
	rec.args = args
	rec.arg_count = arg_count
	rec.chain = addr_chain_link(0)
	rec.call_file = call_file
	rec.call_line = call_line
	generic_forwards.push(rec)
	# keep postfix_expr's callee lookup from matching a stale identifier
	strcpy(last_identifier, c"$forward generic call$")
	return 4


void generic_forward_error(int f, char* message):
	diag_part(c"generic function '")
	diag_part(generic_forwards[f].name)
	diag_part(c"' ")
	diag_part(message)
	diag_part(c" (called at ")
	diag_part(generic_forwards[f].call_file)
	error3(c":", itoa(generic_forwards[f].call_line), c")")


# Append the forward record's chain to the instantiation's chain: walk
# the forward chain to its terminating slot (which stores code_offset)
# and point it at the instantiation's current head.
void generic_forward_merge_chain(int f, int inst):
	int head = generic_forwards[f].chain
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
	char* name = generic_forwards[f].name
	int args = generic_forwards[f].args
	int arg_count = generic_forwards[f].arg_count
	int def = generic_def_lookup(name, 0)
	if (def < 0): generic_forward_error(f, c"is not defined")
	if (arg_count != generic_def_param_count(def)):
		generic_forward_error(f, c"called with the wrong number of type arguments")
	char* mangled = generic_mangle(name, args, arg_count)
	int t = sym_lookup(mangled)
	if (t >= 0):
		if (table[t + 1] == 'D'):
			# already compiled: patch this record's chain directly
			int address = load_int(table + t + 2)
			addr_chain_patch(generic_forwards[f].chain, address)
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
	int is_ident = is_ident_start_byte(c0)
	if (is_ident == 0): return 0
	if (peek(c"const") | peek(c"map") | peek(c"set") | peek(c"list")): return 0
	if (nextc == '['): return 0
	char* save = generic_reparse_save()
	get_token()
	while (accept(c"*")) {}
	int c1 = token[0]
	int name_is_ident = is_ident_start_byte(c1)
	int is_generic = name_is_ident & (nextc == '[')
	# rewind: byte_offset (save offset 28) counts consumed bytes, so it
	# is exactly the fd position the saved lookahead expects
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	if (is_generic): return generic_declaration_scan()
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
		while (generic_forwards_resolved < generic_forward_count()):
			generic_resolve_forward(generic_forwards_resolved)
			generic_forwards_resolved = generic_forwards_resolved + 1
			progress = 1
		while (generic_insts_compiled < generic_inst_count()):
			if (generic_inst_done(generic_insts_compiled) == 0):
				generic_inst_set_done(generic_insts_compiled)
				generic_instantiate_function(generic_insts_compiled)
				progress = 1
			generic_insts_compiled = generic_insts_compiled + 1


/*
'w check' coverage for uninstantiated generics. A generic definition is
captured but never parsed past its header, so before this a check of a
generic-only module (structures/heap.w) exited clean even when every
body was ill-typed - the bodies were only type-checked once a consumer
instantiated them. In check mode (generic_check_mode, set by check_main
in compiler/compiler.w and by nothing else - ordinary compilation and
the deps/symbols/defhash subcommands that share link_impl's check_mode
are unaffected), every definition that nothing instantiated is
self-instantiated once with each type parameter bound to 'int': the
canonical word-sized payload, the same binding inference gives untyped
constants and the binding the containers' documented payload policy
("keep T word-sized; put aggregates behind a pointer") assumes.

The synthetic instantiation is an ordinary registry record: its mangled
name ('max$int') is exactly a real [int] instantiation's, so
generic_inst_intern dedupes against one, the body compiles at the usual
generic_finish_instantiations drain (into the discarded check output),
and diagnostics carry the definition's real source locations because
the re-parse machinery reads the recorded span of the real file.

A definition the user DID instantiate - explicitly, by inference, or
through a still-pending forward call - is skipped: its body was already
type-checked against the arguments it is really used with, and a body
that is only meaningful for those arguments (say 'strlen(a)' on a T
always bound to char*) must not produce false diagnostics against a
type it is never used with. The same reasoning is why an unused
definition's int-instantiation diagnostics are treated as true
positives: a generic whose body cannot even be checked for the
documented word-sized payload has no checkable instantiation at all,
which is exactly what 'w check' should surface.
*/
int generic_check_mode


# 1 when some function instantiation already covers this definition's
# body: a recorded instantiation, or a pending forward call the drain
# will turn into one. Struct instantiations live only in the type table
# (no registry record), so struct defs always report unused here; the
# caller dedupes them against the type table by mangled name instead,
# and an extra [int] field-list re-parse next to a real [char*] one is
# harmless anyway - field lists contain no expressions to mis-check.
int generic_def_used(int def):
	int i = 0
	while (i < generic_inst_count()):
		if (generic_inst_def(i) == def): return 1
		i = i + 1
	if (generic_def_kind(def) == 0):
		i = 0
		while (i < generic_forward_count()):
			if (strcmp(generic_forwards[i].name, generic_def_name(def)) == 0): return 1
			i = i + 1
	return 0


# Called by link_impl at the top-level boundary, after every user file
# has compiled (so all definitions are registered and all symbols their
# bodies may reference exist) and before the drain that compiles the
# queued bodies. A no-op unless check_main armed generic_check_mode.
void generic_check_instantiate_all():
	if (generic_check_mode == 0): return
	int int_type = type_lookup(c"int")
	int d = 0
	while (d < generic_def_count()):
		if (generic_def_used(d) == 0):
			int n = generic_def_param_count(d)
			int args = cast(int, malloc(generic_max_params * __word_size__))
			for i in range(n): save_ptr(args + i * __word_size__, int_type)
			char* mangled = generic_mangle(generic_def_name(d), args, n)
			if (generic_def_kind(d) == 1):
				# struct: instantiate eagerly (fills the type table only,
				# no code) unless a real [int] instantiation already did
				if (type_lookup(mangled) < 0): generic_instantiate_struct(d, args, n, mangled)
				else: free(mangled)
				free(cast(char*, args))
			else:
				# function: intern a record; the drain compiles the body
				generic_inst_intern(d, args, n, mangled)
		d = d + 1
