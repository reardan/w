# w-orm SQL compiler (issue #754, unit U1.2; contracts C3/C4/C5).
#
#   int orm_compile(orm_query* q, orm_dialect* d, orm_compiled* out)
#
# One tree walk emits SQL for every dialect; the few spellings that differ
# switch on d.id or on the C5 capability flags ("one tree, per-backend
# emission"). Values are always bound through sql_builder_bind and
# identifiers always quoted with sql_builder_identifier; the only text
# taken from the tree verbatim is ORM_E_RAW (trusted) and validated
# function / operator names and ORM_E_INT digits.
#
# A SELECT is emitted twice: the first pass writes into a scratch builder
# and only discovers the joins its paths need, the second writes the real
# statement with the complete FROM clause. Subqueries run the same two
# passes inside their parent and use the next alias letter (t0.. for the
# outer query, u0.. one level down, ...), so OUTER_REF can name the
# enclosing alias unambiguously.
#
# Bulk callers must keep the bound values per statement under d.max_params
# themselves; the compiler never splits a statement.
import libs.standard.orm.contract
import libs.standard.orm.dialect_sqlite
import libs.standard.orm.dialect_postgres


struct orm_cjoin:
	char* key            # relation path ("author", "books__tags"), interned
	int through          # 1 for the M2M through-table hop of key
	char* alias
	char* left_alias
	char* left_col
	char* right_col
	char* table
	int kind             # ORM_JOIN_INNER / ORM_JOIN_LEFT


struct orm_cref:
	char* alias          # 0 in unqualified (UPDATE/DELETE/INSERT) mode
	orm_field_desc* field
	orm_model_desc* model
	int nullable         # field is nullable or reached through a LEFT join


struct orm_cgroup:
	char* alias
	char* column         # 0: group by select-list ordinal
	int ordinal


struct orm_cctx:
	orm_query* q
	orm_dialect* d
	sql_builder* b
	orm_compiled* out    # column map target (root statement only)
	orm_cctx* parent     # enclosing query for OUTER_REF, or 0
	orm_cctx* root       # holds the first error
	list[orm_cjoin*] joins
	list[orm_cgroup*] groups
	list[char*] related_done
	char* alias          # base alias; 0 = unqualified column names
	int prefix           # alias letter
	int final            # second pass: fill the column map
	int ncols
	int has_agg
	int exists_mode      # SELECT 1 (EXISTS subquery)
	int no_fields        # INSERT values: field references are errors
	int nesting          # annotation inlining depth
	char* error


# ---------------------------------------------------------------------------
# Small helpers

map[char*, char*] __orm_cintern_table


# Stable copy of a short string (aliases, relation path keys, column-map
# rel_paths). Bounded by the distinct paths a program uses.
char* orm_cintern(char* s):
	if (__orm_cintern_table == 0): __orm_cintern_table = new map[char*, char*]
	if (s in __orm_cintern_table): return __orm_cintern_table[s]
	char* copy = strclone(s)
	__orm_cintern_table[copy] = copy
	return copy


char* orm_calias(int prefix, int n):
	string_builder* s = string_new()
	string_append_char(s, prefix)
	string_append_int(s, n)
	char* alias = orm_cintern(s.data)
	string_free(s)
	return alias


orm_cctx* orm_cctx_new(orm_query* q, orm_dialect* d, orm_cctx* parent, orm_cctx* root):
	orm_cctx* c = new orm_cctx()
	c.q = q
	c.d = d
	c.parent = parent
	c.root = root
	if (root == 0): c.root = c
	c.joins = new list[orm_cjoin*]
	c.groups = new list[orm_cgroup*]
	c.related_done = new list[char*]
	c.prefix = 't'
	if (parent != 0 && parent.prefix < 'z'): c.prefix = parent.prefix + 1
	c.alias = orm_calias(c.prefix, 0)
	return c


void orm_cgroups_clear(orm_cctx* c):
	for orm_cgroup* g in c.groups: free(cast(void*, g))
	c.groups.free()
	c.groups = new list[orm_cgroup*]


void orm_cctx_free(orm_cctx* c):
	for orm_cjoin* j in c.joins: free(cast(void*, j))
	c.joins.free()
	orm_cgroups_clear(c)
	c.groups.free()
	c.related_done.free()
	free(cast(void*, c))


void orm_cappend_opt(string_builder* s, char* part):
	if (part != 0): string_append(s, part)


# Records the first error on the root context. Always returns 0.
int orm_cfail(orm_cctx* c, char* a, char* p2 = 0, char* p3 = 0, char* p4 = 0, char* p5 = 0, char* p6 = 0, char* p7 = 0):
	orm_cctx* r = c.root
	if (r.error != 0): return 0
	string_builder* s = string_new()
	string_append(s, a)
	orm_cappend_opt(s, p2)
	orm_cappend_opt(s, p3)
	orm_cappend_opt(s, p4)
	orm_cappend_opt(s, p5)
	orm_cappend_opt(s, p6)
	orm_cappend_opt(s, p7)
	r.error = strclone(s.data)
	string_free(s)
	return 0


int orm_cok(orm_cctx* c):
	return c.root.error == 0


void orm_csql(orm_cctx* c, char* text):
	sql_builder_append(c.b, text)


void orm_cident(orm_cctx* c, char* name):
	sql_builder_identifier(c.b, name)


void orm_ccol(orm_cctx* c, char* alias, char* column):
	if (alias != 0):
		sql_builder_identifier(c.b, alias)
		sql_builder_append(c.b, c".")
	sql_builder_identifier(c.b, column)


void orm_cint(orm_cctx* c, int v):
	string_append_int(c.b.text, v)


void orm_csep(orm_cctx* c, int i, char* sep):
	if (i > 0): sql_builder_append(c.b, sep)


orm_field_desc* orm_cfield(orm_model_desc* m, char* name):
	if (strcmp(name, c"pk") == 0): return orm_model_pk(m)
	return orm_model_field(m, name)


int orm_cdeprecated(orm_field_desc* f):
	return (f.flags & ORM_F_DEPRECATED) != 0


int orm_cvalid_name(char* s):
	if (s == 0 || s[0] == 0): return 0
	if (s[0] >= '0' && s[0] <= '9'): return 0
	for i in range(strlen(s)):
		char ch = s[i]
		int ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'
		if (ok == 0): return 0
	return 1


int orm_cvalid_int(char* s):
	if (s == 0): return 0
	int i = 0
	if (s[0] == '-'): i = 1
	if (s[i] == 0): return 0
	while (s[i] != 0):
		if (s[i] < '0' || s[i] > '9'): return 0
		i = i + 1
	return 1


char* orm_cfunction_name(orm_dialect* d, char* name):
	if (d.id == ORM_DIALECT_SQLITE): return orm_sqlite_function_name(name)
	if (d.id == ORM_DIALECT_POSTGRES): return orm_postgres_function_name(name)
	return name


void orm_cmap(orm_cctx* c, orm_model_desc* m, orm_field_desc* f, char* rel_path, char* name):
	if (c.final == 0 || c.out == 0): return
	orm_column_map* cm = new orm_column_map()
	cm.model = m
	cm.field = f
	cm.rel_path = rel_path
	cm.name = name
	c.out.columns.push(cm)


void orm_cgroup_add(orm_cctx* c, char* alias, char* column):
	orm_cgroup* g = new orm_cgroup()
	g.alias = alias
	g.column = column
	g.ordinal = c.ncols
	c.groups.push(g)


