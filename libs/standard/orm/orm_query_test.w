# wbuild: arch_only=x64
# U1.3: queryset chaining, expression trees, write trees and row loading,
# with no database (docs/projects/orm/u1_3.md).
import tests.orm.fixtures.library_orm_api
import lib.assert


orm_db* offline_db():
	return orm_db_new(0, orm_dialect_sqlite())


void test_chain_clones():
	orm_db* db = offline_db()
	orm_queryset* base = Book_objects(db)
	orm_queryset* a = base.filter(q(c"title__icontains", c"dune"))
	orm_queryset* b = a.filter(q_eq(c"status", c"pub")).order_by(c"-id").limit(5)
	assert1(base.query.where == 0)
	assert1(a.query != base.query)
	orm_where* w = a.query.where
	assert_equal(ORM_W_LOOKUP, w.kind)
	assert_strings_equal(c"icontains", w.lookup)
	assert_strings_equal(c"title", w.lhs.path)
	assert_equal(ORM_E_VALUE, w.rhs.kind)
	assert_strings_equal(c"dune", w.rhs.value)
	assert_equal(-1, a.query.limit)
	assert_equal(0, a.query.order.length)
	assert_equal(ORM_W_AND, b.query.where.kind)
	assert_equal(2, b.query.where.children.length)
	assert1(b.query.where.children[0] == w)
	assert_equal(5, b.query.limit)
	orm_order* o = b.query.order[0]
	assert1(o.descending)
	assert_strings_equal(c"id", o.expr.path)
	# A third filter flattens into the same AND.
	orm_queryset* c3 = b.filter(q_gt(c"pages", c"100"))
	assert_equal(3, c3.query.where.children.length)
	assert_equal(2, b.query.where.children.length)
	orm_queryset* ex = base.exclude(q_eq(c"status", c"draft"))
	assert_equal(ORM_W_NOT, ex.query.where.kind)
	assert_strings_equal(c"exact", ex.query.where.children[0].lookup)
	assert1(orm_queryset_model(ex) == Book_desc())
	# Nothing ran.
	assert_equal(0, db.query_count)


void test_q_paths():
	orm_where* w = q(c"author__name", c"Frank")
	assert_strings_equal(c"author__name", w.lhs.path)
	assert_strings_equal(c"exact", w.lookup)
	w = q(c"author__name__startswith", c"Fr")
	assert_strings_equal(c"author__name", w.lhs.path)
	assert_strings_equal(c"startswith", w.lookup)
	w = q(c"pages__isnull", c"1")
	assert_strings_equal(c"isnull", w.lookup)
	assert_equal(ORM_E_INT, w.rhs.kind)
	assert_strings_equal(c"1", w.rhs.value)
	w = q(c"pages__isnull", c"false")
	assert_strings_equal(c"0", w.rhs.value)
	w = q(c"published_at", 0)
	assert_equal(ORM_E_NULL, w.rhs.kind)
	w = q_lookup(c"title", 0, c"x")
	assert_strings_equal(c"exact", w.lookup)
	list[char*] ids = new list[char*]
	assert_equal(ORM_W_FALSE, q_in(c"id", ids).kind)
	ids.push(c"1")
	ids.push(c"2")
	w = q_in(c"id", ids)
	assert_strings_equal(c"in", w.lookup)
	assert_equal(2, w.rhs_list.length)
	w = q_range(c"pages", c"1", c"9")
	assert_equal(2, w.rhs_list.length)
	orm_where* t = q_true()
	assert1(q_and(0, t) == t)
	assert1(q_or(t, 0) == t)
	orm_where* o = q_or(q_or(t, q_false()), q_true())
	assert_equal(ORM_W_OR, o.kind)
	assert_equal(3, o.children.length)
	w = q_expr(c"pages", c"gt", f(c"id"))
	assert_equal(ORM_E_FIELD, w.rhs.kind)
	assert1(orm_is_lookup(c"regex"))
	assert1(orm_is_lookup(c"name") == 0)
	assert_strings_equal(c"7", q_eq_int(c"id", 7).rhs.value)


