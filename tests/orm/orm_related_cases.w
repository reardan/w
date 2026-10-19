# prefetch_related, explicit loaders and iterator() over the library
# fixture (unit U2.1, docs/projects/orm/u2_1.md). Shared by
# tests/orm/orm_related_test.w (SQLite) and orm_relations_postgres_test.w.
# Every evaluation asserts the exact number of statements it ran.
import tests.orm.orm_e2e_cases


# Generated-style explicit loaders (the shape bin/orm_gen emits).
orm_result* Book_load_author(orm_db* db, Book* row): return orm_load_related(db, Book_desc(), row, c"author")
orm_result* Book_load_tags(orm_db* db, Book* row): return orm_load_related(db, Book_desc(), row, c"tags")
orm_result* Author_load_books(orm_db* db, Author* row): return orm_load_related(db, Author_desc(), row, c"books")


struct rel_data:
	Author* frank
	Author* ursula
	Author* nobody
	Tag* sf
	Tag* classic
	Tag* fantasy
	list[void*] books        # dune, messiah, children, earthsea, tombs


Book* rel_book(rel_data* d, int i):
	return cast(Book*, d.books[i])


Tag* rel_tag(orm_db* db, char* name):
	Tag* t = Tag_new()
	t.name = name
	check(db, Tag_save(db, t))
	return t


void rel_link(orm_db* db, Book* b, Tag* t1, Tag* t2):
	list[void*] l = new list[void*]
	if (t1 != 0): l.push(t1)
	if (t2 != 0): l.push(t2)
	assert_equal(l.length, orm_m2m_add(db, Book_desc(), b, c"tags", l))
	l.free()


# frank: Dune [sf, classic], Dune Messiah [sf], Children of Dune [];
# ursula: A Wizard of Earthsea [fantasy, classic], The Tombs of Atuan [fantasy];
# nobody: no books.
void rel_setup(orm_db* db, rel_data* d):
	orm_set_now(c"2026-10-19 12:00:00")
	d.frank = make_author(db, c"Frank Herbert", c"frank@example.com")
	d.ursula = make_author(db, c"Ursula K. Le Guin", c"ursula@example.com")
	d.nobody = make_author(db, c"Nobody", c"nobody@example.com")
	d.sf = rel_tag(db, c"sf")
	d.classic = rel_tag(db, c"classic")
	d.fantasy = rel_tag(db, c"fantasy")
	d.books = new list[void*]
	d.books.push(new_book(c"Dune", d.frank, c"9.99", 412))
	d.books.push(new_book(c"Dune Messiah", d.frank, c"12.50", 256))
	d.books.push(new_book(c"Children of Dune", d.frank, c"8.00", 444))
	d.books.push(new_book(c"A Wizard of Earthsea", d.ursula, c"7.00", 183))
	d.books.push(new_book(c"The Tombs of Atuan", d.ursula, c"7.50", 180))
	rel_book(d, 1).status = c"pub"
	rel_book(d, 4).status = c"pub"
	assert_equal(5, orm_bulk_create(db, Book_desc(), d.books, 0, 0))
	rel_link(db, rel_book(d, 0), d.sf, d.classic)
	rel_link(db, rel_book(d, 1), d.sf, 0)
	rel_link(db, rel_book(d, 3), d.fantasy, d.classic)
	rel_link(db, rel_book(d, 4), d.fantasy, 0)
	__e2e_mark = db.query_count


char* tag_names(list[void*] tags):
	string_builder* b = string_new()
	for void* x in tags:
		Tag* t = cast(Tag*, x)
		if (b.length > 0): string_append(b, c",")
		string_append(b, t.name)
	char* out = strclone(b.data)
	string_free(b)
	return out


void expect_tags(char* want, list[void*] tags):
	char* got = tag_names(tags)
	assert_strings_equal(want, got)
	free(got)


char* book_titles(list[void*] books):
	string_builder* b = string_new()
	for void* x in books:
		Book* bk = cast(Book*, x)
		if (b.length > 0): string_append(b, c",")
		string_append(b, bk.title)
	char* out = strclone(b.data)
	string_free(b)
	return out


