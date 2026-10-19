# w-orm migration applier (issue #754, unit U2.4; docs/projects/orm/u2_4.md).
#
#   int   orm_migrate_apply(orm_db* db, list[orm_migration*] ms, int force)
#   list[orm_migration*] orm_migrate_upto(list[orm_migration*] ms, char* name)
#   char* orm_migrate_sql(orm_db* db, list[orm_migration*] ms, char* name)
#   char* orm_migrate_status(orm_db* db, list[orm_migration*] ms)
#   int   orm_migrate_unapply(orm_db* db, orm_migration* m)
#
# Applied migrations are recorded in orm_migrations(app, name, applied_at,
# run); `run` numbers apply calls, so "applied in an earlier deploy" is
# checkable. PostgreSQL applies hold pg_advisory_lock(ORM_MIGRATE_LOCK_KEY).
import libs.standard.orm.migrate.ddl_sqlite
import libs.standard.orm.migrate.ddl_postgres
import libs.standard.orm.migrate.backfill
import libs.standard.orm.migrate.lint


const int ORM_MIGRATE_LOCK_KEY = 754754


struct orm_applied_row:
	char* key            # "app.name"
	char* applied_at
	int run


char* orm_migration_key(char* app, char* name):
	if (app == 0): app = c""
	return orm_mx_cat(app, c".", name, 0)


# A reference from requires_applied / dependencies: "app.name", or a bare
# name in the referring migration's app.
char* orm_migration_ref_key(orm_migration* m, char* ref):
	if (index_of(ref, c".") >= 0): return strclone(ref)
	return orm_migration_key(m.app, ref)


int orm_migrate_ensure_table(orm_mx_ctx* x):
	if (orm_mx_pg(x)): return orm_mx_exec(x, c"CREATE TABLE IF NOT EXISTS orm_migrations (id BIGSERIAL PRIMARY KEY, app VARCHAR(255) NOT NULL, name VARCHAR(255) NOT NULL, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, run INTEGER NOT NULL DEFAULT 0, UNIQUE (app, name))")
	return orm_mx_exec(x, c"CREATE TABLE IF NOT EXISTS orm_migrations (id INTEGER PRIMARY KEY, app VARCHAR(255) NOT NULL, name VARCHAR(255) NOT NULL, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, run INTEGER NOT NULL DEFAULT 0, UNIQUE (app, name))")


# Recorded migrations in apply order; empty when the table does not exist.
list[orm_applied_row*] orm_migrate_load(orm_db* db):
	list[orm_applied_row*] out = new list[orm_applied_row*]
	sql_result* r = sql_query(db.conn, c"SELECT app, name, applied_at, run FROM orm_migrations ORDER BY id")
	if (r == 0): return out
	for i in range(r.rows):
		orm_applied_row* a = new orm_applied_row()
		a.key = orm_migration_key(sql_value(r, i, 0), sql_value(r, i, 1))
		a.applied_at = strclone(sql_value(r, i, 2))
		a.run = atoi(sql_value(r, i, 3))
		out.push(a)
	sql_result_free(r)
	return out


void orm_migrate_rows_free(list[orm_applied_row*] rows):
	for orm_applied_row* a in rows:
		free(a.key)
		free(a.applied_at)
		free(cast(void*, a))
	rows.free()


orm_applied_row* orm_migrate_find(list[orm_applied_row*] rows, char* key):
	for orm_applied_row* a in rows:
		if (strcmp(a.key, key) == 0): return a
	return 0


int orm_migrate_is_applied(orm_db* db, char* app, char* name):
	list[orm_applied_row*] rows = orm_migrate_load(db)
	char* key = orm_migration_key(app, name)
	int found = orm_migrate_find(rows, key) != 0
	free(key)
	orm_migrate_rows_free(rows)
	return found


