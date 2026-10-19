# w-orm migration DDL for SQLite (issue #754, unit U2.4).
#
# SQLite cannot change a column's nullability or add/drop a CHECK or FOREIGN
# KEY in place, so those ops use the documented 12-step table rebuild
# (https://sqlite.org/lang_altertable.html#otheralter): create the new
# shape under a temporary name, copy the rows, drop the old table, rename,
# recreate its indexes and triggers. The applier runs it inside the
# migration's transaction with foreign keys off and checks
# PRAGMA foreign_key_check before COMMIT (ddl_common.w, orm_mx_commit).
import libs.standard.orm.history.ddl


const int ORM_SQLITE_SET_NOT_NULL = 1
const int ORM_SQLITE_DROP_NOT_NULL = 2
const int ORM_SQLITE_ADD_ITEM = 3          # arg = table-constraint text to append
const int ORM_SQLITE_DROP_CONSTRAINT = 4   # arg = constraint name


char* orm_sqlite_table_query(char* head, char* table, char* tail):
	string_builder* b = string_new()
	string_append(b, head)
	orm_mx_literal_to(b, table)
	if (tail != 0): string_append(b, tail)
	return orm_mx_take(b)


list[char*] orm_sqlite_columns(orm_mx_ctx* x, char* table):
	char* q = orm_sqlite_table_query(c"SELECT name FROM pragma_table_info(", table, c") ORDER BY cid")
	list[char*] out = orm_mx_column_list(x, q)
	free(q)
	return out


char* orm_sqlite_pk(orm_mx_ctx* x, char* table):
	char* q = orm_sqlite_table_query(c"SELECT name FROM pragma_table_info(", table, c") WHERE pk = 1")
	char* pk = orm_mx_scalar(x, q)
	free(q)
	if (pk == 0): return strclone(c"rowid")
	return pk


# 1 NOT NULL, 0 nullable, -1 no such column. *has_default (when non-null)
# is set to 1 when the column has a default.
int orm_sqlite_notnull(orm_mx_ctx* x, char* table, char* column, int* has_default):
	string_builder* b = string_new()
	string_append(b, c"SELECT \"notnull\", dflt_value IS NOT NULL FROM pragma_table_info(")
	orm_mx_literal_to(b, table)
	string_append(b, c") WHERE name = ")
	orm_mx_literal_to(b, column)
	char* q = orm_mx_take(b)
	sql_result* r = orm_mx_query(x, q)
	free(q)
	if (r == 0): return -1
	int out = -1
	if (r.rows > 0):
		out = strcmp(sql_value(r, 0, 0), c"0") != 0
		if (has_default != 0): has_default[0] = strcmp(sql_value(r, 0, 1), c"0") != 0
	sql_result_free(r)
	return out


# ---------------------------------------------------------------------------
# CREATE TABLE text surgery

int orm_sqlite_skip_quoted(char* s, int i):
	char open = s[i]
	char close = open
	if (open == '['): close = ']'
	i = i + 1
	while (s[i] != 0):
		if (s[i] == close):
			if (close != ']' && s[i + 1] == close):
				i = i + 2
				continue
			return i + 1
		i = i + 1
	return i


int orm_sqlite_is_quote(char c):
	return c == 39 || c == '"' || c == '`' || c == '['


# Body span of "CREATE TABLE x (...)": *start after "(", *end at ")".
int orm_sqlite_body(char* sql, int* start, int* end):
	int i = 0
	int depth = 0
	while (sql[i] != 0):
		char c = sql[i]
		if (orm_sqlite_is_quote(c)):
			i = orm_sqlite_skip_quoted(sql, i)
			continue
		if (c == '('):
			if (depth == 0): start[0] = i + 1
			depth = depth + 1
		if (c == ')'):
			depth = depth - 1
			if (depth == 0):
				end[0] = i
				return 1
		i = i + 1
	return 0


list[char*] orm_sqlite_items(char* sql, int start, int end):
	list[char*] items = new list[char*]
	int depth = 0
	int from = start
	int i = start
	while (i <= end):
		char c = sql[i]
		if (i < end && orm_sqlite_is_quote(c)):
			i = orm_sqlite_skip_quoted(sql, i)
			continue
		if (c == '('): depth = depth + 1
		if (c == ')' && i < end): depth = depth - 1
		if (i == end || (c == ',' && depth == 0)):
			char* raw = str_copy_range(sql, from, i)
			items.push(strip(raw))
			free(raw)
			from = i + 1
		i = i + 1
	return items