void expect_titles(char* want, list[void*] books):
	char* got = book_titles(books)
	assert_strings_equal(want, got)
	free(got)


void test_select_and_prefetch_counts(orm_db* db, rel_data* d):
	# N books with select_related(author): one query.
	orm_result* r = Book_objects(db).select_related(c"author").order_by(c"id").all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	assert_equal(5, r.rows.length)
	for Book* b in Book_rows(r):
		assert1(b.author != 0)
		assert_equal(b.author_id, b.author.id)
	assert_strings_equal(c"Ursula K. Le Guin", Book_rows(r)[4].author.name)
	orm_result_free(r)
	# prefetch_related("tags"): the books plus one IN query over the links.
	r = Book_objects(db).prefetch_related(c"tags").order_by(c"id").all()
	expect_queries(db, 2)
	asserts(orm_db_error(db), r != 0)
	list[Book*] books = Book_rows(r)
	expect_tags(c"sf,classic", books[0].tags)
	expect_tags(c"sf", books[1].tags)
	expect_tags(c"", books[2].tags)
	expect_tags(c"classic,fantasy", books[3].tags)
	assert_equal(1, Book_tags(books[4]).length)
	expect_tags(c"fantasy", books[4].tags)
	assert1(books[0].author == 0)
	orm_result_free(r)
	# Authors -> books -> tags: three queries, back pointers set.
	r = Author_objects(db).prefetch_related(c"books__tags").order_by(c"id").all()
	expect_queries(db, 3)
	asserts(orm_db_error(db), r != 0)
	list[Author*] authors = Author_rows(r)
	assert_equal(3, authors.length)
	expect_titles(c"Dune,Dune Messiah,Children of Dune", authors[0].books)
	expect_titles(c"A Wizard of Earthsea,The Tombs of Atuan", authors[1].books)
	expect_titles(c"", authors[2].books)
	for Author* a in authors:
		for Book* b in Author_books(a):
			assert1(b.author == a)
	expect_tags(c"sf,classic", Author_books(authors[0])[0].tags)
	expect_tags(c"classic,fantasy", Author_books(authors[1])[0].tags)
	orm_result_free(r)
	# "books" then "books__tags": the shared hop runs once.
	r = Author_objects(db).prefetch_related(c"books").prefetch_related(c"books__tags").all()
	expect_queries(db, 3)
	orm_result_free(r)
	# Forward FK prefetch: two queries; skipped when select_related loaded it.
	r = Book_objects(db).prefetch_related(c"author").order_by(c"id").all()
	expect_queries(db, 2)
	assert_strings_equal(c"Frank Herbert", Book_rows(r)[0].author.name)
	assert1(Book_rows(r)[0].author != Book_rows(r)[3].author)
	assert1(Book_rows(r)[0].author == Book_rows(r)[1].author)
	orm_result_free(r)
	r = Book_objects(db).select_related(c"author").prefetch_related(c"author").all()
	expect_queries(db, 1)
	orm_result_free(r)
	# Multi-hop through a forward FK: books -> author -> books.
	r = Book_objects(db).filter(q_eq(c"title", c"Dune")).prefetch_related(c"author__books").all()
	expect_queries(db, 3)
	assert_equal(3, Book_rows(r)[0].author.books.length)
	orm_result_free(r)
	# first() and get() run the prefetch too.
	r = Book_objects(db).prefetch_related(c"tags").first()
	expect_queries(db, 2)
	expect_tags(c"sf,classic", Book_rows(r)[0].tags)
	orm_result_free(r)
	r = Book_objects(db).prefetch_related(c"tags").get(q_eq(c"title", c"A Wizard of Earthsea"))
	expect_queries(db, 2)
	expect_tags(c"classic,fantasy", Book_rows(r)[0].tags)
	orm_result_free(r)
	# No rows: no prefetch query.
	r = Book_objects(db).filter(q_eq(c"title", c"nope")).prefetch_related(c"tags").all()
	expect_queries(db, 1)
	assert_equal(0, r.rows.length)
	orm_result_free(r)
	# count()/exists() ignore prefetches.
	assert_equal(5, Book_objects(db).prefetch_related(c"tags").count())
	expect_queries(db, 1)


