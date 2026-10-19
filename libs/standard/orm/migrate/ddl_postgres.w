# w-orm migration DDL for PostgreSQL (issue #754, unit U2.4).
#
# Constraints are added NOT VALID and validated by a later op, indexes in
# non-atomic migrations are built CONCURRENTLY, dual-write triggers are
# PL/pgSQL functions (BEFORE ROW for column pairs, AFTER ROW with a
# transaction-local recursion guard for table pairs). Catalog lookups use
# to_regclass so a missing table never aborts the migration's transaction.
import libs.standard.orm.migrate.ddl_common


# "to_regclass(quote_ident('t'))"
void orm_pg_regclass_to(string_builder* b, char* table):
	string_append(b, c"to_regclass(quote_ident(")
	orm_mx_literal_to(b, table)
	string_append(b, c"))")


list[char*] orm_pg_columns(orm_mx_ctx* x, char* table):
	string_builder* b = string_new()
	string_append(b, c"SELECT attname FROM pg_attribute WHERE attrelid = ")
	orm_pg_regclass_to(b, table)
	string_append(b, c" AND attnum > 0 AND NOT attisdropped ORDER BY attnum")
	char* q = orm_mx_take(b)
	list[char*] out = orm_mx_column_list(x, q)
	free(q)
	return out


char* orm_pg_pk(orm_mx_ctx* x, char* table):
	string_builder* b = string_new()
	string_append(b, c"SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) WHERE i.indisprimary AND i.indrelid = ")
	orm_pg_regclass_to(b, table)
	string_append(b, c" LIMIT 1")
	char* q = orm_mx_take(b)
	char* pk = orm_mx_scalar(x, q)
	free(q)
	if (pk == 0): return strclone(c"id")
	return pk


# format_type() of table.column, or 0.
char* orm_pg_column_type(orm_mx_ctx* x, char* table, char* column):
	string_builder* b = string_new()
	string_append(b, c"SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE NOT attisdropped AND attrelid = ")
	orm_pg_regclass_to(b, table)
	string_append(b, c" AND attname = ")
	orm_mx_literal_to(b, column)
	char* q = orm_mx_take(b)
	char* t = orm_mx_scalar(x, q)
	free(q)
	return t


# Sequence behind a serial / identity column, or 0.
char* orm_pg_serial_sequence(orm_mx_ctx* x, char* table, char* column):
	string_builder* b = string_new()
	string_append(b, c"SELECT CASE WHEN ")
	orm_pg_regclass_to(b, table)
	string_append(b, c" IS NULL THEN NULL ELSE pg_get_serial_sequence(quote_ident(")
	orm_mx_literal_to(b, table)
	string_append(b, c"), ")
	orm_mx_literal_to(b, column)
	string_append(b, c") END")
	char* q = orm_mx_take(b)
	char* s = orm_mx_scalar(x, q)
	free(q)
	return s


int orm_pg_exists(orm_mx_ctx* x, char* q):
	char* v = orm_mx_scalar(x, q)
	free(q)
	if (v == 0): return 0
	free(v)
	return 1


int orm_pg_constraint_exists(orm_mx_ctx* x, char* table, char* name):
	string_builder* b = string_new()
	string_append(b, c"SELECT 1 FROM pg_constraint WHERE conrelid = ")
	orm_pg_regclass_to(b, table)
	string_append(b, c" AND conname = ")
	orm_mx_literal_to(b, name)
	return orm_pg_exists(x, orm_mx_take(b))


char* orm_pg_alter(char* table):
	return orm_mx_cat(c"ALTER TABLE ", orm_mx_ident(table), c" ", 0)


# ---------------------------------------------------------------------------
# Ops