# The item's first word, unquoted (owned).
char* orm_sqlite_word(char* item, int* next):
	int i = 0
	while (item[i] == ' ' || item[i] == 9 || item[i] == 10 || item[i] == 13): i = i + 1
	if (orm_sqlite_is_quote(item[i])):
		int e = orm_sqlite_skip_quoted(item, i)
		next[0] = e
		return str_copy_range(item, i + 1, e - 1)
	int s = i
	while (item[i] != 0 && (isalnum(item[i]) || item[i] == '_')): i = i + 1
	next[0] = i
	return str_copy_range(item, s, i)


int orm_sqlite_is_word_char(char c):
	return isalnum(c) || c == '_'


# Finds "NOT NULL" at paren depth 0 outside quotes; *s/*e span it.
int orm_sqlite_find_not_null(char* item, int* s, int* e):
	int i = 0
	int depth = 0
	while (item[i] != 0):
		char c = item[i]
		if (orm_sqlite_is_quote(c)):
			i = orm_sqlite_skip_quoted(item, i)
			continue
		if (c == '('): depth = depth + 1
		if (c == ')'): depth = depth - 1
		int boundary = i == 0 || orm_sqlite_is_word_char(item[i - 1]) == 0
		if (depth == 0 && boundary && orm_mx_lower(c) == 'n' && orm_mx_starts_ci(cast(char*, &item[i]), c"not")):
			int j = i + 3
			if (item[j] == ' ' || item[j] == 9 || item[j] == 10):
				while (item[j] == ' ' || item[j] == 9 || item[j] == 10 || item[j] == 13): j = j + 1
				if (orm_mx_starts_ci(cast(char*, &item[j]), c"null") && orm_sqlite_is_word_char(item[j + 4]) == 0):
					s[0] = i
					e[0] = j + 4
					return 1
		i = i + 1
	return 0


int orm_sqlite_is_constraint_word(char* w):
	return orm_mx_streq_ci(w, c"constraint") || orm_mx_streq_ci(w, c"primary") || orm_mx_streq_ci(w, c"unique") || orm_mx_streq_ci(w, c"check") || orm_mx_streq_ci(w, c"foreign")


# The 12-step rebuild of `table` with one change to its definition.
# Returns 1 when rebuilt, 2 when the change matched nothing (the table is
# left alone), 0 on error.
# AUTOINCREMENT high-water mark: sqlite_sequence[to] becomes at least
# sqlite_sequence[from], so ids deleted from `from` are not handed out
# again once its rows live in `to` (a rebuild or a table swap).
int orm_sqlite_keep_sequence(orm_mx_ctx* x, char* to, char* from):
	char* has = orm_mx_scalar(x, c"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'")
	if (has == 0): return 1
	free(has)
	char* lt = orm_mx_literal(to)
	char* lf = orm_mx_literal(from)
	char* from_seq = orm_mx_cat(c"(SELECT seq FROM sqlite_sequence WHERE name = ", lf, c")", 0)
	string_builder* b = string_new()
	string_append(b, c"INSERT INTO sqlite_sequence (name, seq) SELECT ")
	string_append(b, lt)
	string_append(b, c", seq FROM sqlite_sequence WHERE name = ")
	string_append(b, lf)
	string_append(b, c" AND NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = ")
	string_append(b, lt)
	string_append(b, c")")
	int ok = orm_mx_run_b(x, b)
	string_builder* u = string_new()
	string_append(u, c"UPDATE sqlite_sequence SET seq = ")
	string_append(u, from_seq)
	string_append(u, c" WHERE name = ")
	string_append(u, lt)
	string_append(u, c" AND seq < ")
	string_append(u, from_seq)
	if (ok): ok = orm_mx_run_b(x, u)
	else: string_free(u)
	free(from_seq)
	free(lt)
	free(lf)
	return ok


