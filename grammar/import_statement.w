# Already-imported module paths, so each file is compiled only once.
char* imported_paths
int imported_count

/*
Import aliases: 'import a.b as f' binds the file-scoped name f to the
resolved module path a/b. The alias does not change how the module is
compiled (its symbols still land in the global symbol table); it adds a
checked, qualified spelling f.name whose member must have been declared
in the aliased module's file. Plain imports are recorded per file too, so
an unqualified reference to a module imported only through an alias can
be diagnosed with a warning.

Both registries are file-scoped: compile_save() saves and restores the
count and the base, so entries registered inside an imported file are not
visible to the importer and vice versa.
*/
char* import_alias_names
char* import_alias_paths
int import_alias_count
int import_alias_base

char* import_plain_paths
int import_plain_count
int import_plain_base


void compile_save(char* fn);


# Resolve the reserved __arch__ path segment to the target architecture:
# lib/__arch__/syscalls becomes lib/__arch__/x86/syscalls (or x64 when
# word_size is 8), so one import line binds the per-arch module for
# whichever target is being compiled. Always returns a fresh allocation.
char* import_resolve_arch(char* path):
	int i = 0
	while (path[i]):
		if (starts_with(path + i, c"__arch__")):
			# Match whole path segments only, not identifiers that merely
			# contain the sentinel
			int at_boundary = (i == 0) | (path[i - 1] == '/')
			char after = path[i + 8]
			if (at_boundary & ((after == '/') | (after == 0))):
				char* arch = c"x86"
				if (target_isa == 1):
					arch = c"arm64"
				else if (word_size == 8):
					arch = c"x64"
				char* result = malloc(strlen(path) + 5)
				int j = 0
				while (j < i + 8):
					result[j] = path[j]
					j = j + 1
				result[j] = '/'
				char* rest = strcpy(result + j + 1, arch)
				strcpy(rest, path + i + 8)
				return result
		i = i + 1
	return strclone(path)


int import_lookup(char* path):
	int i = 0
	while (i < imported_count):
		char* p = cast(char*, load_int(imported_paths + i * 4))
		if (strcmp(p, path) == 0):
			return i
		i = i + 1
	return -1


void import_register(char* path):
	int max_imports = 1000
	if (imported_paths == 0):
		imported_paths = malloc(max_imports * 4)
	assert1(imported_count < max_imports)
	save_int(imported_paths + imported_count * 4, cast(int, path))
	imported_count = imported_count + 1


char* import_alias_name(int index):
	return cast(char*, load_int(import_alias_names + index * 4))


char* import_alias_path(int index):
	return cast(char*, load_int(import_alias_paths + index * 4))


# Index of the alias in the current file's scope, or -1.
int import_alias_lookup(char* name):
	int i = import_alias_base
	while (i < import_alias_count):
		if (strcmp(import_alias_name(i), name) == 0):
			return i
		i = i + 1
	return -1


void import_alias_register(char* name, char* path):
	int max_aliases = 1000
	if (import_alias_names == 0):
		import_alias_names = malloc(max_aliases * 4)
		import_alias_paths = malloc(max_aliases * 4)
	assert1(import_alias_count < max_aliases)
	if (import_alias_lookup(name) >= 0):
		diag_part(c"duplicate import alias: '")
		diag_part(name)
		error(c"'")
	save_int(import_alias_names + import_alias_count * 4, cast(int, name))
	save_int(import_alias_paths + import_alias_count * 4, cast(int, path))
	import_alias_count = import_alias_count + 1


void import_plain_register(char* path):
	int max_imports = 1000
	if (import_plain_paths == 0):
		import_plain_paths = malloc(max_imports * 4)
	assert1(import_plain_count < max_imports)
	save_int(import_plain_paths + import_plain_count * 4, cast(int, path))
	import_plain_count = import_plain_count + 1


# Does a compiled file path (e.g. "/repo/lib/testing.w") correspond to a
# resolved module path (e.g. "lib/testing")? Compiled file paths are
# absolute (compile_joined), so match on the "/<module path>.w" suffix.
int import_path_matches_file(char* module_path, char* file_path):
	char* with_ext = strjoin(module_path, c".w")
	int matches = 0
	if (strcmp(with_ext, file_path) == 0):
		matches = 1
	else:
		char* needle = strjoin(c"/", with_ext)
		matches = ends_with(file_path, needle)
		free(needle)
	free(with_ext)
	return matches


# Was the module holding this compiled file plain-imported (no alias) in
# the current file's scope?
int import_plain_imported(char* file_path):
	int i = import_plain_base
	while (i < import_plain_count):
		char* p = cast(char*, load_int(import_plain_paths + i * 4))
		if (import_path_matches_file(p, file_path)):
			return 1
		i = i + 1
	return 0


