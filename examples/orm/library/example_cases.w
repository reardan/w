# The example library app end to end (issue #754, unit U5.2; README.md),
# shared by orm_example_test (SQLite file) and orm_example_postgres_test.
#
# Two connections play two processes: `db` runs release-2 ("new") code,
# the app in app.w; `old` runs release-1 code, the v1/library_v1_orm*
# module generated from the schema before the Book.pages -> page_count
# rename. The story, one deploy at a time (plan section 5.3):
#
#   1. Static checks: every committed migration lints clean on both
#      dialects, release 1's migration matches v1/library_v1.orm, the
#      committed rename plan is what makemigrations plans on either
#      dialect, and makemigrations has nothing left to plan.
#   2. Release 1: the initial migrations; users, groups and permissions;
#      session login (with CSRF) and token login through /api/auth/; the
#      old code writes the first books.
#   3. Expand deploy (0002 expand + 0003 migrate): old and new code run
#      side by side on the same tables and each sees the other's writes;
#      the REST API (CRUD, filters, pagination, history with the request
#      user, /openapi.json) runs on the new code.
#   4. Contract 0004 (old code retired): the dual write stops, new code
#      still works.
#   5. Contract 0005 (a later deploy): the old column is dropped, the new
#      code still works, the old code no longer can, nothing is pending.
import examples.orm.library.app
import examples.orm.library.migrations
import examples.orm.library.v1.library_v1_orm_api
import libs.standard.orm.migrate.apply
import libs.standard.orm.migrate.autodetect
import libs.standard.orm.migrate.lint
import lib.assert


struct ex_state:
	orm_db* db                 # new code
	orm_db* old                # old code (release 1)
	library_app* app
	int dialect
	User* admin
	User* librarian
	User* reader
	char* lib_cookie           # librarian's session cookie value
	char* lib_csrf             # librarian's CSRF token
	char* reader_tok
	char* admin_tok
	int le_guin                # author ids
	int jemisin
	int dispossessed           # book ids (old code wrote them)
	int left_hand
	int fifth_season


ex_state* X


void ex_check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


# ---------------------------------------------------------------------------
# Requests

# One request through the app in process. token: "Authorization: Token";
# cookie: the session cookie value; csrf: X-CSRFToken plus a same-origin
# Origin header.
ServerResponse* ex_call(char* method, char* target, char* body, char* token, char* cookie, char* csrf):
	ServerRequest* req = orm_rest_request_build(method, target, body)
	orm_rest_request_header(req, c"Host", c"library.example.org")
	if (token != 0):
		char* v = orm_rest_concat(c"Token ", token)
		orm_rest_request_header(req, c"Authorization", v)
		free(v)
	if (cookie != 0):
		char* c2 = orm_rest_concat(c"sessionid=", cookie)
		orm_rest_request_header(req, c"Cookie", c2)
		free(c2)
	if (csrf != 0):
		orm_rest_request_header(req, c"X-CSRFToken", csrf)
		orm_rest_request_header(req, c"Origin", c"http://library.example.org")
	ServerResponse* resp = library_app_dispatch(X.app, req)
	server_request_free(req)
	return resp


# Asserts the status (and, when want != 0, the exact body); returns the
# body (owned) and frees resp.
char* ex_expect(ServerResponse* resp, int status, char* want):
	char* body = resp.body
	if (body == 0): body = c""
	if (resp.status != status || (want != 0 && strcmp(want, body) != 0)):
		print(c"status: ")
		println(itoa(resp.status))
		print(c"body: ")
		println(body)
	assert_equal(status, resp.status)
	if (want != 0): assert_strings_equal(want, body)
	char* out = strclone(body)
	server_response_free(resp)
	return out


json_value* ex_json(char* text):
	json_value* v = json_parse(text)
	asserts(text, v != 0)
	return v


int ex_int(json_value* o, char* key):
	json_value* v = json_object_get(o, key)
	asserts(key, v != 0 && v.type == json_type_int())
	return v.int_value


char* ex_str(json_value* o, char* key):
	json_value* v = json_object_get(o, key)
	asserts(key, v != 0 && v.type == json_type_string())
	return v.string_value


int ex_is_null(json_value* o, char* key):
	json_value* v = json_object_get(o, key)
	return v != 0 && v.type == json_type_null()


# The session cookie value a response sets (owned), or 0.
char* ex_set_cookie(ServerResponse* resp):
	char* h = server_response_get_header(resp, c"Set-Cookie")
	if (h == 0): return 0
	if (starts_with(h, c"sessionid=") == 0): return 0
	int end = 10
	while (h[end] != 0 && h[end] != ';'): end = end + 1
	return substring(h, 10, end)


# s with "@" replaced by n.
char* ex_fmt(char* s, int n):
	return replace(s, c"@", itoa(n))


char* ex_fmt2(char* s, int a, int b):
	char* once = replace(s, c"@1", itoa(a))
	return replace(once, c"@2", itoa(b))


# ---------------------------------------------------------------------------
# Old code (release 1) and new code (release 2) workloads

BookV1* ex_old_book(int id):
	orm_result* r = BookV1_objects(X.old).filter(q_eq_int(c"id", id)).all()
	ex_check(X.old, r != 0)
	assert_equal(1, r.rows.length)
	return BookV1_rows(r)[0]


