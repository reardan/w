# U5.1 admin scenarios (docs/projects/orm/u5_1.md), shared by
# orm_admin_test (SQLite in memory) and orm_admin_postgres_test: staff and
# per-permission gating, login / logout, CRUD round trips with CSRF
# tokens, changelist search / filters / ordering / pagination with a
# fixed statement count, the delete cascade preview, history with diffs
# and revert, and HTML escaping of stored data. Requests go through
# U4.3's in-process client.
import tests.orm.fixtures.library_orm_api
import tests.orm.fixtures.library_schema
import tests.orm.orm_session_cases
import libs.standard.orm.admin.admin
import libs.standard.orm.web.client
import libs.standard.orm.migrate.apply
import lib.assert


struct adm_app:
	orm_router* rt
	orm_web_app* app
	orm_web_db_source* src
	orm_web_csrf_config* csrf
	orm_admin_site* site
	orm_db* db               # setup / inspection connection
	int shared               # requests use db itself (statement counts)
	int mark


struct adm_users:
	User* root               # superuser
	User* staff              # every Book permission, view Author / Tag
	User* viewer             # view_book only
	User* nobody             # staff without permissions
	User* plain              # active, not staff
	User* deleter            # delete_author + view_author, not delete_book


void at_check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


void at_mark(adm_app* a):
	a.mark = a.db.query_count
	for char* q in a.db.query_log: free(q)
	a.db.query_log.clear()


# Statements run on the shared connection since the last mark (-1 on
# PostgreSQL, whose pooled request connections count separately).
int at_queries(adm_app* a):
	if (a.shared == 0): return -1
	int got = a.db.query_count - a.mark
	at_mark(a)
	return got


void at_expect_queries(adm_app* a, int n):
	if (a.shared == 0): return
	int got = a.db.query_count - a.mark
	if (got != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(got))
		for char* q in a.db.query_log: println(q)
	assert_equal(n, got)
	at_mark(a)


void at_status(ServerResponse* resp, int status):
	if (resp.status != status):
		print(c"expected status ")
		println(itoa(status))
		print(c"got ")
		println(itoa(resp.status))
		println(orm_web_client_body(resp))
	assert_equal(status, resp.status)


char* at_location(ServerResponse* resp):
	return server_response_get_header(resp, c"location")


# The value of the first csrfmiddlewaretoken input in html (owned).
char* at_token(char* html):
	char* marker = c"name=\"csrfmiddlewaretoken\" value=\""
	int at = index_of(html, marker)
	asserts(c"page has a CSRF input", at >= 0)
	char* start = html + at + strlen(marker)
	int end = index_of(start, c"\"")
	assert_equal(64, end)
	return substring(start, 0, end)


void at_absent(char* body, char* needle):
	if (index_of(body, needle) >= 0):
		print(c"unexpected: ")
		println(needle)
		println(body)
	assert1(index_of(body, needle) < 0)


# GET target, assert the status, return the owned body.
char* at_get(orm_web_client* c, char* target, int status):
	ServerResponse* resp = orm_web_client_get(c, target)
	at_status(resp, status)
	char* body = strclone(orm_web_client_body(resp))
	server_response_free(resp)
	return body


# POST the form plus the client's CSRF token; returns the response.
ServerResponse* at_post(orm_web_client* c, char* target, char* form, char* token):
	string_builder* s = string_new()
	string_append(s, form)
	if (token != 0):
		if (form[0] != 0): string_append(s, c"&")
		string_append(s, c"csrfmiddlewaretoken=")
		string_append(s, token)
	ServerResponse* resp = orm_web_client_post_form(c, target, s.data)
	string_free(s)
	return resp


# A client logged in through the admin login page, and its CSRF token.
orm_web_client* at_login(adm_app* a, char* username, char* password, char** token_out):
	orm_web_client* c = orm_web_client_new(a.app)
	char* page = at_get(c, c"/admin/login/", 200)
	char* token = at_token(page)
	free(page)
	string_builder* s = string_new()
	string_append(s, c"username=")
	string_append(s, username)
	string_append(s, c"&password=")
	string_append(s, password)
	ServerResponse* resp = at_post(c, c"/admin/login/?next=/admin/", s.data, token)
	string_free(s)
	at_status(resp, 302)
	assert_strings_equal(c"/admin/", at_location(resp))
	server_response_free(resp)
	free(token)
	# The login rotated the session and dropped the CSRF secret: a fresh
	# token from the next page.
	char* index = at_get(c, c"/admin/", 200)
	token_out[0] = at_token(index)
	free(index)
	return c


# Number of rows in the changelist body.
int at_rows(char* body):
	int start = index_of(body, c"<tbody>")
	assert1(start >= 0)
	char* rest = body + start
	int end = index_of(rest, c"</tbody>")
	char* section = substring(rest, 0, end)
	int n = count(section, c"<tr>")
	free(section)
	return n


int at_count_sql(orm_db* db, char* sql):
	sql_result* r = sql_query(db.conn, sql)
	if (r == 0): println(sql)
	asserts(sql_error(db.conn), r != 0)
	int n = atoi(sql_value(r, 0, 0))
	sql_result_free(r)
	return n


char* at_text_sql(orm_db* db, char* sql):
	sql_result* r = sql_query(db.conn, sql)
	asserts(sql_error(db.conn), r != 0)
	char* out = 0
	if (r.rows > 0 && sql_value(r, 0, 0) != 0): out = strclone(sql_value(r, 0, 0))
	sql_result_free(r)
	return out


