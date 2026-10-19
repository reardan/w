# The example library app's web layer (issue #754, unit U5.2; README.md):
# U4.1 viewsets over the release-2 models with U3.4 serializers, filters
# and paginators, U3.1/U3.2 session (with CSRF) and token authentication,
# U3.3 history routes and the U4.2 document at /openapi.json.
#
#   library_app* app = library_app_new(db)
#   ServerResponse* resp = library_app_dispatch(app, req)   # in process
#   library_app_mount(app, server)                          # on http_server
#
# Routes:
#   GET  /api/auth/csrf/      {"csrf_token"} + session cookie (anonymous session)
#   POST /api/auth/login/     {"username", "password"}, CSRF  -> {"id", "username", "csrf_token"} + new cookie
#   POST /api/auth/logout/    CSRF                            -> 204, cookie deleted
#   POST /api/auth/token/     {"username", "password", "name"} -> 201 {"token", "name"}
#   /api/authors/  /api/books/  /api/loans/   (viewsets; books and loans have <pk>/history/)
#   POST /api/books/<pk>/checkout/            a loan of the book for the requesting user
#   GET  /openapi.json
import examples.orm.library.library_orm_api
import libs.standard.orm.auth.auth_orm_api
import libs.standard.orm.auth.session_orm_api
import libs.standard.orm.auth.throttle
import libs.standard.orm.rest.viewset


struct library_app:
	orm_db* db
	orm_rest_router* router
	orm_viewset* authors
	orm_viewset* books
	orm_viewset* loans
	auth_login_throttle* logins
	list[char*] trusted        # CSRF trusted origins
	int is_secure              # requests arrive over HTTPS (served behind TLS)


# Registers every model the app uses (library, auth, session).
void library_app_register():
	library_register()
	auth_register()
	session_register()


# ---------------------------------------------------------------------------
# Viewsets

# Staff and other signed-in users see every book; anonymous visitors only
# published ones.
orm_queryset* library_books_qs(orm_rest_request* r, void* ctx):
	orm_queryset* qs = Book_objects(r.db)
	if (r.user == 0): return qs.filter(q_eq(c"status", Book_Status_pub()))
	return qs


orm_queryset* library_authors_qs(orm_rest_request* r, void* ctx):
	return Author_objects(r.db)


# Staff see every loan, other users their own.
orm_queryset* library_loans_qs(orm_rest_request* r, void* ctx):
	orm_queryset* qs = Loan_objects(r.db)
	if (r.user.is_staff): return qs
	return qs.filter(q_eq_int(c"borrower_id", r.user.id))


# perform_create: a new loan always belongs to the requesting user.
int library_loans_on_save(orm_rest_request* r, void* row, void* ctx):
	Loan* l = cast(Loan*, row)
	if (strcmp(r.action, c"create") == 0): l.borrower_id = r.user.id
	return 1


# POST /api/books/<pk>/checkout/: lends the book to the requesting user.
# Runs inside the request's history context, so the loan's history row
# names the user too.
ServerResponse* library_books_checkout(orm_rest_request* r, void* obj, void* ctx):
	Book* b = cast(Book*, obj)
	int on_loan = Loan_objects(r.db).filter(q_eq_int(c"book", b.id)).filter(q_isnull(c"returned_at", 1)).exists()
	if (on_loan < 0): return 0
	if (on_loan): return orm_rest_response_detail(409, c"Book is already on loan.")
	Loan* l = Loan_new()
	l.book_id = b.id
	l.borrower_id = r.user.id
	l.returned_at = 0
	if (Loan_save(r.db, l) == 0):
		Loan_free(l)
		return 0
	json_value* o = json_object()
	json_object_set(o, c"id", json_int(l.id))
	json_object_set(o, c"book", json_int(b.id))
	json_object_set(o, c"borrower_id", json_int(l.borrower_id))
	Loan_free(l)
	return orm_rest_response(201, o)