int orm_sqlite_rebuild(orm_mx_ctx* x, char* table, int mode, char* column, char* arg):
	char* q = orm_sqlite_table_query(c"SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ", table, 0)
	char* sql = orm_mx_scalar(x, q)
	free(q)
	if (sql == 0):
		if (x.dry):
			char* note = orm_mx_cat(c"rebuild of ", table, c" needs the live table definition (not created yet)", 0)
			orm_mx_comment(x, note)
			free(note)
			return 1
		return orm_mx_fail(x, c"rebuild: no table ", table, 0)
	int start = 0
	int end = 0
	if (orm_sqlite_body(sql, &start, &end) == 0):
		free(sql)
		return orm_mx_fail(x, c"rebuild: cannot parse the definition of ", table, 0)
	list[char*] items = orm_sqlite_items(sql, start, end)
	free(sql)
	list[char*] kept = new list[char*]
	int changed = 0
	for char* item in items:
		int next = 0
		char* w = orm_sqlite_word(item, &next)
		int is_constraint = orm_sqlite_is_constraint_word(w) && orm_sqlite_is_quote(item[0]) == 0
		if ((mode == ORM_SQLITE_SET_NOT_NULL || mode == ORM_SQLITE_DROP_NOT_NULL) && is_constraint == 0 && orm_mx_streq_ci(w, column)):
			int s = 0
			int e = 0
			if (mode == ORM_SQLITE_SET_NOT_NULL && orm_sqlite_find_not_null(item, &s, &e) == 0):
				char* grown = orm_mx_cat(item, c" NOT NULL", 0, 0)
				free(item)
				item = grown
				changed = 1
			while (mode == ORM_SQLITE_DROP_NOT_NULL && orm_sqlite_find_not_null(item, &s, &e)):
				char* head = str_copy_range(item, 0, s)
				char* cut = orm_mx_cat(head, cast(char*, &item[e]), 0, 0)
				free(head)
				free(item)
				item = cut
				changed = 1
		if (mode == ORM_SQLITE_DROP_CONSTRAINT && orm_mx_streq_ci(w, c"constraint")):
			int next2 = 0
			char* cname = orm_sqlite_word(cast(char*, &item[next]), &next2)
			int match = strcmp(cname, arg) == 0
			free(cname)
			if (match):
				free(w)
				free(item)
				changed = 1
				continue
		free(w)
		kept.push(item)
	items.free()
	if (mode == ORM_SQLITE_ADD_ITEM):
		kept.push(strclone(arg))
		changed = 1
	if (changed == 0):
		orm_mx_free_strings(kept)
		return 2
	char* tmp = orm_mx_cat(table, c"__w_rebuild", 0, 0)
	string_builder* b = string_new()
	string_append(b, c"CREATE TABLE ")
	orm_mx_ident_to(b, tmp)
	string_append(b, c" (")
	for i in range(kept.length):
		if (i > 0): string_append(b, c", ")
		string_append(b, kept[i])
	string_append(b, c")")
	orm_mx_free_strings(kept)
	int ok = orm_mx_run_b(x, b)
	list[char*] cols = orm_sqlite_columns(x, table)
	if (ok):
		string_builder* ins = string_new()
		string_append(ins, c"INSERT INTO ")
		orm_mx_ident_to(ins, tmp)
		string_append(ins, c" (")
		orm_mx_list_to(ins, cols, 0)
		string_append(ins, c") SELECT ")
		orm_mx_list_to(ins, cols, 0)
		string_append(ins, c" FROM ")
		orm_mx_ident_to(ins, table)
		ok = orm_mx_run_b(x, ins)
	orm_mx_free_strings(cols)
	# SQLite fires the most recently created trigger first: history
	# triggers are recreated last so they still run before sync triggers.
	char* oq = orm_sqlite_table_query(c"SELECT sql FROM sqlite_master WHERE tbl_name = ", table, c" AND type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY type, substr(name, 1, 7) = 'w_hist_', name")
	list[char*] others = orm_mx_column_list(x, oq)
	free(oq)
	if (ok): ok = orm_sqlite_keep_sequence(x, tmp, table)
	if (ok): ok = orm_mx_run(x, orm_mx_cat(c"DROP TABLE ", orm_mx_ident(table), 0, 0))
	if (ok):
		string_builder* rn = string_new()
		string_append(rn, c"ALTER TABLE ")
		orm_mx_ident_to(rn, tmp)
		string_append(rn, c" RENAME TO ")
		orm_mx_ident_to(rn, table)
		ok = orm_mx_run_b(x, rn)
	for char* o in others:
		if (ok && orm_mx_exec(x, o) == 0): ok = 0
	orm_mx_free_strings(others)
	free(tmp)
	return ok


