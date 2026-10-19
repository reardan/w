# wbuild: arch_only=x64
# wbuild: target=orm_apply_postgres_local_test tag=tests dep=orm_apply_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_apply_postgres_test"
# U2.4: the migration applier on PostgreSQL, end to end over every row of
# plan section 5.2 (libs/standard/orm/migrate/orm_apply_scenario.w).
import libs.standard.orm.migrate.orm_apply_scenario
import lib.env


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm apply PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	char* error = 0
	orm_db* db = orm_migrate_open_postgres(conninfo, &error)
	asserts(error, db != 0)
	sql_exec(db.conn, c"SET client_min_messages = warning")
	run_apply_scenario(db)
	# The round trip starts from an empty schema of its own.
	asserts(sql_error(db.conn), sql_exec(db.conn, c"CREATE SCHEMA w_roundtrip"))
	asserts(sql_error(db.conn), sql_exec(db.conn, c"SET search_path TO w_roundtrip"))
	run_makemigrations_roundtrip(db)
	sql_close(db.conn)
	println(c"orm apply PostgreSQL OK")
	return 0
