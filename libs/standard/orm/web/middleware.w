# w-orm web application and middleware (unit U4.3,
# docs/projects/orm/u4_3.md): a router plus an ordered middleware chain,
# served through libs/standard/web/http_server.w.
#
#   orm_web_app* app = orm_web_app_new(router)
#   orm_web_app_use(app, orm_web_security_middleware, orm_web_security_new())
#   orm_web_app_use(app, orm_web_db_middleware, orm_web_db_source_new(open_db, 0))
#   orm_web_app_use(app, orm_web_session_middleware, 0)
#   orm_web_app_use(app, orm_web_auth_middleware, 0)
#   orm_web_app_use(app, orm_web_csrf_middleware, orm_web_csrf_config_new())
#   orm_web_app_templates(app, c"templates")
#   ServerContext* s = server_context_new(c"127.0.0.1", 8000, orm_web_app_server_handler, app)
#
# A middleware is fn(request, ctx) -> response that calls
# orm_web_next(request) to run the rest of the chain (and finally the
# routed handler), so it can act before and after. The route is resolved
# before the chain runs, so middleware can read request.route (the CSRF
# middleware honours orm_route_csrf_exempt). Order matters: the db
# middleware must run before session / auth / CSRF, which use
# request.db; the session middleware before auth and CSRF.
#
# The db middleware gives every request its own orm_db from a source
# (opened by a factory, idle connections reused) and wraps the request in
# a transaction (Django's ATOMIC_REQUESTS): committed when the response
# is below 500 and the handler did not call orm_web_fail, rolled back
# otherwise; the connection goes back to the source afterwards.
import libs.standard.orm.web.router
import libs.standard.orm.web.templates
import libs.standard.orm.auth.csrf
import libs.standard.orm.auth.perms
import libs.standard.orm.atomic


type orm_web_middleware_fn = fn(orm_web_request*, void*) -> ServerResponse*


struct orm_web_mw:
	orm_web_middleware_fn* fn
	void* ctx


struct orm_web_app:
	orm_router* router                 # borrowed
	list[orm_web_mw*] middleware
	orm_tpl_engine* templates          # owned, or 0
	orm_web_handler* not_found         # optional 404 page
	void* not_found_ctx
	int secure                         # treat every request as HTTPS
	int requests                       # requests handled


orm_web_app* orm_web_app_new(orm_router* router):
	orm_web_app* app = new orm_web_app()
	app.router = router
	app.middleware = new list[orm_web_mw*]
	return app


# Appends a middleware; earlier ones wrap later ones.
void orm_web_app_use(orm_web_app* app, orm_web_middleware_fn* fn, void* ctx):
	orm_web_mw* m = new orm_web_mw()
	m.fn = fn
	m.ctx = ctx
	app.middleware.push(m)


# Loads templates from dir (cached by the engine).
orm_tpl_engine* orm_web_app_templates(orm_web_app* app, char* dir):
	if (app.templates != 0): orm_tpl_engine_free(app.templates)
	app.templates = orm_tpl_engine_new(dir)
	return app.templates


void orm_web_app_free(orm_web_app* app):
	if (app == 0): return
	for orm_web_mw* m in app.middleware: free(cast(void*, m))
	app.middleware.free()
	orm_tpl_engine_free(app.templates)
	free(cast(void*, app))


orm_web_app* orm_web_app_of(orm_web_request* r):
	return cast(orm_web_app*, r.app)


# Runs the rest of the chain: the next middleware, or the routed handler
# (404 / 405 when nothing resolved).
ServerResponse* orm_web_next(orm_web_request* r):
	orm_web_app* app = orm_web_app_of(r)
	if (r.mw_index < app.middleware.length):
		orm_web_mw* m = app.middleware[r.mw_index]
		r.mw_index = r.mw_index + 1
		ServerResponse* resp = m.fn(r, m.ctx)
		if (resp == 0): resp = orm_web_text(500, c"Internal Server Error")
		return resp
	if (r.route == 0 && r.status == 404 && app.not_found != 0):
		ServerResponse* nf = app.not_found(r, app.not_found_ctx)
		if (nf != 0): return nf
	return orm_route_call(r)


