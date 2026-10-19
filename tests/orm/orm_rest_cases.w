# Viewset, routing, permission and throttle scenarios (unit U4.1,
# docs/projects/orm/u4_1.md), shared by libs/standard/orm/rest/orm_rest_test.w
# (SQLite) and orm_rest_postgres_test.w. Requests go through
# orm_rest_router_dispatch in process (orm_rest_request_build); the SQLite
# test also serves one router over a real http_server socket.
#
# The library schema (with library_book_history) comes from the migration
# orm_makemigrations plans for the generated snapshot, the auth and session
# tables from hand DDL (tests/orm/orm_session_cases.w).
import tests.orm.generated.library_orm_api
import tests.orm.orm_session_cases
import libs.standard.orm.rest.viewset
import libs.standard.orm.migrate.apply
import libs.standard.orm.migrate.autodetect


orm_db* __rest_db
orm_rest_router* __rest_rt
int __rest_mark
int __rest_ms


struct rest_fixture:
	User* admin
	User* alice
	User* bob
	char* admin_tok
	char* alice_tok
	char* bob_tok
	Author* a1
	Author* a2
	Book* b1                   # Alpha, a1, pub
	Book* b2                   # Beta, a1, draft
	Book* b3                   # Gamma, a2, pub
	Tag* t1                    # public-news
	Tag* t2                    # secret
	orm_viewset* books
	orm_viewset* authors
	orm_viewset* tags
	orm_viewset* catalog
	orm_throttle* tag_throttle


rest_fixture* __rest


int rest_clock_ms():
	return __rest_ms


void rest_check(int ok):
	asserts(orm_db_error(__rest_db), ok)


void rest_mark():
	__rest_mark = __rest_db.query_count


void rest_expect_queries(int n):
	int got = __rest_db.query_count - __rest_mark
	if (got != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(got))
	assert_equal(n, got)
	__rest_mark = __rest_db.query_count


char* rest_int_text(int v):
	return itoa(v)


# s with every "@1".."@9" replaced by the matching argument of ids.
char* rest_fmt(char* s, list[int] ids):
	string_builder* b = string_new()
	int i = 0
	while (s[i] != 0):
		if (s[i] == '@' && s[i + 1] >= '1' && s[i + 1] <= '9'):
			string_append_int(b, ids[s[i + 1] - '1'])
			i = i + 2
			continue
		string_append_char(b, s[i])
		i = i + 1
	char* out = b.data
	free(b)
	return out


list[int] rest_ids():
	list[int] l = new list[int]
	l.push(__rest.b1.id)
	l.push(__rest.b2.id)
	l.push(__rest.b3.id)
	l.push(__rest.a1.id)
	l.push(__rest.a2.id)
	l.push(__rest.t1.id)
	l.push(__rest.t2.id)
	return l


# s with @1..@7 = b1, b2, b3, a1, a2, t1, t2 ids.
char* rest_f(char* s):
	list[int] l = rest_ids()
	char* out = rest_fmt(s, l)
	l.free()
	return out


ServerRequest* rest_req(char* method, char* target, char* body):
	char* t = rest_f(target)
	char* b = 0
	if (body != 0): b = rest_f(body)
	ServerRequest* req = orm_rest_request_build(method, t, b)
	orm_rest_request_header(req, c"Host", c"api.example.org")
	free(t)
	if (b != 0): free(b)
	return req


void rest_token(ServerRequest* req, char* raw):
	char* v = orm_rest_concat(c"Token ", raw)
	orm_rest_request_header(req, c"Authorization", v)
	free(v)


ServerResponse* rest_send(ServerRequest* req):
	ServerResponse* resp = orm_rest_router_dispatch(__rest_rt, req)
	server_request_free(req)
	return resp


# Asserts status and (when want != 0) the exact body, @n expanded; frees resp.
void rest_expect(ServerResponse* resp, int status, char* want):
	char* body = resp.body
	if (body == 0): body = c""
	char* w = 0
	if (want != 0): w = rest_f(want)
	if (resp.status != status || (w != 0 && strcmp(w, body) != 0)):
		print(c"status: ")
		println(itoa(resp.status))
		print(c"body: ")
		println(body)
	assert_equal(status, resp.status)
	if (w != 0):
		assert_strings_equal(w, body)
		free(w)
	server_response_free(resp)


void rest_expect_header(ServerResponse* resp, char* name, char* want):
	char* got = server_response_get_header(resp, name)
	if (want == 0):
		asserts(name, got == 0)
		return
	asserts(name, got != 0)
	assert_strings_equal(want, got)


ServerResponse* rest_call(char* method, char* target, char* body, char* token):
	ServerRequest* req = rest_req(method, target, body)
	if (token != 0): rest_token(req, token)
	return rest_send(req)


# ---------------------------------------------------------------------------
# Schema and data

void rest_schema(orm_db* db):
	rest_check(sess_create_schema(db))
	int dialect = orm_mx_dialect_of(db)
	orm_makemig* r = orm_makemigrations(c"library", 0, library_schema_json(), dialect, 1, 0, 0)
	asserts(r.error, r.error == 0)
	int n = orm_migrate_apply(db, r.migrations, 0)
	if (n != 1): println(orm_db_error(db))
	assert_equal(1, n)


Author* rest_author(char* name, char* email):
	Author* a = Author_new()
	a.name = name
	a.email = email
	rest_check(Author_save(__rest_db, a))
	return a


Book* rest_book(char* title, Author* a, char* status, char* price):
	Book* b = Book_new()
	b.title = title
	b.author_id = a.id
	b.status = status
	b.price = price
	b.pages__isnull = 1
	b.published_at = 0
	rest_check(Book_save(__rest_db, b))
	return b


Tag* rest_tag(char* name):
	Tag* t = Tag_new()
	t.name = name
	rest_check(Tag_save(__rest_db, t))
	return t


void rest_grant(User* u, char* perm):
	Permission* p = permission_get(__rest_db, perm)
	asserts(perm, p != 0)
	rest_check(user_add_permission(__rest_db, u, p))