int at_book_id(orm_db* db, char* title):
	orm_result* r = Book_objects(db).get(q_eq(c"title", title))
	at_check(db, r != 0)
	int id = Book_rows(r)[0].id
	orm_result_free(r)
	return id


char* at_url(char* a, int id, char* b):
	string_builder* s = string_new()
	string_append(s, a)
	string_append_int(s, id)
	string_append(s, b)
	char* out = s.data
	free(cast(void*, s))
	return out


# ---------------------------------------------------------------------------
# Setup

# A model outside the admin whose FK to Book is PROTECT: a loaned book
# blocks deleting it (and its author).
struct Loan:
	int id
	int book_id
	void* book
	char* borrower


orm_model_desc* __adm_loan_desc


orm_model_desc* Loan_desc():
	if (__adm_loan_desc != 0): return __adm_loan_desc
	Loan probe
	char* base = cast(char*, &probe)
	orm_model_desc* m = orm_model_new(c"Loan", c"admintest_loan", sizeof(Loan))
	orm_model_add_field(m, orm_field_new(c"id", c"id", ORM_INT, cast(char*, &probe.id) - base, ORM_F_PK | ORM_F_AUTO))
	orm_field_desc* f = orm_model_add_field(m, orm_field_new(c"book", c"book_id", ORM_FK, cast(char*, &probe.book_id) - base, ORM_F_INDEXED))
	f.rel_model = c"Book"
	f.rel_offset = cast(char*, &probe.book) - base
	f.on_delete = ORM_PROTECT
	f = orm_model_add_field(m, orm_field_new(c"borrower", c"borrower", ORM_TEXT, cast(char*, &probe.borrower) - base, 0))
	f.max_length = 100
	orm_register(m)
	__adm_loan_desc = m
	return m


int adm_loan_create_schema(orm_db* db):
	if (db.dialect.id == ORM_DIALECT_POSTGRES): return orm_db_exec_sql(db, c"CREATE TABLE admintest_loan (id BIGSERIAL PRIMARY KEY, book_id BIGINT NOT NULL REFERENCES library_book (id) ON DELETE RESTRICT, borrower VARCHAR(100) NOT NULL)")
	return orm_db_exec_sql(db, c"CREATE TABLE admintest_loan (id INTEGER PRIMARY KEY AUTOINCREMENT, book_id INTEGER NOT NULL REFERENCES library_book (id) ON DELETE RESTRICT, borrower VARCHAR(100) NOT NULL)")

adm_app* adm_app_new(orm_db* db, orm_web_db_source* src, int shared):
	Loan_desc()
	library_register()
	auth_register()
	adm_app* a = new adm_app()
	a.db = db
	a.src = src
	a.shared = shared
	a.rt = orm_router_new()
	a.site = orm_admin_site_new()
	a.site.title = c"Library <admin>"
	orm_admin_register(a.site, Author_desc()).list_display(c"name,email").search_fields(c"name,email").display(c"name")
	orm_admin_register(a.site, Book_desc()).list_display(c"title,author,status,price,pages").search_fields(c"title,author__name").list_filter(c"status,author").ordering(c"title").readonly_fields(c"published_at").per_page(10)
	orm_admin_register(a.site, Tag_desc())
	orm_admin_mount(a.site, a.rt, c"/admin")
	if (orm_admin_site_error(a.site) != 0): println(orm_admin_site_error(a.site))
	assert1(orm_admin_site_error(a.site) == 0)
	assert1(orm_router_error(a.rt) == 0)
	a.app = orm_web_app_new(a.rt)
	a.csrf = orm_web_csrf_config_new()
	orm_web_app_use(a.app, orm_web_security_middleware, orm_web_security_new())
	orm_web_app_use(a.app, orm_web_db_middleware, src)
	orm_web_app_use(a.app, orm_web_session_middleware, 0)
	orm_web_app_use(a.app, orm_web_auth_middleware, 0)
	orm_web_app_use(a.app, orm_web_csrf_middleware, a.csrf)
	return a


void at_grant(orm_db* db, User* u, char* perms):
	list[char*] names = split(perms, ',')
	for char* name in names:
		Permission* p = permission_get(db, name)
		at_check(db, p != 0)
		at_check(db, user_add_permission(db, u, p))
		Permission_free(p)
		free(name)
	names.free()


User* at_user(orm_db* db, char* name, int staff):
	User* u = auth_user_create(db, name, 0, c"pw-123", staff, 0)
	at_check(db, u != 0)
	return u


Book* at_book(orm_db* db, char* title, int author_id, char* status, char* price):
	Book* b = Book_new()
	b.title = title
	b.author_id = author_id
	b.status = status
	b.price = price
	b.pages__isnull = 1
	at_check(db, Book_save(db, b))
	return b


