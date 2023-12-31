int wildcard_import



void compile_save(char* fn);




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
		
		# Ignore if we have already imported this type
		if (type_lookup(token) >= 0):
			if (verbosity >= 1):
				print2("Warning: ignoring duplicate imported type: '")
				print2(token)
				println2("'")
			get_token()
			return 1

		# Store in the type_table with the full path
		# Shouldnt this be done after the compile??
		char* tok = strclone(token)
		type_push(tok)

		# Add the ".w" extension
		# Shouldnt this be done inside compile*??
		char* with_path = strjoin(tok, ".w")
		compile_save(with_path, import_wildcard_import)
		nextc = get_character()
		get_token()
		free(with_path)
		return 1
	return 0
