# Shared end-to-end scenario for orm_apply_sqlite_test and
# orm_apply_postgres_test (issue #754, unit U2.4).
#
# Creates the library fixture schema from its generated snapshot, then runs
# every row of plan section 5.2 through planner.w and the applier, one
# migration (= one deploy) at a time. Between deploys it runs the plain SQL
# an "old code" and a "new code" version would issue and asserts that what
# should work works and what should fail fails (plan 5.3).
import libs.standard.orm.migrate.apply
import libs.standard.orm.migrate.planner
import libs.standard.orm.migrate.autodetect
import tests.orm.generated.library_orm
import lib.assert


orm_db* T_DB
int T_DIALECT
int T_NEXT
char* T_PREV
list[orm_migration*] T_ALL
char* T_TITLE              # the book title column new code writes


int t_pg():
	return T_DIALECT == ORM_DIALECT_POSTGRES


char* q(char* a, char* b, char* c2, char* d):
	return orm_mx_cat(a, b, c2, d)


void t_ok(char* sql):
	int ok = orm_db_exec_sql(T_DB, sql)
	if (ok == 0):
		print2(c"statement failed: ")
		println2(sql)
		println2(orm_db_error(T_DB))
	asserts(sql, ok)


void t_bad(char* sql):
	int ok = orm_db_exec_sql(T_DB, sql)
	if (ok):
		print2(c"statement unexpectedly succeeded: ")
		println2(sql)
	asserts(sql, ok == 0)


# First cell, "" for no row, "NULL" for SQL NULL.
char* t_val(char* sql):
	sql_result* r = sql_query(T_DB.conn, sql)
	if (r == 0):
		print2(c"query failed: ")
		println2(sql)
		println2(sql_error(T_DB.conn))
	asserts(sql, r != 0)
	char* out = c""
	if (r.rows > 0):
		if (sql_value(r, 0, 0) == 0): out = c"NULL"
		else: out = strclone(sql_value(r, 0, 0))
	sql_result_free(r)
	return out


int t_num(char* sql):
	return atoi(t_val(sql))


void t_eq(char* want, char* sql):
	char* got = t_val(sql)
	if (strcmp(want, got) != 0):
		print2(c"query: ")
		println2(sql)
	assert_strings_equal(want, got)


int t_table_exists(char* table):
	if (t_pg()): return strcmp(t_val(q(c"SELECT to_regclass('", table, c"') IS NOT NULL", 0)), c"t") == 0
	return t_num(q(c"SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '", table, c"'", 0)) == 1


int t_column_exists(char* table, char* column):
	if (t_pg()): return t_num(q(c"SELECT COUNT(*) FROM information_schema.columns WHERE table_name = '", table, c"' AND column_name = '", q(column, c"'", 0, 0))) == 1
	return t_num(q(c"SELECT COUNT(*) FROM pragma_table_info('", table, c"') WHERE name = '", q(column, c"'", 0, 0))) == 1


int t_apply(list[orm_migration*] ms, int force):
	int n = orm_migrate_apply(T_DB, ms, force)
	if (n < 0):
		print2(c"apply failed: ")
		println2(orm_db_error(T_DB))
	return n


# One deploy: the migration joins the app's list and the list is applied.
void deploy(orm_migration* m):
	T_ALL.push(m)
	int n = t_apply(T_ALL, 0)
	if (n != 1):
		print2(c"deploying ")
		println2(m.name)
	assert_equal(1, n)


# Planned for `dialect`, linted and applied on T_DIALECT.
list[orm_migration*] plan_change_as(orm_change* c, int dialect):
	orm_planner* p = orm_planner_new(c"library", dialect, T_NEXT, T_PREV)
	list[orm_change*] cs = new list[orm_change*]
	cs.push(c)
	list[orm_migration*] plan = orm_plan(p, cs)
	asserts(c"orm_plan", plan != 0)
	list[orm_lint_finding*] findings = orm_lint_plan(plan, T_DIALECT)
	if (c.force == 0): assert_equal(0, orm_lint_count(findings, ORM_LINT_ERROR))
	T_NEXT = p.next_number
	T_PREV = plan[plan.length - 1].name
	return plan


list[orm_migration*] plan_change(orm_change* c):
	return plan_change_as(c, T_DIALECT)


orm_migration* hand_migration(char* label):
	char* num = zfill(itoa(T_NEXT), 4)
	orm_migration* m = orm_migration_new(c"library", q(num, c"_", label, 0))
	if (T_PREV != 0): m.dependencies.push(q(c"library.", T_PREV, 0, 0))
	T_NEXT = T_NEXT + 1
	T_PREV = m.name
	return m


char* model_json(char* name):
	json_value* s = json_parse(library_schema_json())
	json_value* models = json_object_get(s, c"models")
	for i in range(json_array_length(models)):
		json_value* m = json_array_get(models, i)
		if (strcmp(orm_mx_jstr(m, c"name"), name) == 0): return json_stringify(m)
	assert1(0)
	return 0


char* field_json(char* model, char* field):
	json_value* m = json_parse(model_json(model))
	json_value* fields = json_object_get(m, c"fields")
	for i in range(json_array_length(fields)):
		json_value* f = json_array_get(fields, i)
		if (strcmp(orm_mx_jstr(f, c"name"), field) == 0): return json_stringify(f)
	assert1(0)
	return 0


char* author_id(char* email):
	return t_val(q(c"SELECT id FROM library_author WHERE email = '", email, c"'", 0))


# ---------------------------------------------------------------------------
# Backfills (registered W functions)

int t_affected(orm_db* db, char* sql):
	sql_result* r = sql_query(db.conn, sql)
	if (r == 0):
		orm_db_set_error(db, sql_error(db.conn))
		return -1
	int n = r.affected
	sql_result_free(r)
	return n


int isbn_backfill(orm_db* db, int batch):
	char* sql = q(c"UPDATE library_book SET isbn = 'isbn-' || id WHERE id IN (SELECT id FROM library_book WHERE isbn IS NULL ORDER BY id LIMIT ", itoa(batch), c")", 0)
	return t_affected(db, sql)


int price_backfill(orm_db* db, int batch):
	char* sql = q(c"UPDATE library_book SET price = 0 WHERE id IN (SELECT id FROM library_book WHERE price IS NULL ORDER BY id LIMIT ", itoa(batch), c")", 0)
	return t_affected(db, sql)