void rest_seed(orm_db* db):
	rest_fixture* f = __rest
	orm_set_now(c"2026-10-19 12:00:00")
	f.admin = create_superuser(db, c"admin", c"admin@example.com", c"pw-admin")
	f.alice = create_user(db, c"alice", c"alice@example.com", c"pw-alice")
	f.bob = create_user(db, c"bob", c"bob@example.com", c"pw-bob")
	asserts(orm_db_error(db), f.admin != 0 && f.alice != 0 && f.bob != 0)
	f.a1 = rest_author(c"Alice Author", c"alice@example.com")
	f.a2 = rest_author(c"Bob Author", c"bob@example.com")
	f.b1 = rest_book(c"Alpha", f.a1, c"pub", c"10.00")
	f.b2 = rest_book(c"Beta", f.a1, c"draft", c"20.00")
	f.b3 = rest_book(c"Gamma", f.a2, c"pub", c"5.00")
	f.t1 = rest_tag(c"public-news")
	f.t2 = rest_tag(c"secret")
	assert1(orm_auth_create_model_permissions(db, Book_desc()) >= 0)
	assert1(orm_auth_create_model_permissions(db, Author_desc()) >= 0)
	assert1(orm_auth_create_model_permissions(db, Tag_desc()) >= 0)
	rest_grant(f.alice, c"library.add_book")
	rest_grant(f.alice, c"library.change_book")
	rest_grant(f.alice, c"library.add_author")
	rest_grant(f.alice, c"library.change_author")
	rest_grant(f.alice, c"library.view_tag")
	rest_grant(f.alice, c"library.change_tag")
	rest_grant(f.bob, c"library.view_tag")
	f.admin_tok = token_create(db, f.admin.id, c"cli", 0)
	f.alice_tok = token_create(db, f.alice.id, c"cli", 0)
	f.bob_tok = token_create(db, f.bob.id, c"cli", 0)
	asserts(orm_db_error(db), f.admin_tok != 0 && f.alice_tok != 0 && f.bob_tok != 0)


# ---------------------------------------------------------------------------
# Viewsets

# Staff see every book, users the books of the author sharing their
# email, anonymous visitors published books only.
orm_queryset* rest_books_qs(orm_rest_request* r, void* ctx):
	orm_queryset* qs = Book_objects(r.db)
	if (r.user == 0): return qs.filter(q_eq(c"status", c"pub"))
	if (r.user.is_staff): return qs
	return qs.filter(q_eq(c"author__email", r.user.email))


int rest_books_on_save(orm_rest_request* r, void* row, void* ctx):
	Book* b = cast(Book*, row)
	if (strcmp(b.title, c"Forbidden") == 0):
		orm_rest_fail(r, 400, c"Title not allowed.")
		return 0
	return 1


ServerResponse* rest_books_stats(orm_rest_request* r, void* obj, void* ctx):
	orm_rest_request* rr = r
	orm_viewset* vs = cast(orm_viewset*, rr.viewset)
	ServerResponse* resp = 0
	orm_queryset* qs = orm_rest_queryset(vs, rr, &resp)
	if (qs == 0): return resp
	json_value* o = json_object()
	json_object_set(o, c"visible", json_int(qs.count()))
	return orm_rest_response(200, o)


ServerResponse* rest_books_publish(orm_rest_request* r, void* obj, void* ctx):
	Book* b = cast(Book*, obj)
	b.status = c"pub"
	list[char*] fields = new list[char*]
	fields.push(c"status")
	int ok = orm_save_fields(r.db, Book_desc(), obj, fields)
	fields.free()
	if (ok == 0): return 0
	json_value* o = json_object()
	json_object_set(o, c"id", json_int(b.id))
	json_object_set(o, c"status", json_string(b.status))
	return orm_rest_response(200, o)


orm_viewset* rest_books_viewset(orm_db* db):
	orm_serializer* ser = orm_serializer_new(Book_desc())
	orm_serializer_exclude(ser, c"published_at")
	orm_serializer_source(ser, c"author_name", c"author__name")
	orm_filter_set* fs = orm_filter_new(Book_desc())
	orm_filter_allow(fs, c"status", c"exact")
	orm_filter_allow(fs, c"title", c"icontains")
	orm_filter_ordering(fs, c"price")
	orm_filter_ordering(fs, c"title")
	orm_viewset* vs = orm_viewset_new(Book_desc(), db, rest_books_qs, 0)
	orm_viewset_serializer(vs, ser)
	orm_viewset_filter(vs, fs)
	orm_viewset_paginator(vs, orm_paginator_page_number(2))
	orm_viewset_clear_authenticators(vs)
	orm_viewset_authenticator(vs, orm_auth_token())
	orm_viewset_authenticator(vs, orm_auth_session(0))
	orm_viewset_permission(vs, orm_perm_django_model_permissions_or_anon_read_only())
	orm_viewset_history(vs, orm_rest_history_json, 0)
	orm_viewset_hooks(vs, rest_books_on_save, 0, 0)
	orm_viewset_action(vs, c"stats", c"GET", 0, rest_books_stats, 0)
	orm_rest_action* pub = orm_viewset_action(vs, c"publish", c"post", 1, rest_books_publish, 0)
	orm_rest_action_permission(pub, orm_perm_is_admin_user())
	return vs


orm_queryset* rest_all_authors(orm_rest_request* r, void* ctx):
	return Author_objects(r.db)


orm_queryset* rest_all_tags(orm_rest_request* r, void* ctx):
	return Tag_objects(r.db)


# Object permissions (U3.1 hook): an author's change permission belongs
# to the user with the same email; public-* tags are viewable.
int rest_obj_hook(orm_db* db, void* user, char* perm, orm_model_desc* m, void* obj):
	User* u = cast(User*, user)
	if (m == Author_desc() && strcmp(perm, c"library.change_author") == 0):
		Author* a = cast(Author*, obj)
		if (strcmp(a.email, u.email) == 0): return 1
		return 0
	if (m == Tag_desc() && strcmp(perm, c"library.view_tag") == 0):
		Tag* t = cast(Tag*, obj)
		if (starts_with(t.name, c"public")): return 1
	return 0


orm_viewset* rest_authors_viewset(orm_db* db):
	orm_viewset* vs = orm_viewset_new(Author_desc(), db, rest_all_authors, 0)
	orm_serializer_exclude(vs.serializer, c"created")
	orm_viewset_clear_authenticators(vs)
	orm_viewset_authenticator(vs, orm_auth_session(0))
	orm_viewset_permission(vs, orm_perm_and(orm_perm_is_authenticated(), orm_perm_django_object_permissions()))
	return vs


orm_viewset* rest_tags_viewset(orm_db* db):
	orm_viewset* vs = orm_viewset_new(Tag_desc(), db, rest_all_tags, 0)
	orm_viewset_clear_authenticators(vs)
	orm_viewset_authenticator(vs, orm_auth_token())
	orm_viewset_permission(vs, orm_perm_django_object_view_permissions())
	orm_throttle* t = orm_throttle_parse(c"3/min")
	orm_throttle_set_clock(t, rest_clock_ms)
	__rest.tag_throttle = t
	orm_viewset_throttle(vs, t)
	return vs


list[char*] rest_names2(char* a, char* b):
	list[char*] l = new list[char*]
	l.push(a)
	l.push(b)
	return l