Book* ex_new_book(int id):
	orm_result* r = Book_objects(X.db).filter(q_eq_int(c"id", id)).all()
	ex_check(X.db, r != 0)
	assert_equal(1, r.rows.length)
	return Book_rows(r)[0]


int ex_old_author(char* name, char* email):
	AuthorV1* a = AuthorV1_new()
	a.name = name
	a.email = email
	a.bio = 0
	ex_check(X.old, AuthorV1_save(X.old, a))
	return a.id


int ex_old_insert(char* title, int author, char* status, char* price, int pages):
	BookV1* b = BookV1_new()
	b.title = title
	b.author_id = author
	b.status = status
	b.price = price
	b.pages = pages
	b.pages__isnull = pages < 0
	ex_check(X.old, BookV1_save(X.old, b))
	return b.id


int ex_new_insert(char* title, int author, char* status, char* price, int pages):
	Book* b = Book_new()
	b.title = title
	b.author_id = author
	b.status = status
	b.price = price
	b.page_count = pages
	b.page_count__isnull = pages < 0
	ex_check(X.db, Book_save(X.db, b))
	return b.id


void ex_old_set_pages(int id, int pages):
	BookV1* b = ex_old_book(id)
	b.pages = pages
	b.pages__isnull = 0
	list[char*] fields = new list[char*]
	fields.push(c"pages")
	ex_check(X.old, orm_save_fields(X.old, BookV1_desc(), b, fields))
	fields.free()


void ex_new_set_pages(int id, int pages):
	Book* b = ex_new_book(id)
	b.page_count = pages
	b.page_count__isnull = 0
	list[char*] fields = new list[char*]
	fields.push(c"page_count")
	ex_check(X.db, orm_save_fields(X.db, Book_desc(), b, fields))
	fields.free()


int ex_old_pages(int id):
	BookV1* b = ex_old_book(id)
	if (b.pages__isnull): return -1
	return b.pages


int ex_new_pages(int id):
	Book* b = ex_new_book(id)
	if (b.page_count__isnull): return -1
	return b.page_count


# Release-1 code's loan desk: lends a book through LoanV1 and lists the
# long books with a pages filter. Returns the loan id.
int ex_old_lend(int book, int borrower):
	LoanV1* l = LoanV1_new()
	l.book_id = book
	l.borrower_id = borrower
	l.returned_at = 0
	ex_check(X.old, LoanV1_save(X.old, l))
	return l.id


int ex_old_count_long(int min_pages):
	int n = BookV1_objects(X.old).filter(q_lookup(c"pages", c"gte", itoa(min_pages))).count()
	ex_check(X.old, n >= 0)
	return n


int ex_new_count_long(int min_pages):
	int n = Book_objects(X.db).filter(q_lookup(c"page_count", c"gte", itoa(min_pages))).count()
	ex_check(X.db, n >= 0)
	return n


# The plan-5.3 check between the expand and contract deploys: release-1
# and release-2 code write the same table at the same time and each reads
# what the other wrote.
void ex_both_codes_work():
	int old_id = ex_old_insert(c"The Word for World Is Forest", X.le_guin, c"pub", c"9.00", 189)
	assert_equal(189, ex_new_pages(old_id))
	int new_id = ex_new_insert(c"The Obelisk Gate", X.jemisin, c"pub", c"16.00", 410)
	assert_equal(410, ex_old_pages(new_id))
	ex_old_set_pages(new_id, 448)
	assert_equal(448, ex_new_pages(new_id))
	ex_new_set_pages(old_id, 190)
	assert_equal(190, ex_old_pages(old_id))
	# Rows written before the expand deploy were copied by 0003.
	assert_equal(387, ex_new_pages(X.dispossessed))
	assert_equal(304, ex_new_pages(X.left_hand))
	# Both filters see every row (old: pages, new: page_count).
	assert_equal(ex_old_count_long(400), ex_new_count_long(400))
	assert_equal(2, ex_new_count_long(400))
	# Untouched tables keep working for both (old LoanV1, new Loan).
	int loan = ex_old_lend(old_id, X.reader.id)
	assert_equal(1, Loan_objects(X.db).filter(q_eq_int(c"id", loan)).count())
	ex_check(X.old, LoanV1_objects(X.old).filter(q_eq_int(c"id", loan)).delete() == 1)
	# The new code's REST API sees the old code's row through page_count.
	char* body = ex_expect(ex_call(c"GET", c"/api/books/?page_count__gte=400&ordering=page_count", 0, X.reader_tok, 0, 0), 200, 0)
	json_value* page = ex_json(body)
	assert_equal(2, ex_int(page, c"count"))
	json_value* first = json_array_get(json_object_get(page, c"results"), 0)
	assert_equal(new_id, ex_int(first, c"id"))
	assert_equal(448, ex_int(first, c"page_count"))
	json_value* second = json_array_get(json_object_get(page, c"results"), 1)
	assert_strings_equal(c"The Fifth Season", ex_str(second, c"title"))
	json_free(page)
	free(body)
	# Clean up through each version's own delete.
	ex_check(X.old, BookV1_objects(X.old).filter(q_eq_int(c"id", new_id)).delete() == 1)
	ex_check(X.db, Book_objects(X.db).filter(q_eq_int(c"id", old_id)).delete() == 1)


