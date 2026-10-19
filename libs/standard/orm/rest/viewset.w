# w-orm REST viewsets and routing (unit U4.1, docs/projects/orm/u4_1.md):
# DRF's ModelViewSet + SimpleRouter over libs/standard/web/http_server.w.
#
#   orm_queryset* books_qs(orm_rest_request* r, void* ctx):
#       return Book_objects(r.db).filter(q_eq_int(c"author__id", owner_of(r.user)))
#
#   orm_viewset* vs = orm_viewset_new(Book_desc(), db, books_qs, 0)
#   orm_viewset_filter(vs, fs)
#   orm_viewset_paginator(vs, orm_paginator_cursor(c"-id", 20))
#   orm_viewset_permission(vs, orm_perm_django_model_permissions())
#
#   orm_rest_router* rt = orm_rest_router_new()
#   orm_rest_router_register(rt, c"/api/books", vs)   # 0 when the viewset is refused
#   orm_rest_router_mount(rt, server)                  # server_route per prefix
#
# Routes (DRF SimpleRouter; the trailing slash is optional):
#   <prefix>/              GET list, POST create
#   <prefix>/<pk>/         GET retrieve, PUT update, PATCH partial_update, DELETE destroy
#   <prefix>/<pk>/history/ GET, when a history callback is set
#   <prefix>/<path>/, <prefix>/<pk>/<path>/   extra actions (orm_viewset_action)
# HEAD answers as GET without a body; OPTIONS returns DRF's metadata.
#
# Every request runs DRF's APIView.initial order: authenticate
# (permissions.w), check permissions, check throttles (throttle.w), then
# the handler (405 with an Allow header when the method has none).
# Detail routes look the object up through get_queryset plus the filter
# set (404 outside it) and then check object permissions. The response
# always carries Allow.
#
# orm_rest_dispatch(vs, request, path_tail) is the plain entry point: any
# router (or a bare http_server handler) strips its prefix and calls it.
# orm_viewset_routes describes the routes for OpenAPI generation.
import libs.standard.orm.rest.permissions
import libs.standard.orm.rest.throttle
import libs.standard.orm.history.history
import libs.standard.orm.rest.openapi


# (request, ctx) -> the queryset this request may see (required; 0 = 500).
type orm_rest_queryset_fn = fn(orm_rest_request*, void*) -> orm_queryset*
# (request, row, ctx) -> 1 to go on, 0 to refuse (orm_rest_fail sets the
# response; default 400). on_save runs before create/update writes the
# validated row (DRF perform_create/perform_update), on_delete before a
# destroy.
type orm_rest_row_fn = fn(orm_rest_request*, void*, void*) -> int
# (request, object, ctx) -> owned JSON text for /<pk>/history/, 0 = error.
type orm_rest_history_fn = fn(orm_rest_request*, void*, void*) -> char*
# (request, object or 0, ctx) -> the response (owned), 0 = error.
type orm_rest_action_fn = fn(orm_rest_request*, void*, void*) -> ServerResponse*


const int ORM_VS_LIST = 1
const int ORM_VS_CREATE = 2
const int ORM_VS_RETRIEVE = 4
const int ORM_VS_UPDATE = 8
const int ORM_VS_PARTIAL_UPDATE = 16
const int ORM_VS_DESTROY = 32
const int ORM_VS_ALL = 63
const int ORM_VS_READ_ONLY = 5


# An extra route (DRF @action).
struct orm_rest_action:
	char* name                 # r.action while it runs
	char* url_path             # path segment
	int detail                 # 1: <pk>/<url_path>/ (object looked up and checked first)
	list[char*] methods        # upper-case
	orm_rest_action_fn* handler
	void* ctx
	orm_permission* permission # 0 = the viewset's
	orm_serializer* serializer # for the route description only, or 0


struct orm_rest_action_serializer:
	char* action
	orm_serializer* serializer


struct orm_viewset:
	orm_model_desc* model
	orm_db* db                 # default database (orm_rest_env.db overrides)
	orm_rest_queryset_fn* get_queryset
	void* ctx
	orm_serializer* serializer # output (and input unless overridden)
	int owns_serializer
	orm_serializer* write_serializer   # input for create/update, 0 = serializer
	list[orm_rest_action_serializer*] action_serializers
	orm_filter_set* filter     # 0 = no filtering
	orm_paginator* paginator   # 0 = plain JSON array
	int reserved               # paginator params reserved in filter
	list[orm_authenticator*] authenticators
	orm_permission* permission
	list[orm_throttle*] throttles
	int actions                # ORM_VS_* enabled
	list[orm_rest_action*] extra
	orm_rest_history_fn* history
	void* history_ctx
	orm_rest_row_fn* on_save
	orm_rest_row_fn* on_delete
	void* hook_ctx
	int history_context        # authenticated writes set U3.3's history context (default: model.history)
	char* error                # configuration error (owned), or 0


# Per-call environment a mounting router supplies (all optional).
struct orm_rest_env:
	orm_db* db                 # request-scoped database, 0 = the viewset's
	int is_secure
	char* remote_addr


# A viewset over model m. get_queryset is required: a viewset without one
# is refused by orm_rest_router_register / orm_rest_register and every
# dispatch answers 500. Defaults: every standard action, a serializer of
# every field (orm_serializer_new), session then token authentication,
# is_authenticated, no throttles.
orm_viewset* orm_viewset_new(orm_model_desc* m, orm_db* db, orm_rest_queryset_fn* get_queryset, void* ctx):
	orm_viewset* vs = new orm_viewset()
	vs.model = m
	vs.db = db
	vs.get_queryset = get_queryset
	vs.ctx = ctx
	vs.serializer = orm_serializer_new(m)
	vs.owns_serializer = 1
	vs.action_serializers = new list[orm_rest_action_serializer*]
	vs.authenticators = new list[orm_authenticator*]
	vs.authenticators.push(orm_auth_session(0))
	vs.authenticators.push(orm_auth_token())
	vs.permission = orm_perm_is_authenticated()
	vs.throttles = new list[orm_throttle*]
	vs.actions = ORM_VS_ALL
	vs.extra = new list[orm_rest_action*]
	vs.history_context = m.history != 0
	return vs


# Frees the viewset and what it created (the default serializer, extra
# action entries); serializers, filters, paginators, permissions,
# authenticators and throttles passed in stay with the caller.
void orm_viewset_free(orm_viewset* vs):
	if (vs == 0): return
	if (vs.owns_serializer): orm_serializer_free(vs.serializer)
	for orm_rest_action_serializer* e in vs.action_serializers: free(cast(char*, e))
	vs.action_serializers.free()
	for orm_rest_action* a in vs.extra:
		for char* mt in a.methods: free(mt)
		a.methods.free()
		free(cast(char*, a))
	vs.extra.free()
	vs.authenticators.free()
	vs.throttles.free()
	if (vs.error != 0): free(vs.error)
	free(cast(char*, vs))


void orm_viewset_fail(orm_viewset* vs, char* msg):
	if (vs.error == 0): vs.error = strclone(msg)


orm_viewset* orm_viewset_serializer(orm_viewset* vs, orm_serializer* ser):
	if (vs.owns_serializer): orm_serializer_free(vs.serializer)
	vs.owns_serializer = 0
	vs.serializer = ser
	return vs


