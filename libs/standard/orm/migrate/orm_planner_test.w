# wbuild: arch_only=x64
# U2.3: the safe-pattern planner expands each change of plan section 5.2
# into the exact expand / migrate / contract sequence
# (docs/projects/orm/u2_3.md).
import libs.standard.orm.migrate.planner
import lib.assert


# Plans one change as migrations 0007.. after "0006_prev", checks that the
# plan itself lints clean, and returns the description.
char* plan_one(orm_change* c, int dialect):
	orm_planner* p = orm_planner_new(c"library", dialect, 7, c"0006_prev")
	list[orm_change*] cs = new list[orm_change*]
	cs.push(c)
	list[orm_migration*] plan = orm_plan(p, cs)
	asserts(c"plan returned 0", plan != 0)
	list[orm_lint_finding*] findings = orm_lint_plan(plan, dialect)
	if (c.force == 0):
		char* text = orm_lint_format(findings)
		assert_strings_equal(c"", text)
		free(text)
	orm_lint_free(findings)
	char* out = strclone(orm_plan_describe(plan))
	orm_planner_free(p, plan)
	cs.free()
	return out


char* BOOK_ISBN():
	return c"{\"name\": \"isbn\", \"column\": \"isbn\", \"kind\": \"text\", \"null\": false}"


void test_add_column_not_null_postgres():
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", c"isbn")
	c.field_json = BOOK_ISBN()
	assert_strings_equal(c"0007_expand_book_isbn (atomic)\n  expand ADD_COLUMN book.isbn null\n0008_migrate_book_isbn (non-atomic)\n  migrate BACKFILL book.isbn name=book_isbn_backfill batch=1000 non_atomic\n  migrate ADD_CONSTRAINT book.isbn name=book_isbn_not_null sql=\"CHECK (isbn IS NOT NULL)\"\n0009_contract_book_isbn (atomic) requires 0007_expand_book_isbn\n  contract VALIDATE_CONSTRAINT book.isbn name=book_isbn_not_null\n  contract ALTER_NULL book.isbn not-null\n  contract DROP_CONSTRAINT book.isbn name=book_isbn_not_null\n", plan_one(c, ORM_DIALECT_POSTGRES))


void test_add_column_not_null_sqlite():
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", c"isbn")
	c.field_json = BOOK_ISBN()
	c.backfill = c"isbn_from_title"
	c.batch_size = 500
	assert_strings_equal(c"0007_expand_book_isbn (atomic)\n  expand ADD_COLUMN book.isbn null\n0008_migrate_book_isbn (non-atomic)\n  migrate BACKFILL book.isbn name=isbn_from_title batch=500 non_atomic\n0009_contract_book_isbn (atomic) requires 0007_expand_book_isbn\n  contract ALTER_NULL book.isbn not-null\n", plan_one(c, ORM_DIALECT_SQLITE))


void test_add_column_single_step():
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", c"isbn")
	c.field_json = BOOK_ISBN()
	c.nullable = 1
	assert_strings_equal(c"0007_expand_book_isbn (atomic)\n  expand ADD_COLUMN book.isbn null\n", plan_one(c, ORM_DIALECT_POSTGRES))
	orm_change* d = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", c"pages")
	d.field_json = c"{\"name\": \"pages\", \"null\": false, \"default\": \"0\"}"
	d.has_default = 1
	assert_strings_equal(c"0007_expand_book_pages (atomic)\n  expand ADD_COLUMN book.pages not-null\n", plan_one(d, ORM_DIALECT_POSTGRES))


void test_add_column_field_json():
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", c"isbn")
	c.field_json = BOOK_ISBN()
	orm_planner* p = orm_planner_new(c"library", ORM_DIALECT_POSTGRES, 7, c"0006_prev")
	list[orm_change*] cs = new list[orm_change*]
	cs.push(c)
	list[orm_migration*] plan = orm_plan(p, cs)
	orm_op* add = plan[0].ops[0]
	assert_strings_equal(c"{\"name\": \"isbn\", \"column\": \"isbn\", \"kind\": \"text\", \"null\": true}", add.field_json)
	orm_op* tighten = plan[2].ops[1]
	assert_strings_equal(c"{\"name\": \"isbn\", \"column\": \"isbn\", \"kind\": \"text\", \"null\": false}", tighten.field_json)
	assert_equal(1, plan[0].dependencies.length)
	assert_strings_equal(c"library.0006_prev", plan[0].dependencies[0])
	assert_strings_equal(c"library.0007_expand_book_isbn", plan[1].dependencies[0])
	assert_strings_equal(c"library.0008_migrate_book_isbn", plan[2].dependencies[0])
	assert1(plan[1].requires_applied == 0)
	assert_equal(10, p.next_number)
	orm_planner_free(p, plan)
	cs.free()