int failing_backfill(orm_db* db, int batch):
	orm_db_set_error(db, c"deliberate failure")
	return -1


# ---------------------------------------------------------------------------
# Steps

void step_initial():
	orm_migration* m = hand_migration(c"initial")
	json_value* s = json_parse(library_schema_json())
	json_value* models = json_object_get(s, c"models")
	for i in range(json_array_length(models)):
		json_value* mj = json_array_get(models, i)
		orm_op* op = orm_op_new(ORM_OP_CREATE_TABLE, ORM_PHASE_EXPAND, orm_mx_jstr(mj, c"table"))
		op.model_json = json_stringify(mj)
		orm_migration_add(m, op)
	T_ALL.push(m)
	char* sql = orm_migrate_sql(T_DB, T_ALL, 0)
	asserts(orm_db_error(T_DB), sql != 0)
	assert_contains(sql, c"CREATE TABLE \"library_book\"")
	assert_contains(sql, c"CREATE TABLE \"library_book_tags\"")
	assert_contains(sql, c"REFERENCES \"library_author\" (\"id\") ON DELETE CASCADE")
	assert_contains(sql, c"\"status\" IN ('draft', 'pub')")
	assert_contains(sql, c"CONSTRAINT \"library_book_price_nonnegative\" CHECK (price >= 0)")
	assert_contains(sql, c"INSERT INTO orm_migrations")
	if (t_pg()):
		assert_contains(sql, c"\"id\" BIGSERIAL PRIMARY KEY")
		assert_contains(sql, c"NUMERIC(8, 2)")
	else: assert_contains(sql, c"\"id\" INTEGER PRIMARY KEY AUTOINCREMENT")
	char* status = orm_migrate_status(T_DB, T_ALL)
	assert_contains(status, c"[ ] library.0001_initial (pending)")
	assert_equal(1, t_apply(T_ALL, 0))
	assert1(orm_migrate_is_applied(T_DB, c"library", c"0001_initial"))
	assert_contains(orm_migrate_status(T_DB, T_ALL), c"[X] library.0001_initial (applied ")
	# Fixture rows and constraint checks.
	t_ok(c"INSERT INTO library_author (name, email, created) VALUES ('Ann', 'ann@x', '2026-01-01 00:00:00')")
	t_ok(c"INSERT INTO library_author (name, email, created) VALUES ('Bob', 'bob@x', '2026-01-02 00:00:00')")
	t_bad(c"INSERT INTO library_author (name, email, created) VALUES ('Ann2', 'ann@x', '2026-01-01 00:00:00')")
	t_bad(c"INSERT INTO library_author (email, created) VALUES ('c@x', '2026-01-01 00:00:00')")
	t_ok(c"INSERT INTO library_tag (name) VALUES ('sf')")
	char* ann = author_id(c"ann@x")
	for i in range(5):
		t_ok(q(c"INSERT INTO library_book (title, author_id, price, pages) VALUES ('Book ", itoa(i), q(c"', ", ann, c", 12.50, ", 0), q(itoa(100 + i), c")", 0, 0)))
	t_eq(c"draft", c"SELECT status FROM library_book WHERE title = 'Book 0'")
	t_bad(q(c"INSERT INTO library_book (title, author_id, price, status) VALUES ('x', ", ann, c", 1, 'bad')", 0))
	t_bad(q(c"INSERT INTO library_book (title, author_id, price) VALUES ('x', ", ann, c", -1)", 0))
	t_bad(c"INSERT INTO library_book (title, author_id, price) VALUES ('x', 999999, 1)")
	t_ok(c"INSERT INTO library_book_tags (book_id, tag_id) SELECT b.id, t.id FROM library_book b, library_tag t WHERE b.title = 'Book 0'")
	t_bad(c"INSERT INTO library_book_tags (book_id, tag_id) SELECT b.id, t.id FROM library_book b, library_tag t WHERE b.title = 'Book 0'")
	# ON DELETE CASCADE through the FK and the m2m table.
	char* bob = author_id(c"bob@x")
	t_ok(q(c"INSERT INTO library_book (title, author_id, price) VALUES ('Bob book', ", bob, c", 1)", 0))
	t_ok(c"INSERT INTO library_book_tags (book_id, tag_id) SELECT b.id, t.id FROM library_book b, library_tag t WHERE b.title = 'Bob book'")
	t_ok(c"DELETE FROM library_author WHERE email = 'bob@x'")
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM library_book WHERE title = 'Bob book'"))
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_tags"))
	# Idempotent re-apply.
	assert_equal(0, t_apply(T_ALL, 0))


list[orm_migration*] one_more(orm_migration* m):
	list[orm_migration*] l = new list[orm_migration*]
	for orm_migration* x in T_ALL: l.push(x)
	l.push(m)
	return l