# Read-only, no authenticators; OPTIONS restricted to staff.
orm_viewset* rest_catalog_viewset(orm_db* db):
	orm_viewset* vs = orm_viewset_new(Book_desc(), db, rest_books_qs, 0)
	orm_serializer_include(vs.serializer, rest_names2(c"id", c"title"))
	orm_viewset_actions(vs, ORM_VS_READ_ONLY)
	orm_viewset_clear_authenticators(vs)
	orm_viewset_permission(vs, orm_perm_for_actions(c"metadata", orm_perm_is_admin_user()))
	return vs


# ---------------------------------------------------------------------------
# Unit-level: throttle buckets and permission composition (no database)

void rest_case_throttle_unit():
	orm_throttle* t = orm_throttle_parse(c"2/min")
	asserts(c"parse 2/min", t != 0)
	assert_equal(2, t.rate)
	assert_equal(60000, t.period_ms)
	assert1(orm_throttle_parse(c"x/min") == 0)
	assert1(orm_throttle_parse(c"5/fortnight") == 0)
	assert1(orm_throttle_parse(c"5") == 0)
	orm_throttle* d = orm_throttle_parse(c"10/day")
	assert_equal(86400000, d.period_ms)
	orm_throttle_free(d)
	__rest_ms = 1000
	orm_throttle_set_clock(t, rest_clock_ms)
	assert_equal(0, orm_throttle_take(t, c"k"))
	assert_equal(0, orm_throttle_take(t, c"k"))
	# Empty: one token every 30 s.
	assert_equal(30000, orm_throttle_take(t, c"k"))
	assert_equal(30000, orm_throttle_wait_ms(t, c"k"))
	assert_equal(0, orm_throttle_take(t, c"other"))
	__rest_ms = 21000
	assert_equal(10000, orm_throttle_take(t, c"k"))
	assert_equal(10, orm_throttle_seconds(10000))
	assert_equal(1, orm_throttle_seconds(1))
	__rest_ms = 31000
	assert_equal(0, orm_throttle_take(t, c"k"))
	assert_equal(30000, orm_throttle_take(t, c"k"))
	# A long idle period refills to the burst, not beyond.
	__rest_ms = 100000000
	assert_equal(0, orm_throttle_take(t, c"k"))
	assert_equal(0, orm_throttle_take(t, c"k"))
	assert1(orm_throttle_take(t, c"k") > 0)
	# burst 1 at 2/min: no back-to-back requests.
	orm_throttle_burst(t, 1)
	orm_throttle_reset(t, c"k")
	assert_equal(0, orm_throttle_take(t, c"k"))
	assert_equal(30000, orm_throttle_take(t, c"k"))
	# Pruning drops full buckets only.
	t.max_keys = 2
	orm_throttle_clear(t)
	assert_equal(0, orm_throttle_take(t, c"a"))
	__rest_ms = __rest_ms + 60000
	assert_equal(0, orm_throttle_take(t, c"b"))
	assert_equal(0, orm_throttle_take(t, c"c"))
	assert_equal(2, t.buckets.length)
	assert1((c"a" in t.buckets) == 0)
	orm_throttle_free(t)


int rest_yes(orm_rest_request* r, void* ctx): return 1
int rest_no(orm_rest_request* r, void* ctx): return 0
int rest_obj_yes(orm_rest_request* r, void* obj, void* ctx): return 1
int rest_obj_no(orm_rest_request* r, void* obj, void* ctx): return 0
int rest_obj_hide(orm_rest_request* r, void* obj, void* ctx): return ORM_PERM_NOT_FOUND


void rest_case_permission_unit():
	orm_rest_request* r = new orm_rest_request()
	r.method = c"GET"
	r.action = c"list"
	orm_permission* yes = orm_perm_new(c"yes", rest_yes, rest_obj_yes, 0)
	orm_permission* no = orm_perm_new(c"no", rest_no, rest_obj_no, 0)
	orm_permission* hide = orm_perm_new(c"hide", rest_yes, rest_obj_hide, 0)
	orm_permission* req_only = orm_perm_new(c"req_only", rest_yes, rest_obj_no, 0)
	orm_permission* obj_only = orm_perm_new(c"obj_only", rest_no, rest_obj_yes, 0)
	assert_equal(1, orm_perm_has(yes, r))
	assert_equal(0, orm_perm_has(no, r))
	assert_equal(0, orm_perm_has(orm_perm_and(yes, no), r))
	assert_equal(1, orm_perm_has(orm_perm_or(no, yes), r))
	assert_equal(1, orm_perm_has(orm_perm_not(no), r))
	assert_equal(0, orm_perm_has(orm_perm_not(orm_perm_or(no, yes)), r))
	assert_equal(1, orm_perm_has_object(orm_perm_and(yes, yes), r, r))
	assert_equal(0, orm_perm_has_object(orm_perm_and(yes, req_only), r, r))
	assert_equal(ORM_PERM_NOT_FOUND, orm_perm_has_object(orm_perm_and(hide, yes), r, r))
	# DRF OR: each side's object check pairs with its own request check, so
	# obj_only (request check fails) cannot grant the object.
	assert_equal(0, orm_perm_has_object(orm_perm_or(req_only, obj_only), r, r))
	assert_equal(1, orm_perm_has_object(orm_perm_or(req_only, yes), r, r))
	assert_equal(ORM_PERM_NOT_FOUND, orm_perm_has_object(orm_perm_or(hide, hide), r, r))
	assert_equal(0, orm_perm_has_object(orm_perm_or(hide, req_only), r, r))
	assert_equal(0, orm_perm_has_object(orm_perm_not(yes), r, r))
	assert_equal(1, orm_perm_has_object(orm_perm_not(req_only), r, r))
	# for_actions: only the listed actions are checked.
	orm_permission* only = orm_perm_for_actions(c"create,destroy", no)
	assert_equal(1, orm_perm_has(only, r))
	r.action = c"destroy"
	assert_equal(0, orm_perm_has(only, r))
	r.action = c"create"
	assert_equal(0, orm_perm_has(only, r))
	r.action = 0
	assert_equal(1, orm_perm_has(only, r))
	# Built-ins without a user.
	r.method = c"GET"
	assert_equal(1, orm_perm_has(orm_perm_allow_any(), r))
	assert_equal(0, orm_perm_has(orm_perm_is_authenticated(), r))
	assert_equal(0, orm_perm_has(orm_perm_is_admin_user(), r))
	assert_equal(1, orm_perm_has(orm_perm_is_authenticated_or_read_only(), r))
	assert_equal(1, orm_perm_has(orm_perm_read_only(), r))
	r.method = c"POST"
	assert_equal(0, orm_perm_has(orm_perm_is_authenticated_or_read_only(), r))
	assert_equal(0, orm_perm_has(orm_perm_read_only(), r))
	assert_equal(0, orm_perm_has(orm_perm_django_model_permissions_or_anon_read_only(), r))
	r.method = c"OPTIONS"
	assert_equal(1, orm_perm_has(orm_perm_django_model_permissions_or_anon_read_only(), r))
	assert_equal(0, orm_perm_has(orm_perm_django_model_permissions(), r))
	# Messages: the composite's own, else the first operand's.
	orm_perm_message(no, c"Nope.")
	assert_strings_equal(c"Nope.", orm_perm_denial_message(orm_perm_and(yes, no)))
	assert1(orm_perm_denial_message(yes) == 0)
	assert_strings_equal(c"library.add_book", orm_rest_model_perm(Book_desc(), c"add"))
	free(cast(char*, r))


