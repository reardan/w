# wbuild: arch_only=x64
# U3.3: trigger-based history on SQLite (a database file, so a second
# connection can write without a context). Scenario:
# libs/standard/orm/history/orm_history_cases.w.
import libs.standard.orm.history.orm_history_cases
import lib.file


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm history sqlite: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	char* path = c"bin/orm_history_sqlite_test.db"
	unlink(path)
	orm_db* db = orm_open_sqlite(path)
	asserts(orm_db_error(db), orm_is_open(db))
	orm_db* other = orm_open_sqlite(path)
	asserts(orm_db_error(other), orm_is_open(other))
	run_history_cases(db, other)
	orm_close(other)
	orm_close(db)
	unlink(path)
	println(c"orm_history_sqlite_test: OK")
	return 0
