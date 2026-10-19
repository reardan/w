# w-orm REST authentication and permissions (unit U4.1,
# docs/projects/orm/u4_1.md): DRF's authentication classes and
# permission classes over U3.1/U3.2.
#
#   orm_viewset_authenticator(vs, orm_auth_token())
#   orm_viewset_permission(vs, orm_perm_or(orm_perm_is_admin_user(), orm_perm_read_only()))
#
# Authenticators run in order; the first that identifies a user wins
# (DRF's request.successful_authenticator):
#   - orm_auth_session(trusted_origins): the session cookie (U3.2
#     session_load + session_user); unsafe methods then need a valid CSRF
#     token in X-CSRFToken (csrf_check_session), failing with 403
#     "CSRF Failed: <reason>". Anonymous sessions are not checked (DRF).
#   - orm_auth_token(): "Authorization: Token <raw>" (U3.2
#     authenticate_token); a bad token is a 401 "Invalid token.", and the
#     authenticator's "Token" challenge goes in WWW-Authenticate.
#   - orm_auth_custom(fn, ctx, challenge).
#
# Permissions are trees: leaves with a request check and an object
# check, combined by orm_perm_and / orm_perm_or / orm_perm_not with DRF's
# operand semantics (OR's object check pairs each side's request check
# with its object check). An object check returns 1 (allow), 0 (deny:
# 403, or 401 for an unauthenticated request) or ORM_PERM_NOT_FOUND (404,
# DjangoObjectPermissions hiding objects the user cannot read).
# Permission objects are configuration: they live as long as the process
# and may be shared between viewsets.
import libs.standard.orm.auth.perms
import libs.standard.orm.auth.token
import libs.standard.orm.auth.csrf
import libs.standard.orm.rest.pagination
import libs.standard.web.http_server


# The per-request state a viewset hands to every callback.
struct orm_rest_request:
	ServerRequest* http        # borrowed
	orm_db* db
	orm_model_desc* model
	void* viewset              # orm_viewset* (viewset.w)
	void* ctx                  # the viewset's callback context
	char* action               # "list", "create", "retrieve", "update", "partial_update", "destroy", "history", "metadata", or an extra action's name; 0 = no handler (405)
	char* method               # borrowed from http
	char* pk                   # detail routes: the path's pk text (owned), else 0
	User* user                 # authenticated user (owned), 0 = anonymous
	auth_session* session      # the session that authenticated (owned), or 0
	void* authenticator        # orm_authenticator* that identified the user, or 0
	orm_params* params         # parsed query string (owned)
	int is_secure              # request came over HTTPS (CSRF Referer rules)
	char* remote_addr          # client address for throttling (borrowed), or 0
	char* auth_error           # authentication failure detail (owned), or 0
	void* object               # detail routes: the object being acted on (owned by its result)
	int fail_status            # set by orm_rest_fail from a hook that returns 0
	char* fail_detail          # owned, or 0


# Records why a viewset hook (on_save, on_delete, history, action)
# refused: the response becomes `status` with {"detail": detail}.
void orm_rest_fail(orm_rest_request* r, int status, char* detail):
	r.fail_status = status
	if (r.fail_detail != 0): free(r.fail_detail)
	r.fail_detail = 0
	if (detail != 0): r.fail_detail = strclone(detail)


# ---------------------------------------------------------------------------
# Authentication

const int ORM_AUTH_SKIP = 0      # not attempted (no credentials of this kind)
const int ORM_AUTH_OK = 1        # r.user (and r.session) set
const int ORM_AUTH_FAILED = -1   # bad credentials: 401 with the challenge, or 403 (DRF AuthenticationFailed)
const int ORM_AUTH_DENIED = -2   # 403 regardless (DRF PermissionDenied, e.g. CSRF)
const int ORM_AUTH_ERROR = -3    # database failure: 500

# (request, ctx) -> ORM_AUTH_*; failures set r.auth_error (owned).
type orm_auth_fn = fn(orm_rest_request*, void*) -> int


struct orm_authenticator:
	char* name                 # "session", "token", ...
	orm_auth_fn* authenticate
	void* ctx
	char* challenge            # WWW-Authenticate value ("Token"), or 0 (session)
	list[char*] trusted        # session: CSRF_TRUSTED_ORIGINS