# Lint refusal, force, reverse_sql via unapply; unsafe ops need force.
void step_lint_and_force():
	orm_migration* m = hand_migration(c"raw_rename")
	orm_op* op = orm_op_new(ORM_OP_RAW_SQL, ORM_PHASE_EXPAND, c"library_tag")
	op.sql = c"ALTER TABLE library_tag RENAME COLUMN name TO label"
	op.reverse_sql = c"ALTER TABLE library_tag RENAME COLUMN label TO name"
	orm_migration_add(m, op)
	T_ALL.push(m)
	assert_equal(-1, orm_migrate_apply(T_DB, T_ALL, 0))
	assert_contains(orm_db_error(T_DB), c"W-ORM-M002")
	assert1(orm_migrate_is_applied(T_DB, c"library", m.name) == 0)
	assert_equal(1, t_apply(T_ALL, 1))
	assert1(t_column_exists(c"library_tag", c"label"))
	asserts(orm_db_error(T_DB), orm_migrate_unapply(T_DB, m))
	assert1(t_column_exists(c"library_tag", c"name"))
	assert1(orm_migrate_is_applied(T_DB, c"library", m.name) == 0)
	assert_equal(1, t_apply(T_ALL, 1))
	asserts(orm_db_error(T_DB), orm_migrate_unapply(T_DB, m))
	# Keep the list consistent: re-applying later would rename again, so
	# the migration is replaced by a no-op RAW_SQL of the same name.
	op.sql = c"SELECT 1"
	op.reverse_sql = 0
	assert_equal(1, t_apply(T_ALL, 0))
	# A scratch table and its forced (unsafe) drop.
	orm_migration* s = hand_migration(c"scratch")
	orm_op* cr = orm_op_new(ORM_OP_RAW_SQL, ORM_PHASE_EXPAND, c"library_scratch")
	cr.sql = c"CREATE TABLE library_scratch (id INTEGER PRIMARY KEY); INSERT INTO library_scratch (id) VALUES (1)"
	orm_migration_add(s, cr)
	deploy(s)
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_scratch"))
	orm_change* c = orm_change_new(ORM_CHANGE_DROP_TABLE, c"library_scratch", 0)
	c.force = 1
	list[orm_migration*] plan = plan_change(c)
	assert_equal(1, plan.length)
	T_ALL.push(plan[0])
	assert_equal(-1, orm_migrate_apply(T_DB, T_ALL, 0))
	assert_contains(orm_db_error(T_DB), c"marked unsafe")
	assert1(t_table_exists(c"library_scratch"))
	assert_equal(1, t_apply(T_ALL, 1))
	assert1(t_table_exists(c"library_scratch") == 0)
	# A failing backfill rolls back and leaves the migration unrecorded.
	orm_backfill_register(c"library_failing_backfill", failing_backfill)
	orm_migration* fb = hand_migration(c"failing_backfill")
	orm_op* b = orm_op_new(ORM_OP_BACKFILL, ORM_PHASE_MIGRATE, c"library_book")
	b.name = c"library_failing_backfill"
	b.sql = b.name
	b.non_atomic = 1
	orm_migration_add(fb, b)
	T_ALL.push(fb)
	assert_equal(-1, orm_migrate_apply(T_DB, T_ALL, 0))
	assert_contains(orm_db_error(T_DB), c"deliberate failure")
	assert1(orm_migrate_is_applied(T_DB, c"library", fb.name) == 0)
	b.name = c"library_noop_backfill"
	b.sql = b.name
	orm_backfill_register(c"library_noop_backfill", price_backfill)
	assert_equal(1, t_apply(T_ALL, 0))
	# Trigger history (U3.3) on library_book and library_author: every later
	# step changes these tables, and the history must follow
	# (step_history_in_step checks it).
	orm_migration* h = hand_migration(c"history")
	orm_migration_add(h, orm_op_new(ORM_OP_CREATE_HISTORY, ORM_PHASE_EXPAND, c"library_book"))
	orm_op* ha = orm_op_new(ORM_OP_CREATE_HISTORY, ORM_PHASE_EXPAND, c"library_author")
	ha.model_json = model_json(c"Author")
	orm_migration_add(h, ha)
	char* hsql = orm_migrate_sql(T_DB, one_more(h), h.name)
	asserts(orm_db_error(T_DB), hsql != 0)
	assert_contains(hsql, c"CREATE TABLE \"library_book_history\"")
	deploy(h)
	assert1(t_table_exists(c"library_book_history"))
	assert1(t_column_exists(c"library_author_history", c"created"))
	t_ok(c"UPDATE library_book SET pages = 999 WHERE title = 'Book 1'")
	t_ok(c"UPDATE library_book SET pages = 999 WHERE title = 'Book 1'")
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_history WHERE pages = 999 AND history_type = '~'"))


char* OLD_BOOK():
	return q(c"INSERT INTO library_book (title, author_id, price) VALUES ('old', ", author_id(c"ann@x"), c", 1)", 0)


# Add a NOT NULL column without default: nullable + backfill + NOT NULL.
void step_add_column():
	orm_backfill_register(c"library_book_isbn_backfill", isbn_backfill)
	orm_change* c = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"library_book", c"isbn")
	c.field_json = c"{\"name\":\"isbn\",\"column\":\"isbn\",\"kind\":4,\"null\":false,\"max_length\":20,\"default\":null}"
	c.batch_size = 2
	list[orm_migration*] plan = plan_change(c)
	assert_equal(3, plan.length)
	deploy(plan[0])
	char* ann = author_id(c"ann@x")
	t_ok(OLD_BOOK())
	t_ok(q(c"INSERT INTO library_book (title, author_id, price, isbn) VALUES ('new', ", ann, c", 1, 'isbn-new')", 0))
	assert1(t_num(c"SELECT COUNT(*) FROM library_book WHERE isbn IS NULL") > 2)
	char* sql = orm_migrate_sql(T_DB, plan, plan[1].name)
	asserts(orm_db_error(T_DB), sql != 0)
	assert_contains(sql, c"backfill library_book_isbn_backfill")
	deploy(plan[1])
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM library_book WHERE isbn IS NULL"))
	t_eq(c"isbn-new", c"SELECT isbn FROM library_book WHERE title = 'new'")
	if (t_pg()): t_bad(OLD_BOOK())
	t_ok(q(c"INSERT INTO library_book (title, author_id, price, isbn) VALUES ('new2', ", ann, c", 1, 'isbn-new2')", 0))
	deploy(plan[2])
	t_bad(OLD_BOOK())
	t_ok(q(c"INSERT INTO library_book (title, author_id, price, isbn) VALUES ('new3', ", ann, c", 1, 'isbn-new3')", 0))
	if (t_pg()): assert_equal(0, t_num(c"SELECT COUNT(*) FROM pg_constraint WHERE conname = 'library_book_isbn_not_null'"))
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_tags"))


char* NEW_BOOK(char* title, char* extra_cols, char* extra_vals):
	string_builder* b = string_new()
	string_append(b, c"INSERT INTO library_book (")
	string_append(b, T_TITLE)
	string_append(b, c", author_id, price, isbn")
	string_append(b, extra_cols)
	string_append(b, c") VALUES ('")
	string_append(b, title)
	string_append(b, c"', ")
	string_append(b, author_id(c"ann@x"))
	string_append(b, c", 1, 'isbn-")
	string_append(b, title)
	string_append(b, c"'")
	string_append(b, extra_vals)
	string_append(b, c")")
	return orm_mx_take(b)