# The expression an annotation or values() name stands for, or 0. A values
# entry that is just the field of the same name is not an alias.
orm_expr* orm_cnamed(orm_cctx* c, char* path):
	if (path == 0): return 0
	orm_query* q = c.q
	for orm_annotation* a in q.annotations:
		if (strcmp(a.name, path) == 0): return a.expr
	for i in range(q.select_names.length):
		if (i < q.select.length && q.select_names[i] != 0 && strcmp(q.select_names[i], path) == 0):
			orm_expr* e = q.select[i]
			if (e.kind == ORM_E_FIELD && e.path != 0 && strcmp(e.path, path) == 0): return 0
			return e
	return 0


# ---------------------------------------------------------------------------
# Paths and joins

char* orm_cjoin_add(orm_cctx* c, char* key, int through, char* table, int kind, char* left_alias, char* left_col, char* right_col):
	for orm_cjoin* j in c.joins:
		if (j.key == key && j.through == through): return j.alias
	if (c.alias == 0):
		orm_cfail(c, c"related path '", key, c"' cannot be used in this statement")
		return 0
	orm_cjoin* j = new orm_cjoin()
	j.key = key
	j.through = through
	j.table = table
	j.kind = kind
	j.left_alias = left_alias
	j.left_col = left_col
	j.right_col = right_col
	j.alias = orm_calias(c.prefix, c.joins.length + 1)
	c.joins.push(j)
	return j.alias


int orm_cjoin_kind(int nullable):
	if (nullable): return ORM_JOIN_LEFT
	return ORM_JOIN_INNER


# Joins one relation hop from alias; returns the target alias or 0.
# nullable[0] turns (and stays) 1 once the hop can produce NULL rows.
char* orm_chop(orm_cctx* c, orm_field_desc* f, orm_model_desc* m, char* alias, char* key, int* nullable):
	orm_model_desc* t = orm_field_target(f)
	if (t == 0):
		orm_cfail(c, c"relation '", f.name, c"' on model ", m.name, c" is not resolved (call orm_registry_resolve)")
		return 0
	orm_field_desc* mpk = orm_model_pk(m)
	orm_field_desc* tpk = orm_model_pk(t)
	if (f.kind == ORM_FK):
		if ((f.flags & ORM_F_NULL) != 0): nullable[0] = 1
		return orm_cjoin_add(c, key, 0, t.table, orm_cjoin_kind(nullable[0]), alias, f.column, tpk.column)
	nullable[0] = 1
	if (f.kind == ORM_REVERSE_FK):
		orm_field_desc* back = orm_model_field(t, f.reverse_field)
		if (back == 0):
			orm_cfail(c, c"reverse relation '", f.name, c"' names a missing field on model ", t.name)
			return 0
		return orm_cjoin_add(c, key, 0, t.table, ORM_JOIN_LEFT, alias, mpk.column, back.column)
	char* mid = orm_cjoin_add(c, key, 1, f.through_table, ORM_JOIN_LEFT, alias, mpk.column, f.through_from)
	if (mid == 0): return 0
	return orm_cjoin_add(c, key, 0, t.table, ORM_JOIN_LEFT, mid, f.through_to, tpk.column)


int orm_cis_relation(orm_field_desc* f):
	return f.kind == ORM_FK || f.kind == ORM_M2M || f.kind == ORM_REVERSE_FK


void orm_cref_set(orm_cref* ref, char* alias, orm_field_desc* f, orm_model_desc* m, int nullable):
	ref.alias = alias
	ref.field = f
	ref.model = m
	ref.nullable = nullable


# 1 when path's FK hop at parts[i] can use the local <fk>_id column
# because the next (last) part is the target's primary key.
int orm_cfk_shortcut(orm_field_desc* f, list[char*] parts, int i):
	if (f.kind != ORM_FK || i != parts.length - 2): return 0
	orm_model_desc* t = orm_field_target(f)
	if (t == 0): return 0
	orm_field_desc* nf = orm_cfield(t, parts[i + 1])
	return nf != 0 && (nf.flags & ORM_F_PK) != 0


int orm_cresolve_parts(orm_cctx* c, char* path, list[char*] parts, orm_cref* ref):
	if (parts.length == 0): return orm_cfail(c, c"empty field path")
	orm_model_desc* m = c.q.model
	char* alias = c.alias
	int nullable = 0
	string_builder* key = string_new()
	int ok = 1
	for i in range(parts.length):
		orm_field_desc* f = orm_cfield(m, parts[i])
		int last = i == parts.length - 1
		if (f == 0):
			ok = orm_cfail(c, c"unknown field '", parts[i], c"' on model ", m.name, c" (path '", path, c"')")
			break
		if (last && orm_field_has_column(f)):
			orm_cref_set(ref, alias, f, m, nullable || (f.flags & ORM_F_NULL) != 0)
			break
		if (orm_cfk_shortcut(f, parts, i)):
			orm_cref_set(ref, alias, f, m, nullable || (f.flags & ORM_F_NULL) != 0)
			break
		if (orm_cis_relation(f) == 0):
			ok = orm_cfail(c, c"field '", f.name, c"' on model ", m.name, c" is not a relation (path '", path, c"')")
			break
		if (key.length > 0): string_append(key, c"__")
		string_append(key, parts[i])
		alias = orm_chop(c, f, m, alias, orm_cintern(key.data), &nullable)
		if (alias == 0):
			ok = 0
			break
		m = orm_field_target(f)
		if (last):
			orm_cref_set(ref, alias, orm_model_pk(m), m, nullable)
	string_free(key)
	return ok


# Resolves a field path to (alias, field), registering the joins it needs.
int orm_cresolve(orm_cctx* c, char* path, orm_cref* ref):
	if (path == 0): return orm_cfail(c, c"missing field path")
	list[char*] parts = orm_path_split(path)
	int ok = orm_cresolve_parts(c, path, parts, ref)
	for char* p in parts: free(p)
	parts.free()
	return ok


void orm_cjoins(orm_cctx* c):
	for orm_cjoin* j in c.joins:
		if (j.kind == ORM_JOIN_LEFT): orm_csql(c, c" LEFT JOIN ")
		else: orm_csql(c, c" INNER JOIN ")
		orm_cident(c, j.table)
		orm_csql(c, c" AS ")
		orm_cident(c, j.alias)
		orm_csql(c, c" ON ")
		orm_ccol(c, j.alias, j.right_col)
		orm_csql(c, c" = ")
		orm_ccol(c, j.left_alias, j.left_col)


int orm_chas_left_join(orm_cctx* c):
	for orm_cjoin* j in c.joins:
		if (j.kind == ORM_JOIN_LEFT): return 1
	return 0


# ---------------------------------------------------------------------------
# Expressions

int orm_cexpr(orm_cctx* c, orm_expr* e);
int orm_cwhere(orm_cctx* c, orm_where* w);
int orm_csubquery(orm_cctx* c, void* subquery, int exists);
int orm_corder_list(orm_cctx* c, list[void*] orders);


int orm_cexprs(orm_cctx* c, list[orm_expr*] l):
	for i in range(l.length):
		orm_csep(c, i, c", ")
		if (orm_cexpr(c, l[i]) == 0): return 0
	return 1


