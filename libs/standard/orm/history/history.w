# w-orm trigger-based history: context, queries, diff, revert, prune
# (issue #754, unit U3.3; docs/projects/orm/u3_3.md).
#
# The rows themselves are written by database triggers that CREATE_HISTORY
# installs (history/ddl.w), so saves, queryset update(), bulk writes and raw
# SQL are all captured. This module tells the triggers who is writing and
# reads the history back:
#
#   char* ctx = orm_history_set_context(db, user.id, c"bulk import")  # context id
#   ... writes ...
#   orm_result* r = Book_history(db, book)          # newest first
#   for orm_history_entry* e in orm_history_entries(r): ... Book_history_row(e) ...
#   list[orm_history_change*] d = orm_history_diff(older, newer)
#   orm_history_revert(db, e)                       # object back to e's state
#   orm_history_revert_changeset(db, ctx)           # undo everything ctx wrote
#   orm_result* past = Book_as_of(db, c"2026-10-19 12:00:00")
#   int n = orm_history_prune(db, Book_desc(), c"2026-01-01 00:00:00")
import libs.standard.orm.orm
import structures.json


# One history row. `row` is a model row (T*) holding the tracked columns as
# they were; fields the history does not track (no_history) are zero.
struct orm_history_entry:
	orm_model_desc* model
	int history_id
	char* date               # UTC text, "YYYY-MM-DD HH:MM:SS[.fff]"
	int type                 # ORM_HISTORY_INSERT / UPDATE / DELETE
	int user_id
	int user_isnull
	char* reason             # 0 = none
	char* context_id         # 0 = written without a context
	void* row


# One changed field between two versions; values are database text, 0 =
# SQL NULL.
struct orm_history_change:
	char* field
	char* old_value
	char* new_value


list[orm_history_entry*] orm_history_entries(orm_result* r):
	return cast(list[orm_history_entry*], r.rows)


char* orm_history_cat(char* a, char* b):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	char* out = s.data
	free(cast(void*, s))
	return out


char* orm_history_table(orm_model_desc* m):
	return orm_history_cat(m.table, ORM_HISTORY_SUFFIX())


int orm_history_is_pg(orm_db* db):
	return db.dialect != 0 && db.dialect.id == ORM_DIALECT_POSTGRES


sql_builder* orm_history_builder(orm_db* db):
	return sql_builder_new(db.dialect.bind_style)


# Executes and frees the builder; 1 when it ran.
int orm_history_run(orm_db* db, sql_builder* b):
	sql_result* r = orm_db_execute(db, b)
	sql_builder_free(b)
	if (r == 0): return 0
	sql_result_free(r)
	return 1


# First cell of the first row (owned), or 0.
char* orm_history_scalar(orm_db* db, sql_builder* b):
	sql_result* r = orm_db_execute(db, b)
	sql_builder_free(b)
	if (r == 0): return 0
	char* out = 0
	if (r.rows > 0 && sql_value(r, 0, 0) != 0): out = strclone(sql_value(r, 0, 0))
	sql_result_free(r)
	return out


# Fields with a column that the history table tracks.
int orm_history_tracks(orm_field_desc* f):
	if (orm_field_has_column(f) == 0 || f.offset < 0): return 0
	return (f.flags & (ORM_F_NO_HISTORY | ORM_F_DEPRECATED)) == 0


# ---------------------------------------------------------------------------
# Context (contract C8)

char* orm_history_json_text(char* s):
	if (s == 0): return strclone(c"null")
	string_builder* b = string_new()
	json_append_escaped_string(b, s)
	char* out = b.data
	free(cast(void*, b))
	return out