# ---------------------------------------------------------------------------
# HTTP scenarios

void rest_case_registration(orm_db* db):
	# get_queryset is required: refused at registration, 500 on dispatch.
	orm_viewset* bad = orm_viewset_new(Book_desc(), db, 0, 0)
	orm_rest_router* rt = orm_rest_router_new()
	assert_equal(0, orm_rest_router_register(rt, c"/bad", bad))
	assert_strings_equal(c"viewset: get_queryset is required", rt.error)
	assert_equal(0, rt.entries.length)
	ServerRequest* req = rest_req(c"GET", c"/bad/", 0)
	rest_expect(orm_rest_dispatch(bad, req, c"/"), 500, c"{\"detail\":\"viewset: get_queryset is required\"}")
	server_request_free(req)
	orm_viewset_free(bad)
	# A misconfigured serializer is refused the same way.
	orm_viewset* bad2 = orm_viewset_new(Book_desc(), db, rest_books_qs, 0)
	orm_serializer_exclude(bad2.serializer, c"nope")
	assert_equal(0, orm_rest_router_register(rt, c"/bad2", bad2))
	assert_strings_equal(c"serializer: unknown field 'nope'", rt.error)
	orm_viewset_free(bad2)
	# Duplicate prefixes are refused.
	assert_equal(1, orm_rest_router_register(rt, c"/x/", __rest.catalog))
	assert_equal(0, orm_rest_router_register(rt, c"/x", __rest.catalog))
	assert_strings_equal(c"router: prefix already registered", rt.error)
	orm_rest_router_free(rt)


void rest_case_books_anonymous():
	rest_mark()
	# list: COUNT + page query (author__name joined by the serializer).
	rest_expect(rest_call(c"GET", c"/api/books/", 0, 0), 200, c"{\"count\":2,\"next\":null,\"previous\":null,\"results\":[{\"id\":@1,\"title\":\"Alpha\",\"author\":@4,\"status\":\"pub\",\"price\":\"10.00\",\"pages\":null,\"author_name\":\"Alice Author\"},{\"id\":@3,\"title\":\"Gamma\",\"author\":@5,\"status\":\"pub\",\"price\":\"5.00\",\"pages\":null,\"author_name\":\"Bob Author\"}]}")
	rest_expect_queries(2)
	rest_expect(rest_call(c"GET", c"/api/books?ordering=price&title__icontains=a", 0, 0), 200, c"{\"count\":2,\"next\":null,\"previous\":null,\"results\":[{\"id\":@3,\"title\":\"Gamma\",\"author\":@5,\"status\":\"pub\",\"price\":\"5.00\",\"pages\":null,\"author_name\":\"Bob Author\"},{\"id\":@1,\"title\":\"Alpha\",\"author\":@4,\"status\":\"pub\",\"price\":\"10.00\",\"pages\":null,\"author_name\":\"Alice Author\"}]}")
	rest_expect(rest_call(c"GET", c"/api/books/?status=bogus", 0, 0), 400, 0)
	rest_expect(rest_call(c"GET", c"/api/books/?page=9", 0, 0), 404, c"{\"detail\":\"Invalid page.\"}")
	rest_mark()
	rest_expect(rest_call(c"GET", c"/api/books/@1/", 0, 0), 200, c"{\"id\":@1,\"title\":\"Alpha\",\"author\":@4,\"status\":\"pub\",\"price\":\"10.00\",\"pages\":null,\"author_name\":\"Alice Author\"}")
	rest_expect_queries(1)
	# Outside get_queryset (a draft) and malformed pks are 404.
	rest_expect(rest_call(c"GET", c"/api/books/@2/", 0, 0), 404, c"{\"detail\":\"No Book matches the given query.\"}")
	rest_mark()
	rest_expect(rest_call(c"GET", c"/api/books/abc/", 0, 0), 404, c"{\"detail\":\"No Book matches the given query.\"}")
	rest_expect_queries(0)
	rest_expect(rest_call(c"GET", c"/api/books/1/2/3/", 0, 0), 404, c"{\"detail\":\"Not found.\"}")
	rest_expect(rest_call(c"GET", c"/api/nothing/", 0, 0), 404, c"{\"detail\":\"Not found.\"}")
	rest_expect(rest_call(c"GET", c"/api/booksx/", 0, 0), 404, c"{\"detail\":\"Not found.\"}")
	# Token auth comes first: unauthenticated writes are 401 with a challenge.
	ServerResponse* resp = rest_call(c"POST", c"/api/books/", c"{\"title\":\"X\"}", 0)
	rest_expect_header(resp, c"WWW-Authenticate", c"Token")
	rest_expect_header(resp, c"Allow", c"GET, POST, HEAD, OPTIONS")
	rest_expect(resp, 401, c"{\"detail\":\"Authentication credentials were not provided.\"}")
	ServerResponse* bad = rest_call(c"GET", c"/api/books/", 0, c"not-a-real-token-at-all-not-a-real-token-xx")
	rest_expect_header(bad, c"WWW-Authenticate", c"Token")
	rest_expect(bad, 401, c"{\"detail\":\"Invalid token.\"}")
	ServerRequest* req = rest_req(c"GET", c"/api/books/", 0)
	orm_rest_request_header(req, c"Authorization", c"Token")
	rest_expect(rest_send(req), 401, c"{\"detail\":\"Invalid token header. No credentials provided.\"}")
	ServerRequest* req2 = rest_req(c"GET", c"/api/books/", 0)
	orm_rest_request_header(req2, c"Authorization", c"Token a b")
	rest_expect(rest_send(req2), 401, c"{\"detail\":\"Invalid token header. Token string should not contain spaces.\"}")
	# Another scheme is not ours: anonymous.
	ServerRequest* req3 = rest_req(c"GET", c"/api/books/@1/", 0)
	orm_rest_request_header(req3, c"Authorization", c"Basic YWxpY2U6cHc=")
	rest_expect(rest_send(req3), 200, 0)
	# Extra list action, metadata, HEAD.
	rest_expect(rest_call(c"GET", c"/api/books/stats/", 0, 0), 200, c"{\"visible\":2}")
	ServerResponse* opt = rest_call(c"OPTIONS", c"/api/books/", 0, 0)
	rest_expect_header(opt, c"Allow", c"GET, POST, HEAD, OPTIONS")
	rest_expect(opt, 200, c"{\"name\":\"Book List\",\"description\":\"\",\"renders\":[\"application/json\"],\"parses\":[\"application/json\"]}")
	ServerResponse* head = rest_call(c"HEAD", c"/api/books/@1/", 0, 0)
	rest_expect_header(head, c"Allow", c"GET, PUT, PATCH, DELETE, HEAD, OPTIONS")
	rest_expect(head, 200, c"")