void step_unique_check_fk_index():
	# Unique: concurrent unique index then constraint (PG), unique index (SQLite).
	orm_change* u = orm_change_new(ORM_CHANGE_ADD_UNIQUE, c"library_book", c"isbn")
	list[orm_migration*] plan = plan_change(u)
	for orm_migration* m in plan: deploy(m)
	t_bad(c"INSERT INTO library_book (title, author_id, price, isbn) SELECT 'dup', author_id, 1, isbn FROM library_book WHERE title = 'new3'")
	if (t_pg()): assert_equal(1, t_num(c"SELECT COUNT(*) FROM pg_constraint WHERE conname = 'library_book_isbn_uniq' AND contype = 'u'"))
	# CHECK: NOT VALID + VALIDATE on PG; table rebuild on SQLite.
	orm_change* ck = orm_change_new(ORM_CHANGE_ADD_CHECK, c"library_book", c"isbn")
	ck.sql = c"CHECK (length(isbn) >= 4)"
	plan = plan_change(ck)
	deploy(plan[0])
	t_bad(q(c"INSERT INTO library_book (title, author_id, price, isbn) VALUES ('short', ", author_id(c"ann@x"), c", 1, 'abc')", 0))
	t_ok(NEW_BOOK(c"chk", c"", c""))
	if (plan.length > 1): deploy(plan[1])
	if (t_pg()): t_eq(c"t", c"SELECT convalidated FROM pg_constraint WHERE conname = 'library_book_isbn_check'")
	else: assert_contains(t_val(c"SELECT sql FROM sqlite_master WHERE name = 'library_book'"), c"CONSTRAINT \"library_book_isbn_check\" CHECK (length(isbn) >= 4)")
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_tags"))
	# FK on a new nullable column.
	orm_change* ed = orm_change_new(ORM_CHANGE_ADD_COLUMN, c"library_book", c"editor_id")
	ed.field_json = c"{\"name\":\"editor_id\",\"column\":\"editor_id\",\"kind\":1,\"null\":true}"
	ed.nullable = 1
	plan = plan_change(ed)
	deploy(plan[0])
	orm_change* fk = orm_change_new(ORM_CHANGE_ADD_FK, c"library_book", c"editor_id")
	fk.sql = c"FOREIGN KEY (editor_id) REFERENCES library_author (id)"
	plan = plan_change(fk)
	deploy(plan[0])
	t_bad(NEW_BOOK(c"ed-bad", c", editor_id", c", 999999"))
	t_ok(NEW_BOOK(c"ed-ok", c", editor_id", q(c", ", author_id(c"ann@x"), 0, 0)))
	if (plan.length > 1): deploy(plan[1])
	# Index: CONCURRENTLY in a non-atomic migration on PG.
	orm_change* ix = orm_change_new(ORM_CHANGE_ADD_INDEX, c"library_book", c"published_at")
	plan = plan_change(ix)
	char* sql = orm_migrate_sql(T_DB, plan, 0)
	asserts(orm_db_error(T_DB), sql != 0)
	if (t_pg()): assert_contains(sql, c"CREATE INDEX CONCURRENTLY IF NOT EXISTS \"library_book_published_at_idx\"")
	else: assert_contains(sql, c"CREATE INDEX IF NOT EXISTS \"library_book_published_at_idx\"")
	deploy(plan[0])
	if (t_pg()): assert_equal(1, t_num(c"SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'library_book_published_at_idx'"))
	else: assert_equal(1, t_num(c"SELECT COUNT(*) FROM sqlite_master WHERE name = 'library_book_published_at_idx'"))


# Rename column title -> name: duplication with dual-write triggers. title
# is NOT NULL, so the PostgreSQL plan carries the CHECK (name IS NOT NULL)
# NOT VALID ops (PostgreSQL-only, orm_op.dialects); one plan made for
# PostgreSQL is applied on both dialects, as a committed list would be.
void step_rename_column():
	orm_change* c = orm_change_new(ORM_CHANGE_RENAME_COLUMN, c"library_book", c"title")
	c.field_json = field_json(c"Book", c"title")
	c.new_name = c"name"
	c.batch_size = 2
	list[orm_migration*] plan = plan_change_as(c, ORM_DIALECT_POSTGRES)
	assert_equal(4, plan.length)
	assert_equal(ORM_OP_ON_POSTGRES, plan[1].ops[plan[1].ops.length - 1].dialects)
	deploy(plan[0])
	char* ann = author_id(c"ann@x")
	# old code writes title, new code writes name; each sees its column.
	t_ok(q(c"INSERT INTO library_book (title, author_id, price, isbn) VALUES ('old-rc', ", ann, c", 1, 'isbn-old-rc')", 0))
	t_eq(c"old-rc", c"SELECT name FROM library_book WHERE isbn = 'isbn-old-rc'")
	# History records the insert first: on SQLite the dual-write UPDATE adds
	# a '~' row after it, never before (the history triggers fire first).
	t_eq(c"+", c"SELECT history_type FROM library_book_history WHERE isbn = 'isbn-old-rc' ORDER BY history_id LIMIT 1")
	t_eq(c"old-rc", c"SELECT name FROM library_book_history WHERE isbn = 'isbn-old-rc' ORDER BY history_id DESC LIMIT 1")
	t_ok(q(c"INSERT INTO library_book (name, author_id, price, isbn) VALUES ('new-rc', ", ann, c", 1, 'isbn-new-rc')", 0))
	t_eq(c"new-rc", c"SELECT title FROM library_book WHERE isbn = 'isbn-new-rc'")
	t_ok(c"UPDATE library_book SET title = 'old-rc2' WHERE isbn = 'isbn-old-rc'")
	t_eq(c"old-rc2", c"SELECT name FROM library_book WHERE isbn = 'isbn-old-rc'")
	t_ok(c"UPDATE library_book SET name = 'new-rc2' WHERE isbn = 'isbn-new-rc'")
	t_eq(c"new-rc2", c"SELECT title FROM library_book WHERE isbn = 'isbn-new-rc'")
	assert1(t_num(c"SELECT COUNT(*) FROM library_book WHERE name IS NULL") > 0)
	deploy(plan[1])
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM library_book WHERE name IS NULL"))
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM library_book WHERE name <> title"))
	# Old code still inserts after the migrate step (no CHECK on SQLite).
	t_ok(q(c"INSERT INTO library_book (title, author_id, price, isbn) VALUES ('old-rc4', ", ann, c", 1, 'isbn-old-rc4')", 0))
	t_eq(c"old-rc4", c"SELECT name FROM library_book WHERE isbn = 'isbn-old-rc4'")
	deploy(plan[2])
	T_TITLE = c"name"
	t_ok(q(c"INSERT INTO library_book (name, author_id, price, isbn) VALUES ('new-rc3', ", ann, c", 1, 'isbn-new-rc3')", 0))
	t_eq(c"NULL", c"SELECT title FROM library_book WHERE isbn = 'isbn-new-rc3'")
	t_bad(q(c"INSERT INTO library_book (title, author_id, price, isbn) VALUES ('old-rc3', ", ann, c", 1, 'isbn-old-rc3')", 0))
	deploy(plan[3])
	assert1(t_column_exists(c"library_book", c"title") == 0)
	t_eq(c"Book 0", c"SELECT name FROM library_book WHERE isbn = 'isbn-' || (SELECT MIN(id) FROM library_book)")
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_tags"))