void adm_seed(adm_app* a, adm_users* us):
	orm_db* db = a.db
	at_check(db, library_create_schema(db))
	at_check(db, sess_create_schema(db))
	at_check(db, adm_loan_create_schema(db))
	orm_migration* h = orm_migration_new(c"library", c"0001_admin_history")
	orm_migration_add(h, orm_op_new(ORM_OP_CREATE_HISTORY, ORM_PHASE_EXPAND, c"library_book"))
	list[orm_migration*] ms = new list[orm_migration*]
	ms.push(h)
	at_check(db, orm_migrate_apply(db, ms, 0) == 1)
	ms.free()
	at_check(db, orm_auth_create_model_permissions(db, Author_desc()) >= 0)
	at_check(db, orm_auth_create_model_permissions(db, Book_desc()) >= 0)
	at_check(db, orm_auth_create_model_permissions(db, Tag_desc()) >= 0)
	us.root = create_superuser(db, c"root", c"root@example.org", c"pw-123")
	at_check(db, us.root != 0)
	us.staff = at_user(db, c"staff", 1)
	at_grant(db, us.staff, c"library.view_book,library.add_book,library.change_book,library.delete_book,library.view_author,library.view_tag")
	us.viewer = at_user(db, c"viewer", 1)
	at_grant(db, us.viewer, c"library.view_book")
	us.nobody = at_user(db, c"nobody", 1)
	us.plain = at_user(db, c"plain", 0)
	at_grant(db, us.plain, c"library.view_book")
	us.deleter = at_user(db, c"deleter", 1)
	at_grant(db, us.deleter, c"library.view_author,library.delete_author")
	Author* frank = Author_new()
	frank.name = c"Frank Herbert"
	frank.email = c"frank@example.org"
	at_check(db, Author_save(db, frank))
	Author* ursula = Author_new()
	ursula.name = c"Ursula K. Le Guin"
	ursula.email = c"ursula@example.org"
	at_check(db, Author_save(db, ursula))
	Author* bad = Author_new()
	bad.name = c"<b>Bad & \"Co\"</b>"
	bad.email = c"bad@example.org"
	at_check(db, Author_save(db, bad))
	Tag* sf = Tag_new()
	sf.name = c"sf"
	at_check(db, Tag_save(db, sf))
	Book* dune = at_book(db, c"Dune", frank.id, c"pub", c"9.99")
	list[void*] tags = new list[void*]
	tags.push(cast(void*, sf))
	at_check(db, orm_m2m_add(db, Book_desc(), dune, c"tags", tags) >= 0)
	tags.free()
	Book_free(at_book(db, c"Children of Dune", frank.id, c"pub", c"8.50"))
	Book_free(at_book(db, c"A Wizard of Earthsea", ursula.id, c"draft", c"7.50"))
	Book_free(at_book(db, c"<script>alert(1)</script>", bad.id, c"draft", c"1.00"))
	# 21 filler books by Ursula: 25 in all, three pages of 10.
	for i in range(21):
		string_builder* s = string_new()
		string_append(s, c"Filler ")
		if (i < 9): string_append_char(s, '0')
		string_append_int(s, i + 1)
		Book* f = at_book(db, s.data, ursula.id, c"draft", c"2.00")
		if (i == 0):
			Loan* loan = cast(Loan*, orm_row_new(Loan_desc()))
			loan.book_id = f.id
			loan.borrower = c"Genly Ai"
			at_check(db, orm_save(db, Loan_desc(), loan))
			orm_row_free(Loan_desc(), loan)
		Book_free(f)
		string_free(s)
	Book_free(dune)
	Tag_free(sf)
	Author_free(frank)
	Author_free(ursula)
	Author_free(bad)


# ---------------------------------------------------------------------------
# Gating

