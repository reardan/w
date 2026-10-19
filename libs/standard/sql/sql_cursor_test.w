# wbuild: arch_only=x64
import libs.standard.sql.client
import lib.assert

void sql_cursor_test_exec(sql_connection* c, char* query):
	int ok = sql_exec(c, query)
	asserts(sql_error(c), ok)

# Streams more rows than the result collector accepts (SQL_MAX_ROWS).
void sql_cursor_test_large(sql_connection* c):
	char*[1] params
	params[0] = c"150000"
	sql_cursor* cur = sql_query_cursor(c, c"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < CAST(?1 AS INTEGER)) SELECT i, 'row' || i AS label FROM n", 1, &params[0])
	asserts(sql_error(c), cur != 0)
	assert_equal(2, sql_cursor_columns(cur))
	assert_strings_equal(c"i", sql_cursor_column_name(cur, 0))
	assert_strings_equal(c"label", sql_cursor_column_name(cur, 1))
	assert1(sql_cursor_column_name(cur, 2) == 0)
	# No current row before the first next.
	assert1(sql_cursor_value(cur, 0) == 0)
	assert_equal(-2, sql_cursor_value_length(cur, 0))
	int rows = 0
	int sum = 0
	while (1):
		int rc = sql_cursor_next(cur)
		if (rc == 0): break
		asserts(sql_error(c), rc == 1)
		rows = rows + 1
		sum = sum + atoi(sql_cursor_value(cur, 0))
		if (rows == 1): assert_strings_equal(c"row1", sql_cursor_value(cur, 1))
		if (rows == 150000):
			assert_strings_equal(c"150000", sql_cursor_value(cur, 0))
			assert_equal(9, sql_cursor_value_length(cur, 1))
	assert1(rows > SQL_MAX_ROWS)
	assert_equal(150000, rows)
	assert_equal(150000 * 150001 / 2, sum)
	# End is sticky, and the connection is already released.
	assert_equal(0, sql_cursor_next(cur))
	assert1(sql_cursor_value(cur, 0) == 0)
	sql_result* r = sql_query(c, c"SELECT 7")
	asserts(sql_error(c), r != 0)
	sql_result_free(r)
	sql_cursor_free(cur)
	# The collector still refuses the same query.
	assert1(sql_query_params(c, c"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < CAST(?1 AS INTEGER)) SELECT i FROM n", 1, &params[0]) == 0)
	assert_contains(sql_error(c), c"row limit")

