# U4.3 end-to-end scenarios over a small library app (list and detail
# pages, create / edit forms, login and logout, CSRF, mounts, 404 / 405,
# per-request transactions), shared by orm_web_test (SQLite in memory) and
# orm_web_postgres_test. Requests go through the in-process client
# (client.w) unless noted.
import tests.orm.fixtures.library_orm_api
import tests.orm.fixtures.library_schema
import tests.orm.orm_session_cases
import libs.standard.orm.web.client
import libs.standard.orm.web.forms
import libs.standard.orm.rest.viewset
import lib.assert


struct webapp:
	orm_router* rt
	orm_router* accounts
	orm_web_app* app
	orm_web_db_source* src
	orm_web_csrf_config* csrf
	orm_db* db               # setup / inspection connection
	int shared               # requests use db itself (SQLite in memory)
	int mark


void wa_check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


void wa_mark(webapp* w):
	w.mark = w.db.query_count
	for char* q in w.db.query_log: free(q)
	w.db.query_log.clear()


# Asserts the statements run on the shared connection since the last
# mark (SQLite only: pooled PostgreSQL connections count separately).
void wa_queries(webapp* w, int n):
	if (w.shared == 0): return
	int got = w.db.query_count - w.mark
	if (got != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(got))
		for char* q in w.db.query_log: println(q)
	assert_equal(n, got)
	wa_mark(w)


ServerResponse* wa_server_error(orm_web_request* r):
	return orm_web_text(500, orm_db_error(r.db))


# ---------------------------------------------------------------------------
# Handlers

ServerResponse* book_list(orm_web_request* r, void* ctx):
	orm_result* res = Book_objects(r.db).select_related(c"author").prefetch_related(c"tags").order_by(c"title").all()
	if (res == 0): return wa_server_error(r)
	orm_tpl_ctx* t = orm_web_context(r)
	orm_tpl_set(t, c"books", orm_tpl_result(t, res))
	ServerResponse* resp = orm_web_render(r, c"book_list.html", t, 200)
	orm_result_free(res)
	return resp


orm_result* wa_get_book(orm_web_request* r):
	int id = orm_web_param_int(r, c"id", 0)
	return Book_objects(r.db).select_related(c"author").prefetch_related(c"tags").get(q_eq_int(c"id", id))


ServerResponse* wa_missing(orm_web_request* r):
	if (orm_error_is_does_not_exist(r.db)): return orm_web_not_found()
	return wa_server_error(r)


ServerResponse* book_detail(orm_web_request* r, void* ctx):
	orm_result* res = wa_get_book(r)
	if (res == 0): return wa_missing(r)
	orm_tpl_ctx* t = orm_web_context(r)
	orm_tpl_set(t, c"book", orm_tpl_row(t, Book_desc(), res.rows[0]))
	ServerResponse* resp = orm_web_render(r, c"book_detail.html", t, 200)
	orm_result_free(res)
	return resp


# Shared by create and edit: bind, validate, save, redirect or re-render.
ServerResponse* wa_book_form(orm_web_request* r, void* instance):
	webapp* w = cast(webapp*, orm_web_app_of(r).not_found_ctx)
	orm_form* f = orm_form_new(Book_desc())
	orm_form_set_instance(f, instance)
	if (orm_form_fk_choices(f, r.db, c"author", c"name") == 0):
		orm_form_free(f)
		return wa_server_error(r)
	if (strcmp(r.method, c"POST") == 0):
		orm_form_bind_request(f, r)
		if (orm_form_is_valid(f, r.db)):
			Book* b = cast(Book*, orm_form_save(f))
			if (b != 0):
				char* url = orm_reverse1_int(w.rt, c"book_detail", c"id", b.id)
				if (instance == 0): Book_free(b)
				orm_form_free(f)
				return orm_web_redirect_take(url)
	orm_tpl_ctx* t = orm_web_context(r)
	orm_tpl_set(t, c"form", orm_form_tpl(t, f, orm_web_csrf_token(r)))
	ServerResponse* resp = orm_web_render(r, c"book_form.html", t, 200)
	orm_form_free(f)
	return resp