# ---------------------------------------------------------------------------
# Ops

char* orm_sqlite_op_column(orm_op* op, json_value* f):
	return orm_mx_field_column(f, op.column)


int orm_sqlite_add_column(orm_mx_ctx* x, orm_op* op):
	json_value* f = json_parse(op.field_json)
	if (f == 0): return orm_mx_fail(x, c"ADD_COLUMN: field_json is missing or not JSON on ", op.table, 0)
	char* def = orm_mx_column_def(x, f, op.column, 1)
	if (def == 0):
		json_free(f)
		return 0
	int ok = orm_mx_run(x, orm_mx_cat(c"ALTER TABLE ", orm_mx_ident(op.table), c" ADD COLUMN ", def))
	free(def)
	if (ok && orm_mx_jbool(f, c"unique")):
		char* col = orm_sqlite_op_column(op, f)
		char* name = orm_mx_name(op.table, c"_", col, c"_uniq")
		json_value* one = json_array()
		json_array_push(one, json_string(col))
		ok = orm_mx_index_sql(x, name, op.table, one, 1, 0, 0)
		json_free(one)
		free(name)
	json_free(f)
	if (ok): ok = orm_hist_after_add_column(x, op)
	return ok


# SQLite refuses DROP COLUMN on an indexed column, so plain indexes that
# cover it go first (UNIQUE / PRIMARY KEY columns still fail: document).
int orm_sqlite_drop_column(orm_mx_ctx* x, orm_op* op):
	string_builder* q = string_new()
	string_append(q, c"SELECT DISTINCT il.name FROM pragma_index_list(")
	orm_mx_literal_to(q, op.table)
	string_append(q, c") AS il, pragma_index_info(il.name) AS ii WHERE ii.name = ")
	orm_mx_literal_to(q, op.column)
	string_append(q, c" AND il.origin = 'c'")
	char* qs = orm_mx_take(q)
	list[char*] indexes = orm_mx_column_list(x, qs)
	free(qs)
	int ok = 1
	for char* ix in indexes:
		if (ok): ok = orm_mx_run(x, orm_mx_cat(c"DROP INDEX IF EXISTS ", orm_mx_ident(ix), 0, 0))
	orm_mx_free_strings(indexes)
	if (ok): ok = orm_hist_before_drop_column(x, op)
	if (ok): ok = orm_mx_run(x, orm_mx_cat(c"ALTER TABLE ", orm_mx_ident(op.table), c" DROP COLUMN ", orm_mx_ident(op.column)))
	if (ok): ok = orm_hist_after_drop_column(x, op)
	return ok


int orm_sqlite_alter_null(orm_mx_ctx* x, orm_op* op):
	json_value* f = json_parse(op.field_json)
	char* col = orm_sqlite_op_column(op, f)
	if (col == 0):
		json_free(f)
		return orm_mx_fail(x, c"ALTER_NULL without a column on ", op.table, 0)
	int want_null = orm_mx_jbool(f, c"null")
	int cur = orm_sqlite_notnull(x, op.table, col, cast(int*, 0))
	int ok = 1
	if (cur < 0):
		if (x.dry): orm_mx_comment(x, c"ALTER_NULL: column not in the live schema yet; rebuild decided at apply time")
		else: ok = orm_mx_fail(x, c"ALTER_NULL: no column ", col, c" in that table")
	else if (want_null && cur == 0): orm_mx_comment(x, c"ALTER_NULL: column already nullable")
	else if (want_null == 0 && cur == 1): orm_mx_comment(x, c"ALTER_NULL: column already NOT NULL")
	else:
		int mode = ORM_SQLITE_SET_NOT_NULL
		if (want_null): mode = ORM_SQLITE_DROP_NOT_NULL
		ok = orm_sqlite_rebuild(x, op.table, mode, col, 0) != 0
	json_free(f)
	return ok


int orm_sqlite_add_index(orm_mx_ctx* x, orm_op* op):
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
	int ok = orm_mx_index_sql(x, name, op.table, cols, orm_mx_jbool(f, c"unique"), orm_mx_jstr(f, c"condition"), 0)
	if (made != 0): free(made)
	json_free(own)
	json_free(f)
	return ok