int orm_pg_add_column(orm_mx_ctx* x, orm_op* op):
	json_value* f = json_parse(op.field_json)
	if (f == 0): return orm_mx_fail(x, c"ADD_COLUMN: field_json is missing or not JSON on ", op.table, 0)
	char* def = orm_mx_column_def(x, f, op.column, 1)
	json_free(f)
	if (def == 0): return 0
	return orm_mx_run(x, orm_mx_cat(c"ALTER TABLE ", orm_mx_ident(op.table), c" ADD COLUMN ", def))


int orm_pg_alter_null(orm_mx_ctx* x, orm_op* op):
	json_value* f = json_parse(op.field_json)
	char* col = orm_mx_field_column(f, op.column)
	if (col == 0):
		json_free(f)
		return orm_mx_fail(x, c"ALTER_NULL without a column on ", op.table, 0)
	string_builder* b = string_new()
	string_append(b, c"ALTER TABLE ")
	orm_mx_ident_to(b, op.table)
	string_append(b, c" ALTER COLUMN ")
	orm_mx_ident_to(b, col)
	if (orm_mx_jbool(f, c"null")): string_append(b, c" DROP NOT NULL")
	else: string_append(b, c" SET NOT NULL")
	json_free(f)
	return orm_mx_run_b(x, b)


int orm_pg_concurrent(orm_mx_ctx* x, orm_op* op):
	return op.non_atomic && x.in_transaction == 0


int orm_pg_add_index(orm_mx_ctx* x, orm_op* op):
	json_value* f = json_parse(op.field_json)
	json_value* cols = orm_mx_jget(f, c"columns")
	json_value* own = 0
	if (orm_mx_jarray_len(cols) == 0):
		if (op.column == 0):
			json_free(f)
			return orm_mx_fail(x, c"ADD_INDEX without columns on ", op.table, 0)
		own = json_array()
		json_array_push(own, json_string(op.column))
		cols = own
	char* name = op.name
	char* made = 0
	if (name == 0):
		made = orm_mx_name(op.table, c"_", op.column, c"_idx")
		name = made
	int concurrently = orm_pg_concurrent(x, op)
	int ok = 1
	if (concurrently):
		# A failed CONCURRENTLY build leaves an INVALID index behind that
		# IF NOT EXISTS would keep; drop it so a re-run rebuilds.
		string_builder* q = string_new()
		string_append(q, c"SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE NOT i.indisvalid AND c.relname = ")
		orm_mx_literal_to(q, name)
		if (orm_pg_exists(x, orm_mx_take(q))):
			ok = orm_mx_run(x, orm_mx_cat(c"DROP INDEX CONCURRENTLY IF EXISTS ", orm_mx_ident(name), 0, 0))
	if (ok): ok = orm_mx_index_sql(x, name, op.table, cols, orm_mx_jbool(f, c"unique"), orm_mx_jstr(f, c"condition"), concurrently)
	if (made != 0): free(made)
	json_free(own)
	json_free(f)
	return ok


int orm_pg_drop_index(orm_mx_ctx* x, orm_op* op):
	char* head = c"DROP INDEX IF EXISTS "
	if (orm_pg_concurrent(x, op)): head = c"DROP INDEX CONCURRENTLY IF EXISTS "
	return orm_mx_run(x, orm_mx_cat(head, orm_mx_ident(op.name), 0, 0))


int orm_pg_add_constraint(orm_mx_ctx* x, orm_op* op):
	if (op.name == 0 || op.sql == 0): return orm_mx_fail(x, c"ADD_CONSTRAINT needs name and sql on ", op.table, 0)
	if (x.dry == 0 && orm_pg_constraint_exists(x, op.table, op.name)): return 1
	string_builder* b = string_new()
	string_append(b, c"ALTER TABLE ")
	orm_mx_ident_to(b, op.table)
	string_append(b, c" ADD CONSTRAINT ")
	orm_mx_ident_to(b, op.name)
	string_append(b, c" ")
	string_append(b, op.sql)
	if (orm_mx_starts_ci(op.sql, c"check") || orm_mx_starts_ci(op.sql, c"foreign")): string_append(b, c" NOT VALID")
	return orm_mx_run_b(x, b)


