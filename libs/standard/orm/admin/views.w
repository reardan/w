# w-orm admin views (unit U5.1, docs/projects/orm/u5_1.md): index,
# login / logout, changelist, add / change / view, delete with a cascade
# preview, and the history tab (versions, diffs, revert) for models with
# trigger history. Mounted on a U4.3 router; the app's middleware
# provides the request db / transaction, session, user and CSRF check.
#
#   orm_admin_mount(site, router, c"/admin/")
#
# URLs under the prefix:
#   ""                                  index (models the user may see)
#   login/  logout/
#   <app>/<model>/                      changelist (?q= ?o= ?p= ?<filter>=)
#   <app>/<model>/add/
#   <app>/<model>/<pk>/change/          edit, or a read-only detail page with only view
#   <app>/<model>/<pk>/delete/
#   <app>/<model>/<pk>/history/         versions
#   <app>/<model>/<pk>/history/<id>/    one version: values, diff, revert (POST)
#
# Every view but login requires an active staff user (others are
# redirected to login/?next=) and the model's view / add / change /
# delete permission (403 otherwise). Writes publish a history context
# (the staff user and a reason such as "Changed title and price.") for
# the duration of the write.
import libs.standard.orm.admin.cascade
import libs.standard.orm.history.history


# ---------------------------------------------------------------------------
# Rendering helpers

orm_admin_site* adm_site(void* ctx):
	return cast(orm_admin_site*, ctx)


orm_tpl_value* adm_crumb(orm_tpl_ctx* t, char* label, char* url):
	orm_tpl_value* c = orm_tpl_map(t)
	orm_tpl_put_str(t, c, c"label", label)
	if (url != 0): orm_tpl_put(c, c"url", orm_tpl_str_take(t, url))
	return c


# The request's template context plus the admin's: site_title, admin_url,
# logout_url, title, breadcrumbs (Home first).
orm_tpl_ctx* adm_context(orm_web_request* r, orm_admin_site* site, char* title):
	orm_tpl_ctx* t = orm_web_context(r)
	orm_tpl_set_str(t, c"site_title", site.title)
	orm_tpl_set_str(t, c"admin_url", site.prefix)
	orm_tpl_set(t, c"logout_url", orm_tpl_str_take(t, orm_admin_url(site, c"logout/")))
	orm_tpl_set_str(t, c"title", title)
	orm_tpl_value* crumbs = orm_tpl_list(t)
	orm_tpl_push(crumbs, adm_crumb(t, c"Home", strclone(site.prefix)))
	orm_tpl_set(t, c"breadcrumbs", crumbs)
	return t


# Home > App > Models [> label]
void adm_model_crumbs(orm_tpl_ctx* t, orm_model_admin* ma, char* label):
	orm_tpl_value* crumbs = orm_tpl_lookup_name(t, c"breadcrumbs")
	char* app = orm_form_label(ma.app)
	orm_tpl_push(crumbs, adm_crumb(t, app, 0))
	free(app)
	char* plural = orm_admin_plural_title(ma)
	char* url = 0
	if (label != 0): url = orm_admin_model_url(ma, 0)
	orm_tpl_push(crumbs, adm_crumb(t, plural, url))
	free(plural)
	if (label != 0): orm_tpl_push(crumbs, adm_crumb(t, label, 0))


# Renders an admin template (frees t). Template errors are 500s.
ServerResponse* adm_render(orm_web_request* r, orm_admin_site* site, char* name, orm_tpl_ctx* t, int status):
	char* html = orm_tpl_render(site.templates, name, t)
	orm_tpl_ctx_free(t)
	if (html == 0):
		char* body = adm_cat(c"Template error: ", orm_tpl_error(site.templates))
		ServerResponse* bad = orm_web_text(500, body)
		free(body)
		return bad
	return orm_web_html_take(status, html)


ServerResponse* adm_error(orm_web_request* r):
	return orm_web_text(500, orm_db_error(r.db))


ServerResponse* adm_forbidden():
	return orm_web_forbidden(c"permission denied")


int adm_is_post(orm_web_request* r):
	return strcmp(r.method, c"POST") == 0


# The model admin named by the route's app / model parameters.
orm_model_admin* adm_model(orm_web_request* r, orm_admin_site* site):
	return orm_admin_lookup(site, orm_web_param(r, c"app"), orm_web_param(r, c"model"))


# Loads object <pk> of ma (FKs of the changelist columns selected), or
# 0 with orm_db_error set.
orm_result* adm_get_object(orm_web_request* r, orm_model_admin* ma, int pk):
	orm_field_desc* pkf = orm_model_pk(ma.model)
	orm_queryset* qs = orm_objects(r.db, ma.model)
	for orm_field_desc* f in ma.model.fields:
		if (f.kind == ORM_FK && f.rel_offset >= 0): qs = qs.select_related(f.name)
	return qs.get(q_eq_int(pkf.name, pk))


ServerResponse* adm_missing(orm_web_request* r):
	if (orm_error_is_does_not_exist(r.db)): return orm_web_not_found()
	return adm_error(r)


# ---------------------------------------------------------------------------
# Writes and the history context

# Publishes the history context (staff user, reason) for one write.
int adm_begin_write(orm_web_request* r, orm_admin_site* site, char* reason):
	char* id = orm_history_set_context(r.db, r.user.id, reason)
	if (id == 0): return 0
	free(id)
	site.writes = site.writes + 1
	return 1


int adm_end_write(orm_web_request* r):
	return orm_history_clear_context(r.db)


# ---------------------------------------------------------------------------
# Index, login, logout