# Input serializer for create/update (DRF's write serializer); the output
# still uses the viewset serializer.
orm_viewset* orm_viewset_write_serializer(orm_viewset* vs, orm_serializer* ser):
	vs.write_serializer = ser
	return vs


# Serializer for one action ("list", "retrieve", "create", ...; DRF
# get_serializer_class by action). For create/update it is the input and
# the output serializer.
orm_viewset* orm_viewset_action_serializer(orm_viewset* vs, char* action, orm_serializer* ser):
	orm_rest_action_serializer* e = new orm_rest_action_serializer()
	e.action = action
	e.serializer = ser
	vs.action_serializers.push(e)
	return vs


orm_viewset* orm_viewset_filter(orm_viewset* vs, orm_filter_set* fs):
	vs.filter = fs
	vs.reserved = 0
	return vs


orm_viewset* orm_viewset_paginator(orm_viewset* vs, orm_paginator* p):
	vs.paginator = p
	vs.reserved = 0
	return vs


# Replaces the authenticators with an empty list (then add some with
# orm_viewset_authenticator; none at all makes every request anonymous).
orm_viewset* orm_viewset_clear_authenticators(orm_viewset* vs):
	vs.authenticators.clear()
	return vs


orm_viewset* orm_viewset_authenticator(orm_viewset* vs, orm_authenticator* a):
	vs.authenticators.push(a)
	return vs


orm_viewset* orm_viewset_permission(orm_viewset* vs, orm_permission* p):
	vs.permission = p
	return vs


orm_viewset* orm_viewset_throttle(orm_viewset* vs, orm_throttle* t):
	vs.throttles.push(t)
	return vs


# Enables only the ORM_VS_* actions in mask (ORM_VS_READ_ONLY = list +
# retrieve, DRF's ReadOnlyModelViewSet).
orm_viewset* orm_viewset_actions(orm_viewset* vs, int mask):
	vs.actions = mask
	return vs


orm_viewset* orm_viewset_history(orm_viewset* vs, orm_rest_history_fn* fn, void* ctx):
	vs.history = fn
	vs.history_ctx = ctx
	return vs


# Ready-made history route (U3.3 trigger history): orm_viewset_history(vs,
# orm_rest_history_json, ser) answers /<pk>/history/ with every version of
# the object, newest first, each the serializer's fields of that version
# (ser 0 = every model field) plus history_id, history_date,
# history_type ("+", "~", "-"), history_user_id, history_reason and
# history_context_id. One query.
char* orm_rest_history_json(orm_rest_request* r, void* obj, void* ctx):
	orm_result* res = orm_history_of(r.db, r.model, obj)
	if (res == 0): return 0
	orm_serializer* ser = cast(orm_serializer*, ctx)
	int own = 0
	if (ser == 0):
		ser = orm_serializer_new(r.model)
		own = 1
	json_value* arr = json_array()
	for orm_history_entry* e in orm_history_entries(res):
		json_value* o = orm_serializer_to_json(ser, e.row)
		json_object_set(o, c"history_id", json_int(e.history_id))
		json_object_set(o, c"history_date", json_string(e.date))
		char* t = c"~"
		if (e.type == ORM_HISTORY_INSERT): t = c"+"
		else if (e.type == ORM_HISTORY_DELETE): t = c"-"
		json_object_set(o, c"history_type", json_string(t))
		if (e.user_isnull): json_object_set(o, c"history_user_id", json_null())
		else: json_object_set(o, c"history_user_id", json_int(e.user_id))
		json_object_set(o, c"history_reason", orm_rest_link_json(e.reason))
		json_object_set(o, c"history_context_id", orm_rest_link_json(e.context_id))
		json_array_push(arr, o)
	orm_result_free(res)
	if (own): orm_serializer_free(ser)
	return orm_rest_render(arr)


# Whether authenticated writes record who made them in U3.3's history
# context (orm_history_set_context with the user id and "<METHOD>
# <path>" as the reason, cleared after the request).
orm_viewset* orm_viewset_history_context(orm_viewset* vs, int on):
	vs.history_context = on
	return vs


orm_viewset* orm_viewset_hooks(orm_viewset* vs, orm_rest_row_fn* on_save, orm_rest_row_fn* on_delete, void* ctx):
	vs.on_save = on_save
	vs.on_delete = on_delete
	vs.hook_ctx = ctx
	return vs


# Registers an extra route (DRF @action): methods is "GET" or "GET,POST";
# url_path 0 = name. Returns the action so its permission or serializer
# can be set.
orm_rest_action* orm_viewset_action(orm_viewset* vs, char* name, char* methods, int detail, orm_rest_action_fn* handler, void* ctx):
	orm_rest_action* a = new orm_rest_action()
	a.name = name
	a.url_path = name
	a.detail = detail
	a.handler = handler
	a.ctx = ctx
	a.methods = new list[char*]
	int start = 0
	int i = 0
	while (1):
		if (methods[i] == ',' || methods[i] == 0):
			if (i > start):
				char* mt = substring(methods, start, i)
				for j in range(strlen(mt)): mt[j] = toupper(mt[j])
				a.methods.push(mt)
			start = i + 1
		if (methods[i] == 0): break
		i = i + 1
	if (strcmp(name, c"history") == 0 && detail): orm_viewset_fail(vs, c"viewset: an extra action may not be named 'history'")
	vs.extra.push(a)
	return a


orm_rest_action* orm_rest_action_url_path(orm_rest_action* a, char* path):
	a.url_path = path
	return a


orm_rest_action* orm_rest_action_permission(orm_rest_action* a, orm_permission* p):
	a.permission = p
	return a


orm_rest_action* orm_rest_action_serializer_set(orm_rest_action* a, orm_serializer* ser):
	a.serializer = ser
	return a


# 0 when vs can serve requests, else the reason (borrowed).
char* orm_viewset_check(orm_viewset* vs):
	if (vs == 0): return c"viewset: missing"
	if (vs.error != 0): return vs.error
	if (vs.get_queryset == 0): return c"viewset: get_queryset is required"
	if (vs.model == 0): return c"viewset: no model"
	if (vs.serializer == 0): return c"viewset: no serializer"
	if (orm_serializer_error(vs.serializer) != 0): return orm_serializer_error(vs.serializer)
	if (vs.filter != 0 && orm_filter_error(vs.filter) != 0): return orm_filter_error(vs.filter)
	if (vs.reserved == 0 && vs.filter != 0 && vs.paginator != 0):
		orm_paginator_reserve(vs.paginator, vs.filter)
	vs.reserved = 1
	return 0


# The serializer for action (input when `input`), per the overrides.
orm_serializer* orm_viewset_serializer_for(orm_viewset* vs, char* action, int input):
	if (action != 0):
		for orm_rest_action_serializer* e in vs.action_serializers:
			if (strcmp(e.action, action) == 0): return e.serializer
	if (input && vs.write_serializer != 0): return vs.write_serializer
	return vs.serializer


# ---------------------------------------------------------------------------
# Responses

# A JSON response taking ownership of body (0 = empty body).
ServerResponse* orm_rest_response(int status, json_value* body):
	ServerResponse* resp = server_response_new(status)
	if (body != 0):
		char* text = orm_rest_render(body)
		server_response_add_header(resp, c"Content-Type", c"application/json")
		server_response_set_text(resp, text)
		free(text)
	return resp


