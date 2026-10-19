# Permissions for w-orm auth (issue #754, unit U3.1;
# docs/projects/orm/u3_1.md): Django's ModelBackend permission checks over
# auth_permission / auth_group / the M2M join tables, a per-user cache, the
# add/change/delete/view permissions Django creates per model, and an
# object-permission hook registry.
#
#   orm_auth_create_model_permissions(db, Book_desc())   # library.add_book, ...
#   user_add_permission(db, u, perm)                      # invalidates u's cache
#   if (user_has_perm(db, u, c"library.change_book")): ...
#
# Permission names are "<app_label>.<codename>" (app_label from
# django_content_type). Imports user.w, so this module is the auth entry
# point.
import libs.standard.orm.auth.user


# ---------------------------------------------------------------------------
# Per-user permission cache

struct auth_perm_cache:
	orm_db* db
	int user_id
	int superuser
	int generation
	list[char*] perms            # load order, deduplicated; owned strings
	map[char*, int] lookup       # perm -> 1 (keys are the strings in perms)


map[int, auth_perm_cache*] __auth_perm_cache
int __auth_perm_generation


void auth_perm_cache_entry_free(auth_perm_cache* e):
	if (e == 0): return
	for char* p in e.perms: free(p)
	e.perms.free()
	e.lookup.free()
	free(cast(void*, e))


# Drops one user's cached permissions (after changing them outside the
# helpers below, e.g. with raw SQL or orm_m2m_* directly).
void auth_perm_cache_invalidate_user(int user_id):
	if (__auth_perm_cache == 0): return
	if (user_id in __auth_perm_cache):
		auth_perm_cache_entry_free(__auth_perm_cache[user_id])
		__auth_perm_cache.remove(user_id)


# Invalidates every cached entry (group or permission changes). Entries are
# dropped lazily on their next use.
void auth_perm_cache_clear():
	__auth_perm_generation = __auth_perm_generation + 1


# Number of live cache entries (tests).
int auth_perm_cache_size():
	if (__auth_perm_cache == 0): return 0
	return __auth_perm_cache.length


char* auth_perm_join(char* app_label, char* codename):
	string_builder* sb = string_new()
	string_append(sb, app_label)
	string_append_char(sb, '.')
	string_append(sb, codename)
	char* r = sb.data
	free(cast(void*, sb))
	return r


# Adds every non-NULL (app_label, codename) pair of a values_list result.
void auth_perm_cache_add_rows(auth_perm_cache* e, orm_result* r):
	for orm_values_row* row in orm_values_rows(r):
		char* app = orm_values_at(row, 0)
		char* code = orm_values_at(row, 1)
		if (app == 0 || code == 0): continue
		char* perm = auth_perm_join(app, code)
		if (perm in e.lookup):
			free(perm)
			continue
		e.lookup[perm] = 1
		e.perms.push(perm)


int auth_perm_cache_query(auth_perm_cache* e, orm_queryset* qs, char* app_path, char* code_path):
	list[char*] cols = new list[char*]
	cols.push(app_path)
	cols.push(code_path)
	orm_result* r = qs.values_list(cols).all()
	cols.free()
	if (r == 0): return 0
	auth_perm_cache_add_rows(e, r)
	orm_result_free(r)
	return 1


# Loads a user's permission set: every permission for a superuser (one
# query), else the user's own plus their groups' (two queries).
auth_perm_cache* auth_perm_cache_load(orm_db* db, User* u):
	auth_perm_cache* e = new auth_perm_cache()
	e.db = db
	e.user_id = u.id
	e.superuser = u.is_superuser != 0
	e.generation = __auth_perm_generation
	e.perms = new list[char*]
	e.lookup = new map[char*, int]
	int ok = 1
	if (e.superuser):
		ok = auth_perm_cache_query(e, Permission_objects(db), c"content_type__app_label", c"codename")
	else:
		orm_queryset* mine = User_objects(db).filter(q_eq_int(c"id", u.id))
		ok = auth_perm_cache_query(e, mine, c"user_permissions__content_type__app_label", c"user_permissions__codename")
		char* group_app = c"groups__permissions__content_type__app_label"
		ok = ok && auth_perm_cache_query(e, mine, group_app, c"groups__permissions__codename")
	if (ok == 0):
		auth_perm_cache_entry_free(e)
		return 0
	return e


