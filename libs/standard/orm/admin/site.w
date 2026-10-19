# w-orm admin site and model registration (unit U5.1,
# docs/projects/orm/u5_1.md): which models the admin shows and how, the
# URL layout, and the staff / model-permission gate every view runs.
#
#   orm_admin_site* site = orm_admin_site_new()
#   orm_model_admin* ma = orm_admin_register(site, Book_desc())
#   ma.columns(c"title,author,status,price").search_fields(c"title,author__name")
#   ma.list_filter(c"status,author").ordering(c"title").readonly_fields(c"published_at")
#   ma.per_page(25)
#   orm_admin_mount(site, router, c"/admin/")      # views.w
#
# Field lists are comma separated. Paths may follow FKs with "__"
# ("author__name"); the changelist select_relates every FK they cross.
import libs.standard.orm.web.forms
import libs.standard.orm.web.middleware
import libs.standard.orm.rest.pagination


struct orm_model_admin:
	void* site                     # orm_admin_site*
	orm_model_desc* model
	char* app                      # owned ("library")
	char* model_name               # owned, lower-case ("book")
	char* verbose_name             # owned ("book")
	char* verbose_plural           # owned ("books")
	list[char*] columns            # owned list_display paths
	list[char*] search           # owned paths
	list[char*] filters            # owned field names
	list[char*] order              # owned specs ("-title")
	list[char*] readonly           # owned field names
	list[char*] select_paths       # owned FK paths the changelist select_relates
	int page_size
	char* display_field            # field naming a row ("title"), 0 = guess
	orm_serializer* ser            # form serializer
	int owns_ser
	orm_filter_set* fs             # built at mount
	orm_paginator* pager           # built at mount


struct orm_admin_site:
	char* title                    # page header ("W administration")
	char* prefix                   # mount prefix ("/admin/"), set by orm_admin_mount
	orm_router* router             # the admin's own routes (included under prefix; freed with the site)
	orm_tpl_engine* templates      # admin templates
	list[orm_model_admin*] models
	char* error                    # first configuration error (owned), or 0
	int writes                     # admin writes made (history contexts set)


char* adm_cat(char* a, char* b):
	return orm_rest_concat(a, b)


char* adm_cat3(char* a, char* b, char* c):
	return orm_rest_concat3(a, b, c)


void adm_free_list(list[char*] l):
	if (l == 0): return
	for char* s in l: free(s)
	l.free()


# Owned pieces of a comma separated list, blanks dropped and trimmed.
list[char*] adm_split_names(char* text):
	list[char*] out = new list[char*]
	if (text == 0): return out
	list[char*] parts = split(text, ',')
	for char* p in parts:
		char* t = strip(p)
		free(p)
		if (t[0] == 0): free(t)
		else: out.push(t)
	parts.free()
	return out


void adm_site_fail(orm_admin_site* site, char* a, char* b, char* c):
	if (site.error != 0): return
	string_builder* s = string_new()
	string_append(s, a)
	if (b != 0): string_append(s, b)
	if (c != 0): string_append(s, c)
	site.error = s.data
	free(cast(void*, s))


# The default admin templates, relative to the working directory.
char* orm_admin_default_templates():
	return c"libs/standard/orm/admin/templates"


orm_admin_site* orm_admin_site_new():
	orm_admin_site* site = new orm_admin_site()
	site.title = c"W administration"
	site.prefix = strclone(c"/admin/")
	site.models = new list[orm_model_admin*]
	site.templates = orm_tpl_engine_new(orm_admin_default_templates())
	return site


# Loads the admin templates from dir instead (copy or override them there).
void orm_admin_site_templates(orm_admin_site* site, char* dir):
	orm_tpl_engine_free(site.templates)
	if (site.router != 0): orm_router_free(site.router)
	site.templates = orm_tpl_engine_new(dir)


char* orm_admin_site_error(orm_admin_site* site):
	return site.error


