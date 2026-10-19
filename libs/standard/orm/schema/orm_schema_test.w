# wbuild: x64
# U1.1: the .orm parser, its error messages, dependency ordering and the
# generated text (docs/projects/orm/u1_1.md). Descriptor equality with the
# hand-written fixture is checked by orm_gen_test (tools/orm_gen.w).
import lib.assert
import lib.file
import lib.str
import libs.standard.orm.schema.schema
import libs.standard.orm.schema.codegen


orm_schema* parse(char* text):
	return orm_schema_parse(text, c"t.orm")


# Parses text and asserts that its first error is exactly want.
void expect_error(char* text, char* want):
	orm_schema* s = parse(text)
	if (s.errors.length == 0):
		print(c"no error, wanted: ")
		println(want)
		assert1(0)
		return
	assert_strings_equal(want, s.errors[0])


void test_library():
	char* text = file_read_text(c"tests/orm/fixtures/library.orm")
	assert1(text != 0)
	orm_schema* s = orm_schema_parse(text, c"tests/orm/fixtures/library.orm")
	assert_equal(0, s.errors.length)
	assert_strings_equal(c"library", s.app)
	assert_equal(3, s.ordered.length)
	assert_strings_equal(c"Author", s.ordered[0].name)
	assert_strings_equal(c"Tag", s.ordered[1].name)
	assert_strings_equal(c"Book", s.ordered[2].name)
	orm_schema_model* book = orm_schema_find_model(s, c"Book")
	assert_strings_equal(c"library_book", book.table)
	assert_equal(1, book.history)
	assert_equal(8, book.fields.length)
	orm_schema_field* id = book.fields[0]
	assert_strings_equal(c"id", id.name)
	assert_equal(ORM_SCHEMA_F_PK | ORM_SCHEMA_F_AUTO, id.flags)
	orm_schema_field* author = orm_schema_find_field(book, c"author")
	assert_equal(ORM_SCHEMA_FK, author.kind)
	assert_equal(ORM_SCHEMA_CASCADE, author.on_delete)
	assert_strings_equal(c"author_id", orm_schema_column(author))
	orm_schema_field* status = orm_schema_find_field(book, c"status")
	assert_equal(ORM_SCHEMA_ENUM, status.kind)
	assert_equal(5, status.max_length)
	assert_strings_equal(c"'draft'", status.default_sql)
	assert_strings_equal(c"price >= 0", book.checks[0].sql)
	assert_strings_equal(c"library_book_price_nonnegative", book.checks[0].name)
	orm_schema_model* a = orm_schema_find_model(s, c"Author")
	assert_equal(1, a.reverse.length)
	assert_strings_equal(c"books", a.reverse[0].name)
	assert_strings_equal(c"library_author_created_idx", a.indexes[0].name)
	# The committed snapshot golden is exactly what codegen produces.
	char* golden = file_read_text(c"tests/orm/fixtures/library_schema.json")
	assert_strings_equal(golden, orm_schema_concat3(orm_codegen_schema_json(s), c"\n", c""))
	char* api = file_read_text(c"tests/orm/fixtures/library_orm_api.golden")
	assert_strings_equal(api, orm_codegen_api(s, c"tests.orm.generated.library_orm"))


void test_syntax():
	orm_schema* s = parse(c"# leading comment\napp demo   # trailing\n\nmodel Node:\n\tfk parent -> Node null on_delete=set_null related_name=children\n\tstring label default=\"two words\" max_length=20\n\tm2m peers -> Node\n\tindex label\n\tunique_together parent label\n\tcheck length(label) > 0\n\ttable=nodes\n")
	assert_equal(0, s.errors.length)
	orm_schema_model* n = s.models[0]
	assert_strings_equal(c"nodes", n.table)
	orm_schema_field* label = orm_schema_find_field(n, c"label")
	assert_strings_equal(c"'two words'", label.default_sql)
	assert_strings_equal(c"nodes_label_idx", n.indexes[0].name)
	assert_strings_equal(c"nodes_check1", n.checks[0].name)
	assert_strings_equal(c"length(label) > 0", n.checks[0].sql)
	assert_equal(1, n.reverse.length)
	char* data = orm_codegen_data(s)
	# Self FK: the slot is void* and the accessor casts.
	assert_contains(data, c"\tint parent_id\n\tvoid* parent\n\tint parent__isnull\n")
	assert_contains(data, c"Node* Node_parent(Node* row): return cast(Node*, row.parent)\n")
	assert_contains(data, c"f.through_from = c\"from_node_id\"")
	assert_contains(data, c"f.through_to = c\"to_node_id\"")
	assert_contains(data, c"ut.push(c\"parent_id\")")
	assert_contains(data, c"char* demo_schema_json():")
	char* json = orm_codegen_schema_json(s)
	assert_contains(json, c"\"unique_together\":[{\"fields\":[\"parent\",\"label\"],\"columns\":[\"parent_id\",\"label\"]}]")
	assert_contains(json, c"\"on_delete\":\"set_null\"")


