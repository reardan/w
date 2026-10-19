# w-orm shared contracts (issue #754, unit U0.4).
#
# Every other w-orm module imports this file and builds against these
# structs. It is owned by U0.4: units in a wave never change it in their own
# PR; a needed change goes through a small contract PR first
# (docs/projects/orm.md, "Contracts").
#
#   C1  orm_model_desc / orm_field_desc / orm_index_desc / orm_check_desc
#   C2  field kinds and flag bits
#   C3  query tree: orm_query, orm_where, orm_expr, orm_order, ...
#   C4  compiler entry points (orm_compiled, orm_column_map)
#   C5  orm_dialect
#   C6  orm_result ownership
#   C7  migration operations (orm_op, orm_migration)
#   C8  history layout constants and context protocol
#   +   orm_db, the connection wrapper every layer shares
import libs.standard.sql.client
import libs.standard.sql.builder
import lib.str
import structures.string


# ---------------------------------------------------------------------------
# C2: field kinds and flags

const int ORM_INT = 1        # word-sized int field
const int ORM_BIGINT = 2     # int on x64; stored as int
const int ORM_BOOL = 3       # int 0/1
const int ORM_TEXT = 4       # char* (VARCHAR(max_length) when max_length > 0, else TEXT)
const int ORM_DECIMAL = 5    # char* decimal text, NUMERIC(digits, places)
const int ORM_DATETIME = 6   # char* ISO-8601 UTC "YYYY-MM-DD HH:MM:SS[.ffffff]"
const int ORM_DATE = 7       # char* "YYYY-MM-DD"
const int ORM_UUID = 8       # char* canonical lower-case text
const int ORM_JSON = 9       # char* JSON text
const int ORM_FK = 10        # int <name>_id column; rel_offset holds the loaded T*
const int ORM_ENUM = 11      # char* stored value, one of enum_values
const int ORM_M2M = 12       # no column; through table; rel_offset holds list[T*]
const int ORM_REVERSE_FK = 13  # no column; rel_offset holds list[T*] of rows pointing here
const int ORM_FLOAT = 14     # char* text (W float support varies by target)

const int ORM_F_PK = 1
const int ORM_F_NULL = 2
const int ORM_F_UNIQUE = 4
const int ORM_F_INDEXED = 8
const int ORM_F_AUTO = 16           # database-generated value (auto-increment pk)
const int ORM_F_AUTO_NOW_ADD = 32   # set to now on insert
const int ORM_F_AUTO_NOW = 64       # set to now on every save
const int ORM_F_DEPRECATED = 128    # "separate and later drop": not selected or written
const int ORM_F_NO_HISTORY = 256    # excluded from history tables
const int ORM_F_READ_ONLY = 512     # never written by save()

const int ORM_CASCADE = 1
const int ORM_PROTECT = 2      # emitted as RESTRICT
const int ORM_RESTRICT = 3
const int ORM_SET_NULL = 4
const int ORM_SET_DEFAULT = 5
const int ORM_DO_NOTHING = 6   # NO ACTION


# ---------------------------------------------------------------------------
# C1: model descriptors
#
# Generated code (bin/orm_gen) and hand-written fixtures build one
# orm_model_desc per model at startup and register it. Struct layout rules
# for a model struct T:
# - the first field is the pk `int id` unless the schema names another pk;
# - scalar kinds store their value at `offset` (int for INT/BIGINT/BOOL/FK,
#   char* for the text-backed kinds); a nullable int-backed field also has an
#   `int <name>__isnull` flag at `null_offset` (-1 when absent; char* kinds use
#   a null pointer for SQL NULL);
# - FK `author` stores `int author_id` at `offset` and a loaded pointer at
#   `rel_offset` (typed `Author*` when Author is declared earlier in the file,
#   otherwise `void*` with a typed accessor `Book_author(b)` emitted later);
# - M2M and reverse-FK relations have offset -1 and a `list[void*]` at
#   `rel_offset`, filled only by prefetch, with a typed accessor.