# Handles one parsed request: resolve, middleware chain, handler.
ServerResponse* orm_web_app_handle(orm_web_app* app, ServerRequest* req):
	orm_web_request* r = orm_web_request_new(req)
	r.app = cast(void*, app)
	r.is_secure = app.secure
	orm_web_request* outer = orm_web_current()
	orm_web_set_current(r)
	app.requests = app.requests + 1
	orm_router_resolve(app.router, r)
	ServerResponse* resp = orm_web_next(r)
	orm_web_set_current(outer)
	orm_web_request_free(r)
	return resp


# server_handler_fn adapter: server_context_new(ip, port, orm_web_app_server_handler, app).
ServerResponse* orm_web_app_server_handler(ServerRequest* req, void* app):
	return orm_web_app_handle(cast(orm_web_app*, app), req)


# Marks the request failed: the db middleware rolls its transaction back
# even though the response is not a 5xx.
void orm_web_fail(orm_web_request* r):
	r.failed = 1


# ---------------------------------------------------------------------------
# Request-scoped database

type orm_web_db_open_fn = fn(void*) -> orm_db*
type orm_web_db_release_fn = fn(void*, orm_db*) -> void


struct orm_web_db_source:
	orm_web_db_open_fn* open
	orm_web_db_release_fn* release   # 0 = orm_close
	void* ctx
	list[orm_db*] idle
	int max_idle                     # idle connections kept for reuse
	int atomic                       # wrap each request in a transaction (default 1)
	int opened                       # connections opened
	int reused                       # requests served by an idle connection
	int commits
	int rollbacks


# A source opening connections with open(ctx) (0 or a closed db = 503).
orm_web_db_source* orm_web_db_source_new(orm_web_db_open_fn* open, void* ctx):
	orm_web_db_source* src = new orm_web_db_source()
	src.open = open
	src.ctx = ctx
	src.idle = new list[orm_db*]
	src.max_idle = 4
	src.atomic = 1
	return src


orm_db* orm_web_db_shared_open(void* db):
	return cast(orm_db*, db)


void orm_web_db_keep(void* ctx, orm_db* db):
	return


# A source that hands every request the same borrowed db (one SQLite
# connection, tests). It is never closed by the source.
orm_web_db_source* orm_web_db_source_shared(orm_db* db):
	orm_web_db_source* src = orm_web_db_source_new(orm_web_db_shared_open, cast(void*, db))
	src.release = orm_web_db_keep
	src.max_idle = 0
	return src


void orm_web_db_close(orm_web_db_source* src, orm_db* db):
	if (src.release != 0): src.release(src.ctx, db)
	else: orm_close(db)


# Closes the idle connections and frees the source.
void orm_web_db_source_free(orm_web_db_source* src):
	if (src == 0): return
	for orm_db* db in src.idle: orm_web_db_close(src, db)
	src.idle.free()
	free(cast(void*, src))


orm_db* orm_web_db_acquire(orm_web_db_source* src):
	while (src.idle.length > 0):
		orm_db* idle = src.idle.pop()
		if (orm_is_open(idle)):
			src.reused = src.reused + 1
			return idle
		orm_web_db_close(src, idle)
	orm_db* db = src.open(src.ctx)
	if (db == 0): return 0
	if (orm_is_open(db) == 0):
		orm_web_db_close(src, db)
		return 0
	src.opened = src.opened + 1
	return db


void orm_web_db_release(orm_web_db_source* src, orm_db* db):
	# A transaction a handler left open never leaks into the next request.
	if (db.atomic_depth > 0):
		sql_rollback(db.conn)
		db.atomic_depth = 0
		db.rollback_only = 0
		orm_on_commit_discard(db, 0)
	orm_db_set_error(db, c"")
	if (src.idle.length < src.max_idle && orm_is_open(db)): src.idle.push(db)
	else: orm_web_db_close(src, db)


