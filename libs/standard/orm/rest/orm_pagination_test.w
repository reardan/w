# wbuild: arch_only=x64
# U3.4 pagination over the library fixture on SQLite in memory: page
# number and limit/offset (with count), cursor (keyset, no count) walked
# forwards and backwards across ordering ties (docs/projects/orm/u3_4.md).
import tests.orm.fixtures.library_orm_api
import tests.orm.fixtures.library_schema
import libs.standard.orm.rest.pagination
import lib.assert


int __mark


void expect_queries(orm_db* db, int n):
	if (db.query_count - __mark != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(db.query_count - __mark))
	assert_equal(n, db.query_count - __mark)
	__mark = db.query_count


void check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


void seed(orm_db* db):
	orm_set_now(c"2026-10-19 12:00:00")
	Author* a = Author_new()
	a.name = c"Anon"
	a.email = c"anon@example.com"
	check(db, Author_save(db, a))
	# Inserted out of price order so ids and prices disagree; ties on 5 and 7.
	char* titles = c"GCAEBFD"
	list[char*] prices = new list[char*]
	prices.push(c"12")
	prices.push(c"7")
	prices.push(c"5")
	prices.push(c"7")
	prices.push(c"5")
	prices.push(c"9")
	prices.push(c"7")
	for i in range(7):
		Book* b = Book_new()
		char* t = cast(char*, malloc(2))
		t[0] = titles[i]
		t[1] = 0
		b.title = t
		b.author_id = a.id
		b.price = prices[i]
		b.pages__isnull = 1
		check(db, Book_save(db, b))
	prices.free()


char* page_titles(orm_page* pg):
	string_builder* s = string_new()
	if (pg.result != 0):
		for Book* b in Book_rows(pg.result): string_append(s, b.title)
	char* out = s.data
	free(s)
	return out


void expect_page(orm_page* pg, char* want, int count, char* next, char* previous):
	if (pg.error != 0):
		print(c"page error: ")
		println(json_stringify(pg.error))
	assert1(pg.error == 0)
	assert_equal(200, pg.status)
	char* got = page_titles(pg)
	assert_strings_equal(want, got)
	free(got)
	assert_equal(count, pg.count)
	if (next == 0): asserts(c"no next link", pg.next == 0)
	else:
		asserts(c"next link", pg.next != 0)
		assert_strings_equal(next, pg.next)
	if (previous == 0): asserts(c"no previous link", pg.previous == 0)
	else:
		asserts(c"previous link", pg.previous != 0)
		assert_strings_equal(previous, pg.previous)


orm_page* page_of(orm_paginator* p, orm_db* db, char* query):
	orm_params* params = orm_params_parse(query)
	orm_page* pg = orm_paginate(p, Book_objects(db), params, c"/books")
	orm_params_free(params)
	return pg


void expect_error(orm_page* pg, int status, char* body):
	assert_equal(status, pg.status)
	asserts(c"page error", pg.error != 0)
	char* text = json_stringify(pg.error)
	assert_strings_equal(body, text)
	free(text)
	orm_page_free(pg)


void test_page_number(orm_db* db):
	orm_paginator* p = orm_paginator_page_number(3)
	__mark = db.query_count
	orm_page* pg = page_of(p, db, c"")
	expect_queries(db, 2)
	expect_page(pg, c"GCA", 7, c"/books?page=2", 0)
	orm_serializer* s = orm_serializer_new(Book_desc())
	list[char*] names = new list[char*]
	names.push(c"id")
	names.push(c"title")
	orm_serializer_include(s, names)
	names.free()
	char* body = orm_page_render(pg, s)
	assert_strings_equal(c"{\"count\":7,\"next\":\"/books?page=2\",\"previous\":null,\"results\":[{\"id\":1,\"title\":\"G\"},{\"id\":2,\"title\":\"C\"},{\"id\":3,\"title\":\"A\"}]}", body)
	free(body)
	orm_page_free(pg)
	# Other params are kept; page 2 links back to the bare URL.
	pg = page_of(p, db, c"status=draft&page=2")
	expect_page(pg, c"EBF", 7, c"/books?status=draft&page=3", c"/books?status=draft")
	orm_page_free(pg)
	pg = page_of(p, db, c"page=3")
	expect_page(pg, c"D", 7, 0, c"/books?page=2")
	orm_page_free(pg)
	pg = page_of(p, db, c"page=last")
	expect_page(pg, c"D", 7, 0, c"/books?page=2")
	orm_page_free(pg)
	expect_error(page_of(p, db, c"page=4"), 404, c"{\"detail\":\"Invalid page.\"}")
	expect_error(page_of(p, db, c"page=0"), 404, c"{\"detail\":\"Invalid page.\"}")
	expect_error(page_of(p, db, c"page=x"), 404, c"{\"detail\":\"Invalid page.\"}")
	# Client-chosen page size, capped.
	orm_paginator_client_size(p, c"page_size", 5)
	pg = page_of(p, db, c"page_size=50")
	expect_page(pg, c"GCAEB", 7, c"/books?page_size=50&page=2", 0)
	orm_page_free(pg)
	pg = page_of(p, db, c"page_size=-2")
	expect_page(pg, c"GCA", 7, c"/books?page_size=-2&page=2", 0)
	orm_page_free(pg)
	# An empty queryset has one empty page.
	orm_params* none = orm_params_parse(c"")
	pg = orm_paginate(p, Book_objects(db).filter(q_eq(c"title", c"zzz")), none, c"/books")
	expect_page(pg, c"", 0, 0, 0)
	orm_page_free(pg)
	orm_params_free(none)
	# A queryset ordering is kept, with the pk as tiebreaker.
	pg = orm_paginate(p, Book_objects(db).order_by(c"price"), 0, c"/books")
	expect_page(pg, c"ABC", 7, c"/books?page=2", 0)
	orm_page_free(pg)
	orm_serializer_free(s)
	orm_paginator_free(p)


