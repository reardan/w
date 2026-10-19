# w-orm migration DDL: pieces shared by the SQLite and PostgreSQL
# generators (issue #754, unit U2.4; docs/projects/orm/u2_4.md).
#
# An orm_mx_ctx carries the connection, the dialect, and whether SQL is
# executed or only collected (orm_migrate_sql). Introspection queries
# (sqlite_master, pg_catalog) always run, also in collect mode, so the
# printed SQL matches what apply would execute against the live database.
import libs.standard.orm.contract
import libs.standard.orm.migrate.lint
import structures.json
import lib.str
import structures.string


struct orm_mx_ctx:
	orm_db* db
	int dialect                       # ORM_DIALECT_SQLITE / ORM_DIALECT_POSTGRES
	int dry                           # 1: append SQL to out instead of executing it
	string_builder* out
	map[char*, char*] model_tables    # model name -> table, from every model_json seen
	map[char*, char*] model_pks       # model name -> pk column
	map[char*, int] known_tables      # every table some CREATE_TABLE model_json creates
	list[char*] deferred              # statements run at the end of the migration (m2m through tables)
	int in_transaction


# ---------------------------------------------------------------------------
# Dialect and connection helpers

orm_dialect* orm_migrate_dialect(int id):
	orm_dialect* d = new orm_dialect()
	d.id = id
	if (id == ORM_DIALECT_POSTGRES):
		d.name = c"postgresql"
		d.bind_style = sql_bind_dollar
		d.supports_returning = 1
		d.supports_for_update = 1
		d.supports_ilike = 1
		d.supports_nulls_order = 1
		d.supports_filter_clause = 1
		d.supports_concurrent_index = 1
		d.supports_transactional_ddl = 1
		d.supports_distinct_on = 1
		d.max_params = 65535
		return d
	d.name = c"sqlite"
	d.bind_style = sql_bind_question
	d.supports_returning = 1
	d.supports_nulls_order = 1
	d.supports_filter_clause = 1
	d.supports_transactional_ddl = 1
	d.max_params = 32766
	return d


int orm_mx_dialect_of(orm_db* db):
	if (db.dialect != 0 && db.dialect.id != 0): return db.dialect.id
	if (db.conn != 0 && db.conn.driver == SQL_POSTGRES): return ORM_DIALECT_POSTGRES
	return ORM_DIALECT_SQLITE


# Opens a SQLite database for migrations (PRAGMA foreign_keys=ON). Returns
# 0 with *error set (a borrowed message) when it cannot open.
orm_db* orm_migrate_open_sqlite(char* path, char** error):
	sql_connection* c = sql_open_sqlite(path)
	if (sql_is_open(c) == 0):
		if (error != 0): error[0] = sql_error(c)
		return 0
	orm_db* db = orm_db_new(c, orm_migrate_dialect(ORM_DIALECT_SQLITE))
	orm_db_exec_sql(db, c"PRAGMA foreign_keys=ON")
	return db


orm_db* orm_migrate_open_postgres(char* conninfo, char** error):
	sql_connection* c = sql_open_postgres(conninfo)
	if (sql_is_open(c) == 0):
		if (error != 0): error[0] = sql_error(c)
		return 0
	return orm_db_new(c, orm_migrate_dialect(ORM_DIALECT_POSTGRES))


orm_mx_ctx* orm_mx_new(orm_db* db, int dry):
	orm_mx_ctx* x = new orm_mx_ctx()
	x.db = db
	x.dialect = orm_mx_dialect_of(db)
	x.dry = dry
	x.out = string_new()
	x.model_tables = new map[char*, char*]
	x.model_pks = new map[char*, char*]
	x.known_tables = new map[char*, int]
	x.deferred = new list[char*]
	return x


int orm_mx_pg(orm_mx_ctx* x):
	return x.dialect == ORM_DIALECT_POSTGRES


# ---------------------------------------------------------------------------
# Strings

char* orm_mx_take(string_builder* b):
	char* s = b.data
	free(cast(void*, b))
	return s


char* orm_mx_cat(char* a, char* b, char* c2, char* d):
	string_builder* s = string_new()
	if (a != 0): string_append(s, a)
	if (b != 0): string_append(s, b)
	if (c2 != 0): string_append(s, c2)
	if (d != 0): string_append(s, d)
	return orm_mx_take(s)


void orm_mx_ident_to(string_builder* b, char* name):
	string_append_char(b, '"')
	int i = 0
	while (name[i] != 0):
		if (name[i] == '"'): string_append_char(b, '"')
		string_append_char(b, name[i])
		i = i + 1
	string_append_char(b, '"')


char* orm_mx_ident(char* name):
	string_builder* b = string_new()
	orm_mx_ident_to(b, name)
	return orm_mx_take(b)


void orm_mx_literal_to(string_builder* b, char* text):
	string_append_char(b, 39)
	int i = 0
	while (text[i] != 0):
		if (text[i] == 39): string_append_char(b, 39)
		string_append_char(b, text[i])
		i = i + 1
	string_append_char(b, 39)


char* orm_mx_literal(char* text):
	string_builder* b = string_new()
	orm_mx_literal_to(b, text)
	return orm_mx_take(b)


