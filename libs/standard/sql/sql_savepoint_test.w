# wbuild: arch_only=x64
import libs.standard.sql.savepoint
import lib.assert

void sp_exec(sql_connection* c, char* query):
	asserts(sql_error(c), sql_exec(c, query))

void sp_expect_ids(sql_connection* c, char* want):
	sql_result* r = sql_query(c, c"SELECT coalesce(group_concat(id, ','), '') FROM (SELECT id FROM sp_items ORDER BY id)")
	asserts(sql_error(c), r != 0)
	assert_strings_equal(want, sql_value(r, 0, 0))
	sql_result_free(r)

void sp_names():
	char* name = sql_savepoint_name(3)
	assert_strings_equal(c"w_sp_3", name)
	free(name)
	name = sql_savepoint_name(0)
	assert_strings_equal(c"w_sp_0", name)
	free(name)
	name = sql_savepoint_name(12345)
	assert_strings_equal(c"w_sp_12345", name)
	free(name)
	assert1(sql_savepoint_name(-1) == 0)
	assert1(sql_savepoint_name_valid(c"a"))
	assert1(sql_savepoint_name_valid(c"_x9"))
	assert1(sql_savepoint_name_valid(c"w_sp_3"))
	assert1(sql_savepoint_name_valid(c"1abc") == 0)
	assert1(sql_savepoint_name_valid(c"") == 0)
	assert1(sql_savepoint_name_valid(cast(char*, 0)) == 0)
	assert1(sql_savepoint_name_valid(c"a-b") == 0)
	assert1(sql_savepoint_name_valid(c"a b") == 0)
	assert1(sql_savepoint_name_valid(c"a\"b") == 0)
	assert1(sql_savepoint_name_valid(c"caf\xc3\xa9") == 0)

# 63 and 64 byte identifiers.
char* sp_long_name(int n):
	char* s = cast(char*, malloc(n + 1))
	for i in range(n): s[i] = 'a'
	s[n] = 0
	return s

void sp_unsupported():
	sql_connection* c = sql_connection_new(SQL_MYSQL)
	c.handle = 1
	c.transaction = 1
	assert1(sql_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"not supported")
	assert1(sql_release_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"not supported")
	assert1(sql_rollback_to_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"not supported")
	free(c.error)
	free(c)
	assert1(sql_savepoint(cast(sql_connection*, 0), c"a") == 0)

int main():
	sp_names()
	sp_unsupported()
	if (sql_sqlite_available() == 0):
		println(c"sql savepoint: SKIP SQLite (libsqlite3.so.0 unavailable)")
		return 0
	sql_connection* c = sql_open_sqlite(c":memory:")
	asserts(sql_error(c), sql_is_open(c))
	sp_exec(c, c"CREATE TABLE sp_items(id INTEGER PRIMARY KEY)")
	# Outside a transaction every operation is rejected.
	assert1(sql_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"active transaction")
	assert1(sql_release_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"active transaction")
	assert1(sql_rollback_to_savepoint(c, c"a") == 0)
	assert_contains(sql_error(c), c"active transaction")
	# Three deep, rollback-to in the middle, then release.
	assert1(sql_begin(c))
	sp_exec(c, c"INSERT INTO sp_items VALUES(1)")
	char* sp1 = sql_savepoint_name(1)
	char* sp2 = sql_savepoint_name(2)
	char* sp3 = sql_savepoint_name(3)
	asserts(sql_error(c), sql_savepoint(c, sp1))
	sp_exec(c, c"INSERT INTO sp_items VALUES(2)")
	asserts(sql_error(c), sql_savepoint(c, sp2))
	sp_exec(c, c"INSERT INTO sp_items VALUES(3)")
	asserts(sql_error(c), sql_savepoint(c, sp3))
	sp_exec(c, c"INSERT INTO sp_items VALUES(4)")
	sp_expect_ids(c, c"1,2,3,4")
	# Rolling back to the middle savepoint discards levels 2 and 3 but keeps
	# savepoint 2 open; savepoint 3 no longer exists.
	asserts(sql_error(c), sql_rollback_to_savepoint(c, sp2))
	sp_expect_ids(c, c"1,2")
	assert1(sql_release_savepoint(c, sp3) == 0)
	assert1(sql_error(c)[0] != 0)
	sp_exec(c, c"INSERT INTO sp_items VALUES(5)")
	asserts(sql_error(c), sql_release_savepoint(c, sp2))
	sp_expect_ids(c, c"1,2,5")
	# Released work still belongs to the enclosing savepoint.
	asserts(sql_error(c), sql_rollback_to_savepoint(c, sp1))
	sp_expect_ids(c, c"1")
	sp_exec(c, c"INSERT INTO sp_items VALUES(6)")
	asserts(sql_error(c), sql_release_savepoint(c, sp1))
	assert1(sql_commit(c))
	sp_expect_ids(c, c"1,6")
	# Releasing an outer savepoint releases the inner ones; an outer rollback
	# discards released work.
	assert1(sql_begin(c))
	asserts(sql_error(c), sql_savepoint(c, sp1))
	sp_exec(c, c"INSERT INTO sp_items VALUES(7)")
	asserts(sql_error(c), sql_savepoint(c, sp2))
	sp_exec(c, c"INSERT INTO sp_items VALUES(8)")
	asserts(sql_error(c), sql_release_savepoint(c, sp1))
	assert1(sql_rollback_to_savepoint(c, sp2) == 0)
	sp_expect_ids(c, c"1,6,7,8")
	assert1(sql_rollback(c))
	sp_expect_ids(c, c"1,6")
	# Bad names are rejected before any SQL is sent.
	assert1(sql_begin(c))
	assert1(sql_savepoint(c, c"1abc") == 0)
	assert_contains(sql_error(c), c"invalid savepoint name")
	assert1(sql_savepoint(c, c"x\"; DROP TABLE sp_items; --") == 0)
	assert_contains(sql_error(c), c"invalid savepoint name")
	assert1(sql_rollback_to_savepoint(c, c"") == 0)
	assert_contains(sql_error(c), c"invalid savepoint name")
	assert1(sql_release_savepoint(c, cast(char*, 0)) == 0)
	assert_contains(sql_error(c), c"invalid savepoint name")
	char* longest = sp_long_name(63)
	char* too_long = sp_long_name(64)
	asserts(sql_error(c), sql_savepoint(c, longest))
	assert_strings_equal(c"", sql_error(c))
	assert1(sql_savepoint(c, too_long) == 0)
	assert_contains(sql_error(c), c"invalid savepoint name")
	# Unknown savepoint: the database reports it.
	assert1(sql_rollback_to_savepoint(c, c"never_opened") == 0)
	assert1(sql_error(c)[0] != 0)
	asserts(sql_error(c), sql_release_savepoint(c, longest))
	assert1(sql_commit(c))
	sp_expect_ids(c, c"1,6")
	free(longest)
	free(too_long)
	free(sp1)
	free(sp2)
	free(sp3)
	sql_close(c)
	println(c"sql savepoint SQLite OK")
	return 0