# Publishes db.history_context to the connection. PostgreSQL:
# set_config('w_orm.context', json, is_local) with is_local while a
# transaction is open (db.atomic_depth > 0), so it ends with that
# transaction, and session-wide otherwise (until cleared). SQLite: the row
# of the TEMP table _w_orm_context, plus a TEMP trigger per history table
# that copies it into each new history row (main-schema triggers cannot
# read TEMP tables). Call it again after migrations create history tables
# in this connection. Returns 1, or 0 with orm_db_error set.
int orm_history_publish(orm_db* db):
	char* json = db.history_context
	if (orm_history_is_pg(db)):
		sql_builder* b = orm_history_builder(db)
		sql_builder_append(b, c"SELECT set_config('w_orm.context', ")
		if (json != 0): sql_builder_bind(b, json)
		else: sql_builder_bind(b, c"")
		if (db.atomic_depth > 0): sql_builder_append(b, c", true)")
		else: sql_builder_append(b, c", false)")
		return orm_history_run(db, b)
	char* table = ORM_HISTORY_SQLITE_CONTEXT_TABLE()
	if (orm_db_exec_sql(db, c"CREATE TEMP TABLE IF NOT EXISTS _w_orm_context (context_id TEXT, user_id INTEGER, reason TEXT)") == 0): return 0
	if (orm_db_exec_sql(db, c"DELETE FROM temp._w_orm_context") == 0): return 0
	if (json != 0):
		json_value* v = json_parse(json)
		if (v == 0): return orm_db_set_error(db, c"orm history: db.history_context is not JSON")
		sql_builder* ib = orm_history_builder(db)
		sql_builder_append(ib, c"INSERT INTO temp.")
		sql_builder_identifier(ib, table)
		sql_builder_append(ib, c" (context_id, user_id, reason) VALUES (")
		json_value* cid = json_object_get(v, c"context_id")
		json_value* uid = json_object_get(v, c"user_id")
		json_value* why = json_object_get(v, c"reason")
		if (cid != 0 && cid.type == json_type_string()): sql_builder_bind(ib, cid.string_value)
		else: sql_builder_bind(ib, 0)
		sql_builder_append(ib, c", ")
		if (uid != 0 && uid.type == json_type_int()):
			char* t = itoa(uid.int_value)
			sql_builder_bind(ib, t)
		else: sql_builder_bind(ib, 0)
		sql_builder_append(ib, c", ")
		if (why != 0 && why.type == json_type_string()): sql_builder_bind(ib, why.string_value)
		else: sql_builder_bind(ib, 0)
		sql_builder_append(ib, c")")
		json_free(v)
		if (orm_history_run(db, ib) == 0): return 0
	sql_result* r = sql_query(db.conn, c"SELECT m.name FROM sqlite_master m WHERE m.type = 'table' AND m.name LIKE '%history' AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) p WHERE p.name = 'history_context_id')")
	db.query_count = db.query_count + 1
	if (r == 0): return orm_db_set_error(db, sql_error(db.conn))
	int ok = 1
	for i in range(r.rows):
		if (ok == 0): break
		char* hist = sql_value(r, i, 0)
		sql_builder* tb = orm_history_builder(db)
		sql_builder_append(tb, c"CREATE TEMP TRIGGER IF NOT EXISTS ")
		char* name = orm_history_cat(c"w_hist_ctx_", hist)
		sql_builder_identifier(tb, name)
		free(name)
		sql_builder_append(tb, c" AFTER INSERT ON main.")
		sql_builder_identifier(tb, hist)
		sql_builder_append(tb, c" FOR EACH ROW WHEN EXISTS (SELECT 1 FROM temp._w_orm_context) BEGIN UPDATE ")
		sql_builder_identifier(tb, hist)
		sql_builder_append(tb, c" SET history_user_id = (SELECT user_id FROM temp._w_orm_context), history_reason = (SELECT reason FROM temp._w_orm_context), history_context_id = (SELECT context_id FROM temp._w_orm_context) WHERE history_id = NEW.history_id; END")
		ok = orm_history_run(db, tb)
	sql_result_free(r)
	return ok


# Sets the context with an explicit id (a request id, say). user_id <= 0
# and reason 0 are stored as NULL. Returns 1, or 0 with orm_db_error set.
int orm_history_set_context_id(orm_db* db, char* context_id, int user_id, char* reason):
	string_builder* b = string_new()
	string_append(b, c"{\"context_id\":")
	char* c1 = orm_history_json_text(context_id)
	string_append(b, c1)
	free(c1)
	string_append(b, c",\"user_id\":")
	if (user_id > 0): string_append_int(b, user_id)
	else: string_append(b, c"null")
	string_append(b, c",\"reason\":")
	char* c2 = orm_history_json_text(reason)
	string_append(b, c2)
	free(c2)
	string_append(b, c"}")
	if (db.history_context != 0): free(db.history_context)
	db.history_context = b.data
	free(cast(void*, b))
	return orm_history_publish(db)


# Sets a context with a fresh random id and returns the id (owned by the
# caller), or 0 with orm_db_error set. Every history row written through
# this connection until the context changes or is cleared carries the id,
# user and reason; the id groups them into one changeset.
char* orm_history_set_context(orm_db* db, int user_id, char* reason):
	sql_builder* b = orm_history_builder(db)
	if (orm_history_is_pg(db)): sql_builder_append(b, c"SELECT md5(random()::text || clock_timestamp()::text)")
	else: sql_builder_append(b, c"SELECT lower(hex(randomblob(16)))")
	char* id = orm_history_scalar(db, b)
	if (id == 0): return 0
	if (orm_history_set_context_id(db, id, user_id, reason) == 0):
		free(id)
		return 0
	return id