void rest_case_books_writes():
	rest_fixture* f = __rest
	rest_mark()
	# Token: SELECT token, UPDATE last_used, SELECT user; then COUNT + page.
	rest_expect(rest_call(c"GET", c"/api/books/?ordering=-price", 0, f.alice_tok), 200, c"{\"count\":2,\"next\":null,\"previous\":null,\"results\":[{\"id\":@2,\"title\":\"Beta\",\"author\":@4,\"status\":\"draft\",\"price\":\"20.00\",\"pages\":null,\"author_name\":\"Alice Author\"},{\"id\":@1,\"title\":\"Alpha\",\"author\":@4,\"status\":\"pub\",\"price\":\"10.00\",\"pages\":null,\"author_name\":\"Alice Author\"}]}")
	rest_expect_queries(5)
	# Validation errors are 400 from the serializer.
	rest_expect(rest_call(c"POST", c"/api/books/", c"{\"title\":\"\",\"pages\":\"x\"}", f.alice_tok), 400, c"{\"title\":[\"This field may not be blank.\"],\"pages\":[\"A valid integer is required.\"],\"author\":[\"This field is required.\"],\"price\":[\"This field is required.\"]}")
	rest_expect(rest_call(c"POST", c"/api/books/", c"{\"title\":", f.alice_tok), 400, c"{\"detail\":\"JSON parse error.\"}")
	ServerRequest* plain = rest_req(c"POST", c"/api/books/", c"title=x")
	rest_token(plain, f.alice_tok)
	orm_rest_request_header(plain, c"Content-Type", c"text/plain; charset=utf-8")
	rest_expect(rest_send(plain), 415, c"{\"detail\":\"Unsupported media type \\\"text/plain\\\" in request.\"}")
	rest_expect(rest_call(c"POST", c"/api/books/", c"{\"title\":\"Forbidden\",\"author\":@4,\"price\":\"1.00\"}", f.alice_tok), 400, c"{\"detail\":\"Title not allowed.\"}")
	# The CHECK constraint (price >= 0) is enforced by the database and
	# mapped to the field.
	rest_expect(rest_call(c"POST", c"/api/books/", c"{\"title\":\"Neg\",\"author\":@4,\"price\":\"-1.00\"}", f.alice_tok), 400, c"{\"price\":[\"Constraint \\\"library_book_price_nonnegative\\\" is violated.\"]}")
	# create: 201, the row reloaded with the serializer's join.
	ServerResponse* created = rest_call(c"POST", c"/api/books/", c"{\"title\":\"Delta\",\"author\":@4,\"price\":\"7.50\"}", f.alice_tok)
	assert_equal(201, created.status)
	json_value* cj = json_parse(created.body)
	int delta = json_object_get(cj, c"id").int_value
	assert_strings_equal(c"Alice Author", json_object_get(cj, c"author_name").string_value)
	assert_strings_equal(c"draft", json_object_get(cj, c"status").string_value)
	json_free(cj)
	server_response_free(created)
	# History context: the insert carries alice's id and the request.
	orm_result* hist = orm_history_for(__rest_db, Book_desc(), delta)
	rest_check(hist != 0)
	assert_equal(1, hist.rows.length)
	orm_history_entry* he = orm_history_entries(hist)[0]
	assert_equal(ORM_HISTORY_INSERT, he.type)
	assert_equal(f.alice.id, he.user_id)
	assert_strings_equal(c"POST /api/books/", he.reason)
	asserts(c"context id", he.context_id != 0)
	orm_result_free(hist)
	# partial_update and update within get_queryset.
	rest_expect(rest_call(c"PATCH", c"/api/books/@2/", c"{\"price\":\"25.00\"}", f.alice_tok), 200, c"{\"id\":@2,\"title\":\"Beta\",\"author\":@4,\"status\":\"draft\",\"price\":\"25.00\",\"pages\":null,\"author_name\":\"Alice Author\"}")
	rest_expect(rest_call(c"PUT", c"/api/books/@2/", c"{\"title\":\"Beta 2\",\"author\":@4,\"price\":\"26.00\",\"status\":\"draft\",\"pages\":300}", f.alice_tok), 200, c"{\"id\":@2,\"title\":\"Beta 2\",\"author\":@4,\"status\":\"draft\",\"price\":\"26.00\",\"pages\":300,\"author_name\":\"Alice Author\"}")
	rest_expect(rest_call(c"PUT", c"/api/books/@2/", c"{\"title\":\"Beta 3\"}", f.alice_tok), 400, c"{\"author\":[\"This field is required.\"],\"price\":[\"This field is required.\"]}")
	# Moving the book to bob's author keeps the response consistent.
	rest_expect(rest_call(c"PATCH", c"/api/books/@2/", c"{\"author\":@5}", f.alice_tok), 200, c"{\"id\":@2,\"title\":\"Beta 2\",\"author\":@5,\"status\":\"draft\",\"price\":\"26.00\",\"pages\":300,\"author_name\":\"Bob Author\"}")
	# ...and now it is outside alice's queryset.
	rest_expect(rest_call(c"PATCH", c"/api/books/@2/", c"{\"author\":@4}", f.alice_tok), 404, c"{\"detail\":\"No Book matches the given query.\"}")
	rest_expect(rest_call(c"GET", c"/api/books/@3/", 0, f.alice_tok), 404, 0)
	# Authenticated but missing delete_book: 403.
	char* path = rest_f(c"/api/books/@1/")
	ServerResponse* del = rest_call(c"DELETE", path, 0, f.alice_tok)
	rest_expect_header(del, c"WWW-Authenticate", 0)
	rest_expect(del, 403, c"{\"detail\":\"You do not have permission to perform this action.\"}")
	free(path)
	# 405 with Allow (after authentication and permissions, as DRF).
	ServerResponse* nope = rest_call(c"PUT", c"/api/books/", c"{}", f.alice_tok)
	rest_expect_header(nope, c"Allow", c"GET, POST, HEAD, OPTIONS")
	rest_expect(nope, 405, c"{\"detail\":\"Method \\\"PUT\\\" not allowed.\"}")
	# Detail action with its own permission (staff only).
	rest_expect(rest_call(c"POST", c"/api/books/@1/publish/", 0, f.alice_tok), 403, c"{\"detail\":\"You do not have permission to perform this action.\"}")
	rest_expect(rest_call(c"GET", c"/api/books/@2/publish/", 0, f.admin_tok), 405, c"{\"detail\":\"Method \\\"GET\\\" not allowed.\"}")
	rest_expect(rest_call(c"POST", c"/api/books/@2/publish/", 0, f.admin_tok), 200, c"{\"id\":@2,\"status\":\"pub\"}")
	# destroy as admin (superuser): 204, empty body; then gone.
	char* dpath = orm_rest_concat3(c"/api/books/", itoa(delta), c"/")
	rest_expect(rest_call(c"DELETE", dpath, 0, f.admin_tok), 204, c"")
	rest_expect(rest_call(c"GET", dpath, 0, f.admin_tok), 404, 0)
	free(dpath)


