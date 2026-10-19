# wbuild: arch_only=x64
# wbuild: target=sql_savepoint_postgres_local_test tag=tests dep=sql_savepoint_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/sql_savepoint_postgres_test"
import libs.standard.sql.savepoint
import lib.env
import lib.assert

void sp_exec(sql_connection* c, char* query):
	asserts(sql_error(c), sql_exec(c, query))

void sp_expect_ids(sql_connection* c, char* want):
	sql_result* r = sql_query(c, c"SELECT coalesce(string_agg(id::text, ',' ORDER BY id), '') FROM sp_items")
	asserts(sql_error(c), r != 0)
	assert_strings_equal(want, sql_value(r, 0, 0))
	sql_result_free(r)

int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"sql savepoint PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	sql_connection* c = sql_open_postgres(conninfo)
	asserts(sql_error(c), sql_is_open(c))
	sp_exec(c, c"CREATE TEMP TABLE sp_items(id bigint PRIMARY KEY)")
	assert1(sql_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"active transaction")
	assert1(sql_rollback_to_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"active transaction")
	char* sp1 = sql_savepoint_name(1)
	char* sp2 = sql_savepoint_name(2)
	char* sp3 = sql_savepoint_name(3)
	# Three deep, rollback-to in the middle, then release.
	assert1(sql_begin(c))
	sp_exec(c, c"INSERT INTO sp_items VALUES(1)")
	asserts(sql_error(c), sql_savepoint(c, sp1))
	sp_exec(c, c"INSERT INTO sp_items VALUES(2)")
	asserts(sql_error(c), sql_savepoint(c, sp2))
	sp_exec(c, c"INSERT INTO sp_items VALUES(3)")
	asserts(sql_error(c), sql_savepoint(c, sp3))
	sp_exec(c, c"INSERT INTO sp_items VALUES(4)")
	sp_expect_ids(c, c"1,2,3,4")
	asserts(sql_error(c), sql_rollback_to_savepoint(c, sp2))
	sp_expect_ids(c, c"1,2")
	sp_exec(c, c"INSERT INTO sp_items VALUES(5)")
	asserts(sql_error(c), sql_release_savepoint(c, sp2))
	sp_expect_ids(c, c"1,2,5")
	asserts(sql_error(c), sql_rollback_to_savepoint(c, sp1))
	sp_expect_ids(c, c"1")
	sp_exec(c, c"INSERT INTO sp_items VALUES(6)")
	asserts(sql_error(c), sql_release_savepoint(c, sp1))
	assert1(sql_commit(c))
	sp_expect_ids(c, c"1,6")
	# The key use case: a failed statement aborts the PostgreSQL transaction;
	# rolling back to the savepoint before it recovers the transaction.
	assert1(sql_begin(c))
	sp_exec(c, c"INSERT INTO sp_items VALUES(10)")
	asserts(sql_error(c), sql_savepoint(c, sp1))
	sp_exec(c, c"INSERT INTO sp_items VALUES(11)")
	assert1(sql_exec(c, c"INSERT INTO sp_items VALUES(1)") == 0)
	assert1(sql_error(c)[0] != 0)
	# While aborted, ordinary statements and new savepoints fail.
	assert1(sql_exec(c, c"SELECT 1") == 0)
	assert_contains(sql_error(c), c"aborted")
	assert1(sql_savepoint(c, sp2) == 0)
	asserts(sql_error(c), sql_rollback_to_savepoint(c, sp1))
	sp_expect_ids(c, c"1,6,10")
	sp_exec(c, c"INSERT INTO sp_items VALUES(12)")
	asserts(sql_error(c), sql_release_savepoint(c, sp1))
	assert1(sql_commit(c))
	sp_expect_ids(c, c"1,6,10,12")
	# Nested failure: recovering the inner level keeps outer work.
	assert1(sql_begin(c))
	asserts(sql_error(c), sql_savepoint(c, sp1))
	sp_exec(c, c"INSERT INTO sp_items VALUES(20)")
	asserts(sql_error(c), sql_savepoint(c, sp2))
	sp_exec(c, c"INSERT INTO sp_items VALUES(21)")
	asserts(sql_error(c), sql_savepoint(c, sp3))
	assert1(sql_exec(c, c"SELECT missing FROM sp_items") == 0)
	asserts(sql_error(c), sql_rollback_to_savepoint(c, sp3))
	asserts(sql_error(c), sql_release_savepoint(c, sp3))
	asserts(sql_error(c), sql_release_savepoint(c, sp2))
	asserts(sql_error(c), sql_release_savepoint(c, sp1))
	assert1(sql_commit(c))
	sp_expect_ids(c, c"1,6,10,12,20,21")
	# Bad names are rejected before any SQL is sent.
	assert1(sql_begin(c))
	assert1(sql_savepoint(c, c"9lives") == 0)
	assert_contains(sql_error(c), c"invalid savepoint name")
	assert1(sql_release_savepoint(c, c"x\"y") == 0)
	assert_contains(sql_error(c), c"invalid savepoint name")
	# An unknown savepoint is a server error that aborts the transaction;
	# commit then reports the abort and ends the transaction.
	assert1(sql_rollback_to_savepoint(c, c"never_opened") == 0)
	assert1(sql_error(c)[0] != 0)
	assert1(sql_commit(c) == 0)
	assert_contains(sql_error(c), c"aborted")
	assert1(sql_savepoint(c, sp1) == 0)
	assert_contains(sql_error(c), c"active transaction")
	sp_expect_ids(c, c"1,6,10,12,20,21")
	free(sp1)
	free(sp2)
	free(sp3)
	sql_close(c)
	println(c"sql savepoint PostgreSQL live OK")
	return 0