# Change pages int -> text through pages_new.
void step_change_type():
	orm_change* c = orm_change_new(ORM_CHANGE_ALTER_TYPE, c"library_book", c"pages")
	c.field_json = c"{\"name\":\"pages\",\"column\":\"pages\",\"kind\":4,\"null\":true,\"max_length\":0}"
	c.nullable = 1
	c.batch_size = 3
	list[orm_migration*] plan = plan_change(c)
	assert_equal(4, plan.length)
	deploy(plan[0])
	char* ann = author_id(c"ann@x")
	t_ok(q(c"INSERT INTO library_book (name, author_id, price, isbn, pages) VALUES ('old-ty', ", ann, c", 1, 'isbn-old-ty', 120)", 0))
	t_eq(c"120", c"SELECT pages_new FROM library_book WHERE isbn = 'isbn-old-ty'")
	t_ok(q(c"INSERT INTO library_book (name, author_id, price, isbn, pages_new) VALUES ('new-ty', ", ann, c", 1, 'isbn-new-ty', '77')", 0))
	t_eq(c"77", c"SELECT pages FROM library_book WHERE isbn = 'isbn-new-ty'")
	deploy(plan[1])
	t_eq(c"100", c"SELECT pages_new FROM library_book WHERE name = 'Book 0'")
	t_eq(c"104", c"SELECT pages_new FROM library_book WHERE name = 'Book 4'")
	deploy(plan[2])
	deploy(plan[3])
	assert1(t_column_exists(c"library_book", c"pages") == 0)
	t_eq(c"77", c"SELECT pages_new FROM library_book WHERE isbn = 'isbn-new-ty'")


# price -> nullable, then back to NOT NULL with a backfill.
void step_alter_null():
	orm_change* c = orm_change_new(ORM_CHANGE_ALTER_NULL, c"library_book", c"price")
	c.field_json = field_json(c"Book", c"price")
	c.nullable = 1
	list[orm_migration*] plan = plan_change(c)
	deploy(plan[0])
	t_ok(NEW_BOOK(c"nullprice", c"", c""))
	t_ok(c"UPDATE library_book SET price = NULL WHERE isbn = 'isbn-nullprice'")
	t_bad(c"UPDATE library_book SET price = -5 WHERE isbn = 'isbn-nullprice'")
	orm_backfill_register(c"library_book_price_backfill", price_backfill)
	orm_change* c2 = orm_change_new(ORM_CHANGE_ALTER_NULL, c"library_book", c"price")
	c2.field_json = field_json(c"Book", c"price")
	plan = plan_change(c2)
	assert_equal(2, plan.length)
	deploy(plan[0])
	t_eq(c"0", c"SELECT COUNT(*) FROM library_book WHERE price IS NULL")
	# The newest book is deleted before SET NOT NULL (a 12-step rebuild on
	# SQLite): its id is not handed out again afterwards.
	t_ok(NEW_BOOK(c"gone", c"", c""))
	int gone = t_num(c"SELECT id FROM library_book WHERE isbn = 'isbn-gone'")
	t_ok(c"DELETE FROM library_book WHERE isbn = 'isbn-gone'")
	deploy(plan[1])
	t_ok(NEW_BOOK(c"after-gone", c"", c""))
	assert1(t_num(c"SELECT id FROM library_book WHERE isbn = 'isbn-after-gone'") > gone)
	t_ok(c"DELETE FROM library_book WHERE isbn = 'isbn-after-gone'")
	t_bad(c"UPDATE library_book SET price = NULL WHERE isbn = 'isbn-nullprice'")
	t_bad(c"UPDATE library_book SET price = -5 WHERE isbn = 'isbn-nullprice'")
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_tags"))


