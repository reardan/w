# wbuild: arch_only=x64
# U2.1 on SQLite in memory: orm_atomic, savepoints, on_commit and the
# select_for_update error (docs/projects/orm/u2_1.md).
import tests.orm.orm_atomic_cases


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_atomic: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	orm_atomic_run(db)
	orm_close(db)
	println(c"orm_atomic_test: OK")
	return 0
