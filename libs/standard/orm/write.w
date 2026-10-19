# w-orm row writes (unit U1.3, docs/projects/orm/u1_3.md).
#
# save / save_fields / delete_row / refresh on single rows, bulk_create and
# bulk_update, get_or_create / update_or_create, and M2M add/remove/set.
# Every write is built as a C3 query tree and compiled by compile.w, so
# values are always bound. Strings the ORM stores into a row (auto_now
# timestamps, RETURNING defaults, refresh) are owned by the row: freed with
# its result, or by orm_row_free for rows from orm_row_new.
import libs.standard.orm.query
import lib.time


# ---------------------------------------------------------------------------
# Clock (auto_now / auto_now_add)

char* __orm_now_override


# Fixes the timestamp writes use (tests); 0 restores the real UTC clock.
void orm_set_now(char* text):
	__orm_now_override = text


# Owned "YYYY-MM-DD HH:MM:SS" UTC text.
char* orm_now_text():
	if (__orm_now_override != 0): return strclone(__orm_now_override)
	return time_format_unix_utc(time_now())


# ---------------------------------------------------------------------------
# Field values

# 1 when save()/bulk writes may write this field's column.
int orm_field_writable(orm_field_desc* fd):
	if (orm_field_has_column(fd) == 0 || fd.offset < 0): return 0
	return (fd.flags & (ORM_F_DEPRECATED | ORM_F_READ_ONLY)) == 0


int orm_field_value_is_null(orm_field_desc* fd, void* row):
	if (orm_field_is_text_backed(fd)): return orm_slot_get(row, fd.offset) == 0
	if (fd.null_offset >= 0 && orm_slot_get(row, fd.null_offset) != 0): return 1
	# An unset nullable FK (id 0) is NULL rather than a dangling reference.
	return fd.kind == ORM_FK && (fd.flags & ORM_F_NULL) != 0 && orm_slot_get(row, fd.offset) == 0


# The value of fd in row as a bound expression. Formatted ints are pushed
# onto `scratch` for the caller to free after execution.
orm_expr* orm_field_value_expr(orm_field_desc* fd, void* row, list[char*] scratch):
	if (orm_field_value_is_null(fd, row)): return e_null()
	int v = orm_slot_get(row, fd.offset)
	if (orm_field_is_text_backed(fd)): return val(cast(char*, v))
	if (fd.kind == ORM_BOOL):
		if (v != 0): v = 1
	char* s = orm_format_int(v)
	scratch.push(s)
	return val(s)


void orm_scratch_free(list[char*] scratch):
	for char* s in scratch: free(s)
	scratch.free()


# Sets auto_now (always) and auto_now_add (when inserting) slots to now.
void orm_touch_auto_fields(orm_model_desc* m, void* row, int inserting):
	char* now = 0
	for orm_field_desc* fd in m.fields:
		if (orm_field_writable(fd) == 0 || orm_field_is_text_backed(fd) == 0): continue
		int set = (fd.flags & ORM_F_AUTO_NOW) != 0
		if (inserting && (fd.flags & ORM_F_AUTO_NOW_ADD) != 0): set = 1
		if (set):
			if (now == 0): now = orm_now_text()
			orm_slot_set(row, fd.offset, cast(int, orm_row_own(m, row, strclone(now))))
	if (now != 0): free(now)


int orm_row_pk(orm_model_desc* m, void* row):
	orm_field_desc* pk = orm_model_pk(m)
	if (pk == 0): return 0
	return orm_slot_get(row, pk.offset)


# pk = <row's pk> as a where node; the formatted id goes onto scratch.
orm_where* orm_pk_where(orm_model_desc* m, int id, list[char*] scratch):
	char* s = orm_format_int(id)
	scratch.push(s)
	return q_eq(orm_model_pk(m).name, s)


