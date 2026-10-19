# End-to-end ORM scenarios over the library fixture, shared by
# libs/standard/orm/orm_sqlite_test.w and orm_postgres_test.w (unit U1.3).
# Every evaluation asserts its result and how many statements it ran.
import tests.orm.fixtures.library_orm_api
import tests.orm.fixtures.library_schema
import lib.assert


int __e2e_mark


# Asserts that exactly n statements ran since the last call.
void expect_queries(orm_db* db, int n):
	if (db.query_count - __e2e_mark != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(db.query_count - __e2e_mark))
		print(c"last error: ")
		println(orm_db_error(db))
		for char* s in db.query_log: println(s)
	assert_equal(n, db.query_count - __e2e_mark)
	__e2e_mark = db.query_count


void check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


Author* make_author(orm_db* db, char* name, char* email):
	Author* a = Author_new()
	a.name = name
	a.email = email
	check(db, Author_save(db, a))
	expect_queries(db, 1)
	return a


Book* new_book(char* title, Author* a, char* price, int pages):
	Book* b = Book_new()
	b.title = title
	b.author_id = a.id
	b.price = price
	if (pages < 0): b.pages__isnull = 1
	else: b.pages = pages
	return b


list[char*] names1(char* a):
	list[char*] l = new list[char*]
	l.push(a)
	return l


list[char*] names2(char* a, char* b):
	list[char*] l = names1(a)
	l.push(b)
	return l


struct e2e_data:
	Author* frank
	Author* ursula
	Author* nobody
	Tag* sf
	Tag* classic
	Tag* fantasy
	Book* dune
	Book* messiah
	Book* earthsea


void test_saves(orm_db* db, e2e_data* d):
	orm_set_now(c"2026-10-19 12:00:00")
	d.frank = make_author(db, c"Frank Herbert", c"frank@example.com")
	assert1(d.frank.id > 0)
	assert_strings_equal(c"2026-10-19 12:00:00", d.frank.created)
	d.ursula = make_author(db, c"Ursula K. Le Guin", c"ursula@example.com")
	assert1(d.ursula.id > d.frank.id)
	d.nobody = make_author(db, c"Nobody", c"nobody@example.com")
	# Tags: one multi-row INSERT ... RETURNING.
	d.sf = Tag_new()
	d.sf.name = c"sf"
	d.classic = Tag_new()
	d.classic.name = c"classic"
	d.fantasy = Tag_new()
	d.fantasy.name = c"fantasy"
	list[void*] tags = new list[void*]
	tags.push(d.sf)
	tags.push(d.classic)
	tags.push(d.fantasy)
	assert_equal(3, orm_bulk_create(db, Tag_desc(), tags, 0, 0))
	expect_queries(db, 1)
	assert1(d.sf.id > 0 && d.classic.id > d.sf.id && d.fantasy.id > d.classic.id)
	# Books: batch of 2 -> two statements; the omitted status picks up the
	# database default through RETURNING.
	d.dune = new_book(c"Dune", d.frank, c"9.99", 412)
	d.messiah = new_book(c"Dune Messiah", d.frank, c"12.5", -1)
	d.messiah.status = c"pub"
	d.earthsea = new_book(c"A Wizard of Earthsea", d.ursula, c"7", 183)
	list[void*] books = new list[void*]
	books.push(d.dune)
	books.push(d.messiah)
	books.push(d.earthsea)
	assert_equal(3, orm_bulk_create(db, Book_desc(), books, 2, 0))
	expect_queries(db, 2)
	assert1(d.dune.id > 0 && d.messiah.id > d.dune.id && d.earthsea.id > d.messiah.id)
	assert_strings_equal(c"draft", d.dune.status)
	assert_strings_equal(c"pub", d.messiah.status)
	# save() of a new row with a defaulted status: INSERT ... RETURNING.
	Book* extra = new_book(c"Children of Dune", d.frank, c"8.00", 444)
	check(db, Book_save(db, extra))
	expect_queries(db, 1)
	assert_strings_equal(c"draft", extra.status)
	assert1(extra.id > d.earthsea.id)
	# save() of an existing row is one UPDATE.
	extra.title = c"Children of Dune (2)"
	check(db, Book_save(db, extra))
	expect_queries(db, 1)
	# delete() by pk.
	int extra_id = extra.id
	assert_equal(1, Book_delete(db, extra))
	expect_queries(db, 1)
	assert_equal(0, extra.id)
	assert_equal(0, Book_objects(db).filter(q_eq_int(c"id", extra_id)).count())
	expect_queries(db, 1)
	# save() with a pk that has no row inserts it with that pk.
	extra.id = extra_id + 100
	check(db, Book_save(db, extra))
	expect_queries(db, 2)
	assert_equal(1, Book_objects(db).filter(q_eq_int(c"id", extra_id + 100)).count())
	expect_queries(db, 1)
	assert_equal(1, Book_delete(db, extra))
	expect_queries(db, 1)
	Book_free(extra)
	books.free()
	tags.free()