void test_slices():
	orm_queryset* qs = Book_objects(offline_db())
	orm_queryset* s = qs.slice(10, 20)
	assert_equal(10, s.query.offset)
	assert_equal(10, s.query.limit)
	orm_queryset* s2 = s.slice(2, 5)
	assert_equal(12, s2.query.offset)
	assert_equal(3, s2.query.limit)
	orm_queryset* s3 = qs.limit(5).slice(3, -1)
	assert_equal(3, s3.query.offset)
	assert_equal(2, s3.query.limit)
	orm_queryset* s4 = qs.limit(5).slice(7, 9)
	assert_equal(0, s4.query.limit)
	orm_queryset* s5 = qs.offset(4).slice(1, -1)
	assert_equal(5, s5.query.offset)
	assert_equal(-1, s5.query.limit)
	assert_equal(-1, qs.limit(-3).query.limit)
	assert_equal(0, qs.offset(-3).query.offset)
	assert_equal(0, qs.query.offset)


void test_chain_options():
	orm_queryset* qs = Book_objects(offline_db())
	orm_queryset* r = qs.select_related(c"author").select_related(c"author")
	assert_equal(1, r.query.select_related.length)
	orm_queryset* p = r.prefetch_related(c"tags")
	assert_equal(1, p.query.prefetch.length)
	assert_strings_equal(c"tags", p.query.prefetch[0].path)
	assert_equal(0, r.query.prefetch.length)
	orm_queryset* an = qs.annotate(c"n_tags", agg_count(c"tags"))
	assert_equal(1, an.query.annotations.length)
	assert_strings_equal(c"n_tags", an.query.annotations[0].name)
	list[char*] names = new list[char*]
	names.push(c"title")
	names.push(c"author__name")
	orm_queryset* v = qs.values(names)
	assert_equal(ORM_VALUES_DICT, v.values_mode)
	assert_equal(2, v.query.select.length)
	assert_strings_equal(c"author__name", v.query.select[1].path)
	assert_strings_equal(c"author__name", v.query.select_names[1])
	assert_equal(ORM_VALUES_LIST, qs.values_list(names).values_mode)
	assert_equal(ORM_VALUES_DICT, v.filter(q_true()).values_mode)
	orm_queryset* only = qs.only(names)
	assert_equal(2, only.query.only_fields.length)
	orm_queryset* fu = qs.for_update(1, 0)
	assert1(fu.query.for_update && fu.query.skip_locked && fu.query.nowait == 0)
	assert1(qs.query.for_update == 0)
	orm_queryset* g = qs.group_by(c"status").having(q_gt(c"pages", c"1"))
	assert_equal(1, g.query.group_by.length)
	assert1(g.query.having != 0)
	assert1(qs.distinct().query.distinct)
	orm_queryset* ob = qs.order_by(c"title").order_by_expr(e_lower(f(c"title")), 1)
	assert_equal(2, ob.query.order.length)
	assert_equal(0, ob.order_clear().query.order.length)
	assert_equal(2, ob.query.order.length)
	assert_equal(ORM_NULLS_LAST, ord_nulls(ord(c"pages"), ORM_NULLS_LAST).nulls)
	assert_equal(1, qs.order(ord(c"-pages")).query.order.length)