# Stores RETURNING columns (matched by column name) into row.
int orm_store_returned(orm_model_desc* m, void* row, sql_result* sr, int index):
	int ok = 1
	for i in range(sr.columns):
		char* col = sql_column_name(sr, i)
		char* text = sql_value(sr, index, i)
		for orm_field_desc* fd in m.fields:
			if (orm_field_has_column(fd) == 0 || fd.offset < 0 || strcmp(fd.column, col) != 0): continue
			if (orm_field_is_text_backed(fd)):
				char* s = 0
				if (text != 0): s = orm_row_own(m, row, strclone(text))
				orm_slot_set(row, fd.offset, cast(int, s))
			else:
				int v = 0
				if (text != 0):
					if (fd.kind == ORM_BOOL): ok = ok && orm_parse_bool(text, &v)
					else: ok = ok && orm_parse_int(text, &v)
				if (fd.null_offset >= 0): orm_slot_set(row, fd.null_offset, text == 0)
				orm_slot_set(row, fd.offset, v)
	return ok


# 1 when fd is NOT NULL with a database default, so a null value can be
# left to the database.
int orm_field_uses_default(orm_field_desc* fd):
	return fd.default_sql != 0 && (fd.flags & ORM_F_NULL) == 0


# ---------------------------------------------------------------------------
# Query trees for single-row writes (exposed for tree-shape tests)

# INSERT of one row: every writable field except an unset auto pk; NOT
# NULL fields with a default and a null value are omitted and RETURNed
# with the pk so the row picks up the database default.
orm_query* orm_insert_query(orm_model_desc* m, void* row, list[char*] scratch):
	orm_query* q = orm_query_new(ORM_Q_INSERT, m)
	orm_field_desc* pk = orm_model_pk(m)
	for orm_field_desc* fd in m.fields:
		if (orm_field_writable(fd) == 0): continue
		if (fd == pk && orm_slot_get(row, fd.offset) == 0 && (fd.flags & ORM_F_AUTO) != 0): continue
		if (orm_field_uses_default(fd) && orm_field_value_is_null(fd, row)):
			q.returning.push(fd.name)
			continue
		q.assignments.push(orm_set(fd.name, orm_field_value_expr(fd, row, scratch)))
	if (pk != 0): q.returning.insert(0, pk.name)
	return q


# UPDATE of one row by pk. fields = 0 writes every writable non-pk field.
orm_query* orm_update_row_query(orm_model_desc* m, void* row, list[char*] fields, list[char*] scratch):
	orm_query* q = orm_query_new(ORM_Q_UPDATE, m)
	orm_field_desc* pk = orm_model_pk(m)
	for orm_field_desc* fd in m.fields:
		if (fd == pk || orm_field_writable(fd) == 0): continue
		if (fields != 0):
			int wanted = 0
			for char* name in fields:
				if (strcmp(name, fd.name) == 0): wanted = 1
			if (wanted == 0): continue
		q.assignments.push(orm_set(fd.name, orm_field_value_expr(fd, row, scratch)))
	q.where = orm_pk_where(m, orm_row_pk(m, row), scratch)
	return q


# ---------------------------------------------------------------------------
# save / delete / refresh

int orm_insert_row(orm_db* db, orm_model_desc* m, void* row):
	list[char*] scratch = new list[char*]
	orm_query* q = orm_insert_query(m, row, scratch)
	orm_clear_error(db)
	sql_result* sr = orm_execute_query(db, q, 0)
	orm_scratch_free(scratch)
	if (sr == 0): return 0
	int ok = 1
	if (sr.rows == 1): ok = orm_store_returned(m, row, sr, 0)
	else if (q.returning.length > 0): ok = orm_db_set_error(db, c"orm: INSERT returned no row")
	sql_result_free(sr)
	return ok