# Integer text is inlined as is, anything else as a quoted literal (keyset
# bounds read back from the table itself).
void orm_mx_value_to(string_builder* b, char* v):
	int i = 0
	if (v[0] == '-'): i = 1
	int digits = v[i] != 0
	while (v[i] != 0):
		if (v[i] < '0' || v[i] > '9'): digits = 0
		i = i + 1
	if (digits): string_append(b, v)
	else: orm_mx_literal_to(b, v)


int orm_mx_lower(int ch):
	if (ch >= 'A' && ch <= 'Z'): return ch + 32
	return ch


int orm_mx_streq_ci(char* a, char* b):
	int i = 0
	while (a[i] != 0 && b[i] != 0):
		if (orm_mx_lower(a[i]) != orm_mx_lower(b[i])): return 0
		i = i + 1
	return a[i] == b[i]


# Case-insensitive prefix test after leading blanks.
int orm_mx_starts_ci(char* s, char* prefix):
	int i = 0
	while (s[i] == ' ' || s[i] == 9 || s[i] == 10 || s[i] == 13): i = i + 1
	int j = 0
	while (prefix[j] != 0):
		if (orm_mx_lower(s[i + j]) != orm_mx_lower(prefix[j])): return 0
		j = j + 1
	return 1


# Generated object names (triggers, functions) stay within PostgreSQL's
# 63-byte identifier limit: longer names keep a prefix plus a hash.
char* orm_mx_name(char* a, char* b, char* c2, char* d):
	char* s = orm_mx_cat(a, b, c2, d)
	int n = strlen(s)
	if (n <= 63): return s
	int h = 5381
	for i in range(n): h = ((h * 33) + (s[i] & 255)) & 268435455
	string_builder* out = string_new()
	string_append_bytes(out, s, 54)
	string_append_char(out, '_')
	for k in range(7):
		int digit = (h >> ((6 - k) * 4)) & 15
		if (digit < 10): string_append_char(out, '0' + digit)
		else: string_append_char(out, 'a' + digit - 10)
	free(s)
	return orm_mx_take(out)


# ---------------------------------------------------------------------------
# Execution

int orm_mx_fail(orm_mx_ctx* x, char* a, char* b, char* c2):
	char* text = orm_mx_cat(a, b, c2, 0)
	orm_db_set_error(x.db, text)
	free(text)
	return 0


void orm_mx_comment(orm_mx_ctx* x, char* text):
	if (x.dry == 0): return
	string_append(x.out, c"-- ")
	string_append(x.out, text)
	string_append(x.out, c"\n")


int orm_mx_exec(orm_mx_ctx* x, char* sql):
	if (x.dry):
		string_append(x.out, sql)
		string_append(x.out, c";\n")
		return 1
	if (orm_db_exec_sql(x.db, sql)): return 1
	char* first = strclone(orm_db_error(x.db))
	orm_mx_fail(x, first, c" -- in: ", sql)
	free(first)
	return 0


# Exec and free the statement.
int orm_mx_run(orm_mx_ctx* x, char* sql):
	int ok = orm_mx_exec(x, sql)
	free(sql)
	return ok


int orm_mx_run_b(orm_mx_ctx* x, string_builder* b):
	return orm_mx_run(x, orm_mx_take(b))


# Introspection: always executed, also in collect mode.
sql_result* orm_mx_query(orm_mx_ctx* x, char* sql):
	x.db.query_count = x.db.query_count + 1
	sql_result* r = sql_query(x.db.conn, sql)
	if (r == 0): orm_mx_fail(x, sql_error(x.db.conn), c" -- in: ", sql)
	return r


# First cell of the first row (owned copy), or 0 when there is no row, the
# cell is NULL, or the query failed.
char* orm_mx_scalar(orm_mx_ctx* x, char* sql):
	sql_result* r = orm_mx_query(x, sql)
	if (r == 0): return 0
	char* out = 0
	if (r.rows > 0 && sql_value(r, 0, 0) != 0): out = strclone(sql_value(r, 0, 0))
	sql_result_free(r)
	return out


# Column 0 of every row (owned copies).
list[char*] orm_mx_column_list(orm_mx_ctx* x, char* sql):
	list[char*] out = new list[char*]
	sql_result* r = orm_mx_query(x, sql)
	if (r == 0): return out
	for i in range(r.rows):
		if (sql_value(r, i, 0) != 0): out.push(strclone(sql_value(r, i, 0)))
	sql_result_free(r)
	return out


void orm_mx_free_strings(list[char*] l):
	for char* s in l: free(s)
	l.free()


int orm_mx_list_has(list[char*] l, char* s):
	for char* t in l:
		if (strcmp(t, s) == 0): return 1
	return 0


# Transactions. SQLite: foreign keys are switched off for the transaction
# (the documented 12-step table rebuild needs it; PRAGMA foreign_keys is a
# no-op inside a transaction) and PRAGMA foreign_key_check must come back
# empty before COMMIT. legacy_alter_table=ON keeps table renames from
# rewriting references in other tables, which a rebuild or swap relies on.
int orm_mx_begin(orm_mx_ctx* x):
	if (x.dry):
		string_append(x.out, c"BEGIN;\n")
		x.in_transaction = 1
		return 1
	if (orm_mx_pg(x) == 0):
		if (orm_mx_exec(x, c"PRAGMA foreign_keys=OFF") == 0): return 0
		if (orm_mx_exec(x, c"PRAGMA legacy_alter_table=ON") == 0): return 0
	if (sql_begin(x.db.conn) == 0): return orm_mx_fail(x, c"BEGIN failed: ", sql_error(x.db.conn), 0)
	x.in_transaction = 1
	x.db.atomic_depth = 1
	return 1