void test_exprs():
	orm_expr* c = agg_count(0)
	assert_equal(ORM_E_AGG, c.kind)
	assert_strings_equal(c"COUNT", c.name)
	assert_equal(ORM_E_STAR, c.args[0].kind)
	assert_equal(ORM_E_STAR, agg_count(c"*").args[0].kind)
	orm_expr* d = agg_count_distinct(c"author")
	assert1(d.distinct)
	assert_strings_equal(c"author", d.args[0].path)
	orm_expr* fl = agg_filter(agg_sum(c"pages"), q_eq(c"status", c"pub"))
	assert1(fl.filter != 0)
	assert_strings_equal(c"SUM", fl.name)
	assert_strings_equal(c"pages", fl.args[0].path)
	assert_strings_equal(c"AVG", agg_avg(c"pages").name)
	assert_strings_equal(c"MIN", agg_min(c"pages").name)
	assert_strings_equal(c"MAX", agg_max(c"pages").name)
	assert_strings_equal(c"SUM", agg_of(c"SUM", e_mul(f(c"pages"), val_int(2))).name)
	orm_expr* sum = e_add(f(c"pages"), val_int(10))
	assert_equal(ORM_E_BINOP, sum.kind)
	assert_strings_equal(c"+", sum.name)
	assert_strings_equal(c"10", sum.args[1].value)
	assert_strings_equal(c"-", e_sub(f(c"a"), f(c"b")).name)
	assert_strings_equal(c"/", e_div(f(c"a"), f(c"b")).name)
	assert_strings_equal(c"||", e_concat(f(c"a"), f(c"b")).name)
	list[orm_when*] whens = new list[orm_when*]
	whens.push(e_when(q_gt(c"pages", c"500"), val(c"long")))
	orm_expr* cs = e_case(whens, val(c"short"))
	assert_equal(ORM_E_CASE, cs.kind)
	assert_equal(1, cs.whens.length)
	assert_strings_equal(c"short", cs.else_expr.value)
	list[orm_expr*] args = new list[orm_expr*]
	args.push(f(c"pages"))
	args.push(val_int(0))
	orm_expr* co = e_coalesce(args)
	assert_strings_equal(c"COALESCE", co.name)
	assert_equal(2, co.args.length)
	args.push(f(c"x"))
	assert_equal(2, co.args.length)
	assert_strings_equal(c"UPPER", e_upper(f(c"title")).name)
	assert_equal(ORM_E_NULL, val(0).kind)
	assert_equal(ORM_E_NULL, e_null().kind)
	orm_expr* raw = e_raw(c"length(%s)", args)
	assert_equal(ORM_E_RAW, raw.kind)
	assert_equal(3, raw.args.length)
	assert_equal(0, e_raw(c"1", 0).args.length)
	assert_equal(ORM_E_OUTER_REF, e_outer(c"id").kind)
	orm_queryset* sub = Book_objects(offline_db()).filter(q_expr(c"author", c"exact", e_outer(c"id")))
	orm_expr* sq = e_subquery(sub)
	assert1(sq.subquery == sub.query)
	assert_equal(ORM_E_EXISTS, e_exists(sub).kind)
	list[orm_expr*] part = new list[orm_expr*]
	part.push(f(c"author"))
	list[orm_order*] order = new list[orm_order*]
	order.push(ord(c"-pages"))
	orm_expr* win = e_window(agg_of(c"ROW_NUMBER", e_star()), part, order)
	assert_equal(ORM_E_WINDOW, win.kind)
	assert_equal(1, win.partition_by.length)
	assert_equal(1, win.order_by.length)
	assert_equal(0, e_window(f(c"x"), 0, 0).partition_by.length)
	assert_equal(ORM_W_EXPR, q_bool(e_exists(sub)).kind)
	assert_strings_equal(c"title", orm_set_text(c"title", c"x").field)
	assert_strings_equal(c"3", orm_set_int(c"pages", 3).value.value)


# A model with fields save() must never write.
struct Note:
	int id
	char* body
	char* legacy
	char* computed
	char* touched
	int flag


orm_model_desc* note_desc():
	Note probe
	orm_model_desc* m = orm_model_new(c"Note", c"t_note", sizeof(Note))
	orm_model_add_field(m, orm_field_new(c"id", c"id", ORM_INT, __library_offset(&probe, &probe.id), ORM_F_PK | ORM_F_AUTO))
	orm_model_add_field(m, orm_field_new(c"body", c"body", ORM_TEXT, __library_offset(&probe, &probe.body), 0))
	orm_model_add_field(m, orm_field_new(c"legacy", c"legacy", ORM_TEXT, __library_offset(&probe, &probe.legacy), ORM_F_DEPRECATED))
	orm_model_add_field(m, orm_field_new(c"computed", c"computed", ORM_TEXT, __library_offset(&probe, &probe.computed), ORM_F_READ_ONLY))
	orm_model_add_field(m, orm_field_new(c"touched", c"touched", ORM_DATETIME, __library_offset(&probe, &probe.touched), ORM_F_AUTO_NOW))
	orm_model_add_field(m, orm_field_new(c"flag", c"flag", ORM_BOOL, __library_offset(&probe, &probe.flag), 0))
	return m