struct orm_field_desc:
	char* name           # W field name, also the lookup name ("author")
	char* column         # SQL column ("author_id"); 0 for M2M/reverse
	int kind             # ORM_*
	int offset           # byte offset of the stored value, -1 for M2M/reverse
	int size             # bytes at offset (word size for every current kind)
	int flags            # ORM_F_*
	int null_offset      # offset of the int null flag, or -1
	int max_length       # TEXT: VARCHAR length, 0 = unbounded
	int digits           # DECIMAL precision
	int places           # DECIMAL scale
	char* default_sql    # SQL default expression, or 0
	char* rel_model      # FK/M2M/reverse target model name
	void* rel_target     # orm_model_desc* once orm_registry_resolve() ran
	int rel_offset       # offset of the loaded pointer/list, or -1
	int on_delete        # ORM_CASCADE ... (FK only)
	char* related_name   # FK: reverse accessor on the target ("books")
	char* through_table  # M2M: join table name
	char* through_from   # M2M: join column pointing at this model
	char* through_to     # M2M: join column pointing at the target
	char* reverse_field  # REVERSE_FK: the FK field name on rel_model
	list[char*] enum_values


struct orm_index_desc:
	char* name
	list[char*] columns
	int unique
	char* condition_sql  # partial index WHERE, or 0


struct orm_check_desc:
	char* name
	char* condition_sql


struct orm_model_desc:
	char* name           # "Book"
	char* table          # "library_book"
	int struct_size
	list[orm_field_desc*] fields   # declaration order; relations included
	int pk_index         # index into fields
	int history          # 1 when the model opted into trigger history (C8)
	list[orm_index_desc*] indexes
	list[orm_check_desc*] checks
	list[list[char*]] unique_together
	char* schema_json    # migration snapshot of this model (U1.1 / U2.2), or 0


orm_field_desc* orm_field_new(char* name, char* column, int kind, int offset, int flags):
	orm_field_desc* f = new orm_field_desc()
	f.name = name
	f.column = column
	f.kind = kind
	f.offset = offset
	f.size = sizeof(int)
	f.flags = flags
	f.null_offset = -1
	f.rel_offset = -1
	f.enum_values = new list[char*]
	return f


orm_model_desc* orm_model_new(char* name, char* table, int struct_size):
	orm_model_desc* m = new orm_model_desc()
	m.name = name
	m.table = table
	m.struct_size = struct_size
	m.fields = new list[orm_field_desc*]
	m.indexes = new list[orm_index_desc*]
	m.checks = new list[orm_check_desc*]
	m.unique_together = new list[list[char*]]
	m.pk_index = -1
	return m


orm_field_desc* orm_model_add_field(orm_model_desc* m, orm_field_desc* f):
	if ((f.flags & ORM_F_PK) != 0): m.pk_index = m.fields.length
	m.fields.push(f)
	return f


orm_field_desc* orm_model_field(orm_model_desc* m, char* name):
	if (m == 0 || name == 0): return 0
	for orm_field_desc* f in m.fields:
		if (strcmp(f.name, name) == 0): return f
	return 0


orm_field_desc* orm_model_pk(orm_model_desc* m):
	if (m == 0 || m.pk_index < 0): return 0
	return m.fields[m.pk_index]


orm_model_desc* orm_field_target(orm_field_desc* f):
	return cast(orm_model_desc*, f.rel_target)


# 1 when the field has a real column on its model's table.
int orm_field_has_column(orm_field_desc* f):
	if (f.kind == ORM_M2M || f.kind == ORM_REVERSE_FK): return 0
	return f.column != 0


int orm_field_is_text_backed(orm_field_desc* f):
	int k = f.kind
	if (k == ORM_INT || k == ORM_BIGINT || k == ORM_BOOL || k == ORM_FK): return 0
	if (k == ORM_M2M || k == ORM_REVERSE_FK): return 0
	return 1


# Raw slot access by descriptor offset. Text-backed kinds hold a char* in
# the word, so both helpers move one word.
int orm_slot_get(void* obj, int offset):
	int* p = cast(int*, cast(char*, obj) + offset)
	return p[0]


void orm_slot_set(void* obj, int offset, int value):
	int* p = cast(int*, cast(char*, obj) + offset)
	p[0] = value


# ---------------------------------------------------------------------------
# Model registry