ServerResponse* adm_index_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	ServerResponse* g = orm_admin_gate(r, site)
	if (g != 0): return g
	orm_tpl_ctx* t = adm_context(r, site, c"Site administration")
	orm_tpl_value* apps = orm_tpl_list(t)
	# Apps by label, models by name.
	list[char*] labels = new list[char*]
	for orm_model_admin* ma in site.models:
		int seen = 0
		for char* l in labels:
			if (strcmp(l, ma.app) == 0): seen = 1
		if (seen == 0):
			int at = 0
			while (at < labels.length && strcmp(labels[at], ma.app) < 0): at = at + 1
			labels.insert(at, ma.app)
	for char* label in labels:
		list[orm_model_admin*] ms = new list[orm_model_admin*]
		for orm_model_admin* ma2 in site.models:
			if (strcmp(ma2.app, label) != 0): continue
			int view = orm_admin_can_view(r, ma2)
			int add = orm_admin_has_perm(r, ma2, c"add")
			if (view == 0 && add == 0): continue
			int pos = 0
			while (pos < ms.length && strcmp(ms[pos].model.name, ma2.model.name) < 0): pos = pos + 1
			ms.insert(pos, ma2)
		if (ms.length > 0):
			orm_tpl_value* app = orm_tpl_map(t)
			orm_tpl_put_str(t, app, c"label", label)
			orm_tpl_put(app, c"name", orm_tpl_str_take(t, orm_form_label(label)))
			orm_tpl_value* models = orm_tpl_list(t)
			for orm_model_admin* m in ms:
				orm_tpl_value* mv = orm_tpl_map(t)
				orm_tpl_put_str(t, mv, c"name", m.model_name)
				orm_tpl_put(mv, c"plural", orm_tpl_str_take(t, orm_admin_plural_title(m)))
				if (orm_admin_can_view(r, m)): orm_tpl_put(mv, c"list_url", orm_tpl_str_take(t, orm_admin_model_url(m, 0)))
				if (orm_admin_has_perm(r, m, c"add")): orm_tpl_put(mv, c"add_url", orm_tpl_str_take(t, orm_admin_model_url(m, c"add/")))
				orm_tpl_push(models, mv)
			orm_tpl_put(app, c"models", models)
			orm_tpl_push(apps, app)
		ms.free()
	labels.free()
	orm_tpl_set(t, c"apps", apps)
	return adm_render(r, site, c"index.html", t, 200)


# The login page's redirect target: a safe ?next=, else the index.
char* adm_next(orm_web_request* r, orm_admin_site* site):
	char* next = orm_web_query_get(r, c"next")
	if (adm_safe_next(next)): return strclone(next)
	return strclone(site.prefix)


ServerResponse* adm_login_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	if (adm_is_post(r) == 0 && orm_admin_is_staff(r)): return orm_web_redirect_take(adm_next(r, site))
	orm_tpl_ctx* t = adm_context(r, site, c"Log in")
	char* action = orm_admin_url(site, c"login/")
	char* next = orm_web_query_get(r, c"next")
	if (next != 0):
		orm_params* p = orm_params_new()
		orm_params_set(p, c"next", next)
		char* with = orm_params_url(action, p)
		orm_params_free(p)
		free(action)
		action = with
	orm_tpl_set(t, c"action", orm_tpl_str_take(t, action))
	if (adm_is_post(r)):
		char* username = orm_web_form_get(r, c"username")
		orm_tpl_set_str(t, c"username", username)
		User* u = authenticate(r.db, username, orm_web_form_get(r, c"password"))
		if (u != 0 && u.is_staff && u.is_active):
			int ok = orm_web_login(r, u)
			User_free(u)
			orm_tpl_ctx_free(t)
			if (ok == 0): return adm_error(r)
			return orm_web_redirect_take(adm_next(r, site))
		if (u != 0): User_free(u)
		orm_tpl_set_str(t, c"error", c"Please enter the correct username and password for a staff account. Note that both fields may be case-sensitive.")
	else if (r.user != 0):
		orm_tpl_set(t, c"denied", orm_tpl_bool(t, 1))
	return adm_render(r, site, c"login.html", t, 200)


ServerResponse* adm_logout_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	if (orm_web_logout(r) == 0): return adm_error(r)
	return orm_web_redirect_take(orm_admin_url(site, c"login/"))


# ---------------------------------------------------------------------------
# Changelist

# params without p and with key set to value (0 removes it), as a link
# to the changelist.
char* adm_list_link(char* base, orm_params* params, char* key, char* value):
	orm_params* c = orm_params_clone(params)
	orm_params_remove(c, c"p")
	if (key != 0): orm_params_set(c, key, value)
	char* url = orm_params_url(base, c)
	orm_params_free(c)
	return url


orm_tpl_value* adm_filter_choice(orm_tpl_ctx* t, char* label, char* url, int selected):
	orm_tpl_value* c = orm_tpl_map(t)
	orm_tpl_put_str(t, c, c"label", label)
	orm_tpl_put(c, c"url", orm_tpl_str_take(t, url))
	orm_tpl_put(c, c"selected", orm_tpl_bool(t, selected))
	return c


int adm_text_is(char* a, char* b):
	return a != 0 && b != 0 && strcmp(a, b) == 0


