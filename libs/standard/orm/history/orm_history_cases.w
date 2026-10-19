# Shared scenario for orm_history_sqlite_test and orm_history_postgres_test
# (issue #754, unit U3.3; docs/projects/orm/u3_3.md).
#
# The library schema comes from the migration orm_makemigrations plans for
# the generated snapshot (its CREATE_HISTORY for library_book included).
# Then every kind of write lands in library_book_history: save, queryset
# update, bulk_create, bulk_update, raw SQL on the same connection and on
# a second one, with and without a context; and the history API reads,
# diffs, reverts and prunes it.
import tests.orm.generated.library_orm_api
import libs.standard.orm.history.history
import libs.standard.orm.migrate.apply
import libs.standard.orm.migrate.autodetect
import lib.assert
import lib.time


orm_db* H_DB


list[char*] names_of(char* a):
	list[char*] l = new list[char*]
	l.push(a)
	return l


char* q_text(char* a, char* b, char* c2):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	string_append(s, c2)
	return s.data


void h_check(int ok):
	asserts(orm_db_error(H_DB), ok)


void h_exec(orm_db* db, char* sql):
	int ok = orm_db_exec_sql(db, sql)
	if (ok == 0): println(sql)
	asserts(orm_db_error(db), ok)


# First cell of the first row, "" for no row, "NULL" for SQL NULL.
char* h_val(char* sql):
	sql_result* r = sql_query(H_DB.conn, sql)
	if (r == 0): println(sql)
	asserts(sql_error(H_DB.conn), r != 0)
	char* out = c""
	if (r.rows > 0):
		if (sql_value(r, 0, 0) == 0): out = c"NULL"
		else: out = strclone(sql_value(r, 0, 0))
	sql_result_free(r)
	return out


int h_num(char* sql):
	return atoi(h_val(sql))


int h_count(char* where):
	string_builder* b = string_new()
	string_append(b, c"SELECT COUNT(*) FROM library_book_history WHERE ")
	string_append(b, where)
	return h_num(b.data)


# The newest history row's `column` for book `id`.
char* h_last(int id, char* column):
	string_builder* b = string_new()
	string_append(b, c"SELECT ")
	string_append(b, column)
	string_append(b, c" FROM library_book_history WHERE id = ")
	string_append_int(b, id)
	string_append(b, c" ORDER BY history_id DESC LIMIT 1")
	return h_val(b.data)


int h_versions(int id):
	string_builder* b = string_new()
	string_append(b, c"id = ")
	string_append_int(b, id)
	return h_count(b.data)


char* h_title(int id):
	string_builder* b = string_new()
	string_append(b, c"SELECT title FROM library_book WHERE id = ")
	string_append_int(b, id)
	return h_val(b.data)


Book* h_book(char* title, Author* a, char* price, int pages):
	Book* b = Book_new()
	b.title = title
	b.author_id = a.id
	b.price = price
	b.pages = pages
	return b


# Newest history_date so far: a point in time between two writes (the
# caller sleeps before the next write, history_date has ms resolution).
char* h_now():
	char* t = h_val(c"SELECT MAX(history_date) FROM library_book_history")
	sleep_ms(15)
	return t


void h_schema(orm_db* db):
	int dialect = orm_mx_dialect_of(db)
	orm_makemig* r = orm_makemigrations(c"library", 0, library_schema_json(), dialect, 1, 0, 0)
	asserts(r.error, r.error == 0)
	assert_equal(1, r.migrations.length)
	int saw = 0
	for orm_op* op in r.migrations[0].ops:
		if (op.kind == ORM_OP_CREATE_HISTORY): saw = saw + 1
	assert_equal(1, saw)
	char* sql = orm_migrate_sql(db, r.migrations, 0)
	asserts(orm_db_error(db), sql != 0)
	assert_contains(sql, c"CREATE TABLE \"library_book_history\"")
	assert_contains(sql, c"\"history_context_id\"")
	int n = orm_migrate_apply(db, r.migrations, 0)
	if (n != 1): println(orm_db_error(db))
	assert_equal(1, n)
	# All model columns, history columns, no m2m.
	assert_equal(0, h_count(c"1 = 1"))
	h_exec(db, c"SELECT id, title, author_id, status, price, pages, published_at, history_id, history_date, history_type, history_user_id, history_reason, history_context_id FROM library_book_history")


struct h_state:
	Author* ann
	char* ctx
	Book* dune
	Book* emma
	Book* ivan
	char* t_dune_v1
	int hid_dune_v1