map[char*, orm_model_desc*] __orm_registry
list[orm_model_desc*] __orm_registry_order


void orm_register(orm_model_desc* m):
	if (__orm_registry == 0):
		__orm_registry = new map[char*, orm_model_desc*]
		__orm_registry_order = new list[orm_model_desc*]
	if (m.name in __orm_registry): return
	__orm_registry[m.name] = m
	__orm_registry_order.push(m)


orm_model_desc* orm_model_lookup(char* name):
	if (__orm_registry == 0 || name == 0): return 0
	if (name in __orm_registry): return __orm_registry[name]
	return 0


list[orm_model_desc*] orm_registry_models():
	if (__orm_registry_order == 0): __orm_registry_order = new list[orm_model_desc*]
	return __orm_registry_order


# Links rel_target pointers. Returns 0 (and leaves the name in *missing when
# non-null) when a relation names an unregistered model.
int orm_registry_resolve(char** missing):
	for orm_model_desc* m in orm_registry_models():
		for orm_field_desc* f in m.fields:
			if (f.rel_model != 0):
				orm_model_desc* t = orm_model_lookup(f.rel_model)
				if (t == 0):
					if (missing != 0): missing[0] = f.rel_model
					return 0
				f.rel_target = t
	return 1


# ---------------------------------------------------------------------------
# C3: query tree
#
# Field paths use Django's "__" separator: "author__name". A lookup is the
# operator name without the leading "__". Everything below is plain data;
# orm_query_clone deep-copies the tree nodes it owns (expressions and where
# nodes are immutable once built, so clones share them).

const int ORM_Q_SELECT = 1
const int ORM_Q_UPDATE = 2
const int ORM_Q_DELETE = 3
const int ORM_Q_INSERT = 4

const int ORM_E_FIELD = 1      # path
const int ORM_E_VALUE = 2      # value (text, bound as a parameter)
const int ORM_E_NULL = 3
const int ORM_E_FUNC = 4       # name(args)
const int ORM_E_AGG = 5        # name(args) with distinct / filter
const int ORM_E_CASE = 6       # whens + else_expr
const int ORM_E_SUBQUERY = 7   # (subquery), must select one column
const int ORM_E_EXISTS = 8     # EXISTS(subquery)
const int ORM_E_STAR = 9       # COUNT(*)
const int ORM_E_RAW = 10       # trusted SQL text in name, args bound in order for each '%s'
const int ORM_E_OUTER_REF = 11 # path resolved against the enclosing query
const int ORM_E_BINOP = 12     # args[0] name args[1], name in + - * / ||
const int ORM_E_WINDOW = 13    # args[0] OVER (PARTITION BY partition ORDER BY order)
const int ORM_E_INT = 14       # value is an integer literal inlined as text (LIMIT-safe ints only)

const int ORM_W_AND = 1
const int ORM_W_OR = 2
const int ORM_W_NOT = 3
const int ORM_W_LOOKUP = 4     # lhs lookup rhs / rhs_list
const int ORM_W_EXPR = 5       # boolean expression lhs
const int ORM_W_TRUE = 6
const int ORM_W_FALSE = 7

# Lookups every dialect must support (U1.2): exact iexact ne lt lte gt gte in
# range isnull contains icontains startswith istartswith endswith iendswith
# regex. `exact` with an ORM_E_NULL rhs compiles to IS NULL.

const int ORM_NULLS_DEFAULT = 0
const int ORM_NULLS_FIRST = 1
const int ORM_NULLS_LAST = 2

const int ORM_JOIN_INNER = 1
const int ORM_JOIN_LEFT = 2

const int ORM_CONFLICT_NONE = 0
const int ORM_CONFLICT_NOTHING = 1
const int ORM_CONFLICT_UPDATE = 2




struct orm_expr:
	int kind
	char* path
	char* value
	char* name
	list[orm_expr*] args
	void* filter         # orm_where* (aggregate FILTER)
	void* subquery       # orm_query*
	int distinct
	list[void*] whens    # orm_when*
	orm_expr* else_expr
	list[orm_expr*] partition_by
	list[void*] order_by # orm_order*
	int output_kind      # ORM_* kind of the result, 0 = unknown