# A response with JSON text already rendered (borrowed).
ServerResponse* orm_rest_response_text(int status, char* json_text):
	ServerResponse* resp = server_response_new(status)
	server_response_add_header(resp, c"Content-Type", c"application/json")
	server_response_set_text(resp, json_text)
	return resp


ServerResponse* orm_rest_response_detail(int status, char* detail):
	return orm_rest_response(status, orm_rest_detail(detail))


# The response for a hook that returned 0.
ServerResponse* orm_rest_failed(orm_rest_request* r, int default_status, char* default_detail):
	int status = r.fail_status
	if (status == 0): status = default_status
	char* detail = r.fail_detail
	if (detail == 0): detail = default_detail
	return orm_rest_response_detail(status, detail)


ServerResponse* orm_rest_db_failure(orm_rest_request* r):
	char* msg = orm_db_error(r.db)
	if (msg == 0 || strlen(msg) == 0): msg = c"A server error occurred."
	return orm_rest_response_detail(500, msg)


# DRF NotAuthenticated / AuthenticationFailed: 401 with the first
# authenticator's challenge in WWW-Authenticate, or 403 when it has none.
ServerResponse* orm_rest_not_authenticated(orm_viewset* vs, char* detail):
	char* challenge = 0
	if (vs.authenticators.length > 0): challenge = vs.authenticators[0].challenge
	if (challenge == 0): return orm_rest_response_detail(403, detail)
	ServerResponse* resp = orm_rest_response_detail(401, detail)
	server_response_add_header(resp, c"WWW-Authenticate", challenge)
	return resp


# DRF permission_denied: unauthenticated requests (with authenticators
# configured) are NotAuthenticated, others 403 with p's message.
ServerResponse* orm_rest_permission_denied(orm_viewset* vs, orm_rest_request* r, orm_permission* p):
	if (vs.authenticators.length > 0 && r.user == 0):
		return orm_rest_not_authenticated(vs, c"Authentication credentials were not provided.")
	char* msg = orm_perm_denial_message(p)
	if (msg == 0): msg = c"You do not have permission to perform this action."
	return orm_rest_response_detail(403, msg)


ServerResponse* orm_rest_not_found_model(orm_model_desc* m):
	char* msg = orm_rest_concat3(c"No ", m.name, c" matches the given query.")
	ServerResponse* resp = orm_rest_response_detail(404, msg)
	free(msg)
	return resp


# ---------------------------------------------------------------------------
# Route resolution

const int ORM_ROUTE_LIST = 1
const int ORM_ROUTE_DETAIL = 2
const int ORM_ROUTE_HISTORY = 3
const int ORM_ROUTE_EXTRA = 4


struct orm_rest_match:
	int kind                   # ORM_ROUTE_*
	char* pk                   # owned, or 0
	orm_rest_action* extra


void orm_rest_match_free(orm_rest_match* rm):
	if (rm == 0): return
	if (rm.pk != 0): free(rm.pk)
	free(cast(char*, rm))


orm_rest_action* orm_viewset_find_action(orm_viewset* vs, char* path, int detail):
	for orm_rest_action* a in vs.extra:
		if (a.detail == detail && strcmp(a.url_path, path) == 0): return a
	return 0


# The route for a path tail ("", "/", "/5/", "5", "/5/history/", ...), or 0.
orm_rest_match* orm_rest_resolve(orm_viewset* vs, char* tail):
	if (tail == 0): tail = c""
	int n = strlen(tail)
	int start = 0
	if (n > 0 && tail[0] == '/'): start = 1
	int end = n
	if (end > start && tail[end - 1] == '/'): end = end - 1
	list[char*] segs = new list[char*]
	if (end > start):
		int s = start
		for i in range(start, end + 1):
			if (i == end || tail[i] == '/'):
				segs.push(substring(tail, s, i))
				s = i + 1
	orm_rest_match* rm = new orm_rest_match()
	int bad = 0
	for char* seg in segs:
		if (strlen(seg) == 0): bad = 1
	if (bad == 0):
		if (segs.length == 0): rm.kind = ORM_ROUTE_LIST
		else if (segs.length == 1):
			orm_rest_action* la = orm_viewset_find_action(vs, segs[0], 0)
			if (la != 0):
				rm.kind = ORM_ROUTE_EXTRA
				rm.extra = la
			else:
				rm.kind = ORM_ROUTE_DETAIL
				rm.pk = strclone(segs[0])
		else if (segs.length == 2):
			orm_rest_action* da = orm_viewset_find_action(vs, segs[1], 1)
			if (strcmp(segs[1], c"history") == 0 && vs.history != 0): rm.kind = ORM_ROUTE_HISTORY
			else if (da != 0):
				rm.kind = ORM_ROUTE_EXTRA
				rm.extra = da
			if (rm.kind != 0): rm.pk = strclone(segs[0])
	for char* sg in segs: free(sg)
	segs.free()
	if (rm.kind == 0):
		orm_rest_match_free(rm)
		return 0
	return rm


int orm_rest_action_has_method(orm_rest_action* a, char* method):
	for char* mt in a.methods:
		if (strcmp(mt, method) == 0): return 1
	return 0


# The action name serving method on route rm, 0 when none (405).
char* orm_rest_action_for(orm_viewset* vs, orm_rest_match* rm, char* method):
	if (strcmp(method, c"OPTIONS") == 0): return c"metadata"
	char* m = method
	if (strcmp(m, c"HEAD") == 0): m = c"GET"
	int on = vs.actions
	if (rm.kind == ORM_ROUTE_LIST):
		if (strcmp(m, c"GET") == 0 && (on & ORM_VS_LIST) != 0): return c"list"
		if (strcmp(m, c"POST") == 0 && (on & ORM_VS_CREATE) != 0): return c"create"
		return 0
	if (rm.kind == ORM_ROUTE_DETAIL):
		if (strcmp(m, c"GET") == 0 && (on & ORM_VS_RETRIEVE) != 0): return c"retrieve"
		if (strcmp(m, c"PUT") == 0 && (on & ORM_VS_UPDATE) != 0): return c"update"
		if (strcmp(m, c"PATCH") == 0 && (on & ORM_VS_PARTIAL_UPDATE) != 0): return c"partial_update"
		if (strcmp(m, c"DELETE") == 0 && (on & ORM_VS_DESTROY) != 0): return c"destroy"
		return 0
	if (rm.kind == ORM_ROUTE_HISTORY):
		if (strcmp(m, c"GET") == 0): return c"history"
		return 0
	if (orm_rest_action_has_method(rm.extra, method)): return rm.extra.name
	if (strcmp(method, c"HEAD") == 0 && orm_rest_action_has_method(rm.extra, c"GET")): return rm.extra.name
	return 0


char* orm_rest_method_name(int i):
	if (i == 0): return c"GET"
	if (i == 1): return c"POST"
	if (i == 2): return c"PUT"
	if (i == 3): return c"PATCH"
	if (i == 4): return c"DELETE"
	if (i == 5): return c"HEAD"
	return c"OPTIONS"