# Registers model m with default options: the changelist shows the row
# label (Django's list_display = ("__str__",)), ordered by descending pk,
# 100 rows a page; the form covers every writable field. The app label is the table prefix ("library_book" ->
# "library"); orm_model_admin_app_label overrides it.
orm_model_admin* orm_admin_register(orm_admin_site* site, orm_model_desc* m):
	orm_model_admin* ma = new orm_model_admin()
	ma.site = cast(void*, site)
	ma.model = m
	ma.app = orm_auth_model_app_label(m)
	if (ma.app == 0):
		ma.app = strclone(m.table)
		adm_site_fail(site, c"admin: table of ", m.name, c" is not <app>_<model>; set the app label")
	ma.model_name = auth_lower(m.name)
	ma.verbose_name = auth_verbose_name(m.name)
	ma.verbose_plural = adm_cat(ma.verbose_name, c"s")
	ma.columns = new list[char*]
	ma.search = new list[char*]
	ma.filters = new list[char*]
	ma.order = new list[char*]
	ma.readonly = new list[char*]
	ma.select_paths = new list[char*]
	ma.page_size = 100
	for orm_model_admin* other in site.models:
		if (other.model == m): adm_site_fail(site, c"admin: ", m.name, c" is registered twice")
	site.models.push(ma)
	return ma


orm_model_admin* orm_model_admin_app_label(orm_model_admin* ma, char* app):
	free(ma.app)
	ma.app = strclone(app)
	orm_admin_site* site = cast(orm_admin_site*, ma.site)
	if (site.error != 0 && index_of(site.error, c" is not <app>_<model>") >= 0):
		free(site.error)
		site.error = 0
	return ma


orm_model_admin* orm_model_admin_list_display(orm_model_admin* ma, char* paths):
	adm_free_list(ma.columns)
	ma.columns = adm_split_names(paths)
	return ma


orm_model_admin* orm_model_admin_search_fields(orm_model_admin* ma, char* paths):
	adm_free_list(ma.search)
	ma.search = adm_split_names(paths)
	return ma


# Sidebar filters: BOOL, ENUM and FK fields (Django's list_filter).
orm_model_admin* orm_model_admin_list_filter(orm_model_admin* ma, char* fields):
	adm_free_list(ma.filters)
	ma.filters = adm_split_names(fields)
	return ma


# Default changelist ordering ("-price,title"); the pk breaks ties.
orm_model_admin* orm_model_admin_ordering(orm_model_admin* ma, char* specs):
	adm_free_list(ma.order)
	ma.order = adm_split_names(specs)
	return ma


# Fields shown on the change page but never written by its form.
orm_model_admin* orm_model_admin_readonly_fields(orm_model_admin* ma, char* fields):
	adm_free_list(ma.readonly)
	ma.readonly = adm_split_names(fields)
	return ma


orm_model_admin* orm_model_admin_per_page(orm_model_admin* ma, int n):
	if (n > 0): ma.page_size = n
	return ma


# The field whose value names a row in links, filters and the delete
# preview (Django's __str__).
orm_model_admin* orm_model_admin_display(orm_model_admin* ma, char* field):
	ma.display_field = field
	return ma


# Forms use ser (borrowed; it must outlive the site) instead of a
# serializer over every field: its read-only / excluded fields, renames
# and validators apply to admin forms as they do to the REST layer.
# readonly_fields are marked read-only on it when the site is mounted.
orm_model_admin* orm_model_admin_serializer(orm_model_admin* ma, orm_serializer* ser):
	if (ma.owns_ser && ma.ser != 0): orm_serializer_free(ma.ser)
	ma.ser = ser
	ma.owns_ser = 0
	return ma


void orm_model_admin_free(orm_model_admin* ma):
	free(ma.app)
	free(ma.model_name)
	free(ma.verbose_name)
	free(ma.verbose_plural)
	adm_free_list(ma.columns)
	adm_free_list(ma.search)
	adm_free_list(ma.filters)
	adm_free_list(ma.order)
	adm_free_list(ma.readonly)
	adm_free_list(ma.select_paths)
	if (ma.owns_ser && ma.ser != 0): orm_serializer_free(ma.ser)
	if (ma.fs != 0): orm_filter_free(ma.fs)
	if (ma.pager != 0): orm_paginator_free(ma.pager)
	free(cast(void*, ma))


