# wbuild: arch_only=x64
# U3.4 serializers over the library fixture on SQLite in memory: output
# shapes and JSON types, declared relations (query counts), validation
# errors, and database integrity errors mapped to fields
# (docs/projects/orm/u3_4.md).
import tests.orm.fixtures.library_orm_api
import tests.orm.fixtures.library_schema
import libs.standard.orm.rest.serializer
import lib.assert


int __mark


void expect_queries(orm_db* db, int n):
	if (db.query_count - __mark != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(db.query_count - __mark))
		println(orm_db_error(db))
	assert_equal(n, db.query_count - __mark)
	__mark = db.query_count


void check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


void expect_json(char* want, json_value* got):
	char* text = json_stringify(got)
	if (strcmp(want, text) != 0):
		print(c"want: ")
		println(want)
		print(c"got:  ")
		println(text)
	assert_strings_equal(want, text)
	free(text)
	json_free(got)


void expect_text(char* want, char* got):
	if (strcmp(want, got) != 0):
		print(c"want: ")
		println(want)
		print(c"got:  ")
		println(got)
	assert_strings_equal(want, got)
	free(got)


void expect_errors(char* want, orm_validation* v):
	expect_text(want, orm_validation_errors_text(v))


struct fixture:
	Author* frank
	Author* ursula
	Tag* sf
	Tag* classic
	Book* dune
	Book* earthsea


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


Book* make_book(orm_db* db, char* title, Author* a, char* price, int pages):
	Book* b = Book_new()
	b.title = title
	b.author_id = a.id
	b.price = price
	if (pages < 0): b.pages__isnull = 1
	else: b.pages = pages
	check(db, Book_save(db, b))
	return b


void seed(orm_db* db, fixture* fx):
	orm_set_now(c"2026-10-19 12:00:00")
	fx.frank = make_author(db, c"Frank Herbert", c"frank@example.com")
	fx.ursula = make_author(db, c"Ursula K. Le Guin", c"ursula@example.com")
	fx.sf = make_tag(db, c"sf")
	fx.classic = make_tag(db, c"classic")
	fx.dune = make_book(db, c"Dune", fx.frank, c"9.99", 412)
	fx.earthsea = make_book(db, c"A Wizard of Earthsea", fx.ursula, c"7", -1)
	list[void*] tags = new list[void*]
	tags.push(fx.sf)
	tags.push(fx.classic)
	assert_equal(2, orm_m2m_add(db, Book_desc(), fx.dune, c"tags", tags))
	tags.free()
	__mark = db.query_count


# ---------------------------------------------------------------------------
# Output

json_value* title_length(void* ctx, void* row):
	Book* b = cast(Book*, row)
	int* calls = cast(int*, ctx)
	calls[0] = calls[0] + 1
	return json_int(strlen(b.title))


void test_output_defaults(orm_db* db, fixture* fx):
	orm_serializer* s = orm_serializer_new(Book_desc())
	assert1(orm_serializer_error(s) == 0)
	orm_result* r = orm_serializer_prepare(s, Book_objects(db)).order_by(c"id").all()
	expect_queries(db, 1)
	expect_text(c"[{\"id\":1,\"title\":\"Dune\",\"author\":1,\"status\":\"draft\",\"price\":\"9.99\",\"pages\":412,\"published_at\":null},{\"id\":2,\"title\":\"A Wizard of Earthsea\",\"author\":2,\"status\":\"draft\",\"price\":\"7.00\",\"pages\":null,\"published_at\":null}]", orm_serializer_render_result(s, r))
	# Decimals as numbers by option.
	orm_serializer_decimals_as_numbers(s, 1)
	expect_json(c"{\"id\":1,\"title\":\"Dune\",\"author\":1,\"status\":\"draft\",\"price\":9.99,\"pages\":412,\"published_at\":null}", orm_serializer_to_json(s, r.rows[0]))
	expect_json(c"{\"id\":2,\"title\":\"A Wizard of Earthsea\",\"author\":2,\"status\":\"draft\",\"price\":7.0,\"pages\":null,\"published_at\":null}", orm_serializer_to_json(s, r.rows[1]))
	orm_result_free(r)
	orm_serializer_free(s)
	# Authors: datetime text, unique text.
	orm_serializer* a = orm_serializer_new(Author_desc())
	r = Author_objects(db).filter(q_eq(c"name", c"Frank Herbert")).all()
	expect_queries(db, 1)
	expect_text(c"{\"id\":1,\"name\":\"Frank Herbert\",\"email\":\"frank@example.com\",\"created\":\"2026-10-19 12:00:00\"}", orm_serializer_render(a, r.rows[0]))
	orm_result_free(r)
	# include/exclude/rename/write-only.
	list[char*] names = new list[char*]
	names.push(c"email")
	names.push(c"name")
	names.push(c"id")
	orm_serializer_include(a, names)
	names.free()
	orm_serializer_rename(a, c"name", c"full_name")
	orm_serializer_write_only(a, c"email")
	r = Author_objects(db).order_by(c"id").all()
	expect_text(c"[{\"full_name\":\"Frank Herbert\",\"id\":1},{\"full_name\":\"Ursula K. Le Guin\",\"id\":2}]", orm_serializer_render_result(a, r))
	orm_result_free(r)
	orm_serializer_exclude(a, c"id")
	orm_serializer_exclude(a, c"nope")
	asserts(c"unknown field error", orm_serializer_error(a) != 0)
	assert_contains(orm_serializer_error(a), c"unknown field 'nope'")
	orm_serializer_free(a)
	__mark = db.query_count