void test_write_trees():
	library_register()
	Book* b = Book_new()
	b.title = c"Dune"
	b.author_id = 3
	b.price = c"9.99"
	b.pages__isnull = 1
	list[char*] scratch = new list[char*]
	orm_query* ins = orm_insert_query(Book_desc(), b, scratch)
	assert_equal(ORM_Q_INSERT, ins.kind)
	# title, author, price, pages, published_at; id auto and status defaulted.
	assert_equal(5, ins.assignments.length)
	assert_strings_equal(c"title", ins.assignments[0].field)
	assert_strings_equal(c"author", ins.assignments[1].field)
	assert_strings_equal(c"3", ins.assignments[1].value.value)
	assert_equal(ORM_E_NULL, ins.assignments[3].value.kind)
	assert_equal(ORM_E_NULL, ins.assignments[4].value.kind)
	assert_equal(2, ins.returning.length)
	assert_strings_equal(c"id", ins.returning[0])
	assert_strings_equal(c"status", ins.returning[1])
	b.id = 11
	b.status = c"pub"
	b.pages = 7
	b.pages__isnull = 0
	orm_query* up = orm_update_row_query(Book_desc(), b, 0, scratch)
	assert_equal(ORM_Q_UPDATE, up.kind)
	assert_equal(6, up.assignments.length)
	assert_strings_equal(c"7", up.assignments[4].value.value)
	assert_strings_equal(c"id", up.where.lhs.path)
	assert_strings_equal(c"11", up.where.rhs.value)
	list[char*] only = new list[char*]
	only.push(c"title")
	assert_equal(1, orm_update_row_query(Book_desc(), b, only, scratch).assignments.length)
	orm_scratch_free(scratch)
	# Deprecated and read-only fields are never written; auto_now is set.
	orm_set_now(c"2026-10-19 12:00:00")
	orm_model_desc* nm = note_desc()
	Note* n = cast(Note*, orm_row_new(nm))
	n.body = c"hi"
	n.legacy = c"old"
	n.computed = c"x"
	n.flag = 5
	orm_touch_auto_fields(nm, n, 1)
	assert_strings_equal(c"2026-10-19 12:00:00", n.touched)
	scratch = new list[char*]
	ins = orm_insert_query(nm, n, scratch)
	assert_equal(3, ins.assignments.length)
	assert_strings_equal(c"body", ins.assignments[0].field)
	assert_strings_equal(c"touched", ins.assignments[1].field)
	assert_strings_equal(c"1", ins.assignments[2].value.value)
	orm_scratch_free(scratch)
	orm_row_free(nm, n)
	orm_set_now(0)
	char* now = orm_now_text()
	assert_equal(19, strlen(now))
	free(now)
	Book_free(b)