void orm_mx_sqlite_restore(orm_mx_ctx* x):
	orm_db_exec_sql(x.db, c"PRAGMA legacy_alter_table=OFF")
	orm_db_exec_sql(x.db, c"PRAGMA foreign_keys=ON")


void orm_mx_rollback(orm_mx_ctx* x):
	if (x.dry):
		x.in_transaction = 0
		return
	if (x.in_transaction):
		char* keep = strclone(orm_db_error(x.db))
		sql_rollback(x.db.conn)
		orm_db_set_error(x.db, keep)
		free(keep)
	x.in_transaction = 0
	x.db.atomic_depth = 0
	if (orm_mx_pg(x) == 0): orm_mx_sqlite_restore(x)


int orm_mx_commit(orm_mx_ctx* x):
	if (x.dry):
		string_append(x.out, c"COMMIT;\n")
		x.in_transaction = 0
		return 1
	if (orm_mx_pg(x) == 0):
		sql_result* r = orm_mx_query(x, c"PRAGMA foreign_key_check")
		if (r == 0):
			orm_mx_rollback(x)
			return 0
		int bad = -1
		for i in range(r.rows):
			if (bad < 0):
				char* pq = orm_mx_cat(c"SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ", orm_mx_literal(sql_value(r, i, 2)), 0, 0)
				char* n = orm_mx_scalar(x, pq)
				free(pq)
				# A row pointing into a dropped table is what PostgreSQL's
				# DROP TABLE .. CASCADE would leave too (it drops that FK).
				if (n != 0 && strcmp(n, c"0") != 0): bad = i
				if (n != 0): free(n)
		if (bad >= 0):
			string_builder* b = string_new()
			string_append(b, c"foreign key violation after migration: table ")
			string_append(b, sql_value(r, bad, 0))
			string_append(b, c" rowid ")
			if (sql_value(r, bad, 1) != 0): string_append(b, sql_value(r, bad, 1))
			string_append(b, c" references missing row in ")
			string_append(b, sql_value(r, bad, 2))
			sql_result_free(r)
			char* text = orm_mx_take(b)
			orm_db_set_error(x.db, text)
			free(text)
			orm_mx_rollback(x)
			return 0
		sql_result_free(r)
	if (sql_commit(x.db.conn) == 0):
		orm_mx_fail(x, c"COMMIT failed: ", sql_error(x.db.conn), 0)
		x.in_transaction = 0
		x.db.atomic_depth = 0
		if (orm_mx_pg(x) == 0): orm_mx_sqlite_restore(x)
		return 0
	x.in_transaction = 0
	x.db.atomic_depth = 0
	if (orm_mx_pg(x) == 0): orm_mx_sqlite_restore(x)
	return 1


# ---------------------------------------------------------------------------
# JSON snapshot access

json_value* orm_mx_jget(json_value* o, char* key):
	if (o == 0 || o.type != json_type_object()): return 0
	return json_object_get(o, key)


char* orm_mx_jstr(json_value* o, char* key):
	json_value* v = orm_mx_jget(o, key)
	if (v == 0 || v.type != json_type_string()): return 0
	return v.string_value


int orm_mx_jbool(json_value* o, char* key):
	json_value* v = orm_mx_jget(o, key)
	if (v == 0): return 0
	if (v.type == json_type_bool() || v.type == json_type_int()): return v.int_value != 0
	return 0


int orm_mx_jint(json_value* o, char* key):
	json_value* v = orm_mx_jget(o, key)
	if (v == 0 || (v.type != json_type_int() && v.type != json_type_bool())): return 0
	return v.int_value


int orm_mx_jarray_len(json_value* a):
	if (a == 0 || a.type != json_type_array()): return 0
	return json_array_length(a)


int orm_mx_kind_from_name(char* n):
	if (n == 0): return 0
	if (strcmp(n, c"int") == 0): return ORM_INT
	if (strcmp(n, c"bigint") == 0): return ORM_BIGINT
	if (strcmp(n, c"bool") == 0): return ORM_BOOL
	if (strcmp(n, c"text") == 0 || strcmp(n, c"string") == 0): return ORM_TEXT
	if (strcmp(n, c"decimal") == 0): return ORM_DECIMAL
	if (strcmp(n, c"datetime") == 0): return ORM_DATETIME
	if (strcmp(n, c"date") == 0): return ORM_DATE
	if (strcmp(n, c"uuid") == 0): return ORM_UUID
	if (strcmp(n, c"json") == 0): return ORM_JSON
	if (strcmp(n, c"fk") == 0): return ORM_FK
	if (strcmp(n, c"enum") == 0): return ORM_ENUM
	if (strcmp(n, c"m2m") == 0): return ORM_M2M
	if (strcmp(n, c"reverse_fk") == 0): return ORM_REVERSE_FK
	if (strcmp(n, c"float") == 0): return ORM_FLOAT
	return 0