ServerResponse* book_create(orm_web_request* r, void* ctx):
	ServerResponse* login = orm_web_login_required(r, c"/accounts/login/")
	if (login != 0): return login
	return wa_book_form(r, 0)


ServerResponse* book_edit(orm_web_request* r, void* ctx):
	ServerResponse* login = orm_web_login_required(r, c"/accounts/login/")
	if (login != 0): return login
	if (orm_web_has_perm(r, c"library.change_book") == 0): return orm_web_forbidden(c"permission denied")
	orm_result* res = wa_get_book(r)
	if (res == 0): return wa_missing(r)
	ServerResponse* resp = wa_book_form(r, res.rows[0])
	orm_result_free(res)
	return resp


# POST /tags/ (token in the X-CSRFToken header): 201 "created <id> of
# <count>", or 400 with the form's errors and the count, proving the
# request's transaction survived a failed INSERT.
ServerResponse* tag_create(orm_web_request* r, void* ctx):
	orm_form* f = orm_form_new(Tag_desc())
	orm_form_bind_request(f, r)
	ServerResponse* resp = 0
	Tag* t = 0
	if (orm_form_is_valid(f, r.db)): t = cast(Tag*, orm_form_save(f))
	int n = Tag_objects(r.db).count()
	string_builder* s = string_new()
	if (t != 0):
		string_append(s, c"created ")
		string_append_int(s, t.id)
		Tag_free(t)
	else:
		char* errors = orm_form_errors_text(f)
		string_append(s, errors)
		free(errors)
	string_append(s, c" of ")
	string_append_int(s, n)
	int status = 201
	if (t == 0): status = 400
	resp = orm_web_text(status, s.data)
	string_free(s)
	orm_form_free(f)
	return resp


ServerResponse* login_view(orm_web_request* r, void* ctx):
	orm_tpl_ctx* t = orm_web_context(r)
	if (strcmp(r.method, c"POST") == 0):
		User* u = authenticate(r.db, orm_web_form_get(r, c"username"), orm_web_form_get(r, c"password"))
		if (u != 0):
			int ok = orm_web_login(r, u)
			User_free(u)
			orm_tpl_ctx_free(t)
			if (ok == 0): return wa_server_error(r)
			char* next = orm_web_query_get(r, c"next")
			if (next == 0): next = c"/books/"
			return orm_web_redirect(next)
		orm_tpl_set_str(t, c"error", c"Please enter a correct username and password.")
	return orm_web_render(r, c"login.html", t, 200)


ServerResponse* logout_view(orm_web_request* r, void* ctx):
	if (orm_web_logout(r) == 0): return wa_server_error(r)
	return orm_web_redirect(c"/books/")


# A stand-in for U4.1's viewset dispatch: (viewset, request, tail).
ServerResponse* fake_viewset(void* viewset, orm_web_request* r, char* tail):
	json_value* o = json_object()
	json_object_set(o, c"viewset", json_string(cast(char*, viewset)))
	json_object_set(o, c"method", json_string(r.method))
	json_object_set(o, c"tail", json_string(tail))
	if (r.user != 0): json_object_set(o, c"user", json_string(r.user.username))
	else: json_object_set(o, c"user", json_null())
	char* text = json_stringify(o)
	json_free(o)
	ServerResponse* resp = orm_web_json(200, text)
	free(text)
	return resp


orm_queryset* rest_books_qs(orm_rest_request* r, void* ctx):
	return Book_objects(r.db).order_by(c"id")


# Mounts a real U4.1 viewset: its dispatch runs on the request's db
# connection and transaction.
ServerResponse* rest_mount(void* vs, orm_web_request* r, char* tail):
	orm_rest_env env
	env.db = r.db
	env.is_secure = r.is_secure
	env.remote_addr = 0
	return orm_rest_dispatch_env(cast(orm_viewset*, vs), r.req, tail, &env)