# INSERT when the pk is 0 (storing the generated pk), else UPDATE by pk
# (falling back to INSERT when no row has that pk). auto_now fields are
# set to the current UTC time, auto_now_add ones on insert; deprecated and
# read-only fields are never written. Returns 1, or 0 with orm_db_error.
int orm_save(orm_db* db, orm_model_desc* m, void* row):
	if (orm_model_pk(m) == 0): return orm_db_set_error(db, c"orm: model has no primary key")
	if (orm_row_pk(m, row) == 0):
		orm_touch_auto_fields(m, row, 1)
		return orm_insert_row(db, m, row)
	orm_touch_auto_fields(m, row, 0)
	list[char*] scratch = new list[char*]
	orm_query* q = orm_update_row_query(m, row, 0, scratch)
	int n = 0
	if (q.assignments.length > 0): n = orm_run_write(db, q)
	else:
		n = orm_queryset_count(orm_queryset_new(db, orm_query_new(ORM_Q_SELECT, m)).filter(q.where))
	orm_scratch_free(scratch)
	if (n < 0): return 0
	if (n == 0):
		orm_touch_auto_fields(m, row, 1)
		return orm_insert_row(db, m, row)
	return 1


# UPDATE only `fields` (by field name) of an existing row. auto_now fields
# are refreshed only when listed (as in Django). Returns 1 when a row was
# updated, 0 otherwise (orm_db_error says why).
int orm_save_fields(orm_db* db, orm_model_desc* m, void* row, list[char*] fields):
	if (orm_model_pk(m) == 0 || orm_row_pk(m, row) == 0):
		return orm_db_set_error(db, c"orm: save_fields needs a saved row")
	for orm_field_desc* fd in m.fields:
		if ((fd.flags & ORM_F_AUTO_NOW) != 0 && orm_field_writable(fd)):
			for char* name in fields:
				if (strcmp(name, fd.name) == 0):
					char* now = orm_now_text()
					orm_slot_set(row, fd.offset, cast(int, orm_row_own(m, row, now)))
	list[char*] scratch = new list[char*]
	orm_query* q = orm_update_row_query(m, row, fields, scratch)
	if (q.assignments.length == 0):
		orm_scratch_free(scratch)
		return orm_db_set_error(db, c"orm: save_fields names no writable field")
	int n = orm_run_write(db, q)
	orm_scratch_free(scratch)
	if (n < 0): return 0
	if (n == 0): return orm_db_set_error(db, c"orm: save_fields did not affect any rows")
	return 1


# DELETE the row by pk (the database applies ON DELETE actions) and reset
# its pk to 0. Returns the deleted count (0 or 1), -1 on error.
int orm_delete_row(orm_db* db, orm_model_desc* m, void* row):
	orm_field_desc* pk = orm_model_pk(m)
	if (pk == 0 || orm_row_pk(m, row) == 0):
		orm_db_set_error(db, c"orm: delete needs a saved row")
		return -1
	list[char*] scratch = new list[char*]
	orm_query* q = orm_query_new(ORM_Q_DELETE, m)
	q.where = orm_pk_where(m, orm_row_pk(m, row), scratch)
	int n = orm_run_write(db, q)
	orm_scratch_free(scratch)
	if (n >= 0): orm_slot_set(row, pk.offset, 0)
	return n


orm_queryset* orm_model_queryset(orm_db* db, orm_model_desc* m):
	return orm_queryset_new(db, orm_query_new(ORM_Q_SELECT, m))


# Reloads every column field of row from the database (one query). FK
# pointer slots whose id changed are cleared. Returns 1, or 0 with
# orm_db_error ("... does not exist" when the row is gone).
int orm_refresh(orm_db* db, orm_model_desc* m, void* row):
	list[char*] scratch = new list[char*]
	orm_where* w = orm_pk_where(m, orm_row_pk(m, row), scratch)
	orm_result* r = orm_model_queryset(db, m).get(w)
	orm_scratch_free(scratch)
	if (r == 0): return 0
	void* fresh = r.rows[0]
	for orm_field_desc* fd in m.fields:
		if (orm_field_has_column(fd) == 0 || fd.offset < 0): continue
		if (fd.kind == ORM_FK && fd.rel_offset >= 0 && orm_slot_get(row, fd.offset) != orm_slot_get(fresh, fd.offset)):
			orm_slot_set(row, fd.rel_offset, 0)
		orm_copy_field(m, fd, row, fresh)
	orm_result_free(r)
	return 1


