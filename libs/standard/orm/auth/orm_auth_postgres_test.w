# wbuild: arch_only=x64
# wbuild: target=orm_auth_postgres_local_test tag=tests dep=orm_auth_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_auth_postgres_test"
# U3.1 end to end on PostgreSQL (the same scenarios as orm_auth_test).
# Needs W_SQL_POSTGRES (a libpq conninfo for an empty database); the
# orm_auth_postgres_local_test target starts a temporary cluster for it.
import tests.orm.orm_auth_cases
import lib.env


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm_auth PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = orm_open_postgres(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	auth_check(db, orm_db_exec_sql(db, c"SET client_min_messages = warning"))
	auth_check(db, auth_drop_schema(db))
	orm_auth_run(db)
	auth_check(db, auth_drop_schema(db))
	orm_close(db)
	println(c"orm_auth_postgres_test: OK")
	return 0
