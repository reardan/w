# wbuild: arch_only=x64
# wbuild: deps=libs/standard/orm/admin/templates/
# wbuild: target=orm_admin_postgres_local_test tag=tests dep=orm_admin_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_admin_postgres_test"
# U5.1 admin on PostgreSQL (the orm_admin_test scenarios). Requests take
# connections from a pooled orm_web_db_source, so each runs in its own
# transaction on its own connection and the history context is
# transaction-local. Needs W_SQL_POSTGRES; orm_admin_postgres_local_test
# starts a temporary cluster for it.
import tests.orm.orm_admin_cases
import lib.env


orm_db* open_pg(void* conninfo):
	orm_db* db = orm_open_postgres(cast(char*, conninfo))
	if (orm_is_open(db)): orm_db_exec_sql(db, c"SET client_min_messages = warning")
	return db


int drop_all(orm_db* db):
	int ok = orm_db_exec_sql(db, c"DROP TABLE IF EXISTS admintest_loan")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS library_book_history")
	ok = ok && orm_db_exec_sql(db, c"DROP FUNCTION IF EXISTS w_hist_library_book() CASCADE")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS orm_migrations")
	ok = ok && sess_drop_schema(db)
	return ok && library_drop_schema(db)


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm_admin PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = open_pg(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	at_check(db, drop_all(db))
	orm_web_db_source* src = orm_web_db_source_new(open_pg, conninfo)
	src.max_idle = 2
	adm_app* a = adm_app_new(db, src, 0)
	orm_admin_run(a)
	assert1(src.opened >= 1 && src.opened <= 2)
	assert1(src.reused > 20)
	orm_web_db_source_free(src)
	at_check(db, drop_all(db))
	orm_admin_site_free(a.site)
	orm_close(db)
	println(c"orm_admin_postgres_test: OK")
	return 0
