# Conservative incremental native compilation using the production compiler.
# One process owns one session. Inputs are ordered complete scalar functions;
# this is a compiler API, not a second parser/emitter or a binary artifact cache.
# Admission below excludes constructs whose compilation can mutate a retained
# prefix (prototypes, imports, generics, types, helpers and global declarations).
# Exact source equality retains code, symbols and AST nodes for the prefix.
# Edits roll back to the first changed definition and recompile its suffix.
import repl.core
import lib.str

struct incremental_entry:
	char* source
	char* name
	repl_state before

struct incremental_result:
	int status
	int reused
	int compiled
	int failed_index
	char* message

list[incremental_entry*] incremental_entries
repl_state incremental_base
repl_state incremental_end
int incremental_active
int incremental_ast_mode
int incremental_required_mode
int incremental_retain_mode
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
	incremental_options = incremental_options_key()
	incremental_active = 1


incremental_result incremental_update(list[char*] sources):
	incremental_result result
	result.status = 0
	result.reused = 0
	result.compiled = 0
	result.failed_index = -1
	result.message = c""
	assert1(incremental_active)
	char* options = incremental_options_key()
	int same_options = strcmp(options, incremental_options) == 0
	free(options)
	# Compiler state has process-global ownership. Reject foreign evaluation or
	# changed compilation modes instead of silently reusing a different session.
	if (same_options == 0 || type_count() != incremental_end.type_count || imported_count != incremental_end.imported_count || codepos != incremental_end.codepos || table_pos != incremental_end.table_pos || ast_expressions_mode != incremental_ast_mode || ast_required_mode != incremental_required_mode || ast_retain_mode != incremental_retain_mode):
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
		if (strcmp(sources[prefix], incremental_entries[prefix].source) != 0): break
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