# Pre-scan (first model_json per model name), then replay the CREATE_TABLE
# ops of already recorded migrations in order so renamed tables resolve to
# their current name; pending migrations update the map as they run.
void orm_migrate_note_models(orm_mx_ctx* x, list[orm_migration*] ms, list[orm_applied_row*] applied):
	for orm_migration* m in ms:
		for orm_op* op in m.ops: orm_mx_note_model(x, op.model_json, 0)
	for orm_migration* m in ms:
		char* key = orm_migration_key(m.app, m.name)
		if (orm_migrate_find(applied, key) != 0):
			for orm_op* op in m.ops:
				if (op.kind == ORM_OP_CREATE_TABLE): orm_mx_note_model(x, op.model_json, 1)
		free(key)


# ---------------------------------------------------------------------------
# Ops

int orm_migrate_backfill(orm_mx_ctx* x, orm_op* op):
	char* name = op.sql
	if (name == 0): name = op.name
	if (name == 0): return orm_mx_fail(x, c"BACKFILL without a name", 0, 0)
	orm_backfill_fn* f = orm_backfill_lookup(name)
	if (x.dry):
		string_builder* b = string_new()
		string_append(b, c"backfill ")
		string_append(b, name)
		string_append(b, c": W function, batches of ")
		string_append_int(b, op.batch_size)
		if (f == 0): string_append(b, c" (not registered in this program)")
		char* text = orm_mx_take(b)
		orm_mx_comment(x, text)
		free(text)
		return 1
	if (f == 0): return orm_mx_fail(x, c"no backfill registered as '", name, c"' (orm_backfill_register)")
	int batch = op.batch_size
	if (batch <= 0): batch = 1000
	while (1):
		int own = x.in_transaction == 0
		if (own && orm_mx_begin(x) == 0): return 0
		orm_db_set_error(x.db, c"")
		int n = f(x.db, batch)
		if (n < 0):
			char* why = strclone(orm_db_error(x.db))
			orm_mx_fail(x, c"backfill ", name, c" failed: ")
			char* full = orm_mx_cat(orm_db_error(x.db), why, 0, 0)
			orm_db_set_error(x.db, full)
			free(full)
			free(why)
			if (own): orm_mx_rollback(x)
			return 0
		if (own && orm_mx_commit(x) == 0): return 0
		if (n == 0): break
	return 1


int orm_migrate_op(orm_mx_ctx* x, orm_op* op):
	int k = op.kind
	if (orm_op_runs_on(op, x.dialect) == 0):
		# Another dialect's op (orm_op.dialects): nothing to do here.
		char* note = orm_mx_cat(orm_op_kind_name(k), c" skipped: not for this dialect", 0, 0)
		orm_mx_comment(x, note)
		free(note)
		return 1
	if (k == ORM_OP_CREATE_TABLE): return orm_mx_create_table(x, op)
	if (k == ORM_OP_RAW_SQL):
		if (op.sql == 0): return orm_mx_fail(x, c"RAW_SQL without sql", 0, 0)
		return orm_mx_raw_sql(x, op.sql)
	if (k == ORM_OP_BACKFILL): return orm_migrate_backfill(x, op)
	if (k == ORM_OP_CREATE_HISTORY): return orm_hist_create(x, op)
	if (k == ORM_OP_DROP_HISTORY): return orm_hist_drop(x, op)
	int r = -1
	if (orm_mx_pg(x)): r = orm_pg_op(x, op)
	else: r = orm_sqlite_op(x, op)
	if (r < 0): return orm_mx_fail(x, c"unknown migration op kind ", orm_op_kind_name(k), 0)
	return r


# Prefixes the current error with "app.name op N (KIND): ".
void orm_migrate_blame(orm_mx_ctx* x, orm_migration* m, int index, orm_op* op):
	string_builder* b = string_new()
	string_append(b, m.app)
	string_append(b, c".")
	string_append(b, m.name)
	if (op != 0):
		string_append(b, c" op ")
		string_append_int(b, index)
		string_append(b, c" (")
		string_append(b, orm_op_kind_name(op.kind))
		string_append(b, c")")
	string_append(b, c": ")
	string_append(b, orm_db_error(x.db))
	char* text = orm_mx_take(b)
	orm_db_set_error(x.db, text)
	free(text)


