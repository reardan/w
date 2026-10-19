# w-orm history DDL (issue #754, unit U3.3; docs/projects/orm/u3_3.md).
#
# The migration applier calls these for CREATE_HISTORY / DROP_HISTORY and,
# from ddl_sqlite.w / ddl_postgres.w, after schema changes to a tracked
# table so "<table>_history" and its triggers stay in step (contract C8).
#
# Layout of "<table>_history": history_id (INTEGER PRIMARY KEY / BIGSERIAL),
# the model's columns minus no_history fields (same types, all nullable, no
# constraints), history_date (UTC "YYYY-MM-DD HH:MM:SS.fff" text on SQLite,
# TIMESTAMP on PostgreSQL), history_type ('+' / '~' / '-'), history_user_id,
# history_reason, history_context_id. Indexes on history_date, the pk column
# and history_context_id.
#
# Triggers:
# - SQLite: AFTER INSERT / UPDATE / DELETE triggers "w_hist_<table>_ins/_upd
#   /_del" list the tracked columns; the UPDATE trigger has a WHEN that
#   compares them column by column (IS NOT), so no-change updates write
#   nothing. Main-schema triggers cannot read TEMP tables, so the context
#   (user, reason, context id) is filled in by a per-connection TEMP trigger
#   on the history table that history.w installs when a context is set.
# - PostgreSQL: one AFTER ROW function "w_hist_<table>" that projects
#   to_jsonb(NEW/OLD) onto the history table's row type, so it never names
#   a column: adding or dropping columns needs no trigger change. It reads
#   current_setting('w_orm.context', true) and skips updates whose
#   projection did not change.
import libs.standard.orm.migrate.ddl_common


struct orm_hist_col:
	char* name
	char* type     # declared SQL type ("" when SQLite has none)


char* orm_hist_table(char* table):
	return orm_mx_cat(table, ORM_HISTORY_SUFFIX(), 0, 0)


char* orm_hist_base(char* table):
	return orm_mx_name(c"w_hist_", table, 0, 0)


int orm_hist_is_meta(char* column):
	return starts_with_at(column, c"history_", 0)


void orm_hist_cols_free(list[orm_hist_col*] cols):
	for orm_hist_col* c in cols:
		free(c.name)
		free(c.type)
		free(cast(void*, c))
	cols.free()


orm_hist_col* orm_hist_find(list[orm_hist_col*] cols, char* name):
	for orm_hist_col* c in cols:
		if (strcmp(c.name, name) == 0): return c
	return 0


# Live columns of `table` with their declared types, in table order; empty
# when the table does not exist (also in collect mode before it is created).
list[orm_hist_col*] orm_hist_live_columns(orm_mx_ctx* x, char* table):
	string_builder* b = string_new()
	if (orm_mx_pg(x)):
		string_append(b, c"SELECT attname, format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = to_regclass(quote_ident(")
		orm_mx_literal_to(b, table)
		string_append(b, c")) AND attnum > 0 AND NOT attisdropped ORDER BY attnum")
	else:
		string_append(b, c"SELECT name, type FROM pragma_table_info(")
		orm_mx_literal_to(b, table)
		string_append(b, c") ORDER BY cid")
	char* q = orm_mx_take(b)
	list[orm_hist_col*] out = new list[orm_hist_col*]
	sql_result* r = orm_mx_query(x, q)
	free(q)
	if (r == 0): return out
	for i in range(r.rows):
		orm_hist_col* c = new orm_hist_col()
		c.name = strclone(sql_value(r, i, 0))
		if (sql_value(r, i, 1) != 0): c.type = strclone(sql_value(r, i, 1))
		else: c.type = strclone(c"")
		out.push(c)
	sql_result_free(r)
	return out


int orm_hist_exists(orm_mx_ctx* x, char* table):
	list[orm_hist_col*] cols = orm_hist_live_columns(x, table)
	int n = cols.length
	orm_hist_cols_free(cols)
	return n > 0


