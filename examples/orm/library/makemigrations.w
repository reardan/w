# wbuild: binary=orm_library_makemigrations arch=x64 tag=tests_x64
# wbuild: step="bin/orm_library_makemigrations --dry-run" expect_stdout="library: 0 new migrations"
/*
makemigrations for the example library app (issue #754, unit U5.2;
README.md): plans the next migrations of each app (U2.2's
orm_makemigrations_next over the committed ones) and writes them with
orm_write_migrations under examples/orm/library/migrations/<app>/.

	bin/orm_library_makemigrations [--release1] [--rename <hint>] [--dry-run]

--release1 plans the library app against v1/library_v1.orm instead of
library.orm (how migrations/library/m0001_initial.w was made).
--rename passes one autodetector hint ("library_book.pages->page_count"
made the 0002..0005 migrations). --dry-run prints the plan and writes
nothing. Run it from the repository root. Migrations are planned for
PostgreSQL, whose plans are the safe superset; the test lints every one
on both dialects.
*/
import examples.orm.library.library_orm
import examples.orm.library.v1.library_v1_orm
import examples.orm.library.migrations
import libs.standard.orm.auth.auth_orm
import libs.standard.orm.auth.session_orm
import libs.standard.orm.migrate.autodetect
import libs.standard.orm.migrate.writer
import libs.standard.orm.migrate.lint
import lib.args


list[orm_migration*] mk_existing(char* app):
	list[orm_migration*] out = new list[orm_migration*]
	for orm_migration* m in library_app_migrations():
		if (strcmp(m.app, app) == 0): out.push(m)
	return out


# Plans and (unless dry) writes app's next migrations; 1 on success.
int mk_app(char* app, char* snapshot, list[char*] hints, int dry):
	list[orm_migration*] existing = mk_existing(app)
	orm_makemig* r = orm_makemigrations_next(app, existing, snapshot, ORM_DIALECT_POSTGRES, hints)
	if (r.error != 0):
		print2(app)
		print2(c": ")
		println2(r.error)
		return 0
	print(app)
	print(c": ")
	print(itoa(r.migrations.length))
	println(c" new migrations")
	for orm_migration* m in r.migrations:
		print(c"  ")
		println(m.name)
		list[orm_lint_finding*] findings = orm_lint_migration(m, ORM_DIALECT_POSTGRES)
		if (findings.length > 0): print(orm_lint_format(findings))
		orm_lint_free(findings)
	if (dry || r.migrations.length == 0): return 1
	char* dir = orm_concat3(c"examples/orm/library/migrations/", app, c"")
	char* prefix = orm_concat3(c"examples.orm.library.migrations.", app, c"")
	char* error = 0
	int n = orm_write_migrations(dir, prefix, app, r.migrations, &error)
	if (n < 0):
		print2(c"makemigrations: ")
		println2(error)
		return 0
	return 1


int main(int argc, int argv):
	args_init(argc, argv)
	args_declare_bool(c"release1")
	args_declare_bool(c"dry-run")
	int dry = args_has_flag(c"dry-run")
	list[char*] hints = new list[char*]
	char* rename = args_value(c"rename")
	if (rename != 0): hints.push(rename)
	char* library = library_schema_json()
	if (args_has_flag(c"release1")): library = library_v1_schema_json()
	int ok = mk_app(c"auth", auth_schema_json(), 0, dry)
	ok = ok && mk_app(c"session", session_schema_json(), 0, dry)
	ok = ok && mk_app(c"library", library, hints, dry)
	if (ok): return 0
	return 1