# The sidebar: per list_filter field, "All" and its choices. FK filters
# list the target's rows (one query each). Returns 0 with orm_db_error
# when a query failed.
orm_tpl_value* adm_filters(orm_web_request* r, orm_admin_site* site, orm_model_admin* ma, orm_tpl_ctx* t, char* base, orm_params* params):
	orm_tpl_value* out = orm_tpl_list(t)
	for char* name in ma.filters:
		orm_field_desc* fd = orm_model_field(ma.model, name)
		char* current = orm_params_get(params, name)
		orm_tpl_value* fv = orm_tpl_map(t)
		orm_tpl_put(fv, c"title", orm_tpl_str_take(t, orm_admin_path_label(name)))
		orm_tpl_value* choices = orm_tpl_list(t)
		orm_tpl_push(choices, adm_filter_choice(t, c"All", adm_list_link(base, params, name, 0), current == 0 || current[0] == 0))
		if (fd.kind == ORM_BOOL):
			orm_tpl_push(choices, adm_filter_choice(t, c"Yes", adm_list_link(base, params, name, c"1"), adm_text_is(current, c"1")))
			orm_tpl_push(choices, adm_filter_choice(t, c"No", adm_list_link(base, params, name, c"0"), adm_text_is(current, c"0")))
		else if (fd.kind == ORM_ENUM):
			for char* v in fd.enum_values:
				orm_tpl_push(choices, adm_filter_choice(t, v, adm_list_link(base, params, name, v), adm_text_is(current, v)))
		else:
			orm_model_desc* target = orm_field_target(fd)
			orm_field_desc* tpk = orm_model_pk(target)
			orm_result* res = orm_objects(r.db, target).order_by(tpk.name).all()
			if (res == 0): return 0
			for void* row in res.rows:
				char* id = itoa(orm_slot_get(row, tpk.offset))
				char* label = orm_admin_label(site, target, row)
				orm_tpl_push(choices, adm_filter_choice(t, label, adm_list_link(base, params, name, id), adm_text_is(current, id)))
				free(label)
				free(id)
			orm_result_free(res)
		orm_tpl_put(fv, c"choices", choices)
		orm_tpl_push(out, fv)
	return out


# Column headers with sort links: o=<path>, toggled to o=-<path> when the
# list is already sorted by it.
orm_tpl_value* adm_headers(orm_model_admin* ma, orm_tpl_ctx* t, char* base, orm_params* params):
	orm_tpl_value* out = orm_tpl_list(t)
	if (ma.columns.length == 0):
		orm_tpl_value* h = orm_tpl_map(t)
		orm_tpl_put(h, c"label", orm_tpl_str_take(t, orm_form_label(ma.verbose_name)))
		orm_tpl_push(out, h)
		return out
	char* o = orm_params_get(params, c"o")
	char* first = 0
	if (o != 0 && o[0] != 0):
		int comma = index_of(o, c",")
		if (comma >= 0): first = substring(o, 0, comma)
		else: first = strclone(o)
	for char* path in ma.columns:
		orm_tpl_value* h = orm_tpl_map(t)
		orm_tpl_put(h, c"label", orm_tpl_str_take(t, orm_admin_path_label(path)))
		char* desc = adm_cat(c"-", path)
		char* next = path
		if (adm_text_is(first, path)):
			orm_tpl_put_str(t, h, c"sorted", c"ascending")
			next = desc
		else if (adm_text_is(first, desc)): orm_tpl_put_str(t, h, c"sorted", c"descending")
		orm_tpl_put(h, c"url", orm_tpl_str_take(t, adm_list_link(base, params, c"o", next)))
		free(desc)
		orm_tpl_push(out, h)
	if (first != 0): free(first)
	return out