# DRF's Allow header for route rm: "GET, POST, HEAD, OPTIONS" (owned).
char* orm_rest_allowed_methods(orm_viewset* vs, orm_rest_match* rm):
	string_builder* s = string_new()
	for i in range(7):
		char* mt = orm_rest_method_name(i)
		if (orm_rest_action_for(vs, rm, mt) != 0):
			if (s.length > 0): string_append(s, c", ")
			string_append(s, mt)
	char* out = s.data
	free(s)
	return out


# ---------------------------------------------------------------------------
# Request steps

void orm_rest_request_free(orm_rest_request* r):
	if (r.pk != 0): free(r.pk)
	if (r.user != 0): User_free(r.user)
	if (r.session != 0): auth_session_free(r.session)
	if (r.params != 0): orm_params_free(r.params)
	if (r.auth_error != 0): free(r.auth_error)
	if (r.fail_detail != 0): free(r.fail_detail)
	free(cast(char*, r))


# Runs the authenticators; a response on failure, else 0.
ServerResponse* orm_rest_authenticate(orm_viewset* vs, orm_rest_request* r):
	for orm_authenticator* a in vs.authenticators:
		int v = a.authenticate(r, a.ctx)
		if (v == ORM_AUTH_OK):
			r.authenticator = cast(void*, a)
			return 0
		if (v == ORM_AUTH_ERROR): return orm_rest_db_failure(r)
		if (v == ORM_AUTH_DENIED): return orm_rest_response_detail(403, r.auth_error)
		if (v == ORM_AUTH_FAILED): return orm_rest_not_authenticated(vs, r.auth_error)
	return 0


# The permission governing r (an extra action's own, else the viewset's).
orm_permission* orm_rest_permission_for(orm_viewset* vs, orm_rest_match* rm):
	if (rm.kind == ORM_ROUTE_EXTRA && rm.extra.permission != 0): return rm.extra.permission
	return vs.permission


char* orm_rest_throttle_key(orm_throttle* t, orm_rest_request* r):
	if (r.user != 0):
		if (t.scope == ORM_THROTTLE_ANON): return 0
		char* id = itoa(r.user.id)
		char* key = orm_rest_concat(c"user:", id)
		free(id)
		return key
	char* addr = r.remote_addr
	if (addr == 0): addr = c""
	return orm_rest_concat(c"ip:", addr)


# DRF check_throttles: every throttle is asked; the longest wait wins.
ServerResponse* orm_rest_check_throttles(orm_viewset* vs, orm_rest_request* r):
	int wait = 0
	for orm_throttle* t in vs.throttles:
		char* key = orm_rest_throttle_key(t, r)
		if (key == 0): continue
		int w = orm_throttle_take(t, key)
		free(key)
		if (w > wait): wait = w
	if (wait == 0): return 0
	int secs = orm_throttle_seconds(wait)
	char* n = itoa(secs)
	string_builder* s = string_new()
	string_append(s, c"Request was throttled. Expected available in ")
	string_append(s, n)
	if (secs == 1): string_append(s, c" second.")
	else: string_append(s, c" seconds.")
	ServerResponse* resp = orm_rest_response_detail(429, s.data)
	server_response_add_header(resp, c"Retry-After", n)
	string_free(s)
	free(n)
	return resp


# get_queryset + the filter set; on failure *resp is the response.
orm_queryset* orm_rest_queryset(orm_viewset* vs, orm_rest_request* r, ServerResponse** resp):
	resp[0] = 0
	orm_clear_error(r.db)
	orm_queryset* qs = vs.get_queryset(r, vs.ctx)
	if (qs == 0):
		if (r.fail_status != 0): resp[0] = orm_rest_failed(r, 500, c"get_queryset failed")
		else if (strlen(orm_db_error(r.db)) > 0): resp[0] = orm_rest_db_failure(r)
		else: resp[0] = orm_rest_response_detail(500, c"get_queryset returned no queryset")
		return 0
	if (vs.filter == 0): return qs
	json_value* errors = 0
	orm_queryset* out = orm_filter_apply(vs.filter, qs, r.params, &errors)
	if (out == 0):
		resp[0] = orm_rest_response(400, errors)
		return 0
	return out


int orm_rest_field_is_int(orm_field_desc* fd):
	return fd.kind == ORM_INT || fd.kind == ORM_BIGINT || fd.kind == ORM_FK


# DRF get_object: the object with r.pk inside get_queryset (filtered),
# then the object permissions. On success r.object is set and *res_out
# owns it; otherwise the response.
ServerResponse* orm_rest_get_object(orm_viewset* vs, orm_rest_request* r, orm_permission* perm, orm_serializer* ser, orm_result** res_out):
	res_out[0] = 0
	ServerResponse* resp = 0
	orm_queryset* qs = orm_rest_queryset(vs, r, &resp)
	if (qs == 0): return resp
	orm_field_desc* pkf = orm_model_pk(vs.model)
	if (orm_rest_field_is_int(pkf)):
		int id = 0
		if (sql_parse_int(r.pk, &id) == 0): return orm_rest_not_found_model(vs.model)
		qs = qs.filter(q_eq_int(pkf.name, id))
	else: qs = qs.filter(q_eq(pkf.name, r.pk))
	if (ser != 0): qs = orm_serializer_prepare(ser, qs)
	orm_result* res = qs.all()
	if (res == 0): return orm_rest_db_failure(r)
	if (res.rows.length != 1):
		int many = res.rows.length > 1
		orm_result_free(res)
		if (many):
			char* msg = orm_rest_concat3(c"get() returned more than one ", vs.model.name, c"")
			resp = orm_rest_response_detail(500, msg)
			free(msg)
			return resp
		return orm_rest_not_found_model(vs.model)
	void* obj = res.rows[0]
	int v = orm_perm_has_object(perm, r, obj)
	if (v != 1):
		orm_result_free(res)
		if (v == ORM_PERM_NOT_FOUND): return orm_rest_response_detail(404, c"Not found.")
		return orm_rest_permission_denied(vs, r, perm)
	r.object = obj
	res_out[0] = res
	return 0


# DRF's parser negotiation for a JSON body: 415 for another media type.
ServerResponse* orm_rest_check_media(orm_rest_request* r):
	if (r.http.body_len == 0): return 0
	char* ct = orm_rest_header(r, c"content-type")
	if (ct == 0): return 0
	int end = 0
	while (ct[end] != 0 && ct[end] != ';'): end = end + 1
	while (end > 0 && ct[end - 1] == ' '): end = end - 1
	char* media = substring(ct, 0, end)
	ServerResponse* resp = 0
	if (http_str_ieq(media, c"application/json") == 0):
		char* msg = orm_rest_concat3(c"Unsupported media type \"", media, c"\" in request.")
		resp = orm_rest_response_detail(415, msg)
		free(msg)
	free(media)
	return resp


char* orm_rest_body(orm_rest_request* r):
	if (r.http.body_len == 0): return c"{}"
	return r.http.body