void test_bulk_trees():
	orm_db* db = offline_db()
	assert_equal(db.dialect.max_params / 3, orm_batch_rows(db, 3, 0))
	assert_equal(10, orm_batch_rows(db, 3, 10))
	assert_equal(1000, orm_batch_rows(db, 0, 0))
	assert_equal(1, orm_batch_rows(db, db.dialect.max_params + 1, 0))
	list[void*] rows = new list[void*]
	Book* x = Book_new()
	x.title = c"A"
	x.price = c"1.00"
	Book* y = Book_new()
	y.title = c"B"
	y.status = c"pub"
	y.price = c"2.00"
	rows.push(x)
	rows.push(y)
	list[char*] scratch = new list[char*]
	list[char*] cf = new list[char*]
	cf.push(c"title")
	list[char*] uf = new list[char*]
	uf.push(c"price")
	orm_query* q1 = orm_bulk_insert_query(Book_desc(), rows, 0, 2, 0, orm_conflict_update(cf, uf), scratch)
	assert_equal(2, q1.insert_rows.length)
	list[orm_assignment*] first = q1.insert_rows[0]
	assert_equal(6, first.length)
	assert_strings_equal(c"status", first[2].field)
	assert_equal(ORM_E_RAW, first[2].value.kind)
	assert_strings_equal(c"'draft'", first[2].value.name)
	list[orm_assignment*] second = q1.insert_rows[1]
	assert_strings_equal(c"pub", second[2].value.value)
	assert_equal(ORM_CONFLICT_UPDATE, q1.conflict_action)
	assert_strings_equal(c"title", q1.conflict_fields[0])
	assert_strings_equal(c"price", q1.update_fields[0])
	assert_equal(2, q1.returning.length)
	orm_query* q2 = orm_bulk_insert_query(Book_desc(), rows, 1, 2, 0, orm_conflict_ignore(0), scratch)
	assert_equal(1, q2.insert_rows.length)
	assert_equal(0, q2.returning.length)
	assert_equal(ORM_CONFLICT_NOTHING, q2.conflict_action)
	orm_scratch_free(scratch)
	# Mixed pks are rejected before any query.
	y.id = 4
	assert_equal(-1, orm_bulk_create(db, Book_desc(), rows, 0, 0))
	assert_contains(orm_db_error(db), c"mix")
	assert_equal(0, db.query_count)
	list[char*] bad = new list[char*]
	bad.push(c"tags")
	assert_equal(-1, orm_bulk_update(db, Book_desc(), rows, bad, 0))
	orm_model_desc* through = orm_through_desc(orm_model_field(Book_desc(), c"tags"))
	assert_strings_equal(c"library_book_tags", through.table)
	assert_strings_equal(c"tag_id", through.fields[1].column)
	assert1(orm_through_desc(orm_model_field(Book_desc(), c"tags")) == through)
	assert_equal(-1, orm_m2m_add(db, Book_desc(), y, c"title", rows))
	Book_free(x)
	Book_free(y)


void push_cell(sql_result* r, char* v):
	if (v == 0):
		r.values.push(0)
		r.lengths.push(-1)
	else:
		r.values.push(strclone(v))
		r.lengths.push(strlen(v))


orm_column_map* col(orm_compiled* c, orm_model_desc* m, char* field, char* rel_path, char* name):
	orm_column_map* cm = new orm_column_map()
	cm.model = m
	if (m != 0): cm.field = orm_model_field(m, field)
	cm.rel_path = rel_path
	cm.name = name
	c.columns.push(cm)
	return cm


