# Conservative incremental native compilation using the production compiler.
# One process owns one session. Inputs are ordered complete scalar functions;
# this is a compiler API, not a second parser/emitter or a binary artifact cache.
# Admission below excludes constructs whose compilation can mutate a retained
# prefix (prototypes, imports, generics, types, helpers and global declarations).
# The prefix is the run of definitions whose compiled function is unchanged:
# equal source bytes, or (with the retained forest on) a source whose retained
# function tree equals the compiled one (see "Retained-tree reuse" below). It
# keeps its code, symbols and AST nodes. Edits roll back to the first changed
# definition and recompile its suffix.
import repl.core
import lib.str

struct incremental_entry:
	char* source
	char* name
	repl_state before
	# Warnings its compile reported (zero under --strict).
	int warnings

struct incremental_result:
	int status
	int reused
	int compiled
	int failed_index
	char* message
	# Of reused: definitions whose bytes changed but whose retained tree did
	# not, and changed definitions probed for that (S2.4).
	int tree_reused
	int tree_probed

list[incremental_entry*] incremental_entries
repl_state incremental_base
repl_state incremental_end
int incremental_active
int incremental_ast_mode
int incremental_required_mode
int incremental_retain_mode
int incremental_emit_mode
char* incremental_options


# These settings define emitted code, diagnostics and compilation side effects.
# The prelude is an immutable in-process snapshot, never loaded from disk again.
void incremental_option(string_builder* key, int value):
	string_append_int(key, value)
	string_append_char(key, 44)


char* incremental_options_key():
	string_builder* key = string_new()
	incremental_option(key, cast(int, code))
	incremental_option(key, cast(int, table))
	incremental_option(key, code_offset)
	incremental_option(key, word_size)
	incremental_option(key, word_size_log2)
	incremental_option(key, target_isa)
	incremental_option(key, target_os)
	incremental_option(key, data_split)
	incremental_option(key, bounds_mode)
	incremental_option(key, strict_mode)
	incremental_option(key, check_bool_ops_mode)
	incremental_option(key, check_imports_mode)
	incremental_option(key, generic_check_mode)
	incremental_option(key, deps_mode)
	incremental_option(key, defhash_mode)
	incremental_option(key, ast_audit_mode)
	incremental_option(key, analysis_mode)
	incremental_option(key, lint_mode)
	incremental_option(key, lint_fix_mode)
	char* result = key.data
	free(key)
	return result


int incremental_scalar(char* word):
	return strcmp(word, c"int") == 0 || strcmp(word, c"bool") == 0 || strcmp(word, c"char") == 0 || strcmp(word, c"void") == 0


int incremental_forbidden(char* word):
	if (incremental_scalar(word) == 0 && type_lookup(word) >= 0): return 1
	string_builder* needle = string_new()
	string_append_char(needle, ' ')
	string_append(needle, word)
	string_append_char(needle, ' ')
	int forbidden = contains(c" import type struct union enum extern c_lib c_import const gpu message export thread_local operator kernel yield defer raw_asm asm new cast sizeof print println to_json from_json to_proto from_proto proto_descriptor goto label function generator debugger for switch case default launch gpu_for ", needle.data)
	string_free(needle)
	return forbidden


int incremental_control(char* word):
	return strcmp(word, c"return") == 0 || strcmp(word, c"if") == 0 || strcmp(word, c"else") == 0 || strcmp(word, c"while") == 0 || strcmp(word, c"break") == 0 || strcmp(word, c"continue") == 0 || strcmp(word, c"pass") == 0 || strcmp(word, c"true") == 0 || strcmp(word, c"false") == 0


int incremental_name_allowed(char* word):
	return incremental_scalar(word) == 0 && incremental_forbidden(word) == 0 && incremental_control(word) == 0 && starts_with(word, c"__") == 0


int incremental_punctuation(int c):
	char* allowed = c"()+-*/%|^~!=<>:,"
	int i = 0
	while (allowed[i]):
		if (allowed[i] == c): return 1
		i = i + 1
	return 0


