# wbuild: arch_only=x64
# U2.4: the migration applier on SQLite, end to end over every row of plan
# section 5.2 (libs/standard/orm/migrate/orm_apply_scenario.w).
import libs.standard.orm.migrate.orm_apply_scenario


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm apply sqlite: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	char* error = 0
	orm_db* db = orm_migrate_open_sqlite(c":memory:", &error)
	asserts(error, db != 0)
	run_apply_scenario(db)
	sql_close(db.conn)
	orm_db* fresh = orm_migrate_open_sqlite(c":memory:", &error)
	asserts(error, fresh != 0)
	run_makemigrations_roundtrip(fresh)
	sql_close(fresh.conn)
	println(c"orm apply sqlite OK")
	return 0