# "kind" is the ORM_* number (contract C7); a kind name is accepted too,
# and "kind_name" as a fallback. Unknown kinds read as ORM_TEXT.
int orm_mx_kind(json_value* f):
	json_value* v = orm_mx_jget(f, c"kind")
	int k = 0
	if (v != 0 && v.type == json_type_int()): k = v.int_value
	else if (v != 0 && v.type == json_type_string()): k = orm_mx_kind_from_name(v.string_value)
	if (k == 0): k = orm_mx_kind_from_name(orm_mx_jstr(f, c"kind_name"))
	if (k == 0): k = ORM_TEXT
	return k


char* orm_mx_on_delete_sql(json_value* f):
	json_value* v = orm_mx_jget(f, c"on_delete")
	int k = ORM_PROTECT
	if (v != 0 && v.type == json_type_int()): k = v.int_value
	else if (v != 0 && v.type == json_type_string()):
		char* n = v.string_value
		if (strcmp(n, c"cascade") == 0): k = ORM_CASCADE
		else if (strcmp(n, c"restrict") == 0): k = ORM_RESTRICT
		else if (strcmp(n, c"set_null") == 0): k = ORM_SET_NULL
		else if (strcmp(n, c"set_default") == 0): k = ORM_SET_DEFAULT
		else if (strcmp(n, c"do_nothing") == 0): k = ORM_DO_NOTHING
	if (k == ORM_CASCADE): return c"CASCADE"
	if (k == ORM_SET_NULL): return c"SET NULL"
	if (k == ORM_SET_DEFAULT): return c"SET DEFAULT"
	if (k == ORM_DO_NOTHING): return c"NO ACTION"
	return c"RESTRICT"


# Field column: the op's column wins, then "column", then "name".
char* orm_mx_field_column(json_value* f, char* op_column):
	if (op_column != 0): return op_column
	char* c = orm_mx_jstr(f, c"column")
	if (c != 0): return c
	return orm_mx_jstr(f, c"name")


# Records model name -> table / pk column from a model snapshot. The
# applier pre-scans every migration with overwrite = 0 (so forward
# references resolve), then overwrites in apply order as CREATE_TABLE ops
# are replayed or run, so a model whose table was renamed resolves to its
# newest table.
void orm_mx_note_model(orm_mx_ctx* x, char* model_json, int overwrite):
	if (model_json == 0): return
	json_value* m = json_parse(model_json)
	if (m == 0): return
	char* name = orm_mx_jstr(m, c"name")
	char* table = orm_mx_jstr(m, c"table")
	if (table != 0 && (table in x.known_tables) == 0): x.known_tables[strclone(table)] = 1
	if (name != 0 && table != 0 && (overwrite || (name in x.model_tables) == 0)):
		char* pk = c"id"
		json_value* fields = orm_mx_jget(m, c"fields")
		for i in range(orm_mx_jarray_len(fields)):
			json_value* f = json_array_get(fields, i)
			if (orm_mx_jbool(f, c"pk") && orm_mx_jstr(f, c"column") != 0): pk = orm_mx_jstr(f, c"column")
		if (name in x.model_tables):
			x.model_tables[name] = strclone(table)
			x.model_pks[name] = strclone(pk)
		else:
			char* key = strclone(name)
			x.model_tables[key] = strclone(table)
			x.model_pks[key] = strclone(pk)
	json_free(m)


# Target table of a relation field: "rel_table" in the field, a model_json
# seen in the migration list, or the runtime registry.
char* orm_mx_rel_table(orm_mx_ctx* x, json_value* f):
	char* t = orm_mx_jstr(f, c"rel_table")
	if (t != 0): return t
	char* model = orm_mx_jstr(f, c"rel_model")
	if (model == 0): return 0
	if (model in x.model_tables): return x.model_tables[model]
	orm_model_desc* d = orm_model_lookup(model)
	if (d != 0): return d.table
	return 0


char* orm_mx_rel_pk(orm_mx_ctx* x, json_value* f):
	char* model = orm_mx_jstr(f, c"rel_model")
	if (model != 0 && (model in x.model_pks)): return x.model_pks[model]
	orm_model_desc* d = orm_model_lookup(model)
	if (d != 0 && orm_model_pk(d) != 0 && orm_model_pk(d).column != 0): return orm_model_pk(d).column
	return c"id"


# ---------------------------------------------------------------------------
# Column types and definitions

char* orm_mx_text_type(json_value* f):
	int n = orm_mx_jint(f, c"max_length")
	if (n <= 0): return strclone(c"TEXT")
	string_builder* b = string_new()
	string_append(b, c"VARCHAR(")
	string_append_int(b, n)
	string_append(b, c")")
	return orm_mx_take(b)


# Owned SQL type for a field snapshot.
char* orm_mx_type(orm_mx_ctx* x, json_value* f):
	int k = orm_mx_kind(f)
	int pg = orm_mx_pg(x)
	if (k == ORM_INT): return strclone(c"INTEGER")
	if (k == ORM_BIGINT || k == ORM_FK):
		if (pg): return strclone(c"BIGINT")
		return strclone(c"INTEGER")
	if (k == ORM_BOOL):
		if (pg): return strclone(c"BOOLEAN")
		return strclone(c"INTEGER")
	if (k == ORM_DECIMAL):
		int d = orm_mx_jint(f, c"digits")
		if (d <= 0): return strclone(c"NUMERIC")
		string_builder* b = string_new()
		string_append(b, c"NUMERIC(")
		string_append_int(b, d)
		string_append(b, c", ")
		string_append_int(b, orm_mx_jint(f, c"places"))
		string_append(b, c")")
		return orm_mx_take(b)
	if (k == ORM_DATETIME):
		if (pg): return strclone(c"TIMESTAMP")
		return strclone(c"TEXT")
	if (k == ORM_DATE):
		if (pg): return strclone(c"DATE")
		return strclone(c"TEXT")
	if (k == ORM_UUID):
		if (pg): return strclone(c"UUID")
		return strclone(c"TEXT")
	if (k == ORM_JSON):
		if (pg): return strclone(c"JSONB")
		return strclone(c"TEXT")
	if (k == ORM_FLOAT):
		if (pg): return strclone(c"DOUBLE PRECISION")
		return strclone(c"REAL")
	return orm_mx_text_type(f)