# Rebuild library_author (adds bio) with a shadow table, copy, swap.
void step_rebuild_table():
	char* shape = replace(model_json(c"Author"), c"],\"indexes\"", c",{\"name\":\"bio\",\"column\":\"bio\",\"kind\":4,\"null\":true}],\"indexes\"")
	orm_change* c = orm_change_new(ORM_CHANGE_REBUILD_TABLE, c"library_author", 0)
	c.model_json = shape
	c.batch_size = 1
	list[orm_migration*] plan = plan_change(c)
	assert_equal(4, plan.length)
	t_ok(c"INSERT INTO library_author (name, email, created) VALUES ('Cat', 'cat@x', '2026-01-03 00:00:00')")
	deploy(plan[0])
	assert1(t_table_exists(c"library_author__new"))
	t_ok(c"INSERT INTO library_author (name, email, created) VALUES ('Dan', 'dan@x', '2026-01-04 00:00:00')")
	t_eq(c"Dan", c"SELECT name FROM library_author__new WHERE email = 'dan@x'")
	t_ok(c"UPDATE library_author SET name = 'Danny' WHERE email = 'dan@x'")
	t_eq(c"Danny", c"SELECT name FROM library_author__new WHERE email = 'dan@x'")
	char* dan = author_id(c"dan@x")
	t_ok(c"DELETE FROM library_author WHERE email = 'dan@x'")
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM library_author__new WHERE email = 'dan@x'"))
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM library_author__new WHERE email = 'cat@x'"))
	deploy(plan[1])
	t_eq(t_val(c"SELECT COUNT(*) FROM library_author"), c"SELECT COUNT(*) FROM library_author__new")
	char* ann = author_id(c"ann@x")
	deploy(plan[2])
	assert1(t_column_exists(c"library_author", c"bio"))
	assert1(t_column_exists(c"library_author__new", c"bio") == 0)
	assert_strings_equal(ann, author_id(c"ann@x"))
	t_ok(c"INSERT INTO library_author (name, email, created, bio) VALUES ('Eve', 'eve@x', '2026-01-05 00:00:00', 'hi')")
	# Dan (the newest author, deleted while the tables were in sync) does
	# not hand his id to Eve: SQLite's sqlite_sequence and PostgreSQL's
	# sequence keep their high-water mark across the swap.
	assert1(atoi(author_id(c"eve@x")) > atoi(dan))
	# FKs from library_book now point at the rebuilt table.
	char* eve = author_id(c"eve@x")
	t_ok(q(c"INSERT INTO library_book (name, author_id, price, isbn) VALUES ('eve book', ", eve, c", 1, 'isbn-eve')", 0))
	t_ok(q(c"UPDATE library_book SET editor_id = ", eve, c" WHERE isbn = 'isbn-eve'", 0))
	t_bad(c"INSERT INTO library_book (name, author_id, price, isbn) VALUES ('ghost', 999999, 1, 'isbn-ghost')")
	t_ok(c"UPDATE library_book SET editor_id = NULL WHERE isbn = 'isbn-eve'")
	t_ok(c"DELETE FROM library_author WHERE email = 'eve@x'")
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM library_book WHERE isbn = 'isbn-eve'"))
	deploy(plan[3])
	assert1(t_table_exists(c"library_author__new") == 0)


# Drop column (separate and later drop) of a NOT NULL, indexed column; the
# contract migration must not ship in the same deploy as its expand step.
void step_drop_column():
	orm_change* c = orm_change_new(ORM_CHANGE_DROP_COLUMN, c"library_author", c"created")
	c.field_json = field_json(c"Author", c"created")
	list[orm_migration*] plan = plan_change(c)
	assert_equal(2, plan.length)
	list[orm_migration*] both = new list[orm_migration*]
	for orm_migration* m in T_ALL: both.push(m)
	both.push(plan[0])
	both.push(plan[1])
	assert_equal(-1, orm_migrate_apply(T_DB, both, 0))
	assert_contains(orm_db_error(T_DB), c"earlier deploy")
	assert1(orm_migrate_is_applied(T_DB, c"library", plan[0].name) == 0)
	deploy(plan[0])
	t_ok(c"INSERT INTO library_author (name, email) VALUES ('Fay', 'fay@x')")
	t_ok(c"INSERT INTO library_author (name, email, created) VALUES ('Gus', 'gus@x', '2026-01-06 00:00:00')")
	# The swap gave the rebuilt table's index its original name back.
	if (t_pg()): assert_equal(1, t_num(c"SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'library_author_created_idx' AND tablename = 'library_author'"))
	else: assert_equal(1, t_num(c"SELECT COUNT(*) FROM sqlite_master WHERE name = 'library_author_created_idx' AND tbl_name = 'library_author'"))
	t_bad(c"INSERT INTO library_book (name, author_id, price, isbn) VALUES ('ghost', 999999, 1, 'isbn-ghost')")
	deploy(plan[1])
	assert1(t_column_exists(c"library_author", c"created") == 0)
	t_ok(c"INSERT INTO library_author (name, email) VALUES ('Hal', 'hal@x')")
	t_bad(c"INSERT INTO library_author (name, email, created) VALUES ('Ivy', 'ivy@x', '2026-01-06 00:00:00')")


# Create a table, rename it by duplication, then drop it later.
void step_tables():
	orm_change* c = orm_change_new(ORM_CHANGE_CREATE_TABLE, c"library_note", 0)
	c.model_json = c"{\"name\":\"Note\",\"table\":\"library_note\",\"fields\":[{\"name\":\"id\",\"column\":\"id\",\"kind\":1,\"pk\":true,\"auto\":true},{\"name\":\"body\",\"column\":\"body\",\"kind\":4,\"max_length\":100}],\"indexes\":[],\"checks\":[],\"unique_together\":[]}"
	list[orm_migration*] plan = plan_change(c)
	deploy(plan[0])
	t_ok(c"INSERT INTO library_note (body) VALUES ('n1')")
	t_ok(c"INSERT INTO library_note (body) VALUES ('n2')")
	orm_change* r = orm_change_new(ORM_CHANGE_RENAME_TABLE, c"library_note", 0)
	r.new_name = c"library_memo"
	r.model_json = replace(c.model_json, c"library_note", c"library_memo")
	r.batch_size = 1
	plan = plan_change(r)
	assert_equal(4, plan.length)
	deploy(plan[0])
	t_ok(c"INSERT INTO library_note (body) VALUES ('old-n3')")
	t_eq(c"1", c"SELECT COUNT(*) FROM library_memo WHERE body = 'old-n3'")
	t_ok(c"INSERT INTO library_memo (body) VALUES ('new-m1')")
	t_eq(c"1", c"SELECT COUNT(*) FROM library_note WHERE body = 'new-m1'")
	assert_equal(0, t_num(c"SELECT COUNT(*) FROM (SELECT id FROM library_note GROUP BY id HAVING COUNT(*) > 1) d"))
	t_eq(t_val(c"SELECT id FROM library_note WHERE body = 'new-m1'"), c"SELECT id FROM library_memo WHERE body = 'new-m1'")
	t_ok(c"UPDATE library_memo SET body = 'new-m1b' WHERE body = 'new-m1'")
	t_eq(c"1", c"SELECT COUNT(*) FROM library_note WHERE body = 'new-m1b'")
	t_ok(c"DELETE FROM library_note WHERE body = 'old-n3'")
	t_eq(c"0", c"SELECT COUNT(*) FROM library_memo WHERE body = 'old-n3'")
	deploy(plan[1])
	t_eq(c"3", c"SELECT COUNT(*) FROM library_memo")
	deploy(plan[2])
	t_ok(c"INSERT INTO library_memo (body) VALUES ('new-m2')")
	t_eq(c"0", c"SELECT COUNT(*) FROM library_note WHERE body = 'new-m2'")
	deploy(plan[3])
	assert1(t_table_exists(c"library_note") == 0)
	orm_change* d = orm_change_new(ORM_CHANGE_DROP_TABLE, c"library_memo", 0)
	plan = plan_change(d)
	assert_equal(2, plan.length)
	deploy(plan[0])
	assert1(t_table_exists(c"library_memo"))
	deploy(plan[1])
	assert1(t_table_exists(c"library_memo") == 0)


