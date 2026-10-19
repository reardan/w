# wbuild: arch_only=x64
# U2.3: the migration linter flags in-place renames and type changes, NOT
# NULL without a default, non-concurrent PostgreSQL index builds and
# destructive steps outside a separate contract migration; force (unsafe = 1)
# downgrades errors to warnings (docs/projects/orm/u2_3.md).
import libs.standard.orm.migrate.lint
import lib.assert


orm_migration* mig(char* name):
	return orm_migration_new(c"library", name)


orm_op* add(orm_migration* m, int kind, int phase, char* table, char* column):
	orm_op* op = orm_op_new(kind, phase, table)
	op.column = column
	orm_migration_add(m, op)
	return op


orm_op* raw(orm_migration* m, char* sql):
	orm_op* op = add(m, ORM_OP_RAW_SQL, ORM_PHASE_EXPAND, 0, 0)
	op.sql = sql
	return op


# The findings as "error W-ORM-M00x@i" items joined by spaces.
char* summary(orm_migration* m, int dialect):
	list[orm_lint_finding*] f = orm_lint_migration(m, dialect)
	string_builder* b = string_new()
	for orm_lint_finding* one in f:
		if (b.length > 0): string_append(b, c" ")
		if (one.severity == ORM_LINT_ERROR): string_append(b, c"error ")
		else: string_append(b, c"warning ")
		string_append(b, one.code)
		string_append(b, c"@")
		string_append_int(b, one.op_index)
	orm_lint_free(f)
	return b.data


void test_clean_migration():
	orm_migration* m = mig(c"0001_expand")
	orm_op* a = add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"isbn")
	a.field_json = c"{\"name\": \"isbn\", \"null\": true}"
	orm_op* b = add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"pages")
	b.field_json = c"{\"name\": \"pages\", \"default\": \"0\"}"
	add(m, ORM_OP_CREATE_TABLE, ORM_PHASE_EXPAND, c"tag", 0)
	assert_strings_equal(c"", summary(m, ORM_DIALECT_POSTGRES))
	assert_strings_equal(c"", summary(m, ORM_DIALECT_SQLITE))


void test_rename_table():
	orm_migration* m = mig(c"0002_rename")
	orm_op* r = add(m, ORM_OP_RENAME_TABLE, ORM_PHASE_EXPAND, c"volume", 0)
	r.source_table = c"book"
	assert_strings_equal(c"error W-ORM-M001@0", summary(m, ORM_DIALECT_SQLITE))
	r.unsafe = 1
	assert_strings_equal(c"warning W-ORM-M001@0", summary(m, ORM_DIALECT_SQLITE))


void test_raw_sql_renames_and_type_changes():
	orm_migration* m = mig(c"0003_raw")
	raw(m, c"ALTER TABLE book RENAME TO volume")
	raw(m, c"alter table \"book\" rename column title to name; ALTER TABLE ONLY public.book RENAME isbn TO code")
	raw(m, c"ALTER TABLE book ALTER COLUMN price TYPE numeric(12, 2)")
	raw(m, c"ALTER TABLE book ALTER price SET DATA TYPE bigint, ADD COLUMN x int")
	raw(m, c"RENAME TABLE book TO volume")
	raw(m, c"-- ALTER TABLE book RENAME TO nope\nALTER TABLE book RENAME CONSTRAINT a TO b; ALTER TABLE book ADD COLUMN note text DEFAULT 'RENAME TO'")
	raw(m, c"ALTER TABLE book MODIFY price bigint")
	assert_strings_equal(c"error W-ORM-M001@0 error W-ORM-M002@1 error W-ORM-M002@1 error W-ORM-M003@2 error W-ORM-M003@3 error W-ORM-M001@4 error W-ORM-M003@6", summary(m, ORM_DIALECT_POSTGRES))


void test_not_null_without_default():
	orm_migration* m = mig(c"0004_not_null")
	orm_op* a = add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"isbn")
	a.field_json = c"{\"name\": \"isbn\", \"null\": false}"
	orm_op* b = add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"code")
	b.field_json = c"{\"name\": \"code\", \"default\": null}"
	add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"bare")
	orm_op* d = add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"ok")
	d.field_json = c"{\"name\": \"ok\", \"null\": false, \"default\": \"''\"}"
	raw(m, c"ALTER TABLE book ADD COLUMN isbn2 text NOT NULL")
	raw(m, c"ALTER TABLE book ADD COLUMN isbn3 text NOT NULL DEFAULT ''")
	raw(m, c"ALTER TABLE book ADD isbn4 text NULL")
	assert_strings_equal(c"error W-ORM-M004@0 error W-ORM-M004@1 error W-ORM-M004@2 error W-ORM-M004@4", summary(m, ORM_DIALECT_SQLITE))
	a.unsafe = 1
	assert_strings_equal(c"warning W-ORM-M004@0 error W-ORM-M004@1 error W-ORM-M004@2 error W-ORM-M004@4", summary(m, ORM_DIALECT_SQLITE))