void sql_cursor_test_values(sql_connection* c):
	sql_cursor_test_exec(c, c"CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, note TEXT, raw BLOB)")
	sql_cursor_test_exec(c, c"INSERT INTO items VALUES (1, 'one', NULL, x'610062'), (2, '', 'two', x''), (3, NULL, NULL, NULL)")
	sql_cursor* cur = sql_query_cursor(c, c"SELECT id, name, note, raw FROM items ORDER BY id", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	assert_strings_equal(c"1", sql_cursor_value(cur, 0))
	assert_strings_equal(c"one", sql_cursor_value(cur, 1))
	assert1(sql_cursor_value(cur, 2) == 0)
	assert_equal(-1, sql_cursor_value_length(cur, 2))
	assert_equal(3, sql_cursor_value_length(cur, 3))
	char* raw = sql_cursor_value(cur, 3)
	assert_equal(97, raw[0])
	assert_equal(0, raw[1])
	assert_equal(98, raw[2])
	assert_equal(0, raw[3])
	assert_equal(-2, sql_cursor_value_length(cur, 4))
	assert_equal(-2, sql_cursor_value_length(cur, -1))
	assert1(sql_cursor_value(cur, 4) == 0)
	assert_equal(1, sql_cursor_next(cur))
	# Empty text and an empty BLOB are non-null with length 0.
	assert_equal(0, sql_cursor_value_length(cur, 1))
	assert1(sql_cursor_value(cur, 1) != 0)
	assert_equal(0, sql_cursor_value_length(cur, 3))
	assert1(sql_cursor_value(cur, 3) != 0)
	assert_strings_equal(c"two", sql_cursor_value(cur, 2))
	assert_equal(1, sql_cursor_next(cur))
	assert1(sql_cursor_value(cur, 1) == 0)
	assert_equal(-1, sql_cursor_value_length(cur, 3))
	assert_equal(0, sql_cursor_next(cur))
	sql_cursor_free(cur)
	# Parameters, including NULL, bind natively.
	char*[2] params
	params[0] = c"2"
	params[1] = 0
	cur = sql_query_cursor(c, c"SELECT name, ?2 IS NULL FROM items WHERE id = ?1", 2, &params[0])
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	assert_strings_equal(c"", sql_cursor_value(cur, 0))
	assert_strings_equal(c"1", sql_cursor_value(cur, 1))
	assert_equal(0, sql_cursor_next(cur))
	sql_cursor_free(cur)
	# A command through a cursor runs and yields no rows.
	cur = sql_query_cursor(c, c"INSERT INTO items VALUES (4, 'four', NULL, NULL)", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(0, sql_cursor_columns(cur))
	assert_equal(0, sql_cursor_next(cur))
	sql_cursor_free(cur)
	sql_result* r = sql_query(c, c"SELECT count(*) FROM items")
	asserts(sql_error(c), r != 0)
	assert_strings_equal(c"4", sql_value(r, 0, 0))
	sql_result_free(r)

void sql_cursor_test_busy(sql_connection* c):
	sql_cursor* cur = sql_query_cursor(c, c"SELECT id FROM items ORDER BY id", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	# Other work on the connection fails clearly while the cursor is open.
	assert1(sql_query(c, c"SELECT 1") == 0)
	assert_contains(sql_error(c), c"open cursor")
	assert1(sql_exec(c, c"DELETE FROM items") == 0)
	assert1(sql_begin(c) == 0)
	assert_contains(sql_error(c), c"open cursor")
	assert1(sql_query_cursor(c, c"SELECT 1", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"open cursor")
	# The open cursor is unaffected by the refused calls.
	assert_strings_equal(c"1", sql_cursor_value(cur, 0))
	assert_equal(1, sql_cursor_next(cur))
	assert_strings_equal(c"2", sql_cursor_value(cur, 0))
	# Early free finalizes and unlocks the connection.
	sql_cursor_free(cur)
	sql_result* r = sql_query(c, c"SELECT count(*) FROM items")
	asserts(sql_error(c), r != 0)
	assert_strings_equal(c"4", sql_value(r, 0, 0))
	sql_result_free(r)
	# Early free of a cursor that never stepped.
	cur = sql_query_cursor(c, c"SELECT id FROM items", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	sql_cursor_free(cur)
	# Cursors work inside a transaction and leave it committable.
	assert1(sql_begin(c))
	sql_cursor_test_exec(c, c"INSERT INTO items VALUES (5, 'five', NULL, NULL)")
	cur = sql_query_cursor(c, c"SELECT id FROM items ORDER BY id", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	assert1(sql_commit(c) == 0)
	assert_contains(sql_error(c), c"open cursor")
	sql_cursor_free(cur)
	assert1(sql_commit(c))
	r = sql_query(c, c"SELECT count(*) FROM items")
	asserts(sql_error(c), r != 0)
	assert_strings_equal(c"5", sql_value(r, 0, 0))
	sql_result_free(r)

void sql_cursor_test_errors(sql_connection* c):
	assert1(sql_query_cursor(c, c"not valid sql", 0, cast(char**, 0)) == 0)
	assert1(sql_error(c)[0] != 0)
	assert1(sql_query_cursor(c, c"SELECT ?", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"parameter count")
	assert1(sql_query_cursor(c, c"SELECT 1; SELECT 2", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"one SQL statement")
	assert1(sql_query_cursor(c, c" -- empty", 0, cast(char**, 0)) == 0)
	assert1(sql_query_cursor(c, c"SELECT 1", 1, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"invalid query arguments")
	assert1(sql_query_cursor(c, cast(char*, 0), 0, cast(char**, 0)) == 0)
	assert1(sql_query_cursor(cast(sql_connection*, 0), c"SELECT 1", 0, cast(char**, 0)) == 0)
	# A runtime error after some rows: -1, sticky, connection released.
	sql_cursor* cur = sql_query_cursor(c, c"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5) SELECT i, abs(CASE WHEN i = 3 THEN -9223372036854775807 - 1 ELSE i END) FROM n", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	assert_equal(1, sql_cursor_next(cur))
	assert_equal(-1, sql_cursor_next(cur))
	assert_contains(sql_error(c), c"overflow")
	assert_equal(-1, sql_cursor_next(cur))
	assert1(sql_cursor_value(cur, 0) == 0)
	assert1(sql_exec(c, c"SELECT 1"))
	sql_cursor_free(cur)
	assert1(sql_exec(c, c"SELECT 1"))
	# Null-safe accessors.
	assert_equal(-1, sql_cursor_next(cast(sql_cursor*, 0)))
	assert_equal(0, sql_cursor_columns(cast(sql_cursor*, 0)))
	assert1(sql_cursor_column_name(cast(sql_cursor*, 0), 0) == 0)
	assert1(sql_cursor_value(cast(sql_cursor*, 0), 0) == 0)
	assert_equal(-2, sql_cursor_value_length(cast(sql_cursor*, 0), 0))
	sql_cursor_free(cast(sql_cursor*, 0))

int main():
	if (sql_sqlite_available() == 0):
		println(c"sql cursor: SKIP SQLite (libsqlite3.so.0 unavailable)")
		return 0
	sql_connection* c = sql_open_sqlite(c":memory:")
	asserts(sql_error(c), sql_is_open(c))
	sql_cursor_test_large(c)
	sql_cursor_test_values(c)
	sql_cursor_test_busy(c)
	sql_cursor_test_errors(c)
	# Closing the connection with an open cursor finalizes it; the cursor
	# then reports an error and can still be freed.
	sql_cursor* cur = sql_query_cursor(c, c"SELECT id FROM items", 0, cast(char**, 0))
	asserts(sql_error(c), cur != 0)
	assert_equal(1, sql_cursor_next(cur))
	sql_close(c)
	assert_equal(-1, sql_cursor_next(cur))
	assert1(sql_cursor_value(cur, 0) == 0)
	assert_strings_equal(c"id", sql_cursor_column_name(cur, 0))
	sql_cursor_free(cur)
	# Other drivers refuse cursors with a clear error.
	c = sql_connection_new(SQL_MYSQL)
	c.handle = 1
	assert1(sql_query_cursor(c, c"SELECT 1", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"only implemented for SQLite and PostgreSQL")
	c.handle = 0
	sql_close(c)
	c = sql_connection_new(SQL_SQLITE)
	assert1(sql_query_cursor(c, c"SELECT 1", 0, cast(char**, 0)) == 0)
	assert_contains(sql_error(c), c"closed")
	sql_close(c)
	println(c"sql cursor SQLite OK")
	return 0