void rest_case_history():
	rest_fixture* f = __rest
	# b2 was inserted (no context), patched, put, moved and published by
	# alice/admin through the API.
	ServerResponse* resp = rest_call(c"GET", c"/api/books/@2/history/", 0, f.admin_tok)
	assert_equal(200, resp.status)
	json_value* arr = json_parse(resp.body)
	asserts(resp.body, arr != 0 && arr.type == json_type_array())
	assert_equal(5, json_array_length(arr))
	json_value* newest = json_array_get(arr, 0)
	assert_strings_equal(c"~", json_object_get(newest, c"history_type").string_value)
	assert_strings_equal(c"pub", json_object_get(newest, c"status").string_value)
	assert_equal(f.admin.id, json_object_get(newest, c"history_user_id").int_value)
	assert_strings_equal(rest_f(c"POST /api/books/@2/publish/"), json_object_get(newest, c"history_reason").string_value)
	json_value* oldest = json_array_get(arr, 4)
	assert_strings_equal(c"+", json_object_get(oldest, c"history_type").string_value)
	assert_strings_equal(c"Beta", json_object_get(oldest, c"title").string_value)
	assert_strings_equal(c"20.00", json_object_get(oldest, c"price").string_value)
	assert1(json_object_get(oldest, c"history_user_id").type == json_type_null())
	assert1(json_object_get(oldest, c"history_context_id").type == json_type_null())
	json_value* v2 = json_array_get(arr, 3)
	assert_strings_equal(c"25.00", json_object_get(v2, c"price").string_value)
	assert_equal(f.alice.id, json_object_get(v2, c"history_user_id").int_value)
	json_free(arr)
	server_response_free(resp)
	# The history route checks get_queryset first.
	rest_expect(rest_call(c"GET", c"/api/books/@2/history/", 0, f.bob_tok), 200, 0)
	rest_expect(rest_call(c"GET", c"/api/books/@1/history/", 0, f.bob_tok), 404, c"{\"detail\":\"No Book matches the given query.\"}")
	ServerResponse* post = rest_call(c"POST", c"/api/books/@1/history/", 0, f.admin_tok)
	rest_expect_header(post, c"Allow", c"GET, HEAD, OPTIONS")
	rest_expect(post, 405, 0)
	# Reads set no context; the context is cleared after each write.
	assert1(__rest_db.history_context == 0)


void rest_case_authors_session():
	rest_fixture* f = __rest
	# Session-only viewset: no challenge, so unauthenticated is 403.
	ServerResponse* anon = rest_call(c"GET", c"/api/authors/", 0, 0)
	rest_expect_header(anon, c"WWW-Authenticate", 0)
	rest_expect(anon, 403, c"{\"detail\":\"Authentication credentials were not provided.\"}")
	auth_session* s = session_login(__rest_db, 0, f.alice)
	rest_check(s != 0)
	char* cookie = orm_rest_concat(c"sessionid=", s.key)
	ServerRequest* g = rest_req(c"GET", c"/api/authors/", 0)
	orm_rest_request_header(g, c"Cookie", cookie)
	rest_mark()
	# SELECT session, SELECT user, SELECT authors.
	rest_expect(rest_send(g), 200, c"[{\"id\":@4,\"name\":\"Alice Author\",\"email\":\"alice@example.com\"},{\"id\":@5,\"name\":\"Bob Author\",\"email\":\"bob@example.com\"}]")
	rest_expect_queries(3)
	# Unsafe methods need CSRF once the session authenticates.
	ServerRequest* p1 = rest_req(c"PATCH", c"/api/authors/@4/", c"{\"name\":\"Alice A.\"}")
	orm_rest_request_header(p1, c"Cookie", cookie)
	rest_expect(rest_send(p1), 403, c"{\"detail\":\"CSRF Failed: CSRF cookie not set.\"}")
	csrf_get_secret(s)
	rest_check(session_save(__rest_db, s))
	ServerRequest* p2 = rest_req(c"PATCH", c"/api/authors/@4/", c"{\"name\":\"Alice A.\"}")
	orm_rest_request_header(p2, c"Cookie", cookie)
	rest_expect(rest_send(p2), 403, c"{\"detail\":\"CSRF Failed: CSRF token missing.\"}")
	char* tok = csrf_token(s)
	ServerRequest* p3 = rest_req(c"PATCH", c"/api/authors/@4/", c"{\"name\":\"Alice A.\"}")
	orm_rest_request_header(p3, c"Cookie", cookie)
	orm_rest_request_header(p3, c"X-CSRFToken", tok)
	orm_rest_request_header(p3, c"Origin", c"https://evil.example.net")
	rest_expect(rest_send(p3), 403, c"{\"detail\":\"CSRF Failed: Origin checking failed - does not match any trusted origins.\"}")
	ServerRequest* p4 = rest_req(c"PATCH", c"/api/authors/@4/", c"{\"name\":\"Alice A.\"}")
	orm_rest_request_header(p4, c"Cookie", cookie)
	orm_rest_request_header(p4, c"X-CSRFToken", tok)
	orm_rest_request_header(p4, c"Origin", c"http://api.example.org")
	rest_expect(rest_send(p4), 200, c"{\"id\":@4,\"name\":\"Alice A.\",\"email\":\"alice@example.com\"}")
	# Object permission (U3.1 hook): not alice's author -> 403.
	ServerRequest* p5 = rest_req(c"PATCH", c"/api/authors/@5/", c"{\"name\":\"Mallory\"}")
	orm_rest_request_header(p5, c"Cookie", cookie)
	orm_rest_request_header(p5, c"X-CSRFToken", tok)
	rest_expect(rest_send(p5), 403, c"{\"detail\":\"You do not have permission to perform this action.\"}")
	# A database UNIQUE violation is a 400 on the field.
	ServerRequest* p6 = rest_req(c"POST", c"/api/authors/", c"{\"name\":\"Dup\",\"email\":\"bob@example.com\"}")
	orm_rest_request_header(p6, c"Cookie", cookie)
	orm_rest_request_header(p6, c"X-CSRFToken", tok)
	rest_expect(rest_send(p6), 400, c"{\"email\":[\"author with this email already exists.\"]}")
	# A token is not accepted here (session only): anonymous -> 403.
	rest_expect(rest_call(c"GET", c"/api/authors/", 0, f.alice_tok), 403, 0)
	free(tok)
	free(cookie)
	rest_check(session_logout(__rest_db, s))
	auth_session_free(s)


