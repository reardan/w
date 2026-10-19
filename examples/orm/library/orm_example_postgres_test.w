# wbuild: binary=orm_example_postgres_test arch=x64 tag=tests_x64
# wbuild: step="bin/orm_example_postgres_test" expect_stdout="orm_example"
# wbuild: target=orm_example_postgres_local_test tag=tests dep=orm_example_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_example_postgres_test"
# The example library app end to end on PostgreSQL (unit U5.2; the same
# example_cases.w as orm_example_test), in a fresh schema orm_example.
# Needs W_SQL_POSTGRES (a libpq conninfo); orm_example_postgres_local_test
# starts a temporary cluster for it through bin/sql_postgres_fixture
# (which refuses to run as root).
import examples.orm.library.example_cases
import lib.env


orm_db* ex_pg_open(char* conninfo):
	orm_db* db = orm_open_postgres(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	asserts(orm_db_error(db), orm_db_exec_sql(db, c"SET client_min_messages = warning"))
	return db


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm_example PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = ex_pg_open(conninfo)
	asserts(orm_db_error(db), orm_db_exec_sql(db, c"DROP SCHEMA IF EXISTS orm_example CASCADE"))
	asserts(orm_db_error(db), orm_db_exec_sql(db, c"CREATE SCHEMA orm_example"))
	asserts(orm_db_error(db), orm_db_exec_sql(db, c"SET search_path TO orm_example"))
	orm_db* old = ex_pg_open(conninfo)
	asserts(orm_db_error(old), orm_db_exec_sql(old, c"SET search_path TO orm_example"))
	db.query_count = 0
	example_run(db, old)
	orm_close(old)
	asserts(orm_db_error(db), orm_db_exec_sql(db, c"DROP SCHEMA orm_example CASCADE"))
	orm_close(db)
	println(c"orm_example_postgres_test: OK")
	return 0
