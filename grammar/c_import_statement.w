import grammar.string_literal
import libs.extras.c_import.importer


int c_import_statement():
	if (accept(c"c_import")):
		# c_import binds whole shared-library headers through the native
		# ABI shims; wasm has neither (extern against a host module is
		# the supported import path, see docs/projects/wasm_webgl.md).
		if (target_isa == 2):
			error(c"c_import is not supported on the wasm target")
		if ((token[0] != '"') && (((token[0] != 'c') || (token[1] != '"')))):
			error(c"c_import expects a \"soname\" string literal")
		int len
		if (token[0] == 'c'):
			len = process_prefixed_string_literal()
		else:
			len = process_string_literal()
		token[len] = 0
		char* soname = strclone(token)
		get_token()

		if ((token[0] != '"') && (((token[0] != 'c') || (token[1] != '"')))):
			error(c"c_import expects a header path string literal")
		if (token[0] == 'c'):
			len = process_prefixed_string_literal()
		else:
			len = process_string_literal()
		token[len] = 0
		char* header_path = strclone(token)
		get_token()

		c_import_header(soname, header_path)
		free(soname)
		free(header_path)
		return 1
	return 0