# Frees the site and its model admins (not the router it was mounted on).
void orm_admin_site_free(orm_admin_site* site):
	if (site == 0): return
	for orm_model_admin* ma in site.models: orm_model_admin_free(ma)
	site.models.free()
	orm_tpl_engine_free(site.templates)
	free(site.prefix)
	if (site.error != 0): free(site.error)
	free(cast(void*, site))


orm_model_admin* orm_admin_lookup(orm_admin_site* site, char* app, char* model):
	if (app == 0 || model == 0): return 0
	for orm_model_admin* ma in site.models:
		if (strcmp(ma.app, app) == 0 && strcmp(ma.model_name, model) == 0): return ma
	return 0


orm_model_admin* orm_admin_for_model(orm_admin_site* site, orm_model_desc* m):
	for orm_model_admin* ma in site.models:
		if (ma.model == m): return ma
	return 0


# ---------------------------------------------------------------------------
# Configuration checks (run by orm_admin_mount)

# The field at the end of path following FKs only, or 0. Adds every FK
# prefix to paths (deduplicated) when paths is not 0.
orm_field_desc* adm_fk_path_field(orm_model_desc* m, char* path, list[char*] paths):
	list[char*] parts = orm_path_split(path)
	orm_field_desc* out = 0
	string_builder* prefix = string_new()
	for i in range(parts.length):
		if (m == 0): break
		orm_field_desc* fd = orm_model_field(m, parts[i])
		if (fd == 0 || orm_field_has_column(fd) == 0): break
		if (i > 0): string_append(prefix, c"__")
		string_append(prefix, parts[i])
		if (fd.kind == ORM_FK && paths != 0):
			int seen = 0
			for char* p in paths:
				if (strcmp(p, prefix.data) == 0): seen = 1
			if (seen == 0): paths.push(strclone(prefix.data))
		if (i == parts.length - 1): out = fd
		else if (fd.kind == ORM_FK): m = orm_field_target(fd)
		else: m = 0
	string_free(prefix)
	adm_free_list(parts)
	return out


int adm_check_model(orm_admin_site* site, orm_model_admin* ma):
	orm_model_desc* m = ma.model
	if (orm_model_pk(m) == 0): adm_site_fail(site, c"admin: ", m.name, c" has no primary key")
	if (ma.display_field != 0):
		orm_field_desc* df = orm_model_field(m, ma.display_field)
		if (df == 0 || orm_field_has_column(df) == 0): adm_site_fail(site, c"admin: display field '", ma.display_field, c"' is not a column")
	adm_free_list(ma.select_paths)
	ma.select_paths = new list[char*]
	if (ma.fs != 0): orm_filter_free(ma.fs)
	orm_filter_set* fs = orm_filter_new(m)
	fs.search_param = c"q"
	fs.ordering_param = c"o"
	ma.fs = fs
	if (ma.pager != 0): orm_paginator_free(ma.pager)
	ma.pager = orm_paginator_page_number(ma.page_size)
	ma.pager.page_param = c"p"
	ma.pager.max_page_size = ma.page_size
	orm_paginator_reserve(ma.pager, fs)
	for char* path in ma.columns:
		if (adm_fk_path_field(m, path, ma.select_paths) == 0): adm_site_fail(site, c"admin: list_display '", path, c"' is not a field path")
		else: orm_filter_ordering(fs, path)
	# Django's default: newest first.
	if (ma.order.length == 0 && orm_model_pk(m) != 0): ma.order.push(adm_cat(c"-", orm_model_pk(m).name))
	for char* spec in ma.order:
		char* path = spec
		if (path[0] == '-'): path = path + 1
		if (adm_fk_path_field(m, path, 0) == 0): adm_site_fail(site, c"admin: ordering '", path, c"' is not a field path")
		else if (orm_filter_ordering_allowed(fs, path) == 0): orm_filter_ordering(fs, path)
	for char* s in ma.search:
		orm_field_desc* sf = adm_fk_path_field(m, s, 0)
		if (sf == 0 || orm_field_is_text_backed(sf) == 0): adm_site_fail(site, c"admin: search field '", s, c"' is not a text field path")
		else: orm_filter_search(fs, s)
	for char* name in ma.filters:
		orm_field_desc* ff = orm_model_field(m, name)
		if (ff == 0 || (ff.kind != ORM_BOOL && ff.kind != ORM_ENUM && ff.kind != ORM_FK)):
			adm_site_fail(site, c"admin: list_filter '", name, c"' must be a BOOL, ENUM or FK field")
		else: orm_filter_allow(fs, name, c"exact")
	if (fs.error != 0): adm_site_fail(site, fs.error, 0, 0)
	if (ma.ser == 0):
		ma.ser = orm_serializer_new(m)
		ma.owns_ser = 1
	for char* ro in ma.readonly:
		orm_field_desc* rf = orm_model_field(m, ro)
		if (rf == 0 || orm_field_has_column(rf) == 0): adm_site_fail(site, c"admin: readonly field '", ro, c"' is not a column")
		else if (orm_serializer_field(ma.ser, ro) != 0): orm_serializer_read_only(ma.ser, ro)
	if (orm_serializer_error(ma.ser) != 0): adm_site_fail(site, orm_serializer_error(ma.ser), 0, 0)
	return site.error == 0