void orm_rest_auth_fail(orm_rest_request* r, char* detail):
	if (r.auth_error != 0): free(r.auth_error)
	r.auth_error = strclone(detail)


# The request header `name` (case-insensitive), or 0.
char* orm_rest_header(orm_rest_request* r, char* name):
	return server_request_header(r.http, name)


int orm_auth_session_fn(orm_rest_request* r, void* ctx):
	orm_authenticator* a = cast(orm_authenticator*, ctx)
	char* raw = session_cookie_value(orm_rest_header(r, c"cookie"))
	if (raw == 0): return ORM_AUTH_SKIP
	auth_session* s = session_load(r.db, raw)
	free(raw)
	if (s == 0):
		if (strlen(orm_db_error(r.db)) > 0): return ORM_AUTH_ERROR
		return ORM_AUTH_SKIP
	User* u = session_user(r.db, s)
	if (u == 0):
		auth_session_free(s)
		if (strlen(orm_db_error(r.db)) > 0 && orm_error_is_does_not_exist(r.db) == 0): return ORM_AUTH_ERROR
		return ORM_AUTH_SKIP
	csrf_request* cr = csrf_request_new(r.method, orm_rest_header(r, c"host"), r.is_secure)
	cr.origin = orm_rest_header(r, c"origin")
	cr.referer = orm_rest_header(r, c"referer")
	cr.token = orm_rest_header(r, c"x-csrftoken")
	char* why = csrf_check_session(s, cr, a.trusted)
	free(cast(char*, cr))
	if (why != 0):
		char* msg = orm_rest_concat(c"CSRF Failed: ", why)
		orm_rest_auth_fail(r, msg)
		free(msg)
		User_free(u)
		auth_session_free(s)
		return ORM_AUTH_DENIED
	r.user = u
	r.session = s
	return ORM_AUTH_OK


# DRF SessionAuthentication with Django's CSRF check for unsafe methods.
# trusted: CSRF_TRUSTED_ORIGINS (borrowed; 0 = none).
orm_authenticator* orm_auth_session(list[char*] trusted):
	orm_authenticator* a = new orm_authenticator()
	a.name = c"session"
	a.authenticate = orm_auth_session_fn
	a.ctx = cast(void*, a)
	if (trusted == 0): trusted = new list[char*]
	a.trusted = trusted
	return a


int orm_auth_token_fn(orm_rest_request* r, void* ctx):
	orm_authenticator* a = cast(orm_authenticator*, ctx)
	char* header = orm_rest_header(r, c"authorization")
	if (header == 0): return ORM_AUTH_SKIP
	list[char*] parts = new list[char*]
	int i = 0
	int n = strlen(header)
	while (i < n):
		while (i < n && (header[i] == ' ' || header[i] == 9)): i = i + 1
		int start = i
		while (i < n && header[i] != ' ' && header[i] != 9): i = i + 1
		if (i > start): parts.push(substring(header, start, i))
	int result = ORM_AUTH_SKIP
	if (parts.length > 0 && http_str_ieq(parts[0], a.challenge) != 0):
		if (parts.length == 1): orm_rest_auth_fail(r, c"Invalid token header. No credentials provided.")
		else if (parts.length > 2): orm_rest_auth_fail(r, c"Invalid token header. Token string should not contain spaces.")
		else:
			User* u = authenticate_token(r.db, parts[1])
			if (u != 0):
				r.user = u
				result = ORM_AUTH_OK
			else if (strcmp(orm_db_error(r.db), AUTH_INVALID_TOKEN()) == 0): orm_rest_auth_fail(r, c"Invalid token.")
			else: result = ORM_AUTH_ERROR
		if (result == ORM_AUTH_SKIP): result = ORM_AUTH_FAILED
	for char* p in parts: free(p)
	parts.free()
	return result


# DRF TokenAuthentication over U3.2's API tokens: "Authorization: Token
# <raw>". Answers 401 with "WWW-Authenticate: Token" when it is the
# viewset's first authenticator.
orm_authenticator* orm_auth_token():
	orm_authenticator* a = new orm_authenticator()
	a.name = c"token"
	a.authenticate = orm_auth_token_fn
	a.ctx = cast(void*, a)
	a.challenge = c"Token"
	return a