int orm_migrate_record(orm_mx_ctx* x, orm_migration* m, int run):
	string_builder* b = string_new()
	string_append(b, c"INSERT INTO orm_migrations (app, name, applied_at, run) VALUES (")
	char* app = m.app
	if (app == 0): app = c""
	orm_mx_literal_to(b, app)
	string_append(b, c", ")
	orm_mx_literal_to(b, m.name)
	string_append(b, c", CURRENT_TIMESTAMP, ")
	string_append_int(b, run)
	string_append(b, c")")
	return orm_mx_run_b(x, b)


# One migration: atomic ones in a single transaction (ops, deferred
# statements, the orm_migrations row); non-atomic ones op by op, each
# ordinary op in its own transaction and non_atomic ops (CONCURRENTLY,
# batched copies, backfills) outside one.
int orm_migrate_run_one(orm_mx_ctx* x, orm_migration* m, int run):
	if (x.dry):
		string_builder* h = string_new()
		string_append(h, m.app)
		string_append(h, c".")
		string_append(h, m.name)
		if (m.atomic): string_append(h, c" (atomic)")
		else: string_append(h, c" (non-atomic)")
		char* head = orm_mx_take(h)
		orm_mx_comment(x, head)
		free(head)
	if (m.atomic):
		if (orm_mx_begin(x) == 0): return 0
		for i in range(m.ops.length):
			orm_op* op = m.ops[i]
			if (orm_migrate_op(x, op) == 0):
				orm_migrate_blame(x, m, i, op)
				orm_mx_rollback(x)
				return 0
		if (orm_mx_run_deferred(x) == 0 || orm_migrate_record(x, m, run) == 0):
			orm_migrate_blame(x, m, -1, 0)
			orm_mx_rollback(x)
			return 0
		if (orm_mx_commit(x) == 0):
			orm_migrate_blame(x, m, -1, 0)
			return 0
		return 1
	for i in range(m.ops.length):
		orm_op* op = m.ops[i]
		if (op.non_atomic):
			if (orm_migrate_op(x, op) == 0):
				orm_migrate_blame(x, m, i, op)
				return 0
			continue
		if (orm_mx_begin(x) == 0): return 0
		if (orm_migrate_op(x, op) == 0):
			orm_migrate_blame(x, m, i, op)
			orm_mx_rollback(x)
			return 0
		if (orm_mx_commit(x) == 0):
			orm_migrate_blame(x, m, i, op)
			return 0
	if (orm_mx_begin(x) == 0): return 0
	if (orm_mx_run_deferred(x) == 0 || orm_migrate_record(x, m, run) == 0):
		orm_migrate_blame(x, m, -1, 0)
		orm_mx_rollback(x)
		return 0
	if (orm_mx_commit(x) == 0):
		orm_migrate_blame(x, m, -1, 0)
		return 0
	return 1


# ---------------------------------------------------------------------------
# Pre-flight checks, all done before anything runs

int orm_migrate_pending_before(list[orm_migration*] pending, int upto, char* key):
	for i in range(upto):
		orm_migration* p = pending[i]
		char* k = orm_migration_key(p.app, p.name)
		int same = strcmp(k, key) == 0
		free(k)
		if (same): return 1
	return 0


# 1 when no migration of `app` is recorded: a brand-new database (for that
# app) has no old code running, so a contract step may follow its expand
# step in the same apply run.
int orm_migrate_app_fresh(list[orm_applied_row*] applied, char* app):
	char* prefix = orm_migration_key(app, c"")
	int fresh = 1
	for orm_applied_row* a in applied:
		if (starts_with_at(a.key, prefix, 0)): fresh = 0
	free(prefix)
	return fresh


