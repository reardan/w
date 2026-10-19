# w-orm QuerySet (unit U1.3, docs/projects/orm/u1_3.md).
#
# An orm_queryset pairs an orm_db with an orm_query tree (C3). Every chain
# call returns a NEW queryset holding a clone of the tree, so a queryset
# can be refined many times without affecting the original; nothing touches
# the database until an evaluation call (all, first, get, count, exists,
# aggregate, update, delete). Evaluations do not cache: each one runs
# exactly one statement and counts it in db.query_count.
#
# Method sugar: qs.filter(w) is orm_queryset_filter(qs, w).
import libs.standard.orm.contract
import libs.standard.orm.expr
import libs.standard.orm.load
import libs.standard.orm.compile


# U2.1 hook: prefetch_related execution lives in related.w, imported at the
# end of this file (it needs orm_queryset and orm_run_select).
int orm_prefetch_execute(orm_db* db, orm_query* q, orm_result* r);


const int ORM_VALUES_NONE = 0
const int ORM_VALUES_DICT = 1    # values(): rows are orm_values_row* with names
const int ORM_VALUES_LIST = 2    # values_list(): same rows, read by position


struct orm_queryset:
	orm_db* db
	orm_query* query
	int values_mode


orm_queryset* orm_queryset_new(orm_db* db, orm_query* q):
	orm_queryset* qs = new orm_queryset()
	qs.db = db
	qs.query = q
	return qs


orm_queryset* orm_queryset_clone(orm_queryset* qs):
	orm_queryset* c = orm_queryset_new(qs.db, orm_query_clone(qs.query))
	c.values_mode = qs.values_mode
	return c


orm_model_desc* orm_queryset_model(orm_queryset* qs):
	return qs.query.model


# Subquery(qs) / Exists(qs): the queryset's tree as an expression.
orm_expr* e_subquery(orm_queryset* qs): return e_subquery_query(qs.query)
orm_expr* e_exists(orm_queryset* qs): return e_exists_query(qs.query)


# ---------------------------------------------------------------------------
# Chaining (each returns a new queryset)

orm_queryset* orm_queryset_filter(orm_queryset* qs, orm_where* w):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.where = q_and(c.query.where, w)
	return c


orm_queryset* orm_queryset_exclude(orm_queryset* qs, orm_where* w):
	if (w == 0): return orm_queryset_clone(qs)
	return orm_queryset_filter(qs, q_not(w))


# Conditions on annotations/aggregates (SQL HAVING).
orm_queryset* orm_queryset_having(orm_queryset* qs, orm_where* w):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.having = q_and(c.query.having, w)
	return c


# Appends one ordering: "title", "-id", "author__name". Call again for a
# secondary key; order_clear() drops the existing ordering.
orm_queryset* orm_queryset_order_by(orm_queryset* qs, char* spec):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.order.push(ord(spec))
	return c


orm_queryset* orm_queryset_order_by_expr(orm_queryset* qs, orm_expr* e, int descending):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.order.push(ord_expr(e, descending))
	return c


orm_queryset* orm_queryset_order(orm_queryset* qs, orm_order* o):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.order.push(o)
	return c


orm_queryset* orm_queryset_order_clear(orm_queryset* qs):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.order.clear()
	return c


orm_queryset* orm_queryset_limit(orm_queryset* qs, int n):
	orm_queryset* c = orm_queryset_clone(qs)
	if (n < 0): n = -1
	c.query.limit = n
	return c


orm_queryset* orm_queryset_offset(orm_queryset* qs, int n):
	orm_queryset* c = orm_queryset_clone(qs)
	if (n < 0): n = 0
	c.query.offset = n
	return c


# Python-style qs[a:b] relative to any existing slice; b < 0 = open end.
orm_queryset* orm_queryset_slice(orm_queryset* qs, int a, int b):
	orm_queryset* c = orm_queryset_clone(qs)
	orm_query* q = c.query
	if (a < 0): a = 0
	int limit = -1
	if (b >= 0):
		limit = b - a
		if (limit < 0): limit = 0
	if (q.limit >= 0):
		int remaining = q.limit - a
		if (remaining < 0): remaining = 0
		if (limit < 0 || remaining < limit): limit = remaining
	q.offset = q.offset + a
	q.limit = limit
	return c


orm_queryset* orm_queryset_distinct(orm_queryset* qs):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.distinct = 1
	return c