void test_reads(orm_db* db, e2e_data* d):
	orm_result* r = Book_objects(db).order_by(c"id").all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	list[Book*] rows = Book_rows(r)
	assert_equal(3, rows.length)
	assert_strings_equal(c"Dune", rows[0].title)
	assert_equal(d.frank.id, rows[0].author_id)
	assert_strings_equal(c"9.99", rows[0].price)
	assert_strings_equal(c"12.50", rows[1].price)
	assert_strings_equal(c"7.00", rows[2].price)
	assert_equal(412, rows[0].pages)
	assert_equal(0, rows[0].pages__isnull)
	assert_equal(1, rows[1].pages__isnull)
	assert1(rows[0].published_at == 0)
	# Without select_related the FK pointer stays unloaded.
	assert1(rows[0].author == 0)
	assert1(rows[0].tags != 0)
	orm_result_free(r)
	# select_related: still one query, authors linked.
	r = Book_objects(db).select_related(c"author").order_by(c"-id").all()
	expect_queries(db, 1)
	rows = Book_rows(r)
	assert_equal(3, rows.length)
	assert_strings_equal(c"A Wizard of Earthsea", rows[0].title)
	for Book* b in rows:
		assert1(b.author != 0)
		assert_equal(b.author_id, b.author.id)
	assert_strings_equal(c"Ursula K. Le Guin", Book_author(rows[0]).name)
	assert_strings_equal(c"frank@example.com", rows[2].author.email)
	assert_strings_equal(c"2026-10-19 12:00:00", rows[2].author.created)
	orm_result_free(r)
	# Filters, lookups across relations, exclude, ordering and slicing.
	orm_queryset* dunes = Book_objects(db).filter(q(c"title__icontains", c"DUNE"))
	assert_equal(2, dunes.count())
	expect_queries(db, 1)
	assert_equal(1, dunes.exists())
	expect_queries(db, 1)
	assert_equal(0, Book_objects(db).filter(q(c"title__startswith", c"Zzz")).exists())
	expect_queries(db, 1)
	assert_equal(2, Book_objects(db).filter(q(c"author__name", c"Frank Herbert")).count())
	expect_queries(db, 1)
	assert_equal(1, Book_objects(db).exclude(q(c"author__email__endswith", c"frank@example.com")).count())
	expect_queries(db, 1)
	assert_equal(1, Book_objects(db).filter(q(c"pages__isnull", c"1")).count())
	expect_queries(db, 1)
	assert_equal(2, Book_objects(db).filter(q_or(q_gt(c"pages", c"400"), q_eq(c"status", c"pub"))).count())
	expect_queries(db, 1)
	assert_equal(2, Book_objects(db).filter(q_in(c"title", names2(c"Dune", c"A Wizard of Earthsea"))).count())
	expect_queries(db, 1)
	r = Book_objects(db).order_by(c"title").slice(1, 2).all()
	expect_queries(db, 1)
	assert_equal(1, r.rows.length)
	assert_strings_equal(c"Dune", Book_rows(r)[0].title)
	orm_result_free(r)
	assert_equal(2, Book_objects(db).order_by(c"title").slice(1, -1).count())
	expect_queries(db, 1)
	# first() orders by pk; get() needs exactly one row.
	r = dunes.first()
	expect_queries(db, 1)
	assert_equal(1, r.rows.length)
	assert_equal(d.dune.id, Book_rows(r)[0].id)
	orm_result_free(r)
	r = Book_objects(db).filter(q_eq(c"title", c"nope")).first()
	expect_queries(db, 1)
	assert_equal(0, r.rows.length)
	orm_result_free(r)
	r = Book_objects(db).select_related(c"author").get(q_eq(c"title", c"Dune Messiah"))
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	assert_strings_equal(c"Frank Herbert", Book_rows(r)[0].author.name)
	orm_result_free(r)
	assert1(Book_objects(db).get(q_eq(c"title", c"nope")) == 0)
	expect_queries(db, 1)
	assert_strings_equal(c"Book matching query does not exist", orm_db_error(db))
	assert1(orm_error_is_does_not_exist(db))
	assert1(dunes.get(0) == 0)
	expect_queries(db, 1)
	assert1(orm_error_is_multiple(db))
	# The base queryset was not changed by any of the chains above.
	assert1(dunes.query.limit == -1 && dunes.query.order.length == 0)


