# Syntax-only SQL parsing; no database client or connection is required.
# The document owns its filename, tokens, all AST nodes and diagnostics.
import libs.standard.sql.generated_sql_parser


struct sql_document:
	char* filename
	pg_token_stream* tokens
	pg_ast_node* root
	pg_diagnostics* diagnostics
	list[pg_ast_node*] statements


sql_document* sql_document_parse(char* source, char* filename):
	sql_document* document = new sql_document()
	document.filename = strclone(filename)
	document.diagnostics = pg_diagnostics_new()
	document.tokens = sql_lex(source, document.filename, document.diagnostics)
	pg_token_stream_own_ast(document.tokens)
	document.statements = new list[pg_ast_node*]
	# The shared block-comment matcher consumes through EOF on an open
	# comment. Report it here instead of accepting silently hidden SQL.
	for i in range(pg_token_stream_all_count(document.tokens)):
		pg_token* token = pg_token_stream_all_get(document.tokens, i)
		if (token.kind == sql_token_BLOCK_COMMENT):
			int n = token.length
			if (n < 4 || token.text[n - 2] != '*' || token.text[n - 1] != '/'):
				pg_diagnostics_add(document.diagnostics, document.filename, token.line, token.column, c"unterminated SQL comment", c"*/", c"EOF")
	document.root = sql_parse_script(document.tokens, document.diagnostics)
	if (document.root == 0):
		pg_syntax_error(document.diagnostics, pg_token_stream_furthest(document.tokens), c"SQL statement")
	# Do not expose partial statements as a successful script.
	if (document.root != 0 && pg_diagnostics_count(document.diagnostics) == 0):
		for i in range(pg_ast_child_count(document.root)):
			pg_ast_node* node = pg_ast_child(document.root, i)
			if (node.token == 0 && node.kind == sql_ast_top_statement): node = pg_ast_child(node, 0)
			if (node.token == 0 && node.kind == sql_ast_statement):
				document.statements.push(pg_ast_child(node, 0))
	return document


int sql_document_ok(sql_document* document):
	return document.root != 0 && pg_diagnostics_count(document.diagnostics) == 0


int sql_document_statement_count(sql_document* document):
	return document.statements.length


# Borrowed concrete statement (select_stmt, insert_stmt, etc.), or null.
pg_ast_node* sql_document_statement(sql_document* document, int index):
	if (index < 0 || index >= document.statements.length): return 0
	return document.statements[index]


void sql_document_free(sql_document* document):
	if (document == 0): return
	__w_list_free(cast(__w_list*, document.statements))
	pg_token_stream_free(document.tokens)
	pg_diagnostics_free(document.diagnostics)
	free(document.filename)
	free(document)