ServerResponse* adm_changelist_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	ServerResponse* g = orm_admin_gate(r, site)
	if (g != 0): return g
	orm_model_admin* ma = adm_model(r, site)
	if (ma == 0): return orm_web_not_found()
	if (orm_admin_can_view(r, ma) == 0): return adm_forbidden()
	orm_model_desc* m = ma.model
	orm_params* params = orm_web_query(r)
	char* base = orm_admin_model_url(ma, 0)
	orm_queryset* qs = orm_objects(r.db, m)
	for char* sp in ma.select_paths: qs = qs.select_related(sp)
	for char* spec in ma.order: qs = qs.order_by(spec)
	char* plural = orm_admin_plural_title(ma)
	char* title = adm_cat(c"Select ", ma.verbose_name)
	char* title2 = adm_cat(title, c" to change")
	free(title)
	orm_tpl_ctx* t = adm_context(r, site, title2)
	free(title2)
	adm_model_crumbs(t, ma, 0)
	free(plural)
	orm_tpl_set(t, c"list_url", orm_tpl_str(t, base))
	orm_tpl_set_str(t, c"verbose_name", ma.verbose_name)
	if (orm_admin_has_perm(r, ma, c"add")): orm_tpl_set(t, c"add_url", orm_tpl_str_take(t, orm_admin_model_url(ma, c"add/")))
	orm_tpl_set(t, c"has_search", orm_tpl_bool(t, ma.search.length > 0))
	char* query = orm_params_get(params, c"q")
	if (query == 0): query = c""
	orm_tpl_set_str(t, c"query", query)
	orm_tpl_value* hidden = orm_tpl_list(t)
	for orm_param* it in params.items:
		if (strcmp(it.key, c"q") == 0 || strcmp(it.key, c"p") == 0): continue
		orm_tpl_value* hv = orm_tpl_map(t)
		orm_tpl_put_str(t, hv, c"name", it.key)
		orm_tpl_put_str(t, hv, c"value", it.value)
		orm_tpl_push(hidden, hv)
	orm_tpl_set(t, c"hidden", hidden)
	orm_tpl_set(t, c"headers", adm_headers(ma, t, base, params))
	orm_tpl_value* filters = adm_filters(r, site, ma, t, base, params)
	if (filters == 0):
		orm_tpl_ctx_free(t)
		free(base)
		return adm_error(r)
	orm_tpl_set(t, c"filters", filters)
	json_value* errors = 0
	orm_queryset* fq = orm_filter_apply(ma.fs, qs, params, &errors)
	orm_tpl_value* rows = orm_tpl_list(t)
	int status = 200
	orm_page* pg = 0
	if (fq == 0):
		# Bad filter values: the messages and no rows (Django redirects to ?e=1).
		orm_tpl_value* msgs = orm_tpl_list(t)
		for char* key, json_value* l in errors.object_values:
			for j in range(json_array_length(l)):
				json_value* msg = json_array_get(l, j)
				string_builder* sb = string_new()
				string_append(sb, key)
				string_append(sb, c": ")
				if (msg.type == json_type_string()): string_append(sb, msg.string_value)
				orm_tpl_push(msgs, orm_tpl_str(t, sb.data))
				string_free(sb)
		json_free(errors)
		orm_tpl_set(t, c"errors", msgs)
		status = 400
	else:
		pg = orm_paginate(ma.pager, fq, params, base)
		if (pg.status == 500):
			orm_page_free(pg)
			orm_tpl_ctx_free(t)
			free(base)
			return adm_error(r)
		if (pg.status != 200):
			orm_page_free(pg)
			orm_tpl_ctx_free(t)
			free(base)
			return orm_web_not_found()
		for void* row in pg.result.rows:
			orm_tpl_value* rv = orm_tpl_map(t)
			int pk = orm_slot_get(row, orm_model_pk(m).offset)
			orm_tpl_put(rv, c"url", orm_tpl_str_take(t, orm_admin_object_url(ma, pk, 0)))
			orm_tpl_value* cells = orm_tpl_list(t)
			if (ma.columns.length == 0): orm_tpl_push(cells, orm_tpl_str_take(t, orm_admin_label(site, m, row)))
			for char* path in ma.columns:
				orm_tpl_push(cells, orm_tpl_str_take(t, orm_admin_path_text(site, m, row, path)))
			orm_tpl_put(rv, c"cells", cells)
			orm_tpl_push(rows, rv)
		int size = ma.page_size
		int pages = (pg.count + size - 1) / size
		if (pages < 1): pages = 1
		int page = 1
		char* ptext = orm_params_get(params, c"p")
		if (ptext != 0 && strcmp(ptext, c"last") == 0): page = pages
		else if (ptext != 0 && ptext[0] != 0): page = atoi(ptext)
		orm_tpl_set_int(t, c"page", page)
		orm_tpl_set_int(t, c"pages", pages)
		orm_tpl_set_int(t, c"count", pg.count)
		if (pg.count == 1): orm_tpl_set_str(t, c"count_name", ma.verbose_name)
		else: orm_tpl_set_str(t, c"count_name", ma.verbose_plural)
		if (pg.next != 0): orm_tpl_set_str(t, c"next", pg.next)
		if (pg.previous != 0): orm_tpl_set_str(t, c"previous", pg.previous)
	orm_tpl_set(t, c"rows", rows)
	ServerResponse* resp = adm_render(r, site, c"change_list.html", t, status)
	if (pg != 0): orm_page_free(pg)
	free(base)
	return resp


# ---------------------------------------------------------------------------
# Add, change, view

orm_tpl_value* adm_field_item(orm_tpl_ctx* t, char* name, char* label, char* value):
	orm_tpl_value* v = orm_tpl_map(t)
	orm_tpl_put_str(t, v, c"name", name)
	orm_tpl_put(v, c"label", orm_tpl_str_take(t, orm_form_label(label)))
	orm_tpl_put(v, c"value", orm_tpl_str_take(t, value))
	return v


# Tabs of an object page: Change / View, History (history models),
# Delete (with the delete permission).
orm_tpl_value* adm_tabs(orm_web_request* r, orm_model_admin* ma, orm_tpl_ctx* t, int pk, char* current):
	orm_tpl_value* tabs = orm_tpl_list(t)
	char* first = c"Change"
	if (orm_admin_has_perm(r, ma, c"change") == 0): first = c"View"
	char* names = c"change,history,delete"
	list[char*] actions = split(names, ',')
	for char* action in actions:
		if (strcmp(action, c"history") == 0 && ma.model.history == 0): continue
		if (strcmp(action, c"delete") == 0 && orm_admin_has_perm(r, ma, c"delete") == 0): continue
		orm_tpl_value* tab = orm_tpl_map(t)
		if (strcmp(action, c"change") == 0): orm_tpl_put_str(t, tab, c"label", first)
		else: orm_tpl_put(tab, c"label", orm_tpl_str_take(t, orm_form_label(action)))
		orm_tpl_put(tab, c"url", orm_tpl_str_take(t, orm_admin_object_url(ma, pk, action)))
		if (strcmp(action, current) == 0): orm_tpl_put_str(t, tab, c"cls", c"active")
		else: orm_tpl_put_str(t, tab, c"cls", action)
		orm_tpl_push(tabs, tab)
	adm_free_list(actions)
	return tabs


# Values of the form's fields in row (owned texts, 0 = NULL).
list[char*] adm_snapshot(orm_form* f, void* row):
	list[char*] out = new list[char*]
	for orm_form_field* ff in f.fields:
		if (row == 0): out.push(0)
		else: out.push(orm_rest_field_text(ff.fd, row))
	return out


void adm_snapshot_free(list[char*] l):
	for char* s in l:
		if (s != 0): free(s)
	l.free()


# Django's change message: "Changed title and price." (owned).
char* adm_change_message(orm_form* f, list[char*] before, void* row):
	list[char*] names = new list[char*]
	for i in range(f.fields.length):
		orm_form_field* ff = f.fields[i]
		char* now = orm_rest_field_text(ff.fd, row)
		char* was = before[i]
		int same = (now == 0 && was == 0) || (now != 0 && was != 0 && strcmp(now, was) == 0)
		if (now != 0): free(now)
		if (same == 0): names.push(ff.name)
	string_builder* s = string_new()
	if (names.length == 0): string_append(s, c"No fields changed.")
	else:
		string_append(s, c"Changed ")
		for j in range(names.length):
			if (j > 0 && j == names.length - 1): string_append(s, c" and ")
			else if (j > 0): string_append(s, c", ")
			string_append(s, names[j])
		string_append(s, c".")
	names.free()
	char* out = s.data
	free(cast(void*, s))
	return out