int orm_pg_constraint_op(orm_mx_ctx* x, orm_op* op, char* verb):
	string_builder* b = string_new()
	string_append(b, c"ALTER TABLE ")
	orm_mx_ident_to(b, op.table)
	string_append(b, verb)
	orm_mx_ident_to(b, op.name)
	return orm_mx_run_b(x, b)


# CAST(<expr> AS <type of table.column>), or the bare expression when the
# column is not in the live schema (collect mode before it exists).
void orm_pg_cast_to(orm_mx_ctx* x, string_builder* b, char* expr, char* table, char* column):
	char* t = orm_pg_column_type(x, table, column)
	if (t == 0):
		string_append(b, expr)
		return
	string_append(b, c"CAST(")
	string_append(b, expr)
	string_append(b, c" AS ")
	string_append(b, t)
	string_append(b, c")")
	free(t)


int orm_pg_copy_column(orm_mx_ctx* x, orm_op* op):
	char* pk = orm_pg_pk(x, op.table)
	string_builder* p = string_new()
	string_append(p, c"UPDATE ")
	orm_mx_ident_to(p, op.table)
	string_append(p, c" SET ")
	orm_mx_ident_to(p, op.column)
	string_append(p, c" = ")
	char* src = orm_mx_ident(op.source_column)
	orm_pg_cast_to(x, p, src, op.table, op.column)
	free(src)
	string_append(p, c" WHERE ")
	orm_mx_ident_to(p, op.column)
	string_append(p, c" IS NULL AND ")
	orm_mx_ident_to(p, op.source_column)
	string_append(p, c" IS NOT NULL AND ")
	char* prefix = orm_mx_take(p)
	int ok = orm_mx_batched(x, op.table, pk, op.batch_size, prefix, c"")
	free(prefix)
	free(pk)
	return ok


void orm_pg_assign_to(orm_mx_ctx* x, string_builder* b, char* table, char* to, char* from):
	string_append(b, c"NEW.")
	orm_mx_ident_to(b, to)
	string_append(b, c" := ")
	char* e = orm_mx_cat(c"NEW.", orm_mx_ident(from), 0, 0)
	orm_pg_cast_to(x, b, e, table, to)
	free(e)
	string_append(b, c";")


# Column pair: one BEFORE INSERT OR UPDATE trigger fills whichever side the
# writing code left alone. It changes NEW in place, so it never re-fires.
int orm_pg_sync_columns(orm_mx_ctx* x, orm_op* op):
	char* base = orm_mx_sync_column_name(op)
	char* qn = orm_mx_ident(op.column)
	char* qo = orm_mx_ident(op.source_column)
	string_builder* b = string_new()
	string_append(b, c"CREATE OR REPLACE FUNCTION ")
	orm_mx_ident_to(b, base)
	string_append(b, c"() RETURNS trigger LANGUAGE plpgsql AS $w_orm$ BEGIN IF TG_OP = 'INSERT' THEN IF NEW.")
	string_append(b, qn)
	string_append(b, c" IS NULL AND NEW.")
	string_append(b, qo)
	string_append(b, c" IS NOT NULL THEN ")
	orm_pg_assign_to(x, b, op.table, op.column, op.source_column)
	string_append(b, c" ELSIF NEW.")
	string_append(b, qo)
	string_append(b, c" IS NULL AND NEW.")
	string_append(b, qn)
	string_append(b, c" IS NOT NULL THEN ")
	orm_pg_assign_to(x, b, op.table, op.source_column, op.column)
	string_append(b, c" END IF; ELSE IF NEW.")
	string_append(b, qo)
	string_append(b, c" IS DISTINCT FROM OLD.")
	string_append(b, qo)
	string_append(b, c" AND NEW.")
	string_append(b, qn)
	string_append(b, c" IS NOT DISTINCT FROM OLD.")
	string_append(b, qn)
	string_append(b, c" THEN ")
	orm_pg_assign_to(x, b, op.table, op.column, op.source_column)
	string_append(b, c" ELSIF NEW.")
	string_append(b, qn)
	string_append(b, c" IS DISTINCT FROM OLD.")
	string_append(b, qn)
	string_append(b, c" AND NEW.")
	string_append(b, qo)
	string_append(b, c" IS NOT DISTINCT FROM OLD.")
	string_append(b, qo)
	string_append(b, c" THEN ")
	orm_pg_assign_to(x, b, op.table, op.source_column, op.column)
	string_append(b, c" END IF; END IF; RETURN NEW; END $w_orm$")
	int ok = orm_mx_run_b(x, b)
	if (ok): ok = orm_mx_run(x, orm_mx_cat(c"DROP TRIGGER IF EXISTS ", orm_mx_ident(base), c" ON ", orm_mx_ident(op.table)))
	if (ok):
		string_builder* t = string_new()
		string_append(t, c"CREATE TRIGGER ")
		orm_mx_ident_to(t, base)
		string_append(t, c" BEFORE INSERT OR UPDATE ON ")
		orm_mx_ident_to(t, op.table)
		string_append(t, c" FOR EACH ROW EXECUTE FUNCTION ")
		orm_mx_ident_to(t, base)
		string_append(t, c"()")
		ok = orm_mx_run_b(x, t)
	free(base)
	free(qn)
	free(qo)
	return ok