# ---------------------------------------------------------------------------
# URLs (owned strings under the mount prefix)

char* orm_admin_url(orm_admin_site* site, char* rest):
	return adm_cat(site.prefix, rest)


# <prefix><app>/<model>/ + rest
char* orm_admin_model_url(orm_model_admin* ma, char* rest):
	orm_admin_site* site = cast(orm_admin_site*, ma.site)
	string_builder* s = string_new()
	string_append(s, site.prefix)
	string_append(s, ma.app)
	string_append_char(s, '/')
	string_append(s, ma.model_name)
	string_append_char(s, '/')
	if (rest != 0): string_append(s, rest)
	char* out = s.data
	free(cast(void*, s))
	return out


# <prefix><app>/<model>/<pk>/<action>/ (action 0 = "change")
char* orm_admin_object_url(orm_model_admin* ma, int pk, char* action):
	if (action == 0): action = c"change"
	string_builder* s = string_new()
	string_append_int(s, pk)
	string_append_char(s, '/')
	string_append(s, action)
	string_append_char(s, '/')
	char* out = orm_admin_model_url(ma, s.data)
	string_free(s)
	return out


# ---------------------------------------------------------------------------
# Permissions

# "<app>.<action>_<model>"
char* orm_admin_perm_name(orm_model_admin* ma, char* action):
	string_builder* s = string_new()
	string_append(s, ma.app)
	string_append_char(s, '.')
	string_append(s, action)
	string_append_char(s, '_')
	string_append(s, ma.model_name)
	char* out = s.data
	free(cast(void*, s))
	return out


# The request's user holds <app>.<action>_<model> (U3.1 has_perm: active
# superusers pass without a query; others load their permissions once
# per request).
int orm_admin_has_perm(orm_web_request* r, orm_model_admin* ma, char* action):
	if (r.user == 0): return 0
	char* perm = orm_admin_perm_name(ma, action)
	int ok = orm_web_has_perm(r, perm)
	free(perm)
	return ok


# Django: the change permission implies view.
int orm_admin_can_view(orm_web_request* r, orm_model_admin* ma):
	return orm_admin_has_perm(r, ma, c"view") || orm_admin_has_perm(r, ma, c"change")


# Active staff only (Django's AdminSite.has_permission).
int orm_admin_is_staff(orm_web_request* r):
	return r.user != 0 && r.user.is_active != 0 && r.user.is_staff != 0


# A safe ?next= target: a local absolute path ("/x", not "//host" or
# "/\host"); else 0.
int adm_safe_next(char* next):
	if (next == 0 || next[0] != '/'): return 0
	if (next[1] == '/' || next[1] == 92): return 0
	int i = 0
	while (next[i] != 0):
		if (next[i] < 32): return 0
		i = i + 1
	return 1


# A redirect to login_url?next=<path>.
ServerResponse* adm_login_redirect(orm_web_request* r, char* login_url):
	char* next = url_quote(r.path)
	string_builder* s = string_new()
	string_append(s, login_url)
	string_append(s, c"?next=")
	string_append(s, next)
	free(next)
	ServerResponse* resp = orm_web_redirect(s.data)
	string_free(s)
	return resp