# Columns of a model snapshot that the history table tracks: fields with a
# column, minus no_history ones. *pk_out gets the pk column.
list[char*] orm_hist_model_columns(json_value* m, char** pk_out):
	list[char*] out = new list[char*]
	json_value* fields = orm_mx_jget(m, c"fields")
	for i in range(orm_mx_jarray_len(fields)):
		json_value* f = json_array_get(fields, i)
		int k = orm_mx_kind(f)
		char* col = orm_mx_jstr(f, c"column")
		if (k == ORM_M2M || k == ORM_REVERSE_FK || col == 0): continue
		if (orm_mx_jbool(f, c"pk") && pk_out != 0): pk_out[0] = col
		if (orm_mx_jbool(f, c"no_history")): continue
		out.push(strclone(col))
	return out


json_value* orm_hist_model_field(json_value* m, char* column):
	json_value* fields = orm_mx_jget(m, c"fields")
	for i in range(orm_mx_jarray_len(fields)):
		json_value* f = json_array_get(fields, i)
		char* col = orm_mx_jstr(f, c"column")
		if (col != 0 && strcmp(col, column) == 0): return f
	return 0


# Owned SQL type for a history column: the live base column's type, else
# the snapshot's (an auto int pk is BIGINT on PostgreSQL, matching
# BIGSERIAL), else TEXT.
char* orm_hist_column_type(orm_mx_ctx* x, list[orm_hist_col*] base, json_value* f, char* column):
	orm_hist_col* live = orm_hist_find(base, column)
	if (live != 0): return strclone(live.type)
	if (f != 0):
		if (orm_mx_pg(x) && orm_mx_jbool(f, c"pk") && orm_mx_kind_is_int(orm_mx_kind(f))): return strclone(c"BIGINT")
		return orm_mx_type(x, f)
	return strclone(c"TEXT")


void orm_hist_column_def_to(string_builder* b, char* column, char* type):
	orm_mx_ident_to(b, column)
	if (type != 0 && type[0] != 0):
		string_append(b, c" ")
		string_append(b, type)


int orm_hist_index(orm_mx_ctx* x, char* hist, char* suffix, char* column):
	char* name = orm_mx_name(hist, suffix, 0, 0)
	json_value* one = json_array()
	json_array_push(one, json_string(column))
	int ok = orm_mx_index_sql(x, name, hist, one, 0, 0, 0)
	json_free(one)
	free(name)
	return ok


int orm_hist_create_table(orm_mx_ctx* x, char* hist, list[char*] cols, list[orm_hist_col*] base, json_value* m, char* pk):
	string_builder* b = string_new()
	string_append(b, c"CREATE TABLE ")
	orm_mx_ident_to(b, hist)
	if (orm_mx_pg(x)): string_append(b, c" (\"history_id\" BIGSERIAL PRIMARY KEY")
	else: string_append(b, c" (\"history_id\" INTEGER PRIMARY KEY")
	for char* c in cols:
		string_append(b, c", ")
		char* t = orm_hist_column_type(x, base, orm_hist_model_field(m, c), c)
		orm_hist_column_def_to(b, c, t)
		free(t)
	if (orm_mx_pg(x)): string_append(b, c", \"history_date\" TIMESTAMP NOT NULL, \"history_type\" VARCHAR(1) NOT NULL, \"history_user_id\" BIGINT, \"history_reason\" TEXT, \"history_context_id\" VARCHAR(64))")
	else: string_append(b, c", \"history_date\" TEXT NOT NULL, \"history_type\" VARCHAR(1) NOT NULL, \"history_user_id\" INTEGER, \"history_reason\" TEXT, \"history_context_id\" VARCHAR(64))")
	int ok = orm_mx_run_b(x, b)
	if (ok): ok = orm_hist_index(x, hist, c"_date_idx", c"history_date")
	if (ok && pk != 0 && orm_mx_list_has(cols, pk)): ok = orm_hist_index(x, hist, c"_pk_idx", pk)
	if (ok): ok = orm_hist_index(x, hist, c"_context_idx", c"history_context_id")
	return ok


int orm_hist_add_column(orm_mx_ctx* x, char* hist, char* column, char* type):
	string_builder* b = string_new()
	string_append(b, c"ALTER TABLE ")
	orm_mx_ident_to(b, hist)
	string_append(b, c" ADD COLUMN ")
	orm_hist_column_def_to(b, column, type)
	return orm_mx_run_b(x, b)