# ---------------------------------------------------------------------------
# Bulk writes

# ON CONFLICT options for bulk_create (0 = plain INSERT).
struct orm_conflict:
	int action                 # ORM_CONFLICT_NOTHING / ORM_CONFLICT_UPDATE
	list[char*] fields         # conflict target field names (may be empty for NOTHING)
	list[char*] update_fields  # DO UPDATE SET these from the proposed row


orm_conflict* orm_conflict_ignore(list[char*] fields):
	orm_conflict* c = new orm_conflict()
	c.action = ORM_CONFLICT_NOTHING
	c.fields = new list[char*]
	c.update_fields = new list[char*]
	if (fields != 0):
		for char* n in fields: c.fields.push(n)
	return c


orm_conflict* orm_conflict_update(list[char*] fields, list[char*] update_fields):
	orm_conflict* c = orm_conflict_ignore(fields)
	c.action = ORM_CONFLICT_UPDATE
	for char* n in update_fields: c.update_fields.push(n)
	return c


# Rows per statement so one statement binds at most max_params values.
int orm_batch_rows(orm_db* db, int params_per_row, int batch):
	int limit = 1000
	if (db.dialect.max_params > 0 && params_per_row > 0): limit = db.dialect.max_params / params_per_row
	if (limit < 1): limit = 1
	if (batch > 0 && batch < limit): return batch
	return limit


# One multi-row INSERT for rows[start, end).
orm_query* orm_bulk_insert_query(orm_model_desc* m, list[void*] rows, int start, int end, int with_pk, orm_conflict* conflict, list[char*] scratch):
	orm_query* q = orm_query_new(ORM_Q_INSERT, m)
	orm_field_desc* pk = orm_model_pk(m)
	for i in range(start, end):
		void* row = rows[i]
		list[orm_assignment*] values = new list[orm_assignment*]
		for orm_field_desc* fd in m.fields:
			if (orm_field_writable(fd) == 0): continue
			if (fd == pk && with_pk == 0): continue
			if (orm_field_uses_default(fd) && orm_field_value_is_null(fd, row)):
				values.push(orm_set(fd.name, e_raw(fd.default_sql, 0)))
			else: values.push(orm_set(fd.name, orm_field_value_expr(fd, row, scratch)))
		q.insert_rows.push(values)
	if (conflict != 0):
		q.conflict_action = conflict.action
		for char* n in conflict.fields: q.conflict_fields.push(n)
		for char* u in conflict.update_fields: q.update_fields.push(u)
	if (conflict == 0 || conflict.action != ORM_CONFLICT_NOTHING):
		if (pk != 0): q.returning.push(pk.name)
		for orm_field_desc* fd in m.fields:
			if (orm_field_writable(fd) && orm_field_uses_default(fd)): q.returning.push(fd.name)
	return q