# The cached (or freshly loaded) permission set of an active user, 0 on a
# database error.
auth_perm_cache* auth_perm_cache_get(orm_db* db, User* u):
	if (__auth_perm_cache == 0): __auth_perm_cache = new map[int, auth_perm_cache*]
	if (u.id in __auth_perm_cache):
		auth_perm_cache* e = __auth_perm_cache[u.id]
		if (e.db == db && e.generation == __auth_perm_generation && e.superuser == (u.is_superuser != 0)): return e
		auth_perm_cache_invalidate_user(u.id)
	auth_perm_cache* fresh = auth_perm_cache_load(db, u)
	if (fresh == 0): return 0
	__auth_perm_cache[u.id] = fresh
	return fresh


# ---------------------------------------------------------------------------
# Checks

# Django's user.get_all_permissions(): a new list of new "app.codename"
# strings (free each, then the list). Inactive or unsaved users have none;
# superusers have every permission row. 0 on a database error.
list[char*] user_get_all_permissions(orm_db* db, User* u):
	list[char*] out = new list[char*]
	if (u == 0 || u.id == 0 || user_is_active(u) == 0): return out
	auth_perm_cache* e = auth_perm_cache_get(db, u)
	if (e == 0):
		out.free()
		return 0
	for char* p in e.perms: out.push(strclone(p))
	return out


void auth_perm_list_free(list[char*] perms):
	if (perms == 0): return
	for char* p in perms: free(p)
	perms.free()


# Django's user.has_perm(perm): active superusers have every permission
# (no query); inactive users have none; otherwise perm must be one of the
# user's or their groups' permissions. The first check per user loads and
# caches the set (two queries); later checks run none until the cache is
# invalidated. A database error answers 0.
int user_has_perm(orm_db* db, User* u, char* perm):
	if (u == 0 || perm == 0 || user_is_active(u) == 0): return 0
	if (u.is_superuser): return 1
	if (u.id == 0): return 0
	auth_perm_cache* e = auth_perm_cache_get(db, u)
	if (e == 0): return 0
	return perm in e.lookup


# Django's has_perms: 1 when the user has every permission in perms.
int user_has_perms(orm_db* db, User* u, list[char*] perms):
	for char* p in perms:
		if (user_has_perm(db, u, p) == 0): return 0
	return 1


# Django's has_module_perms: any permission in app_label.
int user_has_module_perms(orm_db* db, User* u, char* app_label):
	if (u == 0 || app_label == 0 || user_is_active(u) == 0): return 0
	if (u.is_superuser): return 1
	if (u.id == 0): return 0
	auth_perm_cache* e = auth_perm_cache_get(db, u)
	if (e == 0): return 0
	int n = strlen(app_label)
	for char* p in e.perms:
		if (starts_with_at(p, app_label, 0) && p[n] == '.'): return 1
	return 0


# ---------------------------------------------------------------------------
# Object permissions
#
# A hook answers whether `user` (a User*) may use `perm` on `obj`, a row
# of model `m`: > 0 grants, < 0 denies (and stops, like Django's
# PermissionDenied), 0 abstains.

type auth_obj_perm_fn = fn(orm_db*, void*, char*, orm_model_desc*, void*) -> int

list[auth_obj_perm_fn*] __auth_obj_perm_hooks


void auth_register_object_permission(auth_obj_perm_fn* hook):
	if (__auth_obj_perm_hooks == 0): __auth_obj_perm_hooks = new list[auth_obj_perm_fn*]
	__auth_obj_perm_hooks.push(hook)


void auth_clear_object_permissions():
	if (__auth_obj_perm_hooks != 0): __auth_obj_perm_hooks.clear()


# Django's user.has_perm(perm, obj). obj 0 is user_has_perm. Otherwise an
# active superuser has it, an inactive user does not, and the registered
# hooks decide in registration order (no grant = 0). Model permissions do
# not imply object permissions (as Django's ModelBackend).
int user_has_obj_perm(orm_db* db, User* u, char* perm, orm_model_desc* m, void* obj):
	if (obj == 0): return user_has_perm(db, u, perm)
	if (u == 0 || perm == 0 || user_is_active(u) == 0): return 0
	if (u.is_superuser): return 1
	if (__auth_obj_perm_hooks == 0): return 0
	for auth_obj_perm_fn* hook in __auth_obj_perm_hooks:
		int v = hook(db, cast(void*, u), perm, m, obj)
		if (v > 0): return 1
		if (v < 0): return 0
	return 0