int orm_cinline_named(orm_cctx* c, orm_expr* e):
	if (c.nesting > 32): return orm_cfail(c, c"annotation refers to itself")
	c.nesting = c.nesting + 1
	int ok = orm_cexpr(c, e)
	c.nesting = c.nesting - 1
	return ok


int orm_cfield_ref(orm_cctx* c, char* path):
	if (path == 0): return orm_cfail(c, c"field expression without a path")
	if (c.no_fields): return orm_cfail(c, c"field '", path, c"' cannot be referenced in INSERT values")
	orm_expr* named = orm_cnamed(c, path)
	if (named != 0): return orm_cinline_named(c, named)
	orm_cref ref
	if (orm_cresolve(c, path, &ref) == 0): return 0
	orm_ccol(c, ref.alias, ref.field.column)
	return 1


int orm_couter_ref(orm_cctx* c, orm_expr* e):
	orm_cctx* p = c.parent
	if (p == 0): return orm_cfail(c, c"OUTER_REF '", e.path, c"' used outside a subquery")
	orm_cref ref
	if (orm_cresolve(p, e.path, &ref) == 0): return 0
	char* alias = ref.alias
	if (alias == 0): alias = p.q.model.table
	orm_ccol(c, alias, ref.field.column)
	return 1


int orm_cfunc(orm_cctx* c, orm_expr* e):
	if (orm_cvalid_name(e.name) == 0): return orm_cfail(c, c"invalid function name '", e.name, c"'")
	if (strcmp(e.name, c"NOW") == 0 && e.args.length == 0):
		orm_csql(c, c"CURRENT_TIMESTAMP")
		return 1
	orm_csql(c, orm_cfunction_name(c.d, e.name))
	orm_csql(c, c"(")
	if (orm_cexprs(c, e.args) == 0): return 0
	orm_csql(c, c")")
	return 1


int orm_cstar_arg(orm_expr* e):
	return e.args.length == 0 || e.args[0].kind == ORM_E_STAR


# Aggregate FILTER emulated as CASE WHEN for dialects without the clause.
int orm_cagg_case(orm_cctx* c, orm_expr* e, orm_where* filter):
	orm_csql(c, c"CASE WHEN ")
	if (orm_cwhere(c, filter) == 0): return 0
	orm_csql(c, c" THEN ")
	if (orm_cstar_arg(e)): orm_csql(c, c"1")
	else if (orm_cexpr(c, e.args[0]) == 0): return 0
	orm_csql(c, c" END")
	for i in range(1, e.args.length):
		orm_csql(c, c", ")
		if (orm_cexpr(c, e.args[i]) == 0): return 0
	return 1


int orm_cagg(orm_cctx* c, orm_expr* e):
	if (orm_cvalid_name(e.name) == 0): return orm_cfail(c, c"invalid aggregate name '", e.name, c"'")
	orm_where* filter = cast(orm_where*, e.filter)
	orm_csql(c, orm_cfunction_name(c.d, e.name))
	orm_csql(c, c"(")
	if (e.distinct): orm_csql(c, c"DISTINCT ")
	if (filter != 0 && c.d.supports_filter_clause == 0):
		if (orm_cagg_case(c, e, filter) == 0): return 0
		orm_csql(c, c")")
		return 1
	if (orm_cstar_arg(e)): orm_csql(c, c"*")
	else if (orm_cexprs(c, e.args) == 0): return 0
	orm_csql(c, c")")
	if (filter != 0):
		orm_csql(c, c" FILTER (WHERE ")
		if (orm_cwhere(c, filter) == 0): return 0
		orm_csql(c, c")")
	return 1


int orm_ccase(orm_cctx* c, orm_expr* e):
	if (e.whens.length == 0): return orm_cfail(c, c"CASE needs at least one WHEN")
	orm_csql(c, c"CASE")
	for void* wv in e.whens:
		orm_when* w = cast(orm_when*, wv)
		orm_csql(c, c" WHEN ")
		if (orm_cwhere(c, w.condition) == 0): return 0
		orm_csql(c, c" THEN ")
		if (orm_cexpr(c, w.then) == 0): return 0
	if (e.else_expr != 0):
		orm_csql(c, c" ELSE ")
		if (orm_cexpr(c, e.else_expr) == 0): return 0
	orm_csql(c, c" END")
	return 1


int orm_cvalid_binop(char* op):
	if (op == 0): return 0
	if (strcmp(op, c"+") == 0 || strcmp(op, c"-") == 0 || strcmp(op, c"*") == 0): return 1
	if (strcmp(op, c"/") == 0 || strcmp(op, c"%") == 0 || strcmp(op, c"||") == 0): return 1
	return 0


int orm_cbinop(orm_cctx* c, orm_expr* e):
	if (orm_cvalid_binop(e.name) == 0): return orm_cfail(c, c"invalid operator '", e.name, c"'")
	if (e.args.length != 2): return orm_cfail(c, c"operator '", e.name, c"' needs two operands")
	orm_csql(c, c"(")
	if (orm_cexpr(c, e.args[0]) == 0): return 0
	orm_csql(c, c" ")
	orm_csql(c, e.name)
	orm_csql(c, c" ")
	if (orm_cexpr(c, e.args[1]) == 0): return 0
	orm_csql(c, c")")
	return 1


# Trusted SQL; each %s takes the next argument (bound when it is a value),
# %% is a literal percent sign.
int orm_craw(orm_cctx* c, orm_expr* e):
	char* s = e.name
	if (s == 0): return orm_cfail(c, c"raw expression without SQL")
	int next = 0
	int i = 0
	while (s[i] != 0):
		if (s[i] == '%' && s[i + 1] == '%'):
			string_append_char(c.b.text, '%')
			i = i + 2
			continue
		if (s[i] == '%' && s[i + 1] == 's'):
			if (next >= e.args.length): return orm_cfail(c, c"raw expression has more %s than arguments")
			if (orm_cexpr(c, e.args[next]) == 0): return 0
			next = next + 1
			i = i + 2
			continue
		string_append_char(c.b.text, s[i])
		i = i + 1
	if (next != e.args.length): return orm_cfail(c, c"raw expression has fewer %s than arguments")
	return 1


int orm_cwindow(orm_cctx* c, orm_expr* e):
	if (e.args.length != 1): return orm_cfail(c, c"window expression needs exactly one function")
	if (orm_cexpr(c, e.args[0]) == 0): return 0
	orm_csql(c, c" OVER (")
	if (e.partition_by.length > 0):
		orm_csql(c, c"PARTITION BY ")
		if (orm_cexprs(c, e.partition_by) == 0): return 0
	if (e.order_by.length > 0):
		if (e.partition_by.length > 0): orm_csql(c, c" ")
		orm_csql(c, c"ORDER BY ")
		if (orm_corder_list(c, e.order_by) == 0): return 0
	orm_csql(c, c")")
	return 1


int orm_cparen_subquery(orm_cctx* c, orm_expr* e, char* open):
	orm_csql(c, open)
	if (orm_csubquery(c, e.subquery, e.kind == ORM_E_EXISTS) == 0): return 0
	orm_csql(c, c")")
	return 1