int orm_mx_kind_is_int(int k):
	return k == ORM_INT || k == ORM_BIGINT


# Column definition for CREATE TABLE / ADD COLUMN. `adding` = ADD COLUMN:
# SQLite then leaves UNIQUE out (the caller creates a unique index).
# Returns 0 with the db error set when a relation target is unknown.
char* orm_mx_column_def(orm_mx_ctx* x, json_value* f, char* op_column, int adding):
	char* col = orm_mx_field_column(f, op_column)
	if (col == 0):
		orm_db_set_error(x.db, c"field snapshot without a column")
		return 0
	int k = orm_mx_kind(f)
	int pg = orm_mx_pg(x)
	string_builder* b = string_new()
	orm_mx_ident_to(b, col)
	string_append(b, c" ")
	if (orm_mx_jbool(f, c"pk")):
		if (orm_mx_jbool(f, c"auto") && orm_mx_kind_is_int(k)):
			if (pg): string_append(b, c"BIGSERIAL PRIMARY KEY")
			else: string_append(b, c"INTEGER PRIMARY KEY")
			return orm_mx_take(b)
		char* t = orm_mx_type(x, f)
		string_append(b, t)
		free(t)
		string_append(b, c" PRIMARY KEY")
		return orm_mx_take(b)
	char* ty = orm_mx_type(x, f)
	string_append(b, ty)
	free(ty)
	if (orm_mx_jbool(f, c"null") == 0): string_append(b, c" NOT NULL")
	if (orm_mx_jbool(f, c"unique") && (pg || adding == 0)): string_append(b, c" UNIQUE")
	char* def = orm_mx_jstr(f, c"default")
	if (def != 0):
		string_append(b, c" DEFAULT ")
		string_append(b, def)
	if (k == ORM_BOOL && pg == 0):
		string_append(b, c" CHECK (")
		orm_mx_ident_to(b, col)
		string_append(b, c" IN (0, 1))")
	json_value* values = orm_mx_jget(f, c"enum_values")
	if (k == ORM_ENUM && orm_mx_jarray_len(values) > 0):
		string_append(b, c" CHECK (")
		orm_mx_ident_to(b, col)
		string_append(b, c" IN (")
		for i in range(orm_mx_jarray_len(values)):
			json_value* v = json_array_get(values, i)
			if (i > 0): string_append(b, c", ")
			if (v.type == json_type_string()): orm_mx_literal_to(b, v.string_value)
		string_append(b, c"))")
	if (k == ORM_FK):
		char* target = orm_mx_rel_table(x, f)
		if (target == 0):
			string_free(b)
			char* model = orm_mx_jstr(f, c"rel_model")
			if (model == 0): model = c"(none)"
			orm_mx_fail(x, c"unknown FK target model ", model, c" (no model_json or registered model names it)")
			return 0
		string_append(b, c" REFERENCES ")
		orm_mx_ident_to(b, target)
		string_append(b, c" (")
		orm_mx_ident_to(b, orm_mx_rel_pk(x, f))
		string_append(b, c") ON DELETE ")
		string_append(b, orm_mx_on_delete_sql(f))
	return orm_mx_take(b)


# Comma-separated quoted column list from a JSON array of names.
void orm_mx_columns_to(string_builder* b, json_value* cols):
	for i in range(orm_mx_jarray_len(cols)):
		json_value* v = json_array_get(cols, i)
		if (i > 0): string_append(b, c", ")
		if (v.type == json_type_string()): orm_mx_ident_to(b, v.string_value)


void orm_mx_list_to(string_builder* b, list[char*] cols, char* prefix):
	for i in range(cols.length):
		if (i > 0): string_append(b, c", ")
		if (prefix != 0): string_append(b, prefix)
		orm_mx_ident_to(b, cols[i])


# An object name derived from the model table, moved to `table` when a
# duplicate (shadow) table is created: library_author_created_idx ->
# library_author__new_created_idx.
char* orm_mx_rename_object(char* name, char* model_table, char* table):
	if (model_table == 0 || strcmp(model_table, table) == 0): return strclone(name)
	int n = strlen(model_table)
	if (starts_with_at(name, model_table, 0)): return orm_mx_cat(table, cast(char*, &name[n]), 0, 0)
	return orm_mx_cat(table, c"_", name, 0)


int orm_mx_index_sql(orm_mx_ctx* x, char* name, char* table, json_value* cols, int unique, char* condition, int concurrently):
	string_builder* b = string_new()
	string_append(b, c"CREATE ")
	if (unique): string_append(b, c"UNIQUE ")
	string_append(b, c"INDEX ")
	if (concurrently): string_append(b, c"CONCURRENTLY ")
	string_append(b, c"IF NOT EXISTS ")
	orm_mx_ident_to(b, name)
	string_append(b, c" ON ")
	orm_mx_ident_to(b, table)
	string_append(b, c" (")
	orm_mx_columns_to(b, cols)
	string_append(b, c")")
	if (condition != 0):
		string_append(b, c" WHERE ")
		string_append(b, condition)
	return orm_mx_run_b(x, b)


