# wbuild: arch_only=x64
# U3.4 whitelisted query-parameter filtering over the library fixture on
# SQLite in memory (docs/projects/orm/u3_4.md).
import tests.orm.fixtures.library_orm_api
import tests.orm.fixtures.library_schema
import libs.standard.orm.rest.filter
import lib.assert


void check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


Author* make_author(orm_db* db, char* name, char* email):
	Author* a = Author_new()
	a.name = name
	a.email = email
	check(db, Author_save(db, a))
	return a


Tag* make_tag(orm_db* db, char* name):
	Tag* t = Tag_new()
	t.name = name
	check(db, Tag_save(db, t))
	return t


Book* make_book(orm_db* db, char* title, Author* a, char* price, int pages, char* status, Tag* t1, Tag* t2):
	Book* b = Book_new()
	b.title = title
	b.author_id = a.id
	b.price = price
	b.status = status
	if (pages < 0): b.pages__isnull = 1
	else: b.pages = pages
	check(db, Book_save(db, b))
	list[void*] tags = new list[void*]
	if (t1 != 0): tags.push(cast(void*, t1))
	if (t2 != 0): tags.push(cast(void*, t2))
	if (tags.length > 0): orm_m2m_add(db, Book_desc(), b, c"tags", tags)
	tags.free()
	return b


void seed(orm_db* db):
	orm_set_now(c"2026-10-19 12:00:00")
	Author* frank = make_author(db, c"Frank Herbert", c"frank@example.com")
	Author* ursula = make_author(db, c"Ursula K. Le Guin", c"ursula@example.com")
	Tag* sf = make_tag(db, c"sf")
	Tag* classic = make_tag(db, c"classic")
	Tag* fantasy = make_tag(db, c"fantasy")
	make_book(db, c"Dune", frank, c"9.99", 412, c"pub", sf, classic)
	make_book(db, c"Dune Messiah", frank, c"12.50", 256, c"pub", sf, 0)
	make_book(db, c"A Wizard of Earthsea", ursula, c"7", 183, c"draft", fantasy, classic)
	make_book(db, c"The Lathe of Heaven", ursula, c"15", -1, c"draft", sf, 0)


orm_filter_set* book_filters():
	orm_filter_set* fs = orm_filter_new(Book_desc())
	orm_filter_allow(fs, c"title", c"exact,icontains")
	orm_filter_allow(fs, c"price", c"exact,gte,lte,range")
	orm_filter_allow(fs, c"pages", c"exact,gt,isnull")
	orm_filter_allow(fs, c"status", c"exact,in")
	orm_filter_allow(fs, c"author", c"exact")
	orm_filter_allow(fs, c"author__name", c"icontains")
	orm_filter_allow(fs, c"tags__name", c"exact,in")
	orm_filter_ordering(fs, c"price")
	orm_filter_ordering(fs, c"title")
	orm_filter_ordering(fs, c"author__name")
	orm_filter_search(fs, c"title")
	orm_filter_search(fs, c"author__name")
	orm_filter_ignore(fs, c"page")
	asserts(c"filter set configured", orm_filter_error(fs) == 0)
	return fs


# Titles of the filtered books joined with '|' (ordered by id unless the
# params order them).
char* titles(orm_db* db, orm_filter_set* fs, char* query):
	orm_params* p = orm_params_parse(query)
	json_value* errors = 0
	orm_queryset* qs = orm_filter_apply(fs, Book_objects(db).order_by(c"id"), p, &errors)
	if (qs == 0):
		char* text = json_stringify(errors)
		json_free(errors)
		orm_params_free(p)
		return text
	assert1(errors == 0)
	orm_result* r = qs.all()
	asserts(orm_db_error(db), r != 0)
	string_builder* s = string_new()
	for Book* b in Book_rows(r):
		if (s.length > 0): string_append_char(s, '|')
		string_append(s, b.title)
	orm_result_free(r)
	orm_params_free(p)
	char* out = s.data
	free(s)
	return out


void expect(orm_db* db, orm_filter_set* fs, char* query, char* want):
	char* got = titles(db, fs, query)
	if (strcmp(want, got) != 0):
		print(c"query: ")
		println(query)
		print(c"want: ")
		println(want)
		print(c"got:  ")
		println(got)
	assert_strings_equal(want, got)
	free(got)


void test_params():
	orm_params* p = orm_params_parse(c"?a=1&b=x%20y+z&c&d=%zz&e=%26%3D")
	assert_equal(4, p.items.length)
	assert_strings_equal(c"1", orm_params_get(p, c"a"))
	assert_strings_equal(c"x y z", orm_params_get(p, c"b"))
	assert_strings_equal(c"", orm_params_get(p, c"c"))
	assert1(orm_params_get(p, c"d") == 0)
	assert_strings_equal(c"&=", orm_params_get(p, c"e"))
	orm_params_set(p, c"a", c"2")
	orm_params_set(p, c"c", 0)
	char* enc = orm_params_encode(p)
	assert_strings_equal(c"a=2&b=x%20y%20z&e=%26%3D", enc)
	free(enc)
	char* url = orm_params_url(c"/books", p)
	assert_strings_equal(c"/books?a=2&b=x%20y%20z&e=%26%3D", url)
	free(url)
	orm_params_free(p)
	orm_params* empty = orm_params_parse(c"")
	url = orm_params_url(c"/books", empty)
	assert_strings_equal(c"/books", url)
	free(url)
	orm_params_free(empty)