# Writes a tag, then fails: the request transaction must roll it back.
ServerResponse* boom(orm_web_request* r, void* ctx):
	Tag* t = Tag_new()
	t.name = c"boom"
	int ok = Tag_save(r.db, t)
	Tag_free(t)
	if (ok == 0): return wa_server_error(r)
	if (ctx != 0):
		orm_web_fail(r)
		return orm_web_text(200, c"soft failure")
	return orm_web_text(500, c"boom")


ServerResponse* page_not_found(orm_web_request* r, void* ctx):
	char* path = orm_html_escape(r.path)
	char* html = orm_tpl_concat3(c"<h1>Page not found</h1><p>", path, c"</p>")
	free(path)
	return orm_web_html_take(404, html)


webapp* webapp_new(orm_db* db, orm_web_db_source* src, int shared):
	webapp* w = new webapp()
	w.db = db
	w.src = src
	w.shared = shared
	w.accounts = orm_router_new()
	orm_router_add(w.accounts, c"GET,POST", c"/login/", login_view, 0, c"login")
	orm_router_post(w.accounts, c"/logout/", logout_view, 0, c"logout")
	w.rt = orm_router_new()
	orm_router_get(w.rt, c"/books/", book_list, 0, c"book_list")
	orm_router_get(w.rt, c"/books/<int:id>/", book_detail, 0, c"book_detail")
	orm_router_add(w.rt, c"GET,POST", c"/books/new/", book_create, 0, c"book_create")
	orm_router_add(w.rt, c"GET,POST", c"/books/<int:id>/edit/", book_edit, 0, c"book_edit")
	orm_router_post(w.rt, c"/tags/", tag_create, 0, c"tag_create")
	orm_router_get(w.rt, c"/boom/", boom, 0, 0)
	orm_router_get(w.rt, c"/soft-fail/", boom, c"soft", 0)
	orm_router_include(w.rt, c"/accounts/", w.accounts, 0)
	orm_route_csrf_exempt(orm_router_mount(w.rt, c"/api/", fake_viewset, c"books"))
	orm_viewset* vs = orm_viewset_new(Book_desc(), db, rest_books_qs, 0)
	orm_route_csrf_exempt(orm_router_mount(w.rt, c"/rest/books", rest_mount, cast(void*, vs)))
	assert1(orm_router_error(w.rt) == 0)
	w.app = orm_web_app_new(w.rt)
	w.app.not_found = page_not_found
	w.app.not_found_ctx = cast(void*, w)
	w.csrf = orm_web_csrf_config_new()
	orm_web_app_use(w.app, orm_web_security_middleware, orm_web_security_new())
	orm_web_app_use(w.app, orm_web_db_middleware, src)
	orm_web_app_use(w.app, orm_web_session_middleware, 0)
	orm_web_app_use(w.app, orm_web_auth_middleware, 0)
	orm_web_app_use(w.app, orm_web_csrf_middleware, w.csrf)
	orm_web_app_templates(w.app, c"tests/orm/templates")
	return w


# ---------------------------------------------------------------------------
# Scenarios

struct wa_fixture:
	Author* frank
	Author* ursula
	Book* dune
	Book* earthsea
	User* alice
	User* bob


