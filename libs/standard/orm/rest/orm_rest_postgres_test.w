# wbuild: arch_only=x64
# wbuild: target=orm_rest_postgres_local_test tag=tests dep=orm_rest_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_rest_postgres_test"
# U4.1 on PostgreSQL (the same scenarios as orm_rest_test, including the
# serializer's UNIQUE / FK / NOT NULL / CHECK mapping against a live
# server). Needs W_SQL_POSTGRES (a libpq conninfo for an empty database);
# orm_rest_postgres_local_test starts a temporary cluster for it.
import tests.orm.orm_rest_cases
import lib.env


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm_rest PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = orm_open_postgres(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	asserts(orm_db_error(db), orm_db_exec_sql(db, c"SET client_min_messages = warning"))
	rest_run_cases(db)
	orm_rest_teardown()
	orm_close(db)
	println(c"orm_rest_postgres_test: OK")
	return 0