# One direction of a table pair: AFTER ROW, guarded by the transaction-local
# setting w_orm.syncing so the mirrored write does not come back.
int orm_pg_sync_direction(orm_mx_ctx* x, char* from, char* to, list[char*] cols, char* pk):
	char* base = orm_mx_sync_table_name(from, to)
	char* qt = orm_mx_ident(to)
	char* qpk = orm_mx_ident(pk)
	string_builder* b = string_new()
	string_append(b, c"CREATE OR REPLACE FUNCTION ")
	orm_mx_ident_to(b, base)
	string_append(b, c"() RETURNS trigger LANGUAGE plpgsql AS $w_orm$ BEGIN IF current_setting('w_orm.syncing', true) = 'on' THEN RETURN NULL; END IF; PERFORM set_config('w_orm.syncing', 'on', true); IF TG_OP = 'INSERT' THEN INSERT INTO ")
	string_append(b, qt)
	string_append(b, c" (")
	orm_mx_list_to(b, cols, 0)
	string_append(b, c") VALUES (")
	orm_mx_list_to(b, cols, c"NEW.")
	string_append(b, c") ON CONFLICT DO NOTHING; ELSIF TG_OP = 'UPDATE' THEN UPDATE ")
	string_append(b, qt)
	string_append(b, c" SET ")
	for i in range(cols.length):
		if (i > 0): string_append(b, c", ")
		orm_mx_ident_to(b, cols[i])
		string_append(b, c" = NEW.")
		orm_mx_ident_to(b, cols[i])
	string_append(b, c" WHERE ")
	string_append(b, qpk)
	string_append(b, c" = OLD.")
	string_append(b, qpk)
	string_append(b, c"; ELSE DELETE FROM ")
	string_append(b, qt)
	string_append(b, c" WHERE ")
	string_append(b, qpk)
	string_append(b, c" = OLD.")
	string_append(b, qpk)
	string_append(b, c"; END IF; PERFORM set_config('w_orm.syncing', 'off', true); RETURN NULL; END $w_orm$")
	int ok = orm_mx_run_b(x, b)
	if (ok): ok = orm_mx_run(x, orm_mx_cat(c"DROP TRIGGER IF EXISTS ", orm_mx_ident(base), c" ON ", orm_mx_ident(from)))
	if (ok):
		string_builder* t = string_new()
		string_append(t, c"CREATE TRIGGER ")
		orm_mx_ident_to(t, base)
		string_append(t, c" AFTER INSERT OR UPDATE OR DELETE ON ")
		orm_mx_ident_to(t, from)
		string_append(t, c" FOR EACH ROW EXECUTE FUNCTION ")
		orm_mx_ident_to(t, base)
		string_append(t, c"()")
		ok = orm_mx_run_b(x, t)
	free(base)
	free(qt)
	free(qpk)
	return ok