void test_annotations(orm_db* db, e2e_data* d):
	# Annotation over a reverse FK, read by name from the model rows.
	orm_result* r = Author_objects(db).annotate(c"n_books", agg_count(c"books")).order_by(c"id").all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	list[Author*] authors = Author_rows(r)
	assert_equal(3, authors.length)
	assert_equal(2, orm_row_annotation_int(Author_desc(), authors[0], c"n_books", -1))
	assert_equal(1, orm_row_annotation_int(Author_desc(), authors[1], c"n_books", -1))
	assert_equal(0, orm_row_annotation_int(Author_desc(), authors[2], c"n_books", -1))
	orm_result_free(r)
	# Filtering on an annotation (HAVING).
	orm_queryset* prolific = Author_objects(db).annotate(c"n_books", agg_count(c"books")).having(q_gte(c"n_books", c"2"))
	r = prolific.all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	assert_equal(1, r.rows.length)
	assert_strings_equal(c"Frank Herbert", Author_rows(r)[0].name)
	orm_result_free(r)
	assert_equal(1, prolific.count())
	expect_queries(db, 1)
	# values() + annotate groups by the values columns.
	r = Book_objects(db).values(names1(c"status")).annotate(c"n", agg_count(0)).order_by(c"status").all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	list[orm_values_row*] vrows = orm_values_rows(r)
	assert_equal(2, vrows.length)
	assert_strings_equal(c"draft", orm_values_get(vrows[0], c"status"))
	assert_equal(2, orm_values_int(vrows[0], c"n", -1))
	assert_strings_equal(c"pub", orm_values_at(vrows[1], 0))
	assert_equal(1, orm_values_int(vrows[1], c"n", -1))
	orm_result_free(r)
	# values_list across a relation, decimals normalized.
	r = Book_objects(db).values_list(names2(c"author__name", c"price")).order_by(c"id").all()
	expect_queries(db, 1)
	vrows = orm_values_rows(r)
	assert_equal(3, vrows.length)
	assert_strings_equal(c"Frank Herbert", orm_values_at(vrows[0], 0))
	assert_strings_equal(c"12.50", orm_values_at(vrows[1], 1))
	orm_result_free(r)
	# Aggregates.
	char* total = Book_objects(db).aggregate(c"total", agg_sum(c"pages"))
	expect_queries(db, 1)
	assert_strings_equal(c"595", total)
	free(total)
	assert_equal(412, Book_objects(db).aggregate_int(c"m", agg_max(c"pages"), -1))
	expect_queries(db, 1)
	assert1(Book_objects(db).filter(q_eq(c"title", c"nope")).aggregate(c"s", agg_sum(c"pages")) == 0)
	expect_queries(db, 1)
	assert_strings_equal(c"", orm_db_error(db))
	assert_equal(2, Book_objects(db).aggregate_int(c"d", agg_count_distinct(c"author"), -1))
	expect_queries(db, 1)
	assert_equal(1, Book_objects(db).aggregate_int(c"p", agg_filter(agg_count(0), q_eq(c"status", c"pub")), -1))
	expect_queries(db, 1)
	# Subquery / Exists with OuterRef.
	orm_queryset* has_pub = Book_objects(db).filter(q_and(q_expr(c"author", c"exact", e_outer(c"id")), q_eq(c"status", c"pub")))
	assert_equal(1, Author_objects(db).filter(q_bool(e_exists(has_pub))).count())
	expect_queries(db, 1)
	orm_queryset* newest = Book_objects(db).filter(q_expr(c"author", c"exact", e_outer(c"id"))).order_by(c"-id").values(names1(c"title")).limit(1)
	r = Author_objects(db).annotate(c"latest", e_subquery(newest)).order_by(c"id").all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	assert_strings_equal(c"Dune Messiah", orm_row_annotation(Author_desc(), Author_rows(r)[0], c"latest"))
	assert1(orm_row_annotation(Author_desc(), Author_rows(r)[2], c"latest") == 0)
	orm_result_free(r)
	# CASE / WHEN annotation.
	list[orm_when*] whens = new list[orm_when*]
	whens.push(e_when(q_gt(c"pages", c"300"), val(c"long")))
	r = Book_objects(db).annotate(c"size", e_case(whens, val(c"short"))).order_by(c"id").all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	assert_strings_equal(c"long", orm_row_annotation(Book_desc(), r.rows[0], c"size"))
	assert_strings_equal(c"short", orm_row_annotation(Book_desc(), r.rows[1], c"size"))
	orm_result_free(r)
	# Window function, COALESCE and an expression ordering.
	list[orm_expr*] part = new list[orm_expr*]
	part.push(f(c"author"))
	list[orm_order*] order = new list[orm_order*]
	order.push(ord(c"id"))
	list[orm_expr*] coalesce_args = new list[orm_expr*]
	coalesce_args.push(f(c"pages"))
	coalesce_args.push(val_int(0))
	orm_queryset* ranked = Book_objects(db).annotate(c"rank", e_window(e_func(c"ROW_NUMBER", 0), part, order))
	ranked = ranked.annotate(c"pages0", e_coalesce(coalesce_args)).order_by_expr(e_lower(f(c"title")), 0)
	r = ranked.all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	list[Book*] rb = Book_rows(r)
	assert_strings_equal(c"A Wizard of Earthsea", rb[0].title)
	assert_equal(1, orm_row_annotation_int(Book_desc(), rb[0], c"rank", -1))
	assert_equal(1, orm_row_annotation_int(Book_desc(), rb[1], c"rank", -1))
	assert_equal(2, orm_row_annotation_int(Book_desc(), rb[2], c"rank", -1))
	assert_equal(0, orm_row_annotation_int(Book_desc(), rb[2], c"pages0", -1))
	assert_equal(412, orm_row_annotation_int(Book_desc(), rb[1], c"pages0", -1))
	orm_result_free(r)
	part.free()
	order.free()
	coalesce_args.free()