# ---------------------------------------------------------------------------
# 1. Static checks (no database)

list[orm_migration*] ex_app_list(char* app):
	list[orm_migration*] out = new list[orm_migration*]
	for orm_migration* m in library_app_migrations():
		if (strcmp(m.app, app) == 0): out.push(m)
	return out


void ex_lint_clean(int dialect):
	for orm_migration* m in library_app_migrations():
		list[orm_lint_finding*] findings = orm_lint_migration(m, dialect)
		if (findings.length > 0):
			print(m.name)
			print(c": ")
			println(orm_lint_format(findings))
		assert_equal(0, findings.length)
		orm_lint_free(findings)


void ex_nothing_to_plan(char* app, char* snapshot, int dialect):
	orm_makemig* r = orm_makemigrations_next(app, ex_app_list(app), snapshot, dialect, 0)
	asserts(r.error, r.error == 0)
	if (r.migrations.length > 0):
		print(app)
		print(c": unplanned change ")
		println(r.migrations[0].name)
	assert_equal(0, r.migrations.length)
	orm_makemig_free(r)


# The committed rename migrations are exactly what makemigrations plans
# from release 1 on `dialect` (names, phases, op kinds and columns).
void ex_rename_plan_matches(int dialect):
	list[orm_migration*] committed = ex_app_list(c"library")
	assert_equal(5, committed.length)
	list[orm_migration*] release1 = new list[orm_migration*]
	release1.push(committed[0])
	list[char*] hints = new list[char*]
	hints.push(c"library_book.pages->page_count")
	orm_makemig* r = orm_makemigrations_next(c"library", release1, library_schema_json(), dialect, hints)
	asserts(r.error, r.error == 0)
	assert_equal(4, r.migrations.length)
	for i in range(4):
		orm_migration* want = committed[i + 1]
		orm_migration* got = r.migrations[i]
		assert_strings_equal(want.name, got.name)
		assert_equal(want.ops.length, got.ops.length)
		assert_equal(want.atomic, got.atomic)
		for j in range(want.ops.length):
			assert_equal(want.ops[j].kind, got.ops[j].kind)
			assert_equal(want.ops[j].phase, got.ops[j].phase)
			assert_strings_equal(want.ops[j].column, got.ops[j].column)
	orm_makemig_free(r)


void ex_static_checks():
	ex_lint_clean(ORM_DIALECT_SQLITE)
	ex_lint_clean(ORM_DIALECT_POSTGRES)
	# Release 1's migration creates what v1/library_v1.orm describes (the
	# old code's module), table by table and column by column.
	list[orm_migration*] release1 = library_app_migrations_upto(c"library", 1)
	list[orm_migration*] lib1 = new list[orm_migration*]
	for orm_migration* m in release1:
		if (strcmp(m.app, c"library") == 0): lib1.push(m)
	orm_state* st = orm_state_from_migrations(c"library", lib1)
	asserts(st.error, st.error == 0)
	orm_detect* d = orm_autodetect(orm_state_to_json(st), library_v1_schema_json(), 0)
	asserts(d.error, d.error == 0)
	if (d.changes.length > 0): println(orm_detect_describe(d))
	assert_equal(0, d.changes.length)
	# The committed rename is the planner's, and the same on both dialects
	# (a nullable column needs no PostgreSQL-only NOT NULL steps).
	ex_rename_plan_matches(ORM_DIALECT_POSTGRES)
	ex_rename_plan_matches(ORM_DIALECT_SQLITE)
	# The committed migrations are up to date with every schema.
	ex_nothing_to_plan(c"library", library_schema_json(), ORM_DIALECT_POSTGRES)
	ex_nothing_to_plan(c"library", library_schema_json(), ORM_DIALECT_SQLITE)
	ex_nothing_to_plan(c"auth", auth_schema_json(), ORM_DIALECT_POSTGRES)
	ex_nothing_to_plan(c"session", session_schema_json(), ORM_DIALECT_POSTGRES)


# ---------------------------------------------------------------------------
# 2. Release 1

int ex_apply(list[orm_migration*] ms, int want):
	int n = orm_migrate_apply(X.db, ms, 0)
	if (n != want): println(orm_db_error(X.db))
	assert_equal(want, n)
	return n


void ex_grant(User* u, char* perm):
	Permission* p = permission_get(X.db, perm)
	asserts(perm, p != 0)
	ex_check(X.db, user_add_permission(X.db, u, p))