void test_index_builds():
	orm_migration* m = mig(c"0005_index")
	add(m, ORM_OP_ADD_INDEX, ORM_PHASE_EXPAND, c"book", c"title")
	assert_strings_equal(c"error W-ORM-M005@0", summary(m, ORM_DIALECT_POSTGRES))
	assert_strings_equal(c"", summary(m, ORM_DIALECT_SQLITE))
	orm_migration* c = mig(c"0006_index")
	orm_op* i = add(c, ORM_OP_ADD_INDEX, ORM_PHASE_EXPAND, c"book", c"title")
	i.non_atomic = 1
	c.atomic = 0
	assert_strings_equal(c"", summary(c, ORM_DIALECT_POSTGRES))
	orm_migration* r = mig(c"0007_index")
	raw(r, c"CREATE INDEX book_title ON book (title)")
	raw(r, c"create unique index concurrently book_isbn on book (isbn)")
	raw(r, c"ALTER TABLE book ADD CONSTRAINT u UNIQUE (isbn)")
	raw(r, c"ALTER TABLE book ADD CONSTRAINT u2 UNIQUE USING INDEX book_isbn")
	assert_strings_equal(c"error W-ORM-M005@0 error W-ORM-M008@1 error W-ORM-M005@2", summary(r, ORM_DIALECT_POSTGRES))
	assert_strings_equal(c"error W-ORM-M008@1", summary(r, ORM_DIALECT_SQLITE))


void test_destructive_ops():
	# Contract migration with requires_applied and no expand ops: clean.
	orm_migration* ok = mig(c"0009_contract")
	ok.requires_applied = c"0007_expand"
	add(ok, ORM_OP_DROP_COLUMN, ORM_PHASE_CONTRACT, c"book", c"isbn")
	add(ok, ORM_OP_DROP_CONSTRAINT, ORM_PHASE_CONTRACT, c"book", 0)
	add(ok, ORM_OP_DROP_TABLE, ORM_PHASE_CONTRACT, c"old", 0)
	assert_strings_equal(c"", summary(ok, ORM_DIALECT_POSTGRES))
	# No requires_applied.
	orm_migration* bare = mig(c"0010_drop")
	add(bare, ORM_OP_DROP_TABLE, ORM_PHASE_CONTRACT, c"old", 0)
	orm_op* dt = raw(bare, c"DROP TABLE older")
	dt.phase = ORM_PHASE_CONTRACT
	assert_strings_equal(c"error W-ORM-M006@0 error W-ORM-M006@1", summary(bare, ORM_DIALECT_SQLITE))
	# Drop in the same migration as the expand ops it depends on.
	orm_migration* same = mig(c"0011_same")
	same.requires_applied = c"0007_expand"
	orm_op* a = add(same, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"name")
	a.field_json = c"{\"null\": true}"
	orm_op* s = add(same, ORM_OP_SYNC_TRIGGER, ORM_PHASE_EXPAND, c"book", c"name")
	s.source_column = c"title"
	add(same, ORM_OP_DROP_COLUMN, ORM_PHASE_CONTRACT, c"book", c"title")
	raw(same, c"ALTER TABLE book DROP COLUMN legacy")
	assert_strings_equal(c"error W-ORM-M007@2 error W-ORM-M007@3", summary(same, ORM_DIALECT_POSTGRES))
	# force downgrades every error of that op.
	orm_migration* forced = mig(c"0012_forced")
	orm_op* o1 = add(forced, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"x")
	o1.field_json = c"{\"null\": true}"
	orm_op* d = add(forced, ORM_OP_DROP_COLUMN, ORM_PHASE_CONTRACT, c"book", c"y")
	d.unsafe = 1
	assert_strings_equal(c"warning W-ORM-M006@1 warning W-ORM-M007@1", summary(forced, ORM_DIALECT_POSTGRES))


void test_atomicity():
	orm_migration* m = mig(c"0013_mixed")
	orm_op* o2 = add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"x")
	o2.field_json = c"{\"null\": true}"
	orm_op* copy = orm_op_new(ORM_OP_COPY_COLUMN, ORM_PHASE_MIGRATE, c"book")
	copy.non_atomic = 1
	m.ops.push(copy)     # bypasses orm_migration_add, so m stays atomic
	assert_strings_equal(c"error W-ORM-M008@1", summary(m, ORM_DIALECT_SQLITE))
	copy.unsafe = 1
	assert_strings_equal(c"warning W-ORM-M008@1", summary(m, ORM_DIALECT_SQLITE))
	orm_migration* swap = mig(c"0014_swap")
	orm_op* c = add(swap, ORM_OP_COPY_TABLE, ORM_PHASE_MIGRATE, c"book__new", 0)
	c.non_atomic = 1
	swap.atomic = 0
	add(swap, ORM_OP_SWAP_TABLES, ORM_PHASE_MIGRATE, c"book__new", 0)
	assert_strings_equal(c"error W-ORM-M009@1", summary(swap, ORM_DIALECT_SQLITE))