# JOINs an FK path ("author", "author__publisher") into the same query and
# links the loaded rows into the FK pointer slots. Adds no queries.
orm_queryset* orm_queryset_select_related(orm_queryset* qs, char* path):
	orm_queryset* c = orm_queryset_clone(qs)
	for char* p in c.query.select_related:
		if (strcmp(p, path) == 0): return c
	c.query.select_related.push(path)
	return c


# Runs after all()/first()/get(): one query per hop (related.w, U2.1).
orm_queryset* orm_queryset_prefetch_related(orm_queryset* qs, char* path):
	orm_queryset* c = orm_queryset_clone(qs)
	orm_prefetch* pf = new orm_prefetch()
	pf.path = path
	c.query.prefetch.push(pf)
	return c


# Adds a named computed column. On model rows read it with
# orm_row_annotation(model, row, name); on values rows it is a column.
orm_queryset* orm_queryset_annotate(orm_queryset* qs, char* name, orm_expr* e):
	orm_queryset* c = orm_queryset_clone(qs)
	orm_annotation* a = new orm_annotation()
	a.name = name
	a.expr = e
	c.query.annotations.push(a)
	return c


orm_queryset* orm_queryset_values_mode(orm_queryset* qs, list[char*] names, int mode):
	orm_queryset* c = orm_queryset_clone(qs)
	c.values_mode = mode
	c.query.select.clear()
	c.query.select_names.clear()
	if (names != 0):
		for char* n in names:
			c.query.select.push(f(n))
			c.query.select_names.push(n)
	return c


# Rows become orm_values_row* (orm_values_get(row, name)). An empty or 0
# list with annotations selects only the annotations.
orm_queryset* orm_queryset_values(orm_queryset* qs, list[char*] names):
	return orm_queryset_values_mode(qs, names, ORM_VALUES_DICT)


# Same rows as values(), meant to be read by position (orm_values_at).
orm_queryset* orm_queryset_values_list(orm_queryset* qs, list[char*] names):
	return orm_queryset_values_mode(qs, names, ORM_VALUES_LIST)


# Loads only these fields (plus the pk); the others stay zero in the row.
orm_queryset* orm_queryset_only(orm_queryset* qs, list[char*] fields):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.only_fields.clear()
	for char* name in fields: c.query.only_fields.push(name)
	return c


# SELECT ... FOR UPDATE [SKIP LOCKED | NOWAIT]; PostgreSQL only.
orm_queryset* orm_queryset_for_update(orm_queryset* qs, int skip_locked, int nowait):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.for_update = 1
	c.query.skip_locked = skip_locked
	c.query.nowait = nowait
	return c


orm_queryset* orm_queryset_group_by(orm_queryset* qs, char* path):
	orm_queryset* c = orm_queryset_clone(qs)
	c.query.group_by.push(f(path))
	return c


# ---------------------------------------------------------------------------
# Execution

int orm_clear_error(orm_db* db):
	return orm_db_set_error(db, c"")


# Compiles and runs q. Returns the raw result (caller frees) with the column
# map in *compiled_out (caller frees with orm_compiled_free; pass 0 to have
# it freed here), or 0 with orm_db_error(db) set.
sql_result* orm_execute_query(orm_db* db, orm_query* q, orm_compiled** compiled_out):
	if (compiled_out != 0): compiled_out[0] = 0
	if (db == 0 || db.conn == 0):
		if (db != 0): orm_db_set_error(db, c"orm: database is not open")
		return 0
	if (q.for_update && db.dialect.supports_for_update == 0):
		orm_db_set_error(db, c"orm: select_for_update is not supported by this database")
		return 0
	orm_compiled* c = orm_compiled_new(db.dialect)
	if (orm_compile(q, db.dialect, c) == 0):
		# The compiler's error text is the caller's to free (u1_2.md).
		if (c.error != 0):
			orm_db_set_error(db, c.error)
			free(c.error)
			c.error = 0
		else: orm_db_set_error(db, c"orm: query did not compile")
		orm_compiled_free(c)
		return 0
	sql_result* sr = orm_db_execute(db, c.sql)
	if (sr == 0 || compiled_out == 0): orm_compiled_free(c)
	else: compiled_out[0] = c
	return sr


# Runs a SELECT tree and loads it: model rows, or values rows when
# values_mode is set or the query has an explicit select list.
orm_result* orm_run_select(orm_db* db, orm_query* q, int values_mode):
	orm_clear_error(db)
	orm_compiled* c = 0
	sql_result* sr = orm_execute_query(db, q, &c)
	if (sr == 0): return 0
	orm_result* r = orm_result_new(q.model)
	r.affected = sr.affected
	int ok = 0
	if (values_mode != ORM_VALUES_NONE || q.select.length > 0): ok = orm_load_values(db, q, c, sr, r)
	else: ok = orm_load_models(db, q.model, c, sr, r)
	sql_result_free(sr)
	orm_compiled_free(c)
	if (ok == 0):
		orm_result_free(r)
		return 0
	return r