# ---------------------------------------------------------------------------
# Changing permissions (each helper invalidates the cache it affects)

list[void*] auth_one(void* row):
	list[void*] l = new list[void*]
	l.push(row)
	return l


int auth_m2m_change(orm_db* db, orm_model_desc* m, void* row, char* field, void* target, int add):
	list[void*] targets = auth_one(target)
	int n = 0
	if (add): n = orm_m2m_add(db, m, row, field, targets)
	else: n = orm_m2m_remove(db, m, row, field, targets)
	targets.free()
	return n


# Each returns the number of links added/removed (0 or 1), -1 on error.
int user_add_permission(orm_db* db, User* u, Permission* p):
	auth_perm_cache_invalidate_user(u.id)
	return auth_m2m_change(db, User_desc(), u, c"user_permissions", p, 1)


int user_remove_permission(orm_db* db, User* u, Permission* p):
	auth_perm_cache_invalidate_user(u.id)
	return auth_m2m_change(db, User_desc(), u, c"user_permissions", p, 0)


int user_add_group(orm_db* db, User* u, Group* g):
	auth_perm_cache_invalidate_user(u.id)
	return auth_m2m_change(db, User_desc(), u, c"groups", g, 1)


int user_remove_group(orm_db* db, User* u, Group* g):
	auth_perm_cache_invalidate_user(u.id)
	return auth_m2m_change(db, User_desc(), u, c"groups", g, 0)


int group_add_permission(orm_db* db, Group* g, Permission* p):
	auth_perm_cache_clear()
	return auth_m2m_change(db, Group_desc(), g, c"permissions", p, 1)


int group_remove_permission(orm_db* db, Group* g, Permission* p):
	auth_perm_cache_clear()
	return auth_m2m_change(db, Group_desc(), g, c"permissions", p, 0)


# Creates (or finds) a group by name. Heap row (Group_free), 0 on error.
Group* group_get_or_create(orm_db* db, char* name):
	list[orm_assignment*] lookup = new list[orm_assignment*]
	lookup.push(orm_set_text(c"name", name))
	int created = 0
	orm_result* r = orm_get_or_create(db, Group_desc(), lookup, 0, &created)
	lookup.free()
	if (r == 0): return 0
	orm_model_desc* m = Group_desc()
	Group* g = Group_new()
	for orm_field_desc* fd in m.fields: orm_copy_field(m, fd, g, r.rows[0])
	orm_result_free(r)
	return g


# The permission "app_label.codename", as a heap row (Permission_free), or
# 0 ("Permission matching query does not exist" when absent).
Permission* permission_get(orm_db* db, char* perm):
	int dot = index_of(perm, c".")
	if (dot <= 0):
		orm_db_set_error(db, c"auth: permission names look like app_label.codename")
		return 0
	char* app = substring(perm, 0, dot)
	char* code = substring(perm, dot + 1, strlen(perm))
	orm_result* r = Permission_objects(db).get(q_and(q_eq(c"content_type__app_label", app), q_eq(c"codename", code)))
	free(app)
	free(code)
	if (r == 0): return 0
	orm_model_desc* m = Permission_desc()
	Permission* p = Permission_new()
	for orm_field_desc* fd in m.fields: orm_copy_field(m, fd, p, r.rows[0])
	orm_result_free(r)
	return p


# ---------------------------------------------------------------------------
# Default model permissions

# Django's camel_case_to_spaces(name).lower(): "ContentType" -> "content
# type", "HTTPLog" -> "http log". Owned.
char* auth_verbose_name(char* name):
	string_builder* sb = string_new()
	int n = strlen(name)
	for i in range(n):
		char ch = name[i]
		if (i > 0 && isupper(ch)):
			int after_lower = islower(name[i - 1])
			int before_lower = i + 1 < n && isupper(name[i + 1]) == 0
			if (after_lower || before_lower): string_append_char(sb, ' ')
		string_append_char(sb, tolower(ch))
	char* r = sb.data
	free(cast(void*, sb))
	return r