void adm_test_gating(adm_app* a, adm_users* us):
	orm_web_client* anon = orm_web_client_new(a.app)
	ServerResponse* resp = orm_web_client_get(anon, c"/admin/")
	at_status(resp, 302)
	assert_strings_equal(c"/admin/login/?next=/admin/", at_location(resp))
	server_response_free(resp)
	resp = orm_web_client_get(anon, c"/admin/library/book/3/change/")
	at_status(resp, 302)
	assert_strings_equal(c"/admin/login/?next=/admin/library/book/3/change/", at_location(resp))
	server_response_free(resp)
	# Unknown models are hidden behind the login too.
	resp = orm_web_client_get(anon, c"/admin/library/nope/")
	at_status(resp, 302)
	server_response_free(resp)

	# The login page: CSRF required, wrong passwords and non-staff refused.
	char* page = at_get(anon, c"/admin/login/?next=/admin/library/book/", 200)
	assert_contains(page, c"<title>Log in | Library &lt;admin&gt;</title>")
	assert_contains(page, c"action=\"/admin/login/?next=/admin/library/book/\"")
	char* token = at_token(page)
	free(page)
	resp = orm_web_client_post_form(anon, c"/admin/login/", c"username=root&password=pw-123")
	at_status(resp, 403)
	assert_strings_equal(c"Forbidden (CSRF token missing.)", orm_web_client_body(resp))
	server_response_free(resp)
	resp = at_post(anon, c"/admin/login/", c"username=root&password=wrong", token)
	at_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"Please enter the correct username and password for a staff account.")
	server_response_free(resp)
	resp = at_post(anon, c"/admin/login/", c"username=plain&password=pw-123", token)
	at_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"Please enter the correct username and password for a staff account.")
	assert1(orm_web_client_cookie(anon, c"sessionid") != 0)
	server_response_free(resp)
	# An open redirect in ?next= falls back to the index.
	resp = at_post(anon, c"/admin/login/?next=//evil.example/", c"username=root&password=pw-123", token)
	at_status(resp, 302)
	assert_strings_equal(c"/admin/", at_location(resp))
	server_response_free(resp)
	free(token)
	# A staff user on the login page goes to the index.
	resp = orm_web_client_get(anon, c"/admin/login/")
	at_status(resp, 302)
	server_response_free(resp)
	orm_web_client_free(anon)

	# A logged-in user who is not staff is sent to the login page, which
	# says so.
	auth_session* ps = session_create(a.db, us.plain.id)
	at_check(a.db, ps != 0)
	orm_web_client* pc = orm_web_client_new(a.app)
	orm_web_client_set_cookie(pc, c"sessionid", ps.key)
	resp = orm_web_client_get(pc, c"/admin/library/book/")
	at_status(resp, 302)
	assert_strings_equal(c"/admin/login/?next=/admin/library/book/", at_location(resp))
	server_response_free(resp)
	page = at_get(pc, c"/admin/login/", 200)
	assert_contains(page, c"You are authenticated as plain, but are not authorized to access this page.")
	free(page)
	orm_web_client_free(pc)
	auth_session_free(ps)

	# Staff without permissions: the index says so, model pages are 403.
	char* tn = 0
	orm_web_client* nc = at_login(a, c"nobody", c"pw-123", &tn)
	page = at_get(nc, c"/admin/", 200)
	assert_contains(page, c"You don't have permission to view or edit anything.")
	free(page)
	char* forbidden = c"/admin/library/book/,/admin/library/book/add/,/admin/library/book/1/change/,/admin/library/book/1/delete/,/admin/library/book/1/history/"
	list[char*] urls = split(forbidden, ',')
	for char* u in urls:
		free(at_get(nc, u, 403))
		free(u)
	urls.free()
	free(tn)
	orm_web_client_free(nc)

	# view_book only: the list and a read-only detail page, no writes.
	char* tv = 0
	orm_web_client* vc = at_login(a, c"viewer", c"pw-123", &tv)
	page = at_get(vc, c"/admin/", 200)
	assert_contains(page, c"<tr class=\"model-book\"><th scope=\"row\"><a href=\"/admin/library/book/\">Books</a></th><td></td></tr>")
	at_absent(page, c"model-author")
	free(page)
	page = at_get(vc, c"/admin/library/book/", 200)
	at_absent(page, c"addlink")
	free(page)
	free(at_get(vc, c"/admin/library/book/add/", 403))
	free(at_get(vc, c"/admin/library/author/", 403))
	page = at_get(vc, c"/admin/library/book/1/change/", 200)
	assert_contains(page, c"<h1>View book</h1>")
	assert_contains(page, c"<span class=\"readonly-value\" id=\"ro_title\">Dune</span>")
	assert_contains(page, c"<span class=\"readonly-value\" id=\"ro_author\">Frank Herbert</span>")
	at_absent(page, c"<form method=\"post\" action=\"/admin/library/book/1/change/\"")
	at_absent(page, c">Delete</a>")
	assert_contains(page, c"<a href=\"/admin/library/book/1/history/\" class=\"history\">History</a>")
	free(page)
	resp = at_post(vc, c"/admin/library/book/1/change/", c"title=Hacked&author=1&price=1&status=pub", tv)
	at_status(resp, 403)
	server_response_free(resp)
	free(at_get(vc, c"/admin/library/book/1/delete/", 403))
	free(at_get(vc, c"/admin/library/book/1/history/", 200))
	free(tv)
	orm_web_client_free(vc)
	char* still = at_text_sql(a.db, c"SELECT title FROM library_book WHERE id = 1")
	assert_strings_equal(c"Dune", still)
	free(still)

	# An inactive staff user is anonymous again.
	char* ti = 0
	orm_web_client* ic = at_login(a, c"staff", c"pw-123", &ti)
	at_check(a.db, orm_db_exec_sql(a.db, c"UPDATE auth_user SET is_active = FALSE WHERE username = 'staff'"))
	resp = orm_web_client_get(ic, c"/admin/")
	at_status(resp, 302)
	server_response_free(resp)
	at_check(a.db, orm_db_exec_sql(a.db, c"UPDATE auth_user SET is_active = TRUE WHERE username = 'staff'"))
	# Logout is a POST with the token; afterwards the session is gone.
	free(at_get(ic, c"/admin/", 200))
	resp = at_post(ic, c"/admin/logout/", c"", ti)
	at_status(resp, 302)
	assert_strings_equal(c"/admin/login/", at_location(resp))
	server_response_free(resp)
	resp = orm_web_client_get(ic, c"/admin/")
	at_status(resp, 302)
	server_response_free(resp)
	free(ti)
	orm_web_client_free(ic)


# ---------------------------------------------------------------------------
# Index and changelist