# Runs an UPDATE/DELETE/INSERT tree. Returns the affected row count (rows
# returned for a RETURNING statement), or -1 with orm_db_error(db) set.
int orm_run_write(orm_db* db, orm_query* q):
	orm_clear_error(db)
	# SQLite's affected count is a total_changes() difference, which also
	# counts rows changed by ON DELETE actions and triggers. Count the
	# statement's own rows with RETURNING pk instead.
	orm_field_desc* pk = orm_model_pk(q.model)
	int own_rows = db != 0 && db.dialect != 0 && db.dialect.id == ORM_DIALECT_SQLITE && db.dialect.supports_returning
	if (own_rows && pk != 0 && q.returning.length == 0 && (q.kind == ORM_Q_UPDATE || q.kind == ORM_Q_DELETE)):
		q.returning.push(pk.name)
	sql_result* sr = orm_execute_query(db, q, 0)
	if (sr == 0): return -1
	int n = sr.affected
	if (sr.columns > 0 || n < 0): n = sr.rows
	sql_result_free(sr)
	return n


# ---------------------------------------------------------------------------
# Evaluation

# U2.1: runs the queryset's prefetch_related lookups on a loaded result;
# frees it and returns 0 when one fails.
orm_result* orm_with_prefetch(orm_queryset* qs, orm_result* r):
	if (r == 0 || qs.values_mode != ORM_VALUES_NONE || qs.query.select.length > 0): return r
	if (orm_prefetch_execute(qs.db, qs.query, r)): return r
	orm_result_free(r)
	return 0


# Every row (one query, plus one per prefetch hop). Free with
# orm_result_free; 0 on error.
orm_result* orm_queryset_all(orm_queryset* qs):
	return orm_with_prefetch(qs, orm_run_select(qs.db, qs.query, qs.values_mode))


orm_query* orm_first_query(orm_queryset* qs):
	orm_query* q = orm_query_clone(qs.query)
	if (q.order.length == 0 && q.distinct == 0):
		orm_field_desc* pk = orm_model_pk(q.model)
		if (pk != 0): q.order.push(ord(pk.name))
	if (q.limit != 0): q.limit = 1
	return q


# The first row by the current ordering (pk when unordered): a result with
# 0 or 1 rows, 0 on error.
orm_result* orm_queryset_first(orm_queryset* qs):
	return orm_with_prefetch(qs, orm_run_select(qs.db, orm_first_query(qs), qs.values_mode))


# Exactly one row matching `where` (0 = the current filters). Returns 0
# with "<Model> matching query does not exist" or "get() returned more
# than one <Model>" in orm_db_error when the count is not 1.
orm_result* orm_queryset_get(orm_queryset* qs, orm_where* where):
	orm_query* q = orm_query_clone(qs.query)
	q.where = q_and(q.where, where)
	if (q.limit < 0 || q.limit > 2): q.limit = 2
	orm_result* r = orm_run_select(qs.db, q, qs.values_mode)
	if (r == 0): return 0
	if (r.rows.length == 1): return orm_with_prefetch(qs, r)
	string_builder* msg = string_new()
	if (r.rows.length == 0):
		string_append(msg, q.model.name)
		string_append(msg, c" matching query does not exist")
	else:
		string_append(msg, c"get() returned more than one ")
		string_append(msg, q.model.name)
	orm_db_set_error(qs.db, msg.data)
	string_free(msg)
	orm_result_free(r)
	return 0


# 1 when the last get() failed because no row matched.
int orm_error_is_does_not_exist(orm_db* db):
	return ends_with(db.error, c"matching query does not exist")


int orm_error_is_multiple(orm_db* db):
	return starts_with(db.error, c"get() returned more than one")


void orm_query_strip_for_aggregate(orm_query* q):
	q.order.clear()
	q.select_related.clear()
	q.prefetch.clear()
	q.only_fields.clear()