# A custom authenticator; challenge 0 = none (403 instead of 401).
orm_authenticator* orm_auth_custom(char* name, orm_auth_fn* fn, void* ctx, char* challenge):
	orm_authenticator* a = new orm_authenticator()
	a.name = name
	a.authenticate = fn
	a.ctx = ctx
	a.challenge = challenge
	return a


# ---------------------------------------------------------------------------
# Permissions

const int ORM_PERM_LEAF = 0
const int ORM_PERM_AND = 1
const int ORM_PERM_OR = 2
const int ORM_PERM_NOT = 3
const int ORM_PERM_ONLY = 4      # applies `left` to the listed actions only

const int ORM_PERM_NOT_FOUND = -1

# (request, ctx) -> 1 allow / 0 deny.
type orm_perm_fn = fn(orm_rest_request*, void*) -> int
# (request, object, ctx) -> 1 allow / 0 deny / ORM_PERM_NOT_FOUND.
type orm_obj_perm_fn = fn(orm_rest_request*, void*, void*) -> int


struct orm_permission:
	int op                     # ORM_PERM_*
	char* name
	orm_perm_fn* check         # LEAF: 0 = allow
	orm_obj_perm_fn* check_object   # LEAF: 0 = allow
	void* ctx
	orm_permission* left
	orm_permission* right
	list[char*] actions        # ONLY
	char* message              # denial detail, 0 = DRF's default


orm_permission* orm_perm_new(char* name, orm_perm_fn* check, orm_obj_perm_fn* check_object, void* ctx):
	orm_permission* p = new orm_permission()
	p.op = ORM_PERM_LEAF
	p.name = name
	p.check = check
	p.check_object = check_object
	p.ctx = ctx
	return p


orm_permission* orm_perm_op(int op, char* name, orm_permission* a, orm_permission* b):
	orm_permission* p = new orm_permission()
	p.op = op
	p.name = name
	p.left = a
	p.right = b
	return p


orm_permission* orm_perm_and(orm_permission* a, orm_permission* b):
	return orm_perm_op(ORM_PERM_AND, c"and", a, b)


orm_permission* orm_perm_or(orm_permission* a, orm_permission* b):
	return orm_perm_op(ORM_PERM_OR, c"or", a, b)


orm_permission* orm_perm_not(orm_permission* a):
	return orm_perm_op(ORM_PERM_NOT, c"not", a, 0)


# p for the comma-separated actions ("create,destroy"); every other
# action is allowed by this node.
orm_permission* orm_perm_for_actions(char* actions, orm_permission* p):
	orm_permission* o = orm_perm_op(ORM_PERM_ONLY, c"for_actions", p, 0)
	o.actions = new list[char*]
	int start = 0
	int i = 0
	while (1):
		if (actions[i] == ',' || actions[i] == 0):
			if (i > start): o.actions.push(substring(actions, start, i))
			start = i + 1
		if (actions[i] == 0): break
		i = i + 1
	return o


# Sets the detail text of a denial by p (DRF's permission.message).
orm_permission* orm_perm_message(orm_permission* p, char* message):
	p.message = message
	return p


int orm_perm_action_listed(orm_permission* p, orm_rest_request* r):
	if (r.action == 0): return 0
	for char* a in p.actions:
		if (strcmp(a, r.action) == 0): return 1
	return 0


# DRF has_permission.
int orm_perm_has(orm_permission* p, orm_rest_request* r):
	if (p == 0): return 1
	if (p.op == ORM_PERM_AND): return orm_perm_has(p.left, r) && orm_perm_has(p.right, r)
	if (p.op == ORM_PERM_OR): return orm_perm_has(p.left, r) || orm_perm_has(p.right, r)
	if (p.op == ORM_PERM_NOT): return orm_perm_has(p.left, r) == 0
	if (p.op == ORM_PERM_ONLY):
		if (orm_perm_action_listed(p, r) == 0): return 1
		return orm_perm_has(p.left, r)
	if (p.check == 0): return 1
	return p.check(r, p.ctx) > 0