void adm_test_changelist(adm_app* a, adm_users* us):
	char* token = 0
	orm_web_client* c = at_login(a, c"root", c"pw-123", &token)
	char* page = at_get(c, c"/admin/", 200)
	assert_contains(page, c"<caption>Library</caption>")
	assert_contains(page, c"<tr class=\"model-author\"><th scope=\"row\"><a href=\"/admin/library/author/\">Authors</a></th><td><a href=\"/admin/library/author/add/\" class=\"addlink\">Add</a></td></tr>")
	assert_contains(page, c"<tr class=\"model-tag\">")
	assert_contains(page, c"Welcome, <strong>root</strong>.")
	assert1(index_of(page, c"model-author") < index_of(page, c"model-book"))
	free(page)

	# Page 1 of 3, ordered by title; the FK column comes from select_related.
	at_mark(a)
	page = at_get(c, c"/admin/library/book/", 200)
	int fixed = at_queries(a)
	assert_equal(10, at_rows(page))
	assert_contains(page, c"<h1>Select book to change</h1>")
	assert_contains(page, c"<tr><th><a href=\"/admin/library/book/4/change/\">&lt;script&gt;alert(1)&lt;/script&gt;</a></th><td>&lt;b&gt;Bad &amp; &quot;Co&quot;&lt;/b&gt;</td><td>draft</td><td>1.00</td><td>-</td></tr>")
	at_absent(page, c"<script>alert")
	at_absent(page, c"<b>Bad")
	assert_contains(page, c"<a href=\"/admin/library/book/?p=2\" class=\"next\">next</a>")
	assert_contains(page, c"Page 1 of 3")
	assert_contains(page, c"25 books")
	assert_contains(page, c"<a href=\"/admin/library/book/add/\" class=\"addlink\">Add book</a>")
	# Filters: All / enum values / FK rows (escaped).
	assert_contains(page, c"<h3>By Status</h3>")
	assert_contains(page, c"<li class=\"selected\"><a href=\"/admin/library/book/\">All</a></li>")
	assert_contains(page, c"<li><a href=\"/admin/library/book/?status=pub\">pub</a></li>")
	assert_contains(page, c"<li><a href=\"/admin/library/book/?author=3\">&lt;b&gt;Bad &amp; &quot;Co&quot;&lt;/b&gt;</a></li>")
	assert_contains(page, c"<a href=\"/admin/library/book/?o=title\">Title</a>")
	free(page)
	# Same statements for the last page (5 rows) and after 10 more books.
	page = at_get(c, c"/admin/library/book/?p=3", 200)
	assert_equal(5, at_rows(page))
	assert_contains(page, c"<a href=\"/admin/library/book/?p=2\" class=\"previous\">previous</a>")
	free(page)
	int more = at_queries(a)
	assert_equal(fixed, more)
	for i in range(10):
		Book_free(at_book(a.db, c"Zz extra", 2, c"draft", c"3.00"))
	at_mark(a)
	page = at_get(c, c"/admin/library/book/?p=2", 200)
	assert_equal(10, at_rows(page))
	assert_contains(page, c"35 books")
	assert_contains(page, c"Page 2 of 4")
	free(page)
	assert_equal(fixed, at_queries(a))
	# BEGIN, session, user, COUNT, page with authors, author filter, COMMIT
	# (a superuser's permission checks run no query).
	if (a.shared): assert_equal(7, fixed)
	free(at_get(c, c"/admin/library/book/?p=9", 404))
	at_check(a.db, orm_db_exec_sql(a.db, c"DELETE FROM library_book WHERE title = 'Zz extra'"))

	# Search: title or author name, case-insensitive, every term.
	page = at_get(c, c"/admin/library/book/?q=dune", 200)
	assert_equal(2, at_rows(page))
	assert_contains(page, c">Dune</a>")
	assert_contains(page, c">Children of Dune</a>")
	assert_contains(page, c"2 books")
	free(page)
	page = at_get(c, c"/admin/library/book/?q=HERBERT+children", 200)
	assert_equal(1, at_rows(page))
	assert_contains(page, c">Children of Dune</a>")
	free(page)
	page = at_get(c, c"/admin/library/book/?q=%3Cx%3E", 200)
	assert_equal(0, at_rows(page))
	assert_contains(page, c"<input type=\"text\" name=\"q\" value=\"&lt;x&gt;\" id=\"searchbar\">")
	free(page)

	# Filters keep the other parameters; the chosen one is selected.
	page = at_get(c, c"/admin/library/book/?status=pub&q=dune", 200)
	assert_equal(2, at_rows(page))
	assert_contains(page, c"<li class=\"selected\"><a href=\"/admin/library/book/?status=pub&amp;q=dune\">pub</a></li>")
	assert_contains(page, c"<input type=\"hidden\" name=\"status\" value=\"pub\">")
	free(page)
	page = at_get(c, c"/admin/library/book/?author=1", 200)
	assert_equal(2, at_rows(page))
	assert_contains(page, c"<li class=\"selected\"><a href=\"/admin/library/book/?author=1\">Frank Herbert</a></li>")
	free(page)
	page = at_get(c, c"/admin/library/book/?status=nope", 400)
	assert_contains(page, c"<li>status: Select a valid choice. nope is not one of the available choices.</li>")
	free(page)
	page = at_get(c, c"/admin/library/book/?pages=3", 400)
	assert_contains(page, c"<li>pages: Unknown filter parameter.</li>")
	free(page)

	# Ordering: ?o=-title, the header toggles back to ascending.
	page = at_get(c, c"/admin/library/book/?o=-title&author=1", 200)
	assert1(index_of(page, c">Dune</a>") < index_of(page, c">Children of Dune</a>"))
	assert_contains(page, c"<th scope=\"col\" class=\"sorted descending\"><a href=\"/admin/library/book/?o=title&amp;author=1\">Title</a></th>")
	free(page)
	page = at_get(c, c"/admin/library/book/?o=title&author=1", 200)
	assert1(index_of(page, c">Children of Dune</a>") < index_of(page, c">Dune</a>"))
	assert_contains(page, c"<th scope=\"col\" class=\"sorted ascending\"><a href=\"/admin/library/book/?o=-title&amp;author=1\">Title</a></th>")
	free(page)
	page = at_get(c, c"/admin/library/book/?o=price&q=dune", 200)
	assert1(index_of(page, c">Children of Dune</a>") < index_of(page, c">Dune</a>"))
	free(page)
	free(at_get(c, c"/admin/library/book/?o=password", 400))

	# A model with default options lists row labels.
	page = at_get(c, c"/admin/library/tag/", 200)
	assert_contains(page, c"<tr><th><a href=\"/admin/library/tag/1/change/\">sf</a></th></tr>")
	free(page)
	free(at_get(c, c"/admin/library/tag/1/history/", 404))
	free(at_get(c, c"/admin/library/book/999/change/", 404))
	free(token)
	orm_web_client_free(c)