void ex_users():
	orm_db* db = X.db
	X.admin = create_superuser(db, c"admin", c"admin@example.org", c"pw-admin")
	X.librarian = create_user(db, c"librarian", c"lib@example.org", c"pw-librarian")
	X.reader = create_user(db, c"reader", c"reader@example.org", c"pw-reader")
	ex_check(db, X.admin != 0 && X.librarian != 0 && X.reader != 0)
	assert1(orm_auth_create_model_permissions(db, Author_desc()) == 4)
	assert1(orm_auth_create_model_permissions(db, Book_desc()) == 4)
	assert1(orm_auth_create_model_permissions(db, Loan_desc()) == 4)
	# Librarians get their permissions through a group.
	Group* staff = group_get_or_create(db, c"librarians")
	ex_check(db, staff != 0)
	for char* perm in split(c"library.add_book library.change_book library.add_author library.change_author", ' '):
		Permission* p = permission_get(db, perm)
		asserts(perm, p != 0)
		ex_check(db, group_add_permission(db, staff, p))
	ex_check(db, user_add_group(db, X.librarian, staff))
	ex_grant(X.reader, c"library.view_book")
	assert1(user_has_perm(db, X.librarian, c"library.change_book"))
	assert1(user_has_perm(db, X.librarian, c"library.delete_book") == 0)
	assert1(user_has_perm(db, X.reader, c"library.add_book") == 0)
	assert1(user_has_perm(db, X.admin, c"library.delete_book"))


# Session login through /api/auth/ with Django's CSRF rules, then token
# logins. Only auth tables are touched, so this runs on release 1.
void ex_logins():
	# An anonymous session hands out the CSRF token.
	ServerResponse* r1 = ex_call(c"GET", c"/api/auth/csrf/", 0, 0, 0, 0)
	char* anon = ex_set_cookie(r1)
	asserts(c"csrf cookie", anon != 0)
	char* b1 = ex_expect(r1, 200, 0)
	json_value* j1 = ex_json(b1)
	char* tok = strclone(ex_str(j1, c"csrf_token"))
	assert_equal(64, strlen(tok))
	json_free(j1)
	char* creds = c"{\"username\":\"librarian\",\"password\":\"pw-librarian\"}"
	ex_expect(ex_call(c"POST", c"/api/auth/login/", creds, 0, anon, 0), 403, c"{\"detail\":\"CSRF Failed: CSRF token missing.\"}")
	ex_expect(ex_call(c"POST", c"/api/auth/login/", creds, 0, 0, tok), 403, c"{\"detail\":\"CSRF Failed: CSRF cookie not set.\"}")
	ex_expect(ex_call(c"POST", c"/api/auth/login/", c"{\"username\":\"librarian\",\"password\":\"nope\"}", 0, anon, tok), 400, c"{\"detail\":\"Unable to log in with provided credentials.\"}")
	ex_expect(ex_call(c"GET", c"/api/auth/login/", 0, 0, 0, 0), 405, 0)
	# Login rotates the session key and the CSRF secret.
	ServerResponse* r2 = ex_call(c"POST", c"/api/auth/login/", creds, 0, anon, tok)
	X.lib_cookie = ex_set_cookie(r2)
	asserts(c"login cookie", X.lib_cookie != 0)
	assert1(strcmp(X.lib_cookie, anon) != 0)
	char* b2 = ex_expect(r2, 200, 0)
	json_value* j2 = ex_json(b2)
	assert_equal(X.librarian.id, ex_int(j2, c"id"))
	assert_strings_equal(c"librarian", ex_str(j2, c"username"))
	X.lib_csrf = strclone(ex_str(j2, c"csrf_token"))
	json_free(j2)
	# The anonymous key is gone.
	assert1(session_load(X.db, anon) == 0)
	# Tokens: DRF's obtain_auth_token, one named token per user.
	char* b3 = ex_expect(ex_call(c"POST", c"/api/auth/token/", c"{\"username\":\"reader\",\"password\":\"pw-reader\",\"name\":\"cli\"}", 0, 0, 0), 201, 0)
	json_value* j3 = ex_json(b3)
	X.reader_tok = strclone(ex_str(j3, c"token"))
	json_free(j3)
	ex_expect(ex_call(c"POST", c"/api/auth/token/", c"{\"username\":\"reader\",\"password\":\"pw-reader\",\"name\":\"cli\"}", 0, 0, 0), 400, c"{\"detail\":\"A token with this name already exists.\"}")
	ex_expect(ex_call(c"POST", c"/api/auth/token/", c"{\"username\":\"reader\",\"password\":\"bad\"}", 0, 0, 0), 400, 0)
	char* b4 = ex_expect(ex_call(c"POST", c"/api/auth/token/", c"{\"username\":\"admin\",\"password\":\"pw-admin\"}", 0, 0, 0), 201, 0)
	json_value* j4 = ex_json(b4)
	X.admin_tok = strclone(ex_str(j4, c"token"))
	assert_strings_equal(c"api", ex_str(j4, c"name"))
	json_free(j4)
	User* who = authenticate_token(X.db, X.reader_tok)
	ex_check(X.db, who != 0)
	assert_equal(X.reader.id, who.id)
	User_free(who)
	free(tok)
	free(anon)


