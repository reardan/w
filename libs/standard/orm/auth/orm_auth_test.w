# wbuild: arch_only=x64
# wbuild: target=orm_auth_gen_test tag=tests dep=orm_gen input=libs/standard/orm/auth/
# wbuild: step="bin/orm_gen libs/standard/orm/auth/auth.orm -o bin/orm_auth_gen/auth --module libs.standard.orm.auth.auth_orm"
# wbuild: step="cmp bin/orm_auth_gen/auth_orm.w libs/standard/orm/auth/auth_orm.w"
# wbuild: step="cmp bin/orm_auth_gen/auth_orm_api.w libs/standard/orm/auth/auth_orm_api.w"
# wbuild: step="cmp bin/orm_auth_gen/auth_schema.json libs/standard/orm/auth/auth_schema.json"
# U3.1 end to end on SQLite in memory: users, authentication, hash
# upgrades, groups and permissions (docs/projects/orm/u3_1.md).
# orm_auth_gen_test (above) regenerates the committed auth_orm*.w /
# auth_schema.json from auth.orm and fails when they drift.
import tests.orm.orm_auth_cases


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_auth: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	orm_auth_run(db)
	orm_close(db)
	println(c"orm_auth_test: OK")
	return 0
