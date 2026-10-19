# wbuild: arch_only=x64
# wbuild: deps=libs/standard/orm/admin/templates/
# U5.1 admin on SQLite in memory (docs/projects/orm/u5_1.md): the
# scenarios of tests/orm/orm_admin_cases.w through U4.3's in-process
# client, with per-request statement counts.
import tests.orm.orm_admin_cases


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_admin: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	db.log_queries = 1
	adm_app* a = adm_app_new(db, orm_web_db_source_shared(db), 1)
	orm_admin_run(a)
	assert1(a.src.commits > 20 && a.src.opened == a.app.requests)
	orm_admin_site_free(a.site)
	orm_close(db)
	println(c"orm_admin_test: OK")
	return 0