struct orm_where:
	int kind
	list[orm_where*] children
	orm_expr* lhs
	char* lookup
	orm_expr* rhs
	list[orm_expr*] rhs_list


struct orm_when:
	orm_where* condition
	orm_expr* then


struct orm_order:
	orm_expr* expr
	int descending
	int nulls


struct orm_annotation:
	char* name
	orm_expr* expr


struct orm_assignment:
	char* field          # model field name (FKs by field name: "author")
	orm_expr* value


struct orm_prefetch:
	char* path           # relation path from the queried model ("books__tags")
	void* queryset       # orm_query* restricting the related rows, or 0
	char* to_attr        # store in a different list slot, or 0


struct orm_query:
	int kind
	orm_model_desc* model
	orm_where* where
	list[orm_annotation*] annotations
	list[orm_expr*] select        # values()/values_list(); empty = model columns
	list[char*] select_names      # names for select entries
	list[char*] select_related    # relation paths joined in (FK only)
	list[orm_prefetch*] prefetch
	list[orm_order*] order
	list[orm_expr*] group_by
	orm_where* having
	int limit                     # -1 = none
	int offset
	int distinct
	int for_update
	int skip_locked
	int nowait
	list[orm_assignment*] assignments       # UPDATE SET, or one INSERT row
	list[list[orm_assignment*]] insert_rows # multi-row INSERT
	list[char*] returning                   # field names; empty = none
	int conflict_action
	list[char*] conflict_fields
	list[char*] update_fields               # ON CONFLICT DO UPDATE SET these
	list[char*] only_fields                 # only()/defer() result, empty = all


orm_query* orm_query_new(int kind, orm_model_desc* model):
	orm_query* q = new orm_query()
	q.kind = kind
	q.model = model
	q.annotations = new list[orm_annotation*]
	q.select = new list[orm_expr*]
	q.select_names = new list[char*]
	q.select_related = new list[char*]
	q.prefetch = new list[orm_prefetch*]
	q.order = new list[orm_order*]
	q.group_by = new list[orm_expr*]
	q.limit = -1
	q.assignments = new list[orm_assignment*]
	q.insert_rows = new list[list[orm_assignment*]]
	q.returning = new list[char*]
	q.conflict_fields = new list[char*]
	q.update_fields = new list[char*]
	q.only_fields = new list[char*]
	return q


# Shallow list copies: the node objects are shared and never mutated after
# construction, so a clone can be refined without touching the original.
orm_query* orm_query_clone(orm_query* q):
	orm_query* c = orm_query_new(q.kind, q.model)
	c.where = q.where
	for orm_annotation* a in q.annotations: c.annotations.push(a)
	for orm_expr* e in q.select: c.select.push(e)
	for char* n in q.select_names: c.select_names.push(n)
	for char* p in q.select_related: c.select_related.push(p)
	for orm_prefetch* pf in q.prefetch: c.prefetch.push(pf)
	for orm_order* o in q.order: c.order.push(o)
	for orm_expr* g in q.group_by: c.group_by.push(g)
	c.having = q.having
	c.limit = q.limit
	c.offset = q.offset
	c.distinct = q.distinct
	c.for_update = q.for_update
	c.skip_locked = q.skip_locked
	c.nowait = q.nowait
	for orm_assignment* s in q.assignments: c.assignments.push(s)
	for list[orm_assignment*] row in q.insert_rows: c.insert_rows.push(row)
	for char* r in q.returning: c.returning.push(r)
	c.conflict_action = q.conflict_action
	for char* cf in q.conflict_fields: c.conflict_fields.push(cf)
	for char* uf in q.update_fields: c.update_fields.push(uf)
	for char* of in q.only_fields: c.only_fields.push(of)
	return c


orm_expr* orm_expr_new(int kind):
	orm_expr* e = new orm_expr()
	e.kind = kind
	e.args = new list[orm_expr*]
	e.whens = new list[void*]
	e.partition_by = new list[orm_expr*]
	e.order_by = new list[void*]
	return e


orm_where* orm_where_new(int kind):
	orm_where* w = new orm_where()
	w.kind = kind
	w.children = new list[orm_where*]
	w.rhs_list = new list[orm_expr*]
	return w