int orm_migrate_check(orm_mx_ctx* x, list[orm_migration*] pending, list[orm_applied_row*] applied, int force):
	for i in range(pending.length):
		orm_migration* m = pending[i]
		char* mkey = orm_migration_key(m.app, m.name)
		list[orm_lint_finding*] findings = orm_lint_migration(m, x.dialect)
		int errors = orm_lint_count(findings, ORM_LINT_ERROR)
		if (errors > 0 && force == 0):
			char* text = orm_lint_format(findings)
			orm_mx_fail(x, mkey, c": refused by the migration linter (pass force to override):\n", text)
			free(text)
			orm_lint_free(findings)
			free(mkey)
			return 0
		orm_lint_free(findings)
		for j in range(m.ops.length):
			orm_op* op = m.ops[j]
			if (op.unsafe && force == 0):
				orm_mx_fail(x, mkey, c": op ", orm_op_kind_name(op.kind))
				char* t = orm_mx_cat(orm_db_error(x.db), c" is marked unsafe (pass force to apply it)", 0, 0)
				orm_db_set_error(x.db, t)
				free(t)
				free(mkey)
				return 0
		if (m.requires_applied != 0):
			char* r = orm_migration_ref_key(m, m.requires_applied)
			int ok = 1
			if (orm_migrate_find(applied, r) == 0):
				if (orm_migrate_pending_before(pending, i, r)):
					if (force == 0 && orm_migrate_app_fresh(applied, m.app) == 0):
						orm_mx_fail(x, mkey, c": requires ", r)
						char* t2 = orm_mx_cat(orm_db_error(x.db), c" to be applied by an earlier deploy, not in the same apply run (pass force to override)", 0, 0)
						orm_db_set_error(x.db, t2)
						free(t2)
						ok = 0
				else:
					orm_mx_fail(x, mkey, c": requires ", r)
					char* t3 = orm_mx_cat(orm_db_error(x.db), c", which is not applied", 0, 0)
					orm_db_set_error(x.db, t3)
					free(t3)
					ok = 0
			free(r)
			if (ok == 0):
				free(mkey)
				return 0
		for char* dep in m.dependencies:
			char* d = orm_migration_ref_key(m, dep)
			int known = orm_migrate_find(applied, d) != 0 || orm_migrate_pending_before(pending, i, d)
			if (known == 0):
				orm_mx_fail(x, mkey, c": depends on ", d)
				char* t4 = orm_mx_cat(orm_db_error(x.db), c", which is neither applied nor earlier in the migration list", 0, 0)
				orm_db_set_error(x.db, t4)
				free(t4)
				free(d)
				free(mkey)
				return 0
			free(d)
		free(mkey)
	return 1


list[orm_migration*] orm_migrate_pending(list[orm_migration*] ms, list[orm_applied_row*] applied):
	list[orm_migration*] pending = new list[orm_migration*]
	for orm_migration* m in ms:
		char* key = orm_migration_key(m.app, m.name)
		if (orm_migrate_find(applied, key) == 0): pending.push(m)
		free(key)
	return pending


# ---------------------------------------------------------------------------
# Public entry points

# Applies every migration of `ms` not yet recorded, in list order. Before
# running anything it lints each pending migration (errors refuse unless
# force), refuses ops marked unsafe unless force, and checks
# requires_applied (the named migration must have been recorded by an
# earlier apply run; force, or an app with no recorded migration yet, also
# accepts one earlier in this run) and dependencies. Returns the number
# applied, or -1 with orm_db_error set; a failing migration is rolled back
# (atomic) and stops the run.
int orm_migrate_apply(orm_db* db, list[orm_migration*] ms, int force):
	orm_db_set_error(db, c"")
	orm_mx_ctx* x = orm_mx_new(db, 0)
	if (orm_migrate_ensure_table(x) == 0): return -1
	int pg = orm_mx_pg(x)
	if (pg):
		string_builder* lb = string_new()
		string_append(lb, c"SELECT pg_advisory_lock(")
		string_append_int(lb, ORM_MIGRATE_LOCK_KEY)
		string_append(lb, c")")
		if (orm_mx_run_b(x, lb) == 0): return -1
	list[orm_applied_row*] applied = orm_migrate_load(db)
	orm_migrate_note_models(x, ms, applied)
	int run = 1
	for orm_applied_row* a in applied:
		if (a.run >= run): run = a.run + 1
	list[orm_migration*] pending = orm_migrate_pending(ms, applied)
	int count = -1
	if (orm_migrate_check(x, pending, applied, force)):
		count = 0
		for orm_migration* m in pending:
			if (orm_migrate_run_one(x, m, run) == 0):
				count = -1
				break
			count = count + 1
	if (pg):
		char* keep = strclone(orm_db_error(db))
		string_builder* ub = string_new()
		string_append(ub, c"SELECT pg_advisory_unlock(")
		string_append_int(ub, ORM_MIGRATE_LOCK_KEY)
		string_append(ub, c")")
		orm_mx_run_b(x, ub)
		orm_db_set_error(db, keep)
		free(keep)
	pending.free()
	orm_migrate_rows_free(applied)
	return count