int orm_sqlite_add_constraint(orm_mx_ctx* x, orm_op* op):
	if (op.name == 0 || op.sql == 0): return orm_mx_fail(x, c"ADD_CONSTRAINT needs name and sql on ", op.table, 0)
	if (orm_mx_starts_ci(op.sql, c"unique using index")):
		orm_mx_comment(x, c"UNIQUE USING INDEX: the unique index already enforces it on SQLite")
		return 1
	if (orm_mx_starts_ci(op.sql, c"unique")):
		int i = 0
		while (op.sql[i] != 0 && op.sql[i] != '('): i = i + 1
		string_builder* b = string_new()
		string_append(b, c"CREATE UNIQUE INDEX IF NOT EXISTS ")
		orm_mx_ident_to(b, op.name)
		string_append(b, c" ON ")
		orm_mx_ident_to(b, op.table)
		string_append(b, c" ")
		string_append(b, cast(char*, &op.sql[i]))
		return orm_mx_run_b(x, b)
	string_builder* item = string_new()
	string_append(item, c"CONSTRAINT ")
	orm_mx_ident_to(item, op.name)
	string_append(item, c" ")
	string_append(item, op.sql)
	char* text = orm_mx_take(item)
	int ok = orm_sqlite_rebuild(x, op.table, ORM_SQLITE_ADD_ITEM, 0, text) != 0
	free(text)
	return ok


int orm_sqlite_drop_constraint(orm_mx_ctx* x, orm_op* op):
	int r = orm_sqlite_rebuild(x, op.table, ORM_SQLITE_DROP_CONSTRAINT, 0, op.name)
	if (r == 0): return 0
	if (r == 2): return orm_mx_run(x, orm_mx_cat(c"DROP INDEX IF EXISTS ", orm_mx_ident(op.name), 0, 0))
	return 1


# Dual-write between two columns of one table. SQLite checks NOT NULL
# before AFTER triggers run, so a NOT NULL old column without a default is
# relaxed first: new code that writes only the new column must still be
# able to insert. WHEN guards stop the triggers re-firing each other.
int orm_sqlite_sync_columns(orm_mx_ctx* x, orm_op* op):
	char* t = op.table
	char* n = op.column
	char* o = op.source_column
	int has_default = 0
	int nn = orm_sqlite_notnull(x, t, o, &has_default)
	if (nn == 1 && has_default == 0):
		if (orm_sqlite_rebuild(x, t, ORM_SQLITE_DROP_NOT_NULL, o, 0) == 0): return 0
	char* base = orm_mx_sync_column_name(op)
	char* qt = orm_mx_ident(t)
	char* qn = orm_mx_ident(n)
	char* qo = orm_mx_ident(o)
	string_builder* b = string_new()
	string_append(b, c"CREATE TRIGGER ")
	char* ins = orm_mx_cat(base, c"_ins", 0, 0)
	orm_mx_ident_to(b, ins)
	string_append(b, c" AFTER INSERT ON ")
	string_append(b, qt)
	string_append(b, c" FOR EACH ROW BEGIN UPDATE ")
	string_append(b, qt)
	string_append(b, c" SET ")
	string_append(b, qn)
	string_append(b, c" = NEW.")
	string_append(b, qo)
	string_append(b, c" WHERE rowid = NEW.rowid AND NEW.")
	string_append(b, qn)
	string_append(b, c" IS NULL AND NEW.")
	string_append(b, qo)
	string_append(b, c" IS NOT NULL; UPDATE ")
	string_append(b, qt)
	string_append(b, c" SET ")
	string_append(b, qo)
	string_append(b, c" = NEW.")
	string_append(b, qn)
	string_append(b, c" WHERE rowid = NEW.rowid AND NEW.")
	string_append(b, qo)
	string_append(b, c" IS NULL AND NEW.")
	string_append(b, qn)
	string_append(b, c" IS NOT NULL; END")
	int ok = orm_mx_run_b(x, b)
	free(ins)
	for side in range(2):
		char* from = qo
		char* to = qn
		char* suffix = c"_upd_src"
		if (side == 1):
			from = qn
			to = qo
			suffix = c"_upd_dst"
		char* name = orm_mx_cat(base, suffix, 0, 0)
		string_builder* u = string_new()
		string_append(u, c"CREATE TRIGGER ")
		orm_mx_ident_to(u, name)
		string_append(u, c" AFTER UPDATE OF ")
		string_append(u, from)
		string_append(u, c" ON ")
		string_append(u, qt)
		string_append(u, c" FOR EACH ROW WHEN NEW.")
		string_append(u, from)
		string_append(u, c" IS NOT OLD.")
		string_append(u, from)
		string_append(u, c" AND NEW.")
		string_append(u, to)
		string_append(u, c" IS OLD.")
		string_append(u, to)
		string_append(u, c" BEGIN UPDATE ")
		string_append(u, qt)
		string_append(u, c" SET ")
		string_append(u, to)
		string_append(u, c" = NEW.")
		string_append(u, from)
		string_append(u, c" WHERE rowid = NEW.rowid; END")
		if (ok): ok = orm_mx_run_b(x, u)
		else: string_free(u)
		free(name)
	if (ok): ok = orm_hist_after_sync_columns(x, op)
	free(base)
	free(qt)
	free(qn)
	free(qo)
	return ok