int orm_cexpr(orm_cctx* c, orm_expr* e):
	if (e == 0): return orm_cfail(c, c"missing expression")
	int k = e.kind
	if (k == ORM_E_FIELD): return orm_cfield_ref(c, e.path)
	if (k == ORM_E_VALUE):
		sql_builder_bind(c.b, e.value)
		return 1
	if (k == ORM_E_NULL):
		orm_csql(c, c"NULL")
		return 1
	if (k == ORM_E_INT):
		if (orm_cvalid_int(e.value) == 0): return orm_cfail(c, c"ORM_E_INT value is not an integer")
		orm_csql(c, e.value)
		return 1
	if (k == ORM_E_STAR):
		orm_csql(c, c"*")
		return 1
	if (k == ORM_E_FUNC): return orm_cfunc(c, e)
	if (k == ORM_E_AGG): return orm_cagg(c, e)
	if (k == ORM_E_CASE): return orm_ccase(c, e)
	if (k == ORM_E_SUBQUERY): return orm_cparen_subquery(c, e, c"(")
	if (k == ORM_E_EXISTS): return orm_cparen_subquery(c, e, c"EXISTS(")
	if (k == ORM_E_RAW): return orm_craw(c, e)
	if (k == ORM_E_OUTER_REF): return orm_couter_ref(c, e)
	if (k == ORM_E_BINOP): return orm_cbinop(c, e)
	if (k == ORM_E_WINDOW): return orm_cwindow(c, e)
	return orm_cfail(c, c"unknown expression kind")


# 1 when e aggregates over the group (aggregates inside windows and
# subqueries do not count).
int orm_cagg_in(orm_cctx* c, orm_expr* e, int depth):
	if (e == 0 || depth > 32): return 0
	int k = e.kind
	if (k == ORM_E_AGG): return 1
	if (k == ORM_E_WINDOW || k == ORM_E_SUBQUERY || k == ORM_E_EXISTS): return 0
	if (k == ORM_E_FIELD): return orm_cagg_in(c, orm_cnamed(c, e.path), depth + 1)
	for orm_expr* a in e.args:
		if (orm_cagg_in(c, a, depth + 1)): return 1
	for void* wv in e.whens:
		orm_when* w = cast(orm_when*, wv)
		if (orm_cagg_in(c, w.then, depth + 1)): return 1
	return orm_cagg_in(c, e.else_expr, depth + 1)


# Result kind of an expression (ORM_*), 0 when unknown.
int orm_ckind(orm_cctx* c, orm_expr* e, int depth):
	if (e == 0 || depth > 32): return 0
	if (e.output_kind != 0): return e.output_kind
	if (e.kind == ORM_E_FIELD):
		orm_expr* named = orm_cnamed(c, e.path)
		if (named != 0): return orm_ckind(c, named, depth + 1)
		orm_cref ref
		if (c.no_fields || orm_cresolve(c, e.path, &ref) == 0): return 0
		return ref.field.kind
	if (e.kind == ORM_E_INT): return ORM_INT
	if (e.kind == ORM_E_AGG && e.name != 0):
		if (strcmp(e.name, c"COUNT") == 0): return ORM_INT
		if (strcmp(e.name, c"AVG") == 0): return ORM_FLOAT
		if (e.args.length > 0): return orm_ckind(c, e.args[0], depth + 1)
	if (e.kind == ORM_E_WINDOW && e.args.length == 1): return orm_ckind(c, e.args[0], depth + 1)
	return 0


# Right-hand side of a comparison. Values are bound as text; SQLite only
# converts text to numbers through a column's affinity, so when the left
# side is a computed numeric expression (an aggregate, a window, a binop
# with output_kind) the value is cast to match.
int orm_crhs(orm_cctx* c, orm_expr* lhs, orm_expr* rhs):
	int cast_it = c.d.id == ORM_DIALECT_SQLITE && rhs != 0 && rhs.kind == ORM_E_VALUE && rhs.value != 0
	if (cast_it && lhs != 0 && lhs.kind == ORM_E_FIELD && orm_cnamed(c, lhs.path) == 0): cast_it = 0
	char* type = 0
	if (cast_it):
		int k = orm_ckind(c, lhs, 0)
		if (k == ORM_INT || k == ORM_BIGINT || k == ORM_BOOL || k == ORM_FK): type = c" AS INTEGER)"
		if (k == ORM_DECIMAL || k == ORM_FLOAT): type = c" AS NUMERIC)"
	if (type == 0): return orm_cexpr(c, rhs)
	orm_csql(c, c"CAST(")
	sql_builder_bind(c.b, rhs.value)
	orm_csql(c, type)
	return 1


# ---------------------------------------------------------------------------
# WHERE

int orm_cis_null_expr(orm_expr* e):
	return e == 0 || e.kind == ORM_E_NULL || (e.kind == ORM_E_VALUE && e.value == 0)


int orm_ctruth(orm_expr* e):
	if (e == 0 || e.value == 0): return 1
	char* v = e.value
	if (v[0] == 0 || strcmp(v, c"0") == 0 || strcmp(v, c"f") == 0): return 0
	if (strcmp(v, c"false") == 0 || strcmp(v, c"False") == 0): return 0
	return 1


int orm_cis_text_lookup(char* op):
	if (strcmp(op, c"iexact") == 0 || strcmp(op, c"regex") == 0): return 1
	if (strcmp(op, c"contains") == 0 || strcmp(op, c"icontains") == 0): return 1
	if (strcmp(op, c"startswith") == 0 || strcmp(op, c"istartswith") == 0): return 1
	if (strcmp(op, c"endswith") == 0 || strcmp(op, c"iendswith") == 0): return 1
	return 0


char* orm_ccompare_op(char* op):
	if (strcmp(op, c"lt") == 0): return c" < "
	if (strcmp(op, c"lte") == 0): return c" <= "
	if (strcmp(op, c"gt") == 0): return c" > "
	if (strcmp(op, c"gte") == 0): return c" >= "
	return 0


# Pattern for LIKE (escape % _ \ with \) or, for SQLite's case-sensitive
# lookups, GLOB (wrap * ? [ in brackets).
char* orm_cpattern_text(char* v, int lead, int trail, int glob):
	string_builder* s = string_new()
	int any = '%'
	if (glob): any = '*'
	if (lead): string_append_char(s, any)
	for i in range(strlen(v)):
		char ch = v[i]
		if (glob && (ch == '*' || ch == '?' || ch == '[')):
			string_append_char(s, '[')
			string_append_char(s, ch)
			string_append_char(s, ']')
			continue
		if (glob == 0 && (ch == '%' || ch == '_' || ch == '\\')): string_append_char(s, '\\')
		string_append_char(s, ch)
	if (trail): string_append_char(s, any)
	char* text = strclone(s.data)
	string_free(s)
	return text


int orm_cpattern(orm_cctx* c, orm_where* w, char* op):
	orm_expr* rhs = w.rhs
	if (rhs == 0 || rhs.kind != ORM_E_VALUE || rhs.value == 0):
		return orm_cfail(c, c"lookup '", op, c"' needs a text value")
	int ci = op[0] == 'i'
	char* base = op
	if (ci): base = &op[1]
	int lead = strcmp(base, c"contains") == 0 || strcmp(base, c"endswith") == 0
	int trail = strcmp(base, c"contains") == 0 || strcmp(base, c"startswith") == 0
	int glob = ci == 0 && c.d.id == ORM_DIALECT_SQLITE
	int lower = ci && c.d.supports_ilike == 0
	if (lower): orm_csql(c, c"LOWER(")
	if (orm_cexpr(c, w.lhs) == 0): return 0
	if (lower): orm_csql(c, c") LIKE LOWER(")
	else if (glob): orm_csql(c, c" GLOB ")
	else if (ci): orm_csql(c, c" ILIKE ")
	else: orm_csql(c, c" LIKE ")
	char* pattern = orm_cpattern_text(rhs.value, lead, trail, glob)
	sql_builder_bind(c.b, pattern)
	free(pattern)
	if (lower): orm_csql(c, c")")
	if (glob == 0): orm_csql(c, c" ESCAPE '\\'")
	return 1