# Multi-row INSERT ... RETURNING, `batch` rows per statement (0 = as many
# as dialect.max_params allows). Generated pks and database defaults are
# stored back into the rows (not with ORM_CONFLICT_NOTHING, where skipped
# rows return nothing). auto_now/auto_now_add are set. Rows must all have
# a pk or all have pk 0. Returns rows written, -1 on error. Batches are
# separate statements: wrap the call in a transaction for all-or-nothing.
int orm_bulk_create(orm_db* db, orm_model_desc* m, list[void*] rows, int batch, orm_conflict* conflict):
	orm_clear_error(db)
	if (rows.length == 0): return 0
	orm_field_desc* pk = orm_model_pk(m)
	int with_pk = 0
	int without_pk = 0
	for void* row in rows:
		if (pk != 0 && orm_slot_get(row, pk.offset) != 0): with_pk = 1
		else: without_pk = 1
	if (with_pk && without_pk):
		orm_db_set_error(db, c"orm: bulk_create rows mix set and unset primary keys")
		return -1
	int columns = 0
	for orm_field_desc* fd in m.fields:
		if (orm_field_writable(fd) && (fd != pk || with_pk)): columns = columns + 1
	for void* row in rows: orm_touch_auto_fields(m, row, 1)
	int per = orm_batch_rows(db, columns, batch)
	int total = 0
	int start = 0
	while (start < rows.length):
		int end = start + per
		if (end > rows.length): end = rows.length
		list[char*] scratch = new list[char*]
		orm_query* q = orm_bulk_insert_query(m, rows, start, end, with_pk, conflict, scratch)
		sql_result* sr = orm_execute_query(db, q, 0)
		orm_scratch_free(scratch)
		if (sr == 0): return -1
		int n = sr.affected
		if (sr.columns > 0 || n < 0): n = sr.rows
		if (q.returning.length > 0 && sr.rows == end - start):
			for i in range(sr.rows): orm_store_returned(m, rows[start + i], sr, i)
		sql_result_free(sr)
		total = total + n
		start = end
	return total


# UPDATE many rows' `fields` in batches with
#   SET f = CASE WHEN pk = ? THEN ? ... ELSE f END WHERE pk IN (...)
# Returns rows updated, -1 on error.
int orm_bulk_update(orm_db* db, orm_model_desc* m, list[void*] rows, list[char*] fields, int batch):
	orm_clear_error(db)
	orm_field_desc* pk = orm_model_pk(m)
	if (pk == 0):
		orm_db_set_error(db, c"orm: model has no primary key")
		return -1
	list[orm_field_desc*] targets = new list[orm_field_desc*]
	for char* name in fields:
		orm_field_desc* fd = orm_model_field(m, name)
		if (fd == 0 || fd == pk || orm_field_writable(fd) == 0):
			targets.free()
			orm_db_set_error(db, c"orm: bulk_update field is unknown or not writable")
			return -1
		targets.push(fd)
	if (rows.length == 0 || targets.length == 0):
		targets.free()
		return 0
	int per = orm_batch_rows(db, targets.length * 2 + 1, batch)
	int total = 0
	int start = 0
	while (start < rows.length):
		int end = start + per
		if (end > rows.length): end = rows.length
		list[char*] scratch = new list[char*]
		orm_query* q = orm_query_new(ORM_Q_UPDATE, m)
		for orm_field_desc* fd in targets:
			list[orm_when*] whens = new list[orm_when*]
			for i in range(start, end):
				orm_where* cond = orm_pk_where(m, orm_row_pk(m, rows[i]), scratch)
				whens.push(e_when(cond, orm_field_value_expr(fd, rows[i], scratch)))
			q.assignments.push(orm_set(fd.name, e_case(whens, f(fd.name))))
			whens.free()
		list[char*] ids = new list[char*]
		for i in range(start, end):
			char* s = orm_format_int(orm_row_pk(m, rows[i]))
			scratch.push(s)
			ids.push(s)
		q.where = q_in(pk.name, ids)
		ids.free()
		int n = orm_run_write(db, q)
		orm_scratch_free(scratch)
		if (n < 0):
			targets.free()
			return -1
		total = total + n
		start = end
	targets.free()
	return total


# ---------------------------------------------------------------------------
# get_or_create / update_or_create

orm_where* orm_assignments_where(list[orm_assignment*] lookup):
	orm_where* w = 0
	for orm_assignment* a in lookup: w = q_and(w, q_lookup_expr(f(a.field), c"exact", a.value))
	return w