void h_saves(orm_db* db, h_state* s):
	s.ctx = orm_history_set_context(db, 7, c"import")
	asserts(orm_db_error(db), s.ctx != 0)
	assert1(strlen(s.ctx) >= 16)
	assert_contains(db.history_context, s.ctx)
	assert_contains(db.history_context, c"\"user_id\":7")
	s.ann = Author_new()
	s.ann.name = c"Ann"
	s.ann.email = c"ann@x"
	h_check(Author_save(db, s.ann))
	# save(): insert, unchanged save (no row), change.
	s.dune = h_book(c"Dune", s.ann, c"9.99", 412)
	h_check(Book_save(db, s.dune))
	assert_equal(1, h_versions(s.dune.id))
	assert_strings_equal(c"+", h_last(s.dune.id, c"history_type"))
	assert_strings_equal(c"7", h_last(s.dune.id, c"history_user_id"))
	assert_strings_equal(c"import", h_last(s.dune.id, c"history_reason"))
	assert_strings_equal(s.ctx, h_last(s.dune.id, c"history_context_id"))
	assert_strings_equal(c"Dune", h_last(s.dune.id, c"title"))
	h_check(Book_save(db, s.dune))
	assert_equal(1, h_versions(s.dune.id))
	s.t_dune_v1 = h_now()
	s.hid_dune_v1 = atoi(h_last(s.dune.id, c"history_id"))
	s.dune.title = c"Dune (revised)"
	h_check(Book_save(db, s.dune))
	assert_equal(2, h_versions(s.dune.id))
	assert_strings_equal(c"~", h_last(s.dune.id, c"history_type"))
	assert_strings_equal(c"Dune (revised)", h_last(s.dune.id, c"title"))


void h_bulk_and_raw(orm_db* db, h_state* s):
	# bulk_create: one '+' row per object.
	s.emma = h_book(c"Emma", s.ann, c"5", 300)
	s.ivan = h_book(c"Ivanhoe", s.ann, c"6", 400)
	list[void*] rows = new list[void*]
	rows.push(s.emma)
	rows.push(s.ivan)
	assert_equal(2, orm_bulk_create(db, Book_desc(), rows, 0, 0))
	assert_equal(1, h_versions(s.emma.id))
	assert_equal(1, h_versions(s.ivan.id))
	# bulk_update: only the row whose value changed gets a version.
	s.emma.pages = 301
	assert_equal(2, orm_bulk_update(db, Book_desc(), rows, names_of(c"pages"), 0))
	assert_equal(2, h_versions(s.emma.id))
	assert_equal(1, h_versions(s.ivan.id))
	assert_strings_equal(c"301", h_last(s.emma.id, c"pages"))
	# queryset update(): every matched row, still with the context.
	assert_equal(3, Book_objects(db).filter(q(c"author__email", c"ann@x")).update(c"status", val(c"pub")))
	assert_equal(3, h_count(c"history_type = '~' AND status = 'pub'"))
	assert_strings_equal(c"7", h_last(s.ivan.id, c"history_user_id"))
	# Raw SQL on this connection: captured, with the context.
	h_exec(db, c"UPDATE library_book SET published_at = '2026-01-02 03:04:05' WHERE title = 'Emma'")
	assert_equal(4, h_versions(s.emma.id))
	assert_strings_equal(s.ctx, h_last(s.emma.id, c"history_context_id"))
	# A no-op raw update writes nothing.
	h_exec(db, c"UPDATE library_book SET pages = pages")
	assert_equal(4, h_versions(s.emma.id))
	assert_equal(3, h_count(c"history_context_id IS NOT NULL AND history_type = '+'"))


# Writes from a connection that never set a context, and after clearing it.
void h_no_context(orm_db* db, orm_db* other, h_state* s):
	h_exec(other, c"UPDATE library_book SET pages = 999 WHERE title = 'Ivanhoe'")
	assert_equal(3, h_versions(s.ivan.id))
	assert_strings_equal(c"999", h_last(s.ivan.id, c"pages"))
	assert_strings_equal(c"NULL", h_last(s.ivan.id, c"history_user_id"))
	assert_strings_equal(c"NULL", h_last(s.ivan.id, c"history_context_id"))
	h_check(orm_history_clear_context(db))
	assert1(db.history_context == 0)
	h_exec(db, c"UPDATE library_book SET pages = 400 WHERE title = 'Ivanhoe'")
	assert_strings_equal(c"NULL", h_last(s.ivan.id, c"history_user_id"))
	assert_strings_equal(c"NULL", h_last(s.ivan.id, c"history_reason"))
	# An explicit context id, no user.
	h_check(orm_history_set_context_id(db, c"req-42", 0, c"it's \"quoted\""))
	h_exec(db, c"UPDATE library_book SET pages = 401 WHERE title = 'Ivanhoe'")
	assert_strings_equal(c"req-42", h_last(s.ivan.id, c"history_context_id"))
	assert_strings_equal(c"NULL", h_last(s.ivan.id, c"history_user_id"))
	assert_strings_equal(c"it's \"quoted\"", h_last(s.ivan.id, c"history_reason"))