# The serialized row; reloaded by pk through the serializer's relations
# when it declares any (so nested/source fields of a written row are
# filled). Owned JSON.
json_value* orm_rest_output(orm_viewset* vs, orm_rest_request* r, orm_serializer* ser, void* row):
	orm_serializer_paths(ser)
	if (ser.select_paths.length == 0 && ser.prefetch_paths.length == 0): return orm_serializer_to_json(ser, row)
	orm_field_desc* pkf = orm_model_pk(vs.model)
	orm_queryset* qs = orm_objects(r.db, vs.model)
	if (orm_rest_field_is_int(pkf)): qs = qs.filter(q_eq_int(pkf.name, orm_slot_get(row, pkf.offset)))
	else: qs = qs.filter(q_eq(pkf.name, cast(char*, orm_slot_get(row, pkf.offset))))
	orm_result* res = orm_serializer_prepare(ser, qs).all()
	json_value* out = 0
	if (res != 0 && res.rows.length == 1): out = orm_serializer_to_json(ser, res.rows[0])
	else: out = orm_serializer_to_json(ser, row)
	if (res != 0): orm_result_free(res)
	return out


# ---------------------------------------------------------------------------
# Handlers

ServerResponse* orm_rest_do_list(orm_viewset* vs, orm_rest_request* r):
	orm_serializer* ser = orm_viewset_serializer_for(vs, c"list", 0)
	ServerResponse* resp = 0
	orm_queryset* qs = orm_rest_queryset(vs, r, &resp)
	if (qs == 0): return resp
	qs = orm_serializer_prepare(ser, qs)
	if (vs.paginator != 0):
		orm_page* pg = orm_paginate(vs.paginator, qs, r.params, r.http.path)
		if (pg.error != 0): resp = orm_rest_response(pg.status, json_clone(pg.error))
		else: resp = orm_rest_response(200, orm_page_json(pg, ser))
		orm_page_free(pg)
		return resp
	orm_result* res = qs.all()
	if (res == 0): return orm_rest_db_failure(r)
	resp = orm_rest_response(200, orm_serializer_result(ser, res))
	orm_result_free(res)
	return resp


# create / update / partial_update after the object (if any) is loaded.
ServerResponse* orm_rest_do_write(orm_viewset* vs, orm_rest_request* r, void* instance, int partial, int status):
	ServerResponse* resp = orm_rest_check_media(r)
	if (resp != 0): return resp
	orm_serializer* inser = orm_viewset_serializer_for(vs, r.action, 1)
	orm_serializer* out = orm_viewset_serializer_for(vs, r.action, 0)
	orm_validation* v = orm_serializer_validate(inser, r.db, orm_rest_body(r), instance, partial)
	if (orm_validation_ok(v) == 0):
		resp = orm_rest_response(v.status, json_clone(v.errors))
		orm_validation_free(v)
		return resp
	if (vs.on_save != 0 && vs.on_save(r, v.row, vs.hook_ctx) == 0):
		orm_validation_free(v)
		return orm_rest_failed(r, 400, c"Invalid data.")
	if (orm_validation_save(v) == 0):
		resp = orm_rest_response(v.status, json_clone(v.errors))
		orm_validation_free(v)
		return resp
	resp = orm_rest_response(status, orm_rest_output(vs, r, out, v.row))
	orm_validation_free(v)
	return resp


ServerResponse* orm_rest_do_destroy(orm_viewset* vs, orm_rest_request* r):
	if (vs.on_delete != 0 && vs.on_delete(r, r.object, vs.hook_ctx) == 0):
		return orm_rest_failed(r, 400, c"Invalid request.")
	if (orm_delete_row(r.db, vs.model, r.object) == 0): return orm_rest_db_failure(r)
	return orm_rest_response(204, 0)


ServerResponse* orm_rest_do_metadata(orm_viewset* vs, orm_rest_match* rm):
	json_value* o = json_object()
	char* suffix = c" Instance"
	if (rm.kind == ORM_ROUTE_LIST): suffix = c" List"
	else if (rm.kind == ORM_ROUTE_HISTORY): suffix = c" History"
	char* name = 0
	if (rm.kind == ORM_ROUTE_EXTRA): name = orm_rest_concat3(vs.model.name, c" ", rm.extra.name)
	else: name = orm_rest_concat(vs.model.name, suffix)
	json_object_set(o, c"name", json_string(name))
	free(name)
	json_object_set(o, c"description", json_string(c""))
	json_value* renders = json_array()
	json_array_push(renders, json_string(c"application/json"))
	json_object_set(o, c"renders", renders)
	json_value* parses = json_array()
	json_array_push(parses, json_string(c"application/json"))
	json_object_set(o, c"parses", parses)
	return orm_rest_response(200, o)


ServerResponse* orm_rest_handle(orm_viewset* vs, orm_rest_request* r, orm_rest_match* rm, orm_permission* perm);


ServerResponse* orm_rest_run(orm_viewset* vs, orm_rest_request* r, orm_rest_match* rm):
	ServerResponse* resp = orm_rest_authenticate(vs, r)
	if (resp != 0): return resp
	orm_permission* perm = orm_rest_permission_for(vs, rm)
	if (orm_perm_has(perm, r) == 0): return orm_rest_permission_denied(vs, r, perm)
	resp = orm_rest_check_throttles(vs, r)
	if (resp != 0): return resp
	if (r.action == 0):
		char* msg = orm_rest_concat3(c"Method \"", r.method, c"\" not allowed.")
		resp = orm_rest_response_detail(405, msg)
		free(msg)
		return resp
	char* act = r.action
	if (strcmp(act, c"metadata") == 0): return orm_rest_do_metadata(vs, rm)
	if (vs.history_context == 0 || r.user == 0 || orm_rest_method_is_safe(r.method)): return orm_rest_handle(vs, r, rm, perm)
	char* reason = orm_rest_concat3(r.method, c" ", r.http.path)
	char* ctx_id = orm_history_set_context(r.db, r.user.id, reason)
	free(reason)
	if (ctx_id == 0): return orm_rest_db_failure(r)
	free(ctx_id)
	resp = orm_rest_handle(vs, r, rm, perm)
	if (orm_history_clear_context(r.db) == 0 && resp.status < 400):
		server_response_free(resp)
		return orm_rest_db_failure(r)
	return resp


# The action's handler once authentication, permissions and throttles passed.
ServerResponse* orm_rest_handle(orm_viewset* vs, orm_rest_request* r, orm_rest_match* rm, orm_permission* perm):
	ServerResponse* resp = 0
	char* act = r.action
	if (strcmp(act, c"list") == 0): return orm_rest_do_list(vs, r)
	if (strcmp(act, c"create") == 0): return orm_rest_do_write(vs, r, 0, 0, 201)
	orm_result* res = 0
	if (r.pk != 0):
		orm_serializer* ser = 0
		if (strcmp(act, c"retrieve") == 0 || strcmp(act, c"update") == 0 || strcmp(act, c"partial_update") == 0):
			ser = orm_viewset_serializer_for(vs, act, 0)
		resp = orm_rest_get_object(vs, r, perm, ser, &res)
		if (resp != 0): return resp
	if (strcmp(act, c"retrieve") == 0): resp = orm_rest_response(200, orm_serializer_to_json(orm_viewset_serializer_for(vs, act, 0), r.object))
	else if (strcmp(act, c"update") == 0): resp = orm_rest_do_write(vs, r, r.object, 0, 200)
	else if (strcmp(act, c"partial_update") == 0): resp = orm_rest_do_write(vs, r, r.object, 1, 200)
	else if (strcmp(act, c"destroy") == 0): resp = orm_rest_do_destroy(vs, r)
	else if (rm.kind == ORM_ROUTE_HISTORY):
		char* text = vs.history(r, r.object, vs.history_ctx)
		if (text == 0):
			if (r.fail_status != 0): resp = orm_rest_failed(r, 500, c"history unavailable")
			else: resp = orm_rest_db_failure(r)
		else:
			resp = orm_rest_response_text(200, text)
			free(text)
	else:
		resp = rm.extra.handler(r, r.object, rm.extra.ctx)
		if (resp == 0): resp = orm_rest_failed(r, 500, c"A server error occurred.")
	if (res != 0): orm_result_free(res)
	return resp