# Unqualified reference to a symbol whose module was imported only through
# an alias in this file: still legal (the symbol table is global), but
# probably an oversight, so warn. Cheap when no aliases are in scope.
void import_warn_unqualified(char* name):
	if (import_alias_count == import_alias_base):
		return
	int t = sym_lookup(name)
	if (t < 0):
		return
	int file_index = sym_decl_file_index(t)
	if (file_index < 0):
		return
	char* file_path = debug_file_name(file_index)
	int i = import_alias_base
	while (i < import_alias_count):
		if (import_path_matches_file(import_alias_path(i), file_path)):
			if (import_plain_imported(file_path) == 0):
				diag_part(c"warning: unqualified use of '")
				diag_part(name)
				diag_part(c"' from module imported as '")
				diag_part(import_alias_name(i))
				warning(c"'")
			return;
		i = i + 1


# Qualified access through an import alias. The caller has just seen the
# alias identifier with '.' as the next character. Consumes ".member",
# checks the member was declared in the aliased module's file, and then
# resolves it exactly like a plain identifier reference.
int import_alias_member(int alias_index):
	get_token() /* consume the alias name; the next token is the '.' */
	expect(c".")
	int c = token[0]
	int is_name = (('a' <= c) & (c <= 'z')) | (('A' <= c) & (c <= 'Z')) | (c == '_')
	if (is_name == 0):
		diag_part(c"identifier expected after import alias '")
		diag_part(import_alias_name(alias_index))
		error(c"'")
	int t = sym_lookup(token)
	int in_module = 0
	if (t >= 0):
		int file_index = sym_decl_file_index(t)
		if (file_index >= 0):
			in_module = import_path_matches_file(import_alias_path(alias_index), debug_file_name(file_index))
	if (in_module == 0):
		diag_part(c"symbol '")
		diag_part(token)
		diag_part(c"' is not defined in module imported as '")
		diag_part(import_alias_name(alias_index))
		error(c"'")
	strcpy(last_identifier, token)
	return sym_get_value(token)




/*
import_statement:
	'import' dotted_name ['.' '*'] ['as' NAME]
dotted_name:
	| dotted_name '.' NAME
	| NAME

examples:
	import file
	import directory.file
	import directory.file.*
	import directory.file as alias

not implemented (future):
	import a, b comma lists
	import directory.file.[func1, func2, var2] selective imports
*/
# Dotted module path -> resolved filesystem path (dots to slashes plus the
# __arch__ substitution). Always returns a fresh allocation.
char* import_resolve(char* dotted):
	char* path = strclone(dotted)
	str_replace(path, '.', '/')
	char* resolved = import_resolve_arch(path)
	free(path)
	return resolved


# Resolve, register and compile a dotted module path (e.g. "lib.lib").
# Returns 1 when the module was compiled, 0 when it was already imported.
# Shared by import_statement() and in-process compilers (the REPL) that
# preload modules and must keep the registry consistent.
int import_module(char* dotted):
	char* resolved = import_resolve(dotted)

	# Ignore if we have already imported this path
	if (import_lookup(resolved) >= 0):
		if (verbosity >= 1):
			print2(c"Warning: ignoring duplicate import: '")
			print2(resolved)
			println2(c"'")
		free(resolved)
		return 0

	import_register(resolved)

	# Add the ".w" extension
	# Shouldnt this be done inside compile*??
	char* with_path = strjoin(resolved, c".w")
	compile_save(with_path)
	free(with_path)
	return 1


# Aliases must be plain identifiers: letters, digits and underscores, not
# starting with a digit.
void import_validate_alias(char* alias):
	int c = alias[0]
	int valid = (('a' <= c) & (c <= 'z')) | (('A' <= c) & (c <= 'Z')) | (c == '_')
	int i = 1
	while (valid & (alias[i] != 0)):
		c = alias[i]
		valid = (('a' <= c) & (c <= 'z')) | (('A' <= c) & (c <= 'Z')) | (('0' <= c) & (c <= '9')) | (c == '_')
		i = i + 1
	if (valid == 0):
		diag_part(c"invalid import alias: '")
		diag_part(alias)
		error(c"'")


# Splits an optional trailing " as <alias>" clause off an import line,
# truncating the line at the clause. Returns the alias (fresh allocation)
# or 0 when the line has none.
char* import_split_alias(char* line):
	int i = 0
	while (line[i]):
		if (line[i] == ' '):
			if (starts_with(line + i, c" as ")):
				line[i] = 0
				char* alias = strclone(line + i + 4)
				import_validate_alias(alias)
				return alias
		i = i + 1
	return 0


int import_statement():
	if(accept(c"import")):
		# The rest of the line is the module path plus an optional alias
		read_until_end()
		char* alias = import_split_alias(token)

		# Strip a trailing .* wildcard; the whole module is imported either way
		if (ends_with(token, c".*")):
			int len = strlen(token)
			token[len-2] = 0

		char* resolved = import_resolve(token)

		# compile_save clobbers nextc, so only re-read it after a compile
		if (import_module(token)):
			nextc = get_character()
		if (alias != 0):
			import_alias_register(alias, resolved)
		else:
			import_plain_register(resolved)
		get_token()
		return 1
	return 0