# The history tables followed every change above (U3.3): added and
# renamed columns are tracked, dropped ones keep their old values, the
# SQLite rebuilds kept the triggers, and the library_author swap moved them
# to the rebuilt table.
char* t_last_hist(char* table, char* column, char* where):
	return t_val(q(q(c"SELECT ", column, c" FROM ", table), c"_history WHERE ", where, c" ORDER BY history_id DESC LIMIT 1"))


void step_history_in_step():
	assert1(t_column_exists(c"library_book_history", c"isbn"))
	assert1(t_column_exists(c"library_book_history", c"name"))
	assert1(t_column_exists(c"library_book_history", c"pages_new"))
	assert1(t_column_exists(c"library_book_history", c"title"))
	assert1(t_column_exists(c"library_book_history", c"pages"))
	assert1(t_num(c"SELECT COUNT(*) FROM library_book_history WHERE title = 'Book 0'") > 0)
	t_ok(c"UPDATE library_book SET name = 'renamed' WHERE isbn = 'isbn-new3'")
	assert_strings_equal(c"renamed", t_last_hist(c"library_book", c"name", c"isbn = 'isbn-new3'"))
	assert_strings_equal(c"~", t_last_hist(c"library_book", c"history_type", c"isbn = 'isbn-new3'"))
	assert_strings_equal(c"NULL", t_last_hist(c"library_book", c"title", c"isbn = 'isbn-new3'"))
	t_ok(c"DELETE FROM library_book WHERE isbn = 'isbn-new3'")
	assert_strings_equal(c"-", t_last_hist(c"library_book", c"history_type", c"isbn = 'isbn-new3'"))
	# Rows written before and after the library_author swap.
	assert_equal(2, t_num(c"SELECT COUNT(*) FROM library_author_history WHERE email = 'eve@x'"))
	assert1(t_num(c"SELECT COUNT(*) FROM library_author_history WHERE email = 'dan@x'") >= 2)
	t_ok(c"INSERT INTO library_author (name, email) VALUES ('Jan', 'jan@x')")
	assert_strings_equal(c"+", t_last_hist(c"library_author", c"history_type", c"email = 'jan@x'"))
	# The rebuild added bio; CREATE_HISTORY again (every live column) tracks it.
	assert1(t_column_exists(c"library_author_history", c"bio") == 0)
	orm_migration* h = hand_migration(c"author_history_again")
	orm_migration_add(h, orm_op_new(ORM_OP_CREATE_HISTORY, ORM_PHASE_EXPAND, c"library_author"))
	deploy(h)
	assert1(t_column_exists(c"library_author_history", c"bio"))
	t_ok(c"UPDATE library_author SET bio = 'b' WHERE email = 'jan@x'")
	assert_strings_equal(c"b", t_last_hist(c"library_author", c"bio", c"email = 'jan@x'"))
	# Unapplying CREATE_HISTORY drops the history table (DROP_HISTORY).
	asserts(orm_db_error(T_DB), orm_migrate_unapply(T_DB, h))
	assert1(t_table_exists(c"library_author_history") == 0)
	t_ok(c"UPDATE library_author SET bio = 'c' WHERE email = 'jan@x'")
	assert_equal(1, t_apply(T_ALL, 0))
	assert1(t_table_exists(c"library_author_history"))
	# RENAME_TABLE takes the history table along.
	orm_migration* d = hand_migration(c"draft_history")
	orm_op* cd = orm_op_new(ORM_OP_RAW_SQL, ORM_PHASE_EXPAND, c"library_draft")
	cd.sql = c"CREATE TABLE library_draft (id INTEGER PRIMARY KEY, body TEXT)"
	orm_migration_add(d, cd)
	orm_migration_add(d, orm_op_new(ORM_OP_CREATE_HISTORY, ORM_PHASE_EXPAND, c"library_draft"))
	deploy(d)
	t_ok(c"INSERT INTO library_draft (id, body) VALUES (1, 'a')")
	orm_migration* rn = hand_migration(c"rename_draft")
	orm_op* ro = orm_op_new(ORM_OP_RENAME_TABLE, ORM_PHASE_EXPAND, c"library_sketch")
	ro.source_table = c"library_draft"
	orm_migration_add(rn, ro)
	T_ALL.push(rn)
	assert_equal(1, t_apply(T_ALL, 1))
	assert1(t_table_exists(c"library_draft_history") == 0)
	t_ok(c"UPDATE library_sketch SET body = 'b'")
	t_ok(c"DELETE FROM library_sketch")
	assert_equal(3, t_num(c"SELECT COUNT(*) FROM library_sketch_history"))
	t_eq(c"b", c"SELECT body FROM library_sketch_history WHERE history_type = '-'")


void run_apply_scenario(orm_db* db):
	T_DB = db
	T_DIALECT = orm_mx_dialect_of(db)
	T_NEXT = 1
	T_PREV = 0
	T_ALL = new list[orm_migration*]
	T_TITLE = c"title"
	step_initial()
	step_lint_and_force()
	step_add_column()
	step_unique_check_fk_index()
	step_rename_column()
	step_change_type()
	step_alter_null()
	step_rebuild_table()
	step_drop_column()
	step_tables()
	assert_equal(0, t_apply(T_ALL, 0))
	char* status = orm_migrate_status(T_DB, T_ALL)
	assert1(contains(status, c"[ ]") == 0)
	assert1(contains(status, c"[?]") == 0)
	char* none = orm_migrate_sql(T_DB, T_ALL, 0)
	asserts(orm_db_error(T_DB), none != 0)
	assert_strings_equal(c"", none)
	step_history_in_step()