int orm_assignments_have(list[orm_assignment*] items, char* field):
	if (items == 0): return 0
	for orm_assignment* a in items:
		if (strcmp(a.field, field) == 0): return 1
	return 0


# INSERT lookup + defaults (defaults win on a shared field) with auto_now
# timestamps, RETURNING every column, loaded into a one-row result.
orm_result* orm_create_from_assignments(orm_db* db, orm_model_desc* m, list[orm_assignment*] lookup, list[orm_assignment*] defaults):
	orm_query* q = orm_query_new(ORM_Q_INSERT, m)
	for orm_assignment* a in lookup:
		if (orm_assignments_have(defaults, a.field) == 0): q.assignments.push(a)
	if (defaults != 0):
		for orm_assignment* d in defaults: q.assignments.push(d)
	list[char*] scratch = new list[char*]
	for orm_field_desc* fd in m.fields:
		if (orm_field_writable(fd) == 0 || orm_assignments_have(q.assignments, fd.name)): continue
		if ((fd.flags & (ORM_F_AUTO_NOW | ORM_F_AUTO_NOW_ADD)) != 0):
			char* now = orm_now_text()
			scratch.push(now)
			q.assignments.push(orm_set(fd.name, val(now)))
	for orm_field_desc* fd in m.fields:
		if (orm_field_has_column(fd) && fd.offset >= 0 && (fd.flags & ORM_F_DEPRECATED) == 0): q.returning.push(fd.name)
	orm_clear_error(db)
	sql_result* sr = orm_execute_query(db, q, 0)
	orm_scratch_free(scratch)
	if (sr == 0): return 0
	orm_result* r = orm_result_new(m)
	int ok = orm_load_by_column_name(db, m, sr, r)
	sql_result_free(sr)
	if (ok == 0 || r.rows.length != 1):
		if (ok): orm_db_set_error(db, c"orm: INSERT returned no row")
		orm_result_free(r)
		return 0
	return r


# Returns a one-row result: the row matching `lookup` (exact field =
# value pairs), or a new row created from lookup + defaults. A failed
# INSERT (a concurrent creator won the unique constraint) retries the get.
# *created is 1 when the row was inserted. 0 on error.
orm_result* orm_get_or_create(orm_db* db, orm_model_desc* m, list[orm_assignment*] lookup, list[orm_assignment*] defaults, int* created):
	if (created != 0): created[0] = 0
	orm_queryset* qs = orm_model_queryset(db, m)
	orm_where* w = orm_assignments_where(lookup)
	orm_result* r = qs.get(w)
	if (r != 0 || orm_error_is_does_not_exist(db) == 0): return r
	r = orm_create_from_assignments(db, m, lookup, defaults)
	if (r != 0):
		if (created != 0): created[0] = 1
		return r
	char* insert_error = strclone(orm_db_error(db))
	r = qs.get(w)
	if (r == 0): orm_db_set_error(db, insert_error)
	free(insert_error)
	return r