# Writes after this carry no user, reason or context id.
int orm_history_clear_context(orm_db* db):
	if (db.history_context != 0): free(db.history_context)
	db.history_context = 0
	return orm_history_publish(db)


# ---------------------------------------------------------------------------
# Reading

int orm_history_column_index(sql_result* sr, char* name):
	for i in range(sr.columns):
		if (strcmp(sql_column_name(sr, i), name) == 0): return i
	return -1


char* orm_history_cell(sql_result* sr, int row, char* name):
	int i = orm_history_column_index(sr, name)
	if (i < 0): return 0
	return sql_value(sr, row, i)


# Runs a SELECT on a history table and appends one entry per row to out.
int orm_history_load_into(orm_db* db, orm_model_desc* m, sql_builder* b, orm_result* out):
	sql_result* sr = orm_db_execute(db, b)
	sql_builder_free(b)
	if (sr == 0): return 0
	int start = out.rows.length
	int ok = orm_load_by_column_name(db, m, sr, out)
	for i in range(sr.rows):
		orm_history_entry* e = cast(orm_history_entry*, orm_result_alloc(out, sizeof(orm_history_entry)))
		e.model = m
		e.row = out.rows[start + i]
		orm_parse_int(orm_history_cell(sr, i, c"history_id"), &e.history_id)
		e.date = orm_result_strdup(out, orm_history_cell(sr, i, c"history_date"))
		char* t = orm_history_cell(sr, i, c"history_type")
		if (t != 0): e.type = t[0]
		char* u = orm_history_cell(sr, i, c"history_user_id")
		if (u == 0): e.user_isnull = 1
		else: orm_parse_int(u, &e.user_id)
		e.reason = orm_result_strdup(out, orm_history_cell(sr, i, c"history_reason"))
		e.context_id = orm_result_strdup(out, orm_history_cell(sr, i, c"history_context_id"))
		out.rows[start + i] = cast(void*, e)
	sql_result_free(sr)
	return ok


sql_builder* orm_history_select(orm_db* db, orm_model_desc* m):
	sql_builder* b = orm_history_builder(db)
	sql_builder_append(b, c"SELECT * FROM ")
	char* h = orm_history_table(m)
	sql_builder_identifier(b, h)
	free(h)
	return b


void orm_history_pk_eq(sql_builder* b, orm_model_desc* m, int pk):
	sql_builder_identifier(b, orm_model_pk(m).column)
	sql_builder_append(b, c" = ")
	char* t = itoa(pk)
	sql_builder_bind(b, t)


int orm_history_row_pk(orm_model_desc* m, void* row):
	return orm_slot_get(row, orm_model_pk(m).offset)


# Every version of the object with primary key `pk`, newest first. The
# result's rows are orm_history_entry*; free it with orm_result_free.
# Returns 0 with orm_db_error set on failure.
orm_result* orm_history_for(orm_db* db, orm_model_desc* m, int pk):
	if (orm_model_pk(m) == 0):
		orm_db_set_error(db, c"orm history: model has no primary key")
		return 0
	sql_builder* b = orm_history_select(db, m)
	sql_builder_append(b, c" WHERE ")
	orm_history_pk_eq(b, m, pk)
	sql_builder_append(b, c" ORDER BY history_id DESC")
	orm_result* out = orm_result_new(m)
	if (orm_history_load_into(db, m, b, out) == 0):
		orm_result_free(out)
		return 0
	return out


orm_result* orm_history_of(orm_db* db, orm_model_desc* m, void* row):
	if (orm_model_pk(m) == 0):
		orm_db_set_error(db, c"orm history: model has no primary key")
		return 0
	return orm_history_for(db, m, orm_history_row_pk(m, row))


# Every history row of model m written under one context id, oldest first.
orm_result* orm_history_context_rows(orm_db* db, orm_model_desc* m, char* context_id):
	sql_builder* b = orm_history_select(db, m)
	sql_builder_append(b, c" WHERE history_context_id = ")
	sql_builder_bind(b, context_id)
	sql_builder_append(b, c" ORDER BY history_id")
	orm_result* out = orm_result_new(m)
	if (orm_history_load_into(db, m, b, out) == 0):
		orm_result_free(out)
		return 0
	return out