void test_updates(orm_db* db, e2e_data* d):
	# Queryset update with F(): one UPDATE.
	assert_equal(2, Book_objects(db).filter(q_isnull(c"pages", 0)).update(c"pages", e_add(f(c"pages"), val_int(1))))
	expect_queries(db, 1)
	assert_equal(413, Book_objects(db).aggregate_int(c"m", agg_max(c"pages"), -1))
	expect_queries(db, 1)
	list[orm_assignment*] sets = new list[orm_assignment*]
	sets.push(orm_set_text(c"status", c"pub"))
	sets.push(orm_set_text(c"published_at", c"2026-01-02 03:04:05"))
	assert_equal(2, Book_objects(db).filter(q_eq(c"status", c"draft")).update_many(sets))
	expect_queries(db, 1)
	# refresh() reloads a stale row.
	check(db, orm_refresh(db, Book_desc(), d.dune))
	expect_queries(db, 1)
	assert_equal(413, d.dune.pages)
	assert_strings_equal(c"pub", d.dune.status)
	assert_strings_equal(c"2026-01-02 03:04:05", d.dune.published_at)
	# save_fields writes only the listed field.
	d.dune.title = c"Dune (revised)"
	d.dune.pages = 1
	check(db, orm_save_fields(db, Book_desc(), d.dune, names1(c"title")))
	expect_queries(db, 1)
	check(db, orm_refresh(db, Book_desc(), d.dune))
	expect_queries(db, 1)
	assert_strings_equal(c"Dune (revised)", d.dune.title)
	assert_equal(413, d.dune.pages)
	# bulk_update: one CASE statement for both rows.
	d.dune.pages = 500
	d.earthsea.pages = 200
	list[void*] rows = new list[void*]
	rows.push(d.dune)
	rows.push(d.earthsea)
	assert_equal(2, orm_bulk_update(db, Book_desc(), rows, names1(c"pages"), 0))
	expect_queries(db, 1)
	assert_equal(700, Book_objects(db).aggregate_int(c"s", agg_sum(c"pages"), -1))
	expect_queries(db, 1)
	# Batches of one: two statements.
	d.dune.pages = 501
	d.earthsea.pages = 201
	assert_equal(2, orm_bulk_update(db, Book_desc(), rows, names1(c"pages"), 1))
	expect_queries(db, 2)
	assert_equal(702, Book_objects(db).aggregate_int(c"s", agg_sum(c"pages"), -1))
	expect_queries(db, 1)
	rows.free()