void rest_case_tags_throttle():
	rest_fixture* f = __rest
	__rest_ms = 5000
	orm_throttle_clear(f.tag_throttle)
	# Not viewable (hook abstains, view_tag needed per object): 404.
	rest_expect(rest_call(c"GET", c"/api/tags/@7/", 0, f.alice_tok), 404, c"{\"detail\":\"Not found.\"}")
	rest_expect(rest_call(c"GET", c"/api/tags/@6/", 0, f.alice_tok), 200, c"{\"id\":@6,\"name\":\"public-news\"}")
	# Viewable but no change permission on the object: 403.
	rest_expect(rest_call(c"PATCH", c"/api/tags/@6/", c"{\"name\":\"x\"}", f.alice_tok), 403, c"{\"detail\":\"You do not have permission to perform this action.\"}")
	# Fourth request in the minute: 429 (3/min = one token per 20 s).
	ServerResponse* t = rest_call(c"GET", c"/api/tags/@6/", 0, f.alice_tok)
	rest_expect_header(t, c"Retry-After", c"20")
	rest_expect(t, 429, c"{\"detail\":\"Request was throttled. Expected available in 20 seconds.\"}")
	# Buckets are per user.
	rest_expect(rest_call(c"GET", c"/api/tags/@6/", 0, f.bob_tok), 200, 0)
	# bob lacks change_tag: the model permission refuses before the object.
	rest_expect(rest_call(c"PATCH", c"/api/tags/@6/", c"{\"name\":\"x\"}", f.bob_tok), 403, 0)
	__rest_ms = 24999
	ServerResponse* t2 = rest_call(c"GET", c"/api/tags/@6/", 0, f.alice_tok)
	rest_expect_header(t2, c"Retry-After", c"1")
	rest_expect(t2, 429, c"{\"detail\":\"Request was throttled. Expected available in 1 second.\"}")
	__rest_ms = 25000
	rest_expect(rest_call(c"GET", c"/api/tags/@6/", 0, f.alice_tok), 200, 0)
	# Anonymous requests fail authentication/permissions before throttling.
	ServerResponse* anon = rest_call(c"GET", c"/api/tags/", 0, 0)
	rest_expect_header(anon, c"WWW-Authenticate", c"Token")
	rest_expect(anon, 401, 0)


void rest_case_catalog():
	rest_fixture* f = __rest
	rest_expect(rest_call(c"GET", c"/api/catalog/@1/", 0, 0), 200, c"{\"id\":@1,\"title\":\"Alpha\"}")
	ServerResponse* put = rest_call(c"PUT", c"/api/catalog/@1/", c"{}", 0)
	rest_expect_header(put, c"Allow", c"GET, HEAD, OPTIONS")
	rest_expect(put, 405, c"{\"detail\":\"Method \\\"PUT\\\" not allowed.\"}")
	ServerResponse* post = rest_call(c"POST", c"/api/catalog/", c"{}", 0)
	rest_expect_header(post, c"Allow", c"GET, HEAD, OPTIONS")
	rest_expect(post, 405, 0)
	# No authenticators: a denial is a plain 403 (never 401), and a token
	# header is ignored.
	rest_expect(rest_call(c"OPTIONS", c"/api/catalog/", 0, 0), 403, c"{\"detail\":\"You do not have permission to perform this action.\"}")
	rest_expect(rest_call(c"OPTIONS", c"/api/catalog/", 0, f.admin_tok), 403, 0)


void rest_case_routes():
	list[orm_rest_route*] routes = orm_rest_router_routes(__rest_rt)
	string_builder* s = string_new()
	for orm_rest_route* rt in routes:
		string_append(s, rt.method)
		string_append_char(s, ' ')
		string_append(s, rt.path)
		string_append_char(s, ' ')
		string_append(s, rt.action)
		string_append_char(s, ' ')
		string_append_int(s, rt.status)
		if (rt.request != 0): string_append(s, c" in")
		if (rt.many): string_append(s, c" many")
		if (rt.paginator != 0): string_append(s, c" paged")
		if (rt.filter != 0): string_append(s, c" filtered")
		if (rt.partial): string_append(s, c" partial")
		string_append_char(s, '\n')
	assert_strings_equal(c"GET /api/books/ list 200 many paged filtered\nPOST /api/books/ create 201 in\nGET /api/books/stats/ stats 200\nGET /api/books/{id}/ retrieve 200\nPUT /api/books/{id}/ update 200 in\nPATCH /api/books/{id}/ partial_update 200 in partial\nDELETE /api/books/{id}/ destroy 204\nGET /api/books/{id}/history/ history 200\nPOST /api/books/{id}/publish/ publish 200\nGET /api/authors/ list 200 many\nPOST /api/authors/ create 201 in\nGET /api/authors/{id}/ retrieve 200\nPUT /api/authors/{id}/ update 200 in\nPATCH /api/authors/{id}/ partial_update 200 in partial\nDELETE /api/authors/{id}/ destroy 204\nGET /api/tags/ list 200 many\nPOST /api/tags/ create 201 in\nGET /api/tags/{id}/ retrieve 200\nPUT /api/tags/{id}/ update 200 in\nPATCH /api/tags/{id}/ partial_update 200 in partial\nDELETE /api/tags/{id}/ destroy 204\nGET /api/catalog/ list 200 many\nGET /api/catalog/{id}/ retrieve 200\n", s.data)
	string_free(s)
	orm_rest_route* pub = routes[8]
	assert1(pub.detail == 1)
	assert_strings_equal(c"id", pub.pk_name)
	assert1(pub.permission != __rest.books.permission)
	orm_rest_routes_free(routes)


