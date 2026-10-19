# w-orm web routing (unit U4.3, docs/projects/orm/u4_3.md): path
# patterns with typed parameters, method routing, named routes with
# reverse(), mounted handlers and sub-routers, plus the per-request
# object every handler and middleware sees.
#
#   orm_router* rt = orm_router_new()
#   orm_router_get(rt, c"/books/", book_list, 0, c"book_list")
#   orm_router_add(rt, c"GET,POST", c"/books/<int:id>/edit/", book_edit, 0, c"book_edit")
#   orm_router_include(rt, c"/accounts/", accounts_router, c"accounts")
#   orm_router_mount(rt, c"/api/", viewset_dispatch, viewset)
#   char* url = orm_reverse1(rt, c"book_edit", c"id", c"3")    # "/books/3/edit/"
#
# Converters (Django's): <int:name> [0-9]+, <slug:name> [-a-zA-Z0-9_]+,
# <str:name> any non-empty text without '/', <path:name> any non-empty
# text; <name> alone is str. Routes are tried in order: the first whose
# pattern matches and which accepts the method wins (HEAD is accepted by
# GET routes). A path matched only by routes of other methods is 405
# with an Allow header; no match is 404.
#
# Mounts hand everything under a prefix to fn(target, request, tail),
# the shape of U4.1's orm_rest_dispatch; tail is the rest of the path
# after the prefix, with a leading '/' ("/api/" + "/api/books/3/" ->
# "/books/3/"; the prefix itself -> ""). orm_router_mount_raw passes the
# bare ServerRequest for code that does not know orm_web_request. Includes graft a whole
# router under a prefix; its route names are reversed as "ns:name"
# (or plain names when the namespace is 0).
import libs.standard.web.http_server
import libs.standard.orm.rest.filter
import libs.standard.orm.auth.session
import libs.standard.email.message
import lib.container


const int ORM_WP_LITERAL = 0
const int ORM_WP_INT = 1
const int ORM_WP_SLUG = 2
const int ORM_WP_STR = 3
const int ORM_WP_PATH = 4

const int ORM_RK_HANDLER = 1
const int ORM_RK_MOUNT = 2
const int ORM_RK_RAW_MOUNT = 3
const int ORM_RK_INCLUDE = 4


struct orm_route_piece:
	int conv               # ORM_WP_*
	char* text             # literal text, or the parameter name


# One uploaded file of a multipart/form-data body.
struct orm_web_upload:
	char* field
	char* filename
	char* content_type
	char* data             # owned bytes (NUL-terminated)
	int length


# Everything a handler sees for one request. Strings are owned by the
# request unless noted; db / session / user are set by middleware.
struct orm_web_request:
	ServerRequest* req     # borrowed
	char* method           # borrowed from req
	char* path             # borrowed from req
	map[char*, char*] params   # path parameters (decoded text)
	char* tail             # mount: path after the prefix
	void* route            # the resolved orm_route*, or 0
	int status             # 0 resolved, 404 or 405
	char* allow            # 405: the Allow header value
	orm_params* query_params   # lazily parsed query string
	orm_params* form_params    # lazily parsed body
	list[orm_web_upload*] uploads
	int is_secure          # the request arrived over HTTPS (or a trusted proxy said so)
	orm_db* db             # request-scoped database (db middleware)
	auth_session* session  # session middleware: never 0 after it ran
	User* user             # auth middleware: the logged-in user or 0
	char* csrf             # cached masked CSRF token for this response
	int csrf_checked       # the CSRF middleware accepted this request
	int failed             # roll back the request transaction even on success
	void* app              # orm_web_app*
	int mw_index           # position in the middleware chain
	list[char*] owned


type orm_web_handler = fn(orm_web_request*, void*) -> ServerResponse*
type orm_web_mount_fn = fn(void*, orm_web_request*, char*) -> ServerResponse*
type orm_web_raw_mount_fn = fn(void*, ServerRequest*, char*) -> ServerResponse*


