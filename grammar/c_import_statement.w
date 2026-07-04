import grammar.string_literal
import libs.extras.c_import.importer


int c_import_statement():
	if (accept(c"c_import")):
		if (token[0] != '"'):
			error(c"c_import expects a \"soname\" string literal")
		int len = process_string_literal()
		token[len] = 0
		char* soname = strclone(token)
		get_token()

		if (token[0] != '"'):
			error(c"c_import expects a header path string literal")
		len = process_string_literal()
		token[len] = 0
		char* header_path = strclone(token)
		get_token()

		c_import_header(soname, header_path)
		free(soname)
		free(header_path)
		return 1
	return 0
