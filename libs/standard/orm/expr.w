# w-orm where/expression builders (unit U1.3, docs/projects/orm/u1_3.md).
#
# Thin constructors over the C3 nodes in contract.w: Django's Q (q_*),
# F (f), Value (val), aggregates (agg_*), Case/When, functions and window
# expressions. Every builder returns a new node and never mutates its
# arguments, so nodes can be shared between cloned querysets. String
# arguments are borrowed: they must outlive the queryset that uses them
# (literals and row fields do). e_subquery / e_exists, which take a
# queryset, live in query.w.
import libs.standard.orm.contract


# Lookups the compiler understands (contract.w C3), so q("a__b__gt", v)
# can tell a trailing lookup from a relation path.
int orm_is_lookup(char* name):
	if (name == 0): return 0
	if (strcmp(name, c"exact") == 0 || strcmp(name, c"iexact") == 0 || strcmp(name, c"ne") == 0): return 1
	if (strcmp(name, c"lt") == 0 || strcmp(name, c"lte") == 0 || strcmp(name, c"gt") == 0 || strcmp(name, c"gte") == 0): return 1
	if (strcmp(name, c"in") == 0 || strcmp(name, c"range") == 0 || strcmp(name, c"isnull") == 0): return 1
	if (strcmp(name, c"contains") == 0 || strcmp(name, c"icontains") == 0): return 1
	if (strcmp(name, c"startswith") == 0 || strcmp(name, c"istartswith") == 0): return 1
	if (strcmp(name, c"endswith") == 0 || strcmp(name, c"iendswith") == 0): return 1
	return strcmp(name, c"regex") == 0


# ---------------------------------------------------------------------------
# Expressions

# F(path): a field reference, "author__name" across select_related joins.
orm_expr* f(char* path):
	orm_expr* e = orm_expr_new(ORM_E_FIELD)
	e.path = path
	return e


# Value(text): bound as a parameter. A null pointer is SQL NULL.
orm_expr* val(char* text):
	if (text == 0): return orm_expr_new(ORM_E_NULL)
	orm_expr* e = orm_expr_new(ORM_E_VALUE)
	e.value = text
	return e


# An integer literal, inlined (ints only, so it is injection-safe).
orm_expr* val_int(int v):
	orm_expr* e = orm_expr_new(ORM_E_INT)
	e.value = itoa(v)
	e.output_kind = ORM_INT
	return e


orm_expr* e_null():
	return orm_expr_new(ORM_E_NULL)


orm_expr* e_star():
	return orm_expr_new(ORM_E_STAR)


list[orm_expr*] orm_expr_list_copy(list[orm_expr*] items):
	list[orm_expr*] out = new list[orm_expr*]
	if (items != 0):
		for orm_expr* e in items: out.push(e)
	return out


# name(args...). `name` is trusted SQL (a function name).
orm_expr* e_func(char* name, list[orm_expr*] args):
	orm_expr* e = orm_expr_new(ORM_E_FUNC)
	e.name = name
	e.args = orm_expr_list_copy(args)
	return e


orm_expr* e_func1(char* name, orm_expr* a):
	orm_expr* e = orm_expr_new(ORM_E_FUNC)
	e.name = name
	e.args.push(a)
	return e


orm_expr* e_binop(char* op, orm_expr* a, orm_expr* b):
	orm_expr* e = orm_expr_new(ORM_E_BINOP)
	e.name = op
	e.args.push(a)
	e.args.push(b)
	return e


orm_expr* e_add(orm_expr* a, orm_expr* b): return e_binop(c"+", a, b)
orm_expr* e_sub(orm_expr* a, orm_expr* b): return e_binop(c"-", a, b)
orm_expr* e_mul(orm_expr* a, orm_expr* b): return e_binop(c"*", a, b)
orm_expr* e_div(orm_expr* a, orm_expr* b): return e_binop(c"/", a, b)
orm_expr* e_concat(orm_expr* a, orm_expr* b): return e_binop(c"||", a, b)


orm_expr* e_coalesce(list[orm_expr*] args): return e_func(c"COALESCE", args)
orm_expr* e_lower(orm_expr* a): return e_func1(c"LOWER", a)
orm_expr* e_upper(orm_expr* a): return e_func1(c"UPPER", a)


# Trusted SQL text; each "%s" in `sql` takes the next expression of args.
orm_expr* e_raw(char* sql, list[orm_expr*] args):
	orm_expr* e = orm_expr_new(ORM_E_RAW)
	e.name = sql
	e.args = orm_expr_list_copy(args)
	return e


# OuterRef(path): resolved against the query enclosing a subquery.
orm_expr* e_outer(char* path):
	orm_expr* e = orm_expr_new(ORM_E_OUTER_REF)
	e.path = path
	return e


# Subquery over an already-built query tree (see e_subquery in query.w).
orm_expr* e_subquery_query(orm_query* q):
	orm_expr* e = orm_expr_new(ORM_E_SUBQUERY)
	e.subquery = q
	return e