int orm_mx_json_has_string(json_value* a, char* s):
	for i in range(orm_mx_jarray_len(a)):
		json_value* v = json_array_get(a, i)
		if (v.type == json_type_string() && strcmp(v.string_value, s) == 0): return 1
	return 0


# Single-column index already declared in "indexes"?
int orm_mx_indexed_by(json_value* indexes, char* column):
	for i in range(orm_mx_jarray_len(indexes)):
		json_value* cols = orm_mx_jget(json_array_get(indexes, i), c"columns")
		if (orm_mx_jarray_len(cols) >= 1):
			json_value* first = json_array_get(cols, 0)
			if (first.type == json_type_string() && strcmp(first.string_value, column) == 0): return 1
	return 0


# M2M through table, queued in x.deferred so both endpoints exist first.
int orm_mx_through_table(orm_mx_ctx* x, char* table, char* pk, json_value* f):
	char* through = orm_mx_jstr(f, c"through_table")
	char* from_col = orm_mx_jstr(f, c"through_from")
	char* to_col = orm_mx_jstr(f, c"through_to")
	if (through == 0 || from_col == 0 || to_col == 0): return orm_mx_fail(x, c"m2m field without through table: ", orm_mx_jstr(f, c"name"), 0)
	char* target = orm_mx_rel_table(x, f)
	if (target == 0): return orm_mx_fail(x, c"unknown m2m target model ", orm_mx_jstr(f, c"rel_model"), 0)
	char* fk_type = c"INTEGER"
	char* id_def = c"INTEGER PRIMARY KEY"
	if (orm_mx_pg(x)):
		fk_type = c"BIGINT"
		id_def = c"BIGSERIAL PRIMARY KEY"
	string_builder* b = string_new()
	string_append(b, c"CREATE TABLE ")
	orm_mx_ident_to(b, through)
	string_append(b, c" (\"id\" ")
	string_append(b, id_def)
	string_append(b, c", ")
	orm_mx_ident_to(b, from_col)
	string_append(b, c" ")
	string_append(b, fk_type)
	string_append(b, c" NOT NULL REFERENCES ")
	orm_mx_ident_to(b, table)
	string_append(b, c" (")
	orm_mx_ident_to(b, pk)
	string_append(b, c") ON DELETE CASCADE, ")
	orm_mx_ident_to(b, to_col)
	string_append(b, c" ")
	string_append(b, fk_type)
	string_append(b, c" NOT NULL REFERENCES ")
	orm_mx_ident_to(b, target)
	string_append(b, c" (")
	orm_mx_ident_to(b, orm_mx_rel_pk(x, f))
	string_append(b, c") ON DELETE CASCADE, CONSTRAINT ")
	char* uniq = orm_mx_name(through, c"_", from_col, c"_uniq")
	orm_mx_ident_to(b, uniq)
	free(uniq)
	string_append(b, c" UNIQUE (")
	orm_mx_ident_to(b, from_col)
	string_append(b, c", ")
	orm_mx_ident_to(b, to_col)
	string_append(b, c"))")
	x.deferred.push(orm_mx_take(b))
	string_builder* ix = string_new()
	string_append(ix, c"CREATE INDEX IF NOT EXISTS ")
	char* ixname = orm_mx_name(through, c"_", to_col, c"_idx")
	orm_mx_ident_to(ix, ixname)
	free(ixname)
	string_append(ix, c" ON ")
	orm_mx_ident_to(ix, through)
	string_append(ix, c" (")
	orm_mx_ident_to(ix, to_col)
	string_append(ix, c")")
	x.deferred.push(orm_mx_take(ix))
	return 1