void test_limit_offset(orm_db* db):
	orm_paginator* p = orm_paginator_limit_offset(3)
	__mark = db.query_count
	orm_page* pg = page_of(p, db, c"")
	expect_queries(db, 2)
	expect_page(pg, c"GCA", 7, c"/books?limit=3&offset=3", 0)
	orm_page_free(pg)
	pg = page_of(p, db, c"limit=3&offset=3")
	expect_page(pg, c"EBF", 7, c"/books?limit=3&offset=6", c"/books?limit=3")
	orm_page_free(pg)
	pg = page_of(p, db, c"offset=5&limit=2")
	expect_page(pg, c"FD", 7, 0, c"/books?offset=3&limit=2")
	orm_page_free(pg)
	pg = page_of(p, db, c"offset=1")
	expect_page(pg, c"CAE", 7, c"/books?offset=4&limit=3", c"/books?limit=3")
	orm_page_free(pg)
	pg = page_of(p, db, c"offset=-4&limit=junk")
	expect_page(pg, c"GCA", 7, c"/books?offset=3&limit=3", 0)
	orm_page_free(pg)
	orm_paginator_free(p)


# The query string of a link ("/books?x" -> "x").
char* link_query(char* link):
	int at = index_of(link, c"?")
	if (at < 0): return c""
	return link + at + 1


# Follows next links from the first page, then previous links back.
void walk(orm_db* db, orm_paginator* p, char* want_forward, char* want_back):
	string_builder* fwd = string_new()
	string_builder* back = string_new()
	char* query = strclone(c"")
	char* last = 0
	int pages = 0
	while (query != 0):
		__mark = db.query_count
		orm_page* pg = page_of(p, db, query)
		expect_queries(db, 1)
		assert1(pg.error == 0)
		assert_equal(-1, pg.count)
		if (pages == 0): asserts(c"first page has no previous", pg.previous == 0)
		else: asserts(c"later pages have a previous", pg.previous != 0)
		char* t = page_titles(pg)
		if (pages > 0): string_append_char(fwd, '/')
		string_append(fwd, t)
		free(t)
		free(query)
		query = 0
		if (pg.next != 0): query = strclone(link_query(pg.next))
		else if (pg.previous != 0): last = strclone(link_query(pg.previous))
		pages = pages + 1
		orm_page_free(pg)
	assert_strings_equal(want_forward, fwd.data)
	query = last
	int n = 0
	while (query != 0):
		orm_page* bp = page_of(p, db, query)
		assert1(bp.error == 0)
		asserts(c"pages before the last have a next", bp.next != 0)
		char* bt = page_titles(bp)
		if (n > 0): string_append_char(back, '/')
		string_append(back, bt)
		free(bt)
		free(query)
		query = 0
		if (bp.previous != 0): query = strclone(link_query(bp.previous))
		n = n + 1
		orm_page_free(bp)
	assert_strings_equal(want_back, back.data)
	string_free(fwd)
	string_free(back)


