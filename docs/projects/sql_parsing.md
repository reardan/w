# SQL parsing and query construction

Issue [#493](https://github.com/reardan/w/issues/493) builds on the existing
[`sql.pg`](../../libs/extras/grammars/sql.pg) grammar. Two optional modules work
without a database, native client libraries, or compiler changes:

- `libs.standard.sql.parser`: parse SQL into a syntax tree with diagnostics,
  source spans, and a lossless token stream.
- `libs.standard.sql.builder`: compose SQL fragments and quoted identifiers,
  retaining values separately for parameter binding.

## Run the example

[`examples/sql/parse_and_build.w`](../../examples/sql/parse_and_build.w) builds a
parameterized SELECT, parses it, visits its FROM clause, and reproduces the SQL
from the token stream:

```sh
./wbuild sql_parse_example
# Or compile your own consumer directly:
bin/wv2 examples/sql/parse_and_build.w -o bin/sql_example
bin/sql_example
```

The output includes:

```text
SELECT id, name FROM users WHERE "name" = ? ORDER BY id;
parameter: O'Brien
statement: select_stmt
table: users
SELECT id, name FROM users WHERE "name" = ? ORDER BY id;
```

On Apple Silicon, use the native compiler:

```sh
./wbuild build_darwin
bin/wv2_darwin arm64_darwin examples/sql/parse_and_build.w -o bin/sql_example_darwin
tools/mac/run_darwin_tests.sh bin/sql_example_darwin
```

## Parse and inspect

```w
import libs.standard.sql.parser

int main():
	sql_document* doc = sql_document_parse(c"select name from users;", c"query.sql")
	if (sql_document_ok(doc) == 0):
		pg_diagnostics_print(doc.diagnostics)
		sql_document_free(doc)
		return 1
	pg_ast_node* statement = sql_document_statement(doc, 0)
	println(statement.name)  # select_stmt
	sql_document_free(doc)
	return 0
```

`sql_document_parse(source, filename)` returns an owned document on both success
and failure. The inputs are NUL-terminated strings and may be freed after the
call. `sql_document_ok` requires a root and zero lexical/syntax diagnostics.
Invalid input exposes no statements through the convenience accessors.
Empty input and scripts containing only comments or semicolons are valid,
with zero statements. Semicolons separate statements; the final one is optional.

`sql_document_statement_count(doc)` and `sql_document_statement(doc, index)`
expose top-level concrete statement nodes (`select_stmt`, `insert_stmt`, etc.).
Indexes are zero-based; an invalid index returns null. Nodes, tokens, and
diagnostics are borrowed until `sql_document_free(doc)`. Free the document once;
do not separately free its root, children, token stream, or diagnostics. The
document also releases nodes abandoned during parser backtracking.

The tree uses the generic [ParserGenerator runtime](parser_generator.md):

- `pg_ast_child_count`, `pg_ast_child`, and `pg_ast_walk_preorder` inspect rules
  and tokens. Rule constants are `sql_ast_<rule>`; token constants are
  `sql_token_<NAME>`. These are separate kind namespaces: check `node.token == 0`
  before comparing a rule kind. Rule nodes have names corresponding to `sql.pg`.
- `pg_ast_first_token` and `pg_ast_last_token` give a node's source span. Token
  `offset`/`length` are byte-based, starting at zero; `line`/`column` start at one.
  Keywords, identifiers, and literal text retain their original spelling.
- `pg_token_stream_source(doc.tokens)` returns an **owned** reconstruction of
  the original input, including comments and whitespace. Free it with `free`.
- `doc.diagnostics` exposes `pg_diagnostics_count/get/print`; each diagnostic
  contains its filename, line, column, message, expected text, and found text.

This is a grammar tree, not a database execution plan or a normalized relational
AST. Walking `table_primary` finds FROM references in nested SELECTs; other
statement kinds use their own rules. Reproducing tokens preserves the input;
it does not serialize mutations to the AST.

## Build queries with parameters

```w
sql_builder* query = sql_builder_new(sql_bind_dollar)
sql_builder_append(query, c"SELECT * FROM ")
sql_builder_identifier(query, c"users")
sql_builder_append(query, c" WHERE name = ")
sql_builder_bind(query, c"O'Brien")
# query.text.data: SELECT * FROM "users" WHERE name = $1
# query.parameters[0]: O'Brien
```

With an open [SQL client](sql.md) connection using the matching dialect:

```w
sql_result* rows = sql_query_params(db, query.text.data,
	query.parameters.length, sql_builder_values(query))
sql_builder_free(query)
# Check rows for null, then consume/free it as described in sql.md.
```

`sql_builder_new(style)` supports `sql_bind_question` (`?`, SQLite),
`sql_bind_dollar` (`$1`, `$2`, PostgreSQL), and `sql_bind_colon` (`:1`, `:2`, Oracle).
An invalid style returns null. MySQL and SQL Server parameter execution remains
unsupported by the current client adapters.

`sql_builder_append` appends **trusted SQL syntax** verbatim, with no automatic
spacing. `sql_builder_identifier` double-quotes one identifier and doubles any
embedded quotes. For `schema.table`, append each identifier separately with a
literal dot between them; append `*` as syntax. Identifier quoting follows SQL
double-quote rules, not MySQL's default backtick mode.

`sql_builder_bind` appends a placeholder and copies a NUL-terminated text value;
a null pointer represents SQL NULL, distinct from an empty string. Numbering
starts at one. Let the builder create all parameter markers in a query so their
positions match the stored values. Values never become part of the SQL text.
`sql_builder_values` returns a borrowed `char**` suitable for `sql_query_params`
(null for no parameters), invalidated by another bind or by freeing the builder.
`query.text.data` is also borrowed and may move when the builder changes.
`sql_builder_free` releases the text and copied values.

The builder does not validate statement shape; use the parser when desired.
Parsing checks syntax only; the database still resolves names and types and
applies its own dialect rules.

## Grammar coverage and regeneration

The [grammar README](../../libs/extras/grammars/README.md#what-sqlpg-covers)
lists the supported common SQL subset: SELECTs, joins, subqueries, expressions,
INSERT/UPDATE/DELETE, and basic table/index/view DDL. Keywords are ASCII
case-insensitive. Strings and quoted identifiers escape their delimiters by
doubling them; backslashes are ordinary characters. Decimal/exponent numbers
and `?`, `?1`, `$1`, `:1`, and `:name` parameter markers are supported.
Unterminated strings, quoted identifiers, and block comments fail the document
API. The grammar is intentionally permissive about some semantics and is not a
complete validator for any SQL dialect.

CTEs, window functions, PostgreSQL `::` casts, upserts, backtick/bracket names,
and vendor-specific DDL are outside this subset. Parameter binding names/counts
and identifier resolution are left to the database. Parsing is synchronous
and keeps the token stream and syntax tree in memory.

The generated parser is checked in, so importing the library needs no generation
step. To change it, edit the grammar and regenerate; do not edit generated W:

```sh
./wbuild grammars_parser_generator
bin/parser_generator_grammars libs/extras/grammars/sql.pg \
  -o libs/standard/sql/generated_sql_parser.w
./wbuild sql_parser_generated_check grammars_sql_test
./wbuild sql_parser_test sql_parser_64_test sql_builder_test sql_builder_64_test
```

`sql_parser_generated_check` compares freshly generated output with the committed
module. All these tests and the runnable example belong to `./wbuild tests`.
Parser and builder tests run on both x86 and x64 and assert leak-free cleanup
under the guard allocator, including malformed input and speculative AST nodes.