# ---------------------------------------------------------------------------
# Add, change, delete

void adm_test_crud(adm_app* a, adm_users* us):
	char* token = 0
	orm_web_client* c = at_login(a, c"staff", c"pw-123", &token)
	char* page = at_get(c, c"/admin/library/book/add/", 200)
	assert_contains(page, c"<h1>Add book</h1>")
	assert_contains(page, c"<input type=\"text\" name=\"title\" id=\"id_title\" maxlength=\"300\" required>")
	assert_contains(page, c"<option value=\"3\">&lt;b&gt;Bad &amp; &quot;Co&quot;&lt;/b&gt;</option>")
	at_absent(page, c"name=\"published_at\"")
	assert_contains(page, c"<span class=\"readonly-value\" id=\"ro_published_at\">-</span>")
	free(page)
	# No token: refused by the CSRF middleware.
	ServerResponse* resp = orm_web_client_post_form(c, c"/admin/library/book/add/", c"title=X&author=1&price=1&status=pub")
	at_status(resp, 403)
	server_response_free(resp)
	# Invalid: the form again with the serializer's messages.
	resp = at_post(c, c"/admin/library/book/add/", c"title=&author=1&price=abc&status=pub", token)
	at_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"<li>This field may not be blank.</li>")
	assert_contains(orm_web_client_body(resp), c"<li>A valid number is required.</li>")
	server_response_free(resp)
	# Valid: redirect to the changelist; one history row by staff.
	resp = at_post(c, c"/admin/library/book/add/", c"title=The+Dispossessed&author=2&price=8.25&status=pub&pages=387&published_at=2026-01-02+03:04:05", token)
	at_status(resp, 302)
	assert_strings_equal(c"/admin/library/book/", at_location(resp))
	server_response_free(resp)
	int id = at_book_id(a.db, c"The Dispossessed")
	orm_result* made = Book_objects(a.db).get(q_eq_int(c"id", id))
	Book* b = Book_rows(made)[0]
	assert_equal(2, b.author_id)
	assert_strings_equal(c"8.25", b.price)
	assert_equal(387, b.pages)
	assert1(b.published_at == 0)
	orm_result_free(made)
	char* sql = at_url(c"SELECT history_user_id FROM library_book_history WHERE history_type = '+' AND id = ", id, c"")
	char* who = at_text_sql(a.db, sql)
	free(sql)
	char* staff_id = itoa(us.staff.id)
	assert_strings_equal(staff_id, who)
	free(who)
	sql = at_url(c"SELECT history_reason FROM library_book_history WHERE history_type = '+' AND id = ", id, c"")
	char* why = at_text_sql(a.db, sql)
	free(sql)
	assert_strings_equal(c"Added.", why)
	free(why)
	# The context ends with the write: other writes carry none.
	at_check(a.db, orm_db_exec_sql(a.db, c"UPDATE library_book SET pages = 388 WHERE title = 'The Dispossessed'"))
	sql = at_url(c"SELECT COUNT(*) FROM library_book_history WHERE history_user_id IS NULL AND history_type = '~' AND id = ", id, c"")
	assert_equal(1, at_count_sql(a.db, sql))
	free(sql)

	# Change: the form shows the row; saving records what changed.
	char* change = at_url(c"/admin/library/book/", id, c"/change/")
	page = at_get(c, change, 200)
	assert_contains(page, c"<h1>Change book</h1>")
	assert_contains(page, c"value=\"The Dispossessed\"")
	assert_contains(page, c"<option value=\"2\" selected>Ursula K. Le Guin</option>")
	assert_contains(page, c"class=\"history\">History</a>")
	assert_contains(page, c"class=\"delete\">Delete</a>")
	free(page)
	resp = at_post(c, change, c"title=The+Dispossessed%3A+An+Ambiguous+Utopia&author=2&price=9.00&status=pub&pages=388&_continue=1", token)
	at_status(resp, 302)
	assert_strings_equal(change, at_location(resp))
	server_response_free(resp)
	sql = at_url(c"SELECT history_reason FROM library_book_history WHERE id = ", id, c" ORDER BY history_id DESC LIMIT 1")
	why = at_text_sql(a.db, sql)
	free(sql)
	assert_strings_equal(c"Changed title and price.", why)
	free(why)
	# Unchanged save: no history row.
	sql = at_url(c"SELECT COUNT(*) FROM library_book_history WHERE id = ", id, c"")
	int versions = at_count_sql(a.db, sql)
	resp = at_post(c, change, c"title=The+Dispossessed%3A+An+Ambiguous+Utopia&author=2&price=9.00&status=pub&pages=388", token)
	at_status(resp, 302)
	assert_strings_equal(c"/admin/library/book/", at_location(resp))
	server_response_free(resp)
	assert_equal(versions, at_count_sql(a.db, sql))
	free(sql)
	# A unique violation becomes a field error (Author.email).
	char* tr = 0
	orm_web_client* rc = at_login(a, c"root", c"pw-123", &tr)
	resp = at_post(rc, c"/admin/library/author/add/", c"name=Dup&email=frank%40example.org", tr)
	at_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"<li>author with this email already exists.</li>")
	server_response_free(resp)
	resp = at_post(rc, c"/admin/library/author/add/", c"name=%3Ci%3ENew%3C%2Fi%3E&email=new%40example.org", tr)
	at_status(resp, 302)
	server_response_free(resp)
	page = at_get(rc, c"/admin/library/author/", 200)
	assert_contains(page, c"&lt;i&gt;New&lt;/i&gt;")
	at_absent(page, c"<i>New")
	free(page)
	free(tr)
	orm_web_client_free(rc)

	# Delete: confirmation, then the row is gone with a '-' history row.
	char* del = at_url(c"/admin/library/book/", id, c"/delete/")
	page = at_get(c, del, 200)
	assert_contains(page, c"Are you sure you want to delete the book &ldquo;The Dispossessed: An Ambiguous Utopia&rdquo;?")
	assert_contains(page, c"<li>Books: 1</li>")
	free(page)
	resp = at_post(c, del, c"post=yes", token)
	at_status(resp, 302)
	assert_strings_equal(c"/admin/library/book/", at_location(resp))
	server_response_free(resp)
	sql = at_url(c"SELECT COUNT(*) FROM library_book WHERE id = ", id, c"")
	assert_equal(0, at_count_sql(a.db, sql))
	free(sql)
	sql = at_url(c"SELECT history_reason FROM library_book_history WHERE history_type = '-' AND id = ", id, c"")
	why = at_text_sql(a.db, sql)
	free(sql)
	assert_strings_equal(c"Deleted.", why)
	free(why)
	free(at_get(c, change, 404))
	free(change)
	free(del)
	free(staff_id)
	free(token)
	orm_web_client_free(c)