void wa_seed(webapp* w, wa_fixture* fx):
	orm_db* db = w.db
	wa_check(db, library_create_schema(db))
	wa_check(db, sess_create_schema(db))
	wa_check(db, orm_auth_create_auth_permissions(db) >= 0)
	wa_check(db, orm_auth_create_model_permissions(db, Book_desc()) >= 0)
	fx.frank = Author_new()
	fx.frank.name = c"Frank Herbert"
	fx.frank.email = c"frank@example.org"
	wa_check(db, Author_save(db, fx.frank))
	fx.ursula = Author_new()
	fx.ursula.name = c"Ursula K. Le Guin"
	fx.ursula.email = c"ursula@example.org"
	wa_check(db, Author_save(db, fx.ursula))
	Tag* sf = Tag_new()
	sf.name = c"sf"
	wa_check(db, Tag_save(db, sf))
	fx.dune = Book_new()
	fx.dune.title = c"Dune"
	fx.dune.author_id = fx.frank.id
	fx.dune.price = c"9.99"
	fx.dune.status = c"pub"
	fx.dune.pages = 412
	wa_check(db, Book_save(db, fx.dune))
	fx.earthsea = Book_new()
	fx.earthsea.title = c"A Wizard of <Earthsea>"
	fx.earthsea.author_id = fx.ursula.id
	fx.earthsea.price = c"7.50"
	fx.earthsea.pages__isnull = 1
	wa_check(db, Book_save(db, fx.earthsea))
	list[void*] tags = new list[void*]
	tags.push(cast(void*, sf))
	wa_check(db, orm_m2m_add(db, Book_desc(), fx.dune, c"tags", tags) >= 0)
	tags.free()
	Tag_free(sf)
	fx.alice = create_user(db, c"alice", c"alice@example.org", c"s3cret")
	wa_check(db, fx.alice != 0)
	fx.bob = create_user(db, c"bob", c"bob@example.org", c"hunter2")
	wa_check(db, fx.bob != 0)
	Permission* p = permission_get(db, c"library.change_book")
	wa_check(db, p != 0)
	wa_check(db, user_add_permission(db, fx.alice, p))
	Permission_free(p)


void wa_status(ServerResponse* resp, int status):
	if (resp.status != status):
		print(c"expected status ")
		println(itoa(status))
		print(c"got ")
		println(itoa(resp.status))
		println(orm_web_client_body(resp))
	assert_equal(status, resp.status)


# The masked token of the csrfmiddlewaretoken input in html (owned).
char* wa_token(char* html):
	char* marker = c"name=\"csrfmiddlewaretoken\" value=\""
	int at = index_of(html, marker)
	asserts(c"page has a CSRF input", at >= 0)
	char* start = html + at + strlen(marker)
	int end = index_of(start, c"\"")
	assert_equal(64, end)
	return substring(start, 0, end)


char* wa_form_with(char* body, char* token):
	return orm_tpl_concat3(body, c"&csrfmiddlewaretoken=", token)