# The objects of model m as they were at `when` (UTC text, same format as
# history_date): for each primary key the newest history row written at or
# before `when`, unless that row is a delete. The result's rows are model
# rows (T*), in primary-key order; the history columns are not loaded.
orm_result* orm_history_as_of(orm_db* db, orm_model_desc* m, char* when):
	orm_field_desc* pk = orm_model_pk(m)
	if (pk == 0):
		orm_db_set_error(db, c"orm history: model has no primary key")
		return 0
	char* h = orm_history_table(m)
	sql_builder* b = orm_history_builder(db)
	sql_builder_append(b, c"SELECT * FROM ")
	sql_builder_identifier(b, h)
	sql_builder_append(b, c" WHERE history_id IN (SELECT MAX(history_id) FROM ")
	sql_builder_identifier(b, h)
	sql_builder_append(b, c" WHERE history_date <= ")
	sql_builder_bind(b, when)
	sql_builder_append(b, c" GROUP BY ")
	sql_builder_identifier(b, pk.column)
	sql_builder_append(b, c") AND history_type <> '-' ORDER BY ")
	sql_builder_identifier(b, pk.column)
	free(h)
	sql_result* sr = orm_db_execute(db, b)
	sql_builder_free(b)
	if (sr == 0): return 0
	orm_result* out = orm_result_new(m)
	int ok = orm_load_by_column_name(db, m, sr, out)
	sql_result_free(sr)
	if (ok == 0):
		orm_result_free(out)
		return 0
	return out


# ---------------------------------------------------------------------------
# Diff

# Database text of a field in a row (owned), 0 for SQL NULL.
char* orm_history_field_text(orm_field_desc* f, void* row):
	if (row == 0): return 0
	if (orm_field_is_text_backed(f)):
		char* s = cast(char*, orm_slot_get(row, f.offset))
		if (s == 0): return 0
		return strclone(s)
	if (f.null_offset >= 0 && orm_slot_get(row, f.null_offset) != 0): return 0
	return itoa(orm_slot_get(row, f.offset))


int orm_history_text_equal(char* a, char* b):
	if (a == 0 || b == 0): return a == b
	return strcmp(a, b) == 0


# The tracked fields (pk excluded) whose value differs between two
# versions of one object, in field order. `older` may be 0 (the version
# before the first: every non-NULL field of `newer` counts as changed).
# Free with orm_history_diff_free.
list[orm_history_change*] orm_history_diff(orm_history_entry* older, orm_history_entry* newer):
	list[orm_history_change*] out = new list[orm_history_change*]
	if (newer == 0): return out
	orm_model_desc* m = newer.model
	void* before = 0
	if (older != 0): before = older.row
	for orm_field_desc* f in m.fields:
		if (orm_history_tracks(f) == 0 || (f.flags & ORM_F_PK) != 0): continue
		char* a = orm_history_field_text(f, before)
		char* b = orm_history_field_text(f, newer.row)
		if (orm_history_text_equal(a, b)):
			if (a != 0): free(a)
			if (b != 0): free(b)
			continue
		orm_history_change* c = new orm_history_change()
		c.field = f.name
		c.old_value = a
		c.new_value = b
		out.push(c)
	return out


void orm_history_diff_free(list[orm_history_change*] changes):
	for orm_history_change* c in changes:
		if (c.old_value != 0): free(c.old_value)
		if (c.new_value != 0): free(c.new_value)
		free(cast(void*, c))
	changes.free()


# ---------------------------------------------------------------------------
# Revert

void orm_history_from_hist(sql_builder* b, char* h, int history_id):
	sql_builder_append(b, c" FROM ")
	sql_builder_identifier(b, h)
	sql_builder_append(b, c" WHERE history_id = ")
	char* t = itoa(history_id)
	sql_builder_bind(b, t)