void test_relations(orm_db* db, fixture* fx):
	# source across an FK + nested FK serializer: one JOINed query, no N+1.
	orm_serializer* author = orm_serializer_new(Author_desc())
	orm_serializer_exclude(author, c"created")
	orm_serializer_exclude(author, c"email")
	orm_serializer* s = orm_serializer_new(Book_desc())
	list[char*] names = new list[char*]
	names.push(c"id")
	names.push(c"title")
	names.push(c"author")
	orm_serializer_include(s, names)
	names.free()
	orm_serializer_source(s, c"author_name", c"author__name")
	orm_serializer_nested(s, c"author", author)
	int calls = 0
	orm_serializer_method(s, c"title_length", title_length, &calls)
	assert1(orm_serializer_error(s) == 0)
	list[char*] sel = orm_serializer_select_paths(s)
	assert_equal(1, sel.length)
	assert_strings_equal(c"author", sel[0])
	assert_equal(0, orm_serializer_prefetch_paths(s).length)
	orm_queryset* qs = orm_serializer_prepare(s, Book_objects(db)).order_by(c"id")
	assert_equal(1, qs.query.select_related.length)
	orm_result* r = qs.all()
	expect_queries(db, 1)
	expect_text(c"[{\"id\":1,\"title\":\"Dune\",\"author\":{\"id\":1,\"name\":\"Frank Herbert\"},\"author_name\":\"Frank Herbert\",\"title_length\":4},{\"id\":2,\"title\":\"A Wizard of Earthsea\",\"author\":{\"id\":2,\"name\":\"Ursula K. Le Guin\"},\"author_name\":\"Ursula K. Le Guin\",\"title_length\":20}]", orm_serializer_render_result(s, r))
	expect_queries(db, 0)
	assert_equal(2, calls)
	orm_result_free(r)
	# Without prepare the FK pointers are unloaded: nested and source are null.
	r = Book_objects(db).order_by(c"id").limit(1).all()
	expect_text(c"[{\"id\":1,\"title\":\"Dune\",\"author\":null,\"author_name\":null,\"title_length\":4}]", orm_serializer_render_result(s, r))
	orm_result_free(r)
	# A bad source path is a configuration error.
	orm_serializer_source(s, c"bad", c"tags__name")
	assert_contains(orm_serializer_error(s), c"may only follow foreign keys")
	orm_serializer_free(s)
	# Many relations: nested tags and author.books pks are prefetch paths.
	orm_serializer* tag = orm_serializer_new(Tag_desc())
	orm_serializer* bs = orm_serializer_new(Book_desc())
	orm_serializer_nested(bs, c"tags", tag)
	assert1(orm_serializer_error(bs) == 0)
	assert_strings_equal(c"tags", orm_serializer_prefetch_paths(bs)[0])
	orm_serializer* as = orm_serializer_new(Author_desc())
	orm_serializer_pk_list(as, c"books")
	list[char*] pf = orm_serializer_prefetch_paths(as)
	assert_equal(1, pf.length)
	assert_strings_equal(c"books", pf[0])
	orm_queryset* aq = orm_serializer_prepare(as, Author_objects(db))
	assert_equal(1, aq.query.prefetch.length)
	# Lists filled by hand (prefetch execution is U2.1's): output shapes.
	r = Book_objects(db).order_by(c"id").all()
	Book* dune = cast(Book*, r.rows[0])
	dune.tags.push(cast(void*, fx.sf))
	dune.tags.push(cast(void*, fx.classic))
	json_value* out = orm_serializer_to_json(bs, dune)
	json_value* tags_json = json_object_get(out, c"tags")
	assert_equal(2, json_array_length(tags_json))
	expect_json(c"{\"id\":1,\"name\":\"sf\"}", json_clone(json_array_get(tags_json, 0)))
	json_free(out)
	orm_serializer* pks = orm_serializer_new(Book_desc())
	orm_serializer_pk_list(pks, c"tags")
	assert_strings_equal(c"tags", orm_serializer_prefetch_paths(pks)[0])
	json_value* pj = orm_serializer_to_json(pks, dune)
	expect_json(c"[1,2]", json_clone(json_object_get(pj, c"tags")))
	json_free(pj)
	orm_result_free(r)
	# With U2.1's prefetch execution, prepare() fills the lists: one query
	# for the books plus one for the tags.
	__mark = db.query_count
	r = orm_serializer_prepare(bs, Book_objects(db)).order_by(c"id").all()
	expect_queries(db, 2)
	json_value* all_books = orm_serializer_result(bs, r)
	expect_json(c"[{\"id\":1,\"name\":\"sf\"},{\"id\":2,\"name\":\"classic\"}]", json_clone(json_object_get(json_array_get(all_books, 0), c"tags")))
	expect_json(c"[]", json_clone(json_object_get(json_array_get(all_books, 1), c"tags")))
	json_free(all_books)
	orm_result_free(r)
	orm_serializer* ap = orm_serializer_new(Author_desc())
	orm_serializer_pk_list(ap, c"books")
	orm_serializer_annotation(ap, c"prefetch:x", 0)
	assert_contains(orm_serializer_error(ap), c"prefetch to_attr")
	free(ap.error)
	ap.error = 0
	r = orm_serializer_prepare(ap, Author_objects(db)).order_by(c"id").all()
	expect_queries(db, 2)
	expect_json(c"[1]", json_clone(json_object_get(orm_serializer_to_json(ap, r.rows[0]), c"books")))
	orm_result_free(r)
	orm_serializer_free(ap)
	# Nested serializer of a nested many relation: the inner FK becomes a
	# prefetch path under the outer one.
	orm_serializer* inner = orm_serializer_new(Book_desc())
	orm_serializer_source(inner, c"author_email", c"author__email")
	orm_serializer* outer = orm_serializer_new(Author_desc())
	orm_serializer_nested(outer, c"books", inner)
	pf = orm_serializer_prefetch_paths(outer)
	assert_equal(2, pf.length)
	assert_strings_equal(c"books", pf[0])
	assert_strings_equal(c"books__author", pf[1])
	assert_equal(0, orm_serializer_select_paths(outer).length)
	orm_serializer_free(outer)
	orm_serializer_free(inner)
	orm_serializer_free(pks)
	orm_serializer_free(as)
	orm_serializer_free(bs)
	orm_serializer_free(tag)
	orm_serializer_free(author)
	__mark = db.query_count