void test_create_helpers(orm_db* db, e2e_data* d):
	list[orm_assignment*] lookup = new list[orm_assignment*]
	lookup.push(orm_set_text(c"name", c"sf"))
	int created = -1
	orm_result* r = orm_get_or_create(db, Tag_desc(), lookup, 0, &created)
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	assert_equal(0, created)
	assert_equal(d.sf.id, Tag_rows(r)[0].id)
	orm_result_free(r)
	list[orm_assignment*] lookup2 = new list[orm_assignment*]
	lookup2.push(orm_set_text(c"email", c"gene@example.com"))
	list[orm_assignment*] defaults = new list[orm_assignment*]
	defaults.push(orm_set_text(c"name", c"Gene Wolfe"))
	r = orm_get_or_create(db, Author_desc(), lookup2, defaults, &created)
	expect_queries(db, 2)
	asserts(orm_db_error(db), r != 0)
	assert_equal(1, created)
	Author* gene = Author_rows(r)[0]
	assert1(gene.id > d.nobody.id)
	assert_strings_equal(c"Gene Wolfe", gene.name)
	assert_strings_equal(c"2026-10-19 12:00:00", gene.created)
	int gene_id = gene.id
	orm_result_free(r)
	# update_or_create on an existing row: lookup + UPDATE ... RETURNING.
	list[orm_assignment*] defaults2 = new list[orm_assignment*]
	defaults2.push(orm_set_text(c"name", c"Gene W."))
	r = orm_update_or_create(db, Author_desc(), lookup2, defaults2, &created)
	expect_queries(db, 2)
	asserts(orm_db_error(db), r != 0)
	assert_equal(0, created)
	assert_equal(gene_id, Author_rows(r)[0].id)
	assert_strings_equal(c"Gene W.", Author_rows(r)[0].name)
	orm_result_free(r)
	# update_or_create creating a row.
	list[orm_assignment*] lookup3 = new list[orm_assignment*]
	lookup3.push(orm_set_text(c"email", c"iain@example.com"))
	list[orm_assignment*] defaults3 = new list[orm_assignment*]
	defaults3.push(orm_set_text(c"name", c"Iain Banks"))
	r = orm_update_or_create(db, Author_desc(), lookup3, defaults3, &created)
	expect_queries(db, 2)
	asserts(orm_db_error(db), r != 0)
	assert_equal(1, created)
	orm_result_free(r)
	# The INSERT loses a unique race (email exists under another name): the
	# get is retried, still misses, and the insert error is reported.
	list[orm_assignment*] clash = new list[orm_assignment*]
	clash.push(orm_set_text(c"name", c"Impostor"))
	clash.push(orm_set_text(c"email", c"frank@example.com"))
	r = orm_get_or_create(db, Author_desc(), clash, 0, &created)
	expect_queries(db, 3)
	assert1(r == 0)
	assert1(strlen(orm_db_error(db)) > 0)
	assert1(orm_error_is_does_not_exist(db) == 0)
	# Conflict handling in bulk_create.
	Tag* dup = Tag_new()
	dup.name = c"sf"
	Tag* fresh = Tag_new()
	fresh.name = c"horror"
	list[void*] tags = new list[void*]
	tags.push(dup)
	tags.push(fresh)
	assert_equal(1, orm_bulk_create(db, Tag_desc(), tags, 0, orm_conflict_ignore(names1(c"name"))))
	expect_queries(db, 1)
	assert_equal(4, Tag_objects(db).count())
	expect_queries(db, 1)
	assert_equal(-1, orm_bulk_create(db, Tag_desc(), tags, 0, 0))
	expect_queries(db, 1)
	assert1(strlen(orm_db_error(db)) > 0)
	Tag_free(dup)
	Tag_free(fresh)
	tags.free()
	# Upsert: existing email updates the name.
	Author* up = Author_new()
	up.name = c"Frank H."
	up.email = c"frank@example.com"
	list[void*] ups = new list[void*]
	ups.push(up)
	assert_equal(1, orm_bulk_create(db, Author_desc(), ups, 0, orm_conflict_update(names1(c"email"), names1(c"name"))))
	expect_queries(db, 1)
	assert_equal(d.frank.id, up.id)
	r = Author_objects(db).get(q_eq_int(c"id", d.frank.id))
	expect_queries(db, 1)
	assert_strings_equal(c"Frank H.", Author_rows(r)[0].name)
	orm_result_free(r)
	Author_free(up)
	ups.free()