int orm_cin(orm_cctx* c, orm_where* w):
	if (w.rhs != 0 && w.rhs.kind == ORM_E_SUBQUERY):
		if (orm_cexpr(c, w.lhs) == 0): return 0
		orm_csql(c, c" IN ")
		return orm_cexpr(c, w.rhs)
	int n = 0
	for orm_expr* v in w.rhs_list:
		if (orm_cis_null_expr(v) == 0): n = n + 1
	if (n == 0):
		orm_csql(c, c"1 = 0")
		return 1
	if (orm_cexpr(c, w.lhs) == 0): return 0
	orm_csql(c, c" IN (")
	int i = 0
	for orm_expr* v in w.rhs_list:
		if (orm_cis_null_expr(v)): continue
		orm_csep(c, i, c", ")
		if (orm_crhs(c, w.lhs, v) == 0): return 0
		i = i + 1
	orm_csql(c, c")")
	return 1


int orm_crange(orm_cctx* c, orm_where* w):
	if (w.rhs_list.length != 2): return orm_cfail(c, c"lookup 'range' needs exactly two values")
	if (orm_cexpr(c, w.lhs) == 0): return 0
	orm_csql(c, c" BETWEEN ")
	if (orm_crhs(c, w.lhs, w.rhs_list[0]) == 0): return 0
	orm_csql(c, c" AND ")
	return orm_crhs(c, w.lhs, w.rhs_list[1])


# lhs <op> rhs, with a NULL rhs turned into IS [NOT] NULL for exact / ne.
int orm_cbinary(orm_cctx* c, orm_where* w, char* op, char* sql_op):
	int null_rhs = orm_cis_null_expr(w.rhs)
	int is_eq = strcmp(op, c"exact") == 0
	int is_ne = strcmp(op, c"ne") == 0
	if (null_rhs && is_eq == 0 && is_ne == 0): return orm_cfail(c, c"lookup '", op, c"' needs a non-null value")
	if (orm_cexpr(c, w.lhs) == 0): return 0
	if (null_rhs && is_eq):
		orm_csql(c, c" IS NULL")
		return 1
	if (null_rhs):
		orm_csql(c, c" IS NOT NULL")
		return 1
	orm_csql(c, sql_op)
	return orm_crhs(c, w.lhs, w.rhs)


int orm_ciexact(orm_cctx* c, orm_where* w):
	if (orm_cis_null_expr(w.rhs)): return orm_cbinary(c, w, c"exact", c" = ")
	orm_csql(c, c"LOWER(")
	if (orm_cexpr(c, w.lhs) == 0): return 0
	orm_csql(c, c") = LOWER(")
	if (orm_cexpr(c, w.rhs) == 0): return 0
	orm_csql(c, c")")
	return 1


int orm_cisnull(orm_cctx* c, orm_where* w):
	if (orm_cexpr(c, w.lhs) == 0): return 0
	if (orm_ctruth(w.rhs)): orm_csql(c, c" IS NULL")
	else: orm_csql(c, c" IS NOT NULL")
	return 1


int orm_cregex(orm_cctx* c, orm_where* w):
	if (c.d.id != ORM_DIALECT_POSTGRES): return orm_cfail(c, c"lookup 'regex' is not supported on ", c.d.name)
	if (orm_cis_null_expr(w.rhs)): return orm_cfail(c, c"lookup 'regex' needs a non-null value")
	if (orm_cexpr(c, w.lhs) == 0): return 0
	orm_csql(c, c" ~ ")
	return orm_cexpr(c, w.rhs)


# The field a lookup's left side names, or 0 for other expressions.
orm_field_desc* orm_clookup_field(orm_cctx* c, orm_expr* lhs, orm_cref* ref):
	if (lhs == 0 || lhs.kind != ORM_E_FIELD || orm_cnamed(c, lhs.path) != 0): return 0
	if (c.no_fields || orm_cresolve(c, lhs.path, ref) == 0): return 0
	return ref.field


int orm_clookup(orm_cctx* c, orm_where* w):
	char* op = w.lookup
	if (op == 0): op = c"exact"
	if (w.lhs == 0): return orm_cfail(c, c"lookup '", op, c"' without a left-hand side")
	orm_cref ref
	orm_field_desc* f = orm_clookup_field(c, w.lhs, &ref)
	if (orm_cok(c) == 0): return 0
	if (f != 0 && orm_cis_text_lookup(op) && orm_field_is_text_backed(f) == 0):
		return orm_cfail(c, c"lookup '", op, c"' is not valid for field '", f.name, c"' of model ", ref.model.name)
	if (strcmp(op, c"exact") == 0): return orm_cbinary(c, w, op, c" = ")
	if (strcmp(op, c"ne") == 0): return orm_cbinary(c, w, op, c" <> ")
	char* cmp = orm_ccompare_op(op)
	if (cmp != 0): return orm_cbinary(c, w, op, cmp)
	if (strcmp(op, c"iexact") == 0): return orm_ciexact(c, w)
	if (strcmp(op, c"in") == 0): return orm_cin(c, w)
	if (strcmp(op, c"range") == 0): return orm_crange(c, w)
	if (strcmp(op, c"isnull") == 0): return orm_cisnull(c, w)
	if (strcmp(op, c"regex") == 0): return orm_cregex(c, w)
	if (orm_cis_text_lookup(op)): return orm_cpattern(c, w, op)
	return orm_cfail(c, c"unknown lookup '", op, c"'")


int orm_cwhere_join(orm_cctx* c, list[orm_where*] children, char* sep):
	for i in range(children.length):
		orm_csep(c, i, sep)
		orm_where* ch = children[i]
		int paren = ch != 0 && (ch.kind == ORM_W_AND || ch.kind == ORM_W_OR)
		if (paren): orm_csql(c, c"(")
		if (orm_cwhere(c, ch) == 0): return 0
		if (paren): orm_csql(c, c")")
	return 1


# Django's exclude() semantics: NOT (col = x) must keep rows where col is
# NULL, so a negated comparison on a nullable column adds IS NOT NULL.
int orm_cneeds_null_guard(orm_cctx* c, orm_where* w, orm_cref* ref):
	if (w == 0 || w.kind != ORM_W_LOOKUP): return 0
	char* op = w.lookup
	if (op == 0): op = c"exact"
	if (strcmp(op, c"isnull") == 0 || strcmp(op, c"in") == 0): return 0
	if (orm_cis_null_expr(w.rhs) && strcmp(op, c"range") != 0): return 0
	orm_field_desc* f = orm_clookup_field(c, w.lhs, ref)
	return f != 0 && ref.nullable


int orm_cnot(orm_cctx* c, orm_where* w):
	if (w.children.length == 0): return orm_cfail(c, c"NOT without a condition")
	orm_csql(c, c"NOT (")
	if (orm_cwhere_join(c, w.children, c" AND ") == 0): return 0
	orm_cref ref
	if (w.children.length == 1 && orm_cneeds_null_guard(c, w.children[0], &ref)):
		orm_csql(c, c" AND ")
		orm_ccol(c, ref.alias, ref.field.column)
		orm_csql(c, c" IS NOT NULL")
	orm_csql(c, c")")
	return orm_cok(c)