void test_annotations(orm_db* db, fixture* fx):
	orm_serializer* s = orm_serializer_new(Author_desc())
	list[char*] names = new list[char*]
	names.push(c"name")
	orm_serializer_include(s, names)
	names.free()
	orm_serializer_annotation(s, c"n_books", ORM_INT)
	orm_serializer_annotation(s, c"shout", ORM_TEXT)
	orm_serializer_annotation(s, c"missing", 0)
	orm_result* r = orm_serializer_prepare(s, Author_objects(db)).annotate(c"n_books", agg_count(c"books")).annotate(c"shout", e_upper(f(c"name"))).order_by(c"id").all()
	expect_queries(db, 1)
	asserts(orm_db_error(db), r != 0)
	expect_text(c"[{\"name\":\"Frank Herbert\",\"n_books\":1,\"shout\":\"FRANK HERBERT\",\"missing\":null},{\"name\":\"Ursula K. Le Guin\",\"n_books\":1,\"shout\":\"URSULA K. LE GUIN\",\"missing\":null}]", orm_serializer_render_result(s, r))
	orm_result_free(r)
	orm_serializer_free(s)


# ---------------------------------------------------------------------------
# Input

char* no_draft_titles(void* ctx, json_value* v):
	if (v.type == json_type_string() && starts_with(v.string_value, c"Draft")): return c"Titles may not start with Draft."
	return 0