void r_check_tags(orm_db* db, int book_id, char* name):
	list[char*] cols = names1(c"tags__name")
	orm_result* r = Book_objects(db).filter(q_eq_int(c"id", book_id)).values_list(cols).all()
	expect_queries(db, 1)
	assert_equal(1, r.rows.length)
	assert_strings_equal(name, orm_values_at(orm_values_rows(r)[0], 0))
	orm_result_free(r)
	cols.free()


void test_m2m(orm_db* db, e2e_data* d):
	list[void*] targets = new list[void*]
	targets.push(d.sf)
	targets.push(d.classic)
	assert_equal(2, orm_m2m_add(db, Book_desc(), d.dune, c"tags", targets))
	expect_queries(db, 1)
	# Adding an existing link is a no-op.
	assert_equal(0, orm_m2m_add(db, Book_desc(), d.dune, c"tags", targets))
	expect_queries(db, 1)
	list[void*] just_sf = new list[void*]
	just_sf.push(d.sf)
	list[void*] just_classic = new list[void*]
	just_classic.push(d.classic)
	assert_equal(1, orm_m2m_add(db, Book_desc(), d.messiah, c"tags", just_sf))
	expect_queries(db, 1)
	assert_equal(2, Book_objects(db).filter(q_eq(c"tags__name", c"sf")).count())
	expect_queries(db, 1)
	assert_equal(1, Book_objects(db).filter(q_eq(c"tags__name", c"classic")).count())
	expect_queries(db, 1)
	assert_equal(1, orm_m2m_remove(db, Book_desc(), d.dune, c"tags", just_classic))
	expect_queries(db, 1)
	assert_equal(0, Book_objects(db).filter(q_eq(c"tags__name", c"classic")).count())
	expect_queries(db, 1)
	list[void*] only_fantasy = new list[void*]
	only_fantasy.push(d.fantasy)
	assert1(orm_m2m_set(db, Book_desc(), d.dune, c"tags", only_fantasy))
	expect_queries(db, 2)
	r_check_tags(db, d.dune.id, c"fantasy")
	list[void*] none = new list[void*]
	assert1(orm_m2m_set(db, Book_desc(), d.dune, c"tags", none))
	expect_queries(db, 1)
	assert_equal(0, Book_objects(db).filter(q_and(q_eq_int(c"id", d.dune.id), q_isnull(c"tags", 0))).count())
	expect_queries(db, 1)
	assert_equal(-1, orm_m2m_add(db, Book_desc(), d.dune, c"author", targets))
	expect_queries(db, 0)
	targets.free()
	just_sf.free()
	just_classic.free()
	only_fantasy.free()
	none.free()