# Release-1 code writes the first rows (with pages).
void ex_release1_data():
	X.le_guin = ex_old_author(c"Ursula K. Le Guin", c"ursula@example.org")
	X.jemisin = ex_old_author(c"N. K. Jemisin", c"nk@example.org")
	X.dispossessed = ex_old_insert(c"The Dispossessed", X.le_guin, c"pub", c"12.50", 387)
	X.left_hand = ex_old_insert(c"The Left Hand of Darkness", X.le_guin, c"pub", c"11.00", 304)
	X.fifth_season = ex_old_insert(c"The Fifth Season", X.jemisin, c"draft", c"15.00", -1)
	ex_old_set_pages(X.fifth_season, 468)
	assert_equal(2, ex_old_count_long(350))
	# History is on from the first migration; the old code's connection
	# publishes no context, so its rows have no user.
	orm_result* h = orm_history_for(X.old, BookV1_desc(), X.fifth_season)
	ex_check(X.old, h != 0)
	assert_equal(2, h.rows.length)
	orm_history_entry* newest = orm_history_entries(h)[0]
	assert_equal(ORM_HISTORY_UPDATE, newest.type)
	assert_equal(1, newest.user_isnull)
	assert_equal(468, BookV1_history_row(newest).pages)
	orm_result_free(h)


# ---------------------------------------------------------------------------
# 3. The REST API on release 2 (after the expand deploy)

void ex_api_reads():
	# Anonymous: published books only, two per page, newest links kept.
	char* body = ex_expect(ex_call(c"GET", c"/api/books/?ordering=title", 0, 0, 0, 0), 200, 0)
	json_value* page = ex_json(body)
	assert_equal(2, ex_int(page, c"count"))
	assert1(ex_is_null(page, c"next"))
	json_value* first = json_array_get(json_object_get(page, c"results"), 0)
	assert_strings_equal(c"The Dispossessed", ex_str(first, c"title"))
	assert_strings_equal(c"Ursula K. Le Guin", ex_str(first, c"author_name"))
	assert_equal(387, ex_int(first, c"page_count"))
	assert1(json_object_get(first, c"pages") == 0)
	json_free(page)
	free(body)
	# Signed in (token), every book; page_size and links.
	char* b2 = ex_expect(ex_call(c"GET", c"/api/books/?ordering=-price&page_size=1&page=2", 0, X.reader_tok, 0, 0), 200, 0)
	json_value* p2 = ex_json(b2)
	assert_equal(3, ex_int(p2, c"count"))
	assert_strings_equal(c"/api/books/?ordering=-price&page_size=1&page=3", ex_str(p2, c"next"))
	assert_strings_equal(c"/api/books/?ordering=-price&page_size=1", ex_str(p2, c"previous"))
	assert_strings_equal(c"The Dispossessed", ex_str(json_array_get(json_object_get(p2, c"results"), 0), c"title"))
	json_free(p2)
	free(b2)
	# Filters: lookups, related paths, search; bad values are 400.
	char* b3 = ex_expect(ex_call(c"GET", c"/api/books/?author__name__icontains=jemisin&page_count__gte=400&status=draft", 0, X.reader_tok, 0, 0), 200, 0)
	json_value* p3 = ex_json(b3)
	assert_equal(1, ex_int(p3, c"count"))
	assert_strings_equal(c"The Fifth Season", ex_str(json_array_get(json_object_get(p3, c"results"), 0), c"title"))
	json_free(p3)
	free(b3)
	char* b4 = ex_expect(ex_call(c"GET", c"/api/books/?search=hand%20darkness", 0, 0, 0, 0), 200, 0)
	assert_contains(b4, c"\"count\":1,")
	assert_contains(b4, c"The Left Hand of Darkness")
	free(b4)
	ex_expect(ex_call(c"GET", c"/api/books/?page_count__gte=many", 0, 0, 0, 0), 400, 0)
	ex_expect(ex_call(c"GET", c"/api/books/?pages=1", 0, 0, 0, 0), 400, 0)
	# Authors: limit/offset pages with the books as a pk list (prefetched).
	char* b5 = ex_expect(ex_call(c"GET", c"/api/authors/?ordering=name&limit=1", 0, 0, 0, 0), 200, 0)
	json_value* p5 = ex_json(b5)
	assert_equal(2, ex_int(p5, c"count"))
	assert_strings_equal(c"/api/authors/?ordering=name&limit=1&offset=1", ex_str(p5, c"next"))
	json_value* a = json_array_get(json_object_get(p5, c"results"), 0)
	assert_strings_equal(c"N. K. Jemisin", ex_str(a, c"name"))
	assert_equal(1, json_array_length(json_object_get(a, c"books")))
	assert_equal(X.fifth_season, json_array_get(json_object_get(a, c"books"), 0).int_value)
	json_free(p5)
	free(b5)
	# The draft is hidden from anonymous visitors.
	ex_expect(ex_call(c"GET", ex_fmt(c"/api/books/@/", X.fifth_season), 0, 0, 0, 0), 404, c"{\"detail\":\"No Book matches the given query.\"}")