void test_prefetch_objects(orm_db* db, rel_data* d):
	# Custom queryset into the default slot: filtered and ordered.
	orm_queryset* newest = Book_objects(db).order_by(c"-id")
	orm_result* r = Author_objects(db).prefetch(orm_prefetch_new(c"books", newest, 0)).order_by(c"id").all()
	expect_queries(db, 2)
	expect_titles(c"Children of Dune,Dune Messiah,Dune", Author_rows(r)[0].books)
	orm_result_free(r)
	# to_attr: the slot stays empty, the list is read by name.
	orm_queryset* published = Book_objects(db).filter(q_eq(c"status", c"pub"))
	r = Author_objects(db).prefetch(orm_prefetch_new(c"books", published, c"published")).order_by(c"id").all()
	expect_queries(db, 2)
	list[Author*] authors = Author_rows(r)
	assert_equal(0, authors[0].books.length)
	expect_titles(c"Dune Messiah", orm_row_prefetched(Author_desc(), authors[0], c"published"))
	expect_titles(c"The Tombs of Atuan", orm_row_prefetched(Author_desc(), authors[1], c"published"))
	expect_titles(c"", orm_row_prefetched(Author_desc(), authors[2], c"published"))
	assert1(orm_row_prefetched(Author_desc(), authors[0], c"other") == 0)
	orm_result_free(r)
	# to_attr next to SQL annotations keeps both readable.
	r = Author_objects(db).annotate(c"n", agg_count(c"books")).prefetch(orm_prefetch_new(c"books", published, c"published")).order_by(c"id").all()
	expect_queries(db, 2)
	authors = Author_rows(r)
	assert_equal(3, orm_row_annotation_int(Author_desc(), authors[0], c"n", -1))
	assert_equal(2, orm_row_annotation_int(Author_desc(), authors[1], c"n", -1))
	assert_equal(1, orm_row_prefetched(Author_desc(), authors[1], c"published").length)
	orm_result_free(r)
	# to_attr on a forward FK and on an M2M (custom queryset on Tag).
	r = Book_objects(db).prefetch(orm_prefetch_new(c"author", 0, c"writer")).order_by(c"id").all()
	expect_queries(db, 2)
	list[void*] w = orm_row_prefetched(Book_desc(), r.rows[3], c"writer")
	assert_equal(1, w.length)
	Author* writer = cast(Author*, w[0])
	assert_strings_equal(c"Ursula K. Le Guin", writer.name)
	assert1(Book_rows(r)[3].author == 0)
	orm_result_free(r)
	orm_queryset* by_name = Tag_objects(db).filter(q_ne(c"name", c"sf")).order_by(c"name")
	r = Book_objects(db).prefetch(orm_prefetch_new(c"tags", by_name, c"other_tags")).order_by(c"id").all()
	expect_queries(db, 2)
	expect_tags(c"classic", orm_row_prefetched(Book_desc(), r.rows[0], c"other_tags"))
	expect_tags(c"classic,fantasy", orm_row_prefetched(Book_desc(), r.rows[3], c"other_tags"))
	assert_equal(0, Book_rows(r)[0].tags.length)
	orm_result_free(r)
	# A Prefetch queryset with its own prefetch_related: nested hop.
	orm_queryset* with_tags = Book_objects(db).prefetch_related(c"tags")
	r = Author_objects(db).prefetch(orm_prefetch_new(c"books", with_tags, 0)).order_by(c"id").all()
	expect_queries(db, 3)
	expect_tags(c"fantasy", Author_books(Author_rows(r)[1])[1].tags)
	orm_result_free(r)
	# A custom queryset with select_related joins inside the hop query.
	r = Author_objects(db).prefetch(orm_prefetch_new(c"books", Book_objects(db).select_related(c"author"), 0)).order_by(c"id").all()
	expect_queries(db, 2)
	assert_strings_equal(c"Frank Herbert", Author_books(Author_rows(r)[0])[0].author.name)
	orm_result_free(r)
	# Errors: not a relation, unknown name, wrong model, sliced queryset.
	assert1(Book_objects(db).prefetch_related(c"title").all() == 0)
	expect_queries(db, 1)
	assert_contains(orm_db_error(db), c"'title' is not a relation")
	assert1(Book_objects(db).prefetch_related(c"tags__nope").all() == 0)
	expect_queries(db, 2)
	assert_contains(orm_db_error(db), c"'nope' is not a relation")
	assert1(Author_objects(db).prefetch(orm_prefetch_new(c"books", Tag_objects(db), 0)).all() == 0)
	expect_queries(db, 1)
	assert_contains(orm_db_error(db), c"does not match")
	assert1(Author_objects(db).prefetch(orm_prefetch_new(c"books", Book_objects(db).limit(1), 0)).all() == 0)
	expect_queries(db, 1)
	assert_contains(orm_db_error(db), c"cannot be sliced")