void test_drop_column():
	orm_change* c = orm_change_new(ORM_CHANGE_DROP_COLUMN, c"book", c"isbn")
	c.field_json = BOOK_ISBN()
	assert_strings_equal(c"0007_expand_book_isbn (atomic)\n  expand ALTER_NULL book.isbn null deprecated\n0008_contract_book_isbn (atomic) requires 0007_expand_book_isbn\n  contract DROP_COLUMN book.isbn\n", plan_one(c, ORM_DIALECT_POSTGRES))


void test_rename_column():
	orm_change* c = orm_change_new(ORM_CHANGE_RENAME_COLUMN, c"book", c"title")
	c.new_name = c"name"
	c.field_json = c"{\"name\": \"title\", \"column\": \"title\"}"
	assert_strings_equal(c"0007_expand_book_title (atomic)\n  expand ADD_COLUMN book.name null\n  expand SYNC_TRIGGER book.name <- book.title\n0008_migrate_book_title (non-atomic)\n  migrate COPY_COLUMN book.name <- book.title batch=1000 non_atomic\n  migrate ADD_CONSTRAINT book.name name=book_name_not_null sql=\"CHECK (name IS NOT NULL)\"\n0009_contract_book_title (atomic) requires 0007_expand_book_title\n  contract VALIDATE_CONSTRAINT book.name name=book_name_not_null\n  contract ALTER_NULL book.name not-null\n  contract DROP_CONSTRAINT book.name name=book_name_not_null\n  contract ALTER_NULL book.title null deprecated\n  contract DROP_SYNC_TRIGGER book.name <- book.title\n0010_contract_book_title (atomic) requires 0007_expand_book_title\n  contract DROP_COLUMN book.title\n", plan_one(c, ORM_DIALECT_POSTGRES))
	# The new column's snapshot points at the new name.
	orm_planner* p = orm_planner_new(c"library", ORM_DIALECT_SQLITE, 1, 0)
	list[orm_change*] cs = new list[orm_change*]
	cs.push(c)
	list[orm_migration*] plan = orm_plan(p, cs)
	orm_op* add = plan[0].ops[0]
	assert_strings_equal(c"{\"null\": true, \"name\": \"title\", \"column\": \"name\"}", add.field_json)
	assert_equal(0, plan[0].dependencies.length)
	assert_strings_equal(c"0001_expand_book_title", plan[0].name)
	orm_planner_free(p, plan)
	cs.free()


void test_alter_type():
	orm_change* c = orm_change_new(ORM_CHANGE_ALTER_TYPE, c"book", c"price")
	c.field_json = c"{\"name\": \"price\", \"kind\": \"decimal\", \"digits\": 12}"
	c.nullable = 1
	assert_strings_equal(c"0007_expand_book_price (atomic)\n  expand ADD_COLUMN book.price_new null\n  expand SYNC_TRIGGER book.price_new <- book.price\n0008_migrate_book_price (non-atomic)\n  migrate COPY_COLUMN book.price_new <- book.price batch=1000 non_atomic\n0009_contract_book_price (atomic) requires 0007_expand_book_price\n  contract ALTER_NULL book.price null deprecated\n  contract DROP_SYNC_TRIGGER book.price_new <- book.price\n0010_contract_book_price (atomic) requires 0007_expand_book_price\n  contract DROP_COLUMN book.price\n", plan_one(c, ORM_DIALECT_POSTGRES))
	c.nullable = 0
	c.new_name = c"price_cents"
	assert_strings_equal(c"0007_expand_book_price (atomic)\n  expand ADD_COLUMN book.price_cents null\n  expand SYNC_TRIGGER book.price_cents <- book.price\n0008_migrate_book_price (non-atomic)\n  migrate COPY_COLUMN book.price_cents <- book.price batch=1000 non_atomic\n0009_contract_book_price (atomic) requires 0007_expand_book_price\n  contract ALTER_NULL book.price_cents not-null\n  contract ALTER_NULL book.price null deprecated\n  contract DROP_SYNC_TRIGGER book.price_cents <- book.price\n0010_contract_book_price (atomic) requires 0007_expand_book_price\n  contract DROP_COLUMN book.price\n", plan_one(c, ORM_DIALECT_SQLITE))


