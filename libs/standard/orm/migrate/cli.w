# w-orm migration command line (issue #754, unit U2.4).
#
# An application builds its migration list (and registers its backfills),
# then hands its arguments over:
#
#   import libs.standard.orm.migrate.cli
#   int main(int argc, int argv):
#   	orm_backfill_register(c"blog_post_slug_backfill", post_slug_backfill)
#   	return orm_cli_main(argc, argv, blog_migrations())
#
#   app migrate apply  --sqlite <path> | --postgres <conninfo> [--force] [--upto <name>]
#   app migrate sql    --sqlite <path> | --postgres <conninfo> [<name>]
#   app migrate status --sqlite <path> | --postgres <conninfo>
#   app migrate lint   [--sqlite | --postgres] (no connection; dialect only)
#
# Exit status 0 on success, 1 on any error or lint error, 2 on usage.
import libs.standard.orm.migrate.apply
import lib.args


void orm_cli_usage():
	println2(c"usage: migrate apply|sql|status|lint (--sqlite <path> | --postgres <conninfo>) [--force] [--upto <name>] [<name>]")


int orm_cli_lint(list[orm_migration*] ms, int dialect):
	int errors = 0
	int warnings = 0
	for orm_migration* m in ms:
		list[orm_lint_finding*] findings = orm_lint_migration(m, dialect)
		errors = errors + orm_lint_count(findings, ORM_LINT_ERROR)
		warnings = warnings + orm_lint_count(findings, ORM_LINT_WARNING)
		if (findings.length > 0):
			char* text = orm_lint_format(findings)
			print(m.app)
			print(c".")
			print(m.name)
			println(c":")
			print(text)
			free(text)
		orm_lint_free(findings)
	print(c"lint: ")
	print(itoa(ms.length))
	print(c" migrations, ")
	print(itoa(errors))
	print(c" errors, ")
	print(itoa(warnings))
	println(c" warnings")
	return errors > 0


int orm_cli_main(int argc, int argv, list[orm_migration*] ms):
	args_init(argc, argv)
	args_declare_bool(c"force")
	if (args_positional_count() < 2 || strcmp(args_positional(0), c"migrate") != 0):
		orm_cli_usage()
		return 2
	char* cmd = args_positional(1)
	char* name = 0
	if (args_positional_count() > 2): name = args_positional(2)
	int force = args_has_flag(c"force")
	char* sqlite = args_value(c"sqlite")
	char* postgres = args_value(c"postgres")
	if (strcmp(cmd, c"lint") == 0):
		int dialect = ORM_DIALECT_SQLITE
		if (args_has_flag(c"postgres")): dialect = ORM_DIALECT_POSTGRES
		return orm_cli_lint(ms, dialect)
	int known = strcmp(cmd, c"apply") == 0 || strcmp(cmd, c"sql") == 0 || strcmp(cmd, c"status") == 0
	if (known == 0 || (sqlite == 0) == (postgres == 0)):
		orm_cli_usage()
		return 2
	char* error = 0
	orm_db* db = 0
	if (sqlite != 0): db = orm_migrate_open_sqlite(sqlite, &error)
	else: db = orm_migrate_open_postgres(postgres, &error)
	if (db == 0):
		print2(c"orm: cannot connect: ")
		println2(error)
		return 1
	int status = 0
	if (strcmp(cmd, c"apply") == 0):
		# --upto <name>: apply the pending migrations up to and including name.
		char* upto = args_value(c"upto")
		list[orm_migration*] run = ms
		if (upto != 0): run = orm_migrate_upto(ms, upto)
		int n = -1
		if (run == 0):
			char* why = orm_mx_cat(c"no migration named ", upto, 0, 0)
			orm_db_set_error(db, why)
			free(why)
		else: n = orm_migrate_apply(db, run, force)
		if (upto != 0 && run != 0): run.free()
		if (n < 0):
			print2(c"orm: ")
			println2(orm_db_error(db))
			status = 1
		else:
			print(c"applied ")
			print(itoa(n))
			println(c" migrations")
	else if (strcmp(cmd, c"sql") == 0):
		char* text = orm_migrate_sql(db, ms, name)
		if (text == 0):
			print2(c"orm: ")
			println2(orm_db_error(db))
			status = 1
		else:
			print(text)
			free(text)
	else:
		char* st = orm_migrate_status(db, ms)
		print(st)
		free(st)
	sql_close(db.conn)
	return status