# CREATE_TABLE from a model snapshot: columns with types, PK, FKs, NOT NULL,
# UNIQUE, DEFAULT, enum/bool CHECKs, model CHECKs, unique_together, indexes
# (declared and `indexed` fields) and M2M through tables. op.table may name
# a shadow table (table duplication): index names follow it and through
# tables are skipped (they keep pointing at the original table).
int orm_mx_create_table(orm_mx_ctx* x, orm_op* op):
	if (op.model_json == 0): return orm_mx_fail(x, c"CREATE_TABLE without model_json", 0, 0)
	json_value* m = json_parse(op.model_json)
	if (m == 0): return orm_mx_fail(x, c"CREATE_TABLE: model_json is not valid JSON", 0, 0)
	char* model_table = orm_mx_jstr(m, c"table")
	char* table = op.table
	if (table == 0): table = model_table
	if (table == 0):
		json_free(m)
		return orm_mx_fail(x, c"CREATE_TABLE without a table", 0, 0)
	json_value* fields = orm_mx_jget(m, c"fields")
	char* pk = c"id"
	string_builder* b = string_new()
	string_append(b, c"CREATE TABLE ")
	orm_mx_ident_to(b, table)
	string_append(b, c" (")
	int items = 0
	for i in range(orm_mx_jarray_len(fields)):
		json_value* f = json_array_get(fields, i)
		int k = orm_mx_kind(f)
		if (k == ORM_M2M || k == ORM_REVERSE_FK || orm_mx_jstr(f, c"column") == 0): continue
		if (orm_mx_jbool(f, c"pk")): pk = orm_mx_jstr(f, c"column")
		char* def = orm_mx_column_def(x, f, 0, 0)
		if (def == 0):
			string_free(b)
			json_free(m)
			return 0
		if (items > 0): string_append(b, c", ")
		string_append(b, def)
		free(def)
		items = items + 1
	json_value* checks = orm_mx_jget(m, c"checks")
	for i in range(orm_mx_jarray_len(checks)):
		json_value* ch = json_array_get(checks, i)
		char* sql = orm_mx_jstr(ch, c"sql")
		if (sql == 0): continue
		string_append(b, c", ")
		if (orm_mx_jstr(ch, c"name") != 0):
			string_append(b, c"CONSTRAINT ")
			orm_mx_ident_to(b, orm_mx_jstr(ch, c"name"))
			string_append(b, c" ")
		string_append(b, c"CHECK (")
		string_append(b, sql)
		string_append(b, c")")
	json_value* uts = orm_mx_jget(m, c"unique_together")
	for i in range(orm_mx_jarray_len(uts)):
		json_value* ut = json_array_get(uts, i)
		json_value* cols = orm_mx_jget(ut, c"columns")
		if (cols == 0 && ut != 0 && ut.type == json_type_array()): cols = ut
		if (orm_mx_jarray_len(cols) == 0): continue
		string_builder* nb = string_new()
		string_append(nb, table)
		for j in range(orm_mx_jarray_len(cols)):
			json_value* cv = json_array_get(cols, j)
			string_append(nb, c"_")
			if (cv.type == json_type_string()): string_append(nb, cv.string_value)
		string_append(nb, c"_uniq")
		char* raw = orm_mx_take(nb)
		char* uname = orm_mx_name(raw, 0, 0, 0)
		free(raw)
		string_append(b, c", CONSTRAINT ")
		orm_mx_ident_to(b, uname)
		free(uname)
		string_append(b, c" UNIQUE (")
		orm_mx_columns_to(b, cols)
		string_append(b, c")")
	string_append(b, c")")
	if (orm_mx_run_b(x, b) == 0):
		json_free(m)
		return 0
	orm_mx_note_model(x, op.model_json, 1)
	json_value* indexes = orm_mx_jget(m, c"indexes")
	for i in range(orm_mx_jarray_len(indexes)):
		json_value* ix = json_array_get(indexes, i)
		char* iname = orm_mx_jstr(ix, c"name")
		if (iname == 0): continue
		char* moved = orm_mx_rename_object(iname, model_table, table)
		int ok = orm_mx_index_sql(x, moved, table, orm_mx_jget(ix, c"columns"), orm_mx_jbool(ix, c"unique"), orm_mx_jstr(ix, c"condition"), 0)
		free(moved)
		if (ok == 0):
			json_free(m)
			return 0
	for i in range(orm_mx_jarray_len(fields)):
		json_value* f = json_array_get(fields, i)
		char* col = orm_mx_jstr(f, c"column")
		if (col == 0 || orm_mx_jbool(f, c"indexed") == 0 || orm_mx_jbool(f, c"pk") || orm_mx_jbool(f, c"unique")): continue
		if (orm_mx_indexed_by(indexes, col)): continue
		char* nm = orm_mx_name(table, c"_", col, c"_idx")
		json_value* one = json_array()
		json_array_push(one, json_string(col))
		int ok2 = orm_mx_index_sql(x, nm, table, one, 0, 0, 0)
		json_free(one)
		free(nm)
		if (ok2 == 0):
			json_free(m)
			return 0
	int same = model_table == 0 || strcmp(model_table, table) == 0
	for i in range(orm_mx_jarray_len(fields)):
		json_value* f = json_array_get(fields, i)
		if (orm_mx_kind(f) != ORM_M2M): continue
		if (same == 0):
			orm_mx_comment(x, c"m2m through table skipped for a shadow table")
			continue
		# Through tables that have their own CREATE_TABLE (U2.2's state
		# models them as tables) are left to it.
		char* through = orm_mx_jstr(f, c"through_table")
		if (through != 0 && (through in x.known_tables)): continue
		if (orm_mx_through_table(x, table, pk, f) == 0):
			json_free(m)
			return 0
	json_free(m)
	return 1


int orm_mx_run_deferred(orm_mx_ctx* x):
	int ok = 1
	for char* s in x.deferred:
		if (ok && orm_mx_exec(x, s) == 0): ok = 0
		free(s)
	x.deferred.free()
	x.deferred = new list[char*]
	return ok


# ---------------------------------------------------------------------------
# RAW_SQL: split at top-level semicolons (quotes, comments, $tag$ bodies).

int orm_mx_dollar_tag_len(char* s, int i):
	# s[i] == '$'; returns the tag length including both '$', or 0.
	int j = i + 1
	while (s[j] != 0 && (isalnum(s[j]) || s[j] == '_')): j = j + 1
	if (s[j] == '$' && (j == i + 1 || isdigit(s[i + 1]) == 0)): return j - i + 1
	return 0