# UPDATE ... SET defaults (plus auto_now fields) WHERE pk RETURNING every
# column, loaded into a one-row result; 0 when no row has that pk.
orm_result* orm_update_returning(orm_db* db, orm_model_desc* m, int id, list[orm_assignment*] defaults):
	list[char*] scratch = new list[char*]
	orm_query* q = orm_query_new(ORM_Q_UPDATE, m)
	if (defaults != 0):
		for orm_assignment* d in defaults: q.assignments.push(d)
	for orm_field_desc* fd in m.fields:
		if (orm_field_writable(fd) && (fd.flags & ORM_F_AUTO_NOW) != 0 && orm_assignments_have(q.assignments, fd.name) == 0):
			char* now = orm_now_text()
			scratch.push(now)
			q.assignments.push(orm_set(fd.name, val(now)))
	q.where = orm_pk_where(m, id, scratch)
	for orm_field_desc* fd in m.fields:
		if (orm_field_has_column(fd) && fd.offset >= 0 && (fd.flags & ORM_F_DEPRECATED) == 0): q.returning.push(fd.name)
	orm_clear_error(db)
	sql_result* sr = 0
	if (q.assignments.length > 0): sr = orm_execute_query(db, q, 0)
	orm_scratch_free(scratch)
	if (q.assignments.length == 0):
		list[char*] s2 = new list[char*]
		orm_result* same = orm_model_queryset(db, m).get(orm_pk_where(m, id, s2))
		orm_scratch_free(s2)
		return same
	if (sr == 0): return 0
	orm_result* r = orm_result_new(m)
	int ok = orm_load_by_column_name(db, m, sr, r)
	sql_result_free(sr)
	if (ok == 0 || r.rows.length != 1):
		if (ok): orm_db_set_error(db, c"orm: row to update no longer exists")
		orm_result_free(r)
		return 0
	return r


list[char*] orm_pk_list(orm_model_desc* m):
	list[char*] l = new list[char*]
	l.push(orm_model_pk(m).name)
	return l


# Updates the row matching `lookup` with `defaults`, or creates it from
# lookup + defaults. Retries once after a failed INSERT (unique race).
# Returns the up-to-date row as a one-row result; *created as in
# get_or_create. 0 on error.
orm_result* orm_update_or_create(orm_db* db, orm_model_desc* m, list[orm_assignment*] lookup, list[orm_assignment*] defaults, int* created):
	if (created != 0): created[0] = 0
	orm_queryset* qs = orm_model_queryset(db, m)
	orm_where* w = orm_assignments_where(lookup)
	list[char*] pk_only = orm_pk_list(m)
	orm_queryset* lookup_qs = qs.only(pk_only)
	pk_only.free()
	for attempt in range(2):
		orm_result* found = lookup_qs.get(w)
		if (found != 0):
			int id = orm_row_pk(m, found.rows[0])
			orm_result_free(found)
			return orm_update_returning(db, m, id, defaults)
		if (orm_error_is_does_not_exist(db) == 0): return 0
		if (attempt == 1): return 0
		orm_result* r = orm_create_from_assignments(db, m, lookup, defaults)
		if (r != 0):
			if (created != 0): created[0] = 1
			return r
	return 0


# ---------------------------------------------------------------------------
# Many-to-many through rows

map[char*, orm_model_desc*] __orm_through_descs


# A private, unregistered descriptor for an M2M through table with the
# two join columns as INT fields named after their columns.
orm_model_desc* orm_through_desc(orm_field_desc* rel):
	if (__orm_through_descs == 0): __orm_through_descs = new map[char*, orm_model_desc*]
	if (rel.through_table in __orm_through_descs): return __orm_through_descs[rel.through_table]
	orm_model_desc* t = orm_model_new(rel.through_table, rel.through_table, 2 * sizeof(int))
	orm_model_add_field(t, orm_field_new(rel.through_from, rel.through_from, ORM_INT, 0, 0))
	orm_model_add_field(t, orm_field_new(rel.through_to, rel.through_to, ORM_INT, sizeof(int), 0))
	__orm_through_descs[rel.through_table] = t
	return t


orm_field_desc* orm_m2m_field(orm_db* db, orm_model_desc* m, char* field):
	orm_field_desc* rel = orm_model_field(m, field)
	if (rel == 0 || rel.kind != ORM_M2M || rel.through_table == 0 || orm_field_target(rel) == 0):
		orm_db_set_error(db, c"orm: not a resolved many-to-many field")
		return 0
	return rel


# Target row pks as owned decimal strings (pushed onto scratch too).
list[char*] orm_target_ids(orm_model_desc* target, list[void*] rows, list[char*] scratch):
	list[char*] ids = new list[char*]
	for void* t in rows:
		char* s = orm_format_int(orm_row_pk(target, t))
		scratch.push(s)
		ids.push(s)
	return ids