# One direction of a table <-> table dual write. NOT EXISTS / IS NOT
# guards make the mirrored write a no-op when it comes back.
int orm_sqlite_sync_direction(orm_mx_ctx* x, char* from, char* to, list[char*] cols, char* pk):
	char* base = orm_mx_sync_table_name(from, to)
	char* qf = orm_mx_ident(from)
	char* qt = orm_mx_ident(to)
	char* qpk = orm_mx_ident(pk)
	string_builder* b = string_new()
	string_append(b, c"CREATE TRIGGER ")
	char* n1 = orm_mx_cat(base, c"_ins", 0, 0)
	orm_mx_ident_to(b, n1)
	free(n1)
	string_append(b, c" AFTER INSERT ON ")
	string_append(b, qf)
	string_append(b, c" FOR EACH ROW BEGIN INSERT INTO ")
	string_append(b, qt)
	string_append(b, c" (")
	orm_mx_list_to(b, cols, 0)
	string_append(b, c") SELECT ")
	orm_mx_list_to(b, cols, c"NEW.")
	string_append(b, c" WHERE NOT EXISTS (SELECT 1 FROM ")
	string_append(b, qt)
	string_append(b, c" WHERE ")
	string_append(b, qpk)
	string_append(b, c" = NEW.")
	string_append(b, qpk)
	string_append(b, c"); END")
	int ok = orm_mx_run_b(x, b)
	string_builder* u = string_new()
	string_append(u, c"CREATE TRIGGER ")
	char* n2 = orm_mx_cat(base, c"_upd", 0, 0)
	orm_mx_ident_to(u, n2)
	free(n2)
	string_append(u, c" AFTER UPDATE ON ")
	string_append(u, qf)
	string_append(u, c" FOR EACH ROW BEGIN UPDATE ")
	string_append(u, qt)
	string_append(u, c" SET ")
	for i in range(cols.length):
		if (i > 0): string_append(u, c", ")
		orm_mx_ident_to(u, cols[i])
		string_append(u, c" = NEW.")
		orm_mx_ident_to(u, cols[i])
	string_append(u, c" WHERE ")
	string_append(u, qpk)
	string_append(u, c" = OLD.")
	string_append(u, qpk)
	string_append(u, c" AND (")
	for i in range(cols.length):
		if (i > 0): string_append(u, c" OR ")
		orm_mx_ident_to(u, cols[i])
		string_append(u, c" IS NOT NEW.")
		orm_mx_ident_to(u, cols[i])
	string_append(u, c"); END")
	if (ok): ok = orm_mx_run_b(x, u)
	else: string_free(u)
	string_builder* d = string_new()
	string_append(d, c"CREATE TRIGGER ")
	char* n3 = orm_mx_cat(base, c"_del", 0, 0)
	orm_mx_ident_to(d, n3)
	free(n3)
	string_append(d, c" AFTER DELETE ON ")
	string_append(d, qf)
	string_append(d, c" FOR EACH ROW BEGIN DELETE FROM ")
	string_append(d, qt)
	string_append(d, c" WHERE ")
	string_append(d, qpk)
	string_append(d, c" = OLD.")
	string_append(d, qpk)
	string_append(d, c"; END")
	if (ok): ok = orm_mx_run_b(x, d)
	else: string_free(d)
	free(base)
	free(qf)
	free(qt)
	free(qpk)
	return ok