void test_cycle_order():
	# A <-> B cycle, C declared first but depends on D.
	orm_schema* s = parse(c"app x\nmodel C:\n\tfk d -> D\nmodel A:\n\tfk b -> B\nmodel B:\n\tfk a -> A\nmodel D:\n\tint n\n")
	assert_equal(0, s.errors.length)
	assert_strings_equal(c"D", s.ordered[0].name)
	assert_strings_equal(c"C", s.ordered[1].name)
	assert_strings_equal(c"A", s.ordered[2].name)
	assert_strings_equal(c"B", s.ordered[3].name)
	char* data = orm_codegen_data(s)
	assert_contains(data, c"struct A:\n\tint id\n\tint b_id\n\tvoid* b\n")
	assert_contains(data, c"struct B:\n\tint id\n\tint a_id\n\tA* a\n")
	assert_contains(data, c"struct C:\n\tint id\n\tint d_id\n\tD* d\n")


void test_errors():
	expect_error(c"app x\nmodel A:\n\tstrng name\n", c"t.orm:3: unknown type 'strng'")
	expect_error(c"app x\nmodel A:\n\tfk b -> B\n", c"t.orm:3: unknown FK target 'B'")
	expect_error(c"app x\nmodel A:\n\tm2m b -> B\n", c"t.orm:3: unknown M2M target 'B'")
	expect_error(c"app x\nmodel A:\n\tint n\n\tstring n\n", c"t.orm:4: duplicate field 'n'")
	expect_error(c"app x\nmodel B:\n\tint n\nmodel A:\n\tint b_id\n\tfk b -> B\n", c"t.orm:6: duplicate field 'b'")
	expect_error(c"app x\nmodel A:\n\tstring s max_length=abc\n", c"t.orm:3: bad option 'max_length=abc'")
	expect_error(c"app x\nmodel A:\n\tint n frobnicate\n", c"t.orm:3: bad option 'frobnicate'")
	expect_error(c"app x\nmodel A:\n\tint n max_length=3\n", c"t.orm:3: bad option 'max_length'")
	expect_error(c"app x\nmodel A:\n\tint n default=abc\n", c"t.orm:3: bad default 'abc' for an integer field")
	expect_error(c"app x\nmodel A:\n\tbool b default=maybe\n", c"t.orm:3: bad default 'maybe' for a bool field")
	expect_error(c"app x\nmodel A:\n\tdecimal d digits=2 places=4\n", c"t.orm:3: places exceeds digits on field 'd'")
	expect_error(c"app x\nmodel A:\n\tint n default=null\n", c"t.orm:3: default=null needs 'null' on field 'n'")
	expect_error(c"app x\nmodel A:\n    int n\n", c"t.orm:3: indent with tabs, not spaces")
	expect_error(c"model A:\n\tint n\n", c"t.orm:1: missing 'app <name>' line")
	expect_error(c"app x\nmodel A:\n\tint n\nmodel A:\n\tint m\n", c"t.orm:4: duplicate model 'A'")
	expect_error(c"app x\nmodel A\n", c"t.orm:2: expected 'model <Name>:'")
	expect_error(c"app x\n\tint n\n", c"t.orm:2: indented line outside a model")
	expect_error(c"app x\nwidget A:\n", c"t.orm:2: unknown declaration 'widget'")
	expect_error(c"app x\nmodel A:\n\tfk b -> A on_delete=set_null\n", c"t.orm:3: on_delete=set_null needs 'null' on field 'b'")
	expect_error(c"app x\nmodel A:\n\tfk b -> A on_delete=set_default\n", c"t.orm:3: on_delete=set_default needs a default on field 'b'")
	expect_error(c"app x\nmodel A:\n\tfk b -> A on_delete=explode\n", c"t.orm:3: bad option 'on_delete=explode'")
	expect_error(c"app x\nmodel A:\n\tenum E: a, b\n\tE e default=c\n", c"t.orm:4: default 'c' is not a value of the enum")
	expect_error(c"app x\nmodel A:\n\tenum E: a, a\n", c"t.orm:3: duplicate enum value 'a'")
	expect_error(c"app x\nmodel A:\n\tint n\n\tindex m\n", c"t.orm:4: index names unknown field m")
	expect_error(c"app x\nmodel A:\n\tm2m b -> A\n\tunique_together b n\n", c"t.orm:2: unique_together names relation without a column b")
	expect_error(c"app x\nmodel A:\n\tint n\n\tunique_together n\n", c"t.orm:4: 'unique_together' needs at least two fields")
	expect_error(c"app x\nmodel A:\n\tint kids\nmodel B:\n\tfk a -> A related_name=kids\n", c"t.orm:5: related_name 'kids' clashes with a field of the target")
	expect_error(c"app x\nmodel A:\n\tstring code pk\nmodel B:\n\tfk a -> A\n", c"t.orm:5: relation target 'A' needs an int pk")
	expect_error(c"app x\nmodel A:\n\tstring for\n", c"t.orm:3: field name 'for' is reserved")
	expect_error(c"app x\nmodel A:\n\tstring a__b\n", c"t.orm:3: field name 'a__b' may not contain '__'")
	expect_error(c"app x\nmodel A:\n\tfk save -> A\n", c"t.orm:3: relation name 'save' clashes with a generated function")
	expect_error(c"app x\nmodel A:\n\tint a pk\n\tint b pk\n", c"t.orm:2: model 'A' declares more than one pk")
	expect_error(c"app x\nmodel A:\n\tstring id\n", c"t.orm:2: model 'A' has a field 'id' but no pk")
	expect_error(c"app x\nmodel A:\n\tcheck name=only\n", c"t.orm:3: 'check' needs a SQL condition")
	expect_error(c"app x\nmodel A:\n\thistory now\n", c"t.orm:3: 'history' takes no arguments")
	expect_error(c"app x\nmodel A:\n\tfk b A\n", c"t.orm:3: expected 'fk <name> -> <Model>'")
	expect_error(c"app x\nmodel A:\n\t\tint n\n", c"t.orm:3: unexpected indentation")
	# Every error is collected, not just the first.
	orm_schema* s = parse(c"app x\nmodel A:\n\tstrng a\n\tstrng b\n")
	assert_equal(2, s.errors.length)