orm_expr* e_exists_query(orm_query* q):
	orm_expr* e = orm_expr_new(ORM_E_EXISTS)
	e.subquery = q
	e.output_kind = ORM_BOOL
	return e


# ---------------------------------------------------------------------------
# Aggregates. A path of 0 or "*" counts rows.

orm_expr* orm_agg(char* name, char* path, int distinct):
	orm_expr* e = orm_expr_new(ORM_E_AGG)
	e.name = name
	e.distinct = distinct
	if (path == 0 || strcmp(path, c"*") == 0): e.args.push(e_star())
	else: e.args.push(f(path))
	return e


orm_expr* agg_count(char* path):
	orm_expr* e = orm_agg(c"COUNT", path, 0)
	e.output_kind = ORM_INT
	return e


orm_expr* agg_count_distinct(char* path):
	orm_expr* e = orm_agg(c"COUNT", path, 1)
	e.output_kind = ORM_INT
	return e


orm_expr* agg_sum(char* path): return orm_agg(c"SUM", path, 0)
orm_expr* agg_avg(char* path): return orm_agg(c"AVG", path, 0)
orm_expr* agg_min(char* path): return orm_agg(c"MIN", path, 0)
orm_expr* agg_max(char* path): return orm_agg(c"MAX", path, 0)


# Aggregate over an arbitrary expression: agg_of("SUM", e_mul(f("a"), f("b"))).
orm_expr* agg_of(char* name, orm_expr* arg):
	orm_expr* e = orm_expr_new(ORM_E_AGG)
	e.name = name
	e.args.push(arg)
	return e


orm_expr* orm_expr_copy(orm_expr* src):
	orm_expr* e = orm_expr_new(src.kind)
	e.path = src.path
	e.value = src.value
	e.name = src.name
	for orm_expr* a in src.args: e.args.push(a)
	e.filter = src.filter
	e.subquery = src.subquery
	e.distinct = src.distinct
	for void* w in src.whens: e.whens.push(w)
	e.else_expr = src.else_expr
	for orm_expr* p in src.partition_by: e.partition_by.push(p)
	for void* o in src.order_by: e.order_by.push(o)
	e.output_kind = src.output_kind
	return e


# COUNT(...) FILTER (WHERE ...): a copy of `agg` restricted by `where`.
orm_expr* agg_filter(orm_expr* agg, orm_where* where):
	orm_expr* e = orm_expr_copy(agg)
	e.filter = where
	return e


# ---------------------------------------------------------------------------
# Ordering

orm_order* ord_expr(orm_expr* e, int descending):
	orm_order* o = new orm_order()
	o.expr = e
	o.descending = descending
	return o


# "-author__name" -> author__name DESC; "id" -> id ASC.
orm_order* ord(char* spec):
	if (spec != 0 && spec[0] == '-'): return ord_expr(f(spec + 1), 1)
	return ord_expr(f(spec), 0)


orm_order* ord_nulls(orm_order* o, int nulls):
	orm_order* c = ord_expr(o.expr, o.descending)
	c.nulls = nulls
	return c


# expr OVER (PARTITION BY partition ORDER BY order). Either list may be 0.
orm_expr* e_window(orm_expr* e, list[orm_expr*] partition, list[orm_order*] order):
	orm_expr* w = orm_expr_new(ORM_E_WINDOW)
	w.args.push(e)
	if (partition != 0):
		for orm_expr* p in partition: w.partition_by.push(p)
	if (order != 0):
		for orm_order* o in order: w.order_by.push(o)
	return w


# ---------------------------------------------------------------------------
# Where nodes (Django Q)

orm_where* q_true(): return orm_where_new(ORM_W_TRUE)
orm_where* q_false(): return orm_where_new(ORM_W_FALSE)


# lhs lookup rhs with an expression on both sides.
orm_where* q_lookup_expr(orm_expr* lhs, char* lookup, orm_expr* rhs):
	orm_where* w = orm_where_new(ORM_W_LOOKUP)
	w.lhs = lhs
	w.lookup = lookup
	w.rhs = rhs
	return w


# isnull compiles from an ORM_E_INT 1/0 right-hand side.
orm_where* q_isnull(char* path, int is_null):
	if (is_null): return q_lookup_expr(f(path), c"isnull", val_int(1))
	return q_lookup_expr(f(path), c"isnull", val_int(0))


# path lookup value. A null value with exact means IS NULL.
orm_where* q_lookup(char* path, char* lookup, char* value):
	if (lookup == 0): lookup = c"exact"
	if (strcmp(lookup, c"isnull") == 0):
		int truthy = value != 0 && strcmp(value, c"0") != 0 && strcmp(value, c"false") != 0 && strcmp(value, c"False") != 0
		return q_isnull(path, truthy)
	return q_lookup_expr(f(path), lookup, val(value))