void test_filters(orm_db* db):
	orm_filter_set* fs = book_filters()
	expect(db, fs, c"", c"Dune|Dune Messiah|A Wizard of Earthsea|The Lathe of Heaven")
	expect(db, fs, c"title=Dune", c"Dune")
	expect(db, fs, c"title__icontains=DUNE", c"Dune|Dune Messiah")
	expect(db, fs, c"price__gte=10", c"Dune Messiah|The Lathe of Heaven")
	expect(db, fs, c"price__gte=8&price__lte=13", c"Dune|Dune Messiah")
	expect(db, fs, c"price__range=7,10", c"Dune|A Wizard of Earthsea")
	expect(db, fs, c"pages__gt=200", c"Dune|Dune Messiah")
	expect(db, fs, c"pages__isnull=true", c"The Lathe of Heaven")
	expect(db, fs, c"pages__isnull=false&status=draft", c"A Wizard of Earthsea")
	expect(db, fs, c"status__in=draft", c"A Wizard of Earthsea|The Lathe of Heaven")
	expect(db, fs, c"author=1", c"Dune|Dune Messiah")
	expect(db, fs, c"author__name__icontains=ursula", c"A Wizard of Earthsea|The Lathe of Heaven")
	expect(db, fs, c"tags__name=classic", c"Dune|A Wizard of Earthsea")
	# Multi-valued paths are distinct: Earthsea has both tags but appears once.
	expect(db, fs, c"tags__name__in=fantasy,classic", c"Dune|A Wizard of Earthsea")
	orm_params* p = orm_params_parse(c"tags__name__in=fantasy,classic")
	json_value* errors = 0
	orm_queryset* qs = orm_filter_apply(fs, Book_objects(db), p, &errors)
	assert1(qs.query.distinct)
	assert_equal(2, qs.count())
	orm_params_free(p)
	# Empty values and reserved params are ignored.
	expect(db, fs, c"title=&page=3", c"Dune|Dune Messiah|A Wizard of Earthsea|The Lathe of Heaven")
	# Ordering (replaces the queryset's ordering) and search.
	expect(db, fs, c"ordering=-price", c"The Lathe of Heaven|Dune Messiah|Dune|A Wizard of Earthsea")
	expect(db, fs, c"ordering=author__name,-title", c"Dune Messiah|Dune|The Lathe of Heaven|A Wizard of Earthsea")
	expect(db, fs, c"search=dune", c"Dune|Dune Messiah")
	expect(db, fs, c"search=dune+messiah", c"Dune Messiah")
	expect(db, fs, c"search=ursula", c"A Wizard of Earthsea|The Lathe of Heaven")
	expect(db, fs, c"search=heaven,ursula&ordering=title", c"The Lathe of Heaven")
	# Errors: unknown params, lookups not allowed, bad values, bad ordering.
	expect(db, fs, c"color=red", c"{\"color\":[\"Unknown filter parameter.\"]}")
	expect(db, fs, c"price__lt=3", c"{\"price__lt\":[\"Lookup \\\"lt\\\" is not allowed for this field.\"]}")
	expect(db, fs, c"title__startswith=D", c"{\"title__startswith\":[\"Lookup \\\"startswith\\\" is not allowed for this field.\"]}")
	expect(db, fs, c"author__email=x", c"{\"author__email\":[\"Unknown filter parameter.\"]}")
	expect(db, fs, c"price__gte=abc&pages=x", c"{\"price__gte\":[\"Enter a number.\"],\"pages\":[\"Enter a whole number.\"]}")
	expect(db, fs, c"pages__isnull=maybe", c"{\"pages__isnull\":[\"Enter a valid boolean.\"]}")
	expect(db, fs, c"status=gone", c"{\"status\":[\"Select a valid choice. gone is not one of the available choices.\"]}")
	expect(db, fs, c"status__in=pub,gone", c"{\"status__in\":[\"Select a valid choice. gone is not one of the available choices.\"]}")
	expect(db, fs, c"price__range=1", c"{\"price__range\":[\"Enter two values separated by a comma.\"]}")
	expect(db, fs, c"ordering=pages", c"{\"ordering\":[\"Invalid ordering field \\\"pages\\\".\"]}")
	orm_filter_free(fs)
	# Configuration errors surface as {"detail": ...}.
	orm_filter_set* bad = orm_filter_new(Book_desc())
	orm_filter_allow(bad, c"nope", c"exact")
	orm_filter_allow(bad, c"title", c"bogus")
	assert_contains(orm_filter_error(bad), c"'nope' is not a field path")
	expect(db, bad, c"title=x", c"{\"detail\":\"filter: 'nope' is not a field path\"}")
	orm_filter_free(bad)
	orm_filter_set* bad2 = orm_filter_new(Book_desc())
	orm_filter_ordering(bad2, c"tags__name")
	assert_contains(orm_filter_error(bad2), c"single-valued")
	orm_filter_search(bad2, c"pages")
	orm_filter_free(bad2)
	# Without ordering fields, ?ordering is an unknown parameter.
	orm_filter_set* plain = orm_filter_new(Book_desc())
	expect(db, plain, c"ordering=title", c"{\"ordering\":[\"Unknown filter parameter.\"]}")
	orm_params* out = 0
	json_value* errs = 0
	orm_queryset* q2 = orm_filter_apply_query(plain, Book_objects(db), c"", &out, &errs)
	assert_equal(4, q2.count())
	orm_params_free(out)
	orm_filter_free(plain)


int main():
	test_params()
	if (sql_sqlite_available() == 0):
		println(c"orm_rest_filter_test: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	library_register()
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	check(db, library_create_schema(db))
	seed(db)
	test_filters(db)
	orm_close(db)
	println(c"orm_rest_filter_test: OK")
	return 0