# Splits "author__name__icontains" style paths. Returns a new list of parts.
list[char*] orm_path_split(char* path):
	list[char*] parts = new list[char*]
	if (path == 0): return parts
	int n = strlen(path)
	int start = 0
	int i = 0
	while (i <= n):
		if (i == n || (path[i] == '_' && i + 1 < n && path[i + 1] == '_')):
			int len = i - start
			char* part = cast(char*, malloc(len + 1))
			for j in range(len): part[j] = path[start + j]
			part[len] = 0
			parts.push(part)
			if (i == n): break
			i = i + 2
			start = i
			continue
		i = i + 1
	return parts


# ---------------------------------------------------------------------------
# C5: dialects (instances live in U1.2's dialect_*.w)

const int ORM_DIALECT_SQLITE = 1
const int ORM_DIALECT_POSTGRES = 2

struct orm_dialect:
	int id
	char* name
	int bind_style               # sql_bind_question / sql_bind_dollar
	int supports_returning
	int supports_for_update
	int supports_ilike
	int supports_nulls_order
	int supports_filter_clause
	int supports_concurrent_index
	int supports_transactional_ddl
	int supports_distinct_on
	int max_params               # bound parameters per statement


# ---------------------------------------------------------------------------
# C4: compiler output
#
#   int orm_compile(orm_query* q, orm_dialect* d, orm_compiled* out)
#
# (U1.2) fills `out` and returns 1, or returns 0 with out.error set. The
# column map tells the loader (U1.3) what each result column is.

struct orm_column_map:
	orm_model_desc* model       # model the column belongs to, 0 for annotations/values
	orm_field_desc* field       # field, 0 for annotations/values
	char* rel_path              # "" for the root model, else the select_related path
	char* name                  # annotation/values name, or the field name


struct orm_compiled:
	sql_builder* sql
	list[orm_column_map*] columns
	char* error


orm_compiled* orm_compiled_new(orm_dialect* d):
	orm_compiled* c = new orm_compiled()
	c.sql = sql_builder_new(d.bind_style)
	c.columns = new list[orm_column_map*]
	return c


void orm_compiled_free(orm_compiled* c):
	if (c == 0): return
	sql_builder_free(c.sql)
	for orm_column_map* m in c.columns: free(cast(void*, m))
	c.columns.free()
	free(cast(void*, c))


# ---------------------------------------------------------------------------
# orm_db: the connection wrapper every layer shares

type orm_callback_fn = fn(void*) -> void

struct orm_callback:
	orm_callback_fn* fn
	void* ctx


struct orm_db:
	sql_connection* conn
	orm_dialect* dialect
	int query_count
	int atomic_depth             # 0 = autocommit, 1 = outer transaction, >1 = savepoints
	int rollback_only            # set when an inner block failed
	list[orm_callback*] on_commit
	int log_queries
	list[char*] query_log        # copies of executed SQL when log_queries
	char* error                  # last ORM-level error (owned copy), "" when none
	char* history_context        # C8: JSON context for the current transaction, or 0
	void* on_begin               # orm_begin_fn* run after the outermost BEGIN, or 0


# Called by orm_atomic_begin right after the outermost BEGIN (history
# uses it to publish the transaction-local context). Returns 0 with
# orm_db_error set to abort the block.
type orm_begin_fn = fn(orm_db*) -> int


orm_db* orm_db_new(sql_connection* conn, orm_dialect* dialect):
	orm_db* db = new orm_db()
	db.conn = conn
	db.dialect = dialect
	db.on_commit = new list[orm_callback*]
	db.query_log = new list[char*]
	db.error = strclone(c"")
	return db


int orm_db_set_error(orm_db* db, char* message):
	if (db.error != 0): free(db.error)
	db.error = strclone(message)
	return 0


char* orm_db_error(orm_db* db):
	return db.error


# Executes a built statement, counting it. Returns an owned result or 0 with
# orm_db_error / sql_error(db.conn) describing the failure.
sql_result* orm_db_execute(orm_db* db, sql_builder* b):
	db.query_count = db.query_count + 1
	char* text = b.text.data
	if (db.log_queries): db.query_log.push(strclone(text))
	sql_result* r = sql_query_params(db.conn, text, b.parameters.length, sql_builder_values(b))
	if (r == 0): orm_db_set_error(db, sql_error(db.conn))
	return r