# A context set inside a transaction (transaction-local on PostgreSQL) is
# republished by orm_db.on_begin at the next outermost BEGIN.
void h_per_transaction(orm_db* db, h_state* s):
	orm_atomic_block* b = orm_atomic_begin(db)
	h_check(b != 0)
	h_check(orm_history_set_context_id(db, c"tx-1", 5, c"in a transaction"))
	h_exec(db, c"UPDATE library_book SET pages = 402 WHERE title = 'Ivanhoe'")
	h_check(orm_atomic_commit(db, b))
	assert_strings_equal(c"tx-1", h_last(s.ivan.id, c"history_context_id"))
	b = orm_atomic_begin(db)
	h_check(b != 0)
	h_exec(db, c"UPDATE library_book SET pages = 403 WHERE title = 'Ivanhoe'")
	h_check(orm_atomic_commit(db, b))
	assert_strings_equal(c"tx-1", h_last(s.ivan.id, c"history_context_id"))
	assert_strings_equal(c"5", h_last(s.ivan.id, c"history_user_id"))


void h_read_diff(orm_db* db, h_state* s):
	orm_result* r = Book_history(db, s.dune)
	asserts(orm_db_error(db), r != 0)
	list[orm_history_entry*] es = orm_history_entries(r)
	assert_equal(3, es.length)
	orm_history_entry* newest = es[0]
	orm_history_entry* mid = es[1]
	orm_history_entry* oldest = es[2]
	assert1(newest.history_id > mid.history_id && mid.history_id > oldest.history_id)
	assert_equal(ORM_HISTORY_UPDATE, newest.type)
	assert_equal(ORM_HISTORY_INSERT, oldest.type)
	assert_equal(7, oldest.user_id)
	assert_equal(0, oldest.user_isnull)
	assert_strings_equal(c"import", oldest.reason)
	assert_strings_equal(s.ctx, oldest.context_id)
	assert1(strlen(oldest.date) >= 19)
	assert_strings_equal(c"Dune", Book_history_row(oldest).title)
	assert_strings_equal(c"Dune (revised)", Book_history_row(mid).title)
	assert_equal(s.dune.id, Book_history_row(oldest).id)
	assert_equal(412, Book_history_row(oldest).pages)
	assert_strings_equal(c"9.99", Book_history_row(oldest).price)
	assert_strings_equal(c"draft", Book_history_row(oldest).status)
	# diff: title between v1 and v2, status between v2 and v3.
	list[orm_history_change*] d = orm_history_diff(oldest, mid)
	assert_equal(1, d.length)
	assert_strings_equal(c"title", d[0].field)
	assert_strings_equal(c"Dune", d[0].old_value)
	assert_strings_equal(c"Dune (revised)", d[0].new_value)
	orm_history_diff_free(d)
	d = orm_history_diff(mid, newest)
	assert_equal(1, d.length)
	assert_strings_equal(c"status", d[0].field)
	assert_strings_equal(c"pub", d[0].new_value)
	orm_history_diff_free(d)
	# Against nothing: every non-NULL field (published_at is NULL).
	d = orm_history_diff(0, oldest)
	assert_equal(5, d.length)
	assert_strings_equal(c"author", d[1].field)
	assert1(d[1].old_value == 0)
	orm_history_diff_free(d)
	# Changeset rows of the first context.
	orm_result* cs = orm_history_context_rows(db, Book_desc(), s.ctx)
	asserts(orm_db_error(db), cs != 0)
	assert_equal(h_count(q_text(c"history_context_id = '", s.ctx, c"'")), orm_history_entries(cs).length)
	orm_result_free(cs)
	# as_of: the state just after v1, and before anything existed.
	orm_result* past = Book_as_of(db, s.t_dune_v1)
	asserts(orm_db_error(db), past != 0)
	assert_equal(1, past.rows.length)
	assert_strings_equal(c"Dune", Book_rows(past)[0].title)
	orm_result_free(past)
	orm_result* none = Book_as_of(db, c"2000-01-01 00:00:00")
	assert_equal(0, none.rows.length)
	orm_result_free(none)
	orm_result* now = Book_as_of(db, c"2999-01-01 00:00:00")
	assert_equal(3, now.rows.length)
	orm_result_free(now)
	orm_result_free(r)


