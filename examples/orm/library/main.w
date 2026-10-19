# wbuild: binary=orm_library arch=x64
# wbuild: target=orm_example_cli_test tag=tests_x64 dep=orm_library
# wbuild: step="rm -f bin/orm_example_cli.db"
# wbuild: step="bin/orm_library migrate lint --sqlite" expect_stdout="lint: 7 migrations, 0 errors, 0 warnings"
# wbuild: step="bin/orm_library migrate lint --postgres" expect_stdout="lint: 7 migrations, 0 errors, 0 warnings"
# wbuild: step="bin/orm_library migrate status --sqlite bin/orm_example_cli.db" expect_stdout="[ ] library.0002_expand_library_book_pages (pending)"
# wbuild: step="bin/orm_library migrate sql --sqlite bin/orm_example_cli.db 0001_initial" expect_stdout="CREATE TABLE"
# wbuild: step="bin/orm_library migrate apply --sqlite bin/orm_example_cli.db" expect_fail expect_stderr="to be applied by an earlier deploy"
# wbuild: step="bin/orm_library migrate apply --sqlite bin/orm_example_cli.db --force" expect_stdout="applied 7 migrations"
# wbuild: step="bin/orm_library migrate apply --sqlite bin/orm_example_cli.db" expect_stdout="applied 0 migrations"
# wbuild: step="bin/orm_library createsuperuser --sqlite bin/orm_example_cli.db admin admin@example.com pw" expect_stdout="created superuser admin"
# wbuild: step="bin/orm_library createsuperuser --sqlite bin/orm_example_cli.db admin admin@example.com pw" expect_fail
# wbuild: step="bin/orm_library serve" expect_fail expect_stderr="usage:"
/*
orm_library: the example library app's binary (issue #754, unit U5.2;
examples/orm/library/README.md).

	bin/orm_library migrate apply|sql|status|lint (--sqlite <path> | --postgres <conninfo>) [--force] [<name>]
	bin/orm_library createsuperuser (--sqlite <path> | --postgres <conninfo>) <username> <email> <password>
	bin/orm_library serve (--sqlite <path> | --postgres <conninfo>) [--port 8000] [--host 127.0.0.1]

migrate is U2.4's command line over this app's migrations
(migrations.w). The applier refuses a contract migration in the same run
as the expand step it requires, so a fresh database that takes every
migration at once needs `migrate apply --force` (the list lints clean
and has no unsafe ops, so force only waives that rule). serve answers the REST API
(app.w) until killed; the session cookie is sent without Secure, since
this server speaks plain HTTP.
*/
import examples.orm.library.app
import examples.orm.library.migrations
import libs.standard.orm.migrate.cli
import libs.standard.orm.auth.perms


void library_usage():
	println2(c"usage: orm_library migrate ... | createsuperuser (--sqlite <path> | --postgres <conninfo>) <username> <email> <password> | serve (--sqlite <path> | --postgres <conninfo>) [--port N] [--host IP]")


orm_db* library_open():
	char* sqlite = args_value(c"sqlite")
	char* postgres = args_value(c"postgres")
	if ((sqlite == 0) == (postgres == 0)): return 0
	orm_db* db = 0
	if (sqlite != 0): db = orm_open_sqlite(sqlite)
	else: db = orm_open_postgres(postgres)
	if (orm_is_open(db) == 0):
		print2(c"orm_library: cannot connect: ")
		println2(orm_db_error(db))
		return 0
	return db


int library_createsuperuser(orm_db* db):
	if (args_positional_count() != 4):
		library_usage()
		return 2
	library_app_register()
	User* u = create_superuser(db, args_positional(1), args_positional(2), args_positional(3))
	if (u == 0):
		print2(c"orm_library: ")
		println2(orm_db_error(db))
		return 1
	print(c"created superuser ")
	println(u.username)
	User_free(u)
	return 0


ServerResponse* library_unrouted(ServerRequest* req, void* context):
	return server_response_new(404)


int library_serve(orm_db* db):
	char* host = args_value(c"host")
	if (host == 0): host = c"127.0.0.1"
	int port = 8000
	if (args_value(c"port") != 0): port = atoi(args_value(c"port"))
	library_app* app = library_app_new(db)
	if (app == 0): return 1
	session_settings().secure = 0
	ServerContext* s = server_context_new(host, port, library_unrouted, 0)
	if (server_context_bind(s) == 0):
		println2(c"orm_library: cannot bind")
		return 1
	library_app_mount(app, s)
	print(c"serving the library API on http://")
	print(host)
	print(c":")
	println(itoa(server_context_port(s)))
	server_context_accept_loop(s, 0)
	return 0


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() >= 1 && strcmp(args_positional(0), c"migrate") == 0):
		return orm_cli_main(argc, argv, library_app_migrations())
	if (args_positional_count() < 1):
		library_usage()
		return 2
	char* cmd = args_positional(0)
	if (strcmp(cmd, c"createsuperuser") != 0 && strcmp(cmd, c"serve") != 0):
		library_usage()
		return 2
	orm_db* db = library_open()
	if (db == 0):
		library_usage()
		return 2
	if (strcmp(cmd, c"serve") == 0): return library_serve(db)
	return library_createsuperuser(db)