struct orm_route:
	int kind               # ORM_RK_*
	list[char*] methods    # empty = any method
	char* pattern
	char* name             # 0 = unnamed
	list[orm_route_piece*] pieces
	orm_web_handler* handler
	orm_web_mount_fn* mount
	orm_web_raw_mount_fn* raw_mount
	void* ctx              # handler ctx / mount target / included orm_router*
	char* ns               # include namespace, or 0
	int csrf_exempt        # skip the CSRF middleware (token-authenticated APIs)


struct orm_router:
	list[orm_route*] routes
	char* error            # first configuration error (owned), or 0


# ---------------------------------------------------------------------------
# Patterns

orm_router* orm_router_new():
	orm_router* rt = new orm_router()
	rt.routes = new list[orm_route*]
	return rt


int orm_router_fail(orm_router* rt, char* a, char* b):
	if (rt.error != 0): return 0
	string_builder* s = string_new()
	string_append(s, a)
	if (b != 0): string_append(s, b)
	rt.error = s.data
	free(s)
	return 0


char* orm_router_error(orm_router* rt):
	return rt.error


int orm_route_conv(char* name):
	if (strcmp(name, c"int") == 0): return ORM_WP_INT
	if (strcmp(name, c"slug") == 0): return ORM_WP_SLUG
	if (strcmp(name, c"str") == 0): return ORM_WP_STR
	if (strcmp(name, c"path") == 0): return ORM_WP_PATH
	return -1


int orm_route_ident(char* s):
	if (s[0] == 0 || isdigit(s[0])): return 0
	int i = 0
	while (s[i] != 0):
		if (isalnum(s[i]) == 0 && s[i] != '_'): return 0
		i = i + 1
	return 1


# Parses "/books/<int:id>/" into pieces; 0 with rt.error on a bad pattern.
list[orm_route_piece*] orm_route_parse(orm_router* rt, char* pattern):
	list[orm_route_piece*] pieces = new list[orm_route_piece*]
	int n = strlen(pattern)
	int i = 0
	int lit_start = 0
	while (i <= n):
		if (i == n || pattern[i] == '<'):
			if (i > lit_start):
				orm_route_piece* lit = new orm_route_piece()
				lit.conv = ORM_WP_LITERAL
				lit.text = substring(pattern, lit_start, i)
				pieces.push(lit)
			if (i == n): break
			int close = index_of(pattern + i, c">")
			if (close < 0):
				orm_router_fail(rt, c"router: unclosed '<' in ", pattern)
				return 0
			char* inner = substring(pattern, i + 1, i + close)
			int colon = index_of(inner, c":")
			orm_route_piece* p = new orm_route_piece()
			p.conv = ORM_WP_STR
			if (colon >= 0):
				char* conv = substring(inner, 0, colon)
				p.conv = orm_route_conv(conv)
				free(conv)
				p.text = strclone(inner + colon + 1)
			else: p.text = strclone(inner)
			free(inner)
			pieces.push(p)
			if (p.conv < 0):
				orm_router_fail(rt, c"router: unknown converter in ", pattern)
				return 0
			if (orm_route_ident(p.text) == 0):
				orm_router_fail(rt, c"router: bad parameter name in ", pattern)
				return 0
			for j in range(pieces.length - 1):
				orm_route_piece* prev = pieces[j]
				if (prev.conv != ORM_WP_LITERAL && strcmp(prev.text, p.text) == 0):
					orm_router_fail(rt, c"router: parameter used twice in ", pattern)
					return 0
			i = i + close + 1
			lit_start = i
		else: i = i + 1
	return pieces


int orm_route_char_ok(int conv, int ch):
	if (conv == ORM_WP_INT): return ch >= '0' && ch <= '9'
	if (conv == ORM_WP_SLUG): return isalnum(ch) || ch == '-' || ch == '_'
	if (conv == ORM_WP_STR): return ch != '/'
	return 1