# ---------------------------------------------------------------------------
# Dispatch

ServerResponse* orm_rest_dispatch_env(orm_viewset* vs, ServerRequest* req, char* path_tail, orm_rest_env* env);


# The viewset's response to req, whose path below the viewset's prefix is
# path_tail ("" or "/" for the collection, "/5/" for an object). The
# request is borrowed; the response is owned by the caller.
ServerResponse* orm_rest_dispatch(orm_viewset* vs, ServerRequest* req, char* path_tail):
	return orm_rest_dispatch_env(vs, req, path_tail, 0)


ServerResponse* orm_rest_dispatch_env(orm_viewset* vs, ServerRequest* req, char* path_tail, orm_rest_env* env):
	char* problem = orm_viewset_check(vs)
	if (problem != 0): return orm_rest_response_detail(500, problem)
	orm_rest_match* rm = orm_rest_resolve(vs, path_tail)
	if (rm == 0): return orm_rest_response_detail(404, c"Not found.")
	orm_rest_request* r = new orm_rest_request()
	r.http = req
	r.db = vs.db
	if (env != 0):
		if (env.db != 0): r.db = env.db
		r.is_secure = env.is_secure
		r.remote_addr = env.remote_addr
	r.model = vs.model
	r.viewset = cast(void*, vs)
	r.ctx = vs.ctx
	r.method = req.method
	r.pk = rm.pk
	rm.pk = 0
	char* query = req.query
	if (query == 0): query = c""
	r.params = orm_params_parse(query)
	r.action = orm_rest_action_for(vs, rm, req.method)
	ServerResponse* resp = orm_rest_run(vs, r, rm)
	char* allow = orm_rest_allowed_methods(vs, rm)
	server_response_add_header(resp, c"Allow", allow)
	free(allow)
	server_response_add_header(resp, c"Vary", c"Accept")
	if (strcmp(req.method, c"HEAD") == 0): server_response_set_body(resp, c"", 0)
	orm_rest_request_free(r)
	orm_rest_match_free(rm)
	return resp


# ---------------------------------------------------------------------------
# Route description (for OpenAPI generation, U4.2)

struct orm_rest_route:
	char* method               # "GET"
	char* path                 # "/books/{id}/" (owned)
	char* action               # "list", ..., or an extra action's name
	int detail                 # 1 when the path has the pk parameter
	char* pk_name              # the pk parameter's name ("id")
	orm_viewset* viewset
	orm_model_desc* model
	orm_serializer* request    # request body serializer, or 0
	orm_serializer* response   # response serializer, or 0 (no body / free-form JSON)
	int many                   # response is a list (paginated when paginator != 0)
	orm_filter_set* filter     # list: query filters, or 0
	orm_paginator* paginator   # list: pagination, or 0
	int status                 # success status
	orm_permission* permission
	int partial                # PATCH: every body field optional


orm_rest_route* orm_rest_route_new(orm_viewset* vs, char* method, char* path, char* action, int detail, int status):
	orm_rest_route* rt = new orm_rest_route()
	rt.method = method
	rt.path = strclone(path)
	rt.action = action
	rt.detail = detail
	rt.pk_name = orm_model_pk(vs.model).name
	rt.viewset = vs
	rt.model = vs.model
	rt.status = status
	rt.permission = vs.permission
	return rt


char* orm_rest_join_path(char* prefix, char* a, char* b):
	string_builder* s = string_new()
	string_append(s, prefix)
	if (s.length > 0 && s.data[s.length - 1] == '/'):
		s.length = s.length - 1
		s.data[s.length] = 0
	string_append_char(s, '/')
	if (a != 0):
		string_append(s, a)
		string_append_char(s, '/')
	if (b != 0):
		string_append(s, b)
		string_append_char(s, '/')
	char* out = s.data
	free(s)
	return out


# The routes vs serves under prefix, in DRF SimpleRouter order (list,
# list actions, detail, history, detail actions). HEAD and OPTIONS are
# left out. Free with orm_rest_routes_free.
list[orm_rest_route*] orm_viewset_routes(orm_viewset* vs, char* prefix):
	orm_viewset_check(vs)
	list[orm_rest_route*] out = new list[orm_rest_route*]
	char* pkp = orm_rest_concat3(c"{", orm_model_pk(vs.model).name, c"}")
	char* lp = orm_rest_join_path(prefix, 0, 0)
	char* dp = orm_rest_join_path(prefix, pkp, 0)
	if ((vs.actions & ORM_VS_LIST) != 0):
		orm_rest_route* l = orm_rest_route_new(vs, c"GET", lp, c"list", 0, 200)
		l.response = orm_viewset_serializer_for(vs, c"list", 0)
		l.many = 1
		l.filter = vs.filter
		l.paginator = vs.paginator
		out.push(l)
	if ((vs.actions & ORM_VS_CREATE) != 0):
		orm_rest_route* c = orm_rest_route_new(vs, c"POST", lp, c"create", 0, 201)
		c.request = orm_viewset_serializer_for(vs, c"create", 1)
		c.response = orm_viewset_serializer_for(vs, c"create", 0)
		out.push(c)
	for orm_rest_action* la in vs.extra:
		if (la.detail): continue
		char* ap = orm_rest_join_path(prefix, la.url_path, 0)
		for char* mt in la.methods:
			orm_rest_route* x = orm_rest_route_new(vs, mt, ap, la.name, 0, 200)
			x.response = la.serializer
			if (la.permission != 0): x.permission = la.permission
			out.push(x)
		free(ap)
	if ((vs.actions & ORM_VS_RETRIEVE) != 0):
		orm_rest_route* g = orm_rest_route_new(vs, c"GET", dp, c"retrieve", 1, 200)
		g.response = orm_viewset_serializer_for(vs, c"retrieve", 0)
		out.push(g)
	if ((vs.actions & ORM_VS_UPDATE) != 0):
		orm_rest_route* u = orm_rest_route_new(vs, c"PUT", dp, c"update", 1, 200)
		u.request = orm_viewset_serializer_for(vs, c"update", 1)
		u.response = orm_viewset_serializer_for(vs, c"update", 0)
		out.push(u)
	if ((vs.actions & ORM_VS_PARTIAL_UPDATE) != 0):
		orm_rest_route* pu = orm_rest_route_new(vs, c"PATCH", dp, c"partial_update", 1, 200)
		pu.request = orm_viewset_serializer_for(vs, c"partial_update", 1)
		pu.response = orm_viewset_serializer_for(vs, c"partial_update", 0)
		pu.partial = 1
		out.push(pu)
	if ((vs.actions & ORM_VS_DESTROY) != 0): out.push(orm_rest_route_new(vs, c"DELETE", dp, c"destroy", 1, 204))
	if (vs.history != 0):
		char* hp = orm_rest_join_path(prefix, pkp, c"history")
		out.push(orm_rest_route_new(vs, c"GET", hp, c"history", 1, 200))
		free(hp)
	for orm_rest_action* da in vs.extra:
		if (da.detail == 0): continue
		char* dap = orm_rest_join_path(prefix, pkp, da.url_path)
		for char* mt2 in da.methods:
			orm_rest_route* y = orm_rest_route_new(vs, mt2, dap, da.name, 1, 200)
			y.response = da.serializer
			if (da.permission != 0): y.permission = da.permission
			out.push(y)
		free(dap)
	free(pkp)
	free(lp)
	free(dp)
	return out