list[char*] orm_mx_split_sql(char* sql):
	list[char*] out = new list[char*]
	if (sql == 0): return out
	int start = 0
	int i = 0
	while (1):
		char ch = sql[i]
		if (ch == 0 || ch == ';'):
			char* piece = str_copy_range(sql, start, i)
			char* trimmed = strip(piece)
			free(piece)
			if (trimmed[0] != 0): out.push(trimmed)
			else: free(trimmed)
			if (ch == 0): break
			i = i + 1
			start = i
			continue
		if (ch == 39 || ch == '"'):
			i = i + 1
			while (sql[i] != 0 && sql[i] != ch): i = i + 1
			if (sql[i] != 0): i = i + 1
			continue
		if (ch == '-' && sql[i + 1] == '-'):
			while (sql[i] != 0 && sql[i] != 10): i = i + 1
			continue
		if (ch == '/' && sql[i + 1] == '*'):
			i = i + 2
			while (sql[i] != 0 && (sql[i] != '*' || sql[i + 1] != '/')): i = i + 1
			if (sql[i] != 0): i = i + 2
			continue
		if (ch == '$'):
			int n = orm_mx_dollar_tag_len(sql, i)
			if (n > 0):
				char* tag = str_copy_range(sql, i, i + n)
				i = i + n
				while (sql[i] != 0 && starts_with_at(sql, tag, i) == 0): i = i + 1
				if (sql[i] != 0): i = i + n
				free(tag)
				continue
		i = i + 1
	return out


int orm_mx_raw_sql(orm_mx_ctx* x, char* sql):
	list[char*] stmts = orm_mx_split_sql(sql)
	int ok = 1
	for char* s in stmts:
		if (ok && orm_mx_exec(x, s) == 0): ok = 0
	orm_mx_free_strings(stmts)
	return ok


# ---------------------------------------------------------------------------
# Keyset batches: runs prefix + "<pk> > last AND <pk> <= upper" + suffix
# once per window of `batch` primary keys of `table`, in pk order. Outside a
# transaction each statement commits on its own, so no batch holds a long
# transaction.
int orm_mx_batched(orm_mx_ctx* x, char* table, char* pk, int batch, char* prefix, char* suffix):
	if (batch <= 0): batch = 1000
	if (x.dry):
		string_builder* c = string_new()
		string_append(c, c"batched by ")
		string_append(c, pk)
		string_append(c, c", ")
		string_append_int(c, batch)
		string_append(c, c" rows per statement, :last/:upper are keyset bounds")
		char* text = orm_mx_take(c)
		orm_mx_comment(x, text)
		free(text)
		string_builder* s = string_new()
		string_append(s, prefix)
		orm_mx_ident_to(s, pk)
		string_append(s, c" > :last AND ")
		orm_mx_ident_to(s, pk)
		string_append(s, c" <= :upper")
		string_append(s, suffix)
		return orm_mx_run_b(x, s)
	char* last = 0
	while (1):
		orm_db_set_error(x.db, c"")
		string_builder* q = string_new()
		string_append(q, c"SELECT MAX(w_k) FROM (SELECT ")
		orm_mx_ident_to(q, pk)
		string_append(q, c" AS w_k FROM ")
		orm_mx_ident_to(q, table)
		if (last != 0):
			string_append(q, c" WHERE ")
			orm_mx_ident_to(q, pk)
			string_append(q, c" > ")
			orm_mx_value_to(q, last)
		string_append(q, c" ORDER BY ")
		orm_mx_ident_to(q, pk)
		string_append(q, c" LIMIT ")
		string_append_int(q, batch)
		string_append(q, c") w_batch")
		char* qs = orm_mx_take(q)
		char* upper = orm_mx_scalar(x, qs)
		free(qs)
		if (upper == 0):
			if (last != 0): free(last)
			return orm_db_error(x.db)[0] == 0
		string_builder* s = string_new()
		string_append(s, prefix)
		if (last != 0):
			orm_mx_ident_to(s, pk)
			string_append(s, c" > ")
			orm_mx_value_to(s, last)
			string_append(s, c" AND ")
		orm_mx_ident_to(s, pk)
		string_append(s, c" <= ")
		orm_mx_value_to(s, upper)
		string_append(s, suffix)
		if (last != 0): free(last)
		last = upper
		if (orm_mx_run_b(x, s) == 0):
			free(last)
			return 0
	return 1


# Common columns of two tables, in the order of `a`.
list[char*] orm_mx_common_columns(list[char*] a, list[char*] b):
	list[char*] out = new list[char*]
	for char* c in a:
		if (orm_mx_list_has(b, c)): out.push(c)
	return out


# Trigger / function base names for SYNC_TRIGGER.
char* orm_mx_sync_column_name(orm_op* op):
	return orm_mx_name(c"w_sync_", op.table, c"__", op.column)


char* orm_mx_sync_table_name(char* from_table, char* to_table):
	return orm_mx_name(c"w_sync_", from_table, c"__to__", to_table)


# Object name moved from one prefix to another, or 0 when it lacks `from`.
char* orm_mx_reprefix(char* name, char* from, char* to):
	if (starts_with_at(name, from, 0) == 0): return 0
	char* raw = orm_mx_cat(to, cast(char*, &name[strlen(from)]), 0, 0)
	char* out = orm_mx_name(raw, 0, 0, 0)
	free(raw)
	return out


# Prefix used while a swap moves index names between two tables.
char* orm_mx_swap_prefix():
	return c"w_swp_"