# ---------------------------------------------------------------------------
# Delete cascade preview

void adm_test_cascade(adm_app* a, adm_users* us):
	# deleter may delete authors but not their books.
	char* td = 0
	orm_web_client* dc = at_login(a, c"deleter", c"pw-123", &td)
	char* page = at_get(dc, c"/admin/library/author/1/delete/", 200)
	assert_contains(page, c"your account doesn't have permission to delete the following types of objects:</p>\n<ul class=\"perms-lacking\"><li>book</li></ul>")
	at_absent(page, c"Yes, I'm sure")
	free(page)
	ServerResponse* resp = at_post(dc, c"/admin/library/author/1/delete/", c"post=yes", td)
	at_status(resp, 403)
	server_response_free(resp)
	free(td)
	orm_web_client_free(dc)
	assert_equal(1, at_count_sql(a.db, c"SELECT COUNT(*) FROM library_author WHERE id = 1"))

	char* token = 0
	orm_web_client* c = at_login(a, c"root", c"pw-123", &token)
	at_mark(a)
	page = at_get(c, c"/admin/library/author/1/delete/", 200)
	int q = at_queries(a)
	assert_contains(page, c"<h1>Are you sure?</h1>")
	assert_contains(page, c"<ul class=\"summary\"><li>Authors: 1</li><li>Books: 2</li><li>Book-tag relationships: 1</li></ul>")
	assert_contains(page, c"<ul id=\"deleted-objects\"><li>Author: <a href=\"/admin/library/author/1/change/\">Frank Herbert</a><ul><li>Book: <a href=\"/admin/library/book/1/change/\">Dune</a></li><li>Book: <a href=\"/admin/library/book/2/change/\">Children of Dune</a></li></ul></li></ul>")
	free(page)
	# Escaped labels in the tree.
	page = at_get(c, c"/admin/library/author/3/delete/", 200)
	assert_contains(page, c"<li>Author: <a href=\"/admin/library/author/3/change/\">&lt;b&gt;Bad &amp; &quot;Co&quot;&lt;/b&gt;</a><ul><li>Book: <a href=\"/admin/library/book/4/change/\">&lt;script&gt;alert(1)&lt;/script&gt;</a></li></ul></li>")
	assert_contains(page, c"<li>Authors: 1</li><li>Books: 1</li></ul>")
	free(page)
	# Same statements for 22 cascading books as for 2 (BEGIN, session,
	# user, the author, its books, their tag links, their loans, COMMIT).
	# A loaned book (PROTECT) blocks the delete.
	at_mark(a)
	page = at_get(c, c"/admin/library/author/2/delete/", 200)
	assert_contains(page, c"would require deleting the following protected related objects:</p>\n<ul class=\"protected\"><li>Loan: Loan object (1)</li></ul>")
	at_absent(page, c"Yes, I'm sure")
	free(page)
	assert_equal(q, at_queries(a))
	if (a.shared): assert_equal(8, q)
	resp = at_post(c, c"/admin/library/author/2/delete/", c"post=yes", token)
	at_status(resp, 403)
	server_response_free(resp)
	at_check(a.db, orm_db_exec_sql(a.db, c"DELETE FROM admintest_loan"))
	page = at_get(c, c"/admin/library/author/2/delete/", 200)
	assert_contains(page, c"<li>Books: 22</li>")
	free(page)

	resp = at_post(c, c"/admin/library/author/1/delete/", c"post=yes", token)
	at_status(resp, 302)
	assert_strings_equal(c"/admin/library/author/", at_location(resp))
	server_response_free(resp)
	assert_equal(0, at_count_sql(a.db, c"SELECT COUNT(*) FROM library_book WHERE author_id = 1"))
	assert_equal(0, at_count_sql(a.db, c"SELECT COUNT(*) FROM library_book_tags WHERE book_id = 1"))
	char* sql = at_url(c"SELECT COUNT(*) FROM library_book_history WHERE history_type = '-' AND history_reason = 'Deleted.' AND history_user_id = ", us.root.id, c" AND id IN (1, 2)")
	assert_equal(2, at_count_sql(a.db, sql))
	free(sql)
	free(token)
	orm_web_client_free(c)


# ---------------------------------------------------------------------------
# History tab and revert