void test_batches(orm_db* db, rel_data* d):
	# Two keys per IN query: 5 books -> 3 tag queries, same result.
	__orm_prefetch_batch = 2
	orm_result* r = Book_objects(db).prefetch_related(c"tags").order_by(c"id").all()
	expect_queries(db, 4)
	expect_tags(c"sf,classic", Book_rows(r)[0].tags)
	expect_tags(c"fantasy", Book_rows(r)[4].tags)
	orm_result_free(r)
	r = Book_objects(db).prefetch_related(c"author").all()
	expect_queries(db, 2)
	orm_result_free(r)
	__orm_prefetch_batch = 0
	assert1(orm_prefetch_batch_size(db) == db.dialect.max_params - 100)


void test_loaders(orm_db* db, rel_data* d):
	# prefetch_related_objects on rows from an earlier result.
	orm_result* r = Book_objects(db).order_by(c"id").all()
	expect_queries(db, 1)
	orm_result* owner = orm_prefetch_related_objects(db, Book_desc(), r.rows, c"author")
	expect_queries(db, 1)
	asserts(orm_db_error(db), owner != 0)
	assert_equal(0, owner.rows.length)
	assert_strings_equal(c"Frank Herbert", Book_rows(r)[2].author.name)
	orm_result* owner2 = orm_prefetch_related_objects(db, Book_desc(), r.rows, c"tags")
	expect_queries(db, 1)
	expect_tags(c"classic,fantasy", Book_rows(r)[3].tags)
	orm_result_free(owner2)
	orm_result_free(owner)
	orm_result_free(r)
	# ... and on heap rows (orm_row_new): the saved fixture rows.
	owner = orm_prefetch_related_objects(db, Book_desc(), d.books, c"tags")
	expect_queries(db, 1)
	expect_tags(c"sf,classic", rel_book(d, 0).tags)
	orm_result_free(owner)
	assert1(orm_prefetch_related_objects(db, Book_desc(), d.books, c"price") == 0)
	expect_queries(db, 0)
	# Explicit loaders: one query each, even when already loaded.
	Book* dune = rel_book(d, 0)
	owner = Book_load_author(db, dune)
	expect_queries(db, 1)
	assert_strings_equal(c"Frank Herbert", dune.author.name)
	orm_result* again = Book_load_author(db, dune)
	expect_queries(db, 1)
	orm_result_free(owner)
	owner = Book_load_tags(db, dune)
	expect_queries(db, 1)
	expect_tags(c"sf,classic", dune.tags)
	orm_result_free(owner)
	owner = Author_load_books(db, d.ursula)
	expect_queries(db, 1)
	expect_titles(c"A Wizard of Earthsea,The Tombs of Atuan", d.ursula.books)
	Book* first_book = cast(Book*, d.ursula.books[0])
	assert1(first_book.author == d.ursula)
	orm_result_free(owner)
	owner = Author_load_books(db, d.nobody)
	expect_queries(db, 1)
	assert_equal(0, d.nobody.books.length)
	orm_result_free(owner)
	assert1(orm_load_related(db, Book_desc(), dune, c"title") == 0)
	expect_queries(db, 0)
	assert_contains(orm_db_error(db), c"is not a relation")
	dune.author = 0
	orm_result_free(again)
	d.ursula.books.clear()
	for i in range(d.books.length): rel_book(d, i).tags.clear()