# PostgreSQL: history columns follow type changes of their base column
# (a rebuild that widens VARCHAR(300) to VARCHAR(400) must not make the
# trigger fail). SQLite columns take any value, so nothing to do there.
int orm_hist_sync_types(orm_mx_ctx* x, char* table, char* hist):
	if (orm_mx_pg(x) == 0): return 1
	list[orm_hist_col*] base = orm_hist_live_columns(x, table)
	list[orm_hist_col*] hcols = orm_hist_live_columns(x, hist)
	int ok = 1
	for orm_hist_col* h in hcols:
		if (ok == 0): break
		orm_hist_col* bc = orm_hist_find(base, h.name)
		if (bc == 0 || orm_hist_is_meta(h.name) || strcmp(bc.type, h.type) == 0): continue
		string_builder* b = string_new()
		string_append(b, c"ALTER TABLE ")
		orm_mx_ident_to(b, hist)
		string_append(b, c" ALTER COLUMN ")
		orm_mx_ident_to(b, h.name)
		string_append(b, c" TYPE ")
		string_append(b, bc.type)
		string_append(b, c" USING ")
		orm_mx_ident_to(b, h.name)
		string_append(b, c"::")
		string_append(b, bc.type)
		ok = orm_mx_run_b(x, b)
	orm_hist_cols_free(base)
	orm_hist_cols_free(hcols)
	return ok


# ---------------------------------------------------------------------------
# Triggers

int orm_hist_sqlite_drop_triggers(orm_mx_ctx* x, char* table):
	char* base = orm_hist_base(table)
	int ok = 1
	for i in range(3):
		char* suffix = c"_ins"
		if (i == 1): suffix = c"_upd"
		if (i == 2): suffix = c"_del"
		char* name = orm_mx_cat(base, suffix, 0, 0)
		if (ok): ok = orm_mx_run(x, orm_mx_cat(c"DROP TRIGGER IF EXISTS ", orm_mx_ident(name), 0, 0))
		free(name)
	free(base)
	return ok


# One SQLite trigger: AFTER <event> ON table, copying NEW./OLD. columns.
int orm_hist_sqlite_trigger(orm_mx_ctx* x, char* table, char* hist, list[char*] cols, int kind):
	char* base = orm_hist_base(table)
	char* suffix = c"_ins"
	char* event = c"INSERT"
	char* src = c"NEW."
	char* type = c"'+'"
	if (kind == ORM_HISTORY_UPDATE):
		suffix = c"_upd"
		event = c"UPDATE"
		type = c"'~'"
	if (kind == ORM_HISTORY_DELETE):
		suffix = c"_del"
		event = c"DELETE"
		src = c"OLD."
		type = c"'-'"
	char* name = orm_mx_cat(base, suffix, 0, 0)
	string_builder* b = string_new()
	string_append(b, c"CREATE TRIGGER ")
	orm_mx_ident_to(b, name)
	string_append(b, c" AFTER ")
	string_append(b, event)
	string_append(b, c" ON ")
	orm_mx_ident_to(b, table)
	string_append(b, c" FOR EACH ROW")
	if (kind == ORM_HISTORY_UPDATE && cols.length > 0):
		string_append(b, c" WHEN ")
		for i in range(cols.length):
			if (i > 0): string_append(b, c" OR ")
			string_append(b, c"NEW.")
			orm_mx_ident_to(b, cols[i])
			string_append(b, c" IS NOT OLD.")
			orm_mx_ident_to(b, cols[i])
	string_append(b, c" BEGIN INSERT INTO ")
	orm_mx_ident_to(b, hist)
	string_append(b, c" (")
	for char* c in cols:
		orm_mx_ident_to(b, c)
		string_append(b, c", ")
	string_append(b, c"\"history_date\", \"history_type\") VALUES (")
	for char* c2 in cols:
		string_append(b, src)
		orm_mx_ident_to(b, c2)
		string_append(b, c", ")
	string_append(b, c"strftime('%Y-%m-%d %H:%M:%f', 'now'), ")
	string_append(b, type)
	string_append(b, c"); END")
	free(name)
	free(base)
	return orm_mx_run_b(x, b)