void pages_vs_price(void* ctx, void* vp):
	orm_validation* v = cast(orm_validation*, vp)
	char* pages = orm_validation_get(v, c"pages")
	char* title = orm_validation_get(v, c"title")
	if (pages != 0 && strcmp(pages, c"13") == 0 && title != 0 && strcmp(title, c"Unlucky") == 0):
		orm_validation_add_error(v, 0, c"Unlucky books may not have 13 pages.")


void test_validation(orm_db* db, fixture* fx):
	orm_serializer* s = orm_serializer_new(Book_desc())
	# Valid create: id and status ignored/defaulted, FK checked (1 query).
	orm_validation* v = orm_serializer_validate(s, db, c"{\"id\": 99, \"title\": \"Dune Messiah\", \"author\": 1, \"price\": \"12.5\", \"pages\": 256, \"published_at\": \"2026-01-02T03:04:05Z\"}", 0, 0)
	expect_queries(db, 1)
	expect_errors(c"{}", v)
	assert1(orm_validation_ok(v))
	Book* b = cast(Book*, v.row)
	assert_equal(0, b.id)
	assert_strings_equal(c"Dune Messiah", b.title)
	assert_equal(1, b.author_id)
	assert_strings_equal(c"2026-01-02 03:04:05", b.published_at)
	assert_equal(256, b.pages)
	assert1(orm_validation_save(v))
	expect_queries(db, 1)
	assert1(b.id > 0)
	assert_strings_equal(c"draft", b.status)
	int new_id = b.id
	orm_validation_free(v)
	assert_equal(1, Book_objects(db).filter(q_eq_int(c"id", new_id)).count())
	__mark = db.query_count
	# Field errors, all at once.
	v = orm_serializer_validate(s, db, c"{\"title\": \"\", \"author\": \"x\", \"status\": \"gone\", \"price\": \"123456.789\", \"pages\": \"many\", \"color\": \"red\"}", 0, 0)
	expect_queries(db, 0)
	assert_equal(400, v.status)
	expect_errors(c"{\"title\":[\"This field may not be blank.\"],\"author\":[\"Incorrect type. Expected pk value, received str.\"],\"status\":[\"\\\"gone\\\" is not a valid choice.\"],\"price\":[\"Ensure that there are no more than 8 digits in total.\"],\"pages\":[\"A valid integer is required.\"],\"color\":[\"Unknown field.\"]}", v)
	assert1(v.row == 0)
	orm_validation_free(v)
	v = orm_serializer_validate(s, db, c"{\"title\": 5, \"author\": 99, \"price\": \"1.234\", \"pages\": null, \"published_at\": \"yesterday\"}", 0, 0)
	expect_queries(db, 1)
	expect_errors(c"{\"title\":[\"Not a valid string.\"],\"author\":[\"Invalid pk \\\"99\\\" - object does not exist.\"],\"price\":[\"Ensure that there are no more than 2 decimal places.\"],\"published_at\":[\"Datetime has wrong format. Use YYYY-MM-DD HH:MM:SS.\"]}", v)
	orm_validation_free(v)
	v = orm_serializer_validate(s, db, c"{\"price\": \"1234567\", \"title\": null}", 0, 0)
	expect_errors(c"{\"price\":[\"Ensure that there are no more than 6 digits before the decimal point.\"],\"title\":[\"This field may not be null.\"],\"author\":[\"This field is required.\"]}", v)
	orm_validation_free(v)
	v = orm_serializer_validate(s, db, c"{\"title\": \"x\", \"author\": 1, \"price\": \"abc\"}", 0, 0)
	expect_errors(c"{\"price\":[\"A valid number is required.\"]}", v)
	orm_validation_free(v)
	# max_length counts characters, not bytes.
	orm_serializer* ts = orm_serializer_new(Tag_desc())
	v = orm_serializer_validate(ts, db, c"{\"name\": \"01234567890123456789012345678901234567890123456789x\"}", 0, 0)
	expect_errors(c"{\"name\":[\"Ensure this field has no more than 50 characters.\"]}", v)
	orm_validation_free(v)
	v = orm_serializer_validate(ts, db, c"{\"name\": \"\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\"}", 0, 0)
	expect_errors(c"{}", v)
	orm_validation_free(v)
	# Bad JSON and non-objects.
	v = orm_serializer_validate(ts, db, c"{nope", 0, 0)
	assert_equal(400, v.status)
	expect_errors(c"{\"detail\":\"JSON parse error.\"}", v)
	orm_validation_free(v)
	v = orm_serializer_validate(ts, db, c"[1]", 0, 0)
	expect_errors(c"{\"non_field_errors\":[\"Invalid data. Expected a dictionary, but got list.\"]}", v)
	orm_validation_free(v)
	# Unknown keys ignored by option.
	orm_serializer_unknown_fields(ts, ORM_SER_UNKNOWN_IGNORE)
	v = orm_serializer_validate(ts, db, c"{\"name\": \"new\", \"color\": 1}", 0, 0)
	expect_errors(c"{}", v)
	orm_validation_free(v)
	orm_serializer_free(ts)
	# Per-field and object-level validators.
	orm_serializer_field_validator(s, c"title", no_draft_titles, 0)
	orm_serializer_validator(s, pages_vs_price, 0)
	v = orm_serializer_validate(s, db, c"{\"title\": \"Draft one\", \"author\": 1, \"price\": \"1\"}", 0, 0)
	expect_errors(c"{\"title\":[\"Titles may not start with Draft.\"]}", v)
	orm_validation_free(v)
	v = orm_serializer_validate(s, db, c"{\"title\": \"Unlucky\", \"author\": 1, \"price\": \"1\", \"pages\": 13}", 0, 0)
	expect_errors(c"{\"non_field_errors\":[\"Unlucky books may not have 13 pages.\"]}", v)
	orm_validation_free(v)
	# PATCH an existing row: only the given fields change; the object
	# validator sees the instance's values for the rest.
	orm_result* r = Book_objects(db).filter(q_eq_int(c"id", fx.dune.id)).all()
	Book* dune = cast(Book*, r.rows[0])
	dune.title = c"Unlucky"
	v = orm_serializer_validate(s, db, c"{\"pages\": 13}", dune, 1)
	expect_errors(c"{\"non_field_errors\":[\"Unlucky books may not have 13 pages.\"]}", v)
	assert_equal(412, dune.pages)
	orm_validation_free(v)
	dune.title = c"Dune"
	__mark = db.query_count
	v = orm_serializer_validate(s, db, c"{\"pages\": 500, \"status\": \"pub\", \"author\": 2}", dune, 1)
	expect_queries(db, 1)
	expect_errors(c"{}", v)
	assert1(v.row == dune)
	assert_equal(500, dune.pages)
	assert_strings_equal(c"pub", dune.status)
	assert_equal(2, dune.author_id)
	assert1(orm_validation_save(v))
	expect_queries(db, 1)
	orm_validation_free(v)
	orm_result_free(r)
	r = Book_objects(db).select_related(c"author").filter(q_eq_int(c"id", fx.dune.id)).all()
	dune = cast(Book*, r.rows[0])
	assert_equal(500, dune.pages)
	assert_strings_equal(c"Ursula K. Le Guin", dune.author.name)
	# A PUT (not partial) still requires the required fields.
	v = orm_serializer_validate(s, db, c"{\"pages\": 1}", dune, 0)
	expect_errors(c"{\"title\":[\"This field is required.\"],\"author\":[\"This field is required.\"],\"price\":[\"This field is required.\"]}", v)
	orm_validation_free(v)
	# Nullable int set to null.
	v = orm_serializer_validate(s, db, c"{\"pages\": null}", dune, 1)
	expect_errors(c"{}", v)
	assert_equal(1, dune.pages__isnull)
	orm_validation_free(v)
	orm_result_free(r)
	# Read-only and write-only.
	orm_serializer* as = orm_serializer_new(Author_desc())
	orm_serializer_read_only(as, c"email")
	orm_serializer_write_only(as, c"name")
	v = orm_serializer_validate(as, db, c"{\"name\": \"Gene Wolfe\", \"email\": \"x\", \"created\": \"2000-01-01 00:00:00\"}", 0, 0)
	expect_errors(c"{}", v)
	Author* gene = cast(Author*, v.row)
	assert_strings_equal(c"Gene Wolfe", gene.name)
	assert1(gene.email == 0)
	assert1(gene.created == 0)
	orm_validation_free(v)
	orm_serializer_free(as)
	__mark = db.query_count