int incremental_ident_start(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_')


int incremental_ident_part(int c):
	return incremental_ident_start(c) || ((c >= '0') && (c <= '9'))





int incremental_contains(list[char*] names, char* name):
	for char* known in names:
		if (strcmp(known, name) == 0): return 1
	return 0


void incremental_strings_free(list[char*] strings):
	for char* item in strings: free(item)
	strings.free()


# A deliberately narrow admission lexer, not a substitute for W parsing.
# Newlines inside the body must be followed by indentation, whitespace or a
# comment; there can be exactly one top-level declaration in an entry.
list[char*] incremental_tokens(char* source):
	list[char*] tokens = new list[char*]
	int i = 0
	int body = 0
	int line_start = 1
	while (source[i]):
		int c = source[i]
		if (c == 10):
			# Keep statement boundaries: a star on the next physical line
			# must not inherit an expression operand from the preceding line.
			if (body): tokens.push(strclone(c"\n"))
			line_start = 1
			i = i + 1
			continue
		if (c == 9 || c == ' ' || c == 13):
			# Only tabs establish W block scope. Spaces alone must not admit
			# a second top-level declaration disguised as a function local.
			if (c == 9): line_start = 0
			i = i + 1
			continue
		if (c == '#'):
			while (source[i] && source[i] != 10): i = i + 1
			continue
		if (body && line_start):
			incremental_strings_free(tokens)
			return 0
		line_start = 0
		int start = i
		if (incremental_ident_part(c)):
			while (incremental_ident_part(source[i])): i = i + 1
		else:
			# Strings, pointers' address operator, braces, dots, brackets,
			# preprocessor syntax and non-ASCII identifiers are excluded.
			if (incremental_punctuation(c) == 0):
				incremental_strings_free(tokens)
				return 0
			i = i + 1
			if (c == ':'): body = 1
		char* word = malloc(i - start + 1)
		strncpy(word, source + start, i - start)
		word[i - start] = 0
		if (incremental_forbidden(word)):
			free(word)
			incremental_strings_free(tokens)
			return 0
		tokens.push(word)
	return tokens


# Returns an owned function name on success. Only scalar parameter and local
# declarations, scalar expressions, if/else/while and calls to session functions
# are admitted. Unknown identifiers are rejected before changing compiler state.
char* incremental_admit(char* source, list[char*] functions):
	list[char*] tokens = incremental_tokens(source)
	if (tokens == 0): return 0
	char* name = 0
	list[char*] locals = new list[char*]
	int ok = tokens.length >= 6
	if (ok): ok = incremental_scalar(tokens[0]) && incremental_ident_start(tokens[1][0]) && strcmp(tokens[2], c"(") == 0
	if (ok):
		if (incremental_name_allowed(tokens[1]) == 0 || starts_with(tokens[1], c"test_")): ok = 0
	int pos = 3
	while (ok && pos < tokens.length && strcmp(tokens[pos], c")") != 0):
		if (pos + 1 >= tokens.length):
			ok = 0
			break
		if (incremental_scalar(tokens[pos]) == 0 || strcmp(tokens[pos], c"void") == 0 || incremental_ident_start(tokens[pos + 1][0]) == 0 || incremental_name_allowed(tokens[pos + 1]) == 0):
			ok = 0
			break
		locals.push(strclone(tokens[pos + 1]))
		pos = pos + 2
		if (pos < tokens.length && strcmp(tokens[pos], c",") == 0): pos = pos + 1
		else: break
	if (ok):
		ok = pos + 1 < tokens.length
		if (ok): ok = strcmp(tokens[pos], c")") == 0 && strcmp(tokens[pos + 1], c":") == 0
	pos = pos + 2
	int body = pos
	# Collect scalar local names first; the production compiler still checks
	# declaration order and all expression/type/control-flow semantics.
	while (ok && pos + 1 < tokens.length):
		if (incremental_scalar(tokens[pos])):
			if (strcmp(tokens[pos], c"void") == 0 || incremental_ident_start(tokens[pos + 1][0]) == 0 || incremental_name_allowed(tokens[pos + 1]) == 0): ok = 0
			else:
				locals.push(strclone(tokens[pos + 1]))
				if (pos + 2 < tokens.length && strcmp(tokens[pos + 2], c"(") == 0): ok = 0
		pos = pos + 1
	pos = body
	int next_control_colon = -1
	while (ok && pos < tokens.length):
		char* word = tokens[pos]
		# Require parenthesized if/while conditions and an immediate block
		# colon, so an inline statement cannot smuggle in a label declaration.
		if (strcmp(word, c"if") == 0 || strcmp(word, c"while") == 0):
			int scan = pos + 1
			if (scan >= tokens.length || strcmp(tokens[scan], c"(") != 0): ok = 0
			int depth = 0
			while (ok && scan < tokens.length):
				if (strcmp(tokens[scan], c"(") == 0): depth = depth + 1
				if (strcmp(tokens[scan], c")") == 0): depth = depth - 1
				scan = scan + 1
				if (depth == 0): break
			next_control_colon = scan
			if (scan >= tokens.length || strcmp(tokens[scan], c":") != 0): ok = 0
		if (strcmp(word, c"else") == 0): next_control_colon = pos + 1
		if (strcmp(word, c":") == 0 && pos != next_control_colon): ok = 0
		# A star is admitted only as multiplication, never an untyped memory
		# dereference. Labels and inferred declarations are excluded above.
		if (strcmp(word, c"*") == 0):
			if (pos == body): ok = 0
			else:
				char* previous = tokens[pos - 1]
				if (strcmp(previous, c")") != 0 && (incremental_ident_part(previous[0]) == 0 || incremental_control(previous))): ok = 0
		# Every call suffix must follow a directly named session function.
		# Check at '(' so grouped callees, numeric callees and intervening
		# newlines cannot evade the named-identifier check.
		if (strcmp(word, c"(") == 0):
			int previous_pos = pos - 1
			while (previous_pos >= body && strcmp(tokens[previous_pos], c"\n") == 0): previous_pos = previous_pos - 1
			if (previous_pos >= body):
				char* previous = tokens[previous_pos]
				if (strcmp(previous, c")") == 0): ok = 0
				if (incremental_ident_part(previous[0]) && incremental_control(previous) == 0):
					if (incremental_contains(locals, previous)): ok = 0
					if (incremental_contains(functions, previous) == 0 && strcmp(previous, tokens[1]) != 0): ok = 0
		if (incremental_ident_start(word[0])):
			int known = incremental_scalar(word) || incremental_contains(locals, word) || incremental_contains(functions, word)
			if (strcmp(word, tokens[1]) == 0): known = 1
			if (incremental_control(word)): known = 1
			if (known == 0): ok = 0
		pos = pos + 1
	if (ok): name = strclone(tokens[1])
	incremental_strings_free(locals)
	incremental_strings_free(tokens)
	return name


void incremental_restore(repl_state* state):
	repl_state_restore(state)
	current_function_symbol = state.function_symbol
	repl_discard_late_bind()
	repl_sites_truncate(state.sites_count)
	repl_state_clear_context()


void incremental_drop(int count):
	while (incremental_entries.length > count):
		incremental_entry* entry = incremental_entries.pop()
		free(entry.source)
		free(entry.name)
		free(cast(char*, entry))


# ---------------------------------------------------------------------------
# Retained-tree reuse (S2.4). A definition whose bytes changed keeps its
# compiled function when the retained tree of the new source equals the tree
# the kept compile retained. A body is not parsed without emitting it, so the
# new tree comes from a probe: the source compiles once at the end of the
# session (standard error muted), the two trees are compared, and the probe
# is rolled back. Positions are part of the tree (every node's line and
# column), so the kept code's debug rows and its diagnostics' locations are
# those of the new source; in practice the reusable edits are comments and
# trailing blanks. A cheap layout check (incremental_layout_equal) decides
# whether a probe can succeed at all; the trees decide whether it did. The
# kept retained source version and staging file keep the bytes compiled.
#
# Trees are compared field by field. IDs are session-local, so references are
# compared by meaning: a node or binding of the definition's own source by
# its position among that source's records, a semantic type structurally, a
# raw symbol-table offset at or above the compile's starting table position
# (its own declarations, locals included) relative to that position, and
# anything older verbatim. The function node's name (the REPL entry symbol)
# and the staged file's path are per-compile spellings and are not compared.

struct incremental_side:
	int source
	int node_base
	int table_base
	int binding_base
	list[int] nodes
	list[int] bindings


# The text with '#' comments and trailing blanks removed, line by line.
# Admission excludes strings and character literals, so '#' always starts a
# comment in an admitted source.
char* incremental_layout(char* source):
	int length = strlen(source)
	char* out = malloc(length + 1)
	int at = 0
	int line_start = 0
	int i = 0
	while (1):
		int c = source[i]
		if (c == 0 || c == 10):
			int end = line_start
			while (end < i && source[end] != '#'): end = end + 1
			while (end > line_start && (source[end - 1] == ' ' || source[end - 1] == 9 || source[end - 1] == 13)): end = end - 1
			for j in range(line_start, end):
				out[at] = source[j]
				at = at + 1
			if (c == 0): break
			out[at] = 10
			at = at + 1
			line_start = i + 1
		i = i + 1
	out[at] = 0
	return out


# 1 when two sources can only differ in comments and trailing blanks: the
# same lines, each with the same code at the same columns.
int incremental_layout_equal(char* a, char* b):
	char* left = incremental_layout(a)
	char* right = incremental_layout(b)
	int equal = strcmp(left, right) == 0
	free(left)
	free(right)
	return equal


# The records of one compile's own source: its nodes and bindings among
# those created from the bases up to the given ends.
void incremental_side_collect(incremental_side* side, int source, int node_end, int binding_end):
	side.source = source
	side.nodes = new list[int]
	side.bindings = new list[int]
	for i in range(side.node_base, node_end):
		if (retained_nodes[i].source == source): side.nodes.push(i)
	for i in range(side.binding_base, binding_end):
		if (retained_bindings[i].source == source): side.bindings.push(i)


void incremental_side_free(incremental_side* side):
	side.nodes.free()
	side.bindings.free()


# Position of id in an ascending ID list, or -1.
int incremental_index(list[int] ids, int id):
	int low = 0
	int high = ids.length
	while (low < high):
		int mid = (low + high) / 2
		if (ids[mid] < id): low = mid + 1
		else: high = mid
	if (low < ids.length && ids[low] == id): return low
	return -1


int incremental_text_equal(char* a, char* b):
	if (a == 0 || b == 0): return a == b
	return strcmp(a, b) == 0


int incremental_bytes_equal(char* a, char* b, int length):
	if (a == 0 || b == 0): return a == b
	for i in range(length):
		if (a[i] != b[i]): return 0
	return 1


int incremental_type_equal(int a, int b, int depth);


int incremental_type_list_equal(list[int] a, list[int] b, int depth):
	if (a == 0 || b == 0): return a == b
	if (a.length != b.length): return 0
	for i in range(a.length):
		if (incremental_type_equal(a[i], b[i], depth) == 0): return 0
	return 1


# Semantic types are re-recorded per source version, so equal types of two
# compiles usually have different IDs.
int incremental_type_equal(int a, int b, int depth):
	if (a == b): return 1
	if (a < 0 || b < 0 || depth > 16): return 0
	retained_type* x = retained_types[a]
	retained_type* y = retained_types[b]
	if (incremental_text_equal(x.name, y.name) == 0 || x.kind != y.kind || x.size != y.size): return 0
	if (x.pointer_level != y.pointer_level || x.array_length != y.array_length): return 0
	if (incremental_type_equal(x.target, y.target, depth + 1) == 0): return 0
	if (incremental_type_equal(x.return_type, y.return_type, depth + 1) == 0): return 0
	if (incremental_type_list_equal(x.parameters, y.parameters, depth + 1) == 0): return 0
	if (x.fields.length != y.fields.length || x.constants.length != y.constants.length): return 0
	for i in range(x.fields.length):
		retained_field* f = x.fields[i]
		retained_field* g = y.fields[i]
		if (incremental_text_equal(f.name, g.name) == 0 || f.offset != g.offset): return 0
		if (incremental_type_equal(f.type, g.type, depth + 1) == 0): return 0
	for i in range(x.constants.length):
		retained_constant* c = x.constants[i]
		retained_constant* d = y.constants[i]
		if (incremental_text_equal(c.name, d.name) == 0 || c.value != d.value): return 0
	return 1


int incremental_node_ref_equal(incremental_side* a, int x, incremental_side* b, int y):
	if (x < 0 || y < 0): return x == y
	int i = incremental_index(a.nodes, x)
	int j = incremental_index(b.nodes, y)
	if (i >= 0 || j >= 0): return i == j
	return x == y


int incremental_binding_ref_equal(incremental_side* a, int x, incremental_side* b, int y):
	if (x < 0 || y < 0): return x == y
	int own_x = x >= a.binding_base
	int own_y = y >= b.binding_base
	if (own_x != own_y): return 0
	if (own_x == 0): return x == y
	int i = incremental_index(a.bindings, x)
	return i >= 0 && i == incremental_index(b.bindings, y)


int incremental_symbol_equal(incremental_side* a, int x, incremental_side* b, int y):
	int own_x = x >= a.table_base
	int own_y = y >= b.table_base
	if (own_x != own_y): return 0
	if (own_x): return x - a.table_base == y - b.table_base
	return x == y


int incremental_file_equal(incremental_side* a, char* x, incremental_side* b, char* y):
	int own_x = incremental_text_equal(x, retained_sources[a.source].path)
	int own_y = incremental_text_equal(y, retained_sources[b.source].path)
	if (own_x || own_y): return own_x == own_y
	return incremental_text_equal(x, y)


int incremental_name_equal(int kind, char* x, char* y):
	if (kind == retained_module): return 1
	if (x != 0 && y != 0 && starts_with(x, c"__repl_") && starts_with(y, c"__repl_")): return 1
	return incremental_text_equal(x, y)


# 1-based line of a byte offset in a side's source.
int incremental_line(incremental_side* side, int offset):
	list[int] lines = retained_sources[side.source].lines
	int low = 0
	int high = lines.length
	while (low < high):
		int mid = (low + high) / 2
		if (lines[mid] <= offset): low = mid + 1
		else: high = mid
	return low


# Column of a byte offset on its line, where every offset past the line's
# code (in trailing blanks or a comment) counts as the end of that code.
int incremental_column(incremental_side* side, int line, int offset):
	retained_source* source = retained_sources[side.source]
	int start = source.lines[line - 1]
	int end = start
	while ((end < source.length) && (source.bytes[end] != 10) && (source.bytes[end] != '#')): end = end + 1
	while ((end > start) && ((source.bytes[end - 1] == ' ') || (source.bytes[end - 1] == 9) || (source.bytes[end - 1] == 13))): end = end - 1
	if (offset > end): offset = end
	return offset - start


# A recorded line and column, with the column clamped like an offset's.
int incremental_location_equal(incremental_side* a, int line, int column, incremental_side* b, int line_b, int column_b):
	if (line != line_b): return 0
	if (column == column_b): return 1
	list[int] lines_a = retained_sources[a.source].lines
	list[int] lines_b = retained_sources[b.source].lines
	if ((line < 1) || (line > lines_a.length) || (line > lines_b.length) || (column < 1) || (column_b < 1)): return 0
	return incremental_column(a, line, lines_a[line - 1] + column - 1) == incremental_column(b, line, lines_b[line - 1] + column_b - 1)


int incremental_position_equal(incremental_side* a, int x, incremental_side* b, int y):
	if (x <= 0 || y <= 0): return x == y
	int line = incremental_line(a, x)
	if (line == 0 || line != incremental_line(b, y)): return 0
	return incremental_column(a, line, x) == incremental_column(b, line, y)


int incremental_node_equal(incremental_side* a, int i, incremental_side* b, int j):
	retained_node* x = retained_nodes[i]
	retained_node* y = retained_nodes[j]
	if (x.kind != y.kind): return 0
	if (incremental_location_equal(a, x.line, x.column, b, y.line, y.column) == 0): return 0
	if (incremental_name_equal(x.kind, x.name, y.name) == 0): return 0
	if (incremental_node_ref_equal(a, x.parent, b, y.parent) == 0): return 0
	# Byte offsets move with comment edits, so they compare as positions,
	# and an extent that ends in trailing blanks or a comment (where the
	# next token starts) ends at the line's code. The module node spans
	# the whole file and is skipped.
	if (x.kind != retained_module):
		if (incremental_position_equal(a, x.end, b, y.end) == 0): return 0
	if (incremental_position_equal(a, x.final_token_offset, b, y.final_token_offset) == 0): return 0
	if (x.op != y.op || x.left != y.left || x.right != y.right || x.next_arg != y.next_arg): return 0
	if (x.literal_value != y.literal_value || x.literal_high != y.literal_high || x.literal_length != y.literal_length): return 0
	if (incremental_bytes_equal(x.literal_text, y.literal_text, x.literal_length) == 0): return 0
	if (x.type_size != y.type_size || x.type_pointer_level != y.type_pointer_level): return 0
	if (incremental_text_equal(x.result_type, y.result_type) == 0): return 0
	if (incremental_text_equal(x.binding_name, y.binding_name) == 0): return 0
	if (incremental_file_equal(a, x.binding_file, b, y.binding_file) == 0): return 0
	if (incremental_location_equal(a, x.binding_line, x.binding_column, b, y.binding_line, y.binding_column) == 0): return 0
	if (x.binding_scope != y.binding_scope || x.binding_slot != y.binding_slot): return 0
	if (incremental_type_equal(x.semantic_type, y.semantic_type, 0) == 0): return 0
	if (incremental_binding_ref_equal(a, x.binding, b, y.binding) == 0): return 0
	if (incremental_binding_ref_equal(a, x.name_binding, b, y.name_binding) == 0): return 0
	if (x.value != y.value || x.high != y.high): return 0
	if (incremental_symbol_equal(a, x.symbol, b, y.symbol) == 0): return 0
	if (x.in_cast != y.in_cast || x.binding_offset != y.binding_offset || x.binding_text_offset != y.binding_text_offset): return 0
	if (x.it_slot != y.it_slot || x.readonly != y.readonly || x.whole_expression != y.whole_expression): return 0
	if (x.qualified != y.qualified || x.generic_parameters != y.generic_parameters || x.generic_offset != y.generic_offset): return 0
	if (x.generic_instance != y.generic_instance || x.generic_arity != y.generic_arity): return 0
	if (x.infer_coercion != y.infer_coercion || x.result_is_value != y.result_is_value || x.type_value_flags != y.type_value_flags): return 0
	if (incremental_type_equal(x.generic_signature, y.generic_signature, 0) == 0): return 0
	if (incremental_type_equal(x.call_receiver_type, y.call_receiver_type, 0) == 0): return 0
	if (incremental_type_equal(x.infer_want, y.infer_want, 0) == 0): return 0
	if (incremental_text_equal(x.payload_text, y.payload_text) == 0): return 0
	if (x.arena_text_length != y.arena_text_length || x.arena_type_names_length != y.arena_type_names_length): return 0
	if (incremental_bytes_equal(x.arena_text, y.arena_text, x.arena_text_length) == 0): return 0
	if (incremental_bytes_equal(x.arena_type_names, y.arena_type_names, x.arena_type_names_length) == 0): return 0
	if (incremental_text_equal(x.import_path, y.import_path) == 0 || incremental_text_equal(x.import_alias, y.import_alias) == 0): return 0
	return x.import_source == y.import_source


int incremental_binding_equal(incremental_side* a, int i, incremental_side* b, int j):
	retained_binding* x = retained_bindings[i]
	retained_binding* y = retained_bindings[j]
	if (incremental_text_equal(x.name, y.name) == 0 || incremental_file_equal(a, x.file, b, y.file) == 0): return 0
	if (x.scope != y.scope || incremental_location_equal(a, x.line, x.column, b, y.line, y.column) == 0): return 0
	# A local's slot is a frame offset; a global's is its address.
	if ((x.scope == 'L' || x.scope == 'A') && x.slot != y.slot): return 0
	if (incremental_node_ref_equal(a, x.owner, b, y.owner) == 0): return 0
	if (incremental_binding_ref_equal(a, x.linkage, b, y.linkage) == 0): return 0
	if (incremental_symbol_equal(a, x.origin, b, y.origin) == 0): return 0
	if (incremental_type_equal(x.type, y.type, 0) == 0 || incremental_type_equal(x.return_type, y.return_type, 0) == 0): return 0
	return incremental_type_list_equal(x.parameters, y.parameters, 0)


int incremental_trees_equal(incremental_side* a, incremental_side* b):
	if (a.nodes.length == 0 || a.nodes.length != b.nodes.length || a.bindings.length != b.bindings.length): return 0
	for i in range(a.nodes.length):
		if (incremental_node_equal(a, a.nodes[i], b, b.nodes[i]) == 0): return 0
	for i in range(a.bindings.length):
		if (incremental_binding_equal(a, a.bindings[i], b, b.bindings[i]) == 0): return 0
	return 1


# Code length the compiler recorded for a defined function, or -1.
int incremental_function_length(int symbol):
	if (symbol < 0): return -1
	if (table[symbol + 1] != 'D'): return -1
	return load_int(table + symbol + 14)


# Compile source at the end of the session without running it, with the
# standard error stream sent to /dev/null (a probe's diagnostics belong to
# the recompile, if one follows), and compare its tree with the kept
# definition's. The session is rolled back to its state before the probe.
int incremental_tree_unchanged(int index, char* source):
	incremental_entry* kept = incremental_entries[index]
	repl_state* after = &incremental_end
	if (index + 1 < incremental_entries.length): after = &incremental_entries[index + 1].before
	if (kept.before.retained.sources >= after.retained.sources): return 0
	int kept_length = incremental_function_length(sym_probe(kept.name))
	incremental_side old_side
	old_side.node_base = kept.before.retained.nodes
	old_side.table_base = kept.before.table_pos
	old_side.binding_base = kept.before.retained.bindings
	incremental_side_collect(&old_side, kept.before.retained.sources, after.retained.nodes, after.retained.bindings)
	int probe_source = retained_sources.length
	incremental_side new_side
	new_side.node_base = retained_nodes.length
	new_side.table_base = table_pos
	new_side.binding_base = retained_bindings.length
	int warnings_before = warning_count
	# The tokenizer reports space indentation once per line number; the
	# probe's report must not silence the recompile's.
	int spaces_warned = spaces_warned_line
	int old_no_run = repl_no_run
	repl_no_run = 1
	# Settle color detection on the real stream before muting it.
	diag_color()
	int saved_error = open(c"/dev/null", 1, 0)
	int muted = open(c"/dev/null", 1, 0)
	int redirected = 0
	if ((saved_error >= 0) && (muted >= 0) && (dup2(2, saved_error) >= 0)): redirected = dup2(muted, 2) >= 0
	int equal = 0
	if (redirected):
		repl_result probe = repl_eval(source)
		dup2(saved_error, 2)
		if ((probe.status == 1) && (warning_count - warnings_before == kept.warnings) && (retained_sources.length > probe_source)):
			incremental_side_collect(&new_side, probe_source, retained_nodes.length, retained_bindings.length)
			equal = incremental_trees_equal(&old_side, &new_side)
			if (equal): equal = (kept_length >= 0) && (kept_length == incremental_function_length(sym_probe(kept.name)))
			incremental_side_free(&new_side)
	if (saved_error >= 0): close(saved_error)
	if (muted >= 0): close(muted)
	repl_no_run = old_no_run
	incremental_side_free(&old_side)
	warning_count = warnings_before
	spaces_warned_line = spaces_warned
	incremental_restore(&incremental_end)
	return equal


# Call after repl_init, before loading any user definitions. Target ABI and
# imported environment remain fixed for this session; only this API may compile
# into it. Runtime calls through incremental_address do not alter compiler state.
void incremental_init():
	assert1(incremental_active == 0)
	incremental_entries = new list[incremental_entry*]
	repl_state_capture(&incremental_base)
	repl_state_capture(&incremental_end)
	incremental_ast_mode = ast_expressions_mode
	incremental_required_mode = ast_required_mode
	incremental_retain_mode = ast_retain_mode
	incremental_emit_mode = ast_emit_retained_mode
	incremental_options = incremental_options_key()
	incremental_active = 1


incremental_result incremental_update(list[char*] sources):
	incremental_result result
	result.status = 0
	result.reused = 0
	result.compiled = 0
	result.failed_index = -1
	result.message = c""
	result.tree_reused = 0
	result.tree_probed = 0
	assert1(incremental_active)
	char* options = incremental_options_key()
	int same_options = strcmp(options, incremental_options) == 0
	free(options)
	# Compiler state has process-global ownership. Reject foreign evaluation or
	# changed compilation modes instead of silently reusing a different session.
	if (same_options == 0 || type_count() != incremental_end.type_count || imported_count != incremental_end.imported_count || codepos != incremental_end.codepos || table_pos != incremental_end.table_pos || ast_expressions_mode != incremental_ast_mode || ast_required_mode != incremental_required_mode || ast_retain_mode != incremental_retain_mode || ast_emit_retained_mode != incremental_emit_mode):
		result.message = c"incremental session compiler state or options changed"
		return result
	if (sources.length > 256):
		result.message = c"incremental session supports at most 256 functions"
		return result
	list[char*] names = new list[char*]
	for i in range(sources.length):
		if (strlen(sources[i]) > 65536):
			result.message = c"incremental function exceeds 65536 source bytes"
			result.failed_index = i
			incremental_strings_free(names)
			return result
		char* name = incremental_admit(sources[i], names)
		if (name == 0):
			result.message = c"incremental admission requires ordered scalar function definitions"
			result.failed_index = i
			incremental_strings_free(names)
			return result
		int existing = sym_probe(name)
		int owned = 0
		for incremental_entry* previous in incremental_entries:
			if (strcmp(previous.name, name) == 0): owned = 1
		if (incremental_contains(names, name) || (existing >= 0 && owned == 0)):
			free(name)
			result.message = c"duplicate or pre-existing incremental function name"
			result.failed_index = i
			incremental_strings_free(names)
			return result
		names.push(name)
	int prefix = 0
	while (prefix < sources.length && prefix < incremental_entries.length):
		incremental_entry* kept = incremental_entries[prefix]
		if (strcmp(sources[prefix], kept.source) != 0):
			# Without the retained forest there is no tree to compare.
			if ((incremental_retain_mode == 0) || (incremental_layout_equal(sources[prefix], kept.source) == 0)): break
			result.tree_probed = result.tree_probed + 1
			if (incremental_tree_unchanged(prefix, sources[prefix]) == 0): break
			# Same compiled function: keep it, and compare later updates
			# against the new spelling.
			free(kept.source)
			kept.source = strclone(sources[prefix])
			result.tree_reused = result.tree_reused + 1
		prefix = prefix + 1
	result.reused = prefix
	if (prefix < incremental_entries.length):
		incremental_restore(&incremental_entries[prefix].before)
		incremental_drop(prefix)
	int old_no_run = repl_no_run
	repl_no_run = 1
	int i = prefix
	while (i < sources.length):
		incremental_entry* entry = new incremental_entry
		entry.source = strclone(sources[i])
		entry.name = strclone(names[i])
		repl_state_capture(&entry.before)
		int warnings_before = warning_count
		repl_result compiled = repl_eval(sources[i])
		if (compiled.status != 1 || (strict_mode && warning_count > warnings_before)):
			# The successfully compiled prefix remains usable. Failed and
			# unvisited entries are absent, so a repaired update retries them.
			incremental_restore(&entry.before)
			warning_count = warnings_before
			free(entry.source)
			free(entry.name)
			free(cast(char*, entry))
			result.failed_index = i
			result.message = c"incremental function failed production compilation"
			break
		entry.warnings = warning_count - warnings_before
		incremental_entries.push(entry)
		result.compiled = result.compiled + 1
		i = i + 1
	repl_no_run = old_no_run
	repl_state_capture(&incremental_end)
	incremental_strings_free(names)
	if (i == sources.length): result.status = 1
	return result


# Native address of a currently compiled session function, or zero. The caller
# must use the source function's ABI and discard addresses on the next update.
int incremental_address(char* name):
	if (incremental_active == 0): return 0
	for incremental_entry* entry in incremental_entries:
		if (strcmp(entry.name, name) == 0):
			int symbol = sym_probe(name)
			if (symbol >= 0 && table[symbol + 1] == 'D'): return load_int(table + symbol + 2)
	return 0


void incremental_clear():
	if (incremental_active == 0): return
	incremental_restore(&incremental_base)
	incremental_drop(0)
	incremental_entries.free()
	incremental_entries = 0
	incremental_active = 0
	free(incremental_options)
	incremental_options = 0
