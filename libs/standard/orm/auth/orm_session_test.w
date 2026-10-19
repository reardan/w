# wbuild: arch_only=x64
# wbuild: target=orm_session_gen_test tag=tests dep=orm_gen input=libs/standard/orm/auth/
# wbuild: step="bin/orm_gen libs/standard/orm/auth/session.orm -o bin/orm_session_gen/session --module libs.standard.orm.auth.session_orm"
# wbuild: step="cmp bin/orm_session_gen/session_orm.w libs/standard/orm/auth/session_orm.w"
# wbuild: step="cmp bin/orm_session_gen/session_orm_api.w libs/standard/orm/auth/session_orm_api.w"
# wbuild: step="cmp bin/orm_session_gen/session_schema.json libs/standard/orm/auth/session_schema.json"
# U3.2 end to end on SQLite in memory: sessions, API tokens, CSRF and the
# login throttle (docs/projects/orm/u3_2.md). orm_session_gen_test (above)
# regenerates the committed session_orm*.w / session_schema.json from
# session.orm and fails when they drift.
import tests.orm.orm_session_cases


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_session: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	orm_session_run(db)
	orm_close(db)
	println(c"orm_session_test: OK")
	return 0