# Makes object `pk` of model m equal to history row `history_id`: an
# UPDATE copying the tracked columns when the object exists, else an
# INSERT of them (the deleted object comes back with its primary key). The
# copy happens inside the database, so values keep their exact types.
int orm_history_restore(orm_db* db, orm_model_desc* m, int pk, int history_id):
	orm_field_desc* pkf = orm_model_pk(m)
	char* h = orm_history_table(m)
	sql_builder* q = orm_history_builder(db)
	sql_builder_append(q, c"SELECT COUNT(*) FROM ")
	sql_builder_identifier(q, m.table)
	sql_builder_append(q, c" WHERE ")
	orm_history_pk_eq(q, m, pk)
	char* n = orm_history_scalar(db, q)
	if (n == 0):
		free(h)
		return 0
	int exists = strcmp(n, c"0") != 0
	free(n)
	sql_builder* b = orm_history_builder(db)
	if (exists):
		sql_builder_append(b, c"UPDATE ")
		sql_builder_identifier(b, m.table)
		sql_builder_append(b, c" SET ")
		int first = 1
		for orm_field_desc* f in m.fields:
			if (orm_history_tracks(f) == 0 || f == pkf): continue
			if (first == 0): sql_builder_append(b, c", ")
			first = 0
			sql_builder_identifier(b, f.column)
			sql_builder_append(b, c" = (SELECT ")
			sql_builder_identifier(b, f.column)
			orm_history_from_hist(b, h, history_id)
			sql_builder_append(b, c")")
		sql_builder_append(b, c" WHERE ")
		orm_history_pk_eq(b, m, pk)
		if (first):
			sql_builder_free(b)
			free(h)
			return 1
	else:
		sql_builder_append(b, c"INSERT INTO ")
		sql_builder_identifier(b, m.table)
		sql_builder_append(b, c" (")
		int n2 = 0
		for orm_field_desc* f2 in m.fields:
			if (orm_history_tracks(f2) == 0): continue
			if (n2 > 0): sql_builder_append(b, c", ")
			n2 = n2 + 1
			sql_builder_identifier(b, f2.column)
		sql_builder_append(b, c") SELECT ")
		int n3 = 0
		for orm_field_desc* f3 in m.fields:
			if (orm_history_tracks(f3) == 0): continue
			if (n3 > 0): sql_builder_append(b, c", ")
			n3 = n3 + 1
			sql_builder_identifier(b, f3.column)
		orm_history_from_hist(b, h, history_id)
	free(h)
	return orm_history_run(db, b)


int orm_history_delete_object(orm_db* db, orm_model_desc* m, int pk):
	sql_builder* b = orm_history_builder(db)
	sql_builder_append(b, c"DELETE FROM ")
	sql_builder_identifier(b, m.table)
	sql_builder_append(b, c" WHERE ")
	orm_history_pk_eq(b, m, pk)
	return orm_history_run(db, b)


# Puts the object back into the state entry `e` recorded (for a delete
# entry: the object as it was when deleted, so it is re-created). The
# revert is an ordinary write: the triggers record it under the current
# context. Returns 1, or 0 with orm_db_error set.
int orm_history_revert(orm_db* db, orm_history_entry* e):
	orm_model_desc* m = e.model
	if (orm_model_pk(m) == 0): return orm_db_set_error(db, c"orm history: model has no primary key")
	return orm_history_restore(db, m, orm_history_row_pk(m, e.row), e.history_id)


struct orm_history_undo:
	orm_model_desc* model
	int pk
	int target           # history_id to restore, 0 = the object must not exist


int orm_history_table_exists(orm_db* db, orm_model_desc* m):
	char* h = orm_history_table(m)
	sql_builder* b = orm_history_builder(db)
	if (orm_history_is_pg(db)):
		sql_builder_append(b, c"SELECT 1 WHERE to_regclass(quote_ident(")
		sql_builder_bind(b, h)
		sql_builder_append(b, c")) IS NOT NULL")
	else:
		sql_builder_append(b, c"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ")
		sql_builder_bind(b, h)
	free(h)
	char* v = orm_history_scalar(db, b)
	if (v == 0): return 0
	free(v)
	return 1