int orm_cwhere(orm_cctx* c, orm_where* w):
	if (w == 0): return orm_cfail(c, c"missing condition")
	int k = w.kind
	if (k == ORM_W_AND || k == ORM_W_OR):
		if (w.children.length == 0):
			if (k == ORM_W_AND): orm_csql(c, c"1 = 1")
			else: orm_csql(c, c"1 = 0")
			return 1
		if (k == ORM_W_AND): return orm_cwhere_join(c, w.children, c" AND ")
		return orm_cwhere_join(c, w.children, c" OR ")
	if (k == ORM_W_NOT): return orm_cnot(c, w)
	if (k == ORM_W_LOOKUP): return orm_clookup(c, w)
	if (k == ORM_W_EXPR): return orm_cexpr(c, w.lhs)
	if (k == ORM_W_TRUE):
		orm_csql(c, c"1 = 1")
		return 1
	if (k == ORM_W_FALSE):
		orm_csql(c, c"1 = 0")
		return 1
	return orm_cfail(c, c"unknown condition kind")


# ---------------------------------------------------------------------------
# ORDER BY

# A bare field path naming an annotation / values() entry orders by the
# output column; a leading "-" is accepted as an alternative to descending.
int orm_corder_expr(orm_cctx* c, orm_expr* x, char* path):
	if (path == 0): return orm_cexpr(c, x)
	if (orm_cnamed(c, path) != 0):
		orm_cident(c, path)
		return 1
	return orm_cfield_ref(c, path)


int orm_corder_one(orm_cctx* c, orm_order* o):
	if (o == 0 || o.expr == 0): return orm_cfail(c, c"ORDER BY entry without an expression")
	orm_expr* x = o.expr
	int desc = o.descending
	char* path = 0
	if (x.kind == ORM_E_FIELD):
		path = x.path
		if (path != 0 && path[0] == '-'):
			path = &path[1]
			desc = desc == 0
	int emulate = o.nulls != ORM_NULLS_DEFAULT && c.d.supports_nulls_order == 0
	if (emulate):
		orm_csql(c, c"CASE WHEN ")
		if (orm_corder_expr(c, x, path) == 0): return 0
		orm_csql(c, c" IS NULL THEN 1 ELSE 0 END")
		if (o.nulls == ORM_NULLS_FIRST): orm_csql(c, c" DESC")
		orm_csql(c, c", ")
	if (orm_corder_expr(c, x, path) == 0): return 0
	if (desc): orm_csql(c, c" DESC")
	if (emulate == 0 && o.nulls == ORM_NULLS_FIRST): orm_csql(c, c" NULLS FIRST")
	if (emulate == 0 && o.nulls == ORM_NULLS_LAST): orm_csql(c, c" NULLS LAST")
	return 1


int orm_corder_list(orm_cctx* c, list[void*] orders):
	for i in range(orders.length):
		orm_csep(c, i, c", ")
		if (orm_corder_one(c, cast(orm_order*, orders[i])) == 0): return 0
	return 1


# ---------------------------------------------------------------------------
# SELECT

int orm_cin_list(list[char*] l, char* s):
	for char* x in l:
		if (strcmp(x, s) == 0): return 1
	return 0


void orm_cmodel_columns(orm_cctx* c, orm_model_desc* m, char* alias, char* rel_path, list[char*] only):
	for orm_field_desc* f in m.fields:
		if (orm_field_has_column(f) == 0 || orm_cdeprecated(f)): continue
		int keep = only == 0 || only.length == 0 || (f.flags & ORM_F_PK) != 0 || orm_cin_list(only, f.name)
		if (keep == 0): continue
		orm_csep(c, c.ncols, c", ")
		orm_ccol(c, alias, f.column)
		orm_cgroup_add(c, alias, f.column)
		orm_cmap(c, m, f, rel_path, f.name)
		c.ncols = c.ncols + 1


int orm_cselect_related(orm_cctx* c, char* path):
	list[char*] parts = orm_path_split(path)
	orm_model_desc* m = c.q.model
	char* alias = c.alias
	int nullable = 0
	string_builder* key = string_new()
	int ok = 1
	for char* part in parts:
		orm_field_desc* f = orm_cfield(m, part)
		if (f == 0):
			ok = orm_cfail(c, c"select_related: unknown field '", part, c"' on model ", m.name)
			break
		if (f.kind != ORM_FK):
			ok = orm_cfail(c, c"select_related: '", part, c"' on model ", m.name, c" is not a foreign key")
			break
		if (key.length > 0): string_append(key, c"__")
		string_append(key, part)
		char* k = orm_cintern(key.data)
		alias = orm_chop(c, f, m, alias, k, &nullable)
		if (alias == 0):
			ok = 0
			break
		m = orm_field_target(f)
		if (orm_cin_list(c.related_done, k) == 0):
			c.related_done.push(k)
			orm_cmodel_columns(c, m, alias, k, 0)
	string_free(key)
	for char* p in parts: free(p)
	parts.free()
	return ok


char* orm_cselect_name(orm_query* q, int i):
	if (i < q.select_names.length && q.select_names[i] != 0): return q.select_names[i]
	orm_expr* e = q.select[i]
	if (e.kind == ORM_E_FIELD && e.path != 0): return e.path
	return c"value"


# One computed output column: expression AS "name", tracked for the
# implicit GROUP BY and the column map.
int orm_cselect_item(orm_cctx* c, orm_expr* e, char* name):
	orm_csep(c, c.ncols, c", ")
	if (orm_cexpr(c, e) == 0): return 0
	int plain = e.kind == ORM_E_FIELD && e.path != 0 && strcmp(e.path, name) == 0 && orm_cnamed(c, name) == 0
	if (plain == 0):
		orm_csql(c, c" AS ")
		orm_cident(c, name)
	if (orm_cagg_in(c, e, 0)): c.has_agg = 1
	else:
		orm_cref ref
		if (e.kind == ORM_E_FIELD && orm_cnamed(c, e.path) == 0 && orm_cresolve(c, e.path, &ref)):
			orm_cgroup_add(c, ref.alias, ref.field.column)
		else:
			orm_cgroup_add(c, 0, 0)
	orm_cmap(c, 0, 0, c"", name)
	c.ncols = c.ncols + 1
	return orm_cok(c)


int orm_cselect_list(orm_cctx* c):
	orm_query* q = c.q
	if (c.exists_mode):
		orm_csql(c, c"1")
		c.ncols = 1
		return 1
	if (q.select.length > 0):
		for i in range(q.select.length):
			if (orm_cselect_item(c, q.select[i], orm_cselect_name(q, i)) == 0): return 0
	else:
		orm_cmodel_columns(c, q.model, c.alias, c"", q.only_fields)
		for char* path in q.select_related:
			if (orm_cselect_related(c, path) == 0): return 0
	for orm_annotation* a in q.annotations:
		if (orm_cselect_item(c, a.expr, a.name) == 0): return 0
	if (c.ncols == 0): return orm_cfail(c, c"model ", q.model.name, c" has no selectable columns")
	return 1


