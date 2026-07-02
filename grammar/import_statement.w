int wildcard_import

# Already-imported module paths, so each file is compiled only once.
int imported_paths
int imported_count


void compile_save(char* fn);


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
		# Strip .* wildcard and set flag
		int import_wildcard_import = 0
		read_until_end()
		if (ends_with(token, ".*")):
			int len = strlen(token)
			token[len-2] = 0
			import_wildcard_import = 1

		# Change . to path separator
		str_replace(token, '.', '/')
		
		# Ignore if we have already imported this path
		if (import_lookup(token) >= 0):
			if (verbosity >= 1):
				print2("Warning: ignoring duplicate import: '")
				print2(token)
				println2("'")
			get_token()
			return 1

		char* tok = strclone(token)
		import_register(tok)

		# Add the ".w" extension
		# Shouldnt this be done inside compile*??
		char* with_path = strjoin(tok, ".w")
		compile_save(with_path, import_wildcard_import)
		nextc = get_character()
		get_token()
		free(with_path)
		return 1
	return 0