# ---------------------------------------------------------------------------
# Writer round trip: what orm_makemigrations plans for the library fixture
# applies cleanly, then a type change (table rebuild) and a hinted rename of
# a referenced table (which rebuilds the through table). The initial
# migration's CREATE_HISTORY for library_book applies as planned, and the
# history follows the rebuild.


void lint_clean(orm_migration* m):
	list[orm_lint_finding*] findings = orm_lint_migration(m, T_DIALECT)
	if (orm_lint_count(findings, ORM_LINT_ERROR) > 0): println2(orm_lint_format(findings))
	assert_equal(0, orm_lint_count(findings, ORM_LINT_ERROR))


void deploy_all(list[orm_migration*] ms):
	for orm_migration* m in ms:
		lint_clean(m)
		deploy(m)


void run_makemigrations_roundtrip(orm_db* db):
	T_DB = db
	T_DIALECT = orm_mx_dialect_of(db)
	T_ALL = new list[orm_migration*]
	char* s0 = library_schema_json()
	orm_makemig* r = orm_makemigrations(c"library", 0, s0, T_DIALECT, 1, 0, 0)
	asserts(r.error, r.error == 0)
	assert_equal(1, r.migrations.length)
	deploy_all(r.migrations)
	assert1(t_table_exists(c"library_book_tags"))
	t_ok(c"INSERT INTO library_author (name, email, created) VALUES ('Ann', 'ann@x', '2026-01-01 00:00:00')")
	t_ok(c"INSERT INTO library_tag (name) VALUES ('sf')")
	t_ok(c"INSERT INTO library_tag (name) VALUES ('noir')")
	char* ann = author_id(c"ann@x")
	for i in range(3):
		t_ok(q(c"INSERT INTO library_book (title, author_id, price) VALUES ('RT ", itoa(i), c"', ", q(ann, c", 2)", 0, 0)))
	t_ok(c"INSERT INTO library_book_tags (book_id, tag_id) SELECT b.id, t.id FROM library_book b, library_tag t")
	t_bad(c"INSERT INTO library_book_tags (book_id, tag_id) SELECT b.id, t.id FROM library_book b, library_tag t WHERE b.title = 'RT 0'")
	# Longer title: the autodetector rebuilds library_book.
	char* s1 = replace(s0, c"\"max_length\":300", c"\"max_length\":400")
	orm_makemig* r1 = orm_makemigrations_next(c"library", T_ALL, s1, T_DIALECT, 0)
	asserts(r1.error, r1.error == 0)
	assert1(r1.migrations.length >= 4)
	deploy_all(r1.migrations)
	assert1(t_table_exists(c"library_book__new") == 0)
	assert_equal(3, t_num(c"SELECT COUNT(*) FROM library_book"))
	assert_equal(6, t_num(c"SELECT COUNT(*) FROM library_book_tags"))
	if (t_pg()): t_eq(c"character varying(400)", c"SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = to_regclass('library_book') AND attname = 'title'")
	else: assert_contains(t_val(c"SELECT sql FROM sqlite_master WHERE name = 'library_book'"), c"VARCHAR(400)")
	t_ok(q(c"INSERT INTO library_book (title, author_id, price) VALUES ('RT 3', ", ann, c", 2)", 0))
	t_bad(c"INSERT INTO library_book (title, author_id, price) VALUES ('RT ghost', 999999, 2)")
	t_ok(c"DELETE FROM library_book WHERE title = 'RT 2'")
	assert_equal(4, t_num(c"SELECT COUNT(*) FROM library_book_tags"))
	# History survived the rebuild and tracks the rebuilt table.
	assert_equal(4, t_num(c"SELECT COUNT(*) FROM library_book_history WHERE history_type = '+'"))
	assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_history WHERE history_type = '-' AND title = 'RT 2'"))
	if (t_pg()):
		t_eq(c"character varying(400)", c"SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = to_regclass('library_book_history') AND attname = 'title'")
		t_ok(q(c"INSERT INTO library_book (title, author_id, price) VALUES (repeat('x', 350), ", ann, c", 2)", 0))
		assert_equal(1, t_num(c"SELECT COUNT(*) FROM library_book_history WHERE length(title) = 350"))
		t_ok(c"DELETE FROM library_book WHERE length(title) = 350")
	if (t_pg()): assert_equal(1, t_num(c"SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'library_book_author_id_idx' AND tablename = 'library_book' AND schemaname = current_schema()"))
	else: assert_equal(1, t_num(c"SELECT COUNT(*) FROM sqlite_master WHERE name = 'library_book_author_id_idx' AND tbl_name = 'library_book'"))
	# Rename library_tag (referenced by the through table) with a hint.
	char* s2 = replace(s1, c"\"table\":\"library_tag\"", c"\"table\":\"library_label\"")
	list[char*] hints = new list[char*]
	hints.push(c"library_tag->library_label")
	orm_makemig* r2 = orm_makemigrations_next(c"library", T_ALL, s2, T_DIALECT, hints)
	asserts(r2.error, r2.error == 0)
	deploy_all(r2.migrations)
	assert1(t_table_exists(c"library_tag") == 0)
	assert1(t_table_exists(c"library_book_tags__new") == 0)
	assert_equal(2, t_num(c"SELECT COUNT(*) FROM library_label"))
	assert_equal(4, t_num(c"SELECT COUNT(*) FROM library_book_tags"))
	t_ok(c"INSERT INTO library_label (name) VALUES ('poetry')")
	t_ok(c"INSERT INTO library_book_tags (book_id, tag_id) SELECT b.id, t.id FROM library_book b, library_label t WHERE t.name = 'poetry' AND b.title = 'RT 0'")
	t_bad(c"INSERT INTO library_book_tags (book_id, tag_id) SELECT id, 999999 FROM library_book WHERE title = 'RT 0'")
	t_ok(c"DELETE FROM library_label WHERE name = 'poetry'")
	assert_equal(4, t_num(c"SELECT COUNT(*) FROM library_book_tags"))
	# Converged: nothing left to plan.
	orm_makemig* r3 = orm_makemigrations_next(c"library", T_ALL, s2, T_DIALECT, 0)
	asserts(r3.error, r3.error == 0)
	assert_equal(0, r3.migrations.length)
	assert_equal(0, t_apply(T_ALL, 0))
