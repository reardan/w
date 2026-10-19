# wbuild: arch_only=x64
# wbuild: timeout=300000
# U2.1 on SQLite in memory: prefetch_related, explicit loaders and
# iterator() with query-count assertions (docs/projects/orm/u2_1.md).
import tests.orm.orm_related_cases


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_related: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	orm_related_run(db, c"INSERT INTO library_tag (name) WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 120000) SELECT 'bulk' || x FROM c")
	orm_close(db)
	println(c"orm_related_test: OK")
	return 0
