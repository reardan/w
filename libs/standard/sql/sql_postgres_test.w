# wbuild: arch_only=x64
# wbuild: target=sql_postgres_local_test tag=tests dep=sql_postgres_test data=tests/sql_postgres_fixture.py
# wbuild: step="python3 tests/sql_postgres_fixture.py bin/sql_postgres_test"
import libs.standard.sql.client
import lib.env
import lib.assert

int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"sql PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	sql_connection* c = sql_open_postgres(conninfo)
	asserts(sql_error(c), sql_is_open(c))
	asserts(sql_error(c), sql_exec(c, c"CREATE TEMP TABLE w_sql_items(id bigint, name text, note text)"))
	char*[3] params
	params[0] = c"9223372036854775807"
	params[1] = c"quoted ' text; DROP TABLE w_sql_items; --"
	params[2] = 0
	sql_result* r = sql_query_params(c, c"INSERT INTO w_sql_items VALUES($1, $2, $3)", 3, &params[0])
	asserts(sql_error(c), r != 0)
	assert_equal(1, r.affected)
	sql_result_free(r)
	assert1(sql_begin(c))
	assert1(sql_exec(c, c"INSERT INTO w_sql_items VALUES(2,'rollback','')"))
	assert1(sql_rollback(c))
	assert1(sql_begin(c))
	assert1(sql_exec(c, c"INSERT INTO w_sql_items VALUES(3,'commit','')"))
	assert1(sql_commit(c))
	r = sql_query(c, c"SELECT id, name, note FROM w_sql_items ORDER BY id DESC")
	asserts(sql_error(c), r != 0)
	assert_equal(2, r.rows)
	assert_strings_equal(c"name", sql_column_name(r, 1))
	assert_strings_equal(params[0], sql_value(r, 0, 0))
	assert_strings_equal(params[1], sql_value(r, 0, 1))
	assert_equal(-1, sql_value_length(r, 0, 2))
	assert_equal(0, sql_value_length(r, 1, 2))
	assert1(sql_query(c, c"SELECT 1; SELECT 2") == 0)
	assert1(sql_error(c)[0] != 0)
	assert1(sql_query(c, c"SELECT $1") == 0)
	assert1(sql_query(c, c"SELECT missing FROM w_sql_items") == 0)
	assert1(sql_begin(c))
	assert1(sql_query(c, c"SELECT missing FROM w_sql_items") == 0)
	assert1(sql_commit(c) == 0)
	assert_contains(sql_error(c), c"aborted")
	assert1(sql_begin(c))
	assert1(sql_commit(c))
	assert1(sql_exec(c, c"SELECT 42"))
	assert_strings_equal(c"", sql_error(c))
	sql_close(c)
	assert_strings_equal(params[1], sql_value(r, 0, 1))
	sql_result_free(r)
	c = sql_open_postgres(conninfo)
	asserts(sql_error(c), sql_is_open(c))
	assert1(sql_query(c, c"COPY (SELECT 1) TO STDOUT") == 0)
	assert_contains(sql_error(c), c"COPY")
	assert1(sql_is_open(c) == 0)
	sql_close(c)
	println(c"sql PostgreSQL live OK")
	return 0
