# wbuild: arch_only=x64
# wbuild: deps=tests/orm/templates/
# wbuild: target=orm_web_postgres_local_test tag=tests dep=orm_web_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_web_postgres_test"
# U4.3 end to end on PostgreSQL (the orm_web_test scenarios). Requests
# take connections from a pooled orm_web_db_source opened by a factory,
# so every request runs in its own transaction on its own connection, and
# a failed INSERT inside a form save (savepoint) must not abort the
# request. Needs W_SQL_POSTGRES; orm_web_postgres_local_test starts a
# temporary cluster for it.
import libs.standard.orm.web.orm_web_cases
import lib.env


orm_db* open_pg(void* conninfo):
	orm_db* db = orm_open_postgres(cast(char*, conninfo))
	if (orm_is_open(db)): orm_db_exec_sql(db, c"SET client_min_messages = warning")
	return db


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm_web PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = open_pg(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	wa_check(db, sess_drop_schema(db))
	wa_check(db, library_drop_schema(db))
	orm_web_db_source* src = orm_web_db_source_new(open_pg, conninfo)
	src.max_idle = 2
	webapp* w = webapp_new(db, src, 0)
	orm_web_run(w)
	assert1(src.opened >= 1 && src.opened <= 2)
	assert1(src.reused > 10)
	orm_web_db_source_free(src)
	wa_check(db, sess_drop_schema(db))
	wa_check(db, library_drop_schema(db))
	orm_close(db)
	println(c"orm_web_postgres_test: OK")
	return 0