char* rest_lower(char* s):
	char* out = strclone(s)
	for i in range(strlen(out)): out[i] = tolower(out[i])
	return out


# /openapi.json (U4.2's generator over the router's viewsets) lists every
# standard route and method the router serves.
void rest_case_openapi():
	orm_rest_router_openapi(__rest_rt, c"/openapi.json", c"Library API", c"1.0.0")
	ServerResponse* resp = rest_call(c"GET", c"/openapi.json", 0, 0)
	assert_equal(200, resp.status)
	json_value* doc = json_parse(resp.body)
	asserts(c"openapi json", doc != 0)
	assert_strings_equal(c"3.0.3", json_object_get(doc, c"openapi").string_value)
	json_value* paths = json_object_get(doc, c"paths")
	list[orm_rest_route*] routes = orm_rest_router_routes(__rest_rt)
	int checked = 0
	for orm_rest_route* rt in routes:
		if (strcmp(rt.action, c"stats") == 0 || strcmp(rt.action, c"publish") == 0): continue
		json_value* item = json_object_get(paths, rt.path)
		if (item == 0): println(rt.path)
		asserts(rt.path, item != 0)
		char* m = rest_lower(rt.method)
		if (json_object_get(item, m) == 0):
			print(rt.method)
			print(c" ")
			println(rt.path)
		asserts(m, json_object_get(item, m) != 0)
		free(m)
		checked = checked + 1
	assert_equal(21, checked)
	orm_rest_routes_free(routes)
	# Security follows the authenticators; anonymous reads where allowed.
	json_value* books_list = json_object_get(json_object_get(paths, c"/api/books/"), c"get")
	assert_contains(json_stringify(json_object_get(books_list, c"security")), c"tokenAuth")
	json_value* hist = json_object_get(json_object_get(paths, c"/api/books/{id}/history/"), c"get")
	asserts(c"history op", hist != 0)
	json_free(doc)
	server_response_free(resp)
	rest_expect(rest_call(c"POST", c"/openapi.json", c"{}", 0), 405, 0)
	orm_api* api = orm_rest_router_api(__rest_rt, c"Library API", c"1.0.0")
	char* text = orm_openapi_render(api)
	asserts(orm_api_error(api), orm_api_error(api) == 0)
	free(text)
	orm_rest_api_free(api)


void rest_report(orm_db* db, char* what, json_value* errors, int status, char* want);


# Direct check of U3.4's integrity-error mapping against this database
# (UNIQUE, FK, NOT NULL, CHECK), bypassing the serializer's pre-checks.
void rest_case_integrity(orm_db* db):
	orm_serializer* aser = orm_serializer_new(Author_desc())
	orm_serializer* bser = orm_serializer_new(Book_desc())
	int st = 0
	Author* dup = Author_new()
	dup.name = c"Dup"
	dup.email = c"bob@example.com"
	json_value* e1 = orm_serializer_save(db, aser, dup, &st)
	rest_report(db, c"unique", e1, st, c"{\"email\":[\"author with this email already exists.\"]}")
	Book* fk = Book_new()
	fk.title = c"Orphan"
	fk.author_id = 999999
	fk.status = c"draft"
	fk.price = c"1.00"
	fk.pages__isnull = 1
	json_value* e2 = orm_serializer_save(db, bser, fk, &st)
	rest_report(db, c"fk", e2, st, c"{\"author\":[\"Invalid pk \\\"999999\\\" - object does not exist.\"]}")
	Book* nn = Book_new()
	nn.title = 0
	nn.author_id = __rest.a1.id
	nn.status = c"draft"
	nn.price = c"1.00"
	nn.pages__isnull = 1
	json_value* e3 = orm_serializer_save(db, bser, nn, &st)
	rest_report(db, c"not null", e3, st, c"{\"title\":[\"This field may not be null.\"]}")
	Book* ck = Book_new()
	ck.title = c"Neg"
	ck.author_id = __rest.a1.id
	ck.status = c"draft"
	ck.price = c"-3.00"
	ck.pages__isnull = 1
	json_value* e4 = orm_serializer_save(db, bser, ck, &st)
	rest_report(db, c"check", e4, st, c"{\"price\":[\"Constraint \\\"library_book_price_nonnegative\\\" is violated.\"]}")
	orm_serializer_free(aser)
	orm_serializer_free(bser)


void rest_report(orm_db* db, char* what, json_value* errors, int status, char* want):
	asserts(what, errors != 0)
	char* got = json_stringify(errors)
	if (status != 400 || strcmp(got, want) != 0):
		print(what)
		print(c" database error: ")
		println(orm_db_error(db))
		print(c"mapped: ")
		println(got)
	assert_equal(400, status)
	assert_strings_equal(want, got)
	free(got)
	json_free(errors)


# ---------------------------------------------------------------------------
# Entry

orm_rest_router* rest_build_router(orm_db* db):
	rest_fixture* f = __rest
	f.books = rest_books_viewset(db)
	f.authors = rest_authors_viewset(db)
	f.tags = rest_tags_viewset(db)
	f.catalog = rest_catalog_viewset(db)
	orm_rest_router* rt = orm_rest_router_new()
	assert_equal(1, orm_rest_router_register(rt, c"/api/books", f.books))
	assert_equal(1, orm_rest_router_register(rt, c"/api/authors/", f.authors))
	assert_equal(1, orm_rest_router_register(rt, c"/api/tags", f.tags))
	assert_equal(1, orm_rest_router_register(rt, c"/api/catalog", f.catalog))
	return rt


# Sets up schema, data and router on db (auth_set_clock pinned).
void orm_rest_setup(orm_db* db):
	__rest_db = db
	__rest = new rest_fixture()
	library_register()
	auth_register()
	session_register()
	auth_password_set_iterations(1000)
	__sess_t = sess_t0()
	auth_set_clock(sess_clock)
	auth_perm_cache_clear()
	auth_clear_object_permissions()
	auth_register_object_permission(rest_obj_hook)
	rest_schema(db)
	rest_seed(db)
	__rest_rt = rest_build_router(db)


void rest_run_cases(orm_db* db):
	rest_case_throttle_unit()
	rest_case_permission_unit()
	orm_rest_setup(db)
	rest_case_registration(db)
	rest_case_books_anonymous()
	rest_case_books_writes()
	rest_case_history()
	rest_case_authors_session()
	rest_case_tags_throttle()
	rest_case_catalog()
	rest_case_routes()
	rest_case_openapi()
	rest_case_integrity(db)


void orm_rest_teardown():
	auth_clear_object_permissions()
	auth_set_clock(0)
	auth_password_set_iterations(0)
