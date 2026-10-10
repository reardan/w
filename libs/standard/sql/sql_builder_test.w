# wbuild: x64
import libs.standard.sql.builder
import libs.standard.sql.parser
import lib.assert


int main():
	malloc_force_debug_mode()
	assert1(sql_builder_new(-1) == 0)
	assert1(sql_builder_new(3) == 0)
	for style in range(3):
		sql_builder* builder = sql_builder_new(style)
		assert1(sql_builder_values(builder) == 0)
		sql_builder_append(builder, c"SELECT * FROM ")
		sql_builder_identifier(builder, c"my schema")
		sql_builder_append(builder, c".")
		sql_builder_identifier(builder, c"a\"b")
		sql_builder_append(builder, c" WHERE name = ")
		char* input = strclone(c"Robert'); DROP TABLE users;--")
		sql_builder_bind(builder, input)
		free(input)
		sql_builder_append(builder, c" OR note = ")
		sql_builder_bind(builder, 0)
		sql_builder_append(builder, c" OR note = ")
		sql_builder_bind(builder, c"")
		char* expected = c"SELECT * FROM \"my schema\".\"a\"\"b\" WHERE name = ? OR note = ? OR note = ?"
		if (style == sql_bind_dollar): expected = c"SELECT * FROM \"my schema\".\"a\"\"b\" WHERE name = $1 OR note = $2 OR note = $3"
		if (style == sql_bind_colon): expected = c"SELECT * FROM \"my schema\".\"a\"\"b\" WHERE name = :1 OR note = :2 OR note = :3"
		assert_strings_equal(expected, builder.text.data)
		assert_equal(3, builder.parameters.length)
		char** values = sql_builder_values(builder)
		assert_strings_equal(c"Robert'); DROP TABLE users;--", values[0])
		assert1(values[1] == 0)
		assert_strings_equal(c"", values[2])
		sql_document* document = sql_document_parse(builder.text.data, c"built.sql")
		assert1(sql_document_ok(document))
		assert_equal(1, sql_document_statement_count(document))
		sql_document_free(document)
		# Growing the parameter vector preserves values and numbering.
		for i in range(20):
			sql_builder_append(builder, c" OR id = ")
			sql_builder_bind(builder, c"7")
		assert_equal(23, builder.parameters.length)
		assert_strings_equal(c"7", sql_builder_values(builder)[22])
		document = sql_document_parse(builder.text.data, c"grown.sql")
		assert1(sql_document_ok(document))
		sql_document_free(document)
		sql_builder_free(builder)
	sql_builder_free(0)
	assert_equal(0, debug_alloc_report_leaks())
	println(c"sql_builder_test: OK")
	return 0
