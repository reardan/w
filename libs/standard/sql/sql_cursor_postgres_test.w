# wbuild: arch_only=x64
# wbuild: target=sql_cursor_postgres_local_test tag=tests dep=sql_cursor_postgres_test data=tests/sql_postgres_fixture.py
# wbuild: step="python3 tests/sql_postgres_fixture.py bin/sql_cursor_postgres_test"
import libs.standard.sql.client
import lib.env
import lib.assert
import lib.time

void sql_cursor_pg_exec(sql_connection* c, char* query):
	int ok = sql_exec(c, query)
	asserts(sql_error(c), ok)

void sql_cursor_pg_expect_count(sql_connection* c, char* want):
	sql_result* r = sql_query(c, c"SELECT count(*) FROM w_cursor_items")
	asserts(sql_error(c), r != 0)
	assert_strings_equal(want, sql_value(r, 0, 0))
	sql_result_free(r)

# Streams more rows than the result collector accepts (SQL_MAX_ROWS).
void sql_cursor_pg_large(sql_connection* c):
	char*[1] params
	params[0] = c"150000"
	sql_cursor* cur = sql_query_cursor(c, c"SELECT i, 'row' || i AS label FROM generate_series(1, $1::int) AS i", 1, &params[0])
	asserts(sql_error(c), cur != 0)
	assert_equal(2, sql_cursor_columns(cur))
	assert_strings_equal(c"i", sql_cursor_column_name(cur, 0))
	assert_strings_equal(c"label", sql_cursor_column_name(cur, 1))
	assert1(sql_cursor_value(cur, 0) == 0)
	int rows = 0
	int sum = 0
	while (1):
		int rc = sql_cursor_next(cur)
		if (rc == 0): break
		asserts(sql_error(c), rc == 1)
		rows = rows + 1
		sum = sum + atoi(sql_cursor_value(cur, 0))
		if (rows == 1): assert_strings_equal(c"row1", sql_cursor_value(cur, 1))
	assert1(rows > SQL_MAX_ROWS)
	assert_equal(150000, rows)
	assert_equal(150000 * 150001 / 2, sum)
	assert_equal(0, sql_cursor_next(cur))
	assert1(sql_exec(c, c"SELECT 1"))
	sql_cursor_free(cur)
	assert1(sql_query_params(c, c"SELECT i FROM generate_series(1, $1::int) AS i", 1, &params[0]) == 0)
	assert_contains(sql_error(c), c"limits")
	# Early free mid-stream cancels; the connection stays usable.
	cur = sql_query_cursor(c, c"SELECT i FROM generate_series(1, $1::int) AS i", 1, &params[0])
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	assert_equal(1, sql_cursor_next(cur))
	assert_strings_equal(c"2", sql_cursor_value(cur, 0))
	assert1(sql_query(c, c"SELECT 1") == 0)
	assert_contains(sql_error(c), c"open cursor")
	assert1(sql_begin(c) == 0)
	assert1(sql_query_cursor(c, c"SELECT 1", 0, cast(char**, 0)) == 0)
	sql_cursor_free(cur)
	sql_result* r = sql_query(c, c"SELECT 42")
	asserts(sql_error(c), r != 0)
	assert_strings_equal(c"42", sql_value(r, 0, 0))
	sql_result_free(r)
	# Early free cancels outside a transaction: the 20 s tail never runs.
	int start = time_monotonic_ms()
	cur = sql_query_cursor(c, c"SELECT i, CASE WHEN i = 200000 THEN pg_sleep(20) END FROM generate_series(1, 200000) AS i", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	sql_cursor_free(cur)
	assert1(sql_exec(c, c"SELECT 1"))
	asserts(c"early free waited for the query", time_monotonic_ms() - start < 10000)
	# Early free before the first next.
	cur = sql_query_cursor(c, c"SELECT i FROM generate_series(1, $1::int) AS i", 1, &params[0])
	asserts(sql_error(c), cur != 0)
	sql_cursor_free(cur)
	assert1(sql_exec(c, c"SELECT 1"))

void sql_cursor_pg_values(sql_connection* c):
	sql_cursor_pg_exec(c, c"CREATE TEMP TABLE w_cursor_items(id int, name text, note text, raw bytea)")
	sql_cursor_pg_exec(c, c"INSERT INTO w_cursor_items VALUES (1, 'one', NULL, '\\x610062'), (2, '', 'two', ''), (3, NULL, NULL, NULL)")
	sql_cursor* cur = sql_query_cursor(c, c"SELECT id, name, note, raw FROM w_cursor_items ORDER BY id", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(4, sql_cursor_columns(cur))
	assert_equal(1, sql_cursor_next(cur))
	assert_strings_equal(c"1", sql_cursor_value(cur, 0))
	assert_strings_equal(c"one", sql_cursor_value(cur, 1))
	assert1(sql_cursor_value(cur, 2) == 0)
	assert_equal(-1, sql_cursor_value_length(cur, 2))
	# bytea uses PostgreSQL's text encoding.
	assert_strings_equal(c"\\x610062", sql_cursor_value(cur, 3))
	assert_equal(8, sql_cursor_value_length(cur, 3))
	assert_equal(-2, sql_cursor_value_length(cur, 4))
	assert1(sql_cursor_value(cur, -1) == 0)
	assert_equal(1, sql_cursor_next(cur))
	assert_equal(0, sql_cursor_value_length(cur, 1))
	assert1(sql_cursor_value(cur, 1) != 0)
	assert_strings_equal(c"two", sql_cursor_value(cur, 2))
	assert_equal(1, sql_cursor_next(cur))
	assert1(sql_cursor_value(cur, 1) == 0)
	assert_equal(-1, sql_cursor_value_length(cur, 3))
	assert_equal(0, sql_cursor_next(cur))
	sql_cursor_free(cur)
	# Parameters including NULL.
	char*[2] params
	params[0] = c"2"
	params[1] = 0
	cur = sql_query_cursor(c, c"SELECT name, $2::text IS NULL FROM w_cursor_items WHERE id = $1::int", 2, &params[0])
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	assert_strings_equal(c"", sql_cursor_value(cur, 0))
	assert_strings_equal(c"t", sql_cursor_value(cur, 1))
	assert_equal(0, sql_cursor_next(cur))
	sql_cursor_free(cur)
	# Zero-row SELECT keeps its column metadata.
	cur = sql_query_cursor(c, c"SELECT id, name FROM w_cursor_items WHERE false", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(2, sql_cursor_columns(cur))
	assert_strings_equal(c"name", sql_cursor_column_name(cur, 1))
	assert1(sql_exec(c, c"SELECT 1"))
	assert_equal(0, sql_cursor_next(cur))
	sql_cursor_free(cur)
	# A command through a cursor runs and yields no rows.
	cur = sql_query_cursor(c, c"INSERT INTO w_cursor_items VALUES (4, 'four', NULL, NULL)", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(0, sql_cursor_columns(cur))
	assert_equal(0, sql_cursor_next(cur))
	sql_cursor_free(cur)
	sql_cursor_pg_expect_count(c, c"4")

void sql_cursor_pg_transaction(sql_connection* c):
	# Inside a transaction an early free drains instead of cancelling, so the
	# transaction is not aborted and still commits.
	assert1(sql_begin(c))
	sql_cursor_pg_exec(c, c"INSERT INTO w_cursor_items VALUES (5, 'five', NULL, NULL)")
	sql_cursor* cur = sql_query_cursor(c, c"SELECT i FROM generate_series(1, 20000) AS i", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	assert1(sql_commit(c) == 0)
	assert_contains(sql_error(c), c"open cursor")
	sql_cursor_free(cur)
	sql_cursor_pg_exec(c, c"INSERT INTO w_cursor_items VALUES (6, 'six', NULL, NULL)")
	assert1(sql_commit(c))
	sql_cursor_pg_expect_count(c, c"6")

void sql_cursor_pg_errors(sql_connection* c):
	assert1(sql_query_cursor(c, c"SELECT missing FROM w_cursor_items", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"missing")
	assert1(sql_exec(c, c"SELECT 1"))
	assert1(sql_query_cursor(c, c"SELECT 1; SELECT 2", 0, cast(char**, 0)) == 0)
	assert1(sql_error(c)[0] != 0)
	assert1(sql_query_cursor(c, c"SELECT $1", 0, cast(char**, 0)) == 0)
	assert1(sql_error(c)[0] != 0)
	assert1(sql_query_cursor(c, c"", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"one SQL statement")
	assert1(sql_exec(c, c"SELECT 1"))
	# An error after some rows were sent: -1, sticky, connection released.
	sql_cursor* cur = sql_query_cursor(c, c"SELECT 10 / (3 - i) FROM generate_series(1, 5) AS i", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	int rc = sql_cursor_next(cur)
	while (rc == 1): rc = sql_cursor_next(cur)
	assert_equal(-1, rc)
	assert_contains(sql_error(c), c"division by zero")
	assert_equal(-1, sql_cursor_next(cur))
	assert1(sql_exec(c, c"SELECT 1"))
	sql_cursor_free(cur)
	# COPY closes the connection, as in sql_query.
	assert1(sql_query_cursor(c, c"COPY (SELECT 1) TO STDOUT", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"COPY")
	assert1(sql_is_open(c) == 0)

int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"sql cursor PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	sql_connection* c = sql_open_postgres(conninfo)
	asserts(sql_error(c), sql_is_open(c))
	sql_cursor_pg_large(c)
	sql_cursor_pg_values(c)
	sql_cursor_pg_transaction(c)
	sql_cursor_pg_errors(c)
	sql_close(c)
	# Closing with an open cursor; the cursor can still be freed afterwards.
	c = sql_open_postgres(conninfo)
	asserts(sql_error(c), sql_is_open(c))
	sql_cursor* cur = sql_query_cursor(c, c"SELECT i FROM generate_series(1, 150000) AS i", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	sql_close(c)
	assert_equal(-1, sql_cursor_next(cur))
	assert1(sql_cursor_value(cur, 0) == 0)
	sql_cursor_free(cur)
	println(c"sql cursor PostgreSQL live OK")
	return 0