int orm_hist_sqlite_triggers(orm_mx_ctx* x, char* table, char* hist, list[char*] cols):
	int ok = orm_hist_sqlite_drop_triggers(x, table)
	if (ok): ok = orm_hist_sqlite_trigger(x, table, hist, cols, ORM_HISTORY_INSERT)
	if (ok): ok = orm_hist_sqlite_trigger(x, table, hist, cols, ORM_HISTORY_UPDATE)
	if (ok): ok = orm_hist_sqlite_trigger(x, table, hist, cols, ORM_HISTORY_DELETE)
	return ok


# CREATE OR REPLACE also drops cached plans that still hold the history
# table's old row type, so it runs again after the table changes.
int orm_hist_pg_function(orm_mx_ctx* x, char* table, char* hist):
	char* base = orm_hist_base(table)
	char* qh = orm_mx_ident(hist)
	char* lit = orm_mx_literal(qh)
	char* proj_old = orm_mx_cat(c"jsonb_populate_record(NULL::", qh, c", to_jsonb(OLD))", 0)
	char* proj_new = orm_mx_cat(c"jsonb_populate_record(NULL::", qh, c", to_jsonb(NEW))", 0)
	string_builder* b = string_new()
	string_append(b, c"CREATE OR REPLACE FUNCTION ")
	orm_mx_ident_to(b, base)
	string_append(b, c"() RETURNS trigger LANGUAGE plpgsql AS $w_hist$ DECLARE h ")
	string_append(b, qh)
	string_append(b, c"; ctx jsonb; raw text; BEGIN IF TG_OP = 'UPDATE' AND to_jsonb(")
	string_append(b, proj_old)
	string_append(b, c") = to_jsonb(")
	string_append(b, proj_new)
	string_append(b, c") THEN RETURN NULL; END IF; IF TG_OP = 'DELETE' THEN h := ")
	string_append(b, proj_old)
	string_append(b, c"; ELSE h := ")
	string_append(b, proj_new)
	string_append(b, c"; END IF; raw := current_setting('w_orm.context', true); IF raw IS NOT NULL AND raw <> '' THEN ctx := raw::jsonb; END IF; h.history_id := nextval(pg_get_serial_sequence(")
	string_append(b, lit)
	string_append(b, c", 'history_id')); h.history_date := clock_timestamp() AT TIME ZONE 'UTC'; h.history_type := CASE TG_OP WHEN 'INSERT' THEN '+' WHEN 'UPDATE' THEN '~' ELSE '-' END; h.history_user_id := (ctx->>'user_id')::bigint; h.history_reason := ctx->>'reason'; h.history_context_id := ctx->>'context_id'; INSERT INTO ")
	string_append(b, qh)
	string_append(b, c" SELECT (h).*; RETURN NULL; END $w_hist$")
	free(proj_old)
	free(proj_new)
	free(lit)
	free(qh)
	free(base)
	return orm_mx_run_b(x, b)


int orm_hist_pg_drop_trigger(orm_mx_ctx* x, char* table, char* on_table):
	char* base = orm_hist_base(table)
	int ok = orm_mx_run(x, orm_mx_cat(c"DROP TRIGGER IF EXISTS ", orm_mx_ident(base), c" ON ", orm_mx_ident(on_table)))
	free(base)
	return ok


int orm_hist_pg_triggers(orm_mx_ctx* x, char* table, char* hist):
	int ok = orm_hist_pg_function(x, table, hist)
	if (ok): ok = orm_hist_pg_drop_trigger(x, table, table)
	if (ok):
		char* base = orm_hist_base(table)
		string_builder* b = string_new()
		string_append(b, c"CREATE TRIGGER ")
		orm_mx_ident_to(b, base)
		string_append(b, c" AFTER INSERT OR UPDATE OR DELETE ON ")
		orm_mx_ident_to(b, table)
		string_append(b, c" FOR EACH ROW EXECUTE FUNCTION ")
		orm_mx_ident_to(b, base)
		string_append(b, c"()")
		ok = orm_mx_run_b(x, b)
		free(base)
	return ok