# Librarian through the session cookie (+ CSRF); reader and admin through
# tokens. Returns the id of the book the librarian created.
int ex_api_writes():
	char* create = ex_fmt(c"{\"title\":\"The Lathe of Heaven\",\"author\":@,\"price\":\"10.00\",\"page_count\":184}", X.le_guin)
	# Unsafe session requests need the CSRF token.
	ex_expect(ex_call(c"POST", c"/api/books/", create, 0, X.lib_cookie, 0), 403, c"{\"detail\":\"CSRF Failed: CSRF token missing.\"}")
	char* b1 = ex_expect(ex_call(c"POST", c"/api/books/", create, 0, X.lib_cookie, X.lib_csrf), 201, 0)
	json_value* j1 = ex_json(b1)
	int lathe = ex_int(j1, c"id")
	assert_strings_equal(c"draft", ex_str(j1, c"status"))
	assert_equal(184, ex_int(j1, c"page_count"))
	assert_strings_equal(c"Ursula K. Le Guin", ex_str(j1, c"author_name"))
	json_free(j1)
	# The old code sees the API's insert through the dual write.
	assert_equal(184, ex_old_pages(lathe))
	# Validation and database constraints are 400s.
	ex_expect(ex_call(c"POST", c"/api/books/", ex_fmt(c"{\"title\":\"Bad\",\"author\":@,\"price\":\"-1.00\"}", X.le_guin), 0, X.lib_cookie, X.lib_csrf), 400, c"{\"price\":[\"Constraint \\\"library_book_price_nonnegative\\\" is violated.\"]}")
	ex_expect(ex_call(c"POST", c"/api/books/", c"{\"title\":\"\",\"author\":999999}", 0, X.lib_cookie, X.lib_csrf), 400, c"{\"title\":[\"This field may not be blank.\"],\"author\":[\"Invalid pk \\\"999999\\\" - object does not exist.\"],\"price\":[\"This field is required.\"]}")
	char* path = ex_fmt(c"/api/books/@/", lathe)
	ex_expect(ex_call(c"PATCH", path, c"{\"status\":\"pub\",\"page_count\":192}", 0, X.lib_cookie, X.lib_csrf), 200, 0)
	assert_equal(192, ex_old_pages(lathe))
	# The reader may read but not write books (model permissions).
	ex_expect(ex_call(c"PATCH", path, c"{\"price\":\"1.00\"}", X.reader_tok, 0, 0), 403, c"{\"detail\":\"You do not have permission to perform this action.\"}")
	# Session authentication comes first (no challenge): 403, not 401.
	ex_expect(ex_call(c"POST", c"/api/books/", create, 0, 0, 0), 403, c"{\"detail\":\"Authentication credentials were not provided.\"}")
	# ...the librarian has no delete permission, the admin does.
	ex_expect(ex_call(c"DELETE", ex_fmt(c"/api/books/@/", X.left_hand), 0, 0, X.lib_cookie, X.lib_csrf), 403, 0)
	# Authors through the session.
	char* b2 = ex_expect(ex_call(c"POST", c"/api/authors/", c"{\"name\":\"Octavia E. Butler\",\"email\":\"octavia@example.org\",\"bio\":\"Kindred\"}", 0, X.lib_cookie, X.lib_csrf), 201, 0)
	json_value* j2 = ex_json(b2)
	int butler = ex_int(j2, c"id")
	assert_equal(0, json_array_length(json_object_get(j2, c"books")))
	json_free(j2)
	ex_expect(ex_call(c"POST", c"/api/authors/", c"{\"name\":\"Dup\",\"email\":\"octavia@example.org\"}", 0, X.lib_cookie, X.lib_csrf), 400, c"{\"email\":[\"author with this email already exists.\"]}")
	ex_expect(ex_call(c"DELETE", ex_fmt(c"/api/authors/@/", butler), 0, X.admin_tok, 0, 0), 204, c"")
	ex_expect(ex_call(c"GET", ex_fmt(c"/api/authors/@/", butler), 0, 0, 0, 0), 404, 0)
	# Loans: the checkout action, then the reader's own loans (cursor pages).
	char* out = ex_fmt(c"/api/books/@/checkout/", X.dispossessed)
	char* b3 = ex_expect(ex_call(c"POST", out, 0, X.reader_tok, 0, 0), 201, 0)
	json_value* j3 = ex_json(b3)
	int loan = ex_int(j3, c"id")
	assert_equal(X.reader.id, ex_int(j3, c"borrower_id"))
	json_free(j3)
	ex_expect(ex_call(c"POST", out, 0, X.reader_tok, 0, 0), 409, c"{\"detail\":\"Book is already on loan.\"}")
	ex_expect(ex_call(c"POST", out, 0, 0, 0, 0), 403, 0)
	char* b4 = ex_expect(ex_call(c"POST", c"/api/loans/", ex_fmt(c"{\"book\":@,\"borrower_id\":1}", X.left_hand), X.reader_tok, 0, 0), 201, 0)
	json_value* j4 = ex_json(b4)
	assert_equal(X.reader.id, ex_int(j4, c"borrower_id"))
	assert_strings_equal(c"The Left Hand of Darkness", ex_str(j4, c"book_title"))
	json_free(j4)
	char* b5 = ex_expect(ex_call(c"GET", c"/api/loans/?returned_at__isnull=true", 0, X.reader_tok, 0, 0), 200, 0)
	json_value* p5 = ex_json(b5)
	assert1(json_object_get(p5, c"count") == 0)
	assert_equal(2, json_array_length(json_object_get(p5, c"results")))
	assert1(ex_is_null(p5, c"next"))
	json_free(p5)
	free(b5)
	# Other users do not see the reader's loans; staff do.
	char* b6 = ex_expect(ex_call(c"GET", c"/api/loans/", 0, 0, X.lib_cookie, 0), 200, 0)
	assert_contains(b6, c"\"results\":[]")
	free(b6)
	char* b7 = ex_expect(ex_call(c"GET", ex_fmt(c"/api/loans/@/", loan), 0, X.admin_tok, 0, 0), 200, 0)
	assert_contains(b7, c"\"book_title\":\"The Dispossessed\"")
	free(b7)
	ex_expect(ex_call(c"PATCH", ex_fmt(c"/api/loans/@/", loan), c"{\"returned_at\":\"2026-10-20 09:00:00\"}", X.reader_tok, 0, 0), 200, 0)
	char* b8 = ex_expect(ex_call(c"GET", c"/api/loans/?returned_at__isnull=true", 0, X.reader_tok, 0, 0), 200, 0)
	json_value* p8 = ex_json(b8)
	assert_equal(1, json_array_length(json_object_get(p8, c"results")))
	json_free(p8)
	free(b8)
	free(path)
	free(create)
	free(out)
	return lathe