void test_cursor(orm_db* db):
	orm_paginator* p = orm_paginator_cursor(c"price", 3)
	walk(db, p, c"ABC/EDF/G", c"EDF/ABC")
	orm_paginator_free(p)
	p = orm_paginator_cursor(c"-price", 3)
	walk(db, p, c"GFD/ECB/A", c"ECB/GFD")
	orm_paginator_free(p)
	p = orm_paginator_cursor(0, 2)
	walk(db, p, c"GC/AE/BF/D", c"BF/AE/GC")
	orm_paginator_free(p)
	p = orm_paginator_cursor(c"-id", 4)
	walk(db, p, c"DFBE/ACG", c"DFBE")
	orm_paginator_free(p)
	# The envelope has no count; other params survive in the links.
	p = orm_paginator_cursor(c"price", 3)
	orm_page* pg = page_of(p, db, c"status=draft")
	orm_serializer* s = orm_serializer_new(Book_desc())
	list[char*] names = new list[char*]
	names.push(c"title")
	orm_serializer_include(s, names)
	names.free()
	char* body = orm_page_render(pg, s)
	assert_contains(body, c"{\"next\":\"/books?status=draft&cursor=")
	assert_contains(body, c"\",\"previous\":null,\"results\":[{\"title\":\"A\"},{\"title\":\"B\"},{\"title\":\"C\"}]}")
	free(body)
	# The cursor is opaque base64url of the boundary key and pk.
	char* token = strclone(link_query(pg.next) + strlen(c"status=draft&cursor="))
	orm_cursor* c = orm_cursor_decode(token, 1)
	asserts(c"cursor decodes", c != 0)
	assert_equal(0, c.reverse)
	assert_strings_equal(c"2", c.pk)
	assert_strings_equal(c"7.00", c.key)
	orm_cursor_free(c)
	free(token)
	orm_page_free(pg)
	expect_error(page_of(p, db, c"cursor=garbage"), 404, c"{\"detail\":\"Invalid cursor\"}")
	expect_error(page_of(p, db, c"cursor=Znx4fA"), 404, c"{\"detail\":\"Invalid cursor\"}")
	char* forged = orm_cursor_encode(0, c"x", c"1")
	char* q = orm_rest_concat(c"cursor=", forged)
	expect_error(page_of(p, db, q), 404, c"{\"detail\":\"Invalid cursor\"}")
	free(q)
	free(forged)
	# A cursor past the end gives an empty page linking back.
	char* end = orm_cursor_encode(0, c"99", c"99")
	q = orm_rest_concat(c"cursor=", end)
	pg = page_of(p, db, q)
	char* empty = page_titles(pg)
	assert_strings_equal(c"", empty)
	free(empty)
	assert1(pg.next == 0 && pg.previous != 0)
	orm_page_free(pg)
	free(q)
	free(end)
	orm_paginator_free(p)
	# Nullable ordering columns are refused.
	p = orm_paginator_cursor(c"pages", 3)
	expect_error(page_of(p, db, c""), 500, c"{\"detail\":\"Cursor pagination needs a non-null column to order by.\"}")
	orm_paginator_free(p)
	orm_serializer_free(s)


void test_with_filters(orm_db* db):
	orm_filter_set* fs = orm_filter_new(Book_desc())
	orm_filter_allow(fs, c"price", c"gte")
	orm_paginator* p = orm_paginator_cursor(c"price", 2)
	orm_paginator_client_size(p, c"size", 10)
	orm_paginator_reserve(p, fs)
	orm_params* params = orm_params_parse(c"price__gte=7&cursor=&size=3")
	json_value* errors = 0
	orm_queryset* qs = orm_filter_apply(fs, Book_objects(db), params, &errors)
	asserts(c"pagination params are reserved", qs != 0)
	orm_page* pg = orm_paginate(p, qs, params, c"/books")
	char* t = page_titles(pg)
	assert_strings_equal(c"CED", t)
	free(t)
	assert_contains(pg.next, c"/books?price__gte=7&cursor=")
	orm_page_free(pg)
	orm_params_free(params)
	orm_paginator_free(p)
	orm_filter_free(fs)
	fs = orm_filter_new(Book_desc())
	p = orm_paginator_page_number(2)
	orm_paginator_reserve(p, fs)
	params = orm_params_parse(c"page=2&cursor=x")
	qs = orm_filter_apply(fs, Book_objects(db), params, &errors)
	assert1(qs == 0)
	char* et = json_stringify(errors)
	assert_strings_equal(c"{\"cursor\":[\"Unknown filter parameter.\"]}", et)
	free(et)
	json_free(errors)
	orm_params_free(params)
	orm_paginator_free(p)
	orm_filter_free(fs)


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_pagination_test: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	library_register()
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	check(db, library_create_schema(db))
	seed(db)
	test_page_number(db)
	test_limit_offset(db)
	test_cursor(db)
	test_with_filters(db)
	orm_close(db)
	println(c"orm_pagination_test: OK")
	return 0