# Collects, for every object of m the changeset touched, the state to go
# back to: the newest history row before the changeset's first row for it,
# or "absent" (target 0) when there is none or it is a delete.
int orm_history_plan_undo(orm_db* db, orm_model_desc* m, char* context_id, list[orm_history_undo*] out):
	orm_field_desc* pk = orm_model_pk(m)
	char* h = orm_history_table(m)
	sql_builder* b = orm_history_builder(db)
	sql_builder_append(b, c"SELECT ")
	sql_builder_identifier(b, pk.column)
	sql_builder_append(b, c", MIN(history_id) FROM ")
	sql_builder_identifier(b, h)
	sql_builder_append(b, c" WHERE history_context_id = ")
	sql_builder_bind(b, context_id)
	sql_builder_append(b, c" GROUP BY ")
	sql_builder_identifier(b, pk.column)
	sql_builder_append(b, c" ORDER BY ")
	sql_builder_identifier(b, pk.column)
	sql_result* r = orm_db_execute(db, b)
	sql_builder_free(b)
	if (r == 0):
		free(h)
		return 0
	int ok = 1
	for i in range(r.rows):
		if (ok == 0): break
		orm_history_undo* u = new orm_history_undo()
		u.model = m
		orm_parse_int(sql_value(r, i, 0), &u.pk)
		sql_builder* pb = orm_history_builder(db)
		sql_builder_append(pb, c"SELECT history_id, history_type FROM ")
		sql_builder_identifier(pb, h)
		sql_builder_append(pb, c" WHERE ")
		orm_history_pk_eq(pb, m, u.pk)
		sql_builder_append(pb, c" AND history_id < ")
		sql_builder_bind(pb, sql_value(r, i, 1))
		sql_builder_append(pb, c" ORDER BY history_id DESC LIMIT 1")
		sql_result* pr = orm_db_execute(db, pb)
		sql_builder_free(pb)
		if (pr == 0): ok = 0
		else:
			if (pr.rows > 0 && sql_value(pr, 0, 1) != 0 && sql_value(pr, 0, 1)[0] != '-'): orm_parse_int(sql_value(pr, 0, 0), &u.target)
			sql_result_free(pr)
		out.push(u)
	sql_result_free(r)
	free(h)
	return ok


int orm_history_begin(orm_db* db):
	if (db.atomic_depth > 0): return 0
	if (sql_begin(db.conn) == 0):
		orm_db_set_error(db, sql_error(db.conn))
		return -1
	db.atomic_depth = 1
	return 1


int orm_history_end(orm_db* db, int own, int ok):
	if (own != 1): return ok
	db.atomic_depth = 0
	if (ok):
		if (sql_commit(db.conn)): return 1
		orm_db_set_error(db, sql_error(db.conn))
		return 0
	char* keep = strclone(orm_db_error(db))
	sql_rollback(db.conn)
	orm_db_set_error(db, keep)
	free(keep)
	return 0


# Undoes everything written under `context_id` across every registered
# history model: objects it created are deleted, objects it changed or
# deleted go back to their state before the changeset. Later writes by
# other contexts to the same objects are overwritten. Deletes run first in
# reverse registry order, then restores in registry order (FK dependency
# order for generated modules), all in one transaction unless one is
# already open. Returns the number of objects reverted, or -1 with
# orm_db_error set.
int orm_history_revert_changeset(orm_db* db, char* context_id):
	if (context_id == 0):
		orm_db_set_error(db, c"orm history: no context id")
		return -1
	list[orm_history_undo*] undo = new list[orm_history_undo*]
	int ok = 1
	for orm_model_desc* m in orm_registry_models():
		if (ok == 0): break
		if (m.history == 0 || orm_model_pk(m) == 0): continue
		if (orm_history_table_exists(db, m) == 0): continue
		ok = orm_history_plan_undo(db, m, context_id, undo)
	int own = 0
	if (ok):
		own = orm_history_begin(db)
		if (own < 0): ok = 0
	int i = undo.length - 1
	while (ok && i >= 0):
		orm_history_undo* d = undo[i]
		if (d.target == 0): ok = orm_history_delete_object(db, d.model, d.pk)
		i = i - 1
	for orm_history_undo* u in undo:
		if (ok == 0): break
		if (u.target != 0): ok = orm_history_restore(db, u.model, u.pk, u.target)
	if (own >= 0): ok = orm_history_end(db, own, ok)
	int n = undo.length
	for orm_history_undo* x in undo: free(cast(void*, x))
	undo.free()
	if (ok == 0): return -1
	return n


# ---------------------------------------------------------------------------
# Retention

# Deletes the history rows of model m written before `older_than` (UTC
# text). Returns the number deleted, or -1 with orm_db_error set. as_of
# for a time before the cut no longer sees those versions.
int orm_history_prune(orm_db* db, orm_model_desc* m, char* older_than):
	if (older_than == 0):
		orm_db_set_error(db, c"orm history: prune needs a cut-off time")
		return -1
	char* h = orm_history_table(m)
	sql_builder* b = orm_history_builder(db)
	sql_builder_append(b, c"DELETE FROM ")
	sql_builder_identifier(b, h)
	sql_builder_append(b, c" WHERE history_date < ")
	sql_builder_bind(b, older_than)
	free(h)
	sql_result* r = orm_db_execute(db, b)
	sql_builder_free(b)
	if (r == 0): return -1
	int n = r.affected
	sql_result_free(r)
	return n
