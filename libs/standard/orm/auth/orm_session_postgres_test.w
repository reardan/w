# wbuild: arch_only=x64
# wbuild: target=orm_session_postgres_local_test tag=tests dep=orm_session_postgres_test data=tests/sql_postgres_fixture.py
# wbuild: step="python3 tests/sql_postgres_fixture.py bin/orm_session_postgres_test"
# U3.2 end to end on PostgreSQL (the same scenarios as orm_session_test).
# Needs W_SQL_POSTGRES (a libpq conninfo for an empty database); the
# orm_session_postgres_local_test target starts a temporary cluster for it.
import tests.orm.orm_session_cases
import lib.env


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm_session PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = orm_open_postgres(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	sess_check(db, orm_db_exec_sql(db, c"SET client_min_messages = warning"))
	sess_check(db, sess_drop_schema(db))
	orm_session_run(db)
	sess_check(db, sess_drop_schema(db))
	orm_close(db)
	println(c"orm_session_postgres_test: OK")
	return 0