# The prefix of `ms` up to and including migration `name` ("0003_x" or
# "app.0003_x"); 0 when no migration has that name. The list is new (the
# migrations are shared): free it with .free().
list[orm_migration*] orm_migrate_upto(list[orm_migration*] ms, char* name):
	list[orm_migration*] out = new list[orm_migration*]
	for orm_migration* m in ms:
		out.push(m)
		char* key = orm_migration_key(m.app, m.name)
		int hit = strcmp(name, m.name) == 0 || strcmp(name, key) == 0
		free(key)
		if (hit): return out
	out.free()
	return 0


# The SQL apply would run, without running it: every pending migration, or
# only `name` ("0003_x" or "app.0003_x", applied or not). Catalog lookups
# still read the live database so rebuilds and casts match it. Batched
# copies print one statement with :last/:upper keyset bounds, backfills a
# comment. Returns owned text, or 0 with orm_db_error set.
char* orm_migrate_sql(orm_db* db, list[orm_migration*] ms, char* name):
	orm_db_set_error(db, c"")
	orm_mx_ctx* x = orm_mx_new(db, 1)
	list[orm_applied_row*] applied = orm_migrate_load(db)
	orm_migrate_note_models(x, ms, applied)
	int found = 0
	int ok = 1
	for orm_migration* m in ms:
		char* key = orm_migration_key(m.app, m.name)
		int pick = 0
		if (name == 0): pick = orm_migrate_find(applied, key) == 0
		else: pick = strcmp(name, m.name) == 0 || strcmp(name, key) == 0
		free(key)
		if (pick == 0): continue
		found = found + 1
		orm_db_set_error(db, c"")
		if (orm_migrate_run_one(x, m, 0) == 0):
			ok = 0
			break
	orm_migrate_rows_free(applied)
	if (ok && name != 0 && found == 0):
		orm_mx_fail(x, c"no migration named ", name, 0)
		ok = 0
	if (ok == 0):
		string_free(x.out)
		return 0
	return orm_mx_take(x.out)


# One line per migration in list order, then recorded ones the list lacks:
#   [X] library.0001_initial (applied 2026-10-19 12:00:00, run 1)
#   [ ] library.0003_contract_book_title (pending, requires library.0002_expand_book_title)
#   [?] library.0000_gone (applied, not in the migration list)
char* orm_migrate_status(orm_db* db, list[orm_migration*] ms):
	list[orm_applied_row*] applied = orm_migrate_load(db)
	list[char*] listed = new list[char*]
	string_builder* b = string_new()
	for orm_migration* m in ms:
		char* key = orm_migration_key(m.app, m.name)
		listed.push(key)
		orm_applied_row* a = orm_migrate_find(applied, key)
		if (a != 0):
			string_append(b, c"[X] ")
			string_append(b, key)
			string_append(b, c" (applied ")
			string_append(b, a.applied_at)
			string_append(b, c", run ")
			string_append_int(b, a.run)
			string_append(b, c")\n")
			continue
		string_append(b, c"[ ] ")
		string_append(b, key)
		string_append(b, c" (pending")
		if (m.atomic == 0): string_append(b, c", non-atomic")
		if (m.requires_applied != 0):
			char* r = orm_migration_ref_key(m, m.requires_applied)
			string_append(b, c", requires ")
			string_append(b, r)
			free(r)
		string_append(b, c")\n")
	for orm_applied_row* a in applied:
		if (orm_mx_list_has(listed, a.key) == 0):
			string_append(b, c"[?] ")
			string_append(b, a.key)
			string_append(b, c" (applied, not in the migration list)\n")
	orm_mx_free_strings(listed)
	orm_migrate_rows_free(applied)
	return orm_mx_take(b)