void wa_test_pages(webapp* w, wa_fixture* fx):
	orm_web_client* c = orm_web_client_new(w.app)
	wa_mark(w)
	ServerResponse* resp = orm_web_client_get(c, c"/books/")
	wa_status(resp, 200)
	char* body = orm_web_client_body(resp)
	assert_contains(body, c"<title>Books</title>")
	assert_contains(body, c"<li class=\"first\"><a href=\"/books/2/\">A Wizard of &lt;Earthsea&gt;</a> by Ursula K. Le Guin (0 tags)</li>")
	assert_contains(body, c"<li><a href=\"/books/1/\">Dune</a> by Frank Herbert (1 tags)</li>")
	assert_contains(body, c"<a href=\"/accounts/login/\">Log in</a>")
	assert_strings_equal(c"text/html; charset=utf-8", server_response_get_header(resp, c"content-type"))
	assert_strings_equal(c"DENY", server_response_get_header(resp, c"x-frame-options"))
	assert_strings_equal(c"nosniff", server_response_get_header(resp, c"x-content-type-options"))
	assert_strings_equal(c"Cookie", server_response_get_header(resp, c"vary"))
	assert1(server_response_get_header(resp, c"set-cookie") == 0)
	# BEGIN, books with authors, tags prefetch, COMMIT; no session row.
	wa_queries(w, 4)
	server_response_free(resp)

	resp = orm_web_client_get(c, c"/books/1/")
	wa_status(resp, 200)
	body = orm_web_client_body(resp)
	assert_contains(body, c"<title>Dune</title>")
	assert_contains(body, c"<p>Author: Frank Herbert (#1)</p>")
	assert_contains(body, c"<p>Status: PUB</p>")
	assert_contains(body, c"<p>Pages: 412</p>")
	assert_contains(body, c"<p>Tags: sf</p>")
	server_response_free(resp)
	resp = orm_web_client_get(c, c"/books/2/")
	assert_contains(orm_web_client_body(resp), c"<p>Pages: unknown</p>")
	assert_contains(orm_web_client_body(resp), c"<p>Status: DRAFT</p>")
	server_response_free(resp)

	resp = orm_web_client_get(c, c"/books/99/")
	wa_status(resp, 404)
	server_response_free(resp)
	resp = orm_web_client_get(c, c"/nope/<x>")
	wa_status(resp, 404)
	assert_strings_equal(c"<h1>Page not found</h1><p>/nope/&lt;x&gt;</p>", orm_web_client_body(resp))
	server_response_free(resp)
	resp = orm_web_client_post_form(c, c"/books/", c"")
	wa_status(resp, 405)
	assert_strings_equal(c"GET, HEAD", server_response_get_header(resp, c"allow"))
	server_response_free(resp)
	resp = orm_web_client_request(c, c"HEAD", c"/books/", 0, 0, 0, 0)
	wa_status(resp, 200)
	assert_equal(0, resp.body_len)
	server_response_free(resp)
	resp = orm_web_client_get(c, c"/rest/books/")
	assert1(resp.status == 401 || resp.status == 403)
	server_response_free(resp)
	resp = orm_web_client_request(c, c"DELETE", c"/api/books/3/", 0, 0, 0, 0)
	wa_status(resp, 200)
	assert_strings_equal(c"{\"viewset\":\"books\",\"method\":\"DELETE\",\"tail\":\"/books/3/\",\"user\":null}", orm_web_client_body(resp))
	server_response_free(resp)
	orm_web_client_free(c)


void wa_test_transactions(webapp* w):
	orm_web_client* c = orm_web_client_new(w.app)
	int tags = Tag_objects(w.db).count()
	ServerResponse* resp = orm_web_client_get(c, c"/boom/")
	wa_status(resp, 500)
	server_response_free(resp)
	assert_equal(tags, Tag_objects(w.db).count())
	resp = orm_web_client_get(c, c"/soft-fail/")
	wa_status(resp, 200)
	server_response_free(resp)
	assert_equal(tags, Tag_objects(w.db).count())
	assert1(w.src.rollbacks >= 2)
	orm_web_client_free(c)