void orm_cgroup_by(orm_cctx* c):
	orm_query* q = c.q
	if (q.group_by.length > 0):
		orm_csql(c, c" GROUP BY ")
		orm_cexprs(c, q.group_by)
		return
	if (c.has_agg == 0): return
	int n = 0
	for orm_cgroup* g in c.groups:
		orm_csep(c, n, c", ")
		if (n == 0): orm_csql(c, c" GROUP BY ")
		if (g.column != 0): orm_ccol(c, g.alias, g.column)
		else: orm_cint(c, g.ordinal + 1)
		n = n + 1


void orm_climit(orm_cctx* c):
	orm_query* q = c.q
	if (q.limit >= 0):
		orm_csql(c, c" LIMIT ")
		orm_cint(c, q.limit)
	if (q.offset > 0):
		if (q.limit < 0 && c.d.id == ORM_DIALECT_SQLITE): orm_csql(c, c" LIMIT -1")
		orm_csql(c, c" OFFSET ")
		orm_cint(c, q.offset)


int orm_cfor_update(orm_cctx* c):
	orm_query* q = c.q
	if (q.for_update == 0): return 1
	if (c.d.supports_for_update == 0): return orm_cfail(c, c"FOR UPDATE is not supported on ", c.d.name)
	if (q.skip_locked && q.nowait): return orm_cfail(c, c"FOR UPDATE cannot combine SKIP LOCKED and NOWAIT")
	orm_csql(c, c" FOR UPDATE")
	# The nullable side of an outer join cannot be locked: lock the base row.
	if (orm_chas_left_join(c)):
		orm_csql(c, c" OF ")
		orm_cident(c, c.alias)
	if (q.skip_locked): orm_csql(c, c" SKIP LOCKED")
	if (q.nowait): orm_csql(c, c" NOWAIT")
	return 1


int orm_cselect(orm_cctx* c):
	orm_query* q = c.q
	c.ncols = 0
	c.has_agg = 0
	orm_cgroups_clear(c)
	c.related_done.free()
	c.related_done = new list[char*]
	orm_csql(c, c"SELECT ")
	if (q.distinct): orm_csql(c, c"DISTINCT ")
	if (orm_cselect_list(c) == 0): return 0
	orm_csql(c, c" FROM ")
	orm_cident(c, q.model.table)
	orm_csql(c, c" AS ")
	orm_cident(c, c.alias)
	orm_cjoins(c)
	if (q.where != 0):
		orm_csql(c, c" WHERE ")
		if (orm_cwhere(c, q.where) == 0): return 0
	orm_cgroup_by(c)
	if (q.having != 0):
		orm_csql(c, c" HAVING ")
		if (orm_cwhere(c, q.having) == 0): return 0
	if (q.order.length > 0 && c.exists_mode == 0):
		orm_csql(c, c" ORDER BY ")
		for i in range(q.order.length):
			orm_csep(c, i, c", ")
			if (orm_corder_one(c, q.order[i]) == 0): return 0
	orm_climit(c)
	if (orm_cfor_update(c) == 0): return 0
	return orm_cok(c)


# Pass 1 discovers joins into a scratch builder; pass 2 writes target.
int orm_crun_select(orm_cctx* c, sql_builder* target):
	sql_builder* scratch = sql_builder_new(target.style)
	c.b = scratch
	c.final = 0
	int ok = orm_cselect(c)
	sql_builder_free(scratch)
	c.b = target
	if (ok == 0 || orm_cok(c) == 0): return 0
	c.final = 1
	return orm_cselect(c)


int orm_csubquery(orm_cctx* c, void* subquery, int exists):
	orm_query* sq = cast(orm_query*, subquery)
	if (sq == 0 || sq.model == 0): return orm_cfail(c, c"subquery without a query or model")
	if (sq.kind != ORM_Q_SELECT): return orm_cfail(c, c"subquery must be a SELECT")
	orm_cctx* s = orm_cctx_new(sq, c.d, c, c.root)
	s.exists_mode = exists
	int ok = orm_crun_select(s, c.b)
	if (ok && exists == 0 && s.ncols != 1):
		ok = orm_cfail(c, c"subquery must select exactly one column")
	orm_cctx_free(s)
	return ok


# ---------------------------------------------------------------------------
# UPDATE / DELETE / INSERT

void orm_cexpr_free(orm_expr* e):
	e.args.free()
	e.whens.free()
	e.partition_by.free()
	e.order_by.free()
	free(cast(void*, e))


void orm_cquery_free(orm_query* q):
	q.annotations.free()
	q.select.free()
	q.select_names.free()
	q.select_related.free()
	q.prefetch.free()
	q.order.free()
	q.group_by.free()
	q.assignments.free()
	q.insert_rows.free()
	q.returning.free()
	q.conflict_fields.free()
	q.update_fields.free()
	q.only_fields.free()
	free(cast(void*, q))


# The field a write names, checked to have a writable column.
orm_field_desc* orm_cwrite_field(orm_cctx* c, char* name, char* what):
	orm_model_desc* m = c.q.model
	if (name == 0):
		orm_cfail(c, what, c": missing field name")
		return 0
	orm_field_desc* f = orm_cfield(m, name)
	if (f == 0):
		orm_cfail(c, what, c": unknown field '", name, c"' on model ", m.name)
		return 0
	if (orm_field_has_column(f) == 0 || orm_cdeprecated(f)):
		orm_cfail(c, what, c": field '", name, c"' on model ", m.name, c" has no writable column")
		return 0
	return f


# Probes the WHERE with aliases; returns the number of joins it needs,
# or -1 on error.
int orm_cwhere_joins(orm_cctx* c):
	orm_cctx* p = orm_cctx_new(c.q, c.d, 0, c.root)
	p.b = sql_builder_new(c.d.bind_style)
	int ok = orm_cwhere(p, c.q.where)
	int n = p.joins.length
	sql_builder_free(p.b)
	orm_cctx_free(p)
	if (ok == 0): return -1
	return n


# WHERE of an UPDATE/DELETE: unqualified columns when the condition stays
# on the table, else "pk IN (SELECT t0.pk FROM ... joins ... WHERE ...)".
int orm_cdml_where(orm_cctx* c):
	orm_query* q = c.q
	if (q.where == 0): return 1
	int joins = orm_cwhere_joins(c)
	if (joins < 0): return 0
	orm_csql(c, c" WHERE ")
	if (joins == 0): return orm_cwhere(c, q.where)
	orm_field_desc* pk = orm_model_pk(q.model)
	if (pk == 0): return orm_cfail(c, c"model ", q.model.name, c" has no primary key")
	orm_query* sq = orm_query_new(ORM_Q_SELECT, q.model)
	sq.where = q.where
	orm_expr* e = orm_expr_new(ORM_E_FIELD)
	e.path = pk.name
	sq.select.push(e)
	orm_cident(c, pk.column)
	orm_csql(c, c" IN (")
	orm_cctx* s = orm_cctx_new(sq, c.d, 0, c.root)
	int ok = orm_crun_select(s, c.b)
	orm_csql(c, c")")
	orm_cctx_free(s)
	orm_cexpr_free(e)
	orm_cquery_free(sq)
	return ok


int orm_creturning(orm_cctx* c):
	orm_query* q = c.q
	if (q.returning.length == 0): return 1
	if (c.d.supports_returning == 0): return orm_cfail(c, c"RETURNING is not supported on ", c.d.name)
	orm_csql(c, c" RETURNING ")
	for i in range(q.returning.length):
		orm_field_desc* f = orm_cwrite_field(c, q.returning[i], c"RETURNING")
		if (f == 0): return 0
		orm_csep(c, i, c", ")
		orm_cident(c, f.column)
		orm_cmap(c, q.model, f, c"", f.name)
	return 1