# Matches pieces[idx..] against path[pos..]. Whole-path mode needs the
# path to end exactly; prefix mode accepts any remaining text. Returns
# the end position (-1 = no match) and records parameter values in params
# (keys are piece names; values owned).
int orm_route_match_at(list[orm_route_piece*] pieces, int idx, char* path, int pos, int prefix, map[char*, char*] params):
	int n = strlen(path)
	if (idx >= pieces.length):
		if (prefix || pos == n): return pos
		return -1
	orm_route_piece* p = pieces[idx]
	if (p.conv == ORM_WP_LITERAL):
		if (starts_with(path + pos, p.text) == 0): return -1
		return orm_route_match_at(pieces, idx + 1, path, pos + strlen(p.text), prefix, params)
	int max = pos
	while (max < n && orm_route_char_ok(p.conv, path[max] & 255)): max = max + 1
	int end = max
	while (end > pos):
		int got = orm_route_match_at(pieces, idx + 1, path, end, prefix, params)
		if (got >= 0):
			char* raw = substring(path, pos, end)
			char* value = url_unquote(raw)
			free(raw)
			if (value == 0): return -1
			if (p.text in params): free(params[p.text])
			params[p.text] = value
			return got
		end = end - 1
	return -1


orm_route* orm_route_new(orm_router* rt, int kind, char* methods, char* pattern, char* name):
	orm_route* r = new orm_route()
	r.kind = kind
	r.methods = new list[char*]
	if (methods != 0 && strcmp(methods, c"*") != 0):
		list[char*] parts = split(methods, ',')
		for char* m in parts:
			char* t = strip(m)
			free(m)
			if (t[0] != 0): r.methods.push(t)
			else: free(t)
		parts.free()
	r.pattern = strclone(pattern)
	if (name != 0): r.name = strclone(name)
	r.pieces = orm_route_parse(rt, pattern)
	if (r.pieces == 0): r.pieces = new list[orm_route_piece*]
	if (pattern[0] != '/'): orm_router_fail(rt, c"router: patterns start with '/': ", pattern)
	rt.routes.push(r)
	return r


# Registers handler for the comma-separated methods ("GET,POST"; "*" or
# 0 = any) on pattern. name (or 0) is the reverse() name.
orm_route* orm_router_add(orm_router* rt, char* methods, char* pattern, orm_web_handler* handler, void* ctx, char* name):
	orm_route* r = orm_route_new(rt, ORM_RK_HANDLER, methods, pattern, name)
	r.handler = handler
	r.ctx = ctx
	return r


orm_route* orm_router_get(orm_router* rt, char* pattern, orm_web_handler* handler, void* ctx, char* name):
	return orm_router_add(rt, c"GET", pattern, handler, ctx, name)


orm_route* orm_router_post(orm_router* rt, char* pattern, orm_web_handler* handler, void* ctx, char* name):
	return orm_router_add(rt, c"POST", pattern, handler, ctx, name)


# fn(target, request, tail) handles every method under prefix.
orm_route* orm_router_mount(orm_router* rt, char* prefix, orm_web_mount_fn* fn, void* target):
	orm_route* r = orm_route_new(rt, ORM_RK_MOUNT, 0, prefix, 0)
	r.mount = fn
	r.ctx = target
	return r


orm_route* orm_router_mount_raw(orm_router* rt, char* prefix, orm_web_raw_mount_fn* fn, void* target):
	orm_route* r = orm_route_new(rt, ORM_RK_RAW_MOUNT, 0, prefix, 0)
	r.raw_mount = fn
	r.ctx = target
	return r


# Grafts sub's routes under prefix (which may hold parameters). sub is
# borrowed and must outlive rt.
orm_route* orm_router_include(orm_router* rt, char* prefix, orm_router* sub, char* ns):
	orm_route* r = orm_route_new(rt, ORM_RK_INCLUDE, 0, prefix, 0)
	r.ctx = cast(void*, sub)
	if (ns != 0): r.ns = strclone(ns)
	if (sub.error != 0): orm_router_fail(rt, sub.error, 0)
	return r


orm_route* orm_route_csrf_exempt(orm_route* r):
	r.csrf_exempt = 1
	return r