# SELECT COUNT(*) (one query). Sliced, distinct, grouped, annotated or
# values querysets count the rows of the query itself. -1 on error.
int orm_queryset_count(orm_queryset* qs):
	orm_query* q = orm_query_clone(qs.query)
	orm_query_strip_for_aggregate(q)
	int simple = q.limit < 0 && q.offset == 0 && q.distinct == 0 && q.group_by.length == 0 && q.annotations.length == 0 && q.select.length == 0
	if (simple == 0):
		if (q.select.length == 0 && q.annotations.length == 0):
			orm_field_desc* pk = orm_model_pk(q.model)
			q.select.push(f(pk.name))
			q.select_names.push(pk.name)
		orm_result* all = orm_run_select(qs.db, q, ORM_VALUES_LIST)
		if (all == 0): return -1
		int n = all.rows.length
		orm_result_free(all)
		return n
	q.select.push(agg_count(0))
	q.select_names.push(c"__count")
	orm_result* r = orm_run_select(qs.db, q, ORM_VALUES_LIST)
	if (r == 0): return -1
	int count = -1
	if (r.rows.length == 1):
		orm_values_row* row = cast(orm_values_row*, r.rows[0])
		if (orm_parse_int(orm_values_at(row, 0), &count) == 0): count = -1
	orm_result_free(r)
	return count


# 1 when any row matches, 0 when none, -1 on error (one LIMIT 1 query).
int orm_queryset_exists(orm_queryset* qs):
	orm_query* q = orm_query_clone(qs.query)
	orm_query_strip_for_aggregate(q)
	q.select.clear()
	q.select_names.clear()
	q.select.push(val_int(1))
	q.select_names.push(c"__exists")
	if (q.limit != 0): q.limit = 1
	orm_result* r = orm_run_select(qs.db, q, ORM_VALUES_LIST)
	if (r == 0): return -1
	int found = r.rows.length > 0
	orm_result_free(r)
	return found


# One aggregate over the filtered rows: agg(name, agg_sum("pages")).
# Returns an owned copy of the value, or 0 for SQL NULL or on error
# (orm_db_error(db) is "" for NULL).
char* orm_queryset_aggregate(orm_queryset* qs, char* name, orm_expr* e):
	orm_query* q = orm_query_clone(qs.query)
	orm_query_strip_for_aggregate(q)
	q.select.clear()
	q.select_names.clear()
	q.annotations.clear()
	q.select.push(e)
	q.select_names.push(name)
	orm_result* r = orm_run_select(qs.db, q, ORM_VALUES_DICT)
	if (r == 0): return 0
	char* out = 0
	if (r.rows.length > 0):
		char* v = orm_values_at(cast(orm_values_row*, r.rows[0]), 0)
		if (v != 0): out = strclone(v)
	orm_result_free(r)
	return out


int orm_queryset_aggregate_int(orm_queryset* qs, char* name, orm_expr* e, int fallback):
	char* text = orm_queryset_aggregate(qs, name, e)
	int v = fallback
	if (text != 0):
		if (orm_parse_int(text, &v) == 0): v = fallback
		free(text)
	return v


int orm_queryset_reject_slice(orm_queryset* qs, char* what):
	if (qs.query.limit >= 0 || qs.query.offset > 0):
		string_builder* msg = string_new()
		string_append(msg, c"orm: cannot ")
		string_append(msg, what)
		string_append(msg, c" a sliced queryset")
		orm_db_set_error(qs.db, msg.data)
		string_free(msg)
		return 1
	return 0


# UPDATE ... SET field = e for every matching row. Returns the affected
# count, -1 on error. auto_now fields are not touched (as in Django).
int orm_queryset_update_many(orm_queryset* qs, list[orm_assignment*] assignments):
	if (orm_queryset_reject_slice(qs, c"update")): return -1
	orm_query* q = orm_query_clone(qs.query)
	q.kind = ORM_Q_UPDATE
	orm_query_strip_for_aggregate(q)
	q.annotations.clear()
	q.select.clear()
	q.select_names.clear()
	q.assignments.clear()
	for orm_assignment* a in assignments: q.assignments.push(a)
	return orm_run_write(qs.db, q)


int orm_queryset_update(orm_queryset* qs, char* field, orm_expr* e):
	list[orm_assignment*] one = new list[orm_assignment*]
	one.push(orm_set(field, e))
	int n = orm_queryset_update_many(qs, one)
	one.free()
	return n


# DELETE every matching row; the database applies ON DELETE actions.
# Returns the deleted count, -1 on error.
int orm_queryset_delete(orm_queryset* qs):
	if (orm_queryset_reject_slice(qs, c"delete")): return -1
	orm_query* q = orm_query_clone(qs.query)
	q.kind = ORM_Q_DELETE
	orm_query_strip_for_aggregate(q)
	q.annotations.clear()
	q.select.clear()
	q.select_names.clear()
	return orm_run_write(qs.db, q)


# U2.1: prefetch execution, explicit loaders, iterator() and transactions.
import libs.standard.orm.related