# Tracked columns from the catalog: base columns that the history table
# also has.
list[char*] orm_hist_common_columns(orm_mx_ctx* x, char* table, char* hist):
	list[orm_hist_col*] base = orm_hist_live_columns(x, table)
	list[orm_hist_col*] hcols = orm_hist_live_columns(x, hist)
	list[char*] out = new list[char*]
	for orm_hist_col* c in base:
		if (orm_hist_is_meta(c.name) == 0 && orm_hist_find(hcols, c.name) != 0): out.push(strclone(c.name))
	orm_hist_cols_free(base)
	orm_hist_cols_free(hcols)
	return out


# (Re)installs the triggers of a tracked table from the live catalog.
int orm_hist_refresh(orm_mx_ctx* x, char* table, char* hist):
	if (orm_mx_pg(x)): return orm_hist_pg_triggers(x, table, hist)
	list[char*] cols = orm_hist_common_columns(x, table, hist)
	int ok = orm_hist_sqlite_triggers(x, table, hist, cols)
	orm_mx_free_strings(cols)
	return ok


# ---------------------------------------------------------------------------
# CREATE_HISTORY / DROP_HISTORY

# Creates "<table>_history" and the triggers. model_json picks the tracked
# columns (no_history fields are left out); without it every live column
# is tracked. Idempotent: when the history table exists (a rebuilt table
# gets CREATE_HISTORY again, u2_2.md) missing columns are added, PostgreSQL
# column types follow the base table and the triggers are reinstalled.
int orm_hist_create(orm_mx_ctx* x, orm_op* op):
	json_value* m = 0
	if (op.model_json != 0):
		m = json_parse(op.model_json)
		if (m == 0): return orm_mx_fail(x, c"CREATE_HISTORY: model_json is not valid JSON", 0, 0)
	char* table = op.table
	if (table == 0): table = orm_mx_jstr(m, c"table")
	if (table == 0):
		json_free(m)
		return orm_mx_fail(x, c"CREATE_HISTORY without a table", 0, 0)
	char* hist = orm_hist_table(table)
	list[orm_hist_col*] base = orm_hist_live_columns(x, table)
	char* pk = 0
	list[char*] cols = 0
	if (m != 0): cols = orm_hist_model_columns(m, &pk)
	else:
		cols = new list[char*]
		for orm_hist_col* bc in base: cols.push(strclone(bc.name))
		if (base.length > 0): pk = base[0].name
	int ok = 1
	if (cols.length == 0):
		ok = orm_mx_fail(x, c"CREATE_HISTORY: no columns known for ", table, c" (no model_json and no live table)")
	list[orm_hist_col*] hcols = orm_hist_live_columns(x, hist)
	if (ok && hcols.length == 0): ok = orm_hist_create_table(x, hist, cols, base, m, pk)
	else if (ok):
		for char* c in cols:
			if (ok == 0 || orm_hist_find(hcols, c) != 0): continue
			char* t = orm_hist_column_type(x, base, orm_hist_model_field(m, c), c)
			ok = orm_hist_add_column(x, hist, c, t)
			free(t)
		if (ok): ok = orm_hist_sync_types(x, table, hist)
	if (ok):
		if (orm_mx_pg(x)): ok = orm_hist_pg_triggers(x, table, hist)
		else: ok = orm_hist_sqlite_triggers(x, table, hist, cols)
	orm_hist_cols_free(hcols)
	orm_hist_cols_free(base)
	orm_mx_free_strings(cols)
	free(hist)
	json_free(m)
	return ok


# Drops the triggers and the history table (contract phase: the rows go).
int orm_hist_drop(orm_mx_ctx* x, orm_op* op):
	if (op.table == 0): return orm_mx_fail(x, c"DROP_HISTORY without a table", 0, 0)
	char* hist = orm_hist_table(op.table)
	int ok = 1
	if (orm_mx_pg(x)):
		ok = orm_hist_pg_drop_trigger(x, op.table, op.table)
		if (ok):
			char* base = orm_hist_base(op.table)
			ok = orm_mx_run(x, orm_mx_cat(c"DROP FUNCTION IF EXISTS ", orm_mx_ident(base), c"()", 0))
			free(base)
	else: ok = orm_hist_sqlite_drop_triggers(x, op.table)
	if (ok): ok = orm_mx_run(x, orm_mx_cat(c"DROP TABLE IF EXISTS ", orm_mx_ident(hist), 0, 0))
	free(hist)
	return ok