void test_postgres_constraints_and_not_null():
	orm_migration* m = mig(c"0015_constraints")
	raw(m, c"ALTER TABLE book ADD CONSTRAINT fk FOREIGN KEY (author_id) REFERENCES author (id)")
	raw(m, c"ALTER TABLE book ADD CONSTRAINT fk FOREIGN KEY (author_id) REFERENCES author (id) NOT VALID")
	raw(m, c"ALTER TABLE book ADD CHECK (price >= 0)")
	raw(m, c"ALTER TABLE book ALTER COLUMN isbn SET NOT NULL")
	orm_op* n = add(m, ORM_OP_ALTER_NULL, ORM_PHASE_CONTRACT, c"book", c"isbn")
	n.field_json = c"{\"null\": false}"
	assert_strings_equal(c"warning W-ORM-M010@0 warning W-ORM-M010@2 warning W-ORM-M011@3 warning W-ORM-M011@4", summary(m, ORM_DIALECT_POSTGRES))
	assert_strings_equal(c"", summary(m, ORM_DIALECT_SQLITE))
	orm_migration* v = mig(c"0016_validated")
	orm_op* o3 = add(v, ORM_OP_VALIDATE_CONSTRAINT, ORM_PHASE_CONTRACT, c"book", c"isbn")
	o3.name = c"chk"
	orm_op* o4 = add(v, ORM_OP_ALTER_NULL, ORM_PHASE_CONTRACT, c"book", c"isbn")
	o4.field_json = c"{\"null\": false}"
	orm_op* loose = add(v, ORM_OP_ALTER_NULL, ORM_PHASE_CONTRACT, c"book", c"note")
	loose.field_json = c"{\"null\": true}"
	assert_strings_equal(c"", summary(v, ORM_DIALECT_POSTGRES))


# An op masked to one dialect (orm_op.dialects, H1) lints only there.
void test_dialect_mask():
	orm_migration* m = mig(c"0017_masked")
	orm_op* r = raw(m, c"ALTER TABLE book ADD CHECK (price >= 0)")
	r.dialects = ORM_OP_ON_POSTGRES
	orm_op* s = raw(m, c"ALTER TABLE book RENAME COLUMN a TO b")
	s.dialects = ORM_OP_ON_SQLITE
	assert_strings_equal(c"warning W-ORM-M010@0", summary(m, ORM_DIALECT_POSTGRES))
	assert_strings_equal(c"error W-ORM-M002@1", summary(m, ORM_DIALECT_SQLITE))
	assert1(orm_op_runs_on(r, 0))
	assert1(orm_op_runs_on(r, ORM_DIALECT_POSTGRES))
	assert1(orm_op_runs_on(r, ORM_DIALECT_SQLITE) == 0)


void test_messages_and_helpers():
	orm_migration* m = mig(c"0017_msg")
	orm_op* a = add(m, ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"book", c"isbn")
	a.field_json = c"{\"null\": false}"
	list[orm_lint_finding*] f = orm_lint_migration(m, ORM_DIALECT_SQLITE)
	assert_equal(1, f.length)
	assert_equal(1, orm_lint_count(f, ORM_LINT_ERROR))
	assert_equal(0, orm_lint_count(f, ORM_LINT_WARNING))
	assert1(orm_lint_has(f, c"W-ORM-M004"))
	assert1(orm_lint_has(f, c"W-ORM-M001") == 0)
	assert_strings_equal(c"error W-ORM-M004 0017_msg: op 0 ADD_COLUMN book.isbn: NOT NULL column without a default: add it nullable or with a default, backfill, then tighten\n", orm_lint_format(f))
	orm_lint_free(f)
	assert_strings_equal(c"SWAP_TABLES", orm_op_kind_name(ORM_OP_SWAP_TABLES))
	assert_strings_equal(c"UNKNOWN", orm_op_kind_name(0))
	assert_strings_equal(c"migrate", orm_phase_name(ORM_PHASE_MIGRATE))
	list[list[char*]] s = orm_sql_statements(c"select 'a;b' , \"Q\" /* ; */ from [t];; x")
	assert_equal(2, s.length)
	assert_equal(6, s[0].length)
	assert_strings_equal(c"'", s[0][1])
	assert_strings_equal(c"Q", s[0][3])
	assert_strings_equal(c"T", s[0][5])
	orm_sql_statements_free(s)


int main():
	test_clean_migration()
	test_rename_table()
	test_raw_sql_renames_and_type_changes()
	test_not_null_without_default()
	test_index_builds()
	test_destructive_ops()
	test_atomicity()
	test_postgres_constraints_and_not_null()
	test_dialect_mask()
	test_messages_and_helpers()
	print(c"orm_migrate_lint_test: ok\n")
	return 0