# H1: names the history wrappers take (U3.3) are refused for relations
# of history models, and `import` makes another file's models FK targets.
void test_history_names():
	expect_error(c"app x\nmodel A:\n\thistory\n\tfk history -> A null\n", c"t.orm:4: relation name 'history' clashes with a generated function")
	expect_error(c"app x\nmodel A:\n\tm2m as_of -> A\n\thistory\n", c"t.orm:3: relation name 'as_of' clashes with a generated function")
	expect_error(c"app x\nmodel A:\n\thistory\nmodel B:\n\tfk a -> A related_name=prune_history\n", c"t.orm:5: related_name 'prune_history' clashes with a generated function")
	expect_error(c"app x\nmodel A:\n\thistory\nmodel B:\n\tfk a -> A related_name=history_row\n", c"t.orm:5: related_name 'history_row' clashes with a generated function")
	# Without history the names are free.
	orm_schema* s = parse(c"app x\nmodel A:\n\tfk history -> A null\n")
	assert_equal(0, s.errors.length)


void test_imports():
	char* text = c"app sess\nimport libs/standard/orm/auth/auth.orm\nmodel Visit:\n\tfk user -> User on_delete=cascade\n\tfk group -> Group null on_delete=set_null\n"
	orm_schema* s = parse(text)
	assert_equal(0, s.errors.length)
	assert_equal(1, s.imports.length)
	assert_strings_equal(c"auth", s.imports[0].app)
	assert_strings_equal(c"libs.standard.orm.auth.auth_orm", s.import_modules[0])
	assert1(orm_schema_is_external(s, c"User"))
	assert1(orm_schema_is_external(s, c"Visit") == 0)
	char* data = orm_codegen_data(s)
	assert_contains(data, c"import libs.standard.orm.contract\nimport libs.standard.orm.auth.auth_orm\n")
	assert_contains(data, c"\tint user_id\n\tUser* user\n")
	assert_contains(data, c"\tGroup* group\n\tint group__isnull\n")
	assert_contains(data, c"f.rel_model = c\"User\"\n")
	assert_contains(data, c"User* Visit_user(Visit* row): return row.user\n")
	assert_contains(data, c"void sess_register():\n\tauth_register()\n\tVisit_desc()\n")
	# The import is found next to the importing file too.
	orm_schema* near = orm_schema_parse(c"app sess\nimport auth.orm\nmodel V:\n\tfk u -> User\n", c"libs/standard/orm/auth/sess.orm")
	assert_equal(0, near.errors.length)
	assert_strings_equal(c"libs.standard.orm.auth.auth_orm", near.import_modules[0])
	expect_error(c"app x\nimport nowhere/none.orm\n", c"t.orm:2: cannot read import 'nowhere/none.orm'")
	expect_error(c"app x\nimport libs/standard/orm/auth/auth_orm.w\n", c"t.orm:2: import 'libs/standard/orm/auth/auth_orm.w' is not an .orm file")
	expect_error(c"app x\nimport\n", c"t.orm:2: expected 'import <path/to/file.orm>'")
	expect_error(c"app auth\nimport libs/standard/orm/auth/auth.orm\n", c"t.orm:2: import 'libs/standard/orm/auth/auth.orm' declares this file's own app")
	expect_error(c"app x\nimport libs/standard/orm/auth/auth.orm\nmodel V:\n\tm2m users -> User\n", c"t.orm:4: M2M target 'User' is in an imported file (only FKs may cross files)")
	expect_error(c"app x\nimport libs/standard/orm/auth/auth.orm\nmodel V:\n\tfk u -> User related_name=visits\n", c"t.orm:4: related_name 'visits' needs a target in this file (the imported module is generated on its own)")
	expect_error(c"app x\nimport libs/standard/orm/auth/auth.orm\nmodel User:\n\tint n\n", c"t.orm:3: model 'User' clashes with a model of an imported file")


int main():
	test_library()
	test_syntax()
	test_cycle_order()
	test_errors()
	test_history_names()
	test_imports()
	println(c"orm_schema_test: ok")
	return 0
