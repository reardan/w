# wbuild: arch_only=x64
# wbuild: target=sql_native_abi_test tag=tests dep=sql_native_test data=tests/sql_native_fixture.c data=tests/sql_native_fixture.py
# wbuild: step="python3 tests/sql_native_fixture.py bin/sql_native_test"
import libs.standard.sql.client
import lib.assert

void sql_native_test_rows(sql_connection* c):
	asserts(sql_error(c), sql_is_open(c))
	sql_result* r = sql_query(c, c"SELECT fixture")
	asserts(sql_error(c), r != 0)
	assert_equal(3, r.columns)
	assert_equal(1, r.rows)
	assert_strings_equal(c"value", sql_column_name(r, 0))
	assert_strings_equal(c"hello", sql_value(r, 0, 0))
	assert_equal(-1, sql_value_length(r, 0, 1))
	assert_equal(0, sql_value_length(r, 0, 2))
	sql_result_free(r)
	assert1(sql_query(c, c"ERROR") == 0)
	assert_contains(sql_error(c), c"fixture")
	r = sql_query(c, c"SELECT fixture")
	asserts(sql_error(c), r != 0)
	sql_result_free(r)
	if (c.driver == SQL_MYSQL || c.driver == SQL_SQLSERVER):
		assert1(sql_query(c, c"SELECT multiple") == 0)
		assert_contains(sql_error(c), c"multiple")
		char*[1] params
		params[0] = c"value"
		assert1(sql_query_params(c, c"SELECT ?", 1, &params[0]) == 0)
		assert_contains(sql_error(c), c"binding")
	assert1(sql_begin(c))
	assert1(sql_rollback(c))
	assert1(sql_begin(c))
	assert1(sql_commit(c))
	sql_close(c)

int main(int argc, int argv):
	if (argc < 2):
		# Failed opens must retain diagnostics and be safe to close.
		if (sql_postgres_available()):
			sql_connection* p = sql_open_postgres(c"host=127.0.0.1 port=1 connect_timeout=1 dbname=w_sql_missing")
			assert1(sql_is_open(p) == 0)
			assert1(sql_error(p)[0] != 0)
			sql_close(p)
		if (sql_mysql_available()):
			sql_connection* m = sql_open_mysql(c"127.0.0.1", c"w_sql_missing", c"", c"w_sql_missing", 1)
			assert1(sql_is_open(m) == 0)
			assert1(sql_error(m)[0] != 0)
			sql_close(m)
		println(c"sql native failure paths OK")
		return 0
	if (argc == 3):
		assert1(sql_sqlite_available() == 0)
		assert1(sql_postgres_available() == 0)
		assert1(sql_mysql_available() == 0)
		assert1(sql_sqlserver_available() == 0)
		assert1(sql_oracle_available() == 0)
		println(c"sql missing native symbols OK")
		return 0
	assert1(sql_mysql_available())
	assert1(sql_sqlserver_available())
	assert1(sql_oracle_available())
	sql_native_test_rows(sql_open_mysql(c"fixture", c"user", c"password", c"db"))
	sql_native_test_rows(sql_open_sqlserver(c"fixture", c"user", c"password", c"db"))
	sql_native_test_rows(sql_open_oracle(c"fixture", c"user", c"password"))
	sql_connection* c = sql_open_oracle(c"fixture", c"user", c"password")
	char*[2] params
	params[0] = c"quoted ' text"
	params[1] = 0
	sql_result* r = sql_query_params(c, c"SELECT bound", 2, &params[0])
	asserts(sql_error(c), r != 0)
	assert_strings_equal(params[0], sql_value(r, 0, 0))
	assert_equal(-1, sql_value_length(r, 0, 1))
	sql_result_free(r)
	assert1(sql_query(c, c"SELECT too_wide") == 0)
	assert_contains(sql_error(c), c"column limit")
	assert1(sql_query(c, c"SELECT truncated") == 0)
	assert_contains(sql_error(c), c"truncated")
	sql_close(c)
	c = sql_open_sqlserver(c"fail", c"user", c"password", c"db")
	assert1(sql_is_open(c) == 0)
	assert_contains(sql_error(c), c"fixture login")
	sql_close(c)
	c = sql_open_oracle(c"fail", c"user", c"password")
	assert1(sql_is_open(c) == 0)
	assert_contains(sql_error(c), c"fixture")
	sql_close(c)
	c = sql_open_mysql(c"fail", c"user", c"password", c"db")
	assert1(sql_is_open(c) == 0)
	assert_contains(sql_error(c), c"fixture")
	sql_close(c)
	char* fixture = dl_open(c"libclntsh.so")
	int live = dl_trampoline_argv(dl_sym(fixture, c"sql_fixture_live_handles"), 0, 1)
	assert1(live != 0)
	assert_equal(0, sql_native_call(live))
	println(c"sql native ABI fixtures OK")
	return 0