# History rows carry the request's user (U3.3 context set by the viewset).
void ex_api_history(int lathe):
	char* body = ex_expect(ex_call(c"GET", ex_fmt(c"/api/books/@/history/", lathe), 0, X.reader_tok, 0, 0), 200, 0)
	json_value* arr = ex_json(body)
	assert1(json_array_length(arr) >= 2)
	json_value* newest = json_array_get(arr, 0)
	assert_strings_equal(c"~", ex_str(newest, c"history_type"))
	assert_strings_equal(c"pub", ex_str(newest, c"status"))
	assert_equal(192, ex_int(newest, c"page_count"))
	assert_equal(X.librarian.id, ex_int(newest, c"history_user_id"))
	char* reason = ex_fmt(c"PATCH /api/books/@/", lathe)
	assert_strings_equal(reason, ex_str(newest, c"history_reason"))
	# The insert: one '+' row in the POST's context. (On SQLite the
	# rename's AFTER INSERT dual write also records a '~' row for the same
	# statement, with a lower history_id; and a reused SQLite rowid can put
	# an earlier, deleted book's rows in this list. So look the row up.)
	int inserts = 0
	for i in range(json_array_length(arr)):
		json_value* e = json_array_get(arr, i)
		if (strcmp(ex_str(e, c"history_type"), c"+") != 0): continue
		if (ex_is_null(e, c"history_reason") || strcmp(ex_str(e, c"history_reason"), c"POST /api/books/") != 0): continue
		assert_equal(X.librarian.id, ex_int(e, c"history_user_id"))
		assert_equal(184, ex_int(e, c"page_count"))
		assert_strings_equal(c"draft", ex_str(e, c"status"))
		inserts = inserts + 1
	assert_equal(1, inserts)
	json_free(arr)
	free(body)
	# The checkout's loan was written in the reader's request context.
	orm_result* loans = Loan_objects(X.db).filter(q_eq_int(c"book", X.dispossessed)).all()
	ex_check(X.db, loans != 0 && loans.rows.length == 1)
	orm_result* h = Loan_history(X.db, Loan_rows(loans)[0])
	ex_check(X.db, h != 0)
	char* why = ex_fmt(c"POST /api/books/@/checkout/", X.dispossessed)
	int found = 0
	for orm_history_entry* e in orm_history_entries(h):
		if (e.type != ORM_HISTORY_INSERT || e.reason == 0 || strcmp(e.reason, why) != 0): continue
		assert_equal(X.reader.id, e.user_id)
		assert_equal(X.dispossessed, Loan_history_row(e).book_id)
		found = found + 1
	assert_equal(1, found)
	free(why)
	char* lh = ex_expect(ex_call(c"GET", ex_fmt(c"/api/loans/@/history/", Loan_rows(loans)[0].id), 0, X.reader_tok, 0, 0), 200, 0)
	assert_contains(lh, c"\"history_type\":\"~\"")
	free(lh)
	orm_result_free(h)
	orm_result_free(loans)
	# Reads and old-code writes publish no context.
	assert1(X.db.history_context == 0)


void ex_openapi():
	char* body = ex_expect(ex_call(c"GET", c"/openapi.json", 0, 0, 0, 0), 200, 0)
	json_value* doc = ex_json(body)
	assert_strings_equal(c"3.0.3", ex_str(doc, c"openapi"))
	assert_strings_equal(c"Library API", ex_str(json_object_get(doc, c"info"), c"title"))
	json_value* paths = json_object_get(doc, c"paths")
	for char* p in split(c"/api/authors/ /api/authors/{id}/ /api/books/ /api/books/{id}/ /api/books/{id}/history/ /api/loans/ /api/loans/{id}/history/", ' '):
		asserts(p, json_object_get(paths, p) != 0)
	json_value* list_op = json_object_get(json_object_get(paths, c"/api/books/"), c"get")
	char* params = json_stringify(json_object_get(list_op, c"parameters"))
	assert_contains(params, c"\"page_count__gte\"")
	assert_contains(params, c"\"page_size\"")
	free(params)
	char* sec = json_stringify(json_object_get(list_op, c"security"))
	assert_contains(sec, c"tokenAuth")
	assert_contains(sec, c"cookieAuth")
	free(sec)
	json_value* book = json_object_get(json_object_get(json_object_get(doc, c"components"), c"schemas"), c"Book")
	json_value* props = json_object_get(book, c"properties")
	asserts(c"Book.page_count", json_object_get(props, c"page_count") != 0)
	asserts(c"no Book.pages", json_object_get(props, c"pages") == 0)
	json_free(doc)
	free(body)
	orm_api* api = orm_rest_router_api(X.app.router, c"Library API", c"2.0.0")
	char* text = orm_openapi_render(api)
	asserts(orm_api_error(api), orm_api_error(api) == 0)
	free(text)
	orm_rest_api_free(api)