orm_viewset* library_authors_viewset(orm_db* db):
	orm_viewset* vs = orm_viewset_new(Author_desc(), db, library_authors_qs, 0)
	orm_serializer_pk_list(vs.serializer, c"books")
	orm_filter_set* fs = orm_filter_new(Author_desc())
	orm_filter_allow(fs, c"name", c"exact,icontains")
	orm_filter_search(fs, c"name")
	orm_filter_search(fs, c"email")
	orm_filter_ordering(fs, c"name")
	orm_viewset_filter(vs, fs)
	orm_viewset_paginator(vs, orm_paginator_limit_offset(10))
	orm_viewset_permission(vs, orm_perm_django_model_permissions_or_anon_read_only())
	return vs


orm_viewset* library_books_viewset(orm_db* db):
	orm_serializer* ser = orm_serializer_new(Book_desc())
	orm_serializer_source(ser, c"author_name", c"author__name")
	orm_filter_set* fs = orm_filter_new(Book_desc())
	orm_filter_allow(fs, c"status", c"exact")
	orm_filter_allow(fs, c"author", c"exact")
	orm_filter_allow(fs, c"price", c"gte,lte")
	orm_filter_allow(fs, c"page_count", c"gte,lte,isnull")
	orm_filter_allow(fs, c"author__name", c"icontains")
	orm_filter_search(fs, c"title")
	orm_filter_ordering(fs, c"price")
	orm_filter_ordering(fs, c"title")
	orm_filter_ordering(fs, c"page_count")
	orm_viewset* vs = orm_viewset_new(Book_desc(), db, library_books_qs, 0)
	orm_viewset_serializer(vs, ser)
	orm_viewset_filter(vs, fs)
	orm_viewset_paginator(vs, orm_paginator_client_size(orm_paginator_page_number(2), c"page_size", 50))
	orm_viewset_permission(vs, orm_perm_django_model_permissions_or_anon_read_only())
	orm_viewset_history(vs, orm_rest_history_json, 0)
	orm_rest_action* checkout = orm_viewset_action(vs, c"checkout", c"POST", 1, library_books_checkout, 0)
	orm_rest_action_permission(checkout, orm_perm_is_authenticated())
	return vs


orm_viewset* library_loans_viewset(orm_db* db):
	orm_serializer* ser = orm_serializer_new(Loan_desc())
	orm_serializer_read_only(ser, c"borrower_id")
	orm_serializer_source(ser, c"book_title", c"book__title")
	orm_filter_set* fs = orm_filter_new(Loan_desc())
	orm_filter_allow(fs, c"returned_at", c"isnull")
	orm_viewset* vs = orm_viewset_new(Loan_desc(), db, library_loans_qs, 0)
	orm_viewset_serializer(vs, ser)
	orm_viewset_filter(vs, fs)
	orm_viewset_paginator(vs, orm_paginator_cursor(c"-loaned_at", 2))
	orm_viewset_permission(vs, orm_perm_is_authenticated())
	orm_viewset_hooks(vs, library_loans_on_save, 0, 0)
	orm_viewset_history(vs, orm_rest_history_json, 0)
	return vs


# The app over db (models registered here). 0 when a viewset is refused
# (its configuration error is printed).
library_app* library_app_new(orm_db* db):
	library_app_register()
	library_app* app = new library_app()
	app.db = db
	app.trusted = new list[char*]
	app.logins = login_throttle_new(5, 20, 300)
	app.authors = library_authors_viewset(db)
	app.books = library_books_viewset(db)
	app.loans = library_loans_viewset(db)
	orm_rest_router* rt = orm_rest_router_new()
	rt.db = db
	int ok = orm_rest_router_register(rt, c"/api/authors", app.authors)
	ok = ok && orm_rest_router_register(rt, c"/api/books", app.books)
	ok = ok && orm_rest_router_register(rt, c"/api/loans", app.loans)
	if (ok == 0):
		print2(c"library app: ")
		println2(rt.error)
		return 0
	orm_rest_router_openapi(rt, c"/openapi.json", c"Library API", c"2.0.0")
	app.router = rt
	return app


# ---------------------------------------------------------------------------
# Authentication endpoints (/api/auth/...)

ServerResponse* library_json(int status, json_value* body):
	return orm_rest_response(status, body)


ServerResponse* library_with_cookie(ServerResponse* resp, auth_session* s):
	char* cookie = session_cookie_header(s)
	if (cookie != 0):
		server_response_add_header(resp, c"Set-Cookie", cookie)
		free(cookie)
	return resp