# Links row to every target (INSERT ... ON CONFLICT DO NOTHING on the
# join pair, so existing links are kept). Returns links added, -1 on error.
# The row's in-memory relation list is not changed (prefetch fills it).
int orm_m2m_add(orm_db* db, orm_model_desc* m, void* row, char* field, list[void*] targets):
	orm_clear_error(db)
	orm_field_desc* rel = orm_m2m_field(db, m, field)
	if (rel == 0): return -1
	if (targets.length == 0): return 0
	orm_model_desc* t = orm_through_desc(rel)
	orm_model_desc* target = orm_field_target(rel)
	list[char*] scratch = new list[char*]
	char* self_id = orm_format_int(orm_row_pk(m, row))
	scratch.push(self_id)
	int per = orm_batch_rows(db, 2, 0)
	int total = 0
	int start = 0
	while (start < targets.length):
		int end = start + per
		if (end > targets.length): end = targets.length
		orm_query* q = orm_query_new(ORM_Q_INSERT, t)
		for i in range(start, end):
			char* tid = orm_format_int(orm_row_pk(target, targets[i]))
			scratch.push(tid)
			list[orm_assignment*] values = new list[orm_assignment*]
			values.push(orm_set(rel.through_from, val(self_id)))
			values.push(orm_set(rel.through_to, val(tid)))
			q.insert_rows.push(values)
		q.conflict_action = ORM_CONFLICT_NOTHING
		q.conflict_fields.push(rel.through_from)
		q.conflict_fields.push(rel.through_to)
		int n = orm_run_write(db, q)
		if (n < 0):
			orm_scratch_free(scratch)
			return -1
		total = total + n
		start = end
	orm_scratch_free(scratch)
	return total


orm_where* orm_m2m_owner_where(orm_field_desc* rel, char* self_id):
	return q_eq(rel.through_from, self_id)


# Unlinks row from the targets. Returns links removed, -1 on error.
int orm_m2m_remove(orm_db* db, orm_model_desc* m, void* row, char* field, list[void*] targets):
	orm_clear_error(db)
	orm_field_desc* rel = orm_m2m_field(db, m, field)
	if (rel == 0): return -1
	if (targets.length == 0): return 0
	list[char*] scratch = new list[char*]
	char* self_id = orm_format_int(orm_row_pk(m, row))
	scratch.push(self_id)
	list[char*] ids = orm_target_ids(orm_field_target(rel), targets, scratch)
	orm_query* q = orm_query_new(ORM_Q_DELETE, orm_through_desc(rel))
	q.where = q_and(orm_m2m_owner_where(rel, self_id), q_in(rel.through_to, ids))
	int n = orm_run_write(db, q)
	ids.free()
	orm_scratch_free(scratch)
	return n


# Makes the targets exactly row's links: one DELETE of the links not in
# targets, then one INSERT for the missing ones. Returns 1, 0 on error.
int orm_m2m_set(orm_db* db, orm_model_desc* m, void* row, char* field, list[void*] targets):
	orm_clear_error(db)
	orm_field_desc* rel = orm_m2m_field(db, m, field)
	if (rel == 0): return 0
	list[char*] scratch = new list[char*]
	char* self_id = orm_format_int(orm_row_pk(m, row))
	scratch.push(self_id)
	list[char*] ids = orm_target_ids(orm_field_target(rel), targets, scratch)
	orm_query* q = orm_query_new(ORM_Q_DELETE, orm_through_desc(rel))
	q.where = orm_m2m_owner_where(rel, self_id)
	if (ids.length > 0): q.where = q_and(q.where, q_not(q_in(rel.through_to, ids)))
	int n = orm_run_write(db, q)
	ids.free()
	orm_scratch_free(scratch)
	if (n < 0): return 0
	return orm_m2m_add(db, m, row, field, targets) >= 0