int rel_count_until_three(void* row, void* ctx):
	int* n = cast(int*, ctx)
	n[0] = n[0] + 1
	return n[0] < 3


void test_iterator(orm_db* db, rel_data* d):
	# Model rows, chunk of 2: one statement, rows in order.
	orm_iterator* it = Book_objects(db).select_related(c"author").order_by(c"id").iterator(2)
	expect_queries(db, 1)
	asserts(orm_db_error(db), it != 0)
	int n = 0
	Book* b = cast(Book*, it.next())
	while (b != 0):
		assert_equal(rel_book(d, n).id, b.id)
		assert1(b.author != 0)
		assert1(it.chunk.rows.length <= 2)
		n = n + 1
		b = cast(Book*, it.next())
	assert_equal(5, n)
	assert1(orm_iterator_failed(it) == 0)
	assert1(it.next() == 0)
	orm_iterator_free(it)
	expect_queries(db, 0)
	# values_list rows stream too.
	it = Book_objects(db).values_list(names1(c"title")).order_by(c"-id").iterator(0)
	expect_queries(db, 1)
	orm_values_row* v = cast(orm_values_row*, it.next())
	assert_strings_equal(c"The Tombs of Atuan", orm_values_at(v, 0))
	# An early free releases the connection.
	orm_iterator_free(it)
	assert_equal(5, Book_objects(db).count())
	expect_queries(db, 1)
	# Callback form; returning 0 stops.
	int seen = 0
	assert_equal(3, Book_objects(db).each(10, rel_count_until_three, &seen))
	expect_queries(db, 1)
	assert_equal(3, seen)
	# Errors: prefetch_related, a bad path.
	assert1(Book_objects(db).prefetch_related(c"tags").iterator(10) == 0)
	assert_contains(orm_db_error(db), c"prefetch_related")
	assert1(Book_objects(db).filter(q_eq(c"nope", c"1")).iterator(10) == 0)
	assert_contains(orm_db_error(db), c"nope")
	assert_equal(-1, Book_objects(db).filter(q_eq(c"nope", c"1")).each(10, rel_count_until_three, &seen))
	expect_queries(db, 0)


# More rows than the 100k collector limit: all() fails, iterator() streams
# them in bounded chunks.
void test_iterator_large(orm_db* db, char* fill_sql):
	check(db, orm_db_exec_sql(db, fill_sql))
	expect_queries(db, 1)
	orm_result* all = Tag_objects(db).all()
	expect_queries(db, 1)
	assert1(all == 0)
	orm_iterator* it = Tag_objects(db).order_by(c"id").iterator(5000)
	expect_queries(db, 1)
	asserts(orm_db_error(db), it != 0)
	int n = 0
	int last = 0
	Tag* t = cast(Tag*, it.next())
	while (t != 0):
		assert1(t.id > last)
		last = t.id
		n = n + 1
		t = cast(Tag*, it.next())
	asserts(orm_db_error(db), orm_iterator_failed(it) == 0)
	orm_iterator_free(it)
	assert_equal(120003, n)


void orm_related_run(orm_db* db, char* fill_sql):
	library_register()
	db.log_queries = 1
	check(db, library_create_schema(db))
	__e2e_mark = db.query_count
	rel_data d
	rel_setup(db, &d)
	test_select_and_prefetch_counts(db, &d)
	test_prefetch_objects(db, &d)
	test_batches(db, &d)
	test_loaders(db, &d)
	test_iterator(db, &d)
	db.log_queries = 0
	test_iterator_large(db, fill_sql)
	orm_set_now(0)
	for void* b in d.books: Book_free(cast(Book*, b))
	d.books.free()
	Author_free(d.frank)
	Author_free(d.ursula)
	Author_free(d.nobody)
	Tag_free(d.sf)
	Tag_free(d.classic)
	Tag_free(d.fantasy)