# The form over ma's serializer with <select> options for its FKs
# (labelled by the target's display field; one query each). 0 with
# orm_db_error when a query failed.
orm_form* adm_form(orm_web_request* r, orm_admin_site* site, orm_model_admin* ma, void* instance):
	orm_form* f = orm_form_from_serializer(ma.ser)
	orm_form_set_instance(f, instance)
	for orm_form_field* ff in f.fields:
		if (ff.fd.kind != ORM_FK): continue
		orm_model_desc* target = orm_field_target(ff.fd)
		orm_field_desc* lf = orm_admin_display_field(site, target)
		if (lf == 0): lf = orm_model_pk(target)
		if (orm_form_fk_choices(f, r.db, ff.name, lf.name) == 0):
			orm_form_free(f)
			return 0
	return f


# Read-only fields of the page: ma's readonly_fields, or every column
# field when the user may only view.
orm_tpl_value* adm_readonly(orm_admin_site* site, orm_model_admin* ma, orm_tpl_ctx* t, void* row, int all):
	orm_tpl_value* out = orm_tpl_list(t)
	if (all):
		for orm_field_desc* fd in ma.model.fields:
			if (orm_field_has_column(fd) == 0 || (fd.flags & ORM_F_DEPRECATED) != 0): continue
			orm_tpl_push(out, adm_field_item(t, fd.name, fd.name, orm_admin_field_text(site, fd, row)))
		return out
	for char* name in ma.readonly:
		orm_field_desc* rf = orm_model_field(ma.model, name)
		orm_tpl_push(out, adm_field_item(t, rf.name, rf.name, orm_admin_field_text(site, rf, row)))
	return out


# GET shows the form (or, without the change permission, the detail
# page); POST validates and saves under a history context, then
# redirects to the changelist (or back here with _continue).
ServerResponse* adm_form_page(orm_web_request* r, orm_admin_site* site, orm_model_admin* ma, void* instance):
	orm_model_desc* m = ma.model
	int pk = 0
	if (instance != 0): pk = orm_slot_get(instance, orm_model_pk(m).offset)
	int can_write = 0
	if (instance == 0): can_write = orm_admin_has_perm(r, ma, c"add")
	else: can_write = orm_admin_has_perm(r, ma, c"change")
	if (can_write == 0):
		if (instance == 0 || orm_admin_has_perm(r, ma, c"view") == 0 || adm_is_post(r)): return adm_forbidden()
	orm_form* f = 0
	if (can_write):
		f = adm_form(r, site, ma, instance)
		if (f == 0): return adm_error(r)
	if (f != 0 && adm_is_post(r)):
		orm_form_bind_request(f, r)
		list[char*] before = adm_snapshot(f, instance)
		if (orm_form_is_valid(f, r.db)):
			char* reason = 0
			if (instance == 0): reason = strclone(c"Added.")
			else: reason = adm_change_message(f, before, instance)
			void* row = 0
			if (adm_begin_write(r, site, reason)):
				row = orm_form_save(f)
				if (adm_end_write(r) == 0 && row != 0):
					if (instance == 0): orm_row_free(m, row)
					row = 0
			free(reason)
			if (row != 0):
				int saved_pk = orm_slot_get(row, orm_model_pk(m).offset)
				if (instance == 0): orm_row_free(m, row)
				adm_snapshot_free(before)
				int again = orm_web_form_get(r, c"_continue") != 0
				orm_form_free(f)
				if (again): return orm_web_redirect_take(orm_admin_object_url(ma, saved_pk, 0))
				return orm_web_redirect_take(orm_admin_model_url(ma, 0))
			if (f.status == 500 && f.errors == 0):
				adm_snapshot_free(before)
				orm_form_free(f)
				return adm_error(r)
		adm_snapshot_free(before)
	char* label = 0
	char* title = 0
	if (instance == 0): title = adm_cat(c"Add ", ma.verbose_name)
	else:
		label = orm_admin_label(site, m, instance)
		if (can_write): title = adm_cat(c"Change ", ma.verbose_name)
		else: title = adm_cat(c"View ", ma.verbose_name)
	orm_tpl_ctx* t = adm_context(r, site, title)
	free(title)
	if (label != 0): adm_model_crumbs(t, ma, label)
	else: adm_model_crumbs(t, ma, c"Add")
	if (label != 0):
		orm_tpl_set_str(t, c"object", label)
		free(label)
	orm_tpl_set_str(t, c"model_name", ma.model_name)
	if (instance != 0): orm_tpl_set(t, c"tabs", adm_tabs(r, ma, t, pk, c"change"))
	orm_tpl_set(t, c"readonly", adm_readonly(site, ma, t, instance, can_write == 0))
	if (f != 0):
		orm_tpl_set(t, c"form", orm_form_tpl(t, f, orm_web_csrf_token(r)))
		orm_tpl_set_str(t, c"action", r.path)
	ServerResponse* resp = adm_render(r, site, c"change_form.html", t, 200)
	if (f != 0): orm_form_free(f)
	return resp


ServerResponse* adm_add_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	ServerResponse* g = orm_admin_gate(r, site)
	if (g != 0): return g
	orm_model_admin* ma = adm_model(r, site)
	if (ma == 0): return orm_web_not_found()
	if (orm_admin_has_perm(r, ma, c"add") == 0): return adm_forbidden()
	return adm_form_page(r, site, ma, 0)