# Trusted SQL with no parameters (DDL, migrations). Returns 1/0.
int orm_db_exec_sql(orm_db* db, char* text):
	db.query_count = db.query_count + 1
	if (db.log_queries): db.query_log.push(strclone(text))
	int ok = sql_exec(db.conn, text)
	if (ok == 0): orm_db_set_error(db, sql_error(db.conn))
	return ok


# ---------------------------------------------------------------------------
# C6: result ownership
#
# Every evaluated query returns an orm_result that owns all memory it
# loaded: row structs, copied strings and relation lists. orm_result_free
# releases everything at once. Rows that must outlive the result are copied
# out by the caller (generated Model_clone).

struct orm_result:
	orm_model_desc* model
	list[void*] rows
	list[void*] owned            # every allocation, freed by orm_result_free
	list[void*] owned_lists      # list headers (list[void*]) freed with .free()
	int affected


orm_result* orm_result_new(orm_model_desc* model):
	orm_result* r = new orm_result()
	r.model = model
	r.rows = new list[void*]
	r.owned = new list[void*]
	r.owned_lists = new list[void*]
	r.affected = -1
	return r


void* orm_result_alloc(orm_result* r, int size):
	char* p = cast(char*, malloc(size))
	for i in range(size): p[i] = 0
	r.owned.push(p)
	return p


char* orm_result_strdup(orm_result* r, char* s):
	if (s == 0): return 0
	char* c = strclone(s)
	r.owned.push(c)
	return c


list[void*] orm_result_list(orm_result* r):
	list[void*] l = new list[void*]
	r.owned_lists.push(cast(void*, l))
	return l


void orm_result_free(orm_result* r):
	if (r == 0): return
	for void* p in r.owned: free(p)
	for void* lp in r.owned_lists:
		list[void*] l = cast(list[void*], lp)
		l.free()
	r.owned.free()
	r.owned_lists.free()
	r.rows.free()
	free(cast(void*, r))


# ---------------------------------------------------------------------------
# C7: migration operations
#
# A migration is an ordered list of orm_op. The planner (U2.3) expands an
# unsafe change into expand / migrate / contract operations that ship in
# separate migrations; the applier (U2.4) runs them; the autodetector (U2.2)
# produces them from schema snapshots.
#
# Field use per op (agreed by U2.3/U2.4):
# - table-level copies (SYNC_TRIGGER, COPY_TABLE, SWAP_TABLES, RENAME_TABLE):
#   `table` is the new table, `source_table` the old one;
# - column-level copies (SYNC_TRIGGER, COPY_COLUMN): `column` is the new
#   column, `source_column` the old one;
# - ADD_CONSTRAINT: `name` plus `sql` holding the whole constraint body
#   ("CHECK (...)", "FOREIGN KEY (...) REFERENCES ...", "UNIQUE USING INDEX i");
#   the applier appends NOT VALID on PostgreSQL;
# - BACKFILL: `name` and `sql` both hold the registered backfill name.
#
# field_json keys (a subset of the U1.1 schema snapshot's field object):
#   "name", "column", "kind" (ORM_* number), "null" (bool; absent = NOT NULL),
#   "default" (SQL text; present and non-null = the column has a DB default),
#   "deprecated" (bool; an ALTER_NULL carrying it only drops NOT NULL),
#   "max_length", "digits", "places", "unique" (bool), and for ADD_INDEX
#   "columns" (array of column names) plus "unique".