ServerResponse* orm_web_db_middleware(orm_web_request* r, void* ctx):
	orm_web_db_source* src = cast(orm_web_db_source*, ctx)
	orm_db* db = orm_web_db_acquire(src)
	if (db == 0): return orm_web_text(503, c"Service Unavailable")
	r.db = db
	orm_atomic_block* b = 0
	if (src.atomic):
		b = orm_atomic_begin(db)
		if (b == 0):
			r.db = 0
			orm_web_db_release(src, db)
			return orm_web_text(500, c"Internal Server Error")
	ServerResponse* resp = orm_web_next(r)
	if (b != 0):
		if (resp.status >= 500 || r.failed):
			orm_atomic_rollback(db, b)
			src.rollbacks = src.rollbacks + 1
		else if (orm_atomic_commit(db, b) == 0):
			src.rollbacks = src.rollbacks + 1
			server_response_free(resp)
			resp = orm_web_text(500, c"Internal Server Error")
		else: src.commits = src.commits + 1
	r.db = 0
	orm_web_db_release(src, db)
	return resp


# ---------------------------------------------------------------------------
# Sessions and authentication

int orm_web_session_dirty(auth_session* s):
	return s.modified && s.data.length > 0


# Loads the session named by the request's cookie (U3.2 session_load) or
# starts an unsaved anonymous one, and after the handler saves it: a new
# session with data is created (Set-Cookie), a modified one is saved, a
# rotated key (login) is sent again, and a flushed one (logout) deletes
# the cookie. Needs the db middleware.
ServerResponse* orm_web_session_middleware(orm_web_request* r, void* ctx):
	if (r.db == 0): return orm_web_text(500, c"session middleware needs the db middleware")
	char* raw = session_cookie_value(orm_web_header(r, c"cookie"))
	auth_session* s = 0
	if (raw != 0): s = session_load(r.db, raw)
	if (s == 0): s = auth_session_new()
	r.session = s
	char* orig_key = 0
	if (s.key != 0): orig_key = strclone(s.key)
	ServerResponse* resp = orm_web_next(r)
	s = r.session
	int ok = 1
	int send = 0
	if (s.id == 0):
		if (orm_web_session_dirty(s)):
			auth_session* fresh = session_create(r.db, s.user_id)
			if (fresh == 0): ok = 0
			else:
				for char* k, char* v in s.data: session_set(fresh, k, v)
				ok = session_save(r.db, fresh)
				auth_session_free(s)
				s = fresh
				r.session = s
				send = 1
	else:
		if (s.modified):
			ok = session_save(r.db, s)
			send = 1
		if (orig_key == 0 || strcmp(orig_key, s.key) != 0): send = 1
	if (ok == 0):
		server_response_free(resp)
		resp = orm_web_text(500, c"Internal Server Error")
	else if (send):
		char* cookie = session_cookie_header(s)
		if (cookie != 0):
			server_response_add_header(resp, c"Set-Cookie", cookie)
			free(cookie)
	else if (raw != 0 && s.key == 0):
		char* gone = session_cookie_delete_header()
		server_response_add_header(resp, c"Set-Cookie", gone)
		free(gone)
	orm_web_default_header(resp, c"Vary", c"Cookie")
	if (orig_key != 0): free(orig_key)
	if (raw != 0): free(raw)
	auth_session_free(r.session)
	r.session = 0
	return resp


# Sets request.user from the session (U3.2 session_user: one query when
# the session has a user; inactive or deleted users are anonymous).
# Permission checks start from a fresh cache each request.
ServerResponse* orm_web_auth_middleware(orm_web_request* r, void* ctx):
	if (r.db == 0 || r.session == 0): return orm_web_text(500, c"auth middleware needs the db and session middleware")
	if (r.session.user_id != 0):
		auth_perm_cache_invalidate_user(r.session.user_id)
		r.user = session_user(r.db, r.session)
	ServerResponse* resp = orm_web_next(r)
	if (r.user != 0):
		User_free(r.user)
		r.user = 0
	return resp