# DRF has_object_permission: 1, 0 or ORM_PERM_NOT_FOUND.
int orm_perm_has_object(orm_permission* p, orm_rest_request* r, void* obj):
	if (p == 0): return 1
	if (p.op == ORM_PERM_AND):
		int a = orm_perm_has_object(p.left, r, obj)
		if (a != 1): return a
		return orm_perm_has_object(p.right, r, obj)
	if (p.op == ORM_PERM_OR):
		int l = orm_perm_has_object(p.left, r, obj)
		if (l == 1 && orm_perm_has(p.left, r)): return 1
		int rr = orm_perm_has_object(p.right, r, obj)
		if (rr == 1 && orm_perm_has(p.right, r)): return 1
		if (l == ORM_PERM_NOT_FOUND && rr == ORM_PERM_NOT_FOUND): return ORM_PERM_NOT_FOUND
		return 0
	if (p.op == ORM_PERM_NOT):
		if (orm_perm_has_object(p.left, r, obj) == 1): return 0
		return 1
	if (p.op == ORM_PERM_ONLY):
		if (orm_perm_action_listed(p, r) == 0): return 1
		return orm_perm_has_object(p.left, r, obj)
	if (p.check_object == 0): return 1
	int v = p.check_object(r, obj, p.ctx)
	if (v > 0): return 1
	if (v == ORM_PERM_NOT_FOUND): return ORM_PERM_NOT_FOUND
	return 0


# The detail of a denial by p: its own message, else the first message
# found in its operands, else 0.
char* orm_perm_denial_message(orm_permission* p):
	if (p == 0): return 0
	if (p.message != 0): return p.message
	char* m = orm_perm_denial_message(p.left)
	if (m != 0): return m
	return orm_perm_denial_message(p.right)


# DRF SAFE_METHODS: GET, HEAD, OPTIONS.
int orm_rest_method_is_safe(char* method):
	return strcmp(method, c"GET") == 0 || strcmp(method, c"HEAD") == 0 || strcmp(method, c"OPTIONS") == 0


# ---------------------------------------------------------------------------
# Built-in permissions (DRF's permission classes)

int orm_perm_authenticated_fn(orm_rest_request* r, void* ctx):
	return r.user != 0


int orm_perm_admin_fn(orm_rest_request* r, void* ctx):
	return r.user != 0 && r.user.is_staff != 0


int orm_perm_auth_or_read_fn(orm_rest_request* r, void* ctx):
	return r.user != 0 || orm_rest_method_is_safe(r.method)


int orm_perm_read_only_fn(orm_rest_request* r, void* ctx):
	return orm_rest_method_is_safe(r.method)


orm_permission* orm_perm_allow_any():
	return orm_perm_new(c"allow_any", 0, 0, 0)


orm_permission* orm_perm_is_authenticated():
	return orm_perm_new(c"is_authenticated", orm_perm_authenticated_fn, 0, 0)


# DRF IsAdminUser: an authenticated staff user.
orm_permission* orm_perm_is_admin_user():
	return orm_perm_new(c"is_admin_user", orm_perm_admin_fn, 0, 0)


orm_permission* orm_perm_is_staff():
	return orm_perm_is_admin_user()


orm_permission* orm_perm_is_authenticated_or_read_only():
	return orm_perm_new(c"is_authenticated_or_read_only", orm_perm_auth_or_read_fn, 0, 0)


# GET, HEAD and OPTIONS only (compose: orm_perm_or(admin, read_only)).
orm_permission* orm_perm_read_only():
	return orm_perm_new(c"read_only", orm_perm_read_only_fn, 0, 0)


# DjangoModelPermissions options.
struct orm_model_perm_opts:
	int anon_read          # unauthenticated safe requests pass (..._or_anon_read_only)
	int view               # GET/HEAD need view_<model> (DRF leaves them open)
	int objects            # DjangoObjectPermissions: also check per object


# "<app>.<action>_<model>" for r's model (owned), 0 when the table does
# not follow "<app>_<model>".
char* orm_rest_model_perm(orm_model_desc* m, char* action):
	char* app = orm_auth_model_app_label(m)
	if (app == 0): return 0
	char* lower = auth_lower(m.name)
	string_builder* s = string_new()
	string_append(s, app)
	string_append_char(s, '.')
	string_append(s, action)
	string_append_char(s, '_')
	string_append(s, lower)
	free(app)
	free(lower)
	char* out = s.data
	free(s)
	return out