const int ORM_OP_CREATE_TABLE = 1       # model_json: full model snapshot
const int ORM_OP_DROP_TABLE = 2
const int ORM_OP_ADD_COLUMN = 3         # field_json
const int ORM_OP_DROP_COLUMN = 4
const int ORM_OP_ALTER_NULL = 5         # field_json; sets/drops NOT NULL
const int ORM_OP_ADD_INDEX = 6          # index name, columns in field_json
const int ORM_OP_DROP_INDEX = 7
const int ORM_OP_ADD_CONSTRAINT = 8     # name + sql (CHECK/UNIQUE/FK), added NOT VALID where supported
const int ORM_OP_VALIDATE_CONSTRAINT = 9
const int ORM_OP_DROP_CONSTRAINT = 10
const int ORM_OP_COPY_COLUMN = 11       # backfill column from source_column, batched
const int ORM_OP_SYNC_TRIGGER = 12      # install dual-write trigger column <-> source_column (or table <-> source_table)
const int ORM_OP_DROP_SYNC_TRIGGER = 13
const int ORM_OP_COPY_TABLE = 14        # batched copy source_table -> table
const int ORM_OP_SWAP_TABLES = 15       # rename table <-> source_table in one transaction
const int ORM_OP_BACKFILL = 16          # run a registered W backfill function by name (sql = name)
const int ORM_OP_RAW_SQL = 17           # trusted sql; reverse_sql optional
const int ORM_OP_RENAME_TABLE = 18      # only for tables nothing reads yet (planner-checked)
const int ORM_OP_CREATE_HISTORY = 19    # C8: history table + triggers for model_json
const int ORM_OP_DROP_HISTORY = 20

const int ORM_PHASE_EXPAND = 1
const int ORM_PHASE_MIGRATE = 2
const int ORM_PHASE_CONTRACT = 3

struct orm_op:
	int kind
	int phase
	char* table
	char* column
	char* name                # index / constraint / backfill name
	char* source_table
	char* source_column
	char* model_json          # model snapshot (CREATE_TABLE, CREATE_HISTORY)
	char* field_json          # field snapshot (ADD_COLUMN, ALTER_NULL, ADD_INDEX)
	char* sql
	char* reverse_sql
	int non_atomic            # must run outside a transaction (CONCURRENTLY)
	int unsafe                # planner/linter flagged; applier requires force
	int batch_size            # COPY_COLUMN / COPY_TABLE / BACKFILL


struct orm_migration:
	char* app
	char* name                # "0003_book_price_rename"
	list[char*] dependencies  # "app.0002_x"
	list[orm_op*] ops
	int atomic                # 0 when any op is non_atomic
	char* requires_applied    # contract step: name of the expand migration that must be applied first, or 0
	int phase                 # ORM_PHASE_* of the migration as a whole (empty marker migrations), 0 = derive from ops


orm_op* orm_op_new(int kind, int phase, char* table):
	orm_op* op = new orm_op()
	op.kind = kind
	op.phase = phase
	op.table = table
	op.batch_size = 1000
	return op


orm_migration* orm_migration_new(char* app, char* name):
	orm_migration* m = new orm_migration()
	m.app = app
	m.name = name
	m.dependencies = new list[char*]
	m.ops = new list[orm_op*]
	m.atomic = 1
	return m


void orm_migration_add(orm_migration* m, orm_op* op):
	if (op.non_atomic): m.atomic = 0
	m.ops.push(op)


# ---------------------------------------------------------------------------
# C8: history layout
#
# A model with history = 1 gets table "<table>_history" with every
# non-relation column of the model (no UNIQUE/PK/FK constraints, all
# nullable) plus these columns, written only by database triggers:

char* ORM_HISTORY_SUFFIX():
	return c"_history"

# history_id (INTEGER PRIMARY KEY / BIGSERIAL), history_date (UTC text),
# history_type ('+' insert, '~' update, '-' delete), history_user_id (int, null),
# history_reason (text, null), history_context_id (text, null).
const int ORM_HISTORY_INSERT = '+'
const int ORM_HISTORY_UPDATE = '~'
const int ORM_HISTORY_DELETE = '-'

# Context protocol: before writes in a transaction, the ORM publishes
# {"context_id": "...", "user_id": N, "reason": "..."}:
# - PostgreSQL: SELECT set_config('w_orm.context', <json>, true)
#   and triggers read current_setting('w_orm.context', true);
# - SQLite: a per-connection TEMP table
char* ORM_HISTORY_SQLITE_CONTEXT_TABLE():
	return c"_w_orm_context"
# (columns context_id, user_id, reason; one row, replaced per transaction).