int orm_sqlite_sync_tables(orm_mx_ctx* x, orm_op* op):
	list[char*] a = orm_sqlite_columns(x, op.table)
	list[char*] b = orm_sqlite_columns(x, op.source_table)
	list[char*] cols = orm_mx_common_columns(a, b)
	char* pk = orm_sqlite_pk(x, op.source_table)
	int ok = 1
	if (cols.length == 0 && x.dry == 0): ok = orm_mx_fail(x, c"SYNC_TRIGGER: no common columns between ", op.table, c" and its source")
	if (ok): ok = orm_sqlite_sync_direction(x, op.source_table, op.table, cols, pk)
	if (ok): ok = orm_sqlite_sync_direction(x, op.table, op.source_table, cols, pk)
	cols.free()
	orm_mx_free_strings(a)
	orm_mx_free_strings(b)
	free(pk)
	return ok


int orm_sqlite_drop_trigger(orm_mx_ctx* x, char* base, char* suffix):
	char* name = orm_mx_cat(base, suffix, 0, 0)
	int ok = orm_mx_run(x, orm_mx_cat(c"DROP TRIGGER IF EXISTS ", orm_mx_ident(name), 0, 0))
	free(name)
	return ok


int orm_sqlite_drop_table_sync(orm_mx_ctx* x, char* a, char* b):
	int ok = 1
	for side in range(2):
		char* base = orm_mx_sync_table_name(a, b)
		if (side == 1): base = orm_mx_sync_table_name(b, a)
		if (ok): ok = orm_sqlite_drop_trigger(x, base, c"_ins")
		if (ok): ok = orm_sqlite_drop_trigger(x, base, c"_upd")
		if (ok): ok = orm_sqlite_drop_trigger(x, base, c"_del")
		free(base)
	return ok


int orm_sqlite_drop_sync(orm_mx_ctx* x, orm_op* op):
	if (op.source_table != 0): return orm_sqlite_drop_table_sync(x, op.table, op.source_table)
	char* base = orm_mx_sync_column_name(op)
	int ok = orm_sqlite_drop_trigger(x, base, c"_ins")
	if (ok): ok = orm_sqlite_drop_trigger(x, base, c"_upd_src")
	if (ok): ok = orm_sqlite_drop_trigger(x, base, c"_upd_dst")
	free(base)
	return ok


int orm_sqlite_copy_column(orm_mx_ctx* x, orm_op* op):
	char* pk = orm_sqlite_pk(x, op.table)
	string_builder* p = string_new()
	string_append(p, c"UPDATE ")
	orm_mx_ident_to(p, op.table)
	string_append(p, c" SET ")
	orm_mx_ident_to(p, op.column)
	string_append(p, c" = ")
	orm_mx_ident_to(p, op.source_column)
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


int orm_sqlite_copy_table(orm_mx_ctx* x, orm_op* op):
	list[char*] a = orm_sqlite_columns(x, op.table)
	list[char*] b = orm_sqlite_columns(x, op.source_table)
	list[char*] cols = orm_mx_common_columns(a, b)
	char* pk = orm_sqlite_pk(x, op.source_table)
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


int orm_sqlite_rename(orm_mx_ctx* x, char* from, char* to):
	string_builder* b = string_new()
	string_append(b, c"ALTER TABLE ")
	orm_mx_ident_to(b, from)
	string_append(b, c" RENAME TO ")
	orm_mx_ident_to(b, to)
	return orm_mx_run_b(x, b)


# Renames the indexes of `table` named `from...` to `to...`. SQLite has no
# ALTER INDEX .. RENAME, so each is dropped and recreated from its SQL.
int orm_sqlite_rename_indexes(orm_mx_ctx* x, char* table, char* from, char* to):
	char* q = orm_sqlite_table_query(c"SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL AND tbl_name = ", table, c" ORDER BY name")
	sql_result* r = orm_mx_query(x, q)
	free(q)
	if (r == 0): return 0
	int ok = 1
	for i in range(r.rows):
		if (ok == 0): break
		char* name = sql_value(r, i, 0)
		char* moved = orm_mx_reprefix(name, from, to)
		if (moved == 0): continue
		char* sql = sql_value(r, i, 1)
		int at = index_of(sql, name)
		if (at < 0):
			free(moved)
			continue
		char* head = str_copy_range(sql, 0, at)
		char* renamed = orm_mx_cat(head, moved, cast(char*, &sql[at + strlen(name)]), 0)
		free(head)
		ok = orm_mx_run(x, orm_mx_cat(c"DROP INDEX ", orm_mx_ident(name), 0, 0))
		if (ok): ok = orm_mx_exec(x, renamed)
		free(renamed)
		free(moved)
	sql_result_free(r)
	return ok


