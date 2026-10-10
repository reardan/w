# wbuild: target=sql_parse_example tag=tests dep=wv2
# wbuild: step="bin/wv2 examples/sql/parse_and_build.w -o bin/sql_parse_example"
# wbuild: step="bin/sql_parse_example" expect_stdout="statement: select_stmt" expect_stdout="table: users" expect_stdout="parameter: O'Brien"
import libs.standard.sql.builder
import libs.standard.sql.parser


# Rule nodes and token nodes have separate kind namespaces: check token
# before matching a rule kind. This visits FROM targets, including subqueries.
void show_table(pg_ast_node* node):
	if (node.token != 0 || node.kind != sql_ast_table_primary): return
	pg_ast_node* name = pg_ast_child(node, 0)
	if (name.token == 0 && name.kind == sql_ast_qualified_name):
		print(c"table: ")
		println(pg_ast_first_token(name).text)


int main():
	sql_builder* query = sql_builder_new(sql_bind_question)
	sql_builder_append(query, c"SELECT id, name FROM users WHERE ")
	sql_builder_identifier(query, c"name")
	sql_builder_append(query, c" = ")
	sql_builder_bind(query, c"O'Brien")
	sql_builder_append(query, c" ORDER BY id;")
	println(query.text.data)
	print(c"parameter: ")
	println(query.parameters[0])
	sql_document* document = sql_document_parse(query.text.data, c"example.sql")
	if (sql_document_ok(document) == 0):
		pg_diagnostics_print(document.diagnostics)
		sql_document_free(document)
		sql_builder_free(query)
		return 1
	for i in range(sql_document_statement_count(document)):
		pg_ast_node* statement = sql_document_statement(document, i)
		print(c"statement: ")
		println(statement.name)
		pg_ast_walk_preorder(statement, show_table)
	# The retained token stream rebuilds the original text, including trivia.
	char* original = pg_token_stream_source(document.tokens)
	println(original)
	free(original)
	sql_document_free(document)
	sql_builder_free(query)
	return 0