void test_rename_table():
	orm_change* c = orm_change_new(ORM_CHANGE_RENAME_TABLE, c"book", 0)
	c.new_name = c"volume"
	c.model_json = c"{\"name\": \"Book\", \"table\": \"volume\"}"
	assert_strings_equal(c"0007_expand_book_to_volume (atomic)\n  expand CREATE_TABLE volume\n  expand SYNC_TRIGGER volume <- book\n0008_migrate_book_to_volume (non-atomic)\n  migrate COPY_TABLE volume <- book batch=1000 non_atomic\n0009_contract_book_to_volume (atomic) requires 0007_expand_book_to_volume\n  contract DROP_SYNC_TRIGGER volume <- book\n0010_contract_book_to_volume (atomic) requires 0007_expand_book_to_volume\n  contract DROP_TABLE book\n", plan_one(c, ORM_DIALECT_POSTGRES))


void test_rebuild_table():
	orm_change* c = orm_change_new(ORM_CHANGE_REBUILD_TABLE, c"book", 0)
	c.model_json = c"{\"name\": \"Book\", \"table\": \"book\"}"
	assert_strings_equal(c"0007_expand_book (atomic)\n  expand CREATE_TABLE book__new\n  expand SYNC_TRIGGER book__new <- book\n0008_migrate_book (non-atomic)\n  migrate COPY_TABLE book__new <- book batch=1000 non_atomic\n0009_migrate_book (atomic)\n  migrate SWAP_TABLES book__new <- book\n  migrate DROP_SYNC_TRIGGER book__new <- book\n0010_contract_book (atomic) requires 0007_expand_book\n  contract DROP_TABLE book__new\n", plan_one(c, ORM_DIALECT_SQLITE))


void test_add_index():
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_INDEX, c"book", c"title")
	assert_strings_equal(c"0007_expand_book_title (non-atomic)\n  expand ADD_INDEX book.title name=book_title_idx non_atomic\n", plan_one(c, ORM_DIALECT_POSTGRES))
	c.name = c"book_by_title"
	assert_strings_equal(c"0007_expand_book_title (atomic)\n  expand ADD_INDEX book.title name=book_by_title\n", plan_one(c, ORM_DIALECT_SQLITE))
	orm_planner* p = orm_planner_new(c"library", ORM_DIALECT_POSTGRES, 1, 0)
	list[orm_change*] cs = new list[orm_change*]
	cs.push(c)
	list[orm_migration*] plan = orm_plan(p, cs)
	assert_strings_equal(c"{\"columns\": [\"title\"]}", plan[0].ops[0].field_json)
	orm_planner_free(p, plan)
	cs.free()


void test_add_fk_and_check():
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_FK, c"book", c"author_id")
	c.sql = c"FOREIGN KEY (author_id) REFERENCES author (id)"
	assert_strings_equal(c"0007_expand_book_author_id (atomic)\n  expand ADD_CONSTRAINT book.author_id name=book_author_id_fk sql=\"FOREIGN KEY (author_id) REFERENCES author (id)\"\n0008_migrate_book_author_id (atomic)\n  migrate VALIDATE_CONSTRAINT book.author_id name=book_author_id_fk\n", plan_one(c, ORM_DIALECT_POSTGRES))
	orm_change* k = orm_change_new(ORM_CHANGE_ADD_CHECK, c"book", c"price")
	k.sql = c"CHECK (price >= 0)"
	assert_strings_equal(c"0007_expand_book_price (atomic)\n  expand ADD_CONSTRAINT book.price name=book_price_check sql=\"CHECK (price >= 0)\"\n0008_migrate_book_price (atomic)\n  migrate VALIDATE_CONSTRAINT book.price name=book_price_check\n", plan_one(k, ORM_DIALECT_POSTGRES))
	assert_strings_equal(c"0007_expand_book_price (atomic)\n  expand ADD_CONSTRAINT book.price name=book_price_check sql=\"CHECK (price >= 0)\"\n", plan_one(k, ORM_DIALECT_SQLITE))


