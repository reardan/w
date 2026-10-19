# wbuild: target=orm_generated tag=generated dep=wv2 input=libs/standard/orm/schema/ input=tools/orm_gen.w input=tests/orm/fixtures/library.orm input=tests/orm/fixtures/shop.orm output=tests/orm/generated/library_orm.w output=tests/orm/generated/library_orm_api.w output=tests/orm/generated/library_schema.json output=tests/orm/generated/shop_orm.w output=tests/orm/generated/shop_orm_api.w output=tests/orm/generated/shop_schema.json
# wbuild: step="bin/wv2 tools/orm_gen.w -o bin/orm_gen_generated"
# wbuild: step="bin/orm_gen_generated tests/orm/fixtures/library.orm -o tests/orm/generated/"
# wbuild: step="bin/orm_gen_generated tests/orm/fixtures/shop.orm -o tests/orm/generated/"
# wbuild: target=orm_gen_test tag=tests_x64 dep=wv2 dep=orm_gen
# wbuild: step="bin/orm_gen tests/orm/fixtures/library.orm -o bin/orm_gen_test/library --module tests.orm.generated.library_orm"
# wbuild: step="cmp bin/orm_gen_test/library_orm.w tests/orm/generated/library_orm.w"
# wbuild: step="cmp bin/orm_gen_test/library_orm_api.w tests/orm/fixtures/library_orm_api.golden"
# wbuild: step="cmp bin/orm_gen_test/library_schema.json tests/orm/fixtures/library_schema.json"
# wbuild: step="bin/wv2 x64 tests/orm/orm_gen_dump_fixture.w -o bin/orm_gen_dump_fixture"
# wbuild: step="bin/wv2 x64 tests/orm/orm_gen_dump_generated.w -o bin/orm_gen_dump_generated"
# wbuild: step="bin/orm_gen_dump_fixture" stdout_file=bin/orm_gen_dump_fixture.out
# wbuild: step="bin/orm_gen_dump_generated" stdout_file=bin/orm_gen_dump_generated.out
# wbuild: step="cmp bin/orm_gen_dump_fixture.out bin/orm_gen_dump_generated.out"
# wbuild: step="bin/orm_gen tests/orm/fixtures/invalid.orm -o bin/orm_gen_test/" expect_fail expect_stderr="tests/orm/fixtures/invalid.orm:6: unknown type 'strng'" expect_stderr="tests/orm/fixtures/invalid.orm:7: unknown FK target 'Nobody'"
# wbuild: binary=orm_gen
/*
orm_gen: generate the w-orm data and API modules from an .orm schema
(issue #754, unit U1.1; docs/projects/orm.md "Generated code shape",
docs/projects/orm/u1_1.md).

	bin/orm_gen app/models.orm -o out/            # out/<app>_orm.w, out/<app>_orm_api.w, out/<app>_schema.json
	bin/orm_gen app/models.orm -o out/blog        # out/blog_orm.w, out/blog_orm_api.w, out/blog_schema.json
	bin/orm_gen app/models.orm                    # data module on stdout

The API module imports the data module by the dotted form of its path
(out/blog_orm.w -> out.blog_orm), so run orm_gen from the directory W
imports resolve from, or pass --module <dotted.name>. Errors go to stderr
as "file:line: message" and exit 1.

The orm_generated target above (tag=generated, issue #323: generated
files are not committed) writes tests/orm/generated/ before any other
target runs. orm_gen_test regenerates library.orm through bin/orm_gen,
compares the API module and snapshot with committed goldens, and compares
the descriptor dump (libs/standard/orm/schema/dump.w) of the generated
data module with that of the hand-written tests/orm/fixtures/library_orm.w.
*/
import lib.lib
import lib.args
import lib.file
import lib.path
import lib.stat
import lib.str
import libs.standard.orm.schema.schema
import libs.standard.orm.schema.codegen


void orm_gen_usage():
	println2(c"usage: orm_gen schema.orm [-o <dir>/|<prefix>] [--module <dotted.module>]")


int orm_gen_is_dir(char* path):
	int n = strlen(path)
	if (n > 0 && path[n - 1] == '/'): return 1
	file_stat st
	if (file_stat_path(path, &st) != 0): return 0
	return file_is_dir(&st)


# mkdir -p for the directory part of path.
void orm_gen_mkdirs(char* dir):
	if (dir == 0 || dir[0] == 0 || strcmp(dir, c".") == 0 || strcmp(dir, c"/") == 0): return
	if (path_exists(dir)): return
	orm_gen_mkdirs(path_dirname(dir))
	mkdir(dir, 493)


# "tests/orm/generated/library_orm" -> "tests.orm.generated.library_orm"
char* orm_gen_module_name(char* base):
	if (path_is_absolute(base)): base = path_basename(base)
	if (starts_with_at(base, c"./", 0)): base = substring(base, 2, strlen(base))
	return replace(base, c"/", c".")


int orm_gen_write(char* path, char* text):
	if (file_write_text(path, text) == 0):
		print2(c"orm_gen: could not write ")
		println2(path)
		return 0
	return 1


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() != 1):
		orm_gen_usage()
		return 1
	char* input_path = args_positional(0)
	char* out = args_value(c"o")
	char* input = file_read_text(input_path)
	if (input == 0):
		print2(c"orm_gen: could not read ")
		println2(input_path)
		return 1
	orm_schema* s = orm_schema_parse(input, input_path)
	if (s.errors.length > 0):
		for char* e in s.errors: println2(e)
		return 1
	char* data = orm_codegen_data(s)
	if (out == 0):
		print(data)
		return 0
	char* base = out
	if (orm_gen_is_dir(out)):
		char* dir = out
		int n = strlen(dir)
		if (n > 0 && dir[n - 1] == '/'): dir = str_copy_range(dir, 0, n - 1)
		orm_gen_mkdirs(dir)
		base = orm_schema_concat3(dir, c"/", s.app)
	else:
		orm_gen_mkdirs(path_dirname(out))
	char* data_base = orm_schema_concat3(base, c"_orm", c"")
	char* module = args_value(c"module")
	if (module == 0): module = orm_gen_module_name(data_base)
	if (!orm_gen_write(orm_schema_concat3(data_base, c".w", c""), data)): return 1
	if (!orm_gen_write(orm_schema_concat3(data_base, c"_api.w", c""), orm_codegen_api(s, module))): return 1
	char* json = orm_schema_concat3(orm_codegen_schema_json(s), c"\n", c"")
	if (!orm_gen_write(orm_schema_concat3(base, c"_schema.json", c""), json)): return 1
	return 0