void orm_router_free(orm_router* rt):
	if (rt == 0): return
	for orm_route* r in rt.routes:
		for char* m in r.methods: free(m)
		r.methods.free()
		for orm_route_piece* p in r.pieces:
			free(p.text)
			free(cast(void*, p))
		r.pieces.free()
		free(r.pattern)
		if (r.name != 0): free(r.name)
		if (r.ns != 0): free(r.ns)
		free(cast(void*, r))
	rt.routes.free()
	if (rt.error != 0): free(rt.error)
	free(cast(void*, rt))


# ---------------------------------------------------------------------------
# Resolution

int orm_route_accepts(orm_route* r, char* method):
	if (r.methods.length == 0): return 1
	for char* m in r.methods:
		if (strcmp(m, method) == 0): return 1
		if (strcmp(m, c"GET") == 0 && strcmp(method, c"HEAD") == 0): return 1
	return 0


void orm_route_add_allow(list[char*] allow, orm_route* r):
	for char* m in r.methods:
		int seen = 0
		for char* a in allow:
			if (strcmp(a, m) == 0): seen = 1
		if (seen == 0): allow.push(m)
		if (strcmp(m, c"GET") == 0):
			int head = 0
			for char* a2 in allow:
				if (strcmp(a2, c"HEAD") == 0): head = 1
			if (head == 0): allow.push(c"HEAD")


void orm_web_params_clear(map[char*, char*] params):
	for char* k, char* v in params: free(v)
	map_free[char*, char*](params)


# Resolves path for method into r (route, params, tail) or sets r.status
# to 404 / 405 (with r.allow). Returns the route or 0.
orm_route* orm_router_resolve_into(orm_router* rt, char* method, char* path, orm_web_request* req, list[char*] allow):
	for orm_route* r in rt.routes:
		map[char*, char*] params = new map[char*, char*]
		if (r.kind == ORM_RK_HANDLER):
			int end = orm_route_match_at(r.pieces, 0, path, 0, 0, params)
			if (end >= 0):
				if (orm_route_accepts(r, method)):
					for char* k, char* v in params: req.params[k] = v
					map_free[char*, char*](params)
					return r
				orm_route_add_allow(allow, r)
			orm_web_params_clear(params)
			continue
		int pend = orm_route_match_at(r.pieces, 0, path, 0, 1, params)
		char* rest = 0
		if (pend >= 0):
			rest = path + pend
			if (pend > 0 && path[pend - 1] != '/' && rest[0] != 0 && rest[0] != '/'): rest = 0
		if (rest == 0):
			orm_web_params_clear(params)
			continue
		if (r.kind == ORM_RK_INCLUDE):
			char* sub_path = 0
			if (rest[0] == '/'): sub_path = strclone(rest)
			else: sub_path = orm_rest_concat(c"/", rest)
			orm_route* found = orm_router_resolve_into(cast(orm_router*, r.ctx), method, sub_path, req, allow)
			free(sub_path)
			if (found != 0):
				for char* k2, char* v2 in params:
					if (k2 in req.params): free(v2)
					else: req.params[k2] = v2
				map_free[char*, char*](params)
				return found
			orm_web_params_clear(params)
			continue
		for char* k3, char* v3 in params: req.params[k3] = v3
		map_free[char*, char*](params)
		if (rest[0] == 0 || rest[0] == '/'): req.tail = strclone(rest)
		else: req.tail = orm_rest_concat(c"/", rest)
		return r
	return 0


# Fills req.route / params / tail, or req.status (404 / 405 + allow).
orm_route* orm_router_resolve(orm_router* rt, orm_web_request* req):
	list[char*] allow = new list[char*]
	orm_route* r = orm_router_resolve_into(rt, req.method, req.path, req, allow)
	req.route = cast(void*, r)
	if (r == 0):
		if (allow.length > 0):
			req.status = 405
			req.allow = join(allow, c", ")
		else: req.status = 404
	allow.free()
	return r


# ---------------------------------------------------------------------------
# reverse()