void test_load_models():
	orm_db* db = offline_db()
	orm_compiled* c = orm_compiled_new(db.dialect)
	col(c, Book_desc(), c"id", c"", 0)
	col(c, Book_desc(), c"title", c"", 0)
	col(c, Book_desc(), c"author", c"", 0)
	col(c, Book_desc(), c"price", c"", 0)
	col(c, Book_desc(), c"pages", c"", 0)
	col(c, Author_desc(), c"id", c"author", 0)
	col(c, Author_desc(), c"name", c"author", 0)
	col(c, 0, 0, 0, c"n_tags")
	sql_result* sr = sql_result_new(8)
	for i in range(8): sr.names.push(strclone(c"c"))
	push_cell(sr, c"1")
	push_cell(sr, c"Dune")
	push_cell(sr, c"7")
	push_cell(sr, c"9.5")
	push_cell(sr, 0)
	push_cell(sr, c"7")
	push_cell(sr, c"Frank")
	push_cell(sr, c"3")
	push_cell(sr, c"2")
	push_cell(sr, c"Orphan")
	push_cell(sr, c"8")
	push_cell(sr, c"12")
	push_cell(sr, c"412")
	push_cell(sr, 0)
	push_cell(sr, 0)
	push_cell(sr, 0)
	sr.rows = 2
	orm_result* r = orm_result_new(Book_desc())
	assert1(orm_load_models(db, Book_desc(), c, sr, r))
	list[Book*] books = Book_rows(r)
	assert_equal(2, books.length)
	Book* b = books[0]
	assert_equal(1, b.id)
	assert_strings_equal(c"Dune", b.title)
	assert_equal(7, b.author_id)
	assert_strings_equal(c"9.50", b.price)
	assert_equal(1, b.pages__isnull)
	assert1(b.author != 0)
	assert_equal(7, b.author.id)
	assert_strings_equal(c"Frank", b.author.name)
	assert1(b.tags != 0)
	assert_equal(0, b.tags.length)
	assert1(b.author.books != 0)
	assert_strings_equal(c"3", orm_row_annotation(Book_desc(), b, c"n_tags"))
	assert_equal(3, orm_row_annotation_int(Book_desc(), b, c"n_tags", -1))
	assert_equal(-1, orm_row_annotation_int(Book_desc(), b, c"missing", -1))
	Book* o = books[1]
	assert_equal(0, o.pages__isnull)
	assert_equal(412, o.pages)
	assert_strings_equal(c"12.00", o.price)
	# LEFT JOIN miss: the related row is not linked.
	assert1(o.author == 0)
	assert1(orm_row_annotation(Book_desc(), o, c"n_tags") == 0)
	# A string owned on behalf of a result row goes with the result.
	o.title = orm_row_own(Book_desc(), o, strclone(c"renamed"))
	orm_result_free(r)
	# A mismatched column map is an error, not a crash.
	c.columns.pop()
	orm_result* r2 = orm_result_new(Book_desc())
	assert_equal(0, orm_load_models(db, Book_desc(), c, sr, r2))
	assert_contains(orm_db_error(db), c"column map")
	orm_result_free(r2)
	sql_result_free(sr)
	orm_compiled_free(c)


void test_load_values():
	orm_db* db = offline_db()
	orm_compiled* c = orm_compiled_new(db.dialect)
	col(c, 0, 0, 0, c"title")
	col(c, 0, 0, 0, c"n")
	orm_column_map* flag = col(c, Book_desc(), c"price", c"", c"price")
	sql_result* sr = sql_result_new(4)
	for i in range(4): sr.names.push(strclone(c"extra"))
	push_cell(sr, c"Dune")
	push_cell(sr, c"2")
	push_cell(sr, c"3")
	push_cell(sr, 0)
	sr.rows = 1
	orm_result* r = orm_result_new(Book_desc())
	orm_query* vq = orm_query_new(ORM_Q_SELECT, Book_desc())
	vq.select.push(f(c"title"))
	vq.select.push(f(c"author__name"))
	assert1(orm_load_values(db, vq, c, sr, r))
	assert1(orm_path_field(Book_desc(), c"author__name") == orm_model_field(Author_desc(), c"name"))
	assert1(orm_path_field(Book_desc(), c"tags__name") == 0)
	assert1(orm_path_field(Book_desc(), c"author") == orm_model_field(Book_desc(), c"author"))
	assert1(orm_path_field(Book_desc(), c"nope") == 0)
	list[orm_values_row*] rows = orm_values_rows(r)
	assert_equal(1, rows.length)
	assert_strings_equal(c"Dune", orm_values_get(rows[0], c"title"))
	assert_equal(2, orm_values_int(rows[0], c"n", -1))
	assert_equal(-1, orm_values_int(rows[0], c"zzz", -1))
	assert_strings_equal(c"3.00", orm_values_at(rows[0], 2))
	assert_strings_equal(c"extra", rows[0].names[3])
	assert1(orm_values_at(rows[0], 3) == 0)
	assert1(orm_values_at(rows[0], 9) == 0)
	assert1(orm_values_get(0, c"x") == 0)
	assert1(flag.field != 0)
	orm_result_free(r)
	sql_result_free(sr)
	orm_compiled_free(c)