void test_add_unique():
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_UNIQUE, c"book", c"isbn")
	assert_strings_equal(c"0007_expand_book_isbn (non-atomic)\n  expand ADD_INDEX book.isbn name=book_isbn_uniq_idx unique non_atomic\n0008_migrate_book_isbn (atomic)\n  migrate ADD_CONSTRAINT book.isbn name=book_isbn_uniq sql=\"UNIQUE USING INDEX book_isbn_uniq_idx\"\n", plan_one(c, ORM_DIALECT_POSTGRES))
	assert_strings_equal(c"0007_expand_book_isbn (atomic)\n  expand ADD_INDEX book.isbn name=book_isbn_uniq unique\n", plan_one(c, ORM_DIALECT_SQLITE))


void test_alter_null():
	orm_change* c = orm_change_new(ORM_CHANGE_ALTER_NULL, c"book", c"isbn")
	c.field_json = BOOK_ISBN()
	assert_strings_equal(c"0007_migrate_book_isbn (non-atomic)\n  migrate BACKFILL book.isbn name=book_isbn_backfill batch=1000 non_atomic\n  migrate ADD_CONSTRAINT book.isbn name=book_isbn_not_null sql=\"CHECK (isbn IS NOT NULL)\"\n0008_contract_book_isbn (atomic) requires 0007_migrate_book_isbn\n  contract VALIDATE_CONSTRAINT book.isbn name=book_isbn_not_null\n  contract ALTER_NULL book.isbn not-null\n  contract DROP_CONSTRAINT book.isbn name=book_isbn_not_null\n", plan_one(c, ORM_DIALECT_POSTGRES))
	c.nullable = 1
	assert_strings_equal(c"0007_expand_book_isbn (atomic)\n  expand ALTER_NULL book.isbn null\n", plan_one(c, ORM_DIALECT_POSTGRES))


void test_create_and_drop_table():
	orm_change* c = orm_change_new(ORM_CHANGE_CREATE_TABLE, c"tag", 0)
	c.model_json = c"{\"name\": \"Tag\"}"
	assert_strings_equal(c"0007_expand_tag (atomic)\n  expand CREATE_TABLE tag\n", plan_one(c, ORM_DIALECT_POSTGRES))
	orm_change* d = orm_change_new(ORM_CHANGE_DROP_TABLE, c"tag", 0)
	assert_strings_equal(c"0007_expand_tag (atomic)\n  (no database change)\n0008_contract_tag (atomic) requires 0007_expand_tag\n  contract DROP_TABLE tag\n", plan_one(d, ORM_DIALECT_POSTGRES))


void test_force():
	orm_change* c = orm_change_new(ORM_CHANGE_DROP_COLUMN, c"book", c"isbn")
	c.force = 1
	assert_strings_equal(c"0007_contract_book_isbn (atomic)\n  contract DROP_COLUMN book.isbn unsafe\n", plan_one(c, ORM_DIALECT_POSTGRES))
	orm_change* r = orm_change_new(ORM_CHANGE_RENAME_TABLE, c"book", 0)
	r.new_name = c"volume"
	r.force = 1
	assert_strings_equal(c"0007_expand_book_to_volume (atomic)\n  expand RENAME_TABLE volume <- book unsafe\n", plan_one(r, ORM_DIALECT_POSTGRES))
	orm_change* i = orm_change_new(ORM_CHANGE_ADD_INDEX, c"book", c"title")
	i.force = 1
	assert_strings_equal(c"0007_expand_book_title (atomic)\n  expand ADD_INDEX book.title name=book_title_idx unsafe\n", plan_one(i, ORM_DIALECT_POSTGRES))
	orm_change* a = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", c"isbn")
	a.field_json = BOOK_ISBN()
	a.force = 1
	assert_strings_equal(c"0007_expand_book_isbn (atomic)\n  expand ADD_COLUMN book.isbn not-null unsafe\n", plan_one(a, ORM_DIALECT_POSTGRES))
	# Forced plans lint with warnings only.
	orm_planner* p = orm_planner_new(c"library", ORM_DIALECT_POSTGRES, 7, 0)
	list[orm_change*] cs = new list[orm_change*]
	cs.push(c)
	cs.push(r)
	cs.push(i)
	cs.push(a)
	list[orm_migration*] plan = orm_plan(p, cs)
	list[orm_lint_finding*] f = orm_lint_plan(plan, ORM_DIALECT_POSTGRES)
	assert_equal(0, orm_lint_count(f, ORM_LINT_ERROR))
	assert1(orm_lint_has(f, c"W-ORM-M001"))
	assert1(orm_lint_has(f, c"W-ORM-M004"))
	assert1(orm_lint_has(f, c"W-ORM-M005"))
	assert1(orm_lint_has(f, c"W-ORM-M006"))
	orm_lint_free(f)
	orm_planner_free(p, plan)
	cs.free()