# After a swap: indexes created for the shadow table take the original
# names, the old table's indexes take the shadow's.
int orm_sqlite_swap_index_names(orm_mx_ctx* x, char* table, char* source):
	int ok = orm_sqlite_rename_indexes(x, table, source, orm_mx_swap_prefix())
	if (ok): ok = orm_sqlite_rename_indexes(x, source, table, source)
	if (ok): ok = orm_sqlite_rename_indexes(x, table, orm_mx_swap_prefix(), table)
	return ok


# table <-> source_table in the migration's transaction. legacy_alter_table
# is ON there, so other tables' FOREIGN KEYs keep naming the original
# table, which now holds the new shape.
int orm_sqlite_swap(orm_mx_ctx* x, orm_op* op):
	if (orm_sqlite_drop_table_sync(x, op.table, op.source_table) == 0): return 0
	char* tmp = orm_mx_cat(op.source_table, c"__w_swap", 0, 0)
	int ok = orm_sqlite_rename(x, op.source_table, tmp)
	if (ok): ok = orm_sqlite_rename(x, op.table, op.source_table)
	if (ok): ok = orm_sqlite_rename(x, tmp, op.table)
	if (ok): ok = orm_sqlite_keep_sequence(x, op.source_table, op.table)
	if (ok): ok = orm_sqlite_swap_index_names(x, op.table, op.source_table)
	if (ok): ok = orm_hist_after_swap(x, op)
	free(tmp)
	return ok


# A plain rename lets SQLite rewrite FOREIGN KEY references to follow it.
int orm_sqlite_rename_table(orm_mx_ctx* x, orm_op* op):
	if (orm_mx_exec(x, c"PRAGMA legacy_alter_table=OFF") == 0): return 0
	int ok = orm_sqlite_rename(x, op.source_table, op.table)
	if (orm_mx_exec(x, c"PRAGMA legacy_alter_table=ON") == 0): ok = 0
	if (ok): ok = orm_hist_after_rename(x, op)
	return ok


# Dispatch for the dialect-specific op kinds; -1 = not handled here.
int orm_sqlite_op(orm_mx_ctx* x, orm_op* op):
	int k = op.kind
	if (k == ORM_OP_DROP_TABLE): return orm_mx_run(x, orm_mx_cat(c"DROP TABLE ", orm_mx_ident(op.table), 0, 0))
	if (k == ORM_OP_ADD_COLUMN): return orm_sqlite_add_column(x, op)
	if (k == ORM_OP_DROP_COLUMN): return orm_sqlite_drop_column(x, op)
	if (k == ORM_OP_ALTER_NULL): return orm_sqlite_alter_null(x, op)
	if (k == ORM_OP_ADD_INDEX): return orm_sqlite_add_index(x, op)
	if (k == ORM_OP_DROP_INDEX): return orm_mx_run(x, orm_mx_cat(c"DROP INDEX IF EXISTS ", orm_mx_ident(op.name), 0, 0))
	if (k == ORM_OP_ADD_CONSTRAINT): return orm_sqlite_add_constraint(x, op)
	if (k == ORM_OP_VALIDATE_CONSTRAINT):
		orm_mx_comment(x, c"VALIDATE_CONSTRAINT: SQLite validated the rows when the constraint was added")
		return 1
	if (k == ORM_OP_DROP_CONSTRAINT): return orm_sqlite_drop_constraint(x, op)
	if (k == ORM_OP_COPY_COLUMN): return orm_sqlite_copy_column(x, op)
	if (k == ORM_OP_SYNC_TRIGGER):
		if (op.source_table != 0): return orm_sqlite_sync_tables(x, op)
		return orm_sqlite_sync_columns(x, op)
	if (k == ORM_OP_DROP_SYNC_TRIGGER): return orm_sqlite_drop_sync(x, op)
	if (k == ORM_OP_COPY_TABLE): return orm_sqlite_copy_table(x, op)
	if (k == ORM_OP_SWAP_TABLES): return orm_sqlite_swap(x, op)
	if (k == ORM_OP_RENAME_TABLE): return orm_sqlite_rename_table(x, op)
	return -1
