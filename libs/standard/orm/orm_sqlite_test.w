# wbuild: arch_only=x64
# U1.3 end to end on SQLite in memory: querysets, loading, writes and
# query counts over the library fixture (docs/projects/orm/u1_3.md).
import tests.orm.orm_e2e_cases


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_sqlite: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	assert_equal(0, db.query_count)
	orm_e2e_run(db)
	orm_close(db)
	orm_db* bad = orm_open_sqlite(c"/nonexistent-dir/x/y.db")
	assert1(orm_is_open(bad) == 0)
	assert1(strlen(orm_db_error(bad)) > 0)
	orm_close(bad)
	println(c"orm_sqlite_test: OK")
	return 0