# ---------------------------------------------------------------------------
# Hooks the DDL generators call around schema changes. Each is a no-op for
# a table without "<table>_history".

# ADD_COLUMN: the history table gets the column too (unless the field is
# no_history), then the triggers are reinstalled.
int orm_hist_after_add_column(orm_mx_ctx* x, orm_op* op):
	char* hist = orm_hist_table(op.table)
	list[orm_hist_col*] hcols = orm_hist_live_columns(x, hist)
	int ok = 1
	if (hcols.length > 0):
		json_value* f = json_parse(op.field_json)
		char* col = orm_mx_field_column(f, op.column)
		if (col != 0 && orm_mx_jbool(f, c"no_history") == 0 && orm_hist_find(hcols, col) == 0):
			list[orm_hist_col*] base = orm_hist_live_columns(x, op.table)
			char* t = orm_hist_column_type(x, base, f, col)
			ok = orm_hist_add_column(x, hist, col, t)
			free(t)
			orm_hist_cols_free(base)
		if (ok): ok = orm_hist_refresh(x, op.table, hist)
		json_free(f)
	orm_hist_cols_free(hcols)
	free(hist)
	return ok


# DROP_COLUMN on SQLite: the triggers name the column, and SQLite refuses
# to drop a column a trigger uses, so they go first and come back after
# (orm_hist_after_drop_column). The history table keeps the column and its
# old values. PostgreSQL's trigger names no column, so nothing to do there.
int orm_hist_before_drop_column(orm_mx_ctx* x, orm_op* op):
	if (orm_mx_pg(x)): return 1
	char* hist = orm_hist_table(op.table)
	int ok = 1
	if (orm_hist_exists(x, hist)): ok = orm_hist_sqlite_drop_triggers(x, op.table)
	free(hist)
	return ok


int orm_hist_after_drop_column(orm_mx_ctx* x, orm_op* op):
	if (orm_mx_pg(x)): return 1
	char* hist = orm_hist_table(op.table)
	int ok = 1
	if (orm_hist_exists(x, hist)): ok = orm_hist_refresh(x, op.table, hist)
	free(hist)
	return ok


# SWAP_TABLES (the last step of a table rebuild): the history triggers
# followed the old rows' table, which now carries op.table's name. They
# move to op.source_table, the rebuilt table, and PostgreSQL history column
# types follow the new shape. Columns the rebuild added are picked up by
# the CREATE_HISTORY the autodetector plans after a rebuild.
int orm_hist_after_swap(orm_mx_ctx* x, orm_op* op):
	char* table = op.source_table
	char* hist = orm_hist_table(table)
	int ok = 1
	if (orm_hist_exists(x, hist)):
		if (orm_mx_pg(x)):
			ok = orm_hist_pg_drop_trigger(x, table, op.table)
			if (ok): ok = orm_hist_sync_types(x, table, hist)
		if (ok): ok = orm_hist_refresh(x, table, hist)
	free(hist)
	return ok


# RENAME_TABLE: "<old>_history" is renamed along with its table and the
# triggers are recreated under the new name.
int orm_hist_after_rename(orm_mx_ctx* x, orm_op* op):
	char* old_hist = orm_hist_table(op.source_table)
	char* new_hist = orm_hist_table(op.table)
	int ok = 1
	if (orm_hist_exists(x, old_hist) && orm_hist_exists(x, new_hist) == 0):
		if (orm_mx_pg(x)):
			ok = orm_hist_pg_drop_trigger(x, op.source_table, op.table)
			if (ok):
				char* base = orm_hist_base(op.source_table)
				ok = orm_mx_run(x, orm_mx_cat(c"DROP FUNCTION IF EXISTS ", orm_mx_ident(base), c"()", 0))
				free(base)
		else: ok = orm_hist_sqlite_drop_triggers(x, op.source_table)
		if (ok):
			string_builder* b = string_new()
			string_append(b, c"ALTER TABLE ")
			orm_mx_ident_to(b, old_hist)
			string_append(b, c" RENAME TO ")
			orm_mx_ident_to(b, new_hist)
			ok = orm_mx_run_b(x, b)
		if (ok): ok = orm_hist_refresh(x, op.table, new_hist)
	free(old_hist)
	free(new_hist)
	return ok
