# Already-imported module paths, so each file is compiled only once.
char* imported_paths
int imported_count


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
				if (word_size == 8):
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




/*
import_statement:
	'import' dotted_as_names
dotted_as_names:
	| ','.dotted_as_name+
dotted_as_name
	| dotted_name ['as' NAME]
dotted_name:
	| dotted_name '.' NAME
	| NAME

examples:
	import file.*
	import file
	import directory.*
	import directory.file
	import directory.file.[func1, func2, var2]

*/
# Resolve, register and compile a dotted module path (e.g. "lib.lib").
# Returns 1 when the module was compiled, 0 when it was already imported.
# Shared by import_statement() and in-process compilers (the REPL) that
# preload modules and must keep the registry consistent.
int import_module(char* dotted):
	char* path = strclone(dotted)
	str_replace(path, '.', '/')
	char* resolved = import_resolve_arch(path)
	free(path)

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


int import_statement():
	if(accept(c"import")):
		# Strip a trailing .* wildcard; the whole module is imported either way
		read_until_end()
		if (ends_with(token, c".*")):
			int len = strlen(token)
			token[len-2] = 0

		# compile_save clobbers nextc, so only re-read it after a compile
		if (import_module(token)):
			nextc = get_character()
		get_token()
		return 1
	return 0