int orm_reverse_value_ok(int conv, char* v):
	if (v == 0 || v[0] == 0): return 0
	int i = 0
	while (v[i] != 0):
		if (orm_route_char_ok(conv, v[i] & 255) == 0): return 0
		i = i + 1
	return 1


# Appends the route's pieces filled from params to out; counts used params.
int orm_reverse_build(orm_route* r, map[char*, char*] params, string_builder* out, int* used):
	for orm_route_piece* p in r.pieces:
		if (p.conv == ORM_WP_LITERAL):
			string_append(out, p.text)
			continue
		char* v = params.get(p.text, 0)
		if (orm_reverse_value_ok(p.conv, v) == 0): return 0
		# Only <path:> values may hold '/' (checked above), which url_quote keeps.
		char* q = url_quote(v)
		string_append(out, q)
		free(q)
		used[0] = used[0] + 1
	return 1


int orm_web_prefix_eq(char* a, char* b, int n):
	for i in range(n):
		if (a[i] != b[i]): return 0
		if (a[i] == 0): return 1
	return 1


char* orm_reverse_in(orm_router* rt, char* name, map[char*, char*] params, char* prefix, int used_before):
	int colon = index_of(name, c":")
	for orm_route* r in rt.routes:
		if (r.kind == ORM_RK_HANDLER && r.name != 0 && strcmp(r.name, name) == 0):
			string_builder* out = string_new()
			string_append(out, prefix)
			int used = used_before
			if (orm_reverse_build(r, params, out, &used) && used == params.length):
				char* text = out.data
				free(out)
				return text
			string_free(out)
			continue
		if (r.kind != ORM_RK_INCLUDE): continue
		char* rest = 0
		if (r.ns == 0): rest = name
		else if (colon >= 0 && strlen(r.ns) == colon && orm_web_prefix_eq(name, r.ns, colon)): rest = name + colon + 1
		if (rest == 0): continue
		string_builder* pre = string_new()
		string_append(pre, prefix)
		int used2 = used_before
		if (orm_reverse_build(r, params, pre, &used2) == 0):
			string_free(pre)
			continue
		# The included router's patterns start with '/', the prefix usually ends with one.
		if (pre.length > 0 && pre.data[pre.length - 1] == '/'):
			pre.length = pre.length - 1
			pre.data[pre.length] = 0
		char* found = orm_reverse_in(cast(orm_router*, r.ctx), rest, params, pre.data, used2)
		string_free(pre)
		if (found != 0): return found
	return 0


# The path of route `name` ("ns:name" inside a namespaced include) with
# params filled in (every parameter required, no extras, values checked
# against their converters and percent-encoded). Owned, or 0 when nothing
# matches (Django's NoReverseMatch).
char* orm_reverse(orm_router* rt, char* name, map[char*, char*] params):
	map[char*, char*] p = params
	if (p == 0): p = new map[char*, char*]
	char* out = orm_reverse_in(rt, name, p, c"", 0)
	if (params == 0): map_free[char*, char*](p)
	return out


char* orm_reverse0(orm_router* rt, char* name):
	return orm_reverse(rt, name, 0)


char* orm_reverse1(orm_router* rt, char* name, char* key, char* value):
	map[char*, char*] p = new map[char*, char*]
	p[key] = value
	char* out = orm_reverse(rt, name, p)
	map_free[char*, char*](p)
	return out


char* orm_reverse1_int(orm_router* rt, char* name, char* key, int value):
	char* text = itoa(value)
	char* out = orm_reverse1(rt, name, key, text)
	free(text)
	return out


# ---------------------------------------------------------------------------
# Requests

orm_web_request* __orm_web_current


# The request being handled (for code reached through a raw mount).
orm_web_request* orm_web_current():
	return __orm_web_current


void orm_web_set_current(orm_web_request* r):
	__orm_web_current = r


orm_web_request* orm_web_request_new(ServerRequest* req):
	orm_web_request* r = new orm_web_request()
	r.req = req
	r.method = req.method
	r.path = req.path
	if (r.path == 0): r.path = c"/"
	r.params = new map[char*, char*]
	r.uploads = new list[orm_web_upload*]
	r.owned = new list[char*]
	return r


