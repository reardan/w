# wbuild: arch_only=x64
# wbuild: target=orm_history_postgres_local_test tag=tests dep=orm_history_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_history_postgres_test"
# U3.3: trigger-based history on PostgreSQL. Needs W_SQL_POSTGRES (a libpq
# conninfo for an empty database); orm_history_postgres_local_test starts a
# temporary cluster for it. Scenario:
# libs/standard/orm/history/orm_history_cases.w.
import libs.standard.orm.history.orm_history_cases
import lib.env


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm history PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = orm_open_postgres(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	h_exec(db, c"SET client_min_messages = warning")
	orm_db* other = orm_open_postgres(conninfo)
	asserts(orm_db_error(other), orm_is_open(other))
	run_history_cases(db, other)
	orm_close(other)
	orm_close(db)
	println(c"orm_history_postgres_test: OK")
	return 0