void orm_rest_routes_free(list[orm_rest_route*] routes):
	for orm_rest_route* rt in routes:
		free(rt.path)
		free(cast(char*, rt))
	routes.free()


# ---------------------------------------------------------------------------
# Router: several viewsets by prefix, on http_server or in process

struct orm_rest_router_entry:
	char* prefix               # owned, no trailing '/'
	orm_viewset* viewset
	void* router               # orm_rest_router*


struct orm_rest_router:
	list[orm_rest_router_entry*] entries
	orm_db* db                 # 0 = each viewset's own
	char* error                # last registration error (borrowed text), or 0
	char* openapi_path         # "/openapi.json" when served (owned), or 0
	char* openapi_title
	char* openapi_version


orm_rest_router* orm_rest_router_new():
	orm_rest_router* rt = new orm_rest_router()
	rt.entries = new list[orm_rest_router_entry*]
	return rt


void orm_rest_router_free(orm_rest_router* rt):
	if (rt.openapi_path != 0): free(rt.openapi_path)
	for orm_rest_router_entry* e in rt.entries:
		free(e.prefix)
		free(cast(char*, e))
	rt.entries.free()
	free(cast(char*, rt))


char* orm_rest_strip_slash(char* prefix):
	int n = strlen(prefix)
	while (n > 0 && prefix[n - 1] == '/'): n = n - 1
	return substring(prefix, 0, n)


# Adds vs under prefix ("/api/books"). Returns 1, or 0 with rt.error when
# the viewset is refused (no get_queryset, configuration errors) or the
# prefix is taken.
int orm_rest_router_register(orm_rest_router* rt, char* prefix, orm_viewset* vs):
	rt.error = orm_viewset_check(vs)
	if (rt.error != 0): return 0
	char* p = orm_rest_strip_slash(prefix)
	for orm_rest_router_entry* e in rt.entries:
		if (strcmp(e.prefix, p) == 0):
			free(p)
			rt.error = c"router: prefix already registered"
			return 0
	orm_rest_router_entry* entry = new orm_rest_router_entry()
	entry.prefix = p
	entry.viewset = vs
	entry.router = cast(void*, rt)
	rt.entries.push(entry)
	return 1


# The path below e's prefix when path is under it ("" or "/..."), else 0.
char* orm_rest_entry_tail(orm_rest_router_entry* e, char* path):
	if (starts_with(path, e.prefix) == 0): return 0
	char* tail = &path[strlen(e.prefix)]
	if (tail[0] != 0 && tail[0] != '/'): return 0
	return tail


# The entry with the longest prefix covering path, or 0.
orm_rest_router_entry* orm_rest_router_find(orm_rest_router* rt, char* path):
	orm_rest_router_entry* best = 0
	for orm_rest_router_entry* e in rt.entries:
		if (orm_rest_entry_tail(e, path) == 0): continue
		if (best == 0 || strlen(e.prefix) > strlen(best.prefix)): best = e
	return best


ServerResponse* orm_rest_router_openapi_response(orm_rest_router* rt, ServerRequest* req);


ServerResponse* orm_rest_router_dispatch_env(orm_rest_router* rt, ServerRequest* req, orm_rest_env* env):
	if (rt.openapi_path != 0 && strcmp(req.path, rt.openapi_path) == 0): return orm_rest_router_openapi_response(rt, req)
	orm_rest_router_entry* e = orm_rest_router_find(rt, req.path)
	if (e == 0): return orm_rest_response_detail(404, c"Not found.")
	orm_rest_env local
	local.db = rt.db
	local.is_secure = 0
	local.remote_addr = 0
	if (env != 0):
		if (env.db != 0): local.db = env.db
		local.is_secure = env.is_secure
		local.remote_addr = env.remote_addr
	return orm_rest_dispatch_env(e.viewset, req, orm_rest_entry_tail(e, req.path), &local)


# In-process dispatch of a parsed request (tests, other routers).
ServerResponse* orm_rest_router_dispatch(orm_rest_router* rt, ServerRequest* req):
	return orm_rest_router_dispatch_env(rt, req, 0)


# Dotted-quad text of a ConnectionContext peer_ip (owned).
char* orm_rest_ip_text(int ip):
	string_builder* s = string_new()
	for i in range(4):
		if (i > 0): string_append_char(s, '.')
		char* part = itoa((ip >> (8 * i)) & 255)
		string_append(s, part)
		free(part)
	char* out = s.data
	free(s)
	return out


# Copies resp into rc's buffered response.
void orm_rest_write_context(RequestContext* rc, ServerResponse* resp):
	request_context_set_status(rc, resp.status)
	for http_header* h in resp.headers: request_context_set_header(rc, h.name, h.value)
	if (resp.body_len > 0): request_context_write_body(rc, resp.body, resp.body_len)


# The server_route handler for one router entry.
void orm_rest_route_handler(RequestContext* rc, void* user_data):
	orm_rest_router_entry* e = cast(orm_rest_router_entry*, user_data)
	orm_rest_router* rt = cast(orm_rest_router*, e.router)
	ServerRequest* req = rc.request
	char* tail = orm_rest_entry_tail(e, req.path)
	if (tail == 0):
		ServerResponse* nf = orm_rest_response_detail(404, c"Not found.")
		orm_rest_write_context(rc, nf)
		server_response_free(nf)
		return
	orm_rest_env env
	env.db = rt.db
	env.is_secure = rc.conn.tls != 0
	env.remote_addr = orm_rest_ip_text(rc.conn.peer_ip)
	ServerResponse* resp = orm_rest_dispatch_env(e.viewset, req, tail, &env)
	free(env.remote_addr)
	orm_rest_write_context(rc, resp)
	server_response_free(resp)


# The server_route handler for the OpenAPI document.
void orm_rest_openapi_handler(RequestContext* rc, void* user_data):
	ServerResponse* resp = orm_rest_router_openapi_response(cast(orm_rest_router*, user_data), rc.request)
	orm_rest_write_context(rc, resp)
	server_response_free(resp)