char* auth_lower(char* s):
	char* out = strclone(s)
	for i in range(strlen(out)): out[i] = tolower(out[i])
	return out


# The app label of a model whose table is "<app>_<model lower-case>" (the
# generator's default naming); 0 when the table does not follow it. Owned.
char* orm_auth_model_app_label(orm_model_desc* m):
	char* lower = auth_lower(m.name)
	int tn = strlen(m.table)
	int ln = strlen(lower)
	char* app = 0
	if (tn > ln + 1 && m.table[tn - ln - 1] == '_' && strcmp(&m.table[tn - ln], lower) == 0):
		app = substring(m.table, 0, tn - ln - 1)
	free(lower)
	return app


char* auth_default_action(int i):
	if (i == 0): return c"add"
	if (i == 1): return c"change"
	if (i == 2): return c"delete"
	return c"view"


# Django's post-migrate create_permissions for one model: the content type
# (app_label, model lower-case) and the permissions add_<model>,
# change_<model>, delete_<model>, view_<model> named "Can add <verbose
# name>", ... . Existing rows are kept. Returns the number of permissions
# created, -1 on error. Two or three queries.
int orm_auth_create_model_permissions_app(orm_db* db, char* app_label, orm_model_desc* m):
	char* model_name = auth_lower(m.name)
	list[orm_assignment*] lookup = new list[orm_assignment*]
	lookup.push(orm_set_text(c"app_label", app_label))
	lookup.push(orm_set_text(c"model", model_name))
	int created = 0
	orm_result* ct = orm_get_or_create(db, ContentType_desc(), lookup, 0, &created)
	lookup.free()
	if (ct == 0):
		free(model_name)
		return -1
	int ct_id = ContentType_rows(ct)[0].id
	orm_result_free(ct)
	char* verbose = auth_verbose_name(m.name)
	list[char*] owned = new list[char*]
	list[void*] rows = new list[void*]
	for i in range(4):
		char* action = auth_default_action(i)
		Permission* p = Permission_new()
		p.content_type_id = ct_id
		string_builder* code = string_new()
		string_append(code, action)
		string_append_char(code, '_')
		string_append(code, model_name)
		string_builder* name = string_new()
		string_append(name, c"Can ")
		string_append(name, action)
		string_append_char(name, ' ')
		string_append(name, verbose)
		p.codename = code.data
		p.name = name.data
		owned.push(code.data)
		owned.push(name.data)
		free(cast(void*, code))
		free(cast(void*, name))
		rows.push(p)
	list[char*] conflict = new list[char*]
	conflict.push(c"content_type")
	conflict.push(c"codename")
	int n = orm_bulk_create(db, Permission_desc(), rows, 0, orm_conflict_ignore(conflict))
	for void* row in rows: Permission_free(cast(Permission*, row))
	rows.free()
	for char* s in owned: free(s)
	owned.free()
	free(verbose)
	free(model_name)
	auth_perm_cache_clear()
	return n


# orm_auth_create_model_permissions_app with the app label taken from the
# model's table ("library_book" -> "library"). Models with a table= that
# does not follow "<app>_<model>" need the _app form (-1 and an error).
int orm_auth_create_model_permissions(orm_db* db, orm_model_desc* m):
	char* app = orm_auth_model_app_label(m)
	if (app == 0):
		orm_db_set_error(db, c"auth: no app label in the table name; use orm_auth_create_model_permissions_app")
		return -1
	int n = orm_auth_create_model_permissions_app(db, app, m)
	free(app)
	return n


# The permissions Django's migrate creates for its own auth and
# contenttypes models (auth.add_user, ..., contenttypes.view_contenttype).
# Returns permissions created, -1 on error.
int orm_auth_create_auth_permissions(orm_db* db):
	auth_register()
	int total = 0
	int n = orm_auth_create_model_permissions_app(db, c"contenttypes", ContentType_desc())
	if (n < 0): return -1
	total = total + n
	n = orm_auth_create_model_permissions_app(db, c"auth", Permission_desc())
	if (n < 0): return -1
	total = total + n
	n = orm_auth_create_model_permissions_app(db, c"auth", Group_desc())
	if (n < 0): return -1
	total = total + n
	n = orm_auth_create_model_permissions_app(db, c"auth", User_desc())
	if (n < 0): return -1
	return total + n