void wa_test_login_and_forms(webapp* w, wa_fixture* fx):
	orm_web_client* c = orm_web_client_new(w.app)
	# Anonymous form pages redirect to the login page.
	ServerResponse* resp = orm_web_client_get(c, c"/books/new/")
	wa_status(resp, 302)
	assert_strings_equal(c"/accounts/login/?next=/books/new/", server_response_get_header(resp, c"location"))
	server_response_free(resp)

	# The login page issues a CSRF token, which saves a new anonymous session.
	wa_mark(w)
	resp = orm_web_client_get(c, c"/accounts/login/")
	wa_status(resp, 200)
	assert_contains(server_response_get_header(resp, c"set-cookie"), c"sessionid=")
	assert_contains(server_response_get_header(resp, c"set-cookie"), c"HttpOnly")
	# BEGIN, INSERT session, UPDATE its data, COMMIT.
	wa_queries(w, 4)
	char* token = wa_token(orm_web_client_body(resp))
	char* anon_key = strclone(orm_web_client_cookie(c, c"sessionid"))
	server_response_free(resp)

	# POST without a token, with a bad token, with a foreign Origin.
	resp = orm_web_client_post_form(c, c"/accounts/login/", c"username=alice&password=s3cret")
	wa_status(resp, 403)
	assert_strings_equal(c"Forbidden (CSRF token missing.)", orm_web_client_body(resp))
	server_response_free(resp)
	resp = orm_web_client_post_form(c, c"/accounts/login/", c"username=alice&password=s3cret&csrfmiddlewaretoken=abc")
	wa_status(resp, 403)
	assert_strings_equal(c"Forbidden (CSRF token has incorrect length.)", orm_web_client_body(resp))
	server_response_free(resp)
	char* form = wa_form_with(c"username=alice&password=s3cret", token)
	orm_web_client_header(c, c"Origin", c"https://evil.example")
	resp = orm_web_client_post_form(c, c"/accounts/login/", form)
	wa_status(resp, 403)
	assert_contains(orm_web_client_body(resp), c"Origin checking failed")
	server_response_free(resp)
	orm_web_client_clear_headers(c)
	assert_equal(3, w.csrf.failures)

	# Wrong password: the page again, no login.
	char* bad = wa_form_with(c"username=alice&password=nope", token)
	resp = orm_web_client_post_form(c, c"/accounts/login/", bad)
	wa_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"Please enter a correct username and password.")
	server_response_free(resp)
	free(bad)

	# Login rotates the session key.
	orm_web_client_header(c, c"Origin", c"http://testserver")
	resp = orm_web_client_post_form(c, c"/accounts/login/?next=/books/new/", form)
	orm_web_client_clear_headers(c)
	wa_status(resp, 302)
	assert_strings_equal(c"/books/new/", server_response_get_header(resp, c"location"))
	server_response_free(resp)
	free(form)
	char* user_key = orm_web_client_cookie(c, c"sessionid")
	assert1(user_key != 0 && strcmp(user_key, anon_key) != 0)

	# The old token's secret was dropped at login.
	resp = orm_web_client_post_form(c, c"/books/new/", wa_form_with(c"title=x", token))
	wa_status(resp, 403)
	assert_strings_equal(c"Forbidden (CSRF cookie not set.)", orm_web_client_body(resp))
	server_response_free(resp)
	free(token)

	resp = orm_web_client_get(c, c"/books/new/")
	wa_status(resp, 200)
	char* page = orm_web_client_body(resp)
	assert_contains(page, c"Signed in as alice")
	assert_contains(page, c"<p><label for=\"id_title\">Title:</label> <input type=\"text\" name=\"title\" id=\"id_title\" maxlength=\"300\" required></p>")
	assert_contains(page, c"<select name=\"author\" id=\"id_author\" required><option value=\"\">---------</option><option value=\"1\">Frank Herbert</option><option value=\"2\">Ursula K. Le Guin</option></select>")
	assert_contains(page, c"<option value=\"draft\" selected>draft</option>")
	assert_contains(page, c"<input type=\"number\" name=\"price\" id=\"id_price\" step=\"0.01\" required>")
	token = wa_token(page)
	server_response_free(resp)

	# Invalid input: the same messages the serializer gives the REST layer.
	resp = orm_web_client_post_form(c, c"/books/new/", wa_form_with(c"title=&author=99&price=abc&status=nope&pages=", token))
	wa_status(resp, 200)
	page = orm_web_client_body(resp)
	assert_contains(page, c"<ul class=\"errorlist\"><li>This field may not be blank.</li></ul><p><label for=\"id_title\">")
	assert_contains(page, c"<li>Invalid pk &quot;99&quot; - object does not exist.</li>")
	assert_contains(page, c"<li>A valid number is required.</li>")
	assert_contains(page, c"<li>&quot;nope&quot; is not a valid choice.</li>")
	assert_contains(page, c"<option value=\"2\">Ursula")
	server_response_free(resp)

	# Valid urlencoded create.
	resp = orm_web_client_post_form(c, c"/books/new/", wa_form_with(c"title=The+Dispossessed&author=2&price=8.25&status=pub&pages=387", token))
	wa_status(resp, 302)
	char* location = strclone(server_response_get_header(resp, c"location"))
	server_response_free(resp)
	orm_result* made = Book_objects(w.db).get(q_eq(c"title", c"The Dispossessed"))
	wa_check(w.db, made != 0)
	Book* b = Book_rows(made)[0]
	char* want = orm_tpl_concat3(c"/books/", itoa(b.id), c"/")
	assert_strings_equal(want, location)
	assert_equal(2, b.author_id)
	assert_strings_equal(c"8.25", b.price)
	assert_equal(387, b.pages)
	orm_result_free(made)
	free(want)
	free(location)

	# Multipart create, with a file part the model ignores.
	string_builder* mp = string_new()
	char* parts = c"title\x01Left Hand\x02author\x011\x02price\x013.00\x02status\x01draft"
	list[char*] fields = split(parts, 2)
	for char* fv in fields:
		list[char*] kv = split(fv, 1)
		string_append(mp, c"--XyZ\x0d\x0aContent-Disposition: form-data; name=\"")
		string_append(mp, kv[0])
		string_append(mp, c"\"\x0d\x0a\x0d\x0a")
		string_append(mp, kv[1])
		string_append(mp, c"\x0d\x0a")
		for char* x in kv: free(x)
		kv.free()
		free(fv)
	fields.free()
	string_append(mp, c"--XyZ\x0d\x0aContent-Disposition: form-data; name=\"csrfmiddlewaretoken\"\x0d\x0a\x0d\x0a")
	string_append(mp, token)
	string_append(mp, c"\x0d\x0a--XyZ\x0d\x0aContent-Disposition: form-data; name=\"cover\"; filename=\"c.txt\"\x0d\x0aContent-Type: text/plain\x0d\x0a\x0d\x0ahello\x0d\x0a--XyZ--\x0d\x0a")
	resp = orm_web_client_request(c, c"POST", c"/books/new/", c"multipart/form-data; boundary=XyZ", mp.data, mp.length, 0)
	string_free(mp)
	wa_status(resp, 302)
	server_response_free(resp)
	orm_result* left = Book_objects(w.db).get(q_eq(c"title", c"Left Hand"))
	wa_check(w.db, left != 0)
	assert_strings_equal(c"draft", Book_rows(left)[0].status)
	orm_result_free(left)

	# Edit (alice has library.change_book): unbound form shows the row.
	resp = orm_web_client_get(c, c"/books/1/edit/")
	wa_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"value=\"Dune\"")
	assert_contains(orm_web_client_body(resp), c"<option value=\"1\" selected>Frank Herbert</option>")
	server_response_free(resp)
	resp = orm_web_client_post_form(c, c"/books/1/edit/", wa_form_with(c"title=Dune+Messiah&author=1&price=10.00&status=pub&pages=", token))
	wa_status(resp, 302)
	assert_strings_equal(c"/books/1/", server_response_get_header(resp, c"location"))
	server_response_free(resp)
	resp = orm_web_client_get(c, c"/books/1/")
	assert_contains(orm_web_client_body(resp), c"<h1>Dune Messiah</h1>")
	assert_contains(orm_web_client_body(resp), c"<p>Pages: unknown</p>")
	server_response_free(resp)

	# Tag form through the X-CSRFToken header; a duplicate name is a field
	# error and the request's transaction stays usable afterwards.
	orm_web_client_header(c, c"X-CSRFToken", token)
	resp = orm_web_client_post_form(c, c"/tags/", c"name=fantasy")
	wa_status(resp, 201)
	assert_contains(orm_web_client_body(resp), c"created ")
	server_response_free(resp)
	resp = orm_web_client_post_form(c, c"/tags/", c"name=fantasy")
	wa_status(resp, 400)
	assert_strings_equal(c"{\"name\":[\"tag with this name already exists.\"]} of 2", orm_web_client_body(resp))
	server_response_free(resp)
	resp = orm_web_client_post_form(c, c"/tags/", c"name=")
	wa_status(resp, 400)
	assert_strings_equal(c"{\"name\":[\"This field may not be blank.\"]} of 2", orm_web_client_body(resp))
	server_response_free(resp)
	orm_web_client_clear_headers(c)

	# A real U4.1 viewset mounted under /rest/books sees the same session.
	resp = orm_web_client_get(c, c"/rest/books/1/")
	wa_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"\"title\":\"Dune Messiah\"")
	server_response_free(resp)

	# The mounted viewset sees the user; it is CSRF exempt.
	resp = orm_web_client_post_form(c, c"/api/books/", c"")
	wa_status(resp, 200)
	assert_contains(orm_web_client_body(resp), c"\"user\":\"alice\"")
	server_response_free(resp)

	# Logout deletes the cookie; the old key no longer logs in.
	char* old_key = strclone(orm_web_client_cookie(c, c"sessionid"))
	resp = orm_web_client_post_form(c, c"/accounts/logout/", wa_form_with(c"", token))
	wa_status(resp, 302)
	assert_contains(server_response_get_header(resp, c"set-cookie"), c"Max-Age=0")
	server_response_free(resp)
	assert1(orm_web_client_cookie(c, c"sessionid") == 0)
	orm_web_client_set_cookie(c, c"sessionid", old_key)
	resp = orm_web_client_get(c, c"/books/new/")
	wa_status(resp, 302)
	server_response_free(resp)
	free(old_key)
	free(anon_key)
	free(token)
	orm_web_client_free(c)

	# bob may create books but not edit them.
	orm_web_client* cb = orm_web_client_new(w.app)
	resp = orm_web_client_get(cb, c"/accounts/login/")
	char* tb = wa_token(orm_web_client_body(resp))
	server_response_free(resp)
	resp = orm_web_client_post_form(cb, c"/accounts/login/", wa_form_with(c"username=bob&password=hunter2", tb))
	wa_status(resp, 302)
	server_response_free(resp)
	resp = orm_web_client_get(cb, c"/books/1/edit/")
	wa_status(resp, 403)
	server_response_free(resp)
	free(tb)
	orm_web_client_free(cb)