ServerResponse* adm_change_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	ServerResponse* g = orm_admin_gate(r, site)
	if (g != 0): return g
	orm_model_admin* ma = adm_model(r, site)
	if (ma == 0): return orm_web_not_found()
	if (orm_admin_can_view(r, ma) == 0): return adm_forbidden()
	orm_result* res = adm_get_object(r, ma, orm_web_param_int(r, c"pk", 0))
	if (res == 0): return adm_missing(r)
	ServerResponse* resp = adm_form_page(r, site, ma, res.rows[0])
	orm_result_free(res)
	return resp


# ---------------------------------------------------------------------------
# Delete

char* adm_model_title(orm_admin_site* site, orm_model_desc* m):
	orm_model_admin* ma = orm_admin_for_model(site, m)
	if (ma != 0): return orm_form_label(ma.verbose_name)
	char* v = auth_verbose_name(m.name)
	char* out = orm_form_label(v)
	free(v)
	return out


void adm_tree_html(orm_web_request* r, orm_admin_site* site, string_builder* s, adm_node* n):
	char* model = adm_model_title(site, n.model)
	string_append(s, c"<li>")
	orm_html_append_escaped(s, model)
	string_append(s, c": ")
	free(model)
	orm_model_admin* ma = orm_admin_for_model(site, n.model)
	if (ma != 0 && orm_admin_can_view(r, ma)):
		char* url = orm_admin_object_url(ma, n.pk, 0)
		string_append(s, c"<a href=\"")
		orm_html_append_escaped(s, url)
		string_append(s, c"\">")
		orm_html_append_escaped(s, n.label)
		string_append(s, c"</a>")
		free(url)
	else: orm_html_append_escaped(s, n.label)
	if (n.children.length > 0):
		string_append(s, c"<ul>")
		for adm_node* c in n.children: adm_tree_html(r, site, s, c)
		string_append(s, c"</ul>")
	string_append(s, c"</li>")


ServerResponse* adm_delete_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	ServerResponse* g = orm_admin_gate(r, site)
	if (g != 0): return g
	orm_model_admin* ma = adm_model(r, site)
	if (ma == 0): return orm_web_not_found()
	if (orm_admin_has_perm(r, ma, c"delete") == 0): return adm_forbidden()
	orm_model_desc* m = ma.model
	int pk = orm_web_param_int(r, c"pk", 0)
	orm_result* res = adm_get_object(r, ma, pk)
	if (res == 0): return adm_missing(r)
	void* row = res.rows[0]
	adm_cascade* c = orm_admin_collect(r.db, site, m, row)
	if (c.failed):
		adm_cascade_free(c)
		orm_result_free(res)
		return adm_error(r)
	# Django: the delete permission on every registered model in the cascade.
	list[char*] lacking = new list[char*]
	for char* name in c.order:
		orm_model_admin* other = orm_admin_for_model(site, orm_model_lookup(name))
		if (other != 0 && orm_admin_has_perm(r, other, c"delete") == 0): lacking.push(other.verbose_name)
	if (adm_is_post(r)):
		if (c.protected.length > 0 || lacking.length > 0):
			lacking.free()
			adm_cascade_free(c)
			orm_result_free(res)
			return adm_forbidden()
		int ok = adm_begin_write(r, site, c"Deleted.")
		if (ok): ok = orm_delete_row(r.db, m, row) >= 0
		if (ok): ok = adm_end_write(r)
		lacking.free()
		adm_cascade_free(c)
		orm_result_free(res)
		if (ok == 0): return adm_error(r)
		return orm_web_redirect_take(orm_admin_model_url(ma, 0))
	char* label = orm_admin_label(site, m, row)
	orm_tpl_ctx* t = adm_context(r, site, c"Are you sure?")
	adm_model_crumbs(t, ma, label)
	orm_tpl_set_str(t, c"object", label)
	free(label)
	orm_tpl_set_str(t, c"verbose_name", ma.verbose_name)
	orm_tpl_set(t, c"tabs", adm_tabs(r, ma, t, pk, c"delete"))
	orm_tpl_value* prot = orm_tpl_list(t)
	for adm_node* p in c.protected:
		char* pm = adm_model_title(site, p.model)
		orm_tpl_push(prot, orm_tpl_str_take(t, adm_cat3(pm, c": ", p.label)))
		free(pm)
	orm_tpl_set(t, c"protected", prot)
	orm_tpl_value* lack = orm_tpl_list(t)
	for char* ln in lacking: orm_tpl_push(lack, orm_tpl_str(t, ln))
	orm_tpl_set(t, c"perms_lacking", lack)
	lacking.free()
	orm_tpl_value* summary = orm_tpl_list(t)
	for char* mn in c.order:
		orm_model_desc* sm = orm_model_lookup(mn)
		orm_model_admin* sma = orm_admin_for_model(site, sm)
		char* plural = 0
		if (sma != 0): plural = orm_admin_plural_title(sma)
		else:
			char* v = auth_verbose_name(sm.name)
			char* vs = adm_cat(v, c"s")
			plural = orm_form_label(vs)
			free(v)
			free(vs)
		orm_tpl_value* sv = orm_tpl_map(t)
		orm_tpl_put(sv, c"label", orm_tpl_str_take(t, plural))
		orm_tpl_put(sv, c"count", orm_tpl_int(t, c.counts[mn]))
		orm_tpl_push(summary, sv)
	for adm_link_count* lc in c.links:
		orm_tpl_value* lv = orm_tpl_map(t)
		orm_tpl_put(lv, c"label", orm_tpl_str_take(t, adm_cat(lc.name, c"s")))
		orm_tpl_put(lv, c"count", orm_tpl_int(t, lc.count))
		orm_tpl_push(summary, lv)
	orm_tpl_set(t, c"summary", summary)
	string_builder* tree = string_new()
	string_append(tree, c"<ul id=\"deleted-objects\">")
	adm_tree_html(r, site, tree, c.root)
	string_append(tree, c"</ul>")
	orm_tpl_set(t, c"tree", orm_tpl_safe(t, tree.data))
	string_free(tree)
	orm_tpl_set_str(t, c"action", r.path)
	orm_tpl_set(t, c"cancel_url", orm_tpl_str_take(t, orm_admin_object_url(ma, pk, 0)))
	adm_cascade_free(c)
	ServerResponse* resp = adm_render(r, site, c"delete_confirmation.html", t, 200)
	orm_result_free(res)
	return resp