void test_integrity(orm_db* db, fixture* fx):
	orm_serializer* as = orm_serializer_new(Author_desc())
	orm_serializer_rename(as, c"email", c"mail")
	orm_validation* v = orm_serializer_validate(as, db, c"{\"name\": \"Frank 2\", \"mail\": \"frank@example.com\"}", 0, 0)
	expect_errors(c"{}", v)
	assert1(orm_validation_save(v) == 0)
	assert_equal(400, v.status)
	expect_errors(c"{\"mail\":[\"author with this email already exists.\"]}", v)
	orm_validation_free(v)
	# CHECK constraint: the one column the condition names.
	orm_serializer* s = orm_serializer_new(Book_desc())
	v = orm_serializer_validate(s, db, c"{\"title\": \"Negative\", \"author\": 1, \"price\": \"-1\"}", 0, 0)
	expect_errors(c"{}", v)
	assert1(orm_validation_save(v) == 0)
	expect_errors(c"{\"price\":[\"Constraint \\\"library_book_price_nonnegative\\\" is violated.\"]}", v)
	orm_validation_free(v)
	# FK target deleted between validation and save: SQLite names no
	# column, so the serializer probes the row's FKs.
	Author* gone = make_author(db, c"Gone", c"gone@example.com")
	char* body = orm_rest_concat3(c"{\"title\": \"Orphan\", \"price\": \"1\", \"author\": ", itoa(gone.id), c"}")
	v = orm_serializer_validate(s, db, body, 0, 0)
	expect_errors(c"{}", v)
	assert_equal(1, Author_delete(db, gone))
	assert1(orm_validation_save(v) == 0)
	assert_equal(400, v.status)
	assert_contains(orm_validation_errors_text(v), c"{\"author\":[\"Invalid pk \\\"")
	orm_validation_free(v)
	free(body)
	# NOT NULL from the database when the serializer does not require it.
	orm_serializer_required(s, c"title", 0)
	v = orm_serializer_validate(s, db, c"{\"author\": 1, \"price\": \"1\"}", 0, 0)
	expect_errors(c"{}", v)
	assert1(orm_validation_save(v) == 0)
	expect_errors(c"{\"title\":[\"This field may not be null.\"]}", v)
	orm_validation_free(v)
	# PostgreSQL messages (no server needed: the mapping is text-based).
	int st = 0
	json_value* e = orm_serializer_integrity_errors(db, as, 0, c"ERROR:  duplicate key value violates unique constraint \"library_author_email_key\"\nDETAIL:  Key (email)=(frank@example.com) already exists.\n", &st)
	assert_equal(400, st)
	expect_json(c"{\"mail\":[\"author with this email already exists.\"]}", e)
	e = orm_serializer_integrity_errors(db, s, 0, c"ERROR:  insert or update on table \"library_book\" violates foreign key constraint \"library_book_author_id_fkey\"\nDETAIL:  Key (author_id)=(77) is not present in table \"library_author\".\n", &st)
	expect_json(c"{\"author\":[\"Invalid pk \\\"77\\\" - object does not exist.\"]}", e)
	e = orm_serializer_integrity_errors(db, s, 0, c"ERROR:  null value in column \"title\" of relation \"library_book\" violates not-null constraint\n", &st)
	expect_json(c"{\"title\":[\"This field may not be null.\"]}", e)
	e = orm_serializer_integrity_errors(db, s, 0, c"ERROR:  new row for relation \"library_book\" violates check constraint \"library_book_price_nonnegative\"\n", &st)
	expect_json(c"{\"price\":[\"Constraint \\\"library_book_price_nonnegative\\\" is violated.\"]}", e)
	e = orm_serializer_integrity_errors(db, s, 0, c"UNIQUE constraint failed: library_book_tags.book_id, library_book_tags.tag_id", &st)
	expect_json(c"{\"non_field_errors\":[\"The fields book_id, tag_id must make a unique set.\"]}", e)
	e = orm_serializer_integrity_errors(db, s, 0, c"disk I/O error", &st)
	assert_equal(500, st)
	expect_json(c"{\"detail\":\"disk I/O error\"}", e)
	orm_serializer_free(s)
	orm_serializer_free(as)


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_serializer_test: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	library_register()
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	check(db, library_create_schema(db))
	fixture* fx = new fixture()
	seed(db, fx)
	test_output_defaults(db, fx)
	test_relations(db, fx)
	test_annotations(db, fx)
	test_validation(db, fx)
	test_integrity(db, fx)
	orm_close(db)
	println(c"orm_serializer_test: OK")
	return 0