void test_errors_and_deletes(orm_db* db, e2e_data* d):
	# Constraint violations surface as save() failures.
	Book* bad = new_book(c"Orphan", d.frank, c"1.00", 1)
	bad.author_id = 999999
	assert_equal(0, Book_save(db, bad))
	expect_queries(db, 1)
	assert1(strlen(orm_db_error(db)) > 0)
	assert_equal(0, bad.id)
	bad.author_id = d.frank.id
	bad.price = c"-1"
	assert_equal(0, Book_save(db, bad))
	expect_queries(db, 1)
	Book_free(bad)
	# Unknown paths fail at compile time and run no statement.
	assert1(Book_objects(db).filter(q_eq(c"nope", c"x")).all() == 0)
	expect_queries(db, 0)
	assert_contains(orm_db_error(db), c"nope")
	# Queryset delete; the database cascades from authors to books.
	assert_equal(1, Author_objects(db).filter(q_eq(c"email", c"nobody@example.com")).delete())
	expect_queries(db, 1)
	assert_equal(1, Author_delete(db, d.ursula))
	expect_queries(db, 1)
	assert_equal(2, Book_objects(db).count())
	expect_queries(db, 1)
	assert_equal(0, Book_objects(db).filter(q_eq(c"title", c"A Wizard of Earthsea")).count())
	expect_queries(db, 1)
	assert_equal(-1, Author_delete(db, d.ursula))
	expect_queries(db, 0)
	assert_equal(2, Book_objects(db).delete())
	expect_queries(db, 1)
	assert_equal(0, Book_objects(db).exists())
	expect_queries(db, 1)


void test_for_update(orm_db* db):
	orm_result* r = Author_objects(db).for_update(1, 0).order_by(c"id").all()
	if (db.dialect.supports_for_update):
		expect_queries(db, 1)
		asserts(orm_db_error(db), r != 0)
		orm_result_free(r)
	else:
		expect_queries(db, 0)
		assert1(r == 0)
		assert_contains(orm_db_error(db), c"select_for_update")


# Runs every scenario on an open, empty database.
void orm_e2e_run(orm_db* db):
	library_register()
	db.log_queries = 1
	check(db, library_create_schema(db))
	__e2e_mark = db.query_count
	e2e_data d
	test_saves(db, &d)
	test_reads(db, &d)
	test_annotations(db, &d)
	test_updates(db, &d)
	test_create_helpers(db, &d)
	test_m2m(db, &d)
	test_for_update(db)
	test_errors_and_deletes(db, &d)
	orm_set_now(0)
	Author_free(d.frank)
	Author_free(d.ursula)
	Author_free(d.nobody)
	Tag_free(d.sf)
	Tag_free(d.classic)
	Tag_free(d.fantasy)
	Book_free(d.dune)
	Book_free(d.messiah)
	Book_free(d.earthsea)