# ---------------------------------------------------------------------------
# History

char* adm_history_action(int type):
	if (type == ORM_HISTORY_INSERT): return c"Added"
	if (type == ORM_HISTORY_DELETE): return c"Deleted"
	return c"Changed"


# The history of object <pk> (newest first), or 0 with the response to
# send in *resp (404 for models without history or unknown objects).
orm_result* adm_history_rows(orm_web_request* r, orm_admin_site* site, orm_model_admin* ma, ServerResponse** resp):
	resp[0] = 0
	if (ma.model.history == 0):
		resp[0] = orm_web_not_found()
		return 0
	orm_result* hr = orm_history_for(r.db, ma.model, orm_web_param_int(r, c"pk", 0))
	if (hr == 0):
		resp[0] = adm_error(r)
		return 0
	if (hr.rows.length == 0):
		orm_result_free(hr)
		resp[0] = orm_web_not_found()
		return 0
	return hr


# Usernames of the entries' users (one query; none when no entry has one).
map[int, char*] adm_history_users(orm_web_request* r, orm_result* hr, orm_result** users_out):
	map[int, char*] names = new map[int, char*]
	users_out[0] = 0
	list[char*] ids = new list[char*]
	for orm_history_entry* e in orm_history_entries(hr):
		if (e.user_isnull == 0 && e.user_id > 0): ids.push(itoa(e.user_id))
	if (ids.length > 0):
		orm_result* ur = User_objects(r.db).filter(q_in(c"id", ids)).all()
		if (ur != 0):
			for User* u in User_rows(ur): names[u.id] = u.username
		users_out[0] = ur
	adm_free_list(ids)
	return names


ServerResponse* adm_gate_history(orm_web_request* r, orm_admin_site* site, orm_model_admin* ma):
	ServerResponse* g = orm_admin_gate(r, site)
	if (g != 0): return g
	if (ma == 0): return orm_web_not_found()
	if (orm_admin_can_view(r, ma) == 0): return adm_forbidden()
	return 0


ServerResponse* adm_history_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	orm_model_admin* ma = adm_model(r, site)
	ServerResponse* g = adm_gate_history(r, site, ma)
	if (g != 0): return g
	ServerResponse* fail = 0
	orm_result* hr = adm_history_rows(r, site, ma, &fail)
	if (hr == 0): return fail
	int pk = orm_web_param_int(r, c"pk", 0)
	orm_result* ur = 0
	map[int, char*] users = adm_history_users(r, hr, &ur)
	list[orm_history_entry*] entries = orm_history_entries(hr)
	char* label = orm_admin_label(site, ma.model, entries[0].row)
	char* title = adm_cat(c"Change history: ", label)
	orm_tpl_ctx* t = adm_context(r, site, title)
	free(title)
	adm_model_crumbs(t, ma, label)
	orm_tpl_set_str(t, c"object", label)
	free(label)
	orm_tpl_set(t, c"tabs", adm_tabs(r, ma, t, pk, c"history"))
	orm_tpl_value* items = orm_tpl_list(t)
	for orm_history_entry* e in entries:
		orm_tpl_value* ev = orm_tpl_map(t)
		orm_tpl_put(ev, c"id", orm_tpl_int(t, e.history_id))
		char* hid = itoa(e.history_id)
		char* base = orm_admin_object_url(ma, pk, c"history")
		char* url = adm_cat3(base, hid, c"/")
		free(base)
		free(hid)
		orm_tpl_put(ev, c"url", orm_tpl_str_take(t, url))
		orm_tpl_put_str(t, ev, c"date", e.date)
		orm_tpl_put_str(t, ev, c"action", adm_history_action(e.type))
		if (e.user_id in users): orm_tpl_put_str(t, ev, c"user", users[e.user_id])
		else: orm_tpl_put_str(t, ev, c"user", c"-")
		if (e.reason != 0): orm_tpl_put_str(t, ev, c"reason", e.reason)
		orm_tpl_push(items, ev)
	orm_tpl_set(t, c"entries", items)
	ServerResponse* resp = adm_render(r, site, c"object_history.html", t, 200)
	map_free[int, char*](users)
	if (ur != 0): orm_result_free(ur)
	orm_result_free(hr)
	return resp