int orm_pg_set_default_seq(orm_mx_ctx* x, char* table, char* pk, char* seq):
	string_builder* b = string_new()
	string_append(b, c"ALTER TABLE ")
	orm_mx_ident_to(b, table)
	string_append(b, c" ALTER COLUMN ")
	orm_mx_ident_to(b, pk)
	string_append(b, c" SET DEFAULT nextval(")
	orm_mx_literal_to(b, seq)
	string_append(b, c"::regclass)")
	return orm_mx_run_b(x, b)


# Table pair. While both tables take inserts they share the source table's
# id sequence, so rows written to either side never collide.
int orm_pg_sync_tables(orm_mx_ctx* x, orm_op* op):
	list[char*] a = orm_pg_columns(x, op.table)
	list[char*] b = orm_pg_columns(x, op.source_table)
	list[char*] cols = orm_mx_common_columns(a, b)
	char* pk = orm_pg_pk(x, op.source_table)
	int ok = 1
	if (cols.length == 0 && x.dry == 0): ok = orm_mx_fail(x, c"SYNC_TRIGGER: no common columns between ", op.table, c" and its source")
	if (ok): ok = orm_pg_sync_direction(x, op.source_table, op.table, cols, pk)
	if (ok): ok = orm_pg_sync_direction(x, op.table, op.source_table, cols, pk)
	char* seq = orm_pg_serial_sequence(x, op.source_table, pk)
	if (ok && seq != 0): ok = orm_pg_set_default_seq(x, op.table, pk, seq)
	if (seq != 0): free(seq)
	cols.free()
	orm_mx_free_strings(a)
	orm_mx_free_strings(b)
	free(pk)
	return ok


int orm_pg_drop_trigger_function(orm_mx_ctx* x, char* base, char* table):
	int ok = orm_mx_run(x, orm_mx_cat(c"DROP TRIGGER IF EXISTS ", orm_mx_ident(base), c" ON ", orm_mx_ident(table)))
	if (ok): ok = orm_mx_run(x, orm_mx_cat(c"DROP FUNCTION IF EXISTS ", orm_mx_ident(base), c"()", 0))
	return ok


# Gives a serial pk its own sequence back, moved past the current rows.
int orm_pg_reset_serial(orm_mx_ctx* x, char* table):
	char* pk = orm_pg_pk(x, table)
	char* seq = orm_pg_serial_sequence(x, table, pk)
	int ok = 1
	if (seq != 0):
		ok = orm_pg_set_default_seq(x, table, pk, seq)
		if (ok):
			string_builder* b = string_new()
			string_append(b, c"SELECT setval(")
			orm_mx_literal_to(b, seq)
			string_append(b, c", COALESCE(MAX(")
			orm_mx_ident_to(b, pk)
			string_append(b, c"), 0) + 1, false) FROM ")
			orm_mx_ident_to(b, table)
			ok = orm_mx_run_b(x, b)
		free(seq)
	free(pk)
	return ok


int orm_pg_drop_table_sync(orm_mx_ctx* x, char* a, char* b):
	char* ab = orm_mx_sync_table_name(a, b)
	char* ba = orm_mx_sync_table_name(b, a)
	int ok = orm_pg_drop_trigger_function(x, ab, a)
	if (ok): ok = orm_pg_drop_trigger_function(x, ba, b)
	free(ab)
	free(ba)
	return ok


int orm_pg_drop_sync(orm_mx_ctx* x, orm_op* op):
	if (op.source_table != 0):
		int ok = orm_pg_drop_table_sync(x, op.table, op.source_table)
		if (ok): ok = orm_pg_reset_serial(x, op.table)
		if (ok): ok = orm_pg_reset_serial(x, op.source_table)
		return ok
	char* base = orm_mx_sync_column_name(op)
	int ok2 = orm_pg_drop_trigger_function(x, base, op.table)
	free(base)
	return ok2