# The inverse of an op, or 0 when it has none.
orm_op* orm_migrate_inverse(orm_op* op):
	int k = op.kind
	orm_op* r = 0
	if (k == ORM_OP_RAW_SQL && op.reverse_sql != 0):
		r = orm_op_new(ORM_OP_RAW_SQL, op.phase, op.table)
		r.sql = op.reverse_sql
	else if (k == ORM_OP_CREATE_TABLE): r = orm_op_new(ORM_OP_DROP_TABLE, op.phase, op.table)
	else if (k == ORM_OP_ADD_COLUMN):
		r = orm_op_new(ORM_OP_DROP_COLUMN, op.phase, op.table)
		r.column = op.column
	else if (k == ORM_OP_ADD_INDEX): r = orm_op_new(ORM_OP_DROP_INDEX, op.phase, op.table)
	else if (k == ORM_OP_ADD_CONSTRAINT): r = orm_op_new(ORM_OP_DROP_CONSTRAINT, op.phase, op.table)
	else if (k == ORM_OP_SYNC_TRIGGER): r = orm_op_new(ORM_OP_DROP_SYNC_TRIGGER, op.phase, op.table)
	else if (k == ORM_OP_CREATE_HISTORY): r = orm_op_new(ORM_OP_DROP_HISTORY, op.phase, op.table)
	else if (k == ORM_OP_VALIDATE_CONSTRAINT || k == ORM_OP_COPY_COLUMN || k == ORM_OP_COPY_TABLE || k == ORM_OP_BACKFILL):
		r = orm_op_new(ORM_OP_RAW_SQL, op.phase, op.table)
	if (r == 0): return 0
	if (r.kind != ORM_OP_RAW_SQL || k == ORM_OP_RAW_SQL):
		r.column = op.column
		r.name = op.name
		r.source_table = op.source_table
		r.source_column = op.source_column
	r.non_atomic = op.non_atomic
	r.dialects = op.dialects
	return r


# Rolls back one recorded migration in a single transaction: RAW_SQL runs
# its reverse_sql, CREATE_TABLE / ADD_COLUMN / ADD_INDEX / ADD_CONSTRAINT /
# SYNC_TRIGGER / CREATE_HISTORY are dropped, data ops (copies, backfills,
# validation) are no-ops. Any other op refuses the whole unapply. Returns
# 1, or 0 with orm_db_error set.
int orm_migrate_unapply(orm_db* db, orm_migration* m):
	orm_db_set_error(db, c"")
	orm_mx_ctx* x = orm_mx_new(db, 0)
	if (orm_migrate_is_applied(db, m.app, m.name) == 0): return orm_mx_fail(x, m.name, c" is not applied", 0)
	list[orm_op*] inv = new list[orm_op*]
	int i = m.ops.length - 1
	while (i >= 0):
		orm_op* r = orm_migrate_inverse(m.ops[i])
		if (r == 0):
			for orm_op* o in inv: free(cast(void*, o))
			inv.free()
			return orm_mx_fail(x, m.name, c": cannot unapply op ", orm_op_kind_name(m.ops[i].kind))
		inv.push(r)
		i = i - 1
	int ok = orm_mx_begin(x)
	for orm_op* op in inv:
		if (ok == 0): break
		if (op.kind == ORM_OP_RAW_SQL && op.sql == 0): continue
		op.non_atomic = 0
		if (orm_migrate_op(x, op) == 0): ok = 0
	if (ok):
		string_builder* b = string_new()
		string_append(b, c"DELETE FROM orm_migrations WHERE app = ")
		char* app = m.app
		if (app == 0): app = c""
		orm_mx_literal_to(b, app)
		string_append(b, c" AND name = ")
		orm_mx_literal_to(b, m.name)
		ok = orm_mx_run_b(x, b)
	if (ok): ok = orm_mx_commit(x)
	else: orm_mx_rollback(x)
	for orm_op* o in inv: free(cast(void*, o))
	inv.free()
	return ok
