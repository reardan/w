# Already-imported module paths, so each file is compiled only once.
int imported_paths
int imported_count


void compile_save(char* fn);


# Resolve the reserved __arch__ path segment to the target architecture:
# lib/__arch__/syscalls becomes lib/__arch__/x86/syscalls (or x64 when
# word_size is 8), so one import line binds the per-arch module for
# whichever target is being compiled. Always returns a fresh allocation.
char* import_resolve_arch(char* path):
	int i = 0
	while (path[i]):
		if (starts_with(path + i, "__arch__")):
			# Match whole path segments only, not identifiers that merely
			# contain the sentinel
			int at_boundary = (i == 0) | (path[i - 1] == '/')
			char after = path[i + 8]
			if (at_boundary & ((after == '/') | (after == 0))):
				char* arch = "x86"
				if (word_size == 8):
					arch = "x64"
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
		char* p = load_int(imported_paths + i * 4)
		if (strcmp(p, path) == 0):
			return i
		i = i + 1
	return -1


void import_register(char* path):
	int max_imports = 1000
	if (imported_paths == 0):
		imported_paths = malloc(max_imports * 4)
	assert1(imported_count < max_imports)
	save_int(imported_paths + imported_count * 4, path)
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
int import_statement():
	if(accept("import")):
		# Strip a trailing .* wildcard; the whole module is imported either way
		read_until_end()
		if (ends_with(token, ".*")):
			int len = strlen(token)
			token[len-2] = 0

		# Change . to path separator
		str_replace(token, '.', '/')

		char* tok = import_resolve_arch(token)

		# Ignore if we have already imported this path
		if (import_lookup(tok) >= 0):
			if (verbosity >= 1):
				print2("Warning: ignoring duplicate import: '")
				print2(tok)
				println2("'")
			free(tok)
			get_token()
			return 1

		import_register(tok)

		# Add the ".w" extension
		# Shouldnt this be done inside compile*??
		char* with_path = strjoin(tok, ".w")
		compile_save(with_path)
		nextc = get_character()
		get_token()
		free(with_path)
		return 1
	return 0