int orm_pg_copy_table(orm_mx_ctx* x, orm_op* op):
	list[char*] a = orm_pg_columns(x, op.table)
	list[char*] b = orm_pg_columns(x, op.source_table)
	list[char*] cols = orm_mx_common_columns(a, b)
	char* pk = orm_pg_pk(x, op.source_table)
	string_builder* p = string_new()
	string_append(p, c"INSERT INTO ")
	orm_mx_ident_to(p, op.table)
	string_append(p, c" (")
	orm_mx_list_to(p, cols, 0)
	string_append(p, c") SELECT ")
	orm_mx_list_to(p, cols, 0)
	string_append(p, c" FROM ")
	orm_mx_ident_to(p, op.source_table)
	string_append(p, c" WHERE NOT EXISTS (SELECT 1 FROM ")
	orm_mx_ident_to(p, op.table)
	string_append(p, c" AS w_dst WHERE w_dst.")
	orm_mx_ident_to(p, pk)
	string_append(p, c" = ")
	orm_mx_ident_to(p, op.source_table)
	string_append(p, c".")
	orm_mx_ident_to(p, pk)
	string_append(p, c") AND ")
	char* prefix = orm_mx_take(p)
	int ok = orm_mx_batched(x, op.source_table, pk, op.batch_size, prefix, c"")
	free(prefix)
	free(pk)
	cols.free()
	orm_mx_free_strings(a)
	orm_mx_free_strings(b)
	return ok


int orm_pg_rename(orm_mx_ctx* x, char* from, char* to):
	string_builder* b = string_new()
	string_append(b, c"ALTER TABLE ")
	orm_mx_ident_to(b, from)
	string_append(b, c" RENAME TO ")
	orm_mx_ident_to(b, to)
	return orm_mx_run_b(x, b)


# Renames the indexes of `table` (constraint-backed ones too, which renames
# their constraints) named `from...` to `to...`.
int orm_pg_rename_indexes(orm_mx_ctx* x, char* table, char* from, char* to):
	string_builder* b = string_new()
	string_append(b, c"SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = ")
	orm_pg_regclass_to(b, table)
	string_append(b, c" ORDER BY 1")
	char* q = orm_mx_take(b)
	list[char*] names = orm_mx_column_list(x, q)
	free(q)
	int ok = 1
	for char* name in names:
		if (ok == 0): break
		char* moved = orm_mx_reprefix(name, from, to)
		if (moved == 0): continue
		string_builder* a = string_new()
		string_append(a, c"ALTER INDEX ")
		orm_mx_ident_to(a, name)
		string_append(a, c" RENAME TO ")
		orm_mx_ident_to(a, moved)
		ok = orm_mx_run_b(x, a)
		free(moved)
	orm_mx_free_strings(names)
	return ok