# The session named by the request's cookie, or 0.
auth_session* library_request_session(library_app* app, ServerRequest* req):
	char* raw = session_cookie_value(server_request_header(req, c"cookie"))
	if (raw == 0): return 0
	auth_session* s = session_load(app.db, raw)
	free(raw)
	return s


# Django's CSRF check of an unsafe request against s: 0, or the reason.
char* library_csrf_reason(library_app* app, ServerRequest* req, auth_session* s):
	csrf_request* cr = csrf_request_new(req.method, server_request_header(req, c"host"), app.is_secure)
	cr.origin = server_request_header(req, c"origin")
	cr.referer = server_request_header(req, c"referer")
	cr.token = server_request_header(req, c"x-csrftoken")
	char* why = csrf_check_session(s, cr, app.trusted)
	free(cast(char*, cr))
	return why


ServerResponse* library_csrf_failed(char* why):
	char* msg = orm_rest_concat(c"CSRF Failed: ", why)
	ServerResponse* resp = orm_rest_response_detail(403, msg)
	free(msg)
	return resp


# A string member of a JSON object body, or 0.
char* library_body_text(json_value* body, char* key):
	if (body == 0 || body.type != json_type_object()): return 0
	json_value* v = json_object_get(body, key)
	if (v == 0 || v.type != json_type_string()): return 0
	return v.string_value


# authenticate_throttled with the request's credentials; 0 and *resp set
# on failure.
User* library_login_user(library_app* app, json_value* body, ServerResponse** resp):
	char* username = library_body_text(body, c"username")
	char* password = library_body_text(body, c"password")
	if (username == 0 || password == 0):
		resp[0] = orm_rest_response_detail(400, c"username and password are required.")
		return 0
	User* u = authenticate_throttled(app.db, app.logins, username, password, c"local")
	if (u != 0): return u
	if (strcmp(orm_db_error(app.db), AUTH_THROTTLED()) == 0):
		resp[0] = orm_rest_response_detail(429, c"Too many failed logins.")
	else if (strcmp(orm_db_error(app.db), AUTH_INVALID_LOGIN()) == 0):
		resp[0] = orm_rest_response_detail(400, c"Unable to log in with provided credentials.")
	else:
		resp[0] = orm_rest_response_detail(500, orm_db_error(app.db))
	return 0


# GET /api/auth/csrf/: a CSRF token for the request's session, creating an
# anonymous session (and cookie) when there is none.
ServerResponse* library_auth_csrf(library_app* app, ServerRequest* req):
	auth_session* s = library_request_session(app, req)
	if (s == 0): s = session_create(app.db, 0)
	if (s == 0): return orm_rest_response_detail(500, orm_db_error(app.db))
	char* tok = csrf_token(s)
	session_save(app.db, s)
	json_value* o = json_object()
	json_object_set(o, c"csrf_token", json_string(tok))
	free(tok)
	ServerResponse* resp = library_with_cookie(library_json(200, o), s)
	auth_session_free(s)
	return resp


# POST /api/auth/login/: Django's login view as JSON. Needs the session
# cookie and CSRF token from /api/auth/csrf/; answers with the rotated
# session cookie and a fresh CSRF token (login drops the old secret).
ServerResponse* library_auth_login(library_app* app, ServerRequest* req):
	auth_session* s = library_request_session(app, req)
	char* why = library_csrf_reason(app, req, s)
	if (why != 0):
		if (s != 0): auth_session_free(s)
		return library_csrf_failed(why)
	json_value* body = json_parse(req.body)
	ServerResponse* resp = 0
	User* u = library_login_user(app, body, &resp)
	if (body != 0): json_free(body)
	if (u == 0):
		if (s != 0): auth_session_free(s)
		return resp
	auth_session* s2 = session_login(app.db, s, u)
	if (s2 == 0):
		User_free(u)
		return orm_rest_response_detail(500, orm_db_error(app.db))
	char* tok = csrf_token(s2)
	session_save(app.db, s2)
	json_value* o = json_object()
	json_object_set(o, c"id", json_int(u.id))
	json_object_set(o, c"username", json_string(u.username))
	json_object_set(o, c"csrf_token", json_string(tok))
	free(tok)
	resp = library_with_cookie(library_json(200, o), s2)
	User_free(u)
	auth_session_free(s2)
	if (s != 0 && s != s2): auth_session_free(s)
	return resp