# Django's auth.login for this request: rotates (or replaces) the
# session, records the user, and sets request.user to a copy of u.
# Returns 1, or 0 with orm_db_error(request.db).
int orm_web_login(orm_web_request* r, User* u):
	if (r.db == 0 || r.session == 0): return 0
	auth_session* s = r.session
	auth_session* use = s
	if (s.id == 0): use = 0
	auth_session* next = session_login(r.db, use, u)
	if (next == 0): return 0
	if (next != s): auth_session_free(s)
	r.session = next
	if (r.user != 0): User_free(r.user)
	r.user = auth_user_copy(u)
	if (r.csrf != 0):
		free(r.csrf)
		r.csrf = 0
	return 1


# Django's auth.logout: flushes the session (the cookie is deleted) and
# clears request.user.
int orm_web_logout(orm_web_request* r):
	if (r.db == 0 || r.session == 0): return 0
	int ok = session_logout(r.db, r.session)
	if (r.user != 0):
		User_free(r.user)
		r.user = 0
	if (r.csrf != 0):
		free(r.csrf)
		r.csrf = 0
	return ok


# 0 when a user is logged in, else a redirect to login_url?next=<path>.
ServerResponse* orm_web_login_required(orm_web_request* r, char* login_url):
	if (r.user != 0): return 0
	char* next = url_quote(r.path)
	string_builder* s = string_new()
	string_append(s, login_url)
	string_append(s, c"?next=")
	string_append(s, next)
	free(next)
	ServerResponse* resp = orm_web_redirect(s.data)
	string_free(s)
	return resp


# U3.1 user_has_perm for the request's user (0 when anonymous).
int orm_web_has_perm(orm_web_request* r, char* perm):
	if (r.user == 0 || r.db == 0): return 0
	return user_has_perm(r.db, r.user, perm) == 1


# ---------------------------------------------------------------------------
# CSRF

struct orm_web_csrf_config:
	list[char*] trusted_origins   # CSRF_TRUSTED_ORIGINS ("https://app.example.org", "https://*.example.net")
	int failures


orm_web_csrf_config* orm_web_csrf_config_new():
	orm_web_csrf_config* c = new orm_web_csrf_config()
	c.trusted_origins = new list[char*]
	return c


# The request's masked CSRF token (Django's get_token), creating the
# session's secret when needed (the session middleware then saves it).
# Borrowed; 0 without a session.
char* orm_web_csrf_token(orm_web_request* r):
	if (r.session == 0): return 0
	if (r.csrf == 0): r.csrf = csrf_token(r.session)
	return r.csrf


# Django's CsrfViewMiddleware over U3.2's csrf_check: unsafe methods need
# a verified Origin (or, over HTTPS, Referer) and a token from the
# X-CSRFToken header or the csrfmiddlewaretoken form field matching the
# session's secret. Failures are 403 "Forbidden (<reason>)". Routes
# marked orm_route_csrf_exempt and unresolved paths (404 / 405) skip it.
ServerResponse* orm_web_csrf_middleware(orm_web_request* r, void* ctx):
	orm_web_csrf_config* cfg = cast(orm_web_csrf_config*, ctx)
	orm_route* route = cast(orm_route*, r.route)
	if (route == 0 || route.csrf_exempt || csrf_method_is_safe(r.method)): return orm_web_next(r)
	if (r.session == 0): return orm_web_text(500, c"CSRF middleware needs the session middleware")
	csrf_request* cr = csrf_request_new(r.method, orm_web_header(r, c"host"), r.is_secure)
	cr.origin = orm_web_header(r, c"origin")
	cr.referer = orm_web_header(r, c"referer")
	cr.token = orm_web_header(r, c"x-csrftoken")
	if (cr.token == 0): cr.token = orm_web_form_get(r, c"csrfmiddlewaretoken")
	char* why = csrf_check_session(r.session, cr, cfg.trusted_origins)
	free(cast(void*, cr))
	if (why != 0):
		cfg.failures = cfg.failures + 1
		return orm_web_forbidden(why)
	r.csrf_checked = 1
	return orm_web_next(r)


# ---------------------------------------------------------------------------
# Security headers