void ex_logout():
	ServerResponse* r = ex_call(c"POST", c"/api/auth/logout/", 0, 0, X.lib_cookie, X.lib_csrf)
	assert_contains(server_response_get_header(r, c"Set-Cookie"), c"Max-Age=0")
	ex_expect(r, 204, c"")
	# The cookie no longer authenticates: anonymous again.
	ex_expect(ex_call(c"POST", c"/api/books/", c"{}", 0, X.lib_cookie, X.lib_csrf), 403, c"{\"detail\":\"Authentication credentials were not provided.\"}")


# ---------------------------------------------------------------------------
# Entry

void example_run(orm_db* db, orm_db* old):
	X = new ex_state()
	X.db = db
	X.old = old
	X.dialect = orm_mx_dialect_of(db)
	auth_password_set_iterations(1000)
	auth_perm_cache_clear()
	orm_set_now(c"2026-10-19 12:00:00")
	library_v1_register()
	X.app = library_app_new(db)
	asserts(c"library app", X.app != 0)
	# 1. Static checks.
	ex_static_checks()
	# 2. Release 1: initial migrations of auth, session and library.
	assert_equal(7, library_app_migrations().length)
	ex_apply(library_app_migrations_upto(c"library", 1), 3)
	ex_users()
	ex_logins()
	ex_release1_data()
	# The rename's contract step refuses to ship with its expand step.
	assert_equal(-1, orm_migrate_apply(db, library_app_migrations(), 0))
	assert_contains(orm_db_error(db), c"to be applied by an earlier deploy")
	# 3. Expand deploy: 0002 (page_count + dual-write trigger) and 0003
	# (copy). Old and new code now share the table.
	ex_apply(library_app_migrations_upto(c"library", 3), 2)
	ex_both_codes_work()
	ex_api_reads()
	int lathe = ex_api_writes()
	ex_api_history(lathe)
	ex_openapi()
	ex_both_codes_work()
	# 4. Contract 0004, once no release-1 code runs: pages becomes a
	# deprecated nullable column and the dual write stops.
	ex_apply(library_app_migrations_upto(c"library", 4), 1)
	int id = ex_new_insert(c"Always Coming Home", X.le_guin, c"pub", c"20.00", 562)
	assert_equal(562, ex_new_pages(id))
	assert_equal(-1, ex_old_pages(id))
	char* p = ex_fmt(c"/api/books/@/", id)
	ex_expect(ex_call(c"PATCH", p, c"{\"page_count\":563}", X.admin_tok, 0, 0), 200, 0)
	assert_equal(-1, ex_old_pages(id))
	# 5. Contract 0005 (a later deploy): pages is dropped.
	ex_apply(library_app_migrations(), 1)
	assert_equal(0, orm_migrate_apply(db, library_app_migrations(), 0))
	char* status = orm_migrate_status(db, library_app_migrations())
	assert_contains(status, c"[X] library.0005_contract_library_book_pages")
	assert1(index_of(status, c"[ ]") < 0)
	free(status)
	# New code: ORM, REST and history keep working.
	ex_new_set_pages(id, 570)
	char* b = ex_expect(ex_call(c"GET", c"/api/books/?page_count__gte=500", 0, 0, 0, 0), 200, 0)
	assert_contains(b, c"\"title\":\"Always Coming Home\"")
	assert_contains(b, c"\"page_count\":570")
	free(b)
	ex_expect(ex_call(c"DELETE", p, 0, X.admin_tok, 0, 0), 204, c"")
	char* hb = ex_expect(ex_call(c"GET", ex_fmt(c"/api/books/@/history/", X.dispossessed), 0, X.admin_tok, 0, 0), 200, 0)
	json_value* hist = ex_json(hb)
	assert_equal(387, ex_int(json_array_get(hist, 0), c"page_count"))
	json_free(hist)
	free(hb)
	char* lb = ex_expect(ex_call(c"GET", c"/api/books/?ordering=-page_count&page_size=10", 0, X.reader_tok, 0, 0), 200, 0)
	json_value* all = ex_json(lb)
	assert_equal(4, ex_int(all, c"count"))
	json_value* top = json_array_get(json_object_get(all, c"results"), 0)
	assert_strings_equal(c"The Fifth Season", ex_str(top, c"title"))
	assert_equal(468, ex_int(top, c"page_count"))
	json_free(all)
	free(lb)
	ex_logout()
	# Release-1 code can no longer read books (its pages column is gone).
	orm_result* gone = BookV1_objects(old).filter(q_eq_int(c"id", X.dispossessed)).all()
	assert1(gone == 0)
	assert1(strlen(orm_db_error(old)) > 0)
	free(p)
	auth_password_set_iterations(0)
	orm_set_now(0)