void orm_web_request_free(orm_web_request* r):
	if (r == 0): return
	orm_web_params_clear(r.params)
	if (r.tail != 0): free(r.tail)
	if (r.allow != 0): free(r.allow)
	orm_params_free(r.query_params)
	orm_params_free(r.form_params)
	for orm_web_upload* u in r.uploads:
		free(u.field)
		if (u.filename != 0): free(u.filename)
		if (u.content_type != 0): free(u.content_type)
		free(u.data)
		free(cast(void*, u))
	r.uploads.free()
	if (r.csrf != 0): free(r.csrf)
	for char* s in r.owned: free(s)
	r.owned.free()
	if (__orm_web_current == r): __orm_web_current = 0
	free(cast(void*, r))


# Keeps s (malloc'd) alive until the request is freed.
char* orm_web_own(orm_web_request* r, char* s):
	if (s != 0): r.owned.push(s)
	return s


char* orm_web_header(orm_web_request* r, char* name):
	return server_request_header(r.req, name)


# Path parameter (borrowed), or 0.
char* orm_web_param(orm_web_request* r, char* name):
	return r.params.get(name, 0)


# Integer path parameter, or fallback when absent or not a number.
int orm_web_param_int(orm_web_request* r, char* name, int fallback):
	char* v = orm_web_param(r, name)
	int out = 0
	if (v == 0 || sql_parse_int(v, &out) == 0): return fallback
	return out


orm_params* orm_web_query(orm_web_request* r):
	if (r.query_params == 0): r.query_params = orm_params_parse(r.req.query)
	return r.query_params


# A query-string value (borrowed), or 0.
char* orm_web_query_get(orm_web_request* r, char* name):
	return orm_params_get(orm_web_query(r), name)


int orm_web_ctype_is(char* ctype, char* want):
	if (ctype == 0): return 0
	int n = strlen(want)
	for i in range(n):
		if (tolower(ctype[i]) != want[i]): return 0
	int ch = ctype[n]
	return ch == 0 || ch == ';' || ch == ' ' || ch == 9


# Parses a multipart/form-data body: text parts become params, parts
# with a filename become uploads.
void orm_web_parse_multipart(orm_web_request* r, char* ctype, orm_params* out):
	string_builder* doc = string_new()
	string_append(doc, c"Content-Type: ")
	string_append(doc, ctype)
	string_append(doc, c"\x0d\x0a\x0d\x0a")
	string_append_bytes(doc, r.req.body, r.req.body_len)
	email_message* m = email_message_from_bytes(doc.data, doc.length)
	if (email_message_is_multipart(m)):
		for i in range(email_message_part_count(m)):
			email_message* part = email_message_part(m, i)
			char* field = email_message_get_param(part, c"name", c"content-disposition")
			if (field == 0): continue
			int len = 0
			char* data = email_message_get_payload_decoded(part, &len)
			if (data == 0):
				data = strclone(c"")
				len = 0
			char* filename = email_message_param_collapsed(part, c"filename", c"content-disposition")
			if (filename != 0):
				orm_web_upload* u = new orm_web_upload()
				u.field = field
				u.filename = filename
				char* ct = email_message_get(part, c"content-type")
				if (ct != 0): u.content_type = strclone(ct)
				u.data = data
				u.length = len
				r.uploads.push(u)
			else:
				orm_params_add(out, field, data)
				free(field)
				free(data)
	email_message_free(m)
	string_free(doc)


# The request body as form fields: application/x-www-form-urlencoded or
# multipart/form-data (other types give no fields). Parsed once.
orm_params* orm_web_form(orm_web_request* r):
	if (r.form_params != 0): return r.form_params
	char* ctype = orm_web_header(r, c"content-type")
	if (orm_web_ctype_is(ctype, c"application/x-www-form-urlencoded")): r.form_params = orm_params_parse(r.req.body)
	else:
		r.form_params = orm_params_new()
		if (orm_web_ctype_is(ctype, c"multipart/form-data")): orm_web_parse_multipart(r, ctype, r.form_params)
	return r.form_params