void test_load_by_name_and_conversions():
	orm_db* db = offline_db()
	sql_result* sr = sql_result_new(3)
	sr.names.push(strclone(c"id"))
	sr.names.push(strclone(c"name"))
	sr.names.push(strclone(c"unknown"))
	push_cell(sr, c"5")
	push_cell(sr, c"Ada")
	push_cell(sr, c"?")
	sr.rows = 1
	orm_result* r = orm_result_new(Author_desc())
	assert1(orm_load_by_column_name(db, Author_desc(), sr, r))
	Author* a = Author_rows(r)[0]
	assert_equal(5, a.id)
	assert_strings_equal(c"Ada", a.name)
	Author* h = Author_new()
	orm_copy_field(Author_desc(), orm_model_field(Author_desc(), c"name"), h, a)
	assert_strings_equal(c"Ada", h.name)
	assert1(h.name != a.name)
	orm_result_free(r)
	sql_result_free(sr)
	Author_free(h)
	int v = 0
	assert1(orm_parse_bool(c"t", &v) && v == 1)
	assert1(orm_parse_bool(c"0", &v) && v == 0)
	assert1(orm_parse_bool(c"maybe", &v) == 0)
	assert1(orm_parse_int(c"-42", &v) && v == -42)
	assert1(orm_parse_int(c"4x", &v) == 0)
	orm_result* t = orm_result_new(0)
	assert_strings_equal(c"-1.50", orm_decimal_text(t, c"-1.5", 2))
	assert_strings_equal(c"1.234", orm_decimal_text(t, c"1.234", 2))
	assert_strings_equal(c"1e-05", orm_decimal_text(t, c"1e-05", 2))
	assert_strings_equal(c"7", orm_decimal_text(t, c"7", 0))
	assert_strings_equal(c"1.2.3", orm_decimal_text(t, c"1.2.3", 2))
	orm_result_free(t)
	char* s = orm_format_int(-7)
	assert_strings_equal(c"-7", s)
	free(s)


void test_offline_evaluation():
	orm_db* db = offline_db()
	orm_queryset* qs = Book_objects(db)
	assert1(qs.all() == 0)
	assert_contains(orm_db_error(db), c"not open")
	assert_equal(-1, qs.count())
	assert_equal(-1, qs.exists())
	assert1(qs.first() == 0)
	assert1(qs.get(q_eq_int(c"id", 1)) == 0)
	assert1(qs.aggregate(c"s", agg_sum(c"pages")) == 0)
	assert_equal(-1, qs.update(c"pages", val_int(1)))
	assert_equal(-1, qs.delete())
	assert_equal(-1, qs.limit(2).delete())
	assert_contains(orm_db_error(db), c"sliced")
	assert_equal(-1, qs.slice(1, 3).update(c"pages", val_int(1)))
	# select_for_update is rejected on SQLite before compiling.
	db.conn = cast(sql_connection*, 1)
	assert1(qs.for_update(0, 0).all() == 0)
	assert_contains(orm_db_error(db), c"select_for_update")
	db.conn = 0
	assert_equal(0, db.query_count)
	orm_query* fq = orm_first_query(qs)
	assert_equal(1, fq.limit)
	assert_strings_equal(c"id", fq.order[0].expr.path)
	assert_strings_equal(c"title", orm_first_query(qs.order_by(c"title")).order[0].expr.path)
	assert_equal(0, orm_first_query(qs.limit(0)).limit)
	assert1(orm_is_open(db) == 0)
	assert1(orm_is_open(0) == 0)
	orm_db_set_error(db, c"Book matching query does not exist")
	assert1(orm_error_is_does_not_exist(db))
	orm_db_set_error(db, c"get() returned more than one Book")
	assert1(orm_error_is_multiple(db))


int main():
	library_register()
	test_chain_clones()
	test_q_paths()
	test_slices()
	test_chain_options()
	test_exprs()
	test_write_trees()
	test_bulk_trees()
	test_load_models()
	test_load_values()
	test_load_by_name_and_conversions()
	test_offline_evaluation()
	println(c"orm_query_test: OK")
	return 0