int orm_cno_slice(orm_cctx* c, char* what):
	orm_query* q = c.q
	if (q.limit >= 0 || q.offset > 0): return orm_cfail(c, what, c" cannot use LIMIT/OFFSET")
	return 1


int orm_cupdate(orm_cctx* c):
	orm_query* q = c.q
	if (orm_cno_slice(c, c"UPDATE") == 0): return 0
	if (q.assignments.length == 0): return orm_cfail(c, c"UPDATE needs at least one assignment")
	orm_csql(c, c"UPDATE ")
	orm_cident(c, q.model.table)
	orm_csql(c, c" SET ")
	for i in range(q.assignments.length):
		orm_assignment* s = q.assignments[i]
		orm_field_desc* f = orm_cwrite_field(c, s.field, c"UPDATE")
		if (f == 0): return 0
		orm_csep(c, i, c", ")
		orm_cident(c, f.column)
		orm_csql(c, c" = ")
		if (orm_cexpr(c, s.value) == 0): return 0
	if (orm_cdml_where(c) == 0): return 0
	return orm_creturning(c)


int orm_cdelete(orm_cctx* c):
	if (orm_cno_slice(c, c"DELETE") == 0): return 0
	orm_csql(c, c"DELETE FROM ")
	orm_cident(c, c.q.model.table)
	if (orm_cdml_where(c) == 0): return 0
	return orm_creturning(c)


orm_expr* orm_crow_value(list[orm_assignment*] row, char* field):
	for orm_assignment* s in row:
		if (s.field != 0 && strcmp(s.field, field) == 0): return s.value
	return 0


int orm_cinsert_columns(orm_cctx* c, list[orm_assignment*] first):
	orm_csql(c, c" (")
	for i in range(first.length):
		orm_field_desc* f = orm_cwrite_field(c, first[i].field, c"INSERT")
		if (f == 0): return 0
		if (orm_crow_value(first, first[i].field) != first[i].value):
			return orm_cfail(c, c"INSERT: field '", first[i].field, c"' is set twice")
		orm_csep(c, i, c", ")
		orm_cident(c, f.column)
	orm_csql(c, c")")
	return 1


int orm_cinsert_row(orm_cctx* c, list[orm_assignment*] first, list[orm_assignment*] row):
	if (row.length != first.length): return orm_cfail(c, c"INSERT rows must set the same fields")
	orm_csql(c, c"(")
	for i in range(first.length):
		orm_expr* v = orm_crow_value(row, first[i].field)
		if (v == 0): return orm_cfail(c, c"INSERT row has no value for field '", first[i].field, c"'")
		orm_csep(c, i, c", ")
		if (orm_cexpr(c, v) == 0): return 0
	orm_csql(c, c")")
	return 1


int orm_cconflict(orm_cctx* c):
	orm_query* q = c.q
	if (q.conflict_action == ORM_CONFLICT_NONE): return 1
	orm_csql(c, c" ON CONFLICT")
	if (q.conflict_fields.length > 0):
		orm_csql(c, c" (")
		for i in range(q.conflict_fields.length):
			orm_field_desc* f = orm_cwrite_field(c, q.conflict_fields[i], c"ON CONFLICT")
			if (f == 0): return 0
			orm_csep(c, i, c", ")
			orm_cident(c, f.column)
		orm_csql(c, c")")
	if (q.conflict_action == ORM_CONFLICT_NOTHING):
		orm_csql(c, c" DO NOTHING")
		return 1
	if (q.conflict_fields.length == 0): return orm_cfail(c, c"ON CONFLICT DO UPDATE needs conflict fields")
	if (q.update_fields.length == 0): return orm_cfail(c, c"ON CONFLICT DO UPDATE needs update fields")
	orm_csql(c, c" DO UPDATE SET ")
	for i in range(q.update_fields.length):
		orm_field_desc* f = orm_cwrite_field(c, q.update_fields[i], c"ON CONFLICT")
		if (f == 0): return 0
		orm_csep(c, i, c", ")
		orm_cident(c, f.column)
		orm_csql(c, c" = excluded.")
		orm_cident(c, f.column)
	return 1


int orm_cinsert_rows(orm_cctx* c, list[list[orm_assignment*]] rows):
	list[orm_assignment*] first = rows[0]
	if (first.length == 0):
		if (rows.length > 1): return orm_cfail(c, c"multi-row INSERT needs at least one field")
		orm_csql(c, c" DEFAULT VALUES")
		return 1
	if (orm_cinsert_columns(c, first) == 0): return 0
	orm_csql(c, c" VALUES ")
	for i in range(rows.length):
		orm_csep(c, i, c", ")
		if (orm_cinsert_row(c, first, rows[i]) == 0): return 0
	return 1


int orm_cinsert(orm_cctx* c):
	orm_query* q = c.q
	c.no_fields = 1
	list[list[orm_assignment*]] rows = new list[list[orm_assignment*]]
	if (q.insert_rows.length > 0):
		for list[orm_assignment*] r in q.insert_rows: rows.push(r)
	else:
		rows.push(q.assignments)
	orm_csql(c, c"INSERT INTO ")
	orm_cident(c, q.model.table)
	int ok = orm_cinsert_rows(c, rows)
	rows.free()
	if (ok == 0): return 0
	if (orm_cconflict(c) == 0): return 0
	return orm_creturning(c)


# ---------------------------------------------------------------------------
# Entry points

# C4: fills out.sql (and out.columns for SELECT / RETURNING) and returns 1,
# or returns 0 with out.error set (an owned copy).
int orm_compile(orm_query* q, orm_dialect* d, orm_compiled* out):
	if (out == 0): return 0
	if (q == 0 || d == 0 || q.model == 0):
		out.error = strclone(c"orm_compile: missing query, model or dialect")
		return 0
	if (out.sql == 0): out.sql = sql_builder_new(d.bind_style)
	if (out.columns == 0): out.columns = new list[orm_column_map*]
	orm_cctx* c = orm_cctx_new(q, d, 0, 0)
	c.out = out
	c.b = out.sql
	int ok = 0
	if (q.kind == ORM_Q_SELECT):
		ok = orm_crun_select(c, out.sql)
	else:
		c.final = 1
		c.alias = 0
		if (q.kind == ORM_Q_UPDATE): ok = orm_cupdate(c)
		else if (q.kind == ORM_Q_DELETE): ok = orm_cdelete(c)
		else if (q.kind == ORM_Q_INSERT): ok = orm_cinsert(c)
		else: ok = orm_cfail(c, c"orm_compile: unknown query kind")
	if (c.error != 0):
		out.error = c.error
		ok = 0
	orm_cctx_free(c)
	return ok


# The compiled statement text (borrowed from out.sql).
char* orm_compiled_sql(orm_compiled* c):
	if (c == 0 || c.sql == 0): return c""
	return c.sql.text.data


# Bound value i (0-based; 0 pointer for SQL NULL or out of range).
char* orm_compiled_param(orm_compiled* c, int i):
	if (c == 0 || c.sql == 0 || i < 0 || i >= c.sql.parameters.length): return 0
	return c.sql.parameters[i]


int orm_compiled_param_count(orm_compiled* c):
	if (c == 0 || c.sql == 0): return 0
	return c.sql.parameters.length