# table <-> source_table. PostgreSQL FOREIGN KEYs follow a table across a
# rename, so FKs from other tables that pointed at source_table are dropped
# and re-added against the name (now the new table), NOT VALID: they are
# enforced for new writes at once and can be validated later.
int orm_pg_swap(orm_mx_ctx* x, orm_op* op):
	if (orm_pg_drop_table_sync(x, op.table, op.source_table) == 0): return 0
	string_builder* q = string_new()
	string_append(q, c"SELECT c.conrelid::regclass::text, c.conname, pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.contype = 'f' AND c.conrelid <> c.confrelid AND c.confrelid = ")
	orm_pg_regclass_to(q, op.source_table)
	string_append(q, c" AND c.conrelid IS DISTINCT FROM ")
	orm_pg_regclass_to(q, op.table)
	string_append(q, c" ORDER BY 1, 2")
	char* qs = orm_mx_take(q)
	sql_result* fks = orm_mx_query(x, qs)
	free(qs)
	if (fks == 0): return 0
	char* tmp = orm_mx_cat(op.source_table, c"__w_swap", 0, 0)
	int ok = orm_pg_rename(x, op.source_table, tmp)
	if (ok): ok = orm_pg_rename(x, op.table, op.source_table)
	if (ok): ok = orm_pg_rename(x, tmp, op.table)
	free(tmp)
	if (ok): ok = orm_pg_rename_indexes(x, op.table, op.source_table, orm_mx_swap_prefix())
	if (ok): ok = orm_pg_rename_indexes(x, op.source_table, op.table, op.source_table)
	if (ok): ok = orm_pg_rename_indexes(x, op.table, orm_mx_swap_prefix(), op.table)
	for i in range(fks.rows):
		if (ok == 0): break
		char* child = sql_value(fks, i, 0)
		string_builder* d = string_new()
		string_append(d, c"ALTER TABLE ")
		string_append(d, child)
		string_append(d, c" DROP CONSTRAINT ")
		orm_mx_ident_to(d, sql_value(fks, i, 1))
		ok = orm_mx_run_b(x, d)
		if (ok == 0): break
		string_builder* a = string_new()
		string_append(a, c"ALTER TABLE ")
		string_append(a, child)
		string_append(a, c" ADD CONSTRAINT ")
		orm_mx_ident_to(a, sql_value(fks, i, 1))
		string_append(a, c" ")
		string_append(a, sql_value(fks, i, 2))
		string_append(a, c" NOT VALID")
		ok = orm_mx_run_b(x, a)
	sql_result_free(fks)
	return ok


# Dispatch for the dialect-specific op kinds; -1 = not handled here.
int orm_pg_op(orm_mx_ctx* x, orm_op* op):
	int k = op.kind
	# CASCADE: a rebuilt table's old shadow can still hold an FK to the table
	# a rename's contract step drops (docs/projects/orm/u2_2.md, limits).
	if (k == ORM_OP_DROP_TABLE): return orm_mx_run(x, orm_mx_cat(c"DROP TABLE ", orm_mx_ident(op.table), c" CASCADE", 0))
	if (k == ORM_OP_ADD_COLUMN): return orm_pg_add_column(x, op)
	if (k == ORM_OP_DROP_COLUMN): return orm_mx_run(x, orm_mx_cat(c"ALTER TABLE ", orm_mx_ident(op.table), c" DROP COLUMN ", orm_mx_ident(op.column)))
	if (k == ORM_OP_ALTER_NULL): return orm_pg_alter_null(x, op)
	if (k == ORM_OP_ADD_INDEX): return orm_pg_add_index(x, op)
	if (k == ORM_OP_DROP_INDEX): return orm_pg_drop_index(x, op)
	if (k == ORM_OP_ADD_CONSTRAINT): return orm_pg_add_constraint(x, op)
	if (k == ORM_OP_VALIDATE_CONSTRAINT): return orm_pg_constraint_op(x, op, c" VALIDATE CONSTRAINT ")
	if (k == ORM_OP_DROP_CONSTRAINT): return orm_pg_constraint_op(x, op, c" DROP CONSTRAINT IF EXISTS ")
	if (k == ORM_OP_COPY_COLUMN): return orm_pg_copy_column(x, op)
	if (k == ORM_OP_SYNC_TRIGGER):
		if (op.source_table != 0): return orm_pg_sync_tables(x, op)
		return orm_pg_sync_columns(x, op)
	if (k == ORM_OP_DROP_SYNC_TRIGGER): return orm_pg_drop_sync(x, op)
	if (k == ORM_OP_COPY_TABLE): return orm_pg_copy_table(x, op)
	if (k == ORM_OP_SWAP_TABLES): return orm_pg_swap(x, op)
	if (k == ORM_OP_RENAME_TABLE): return orm_pg_rename(x, op.source_table, op.table)
	return -1