void adm_test_history(adm_app* a, adm_users* us):
	char* token = 0
	orm_web_client* c = at_login(a, c"staff", c"pw-123", &token)
	int id = at_book_id(a.db, c"A Wizard of Earthsea")
	char* change = at_url(c"/admin/library/book/", id, c"/change/")
	ServerResponse* resp = at_post(c, change, c"title=A+Wizard+of+%3CEarthsea%3E&author=2&price=7.50&status=draft", token)
	at_status(resp, 302)
	server_response_free(resp)
	resp = at_post(c, change, c"title=A+Wizard+of+%3CEarthsea%3E&author=2&price=12.00&status=pub", token)
	at_status(resp, 302)
	server_response_free(resp)
	char* hist = at_url(c"/admin/library/book/", id, c"/history/")
	char* page = at_get(c, hist, 200)
	assert_contains(page, c"<h1>Change history: A Wizard of &lt;Earthsea&gt;</h1>")
	assert_contains(page, c"<td>Changed</td><td>staff</td><td>Changed status and price.</td>")
	assert_contains(page, c"<td>Changed</td><td>staff</td><td>Changed title.</td>")
	assert_contains(page, c"<td>Added</td><td>-</td><td></td>")
	assert_contains(page, c"class=\"active\">History</a>")
	free(page)
	# Versions, newest first: the title change is the second newest.
	orm_result* hr = orm_history_for(a.db, Book_desc(), id)
	at_check(a.db, hr != 0)
	list[orm_history_entry*] es = orm_history_entries(hr)
	assert_equal(3, es.length)
	int title_version = es[1].history_id
	int first_version = es[2].history_id
	orm_result_free(hr)
	char* vpath = at_url(hist, title_version, c"/")
	page = at_get(c, vpath, 200)
	assert_contains(page, c"<tr><th scope=\"row\">Title</th><td class=\"old\">A Wizard of Earthsea</td><td class=\"new\">A Wizard of &lt;Earthsea&gt;</td></tr>")
	assert_contains(page, c"<p class=\"version-meta\">Changed at ")
	assert_contains(page, c": Changed title.</p>")
	assert_contains(page, c"<td id=\"v_price\">7.50</td>")
	assert_contains(page, c"id=\"revert-form\"")
	free(page)
	# The first version diffs against nothing.
	char* first = at_url(hist, first_version, c"/")
	page = at_get(c, first, 200)
	assert_contains(page, c"<tr><th scope=\"row\">Title</th><td class=\"old\">-</td><td class=\"new\">A Wizard of Earthsea</td></tr>")
	free(page)
	# The viewer sees versions but may not revert.
	char* tv = 0
	orm_web_client* vc = at_login(a, c"viewer", c"pw-123", &tv)
	page = at_get(vc, vpath, 200)
	at_absent(page, c"revert-form")
	free(page)
	resp = at_post(vc, vpath, c"", tv)
	at_status(resp, 403)
	server_response_free(resp)
	free(tv)
	orm_web_client_free(vc)
	# Revert to the first version: title and price come back, recorded
	# under staff with the reason.
	resp = at_post(c, first, c"", token)
	at_status(resp, 302)
	assert_strings_equal(hist, at_location(resp))
	server_response_free(resp)
	orm_result* now = Book_objects(a.db).get(q_eq_int(c"id", id))
	at_check(a.db, now != 0)
	assert_strings_equal(c"A Wizard of Earthsea", Book_rows(now)[0].title)
	assert_strings_equal(c"7.50", Book_rows(now)[0].price)
	assert_strings_equal(c"draft", Book_rows(now)[0].status)
	orm_result_free(now)
	page = at_get(c, hist, 200)
	char* reverted = at_url(c"<td>Changed</td><td>staff</td><td>Reverted to version ", first_version, c".</td>")
	assert_contains(page, reverted)
	free(reverted)
	free(page)
	free(at_get(c, c"/admin/library/book/1/history/999999/", 404))
	free(vpath)
	free(first)

	# A deleted book keeps its history and can be restored by a user with
	# add and change permissions.
	char* del = at_url(c"/admin/library/book/", id, c"/delete/")
	resp = at_post(c, del, c"post=yes", token)
	at_status(resp, 302)
	server_response_free(resp)
	free(del)
	page = at_get(c, hist, 200)
	assert_contains(page, c"<td>Deleted</td><td>staff</td><td>Deleted.</td>")
	free(page)
	hr = orm_history_for(a.db, Book_desc(), id)
	at_check(a.db, hr != 0)
	int before_delete = orm_history_entries(hr)[1].history_id
	orm_result_free(hr)
	char* restore = at_url(hist, before_delete, c"/")
	resp = at_post(c, restore, c"", token)
	at_status(resp, 302)
	server_response_free(resp)
	free(restore)
	assert_equal(id, at_book_id(a.db, c"A Wizard of Earthsea"))
	free(at_get(c, change, 200))
	free(change)
	free(hist)
	free(token)
	orm_web_client_free(c)


void orm_admin_run(adm_app* a):
	auth_password_set_iterations(1000)
	adm_users us
	adm_seed(a, &us)
	adm_test_gating(a, &us)
	adm_test_changelist(a, &us)
	adm_test_crud(a, &us)
	adm_test_history(a, &us)
	adm_test_cascade(a, &us)
	assert1(a.site.writes >= 10)
	auth_password_set_iterations(0)
	User_free(us.root)
	User_free(us.staff)
	User_free(us.viewer)
	User_free(us.nobody)
	User_free(us.plain)
	User_free(us.deleter)
