# wbuild: binary=orm_example_test arch=x64 tag=tests_x64
# wbuild: step="bin/orm_example_test" expect_stdout="orm_example"
# wbuild: target=orm_example_gen_test tag=tests dep=orm_gen input=examples/orm/library/
# wbuild: step="bin/orm_gen examples/orm/library/library.orm -o bin/orm_example_gen/library --module examples.orm.library.library_orm"
# wbuild: step="cmp bin/orm_example_gen/library_orm.w examples/orm/library/library_orm.w"
# wbuild: step="cmp bin/orm_example_gen/library_orm_api.w examples/orm/library/library_orm_api.w"
# wbuild: step="cmp bin/orm_example_gen/library_schema.json examples/orm/library/library_schema.json"
# wbuild: step="bin/orm_gen examples/orm/library/v1/library_v1.orm -o bin/orm_example_gen/library_v1 --module examples.orm.library.v1.library_v1_orm"
# wbuild: step="cmp bin/orm_example_gen/library_v1_orm.w examples/orm/library/v1/library_v1_orm.w"
# wbuild: step="cmp bin/orm_example_gen/library_v1_orm_api.w examples/orm/library/v1/library_v1_orm_api.w"
# wbuild: step="cmp bin/orm_example_gen/library_v1_schema.json examples/orm/library/v1/library_v1_schema.json"
# The example library app end to end on a SQLite file (unit U5.2;
# examples/orm/library/README.md): example_cases.w with release-2 code and
# release-1 code on two connections. The conventional *_test.w scan does
# not cover examples/, so the target is spelled out above (x64 only: the
# SQL client is Linux x64). orm_example_gen_test (above)
# regenerates the committed library_orm*.w / library_v1_orm*.w and
# snapshots and fails when they drift from the .orm files.
import examples.orm.library.example_cases


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_example: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	char* path = c"bin/orm_example_test.db"
	unlink(path)
	orm_db* db = orm_open_sqlite(path)
	asserts(orm_db_error(db), orm_is_open(db))
	orm_db* old = orm_open_sqlite(path)
	asserts(orm_db_error(old), orm_is_open(old))
	example_run(db, old)
	orm_close(old)
	orm_close(db)
	unlink(path)
	println(c"orm_example_test: OK")
	return 0