# Form and REST serializer report identical errors for the same input.
void wa_test_form_matches_serializer(webapp* w):
	orm_params* p = orm_params_parse(c"title=&author=99&price=12345678.5&status=nope&pages=x")
	orm_form* f = orm_form_new(Book_desc())
	orm_form_bind(f, p)
	assert1(orm_form_is_valid(f, w.db) == 0)
	assert_equal(400, f.status)
	orm_serializer* ser = orm_serializer_new(Book_desc())
	orm_validation* v = orm_serializer_validate(ser, w.db, c"{\"title\": \"\", \"author\": \"99\", \"status\": \"nope\", \"price\": \"12345678.5\", \"pages\": \"x\"}", 0, 0)
	char* want = orm_validation_errors_text(v)
	char* got = orm_form_errors_text(f)
	assert_strings_equal(want, got)
	assert_contains(got, c"Ensure that there are no more than 8 digits in total.")
	assert_contains(got, c"A valid integer is required.")
	free(want)
	free(got)
	orm_validation_free(v)
	orm_serializer_free(ser)
	orm_form_free(f)
	orm_params_free(p)
	# Unbound: never valid; empty optional values become NULL.
	orm_form* g = orm_form_new(Book_desc())
	assert1(orm_form_is_valid(g, w.db) == 0)
	orm_params* q = orm_params_parse(c"title=T&author=1&price=1&pages=&published_at=")
	orm_form_bind(g, q)
	assert1(orm_form_is_valid(g, w.db))
	Book* nb = cast(Book*, orm_form_save(g))
	wa_check(w.db, nb != 0)
	assert_equal(1, nb.pages__isnull)
	assert1(nb.published_at == 0)
	assert_strings_equal(c"draft", nb.status)
	wa_check(w.db, Book_delete(w.db, nb) > 0)
	Book_free(nb)
	orm_params_free(q)
	orm_form_free(g)


void orm_web_run(webapp* w):
	library_register()
	auth_password_set_iterations(1000)
	wa_fixture fx
	wa_seed(w, &fx)
	wa_test_pages(w, &fx)
	wa_test_transactions(w)
	wa_test_login_and_forms(w, &fx)
	wa_test_form_matches_serializer(w)
	auth_password_set_iterations(0)