# The Django permission action an HTTP method needs (DRF perms_map), ""
# for none, 0 for an unknown method.
char* orm_rest_method_perm_action(char* method, int view):
	if (strcmp(method, c"GET") == 0 || strcmp(method, c"HEAD") == 0):
		if (view): return c"view"
		return c""
	if (strcmp(method, c"OPTIONS") == 0): return c""
	if (strcmp(method, c"POST") == 0): return c"add"
	if (strcmp(method, c"PUT") == 0 || strcmp(method, c"PATCH") == 0): return c"change"
	if (strcmp(method, c"DELETE") == 0): return c"delete"
	return 0


# user_has_perm / user_has_obj_perm for the permission `method` needs.
int orm_rest_user_has_method_perm(orm_rest_request* r, char* method, int view, void* obj):
	char* action = orm_rest_method_perm_action(method, view)
	if (action == 0): return 0
	if (strlen(action) == 0): return 1
	char* perm = orm_rest_model_perm(r.model, action)
	if (perm == 0): return 0
	int ok = 0
	if (obj == 0): ok = user_has_perm(r.db, r.user, perm)
	else: ok = user_has_obj_perm(r.db, r.user, perm, r.model, obj)
	free(perm)
	return ok


int orm_perm_model_fn(orm_rest_request* r, void* ctx):
	orm_model_perm_opts* o = cast(orm_model_perm_opts*, ctx)
	if (r.user == 0): return o.anon_read && orm_rest_method_is_safe(r.method)
	return orm_rest_user_has_method_perm(r, r.method, o.view, 0)


# DRF DjangoObjectPermissions.has_object_permission: missing read access
# hides the object (404); read access without the needed one is 403.
int orm_perm_object_fn(orm_rest_request* r, void* obj, void* ctx):
	orm_model_perm_opts* o = cast(orm_model_perm_opts*, ctx)
	if (o.objects == 0): return 1
	if (r.user == 0): return 0
	if (orm_rest_user_has_method_perm(r, r.method, o.view, obj)): return 1
	if (orm_rest_method_is_safe(r.method)): return ORM_PERM_NOT_FOUND
	if (orm_rest_user_has_method_perm(r, c"GET", o.view, obj) == 0): return ORM_PERM_NOT_FOUND
	return 0


orm_permission* orm_perm_model_new(char* name, int anon_read, int view, int objects):
	orm_model_perm_opts* o = new orm_model_perm_opts()
	o.anon_read = anon_read
	o.view = view
	o.objects = objects
	return orm_perm_new(name, orm_perm_model_fn, orm_perm_object_fn, cast(void*, o))


# DRF DjangoModelPermissions: an authenticated user holding
# <app>.add_<model> for POST, change_ for PUT/PATCH, delete_ for DELETE
# (U3.1 user_has_perm); GET/HEAD/OPTIONS need none.
orm_permission* orm_perm_django_model_permissions():
	return orm_perm_model_new(c"django_model_permissions", 0, 0, 0)


# DjangoModelPermissionsOrAnonReadOnly.
orm_permission* orm_perm_django_model_permissions_or_anon_read_only():
	return orm_perm_model_new(c"django_model_permissions_or_anon_read_only", 1, 0, 0)


# DjangoModelPermissions that also require view_<model> for GET/HEAD.
orm_permission* orm_perm_django_model_view_permissions():
	return orm_perm_model_new(c"django_model_view_permissions", 0, 1, 0)


# DRF DjangoObjectPermissions: model permissions for the request, then
# U3.1's user_has_obj_perm (the registered object-permission hooks) for
# each unsafe request's object. As in DRF, reads need no object
# permission, so a refusal is always 403.
orm_permission* orm_perm_django_object_permissions():
	return orm_perm_model_new(c"django_object_permissions", 0, 0, 1)


# The same with view_<model> required for GET/HEAD (model and object, the
# usual django-guardian perms_map): objects the user cannot view are 404,
# viewable ones refused for a write are 403.
orm_permission* orm_perm_django_object_view_permissions():
	return orm_perm_model_new(c"django_object_view_permissions", 0, 1, 1)