# Several changes: stage k of every change ships before stage k + 1.
void test_multiple_changes_interleave():
	orm_change* a = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", c"isbn")
	a.field_json = BOOK_ISBN()
	orm_change* b = orm_change_new(ORM_CHANGE_DROP_COLUMN, c"author", c"nickname")
	orm_change* i = orm_change_new(ORM_CHANGE_ADD_INDEX, c"book", c"title")
	orm_planner* p = orm_planner_new(c"library", ORM_DIALECT_SQLITE, 3, c"0002_initial")
	list[orm_change*] cs = new list[orm_change*]
	cs.push(a)
	cs.push(b)
	cs.push(i)
	list[orm_migration*] plan = orm_plan(p, cs)
	assert_strings_equal(c"0003_expand_book_isbn (atomic)\n  expand ADD_COLUMN book.isbn null\n0004_expand_author_nickname (atomic)\n  expand ALTER_NULL author.nickname null deprecated\n0005_expand_book_title (atomic)\n  expand ADD_INDEX book.title name=book_title_idx\n0006_migrate_book_isbn (non-atomic)\n  migrate BACKFILL book.isbn name=book_isbn_backfill batch=1000 non_atomic\n0007_contract_author_nickname (atomic) requires 0004_expand_author_nickname\n  contract DROP_COLUMN author.nickname\n0008_contract_book_isbn (atomic) requires 0003_expand_book_isbn\n  contract ALTER_NULL book.isbn not-null\n", orm_plan_describe(plan))
	assert_strings_equal(c"library.0006_migrate_book_isbn", plan[4].dependencies[0])
	orm_planner_free(p, plan)
	cs.free()


void test_invalid_changes():
	orm_planner* p = orm_planner_new(c"library", ORM_DIALECT_SQLITE, 1, 0)
	list[orm_change*] cs = new list[orm_change*]
	cs.push(orm_change_new(ORM_CHANGE_RENAME_COLUMN, c"book", c"title"))
	assert1(orm_plan(p, cs) == 0)
	assert_contains(p.error, c"without new_name")
	cs[0] = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"book", 0)
	assert1(orm_plan(p, cs) == 0)
	assert_contains(p.error, c"without a column")
	cs[0] = orm_change_new(ORM_CHANGE_ADD_COLUMN, 0, c"x")
	assert1(orm_plan(p, cs) == 0)
	cs[0] = orm_change_new(99, c"book", c"x")
	assert1(orm_plan(p, cs) == 0)
	assert_contains(p.error, c"unknown change kind")
	orm_planner_free(p, 0)
	cs.free()


void test_json_helpers():
	assert_strings_equal(c"{\"null\": true}", orm_mjson_set(0, c"null", c"true"))
	assert_strings_equal(c"{\"null\": true}", orm_mjson_set(c"{ }", c"null", c"true"))
	assert_strings_equal(c"{\"a\": {\"null\": false}, \"null\": true}", orm_mjson_set(c"{\"a\": {\"null\": false}, \"null\": 1}", c"null", c"true"))
	assert_strings_equal(c"{\"x\": 1, \"s\": \"a\\\"b,}\"}", orm_mjson_set(c"{\"s\": \"a\\\"b,}\"}", c"x", c"1"))
	assert_strings_equal(c"[1, [2]]", orm_mjson_get(c"{\"k\": \"v\", \"l\": [1, [2]]}", c"l"))
	assert1(orm_mjson_get(c"{\"k\": \"v\"}", c"l") == 0)
	assert1(orm_mjson_has_value(c"{\"default\": null}", c"default") == 0)
	assert1(orm_mjson_has_value(c"{\"default\": \"0\"}", c"default"))
	assert_strings_equal(c"\"a\\\"b\"", orm_mjson_quote(c"a\"b"))


int main():
	test_add_column_not_null_postgres()
	test_add_column_not_null_sqlite()
	test_add_column_single_step()
	test_add_column_field_json()
	test_drop_column()
	test_rename_column()
	test_alter_type()
	test_rename_table()
	test_rebuild_table()
	test_add_index()
	test_add_fk_and_check()
	test_add_unique()
	test_alter_null()
	test_create_and_drop_table()
	test_force()
	test_multiple_changes_interleave()
	test_invalid_changes()
	test_json_helpers()
	print(c"orm_planner_test: ok\n")
	return 0