# POST /api/auth/logout/ (session + CSRF): flushes the session.
ServerResponse* library_auth_logout(library_app* app, ServerRequest* req):
	auth_session* s = library_request_session(app, req)
	if (s == 0): return orm_rest_response_detail(403, c"Authentication credentials were not provided.")
	char* why = library_csrf_reason(app, req, s)
	if (why != 0):
		auth_session_free(s)
		return library_csrf_failed(why)
	session_logout(app.db, s)
	auth_session_free(s)
	ServerResponse* resp = server_response_new(204)
	char* gone = session_cookie_delete_header()
	server_response_add_header(resp, c"Set-Cookie", gone)
	free(gone)
	return resp


# POST /api/auth/token/: DRF's obtain_auth_token with a token name. The
# raw token is returned once; only its digest is stored.
ServerResponse* library_auth_token(library_app* app, ServerRequest* req):
	json_value* body = json_parse(req.body)
	ServerResponse* resp = 0
	User* u = library_login_user(app, body, &resp)
	if (u == 0):
		if (body != 0): json_free(body)
		return resp
	char* name = library_body_text(body, c"name")
	if (name == 0): name = c"api"
	char* raw = token_create(app.db, u.id, name, 0)
	if (raw == 0):
		resp = orm_rest_response_detail(400, c"A token with this name already exists.")
	else:
		json_value* o = json_object()
		json_object_set(o, c"token", json_string(raw))
		json_object_set(o, c"name", json_string(name))
		resp = library_json(201, o)
		free(raw)
	json_free(body)
	User_free(u)
	return resp


# The /api/auth/ routes; 0 when path is not one of them.
ServerResponse* library_auth_dispatch(library_app* app, ServerRequest* req):
	char* p = req.path
	if (starts_with(p, c"/api/auth/") == 0): return 0
	char* name = orm_rest_strip_slash(&p[10])
	ServerResponse* resp = 0
	char* want = c"POST"
	if (strcmp(name, c"csrf") == 0): want = c"GET"
	if (strcmp(name, c"csrf") != 0 && strcmp(name, c"login") != 0 && strcmp(name, c"logout") != 0 && strcmp(name, c"token") != 0):
		resp = orm_rest_response_detail(404, c"Not found.")
	else if (strcmp(req.method, want) != 0):
		char* msg = orm_rest_concat3(c"Method \"", req.method, c"\" not allowed.")
		resp = orm_rest_response_detail(405, msg)
		free(msg)
		server_response_add_header(resp, c"Allow", want)
	else if (strcmp(name, c"csrf") == 0): resp = library_auth_csrf(app, req)
	else if (strcmp(name, c"login") == 0): resp = library_auth_login(app, req)
	else if (strcmp(name, c"logout") == 0): resp = library_auth_logout(app, req)
	else: resp = library_auth_token(app, req)
	free(name)
	return resp


# ---------------------------------------------------------------------------
# Entry points

# One request in process: the auth routes, then the router (viewsets and
# /openapi.json).
ServerResponse* library_app_dispatch(library_app* app, ServerRequest* req):
	ServerResponse* resp = library_auth_dispatch(app, req)
	if (resp != 0): return resp
	orm_rest_env env
	env.db = app.db
	env.is_secure = app.is_secure
	env.remote_addr = c"local"
	return orm_rest_router_dispatch_env(app.router, req, &env)


void library_auth_route(RequestContext* rc, void* user_data):
	library_app* app = cast(library_app*, user_data)
	ServerResponse* resp = library_auth_dispatch(app, rc.request)
	if (resp == 0): resp = orm_rest_response_detail(404, c"Not found.")
	orm_rest_write_context(rc, resp)
	server_response_free(resp)


# Serves the app on s: the auth routes, every viewset and /openapi.json.
void library_app_mount(library_app* app, ServerContext* s):
	server_route(s, c"*", c"/api/auth/*", library_auth_route, cast(void*, app))
	orm_rest_router_mount(app.router, s)