void h_revert(orm_db* db, h_state* s):
	h_check(orm_history_set_context_id(db, c"revert-1", 3, c"revert"))
	orm_result* r = Book_history(db, s.dune)
	list[orm_history_entry*] es = orm_history_entries(r)
	orm_history_entry* v1 = es[es.length - 1]
	assert_equal(s.hid_dune_v1, v1.history_id)
	h_check(orm_history_revert(db, v1))
	assert_strings_equal(c"Dune", h_title(s.dune.id))
	assert_strings_equal(c"draft", h_val(q_text(c"SELECT status FROM library_book WHERE id = ", itoa(s.dune.id), c"")))
	assert_strings_equal(c"~", h_last(s.dune.id, c"history_type"))
	assert_strings_equal(c"3", h_last(s.dune.id, c"history_user_id"))
	orm_result_free(r)
	# Delete, then revert the delete entry: the row comes back, same id.
	int emma = s.emma.id
	h_check(Book_delete(db, s.emma))
	s.emma.id = emma
	assert_strings_equal(c"", h_title(s.emma.id))
	assert_strings_equal(c"-", h_last(s.emma.id, c"history_type"))
	orm_result* er = Book_history(db, s.emma)
	orm_history_entry* del = orm_history_entries(er)[0]
	assert_equal(ORM_HISTORY_DELETE, del.type)
	h_check(orm_history_revert(db, del))
	assert_strings_equal(c"Emma", h_title(s.emma.id))
	assert_strings_equal(c"2026-01-02 03:04:05", h_val(q_text(c"SELECT published_at FROM library_book WHERE id = ", itoa(s.emma.id), c"")))
	assert_strings_equal(c"+", h_last(s.emma.id, c"history_type"))
	orm_result_free(er)


# One context creates, changes and deletes; reverting it undoes all three
# and leaves writes of other contexts alone.
void h_changeset(orm_db* db, h_state* s):
	char* ctx = orm_history_set_context(db, 9, c"batch")
	asserts(orm_db_error(db), ctx != 0)
	Book* x = h_book(c"Xanadu", s.ann, c"1", 10)
	h_check(Book_save(db, x))
	s.dune.title = c"Dune (batch)"
	h_check(Book_save(db, s.dune))
	s.dune.title = c"Dune (batch 2)"
	h_check(Book_save(db, s.dune))
	int ivan = s.ivan.id
	h_check(Book_delete(db, s.ivan))
	s.ivan.id = ivan
	int other_before = h_versions(s.emma.id)
	assert_equal(3, h_count(q_text(c"history_context_id = '", ctx, c"' AND history_type IN ('+', '-')")) + h_count(q_text(c"history_context_id = '", ctx, c"' AND history_type = '~' AND title = 'Dune (batch)'")))
	h_check(orm_history_set_context_id(db, c"undo", 1, c"undo batch"))
	assert_equal(3, orm_history_revert_changeset(db, ctx))
	assert_strings_equal(c"", h_title(x.id))
	assert_strings_equal(c"Dune", h_title(s.dune.id))
	assert_strings_equal(c"Ivanhoe", h_title(s.ivan.id))
	assert_strings_equal(c"401", h_val(q_text(c"SELECT pages FROM library_book WHERE id = ", itoa(s.ivan.id), c"")))
	assert_equal(other_before, h_versions(s.emma.id))
	assert_strings_equal(c"undo", h_last(s.ivan.id, c"history_context_id"))
	assert_equal(3, h_count(c"history_context_id = 'undo'"))
	# Reverting a context that wrote nothing is a no-op.
	assert_equal(0, orm_history_revert_changeset(db, c"no-such-context"))
	assert_equal(-1, orm_history_revert_changeset(db, cast(char*, 0)))


void h_prune(orm_db* db):
	int total = h_count(c"1 = 1")
	assert1(total > 10)
	assert_equal(0, Book_prune_history(db, c"2000-01-01 00:00:00"))
	assert_equal(total, Book_prune_history(db, c"2999-01-01 00:00:00"))
	assert_equal(0, h_count(c"1 = 1"))
	assert_equal(-1, orm_history_prune(db, Book_desc(), cast(char*, 0)))
	# Pruned objects have no past; new writes start a fresh history.
	orm_result* past = Book_as_of(db, c"2999-01-01 00:00:00")
	assert_equal(0, past.rows.length)
	orm_result_free(past)
	h_exec(db, c"UPDATE library_book SET pages = pages + 1")
	assert_equal(3, h_count(c"history_type = '~'"))


# `other` is a second connection to the same database.
void run_history_cases(orm_db* db, orm_db* other):
	H_DB = db
	library_register()
	h_schema(db)
	h_state* s = new h_state()
	h_saves(db, s)
	h_bulk_and_raw(db, s)
	h_no_context(db, other, s)
	h_read_diff(db, s)
	h_revert(db, s)
	h_changeset(db, s)
	h_per_transaction(db, s)
	h_prune(db)
	h_check(orm_history_clear_context(db))