# A form field (borrowed), or 0.
char* orm_web_form_get(orm_web_request* r, char* name):
	return orm_params_get(orm_web_form(r), name)


orm_web_upload* orm_web_upload_get(orm_web_request* r, char* field):
	orm_web_form(r)
	for orm_web_upload* u in r.uploads:
		if (strcmp(u.field, field) == 0): return u
	return 0


# ---------------------------------------------------------------------------
# Responses

ServerResponse* orm_web_response(int status, char* content_type, char* body):
	ServerResponse* resp = server_response_new(status)
	if (content_type != 0): server_response_add_header(resp, c"Content-Type", content_type)
	if (body != 0): server_response_set_text(resp, body)
	else: server_response_set_body(resp, c"", 0)
	return resp


ServerResponse* orm_web_html(int status, char* html):
	return orm_web_response(status, c"text/html; charset=utf-8", html)


# Same, taking ownership of html.
ServerResponse* orm_web_html_take(int status, char* html):
	ServerResponse* resp = orm_web_html(status, html)
	free(html)
	return resp


ServerResponse* orm_web_text(int status, char* text):
	return orm_web_response(status, c"text/plain; charset=utf-8", text)


ServerResponse* orm_web_json(int status, char* json_text):
	return orm_web_response(status, c"application/json", json_text)


# 302 to location (copied).
ServerResponse* orm_web_redirect(char* location):
	ServerResponse* resp = orm_web_response(302, 0, 0)
	server_response_add_header(resp, c"Location", location)
	return resp


ServerResponse* orm_web_redirect_take(char* location):
	ServerResponse* resp = orm_web_redirect(location)
	free(location)
	return resp


ServerResponse* orm_web_not_found():
	return orm_web_text(404, c"Not Found")


ServerResponse* orm_web_forbidden(char* reason):
	char* body = orm_rest_concat3(c"Forbidden (", reason, c")")
	ServerResponse* resp = orm_web_text(403, body)
	free(body)
	return resp


ServerResponse* orm_web_method_not_allowed(char* allow):
	ServerResponse* resp = orm_web_text(405, c"Method Not Allowed")
	if (allow != 0): server_response_add_header(resp, c"Allow", allow)
	return resp


# Sets (replacing) a response header.
void orm_web_set_header(ServerResponse* resp, char* name, char* value):
	int i = 0
	while (i < resp.headers.length):
		http_header* h = resp.headers[i]
		if (http_str_ieq(h.name, name) != 0):
			free(h.name)
			free(h.value)
			free(cast(void*, h))
			resp.headers.remove(i)
		else: i = i + 1
	server_response_add_header(resp, name, value)


# Adds a header only when the handler did not set one.
void orm_web_default_header(ServerResponse* resp, char* name, char* value):
	if (server_response_get_header(resp, name) == 0): server_response_add_header(resp, name, value)


# Runs the resolved route of r (after orm_router_resolve). 404 / 405 when
# nothing resolved.
ServerResponse* orm_route_call(orm_web_request* r):
	orm_route* route = cast(orm_route*, r.route)
	if (route == 0):
		if (r.status == 405): return orm_web_method_not_allowed(r.allow)
		return orm_web_not_found()
	ServerResponse* resp = 0
	if (route.kind == ORM_RK_HANDLER): resp = route.handler(r, route.ctx)
	else if (route.kind == ORM_RK_MOUNT): resp = route.mount(route.ctx, r, r.tail)
	else if (route.kind == ORM_RK_RAW_MOUNT): resp = route.raw_mount(route.ctx, r.req, r.tail)
	if (resp == 0): resp = orm_web_text(500, c"Internal Server Error")
	if (strcmp(r.method, c"HEAD") == 0): server_response_set_body(resp, c"", 0)
	return resp


# Resolves and runs one request against rt with no middleware.
ServerResponse* orm_router_dispatch(orm_router* rt, orm_web_request* r):
	orm_router_resolve(rt, r)
	return orm_route_call(r)