# One version: its values, the diff from the version before it, and a
# revert button (POST) for users with the change permission (plus add
# when the object is currently deleted).
ServerResponse* adm_version_view(orm_web_request* r, void* ctx):
	orm_admin_site* site = adm_site(ctx)
	orm_model_admin* ma = adm_model(r, site)
	ServerResponse* g = adm_gate_history(r, site, ma)
	if (g != 0): return g
	ServerResponse* fail = 0
	orm_result* hr = adm_history_rows(r, site, ma, &fail)
	if (hr == 0): return fail
	int pk = orm_web_param_int(r, c"pk", 0)
	int hid = orm_web_param_int(r, c"hid", 0)
	list[orm_history_entry*] entries = orm_history_entries(hr)
	int at = -1
	for i in range(entries.length):
		if (entries[i].history_id == hid): at = i
	if (at < 0):
		orm_result_free(hr)
		return orm_web_not_found()
	orm_history_entry* e = entries[at]
	orm_history_entry* prev = 0
	if (at + 1 < entries.length): prev = entries[at + 1]
	int gone = entries[0].type == ORM_HISTORY_DELETE
	int can_revert = orm_admin_has_perm(r, ma, c"change") && (gone == 0 || orm_admin_has_perm(r, ma, c"add"))
	if (adm_is_post(r)):
		if (can_revert == 0):
			orm_result_free(hr)
			return adm_forbidden()
		char* n = itoa(hid)
		char* reason = adm_cat3(c"Reverted to version ", n, c".")
		free(n)
		int ok = adm_begin_write(r, site, reason)
		free(reason)
		if (ok): ok = orm_history_revert(r.db, e)
		if (ok): ok = adm_end_write(r)
		orm_result_free(hr)
		if (ok == 0): return adm_error(r)
		return orm_web_redirect_take(orm_admin_object_url(ma, pk, c"history"))
	char* label = orm_admin_label(site, ma.model, e.row)
	char* num = itoa(hid)
	char* title = adm_cat3(c"Version ", num, c": ")
	char* title2 = adm_cat(title, label)
	free(title)
	orm_tpl_ctx* t = adm_context(r, site, title2)
	free(title2)
	adm_model_crumbs(t, ma, label)
	orm_tpl_set_str(t, c"object", label)
	free(label)
	orm_tpl_set(t, c"version", orm_tpl_str_take(t, num))
	orm_tpl_set(t, c"tabs", adm_tabs(r, ma, t, pk, c"history"))
	orm_tpl_set_str(t, c"date", e.date)
	orm_tpl_set_str(t, c"action_name", adm_history_action(e.type))
	if (e.reason != 0): orm_tpl_set_str(t, c"reason", e.reason)
	orm_tpl_value* values = orm_tpl_list(t)
	for orm_field_desc* fd in ma.model.fields:
		if (orm_history_tracks(fd) == 0): continue
		orm_tpl_push(values, adm_field_item(t, fd.name, fd.name, orm_admin_field_text(site, fd, e.row)))
	orm_tpl_set(t, c"values", values)
	list[orm_history_change*] diff = orm_history_diff(prev, e)
	orm_tpl_value* changes = orm_tpl_list(t)
	for orm_history_change* ch in diff:
		orm_tpl_value* cv = orm_tpl_map(t)
		orm_tpl_put(cv, c"label", orm_tpl_str_take(t, orm_form_label(ch.field)))
		if (ch.old_value != 0): orm_tpl_put_str(t, cv, c"old", ch.old_value)
		else: orm_tpl_put_str(t, cv, c"old", c"-")
		if (ch.new_value != 0): orm_tpl_put_str(t, cv, c"new", ch.new_value)
		else: orm_tpl_put_str(t, cv, c"new", c"-")
		orm_tpl_push(changes, cv)
	orm_history_diff_free(diff)
	orm_tpl_set(t, c"changes", changes)
	orm_tpl_set(t, c"can_revert", orm_tpl_bool(t, can_revert))
	orm_tpl_set_str(t, c"action", r.path)
	orm_tpl_set(t, c"history_url", orm_tpl_str_take(t, orm_admin_object_url(ma, pk, c"history")))
	ServerResponse* resp = adm_render(r, site, c"object_version.html", t, 200)
	orm_result_free(hr)
	return resp


# ---------------------------------------------------------------------------
# Mounting

orm_route* adm_mount_fail(orm_router* rt, char* why):
	orm_router_fail(rt, why, 0)
	return 0


# Checks every registration and includes the admin's routes in rt under
# prefix (a trailing '/' is added). Configuration errors are reported by
# orm_admin_site_error(site) and orm_router_error(rt). Returns the
# include route.
orm_route* orm_admin_mount(orm_admin_site* site, orm_router* rt, char* prefix):
	if (site.router != 0):
		adm_site_fail(site, c"admin: the site is already mounted", 0, 0)
		return adm_mount_fail(rt, site.error)
	free(site.prefix)
	int n = strlen(prefix)
	if (n == 0 || prefix[n - 1] != '/'): site.prefix = adm_cat(prefix, c"/")
	else: site.prefix = strclone(prefix)
	for orm_model_admin* ma in site.models: adm_check_model(site, ma)
	orm_router* a = orm_router_new()
	void* s = cast(void*, site)
	orm_router_get(a, c"/", adm_index_view, s, c"index")
	orm_router_add(a, c"GET,POST", c"/login/", adm_login_view, s, c"login")
	orm_router_post(a, c"/logout/", adm_logout_view, s, c"logout")
	orm_router_get(a, c"/<slug:app>/<slug:model>/", adm_changelist_view, s, c"changelist")
	orm_router_add(a, c"GET,POST", c"/<slug:app>/<slug:model>/add/", adm_add_view, s, c"add")
	orm_router_add(a, c"GET,POST", c"/<slug:app>/<slug:model>/<int:pk>/change/", adm_change_view, s, c"change")
	orm_router_add(a, c"GET,POST", c"/<slug:app>/<slug:model>/<int:pk>/delete/", adm_delete_view, s, c"delete")
	orm_router_get(a, c"/<slug:app>/<slug:model>/<int:pk>/history/", adm_history_view, s, c"history")
	orm_router_add(a, c"GET,POST", c"/<slug:app>/<slug:model>/<int:pk>/history/<int:hid>/", adm_version_view, s, c"version")
	site.router = a
	if (site.error != 0): orm_router_fail(rt, site.error, 0)
	return orm_router_include(rt, site.prefix, a, c"admin")