orm_where* q_eq(char* path, char* value): return q_lookup(path, c"exact", value)
orm_where* q_ne(char* path, char* value): return q_lookup(path, c"ne", value)
orm_where* q_gt(char* path, char* value): return q_lookup(path, c"gt", value)
orm_where* q_gte(char* path, char* value): return q_lookup(path, c"gte", value)
orm_where* q_lt(char* path, char* value): return q_lookup(path, c"lt", value)
orm_where* q_lte(char* path, char* value): return q_lookup(path, c"lte", value)
orm_where* q_icontains(char* path, char* value): return q_lookup(path, c"icontains", value)


orm_where* q_eq_int(char* path, int value):
	return q_lookup_expr(f(path), c"exact", val(itoa(value)))


# path lookup expression (F(), subquery, ...).
orm_where* q_expr(char* path, char* lookup, orm_expr* rhs):
	if (lookup == 0): lookup = c"exact"
	return q_lookup_expr(f(path), lookup, rhs)


# path IN (values...). An empty list matches nothing.
orm_where* q_in(char* path, list[char*] values):
	if (values == 0 || values.length == 0): return q_false()
	orm_where* w = orm_where_new(ORM_W_LOOKUP)
	w.lhs = f(path)
	w.lookup = c"in"
	for char* v in values: w.rhs_list.push(val(v))
	return w


# path IN (expressions...), e.g. a list of val_int.
orm_where* q_in_exprs(char* path, list[orm_expr*] values):
	if (values == 0 || values.length == 0): return q_false()
	orm_where* w = orm_where_new(ORM_W_LOOKUP)
	w.lhs = f(path)
	w.lookup = c"in"
	for orm_expr* v in values: w.rhs_list.push(v)
	return w


orm_where* q_range(char* path, char* low, char* high):
	orm_where* w = orm_where_new(ORM_W_LOOKUP)
	w.lhs = f(path)
	w.lookup = c"range"
	w.rhs_list.push(val(low))
	w.rhs_list.push(val(high))
	return w


# Django-style "author__name__icontains": a trailing lookup name is split
# off, a bare path means exact.
orm_where* q(char* path_lookup, char* value):
	list[char*] parts = orm_path_split(path_lookup)
	char* lookup = c"exact"
	char* path = path_lookup
	if (parts.length > 1 && orm_is_lookup(parts[parts.length - 1])):
		char* last = parts[parts.length - 1]
		lookup = strclone(last)
		int n = strlen(path_lookup) - strlen(last) - 2
		path = cast(char*, malloc(n + 1))
		for i in range(n): path[i] = path_lookup[i]
		path[n] = 0
	for char* p in parts: free(p)
	parts.free()
	return q_lookup(path, lookup, value)


# A boolean expression used as a condition (EXISTS(...), a boolean field).
orm_where* q_bool(orm_expr* e):
	orm_where* w = orm_where_new(ORM_W_EXPR)
	w.lhs = e
	return w


orm_where* orm_where_join(int kind, orm_where* a, orm_where* b):
	if (a == 0): return b
	if (b == 0): return a
	orm_where* w = orm_where_new(kind)
	if (a.kind == kind):
		for orm_where* c in a.children: w.children.push(c)
	else: w.children.push(a)
	if (b.kind == kind):
		for orm_where* c in b.children: w.children.push(c)
	else: w.children.push(b)
	return w


# Either side may be 0 (no condition); nested ANDs/ORs are flattened.
orm_where* q_and(orm_where* a, orm_where* b): return orm_where_join(ORM_W_AND, a, b)
orm_where* q_or(orm_where* a, orm_where* b): return orm_where_join(ORM_W_OR, a, b)


orm_where* q_not(orm_where* a):
	orm_where* w = orm_where_new(ORM_W_NOT)
	w.children.push(a)
	return w


# ---------------------------------------------------------------------------
# Case / When

orm_when* e_when(orm_where* condition, orm_expr* then):
	orm_when* w = new orm_when()
	w.condition = condition
	w.then = then
	return w


# CASE WHEN ... THEN ... [ELSE else_expr] END; else_expr may be 0.
orm_expr* e_case(list[orm_when*] whens, orm_expr* else_expr):
	orm_expr* e = orm_expr_new(ORM_E_CASE)
	if (whens != 0):
		for orm_when* w in whens: e.whens.push(w)
	e.else_expr = else_expr
	return e


# ---------------------------------------------------------------------------
# Assignments (UPDATE SET / INSERT values)

orm_assignment* orm_set(char* field, orm_expr* value):
	orm_assignment* a = new orm_assignment()
	a.field = field
	a.value = value
	return a


orm_assignment* orm_set_text(char* field, char* value):
	return orm_set(field, val(value))


orm_assignment* orm_set_int(char* field, int value):
	return orm_set(field, val(itoa(value)))
