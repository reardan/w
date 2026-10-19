# wbuild: binary=orm arch=x64
# wbuild: target=orm_cli_test tag=tests_x64 dep=orm
# wbuild: step="rm -f bin/orm_cli_test.db"
# wbuild: step="bin/orm migrate lint --sqlite" expect_stdout="lint: 3 migrations, 0 errors"
# wbuild: step="bin/orm migrate lint --postgres" expect_fail expect_stdout="W-ORM-M005"
# wbuild: step="bin/orm migrate status --sqlite bin/orm_cli_test.db" expect_stdout="[ ] demo.0001_initial (pending)"
# wbuild: step="bin/orm migrate sql --sqlite bin/orm_cli_test.db 0002_expand_demo_item_note" expect_stdout="ADD COLUMN"
# wbuild: step="bin/orm migrate apply --sqlite bin/orm_cli_test.db" expect_stdout="applied 3 migrations"
# wbuild: step="bin/orm migrate apply --sqlite bin/orm_cli_test.db" expect_stdout="applied 0 migrations"
# wbuild: step="bin/orm migrate status --sqlite bin/orm_cli_test.db" expect_stdout="[X] demo.0003_demo_rows (applied"
# wbuild: step="bin/orm migrate apply" expect_fail expect_stderr="usage:"
/*
orm: the w-orm migration command line (issue #754, unit U2.4;
docs/projects/orm/u2_4.md).

	bin/orm migrate apply|sql|status|lint --sqlite <path> | --postgres <conninfo> [--force] [<name>]

Applications link the same command line into their own binary with their
own migration list (libs/standard/orm/migrate/cli.w, orm_cli_main). This
binary runs it on three built-in demo migrations, which is what its test
target drives.
*/
import libs.standard.orm.migrate.cli


list[orm_migration*] orm_demo_migrations():
	list[orm_migration*] ms = new list[orm_migration*]
	orm_migration* m1 = orm_migration_new(c"demo", c"0001_initial")
	orm_op* create = orm_op_new(ORM_OP_CREATE_TABLE, ORM_PHASE_EXPAND, c"demo_item")
	create.model_json = c"{\"name\":\"Item\",\"table\":\"demo_item\",\"fields\":[{\"name\":\"id\",\"column\":\"id\",\"kind\":1,\"pk\":true,\"auto\":true},{\"name\":\"name\",\"column\":\"name\",\"kind\":4,\"max_length\":100,\"indexed\":true},{\"name\":\"qty\",\"column\":\"qty\",\"kind\":1,\"null\":true,\"default\":\"0\"}],\"indexes\":[],\"checks\":[{\"name\":\"demo_item_qty_check\",\"sql\":\"qty >= 0\"}],\"unique_together\":[]}"
	orm_migration_add(m1, create)
	ms.push(m1)
	orm_migration* m2 = orm_migration_new(c"demo", c"0002_expand_demo_item_note")
	m2.dependencies.push(c"demo.0001_initial")
	orm_op* add = orm_op_new(ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"demo_item")
	add.column = c"note"
	add.field_json = c"{\"name\":\"note\",\"column\":\"note\",\"kind\":4,\"null\":true}"
	orm_migration_add(m2, add)
	orm_op* ix = orm_op_new(ORM_OP_ADD_INDEX, ORM_PHASE_EXPAND, c"demo_item")
	ix.name = c"demo_item_note_idx"
	ix.field_json = c"{\"columns\":[\"note\"]}"
	orm_migration_add(m2, ix)
	ms.push(m2)
	orm_migration* m3 = orm_migration_new(c"demo", c"0003_demo_rows")
	m3.dependencies.push(c"demo.0002_expand_demo_item_note")
	orm_op* raw = orm_op_new(ORM_OP_RAW_SQL, ORM_PHASE_MIGRATE, c"demo_item")
	raw.sql = c"INSERT INTO demo_item (name, qty) VALUES ('first', 1); INSERT INTO demo_item (name, note) VALUES ('second', 'n')"
	raw.reverse_sql = c"DELETE FROM demo_item"
	orm_migration_add(m3, raw)
	ms.push(m3)
	return ms


int main(int argc, int argv):
	return orm_cli_main(argc, argv, orm_demo_migrations())