# Registers a server_route for every viewset of rt on s (any method,
# "<prefix>*"; a longer prefix registered later still wins because each
# handler only serves paths under its own prefix boundary).
void orm_rest_router_mount(orm_rest_router* rt, ServerContext* s):
	# Longest prefixes first, so "/api/books/special" is tried before "/api/books".
	list[orm_rest_router_entry*] order = new list[orm_rest_router_entry*]
	for orm_rest_router_entry* e in rt.entries: order.push(e)
	for i in range(order.length):
		for j in range(i + 1, order.length):
			if (strlen(order[j].prefix) > strlen(order[i].prefix)):
				orm_rest_router_entry* t = order[i]
				order[i] = order[j]
				order[j] = t
	if (rt.openapi_path != 0): server_route(s, c"*", rt.openapi_path, orm_rest_openapi_handler, cast(void*, rt))
	for orm_rest_router_entry* e2 in order:
		char* pattern = orm_rest_concat(e2.prefix, c"*")
		server_route(s, c"*", pattern, orm_rest_route_handler, cast(void*, e2))
		free(pattern)
	order.free()


# Every route of every registered viewset (for OpenAPI generation).
list[orm_rest_route*] orm_rest_router_routes(orm_rest_router* rt):
	list[orm_rest_route*] out = new list[orm_rest_route*]
	for orm_rest_router_entry* e in rt.entries:
		list[orm_rest_route*] part = orm_viewset_routes(e.viewset, e.prefix)
		for orm_rest_route* x in part: out.push(x)
		part.free()
	return out


# The plan's one-call form: a one-viewset router mounted on s. Returns
# the router (0 when the viewset is refused).
orm_rest_router* orm_rest_register(ServerContext* s, char* prefix, orm_viewset* vs):
	orm_rest_router* rt = orm_rest_router_new()
	if (orm_rest_router_register(rt, prefix, vs) == 0):
		orm_rest_router_free(rt)
		return 0
	orm_rest_router_mount(rt, s)
	return rt


# ---------------------------------------------------------------------------
# In-process client helpers (tests, examples)

# Sets a request header (name lower-cased, value copied).
void orm_rest_request_header(ServerRequest* req, char* name, char* value):
	char* lower = strclone(name)
	for i in range(strlen(lower)): lower[i] = tolower(lower[i])
	if (lower in req.headers): free(req.headers[lower])
	req.headers[lower] = strclone(value)
	free(lower)


# A parsed request as server_read_request would produce it: target is
# "/path?query", body 0 = none. Free with server_request_free.
ServerRequest* orm_rest_request_build(char* method, char* target, char* body):
	ServerRequest* req = server_request_new()
	req.method = strclone(method)
	req.target = strclone(target)
	server_split_target(req)
	if (body != 0):
		free(req.body)
		req.body = strclone(body)
		req.body_len = strlen(body)
		orm_rest_request_header(req, c"Content-Type", c"application/json")
	return req


# ---------------------------------------------------------------------------
# OpenAPI (U4.2's orm_api description built from the viewsets)

# 1 when p can let an anonymous request through (for the document's
# security alternatives); a static reading of the permission tree.
int orm_rest_perm_allows_anon(orm_permission* p):
	if (p == 0): return 1
	if (p.op == ORM_PERM_AND): return orm_rest_perm_allows_anon(p.left) && orm_rest_perm_allows_anon(p.right)
	if (p.op == ORM_PERM_OR): return orm_rest_perm_allows_anon(p.left) || orm_rest_perm_allows_anon(p.right)
	if (p.op == ORM_PERM_NOT): return 0
	if (p.op == ORM_PERM_ONLY): return 1
	if (p.check == 0): return 1
	char* n = p.name
	return strcmp(n, c"is_authenticated_or_read_only") == 0 || strcmp(n, c"read_only") == 0 || strcmp(n, c"django_model_permissions_or_anon_read_only") == 0


# ORM_API_AUTH_* bits for vs.
int orm_viewset_api_auth(orm_viewset* vs):
	int auth = 0
	for orm_authenticator* a in vs.authenticators:
		if (strcmp(a.name, c"session") == 0): auth = auth | ORM_API_AUTH_SESSION
		else if (strcmp(a.name, c"token") == 0): auth = auth | ORM_API_AUTH_TOKEN
	if (auth != 0 && orm_rest_perm_allows_anon(vs.permission)): auth = auth | ORM_API_AUTH_ANON
	return auth


# Adds vs's standard routes under prefix to api (DRF trailing-slash
# paths). Extra actions are not described (orm_api has no slot for them).
orm_api_route* orm_viewset_api_route(orm_api* api, orm_viewset* vs, char* prefix):
	orm_viewset_check(vs)
	char* path = orm_rest_join_path(prefix, 0, 0)
	orm_api_route* r = orm_api_add(api, path, vs.serializer)
	int actions = 0
	if ((vs.actions & ORM_VS_LIST) != 0): actions = actions | ORM_API_LIST
	if ((vs.actions & ORM_VS_CREATE) != 0): actions = actions | ORM_API_CREATE
	if ((vs.actions & ORM_VS_RETRIEVE) != 0): actions = actions | ORM_API_RETRIEVE
	if ((vs.actions & ORM_VS_UPDATE) != 0): actions = actions | ORM_API_UPDATE
	if ((vs.actions & ORM_VS_PARTIAL_UPDATE) != 0): actions = actions | ORM_API_PARTIAL_UPDATE
	if ((vs.actions & ORM_VS_DESTROY) != 0): actions = actions | ORM_API_DESTROY
	orm_api_route_actions(r, actions)
	orm_api_route_filters(r, vs.filter)
	orm_api_route_paginator(r, vs.paginator)
	orm_api_route_auth(r, orm_viewset_api_auth(vs))
	orm_api_route_history(r, vs.history != 0)
	return r


# The description of every viewset of rt; free with orm_rest_api_free
# (route paths are owned strings).
orm_api* orm_rest_router_api(orm_rest_router* rt, char* title, char* version):
	orm_api* api = orm_api_new(title, version)
	for orm_rest_router_entry* e in rt.entries:
		orm_api_route* r = orm_viewset_api_route(api, e.viewset, e.prefix)
		char* name = e.prefix
		int last = 0
		for i in range(strlen(name)):
			if (name[i] == '/'): last = i + 1
		orm_api_route_name(r, &name[last])
	return api


void orm_rest_api_free(orm_api* api):
	for orm_api_route* r in api.routes: free(r.path)
	orm_api_free(api)


# Serves the generated document at path ("/openapi.json") from rt.
void orm_rest_router_openapi(orm_rest_router* rt, char* path, char* title, char* version):
	if (rt.openapi_path != 0): free(rt.openapi_path)
	rt.openapi_path = strclone(path)
	rt.openapi_title = title
	rt.openapi_version = version


ServerResponse* orm_rest_router_openapi_response(orm_rest_router* rt, ServerRequest* req):
	if (strcmp(req.method, c"GET") != 0 && strcmp(req.method, c"HEAD") != 0):
		char* msg = orm_rest_concat3(c"Method \"", req.method, c"\" not allowed.")
		ServerResponse* bad = orm_rest_response_detail(405, msg)
		free(msg)
		server_response_add_header(bad, c"Allow", c"GET, HEAD")
		return bad
	orm_api* api = orm_rest_router_api(rt, rt.openapi_title, rt.openapi_version)
	char* text = orm_openapi_render(api)
	ServerResponse* resp = orm_rest_response_text(200, text)
	free(text)
	orm_rest_api_free(api)
	if (strcmp(req.method, c"HEAD") == 0): server_response_set_body(resp, c"", 0)
	return resp