struct orm_web_security:
	int nosniff                  # X-Content-Type-Options: nosniff
	char* frame_options          # X-Frame-Options ("DENY"), 0 = none
	char* referrer_policy        # "same-origin", 0 = none
	char* opener_policy          # Cross-Origin-Opener-Policy ("same-origin"), 0 = none
	char* content_security_policy    # 0 = none
	int hsts_seconds             # Strict-Transport-Security on HTTPS responses (0 = none)
	int hsts_subdomains


# Django's SecurityMiddleware / XFrameOptionsMiddleware defaults.
orm_web_security* orm_web_security_new():
	orm_web_security* s = new orm_web_security()
	s.nosniff = 1
	s.frame_options = c"DENY"
	s.referrer_policy = c"same-origin"
	s.opener_policy = c"same-origin"
	return s


# Adds the configured headers unless the handler set them itself.
ServerResponse* orm_web_security_middleware(orm_web_request* r, void* ctx):
	orm_web_security* cfg = cast(orm_web_security*, ctx)
	ServerResponse* resp = orm_web_next(r)
	if (cfg.nosniff): orm_web_default_header(resp, c"X-Content-Type-Options", c"nosniff")
	if (cfg.frame_options != 0): orm_web_default_header(resp, c"X-Frame-Options", cfg.frame_options)
	if (cfg.referrer_policy != 0): orm_web_default_header(resp, c"Referrer-Policy", cfg.referrer_policy)
	if (cfg.opener_policy != 0): orm_web_default_header(resp, c"Cross-Origin-Opener-Policy", cfg.opener_policy)
	if (cfg.content_security_policy != 0): orm_web_default_header(resp, c"Content-Security-Policy", cfg.content_security_policy)
	if (cfg.hsts_seconds > 0 && r.is_secure):
		string_builder* v = string_new()
		string_append(v, c"max-age=")
		string_append_int(v, cfg.hsts_seconds)
		if (cfg.hsts_subdomains): string_append(v, c"; includeSubDomains")
		orm_web_default_header(resp, c"Strict-Transport-Security", v.data)
		string_free(v)
	return resp


# ---------------------------------------------------------------------------
# Rendering

char* orm_web_tpl_url(void* app, char* name, map[char*, char*] params):
	orm_web_app* a = cast(orm_web_app*, app)
	return orm_reverse(a.router, name, params)


char* orm_web_tpl_csrf(void* r):
	return orm_web_csrf_token(cast(orm_web_request*, r))


# A template context wired to this request: {% url %} reverses through
# the app's router, {% csrf_token %} uses the session, and it holds
# `user` (the logged-in User row, or null) and `request` (path, method).
orm_tpl_ctx* orm_web_context(orm_web_request* r):
	orm_tpl_ctx* ctx = orm_tpl_ctx_new()
	orm_tpl_set_url(ctx, orm_web_tpl_url, r.app)
	orm_tpl_set_csrf(ctx, orm_web_tpl_csrf, cast(void*, r))
	if (r.user != 0): orm_tpl_set(ctx, c"user", orm_tpl_row(ctx, User_desc(), r.user))
	else: orm_tpl_set(ctx, c"user", orm_tpl_null(ctx))
	orm_tpl_value* req = orm_tpl_map(ctx)
	orm_tpl_put_str(ctx, req, c"path", r.path)
	orm_tpl_put_str(ctx, req, c"method", r.method)
	orm_tpl_set(ctx, c"request", req)
	return ctx


# Renders template `name` from the app's engine as an HTML response and
# frees ctx. A template error is a 500 whose body names the error.
ServerResponse* orm_web_render(orm_web_request* r, char* name, orm_tpl_ctx* ctx, int status):
	orm_web_app* app = orm_web_app_of(r)
	char* html = 0
	if (app.templates != 0): html = orm_tpl_render(app.templates, name, ctx)
	orm_tpl_ctx_free(ctx)
	if (html == 0):
		char* why = c"no template engine"
		if (app.templates != 0): why = orm_tpl_error(app.templates)
		char* body = orm_rest_concat(c"Template error: ", why)
		ServerResponse* bad = orm_web_text(500, body)
		free(body)
		return bad
	return orm_web_html_take(status, html)