# 0 when the request may enter the admin; otherwise the redirect to the
# admin login page with ?next=<path> (anonymous, inactive or non-staff
# users, as Django's admin_view).
ServerResponse* orm_admin_gate(orm_web_request* r, orm_admin_site* site):
	if (orm_admin_is_staff(r)): return 0
	char* login = orm_admin_url(site, c"login/")
	ServerResponse* resp = adm_login_redirect(r, login)
	free(login)
	return resp


# ---------------------------------------------------------------------------
# Display

orm_field_desc* adm_guess_display(orm_model_desc* m):
	char* names = c"name,title,username,label,slug"
	list[char*] cands = split(names, ',')
	orm_field_desc* out = 0
	for char* c in cands:
		orm_field_desc* fd = orm_model_field(m, c)
		if (out == 0 && fd != 0 && orm_field_has_column(fd) && orm_field_is_text_backed(fd)): out = fd
	adm_free_list(cands)
	return out


orm_field_desc* orm_admin_display_field(orm_admin_site* site, orm_model_desc* m):
	orm_model_admin* ma = 0
	if (site != 0): ma = orm_admin_for_model(site, m)
	if (ma != 0 && ma.display_field != 0): return orm_model_field(m, ma.display_field)
	return adm_guess_display(m)


# A row's label (owned): its display field, else "<Model> object (<pk>)".
char* orm_admin_label(orm_admin_site* site, orm_model_desc* m, void* row):
	orm_field_desc* df = orm_admin_display_field(site, m)
	if (df != 0):
		char* t = orm_rest_field_text(df, row)
		if (t != 0 && t[0] != 0): return t
		if (t != 0): free(t)
	string_builder* s = string_new()
	string_append(s, m.name)
	string_append(s, c" object (")
	orm_field_desc* pk = orm_model_pk(m)
	if (pk != 0): string_append_int(s, orm_slot_get(row, pk.offset))
	string_append(s, c")")
	char* out = s.data
	free(cast(void*, s))
	return out


# The text a field shows (owned): "-" for NULL, Yes / No for booleans,
# an FK's loaded row by its label (its id when not loaded).
char* orm_admin_field_text(orm_admin_site* site, orm_field_desc* fd, void* row):
	if (row == 0): return strclone(c"-")
	if (fd.kind == ORM_FK && fd.rel_offset >= 0):
		void* target = cast(void*, orm_slot_get(row, fd.rel_offset))
		if (target != 0): return orm_admin_label(site, orm_field_target(fd), target)
	char* t = orm_rest_field_text(fd, row)
	if (t == 0): return strclone(c"-")
	if (fd.kind == ORM_BOOL):
		int on = strcmp(t, c"1") == 0
		free(t)
		if (on): return strclone(c"Yes")
		return strclone(c"No")
	return t


# The text at a path of FKs ("author__name") from row (owned).
char* orm_admin_path_text(orm_admin_site* site, orm_model_desc* m, void* row, char* path):
	list[char*] parts = orm_path_split(path)
	char* out = 0
	for i in range(parts.length):
		if (out != 0): break
		orm_field_desc* fd = orm_model_field(m, parts[i])
		if (fd == 0 || row == 0):
			out = strclone(c"-")
		else if (i == parts.length - 1):
			out = orm_admin_field_text(site, fd, row)
		else if (fd.kind == ORM_FK && fd.rel_offset >= 0):
			row = cast(void*, orm_slot_get(row, fd.rel_offset))
			m = orm_field_target(fd)
		else: out = strclone(c"-")
	adm_free_list(parts)
	if (out == 0): out = strclone(c"-")
	return out


# Column header text of a path: its last field as a label ("Author name"
# for "author__name").
char* orm_admin_path_label(char* path):
	char* spaced = replace(path, c"__", c" ")
	char* out = orm_form_label(spaced)
	free(spaced)
	return out


# The plural verbose name, capitalised ("Books").
char* orm_admin_plural_title(orm_model_admin* ma):
	return orm_form_label(ma.verbose_plural)
