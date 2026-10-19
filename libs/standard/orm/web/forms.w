# w-orm HTML forms (unit U4.3, docs/projects/orm/u4_3.md): Django
# ModelForm over a U3.4 serializer, so a form and the REST layer accept
# the same input and report the same messages.
#
#   orm_form* f = orm_form_new(Book_desc())          # or orm_form_from_serializer(ser)
#   orm_form_fk_choices(f, db, c"author", c"name")   # <select> for an FK
#   orm_form_bind_request(f, request)                # urlencoded or multipart body
#   if (orm_form_is_valid(f, request.db)):
#       Book* b = cast(Book*, orm_form_save(f))       # 0 with errors on a constraint violation
#   html = orm_form_render(f, orm_web_csrf_token(request))
#
# Fields are the serializer's writable model fields in order. Binding
# turns form text into the serializer's JSON input: "" is null for
# nullable fields, absent for required non-text fields (so the message is
# "This field is required."), and kept as "" for text fields (so it is
# "This field may not be blank."); checkboxes are false when absent.
# Validation is orm_serializer_validate_json; orm_form_save writes through
# orm_validation_save inside a savepoint, so an integrity error on
# PostgreSQL does not abort the request's transaction, and maps it to
# field errors exactly as the REST layer does.
import libs.standard.orm.web.router
import libs.standard.orm.web.templates
import libs.standard.orm.rest.serializer
import libs.standard.orm.atomic


struct orm_form_field:
	char* name                 # input name (the serializer key)
	char* label                # "Published at"
	orm_ser_field* sf
	orm_field_desc* fd
	char* widget               # text, textarea, number, checkbox, select
	list[char*] choice_values  # select options (owned)
	list[char*] choice_labels
	int required


struct orm_form:
	orm_serializer* ser
	int owns_ser
	orm_model_desc* model
	list[orm_form_field*] fields
	orm_params* data           # bound data (owned copy), 0 when unbound
	void* instance             # row being edited (borrowed), or 0
	map[char*, char*] initial  # owned initial values for unbound forms
	json_value* input          # JSON handed to the serializer (owned)
	orm_validation* v
	json_value* errors         # owned copy of the last errors, or 0
	int status                 # 0, 400 or 500 after validation / save
	int saved


char* orm_form_label(char* name):
	char* out = strclone(name)
	int i = 0
	while (out[i] != 0):
		if (out[i] == '_'): out[i] = ' '
		i = i + 1
	if (out[0] != 0): out[0] = toupper(out[0])
	return out


char* orm_form_widget_for(orm_field_desc* fd):
	int k = fd.kind
	if (k == ORM_BOOL): return c"checkbox"
	if (k == ORM_ENUM): return c"select"
	if (k == ORM_INT || k == ORM_BIGINT || k == ORM_FK || k == ORM_DECIMAL || k == ORM_FLOAT): return c"number"
	if (k == ORM_JSON): return c"textarea"
	if (k == ORM_TEXT && fd.max_length <= 0): return c"textarea"
	return c"text"


orm_form* orm_form_from_serializer(orm_serializer* ser):
	orm_form* f = new orm_form()
	f.ser = ser
	f.model = ser.model
	f.fields = new list[orm_form_field*]
	f.initial = new map[char*, char*]
	for orm_ser_field* sf in ser.fields:
		if (sf.kind != ORM_SF_FIELD || sf.read_only): continue
		orm_form_field* ff = new orm_form_field()
		ff.name = sf.name
		ff.label = orm_form_label(sf.name)
		ff.sf = sf
		ff.fd = sf.field
		ff.widget = orm_form_widget_for(sf.field)
		ff.choice_values = new list[char*]
		ff.choice_labels = new list[char*]
		ff.required = orm_ser_field_required(sf) && sf.field.kind != ORM_BOOL
		if (sf.field.kind == ORM_ENUM):
			for char* choice in sf.field.enum_values:
				ff.choice_values.push(strclone(choice))
				ff.choice_labels.push(strclone(choice))
		f.fields.push(ff)
	return f


# A form over every writable field of m (its own serializer).
orm_form* orm_form_new(orm_model_desc* m):
	orm_form* f = orm_form_from_serializer(orm_serializer_new(m))
	f.owns_ser = 1
	return f


void orm_form_reset(orm_form* f):
	if (f.v != 0): orm_validation_free(f.v)
	f.v = 0
	if (f.input != 0): json_free(f.input)
	f.input = 0
	if (f.errors != 0): json_free(f.errors)
	f.errors = 0
	f.status = 0
	f.saved = 0


void orm_form_free(orm_form* f):
	if (f == 0): return
	orm_form_reset(f)
	for orm_form_field* ff in f.fields:
		free(ff.label)
		for char* a in ff.choice_values: free(a)
		for char* b in ff.choice_labels: free(b)
		ff.choice_values.free()
		ff.choice_labels.free()
		free(cast(void*, ff))
	f.fields.free()
	for char* k, char* v in f.initial: free(v)
	map_free[char*, char*](f.initial)
	orm_params_free(f.data)
	if (f.owns_ser): orm_serializer_free(f.ser)
	free(cast(void*, f))


orm_form_field* orm_form_field_get(orm_form* f, char* name):
	for orm_form_field* ff in f.fields:
		if (strcmp(ff.name, name) == 0): return ff
	return 0


# Edits row: unbound forms show its values; validation applies onto it.
void orm_form_set_instance(orm_form* f, void* row):
	f.instance = row


# Initial value of an unbound field (copied).
void orm_form_set_initial(orm_form* f, char* name, char* value):
	if (name in f.initial):
		free(f.initial[name])
		f.initial.remove(name)
	if (value != 0): f.initial[name] = strclone(value)


# Replaces a field's <select> options (values and labels copied).
void orm_form_choices(orm_form* f, char* name, list[char*] values, list[char*] labels):
	orm_form_field* ff = orm_form_field_get(f, name)
	if (ff == 0): return
	for char* a in ff.choice_values: free(a)
	for char* b in ff.choice_labels: free(b)
	ff.choice_values.free()
	ff.choice_labels.free()
	ff.choice_values = new list[char*]
	ff.choice_labels = new list[char*]
	for i in range(values.length):
		ff.choice_values.push(strclone(values[i]))
		if (labels != 0 && i < labels.length): ff.choice_labels.push(strclone(labels[i]))
		else: ff.choice_labels.push(strclone(values[i]))
	ff.widget = c"select"


# Options for FK field `name` from every row of its target, labelled by
# label_field (pk order; one query). Returns 1, or 0 with orm_db_error.
int orm_form_fk_choices(orm_form* f, orm_db* db, char* name, char* label_field):
	orm_form_field* ff = orm_form_field_get(f, name)
	if (ff == 0 || ff.fd.kind != ORM_FK): return orm_db_set_error(db, c"forms: not an FK field")
	orm_model_desc* target = orm_field_target(ff.fd)
	orm_field_desc* pk = orm_model_pk(target)
	orm_field_desc* lf = orm_model_field(target, label_field)
	if (lf == 0): lf = pk
	orm_result* r = orm_objects(db, target).order_by(pk.name).all()
	if (r == 0): return 0
	list[char*] values = new list[char*]
	list[char*] labels = new list[char*]
	for void* row in r.rows:
		values.push(orm_rest_field_text(pk, row))
		char* label = orm_rest_field_text(lf, row)
		if (label == 0): label = strclone(c"")
		labels.push(label)
	orm_form_choices(f, name, values, labels)
	for char* a in values: free(a)
	for char* b in labels: free(b)
	values.free()
	labels.free()
	orm_result_free(r)
	return 1


# Binds submitted data (copied).
void orm_form_bind(orm_form* f, orm_params* data):
	orm_form_reset(f)
	orm_params_free(f.data)
	f.data = orm_params_clone(data)


void orm_form_bind_request(orm_form* f, orm_web_request* r):
	orm_form_bind(f, orm_web_form(r))


int orm_form_is_bound(orm_form* f):
	return f.data != 0


int orm_form_checkbox_value(char* v, int* out):
	if (v == 0): return 0
	char* lower = strclone(v)
	int i = 0
	while (lower[i] != 0):
		lower[i] = tolower(lower[i])
		i = i + 1
	int ok = 1
	if (strcmp(lower, c"on") == 0 || strcmp(lower, c"true") == 0 || strcmp(lower, c"1") == 0 || strcmp(lower, c"yes") == 0): out[0] = 1
	else if (strcmp(lower, c"off") == 0 || strcmp(lower, c"false") == 0 || strcmp(lower, c"0") == 0 || strcmp(lower, c"no") == 0 || lower[0] == 0): out[0] = 0
	else: ok = 0
	free(lower)
	return ok


# The serializer input for the bound data (see the module comment).
json_value* orm_form_input(orm_form* f):
	json_value* o = json_object()
	for orm_form_field* ff in f.fields:
		char* v = orm_params_get(f.data, ff.name)
		orm_field_desc* fd = ff.fd
		if (fd.kind == ORM_BOOL):
			int b = 0
			if (v == 0): json_object_set(o, ff.name, json_bool(0))
			else if (orm_form_checkbox_value(v, &b)): json_object_set(o, ff.name, json_bool(b))
			else: json_object_set(o, ff.name, json_string(v))
			continue
		if (v == 0): continue
		if (v[0] == 0):
			if ((fd.flags & ORM_F_NULL) != 0): json_object_set(o, ff.name, json_null())
			else if (fd.kind == ORM_TEXT): json_object_set(o, ff.name, json_string(v))
			continue
		json_object_set(o, ff.name, json_string(v))
	return o


# Validates the bound data with the serializer (an unbound form is
# invalid). FK values cost one existence query each, as in the REST layer.
int orm_form_is_valid(orm_form* f, orm_db* db):
	if (f.data == 0): return 0
	if (f.v != 0): return orm_validation_ok(f.v)
	f.input = orm_form_input(f)
	f.v = orm_serializer_validate_json(f.ser, db, f.input, f.instance, 0)
	f.status = f.v.status
	if (orm_validation_ok(f.v)): return 1
	f.errors = json_clone(f.v.errors)
	return 0


# Saves a valid form (inside a savepoint / transaction). Returns the row:
# the instance, or a new heap row the caller frees with orm_row_free.
# 0 when invalid or when the database refused it (errors mapped to
# fields, status 400; other failures status 500).
void* orm_form_save(orm_form* f):
	if (f.v == 0 || orm_validation_ok(f.v) == 0): return 0
	orm_db* db = f.v.db
	orm_atomic_block* b = orm_atomic_begin(db)
	if (b == 0):
		f.status = 500
		if (f.errors != 0): json_free(f.errors)
		f.errors = orm_rest_detail(orm_db_error(db))
		return 0
	int ok = orm_validation_save(f.v)
	if (ok): ok = orm_atomic_commit(db, b)
	else: orm_atomic_rollback(db, b)
	if (ok == 0):
		if (f.errors != 0): json_free(f.errors)
		if (orm_validation_ok(f.v)):
			f.status = 500
			f.errors = orm_rest_detail(orm_db_error(db))
		else:
			f.status = f.v.status
			f.errors = json_clone(f.v.errors)
		return 0
	f.saved = 1
	if (f.instance != 0): return f.instance
	return orm_validation_take_row(f.v)


# The errors object ({"field": ["message"], "non_field_errors": [...]}
# or {"detail": ...}), or 0 when there are none. Borrowed.
json_value* orm_form_errors(orm_form* f):
	return f.errors


# Owned JSON text of the errors ("{}" when none).
char* orm_form_errors_text(orm_form* f):
	if (f.errors == 0): return strclone(c"{}")
	return json_stringify(f.errors)


# ---------------------------------------------------------------------------
# Rendering

# The value a field shows (owned, 0 = empty): bound data, else the
# instance's value, else the initial value, else a literal SQL default.
char* orm_form_value(orm_form* f, orm_form_field* ff):
	if (f.data != 0):
		char* v = orm_params_get(f.data, ff.name)
		if (v == 0): return 0
		return strclone(v)
	if (f.instance != 0): return orm_rest_field_text(ff.fd, f.instance)
	if (ff.name in f.initial): return strclone(f.initial[ff.name])
	char* d = ff.fd.default_sql
	if (d != 0 && strlen(d) >= 2 && d[0] == 39 && d[strlen(d) - 1] == 39): return substring(d, 1, strlen(d) - 1)
	return 0


void orm_form_attr(string_builder* s, char* name, char* value):
	string_append_char(s, ' ')
	string_append(s, name)
	string_append(s, c"=\"")
	orm_html_append_escaped(s, value)
	string_append_char(s, '"')


char* orm_form_step(int places):
	if (places <= 0): return strclone(c"1")
	string_builder* s = string_new()
	string_append(s, c"0.")
	for i in range(places - 1): string_append_char(s, '0')
	string_append_char(s, '1')
	char* out = s.data
	free(s)
	return out


# The field's widget HTML (owned).
char* orm_form_widget_html(orm_form* f, orm_form_field* ff):
	string_builder* s = string_new()
	char* value = orm_form_value(f, ff)
	char* id = orm_rest_concat(c"id_", ff.name)
	char* w = ff.widget
	if (strcmp(w, c"select") == 0):
		string_append(s, c"<select")
		orm_form_attr(s, c"name", ff.name)
		orm_form_attr(s, c"id", id)
		if (ff.required): string_append(s, c" required")
		string_append(s, c">")
		if (ff.required == 0 || value == 0 || ff.fd.kind == ORM_FK):
			string_append(s, c"<option value=\"\">---------</option>")
		for i in range(ff.choice_values.length):
			string_append(s, c"<option")
			orm_form_attr(s, c"value", ff.choice_values[i])
			if (value != 0 && strcmp(value, ff.choice_values[i]) == 0): string_append(s, c" selected")
			string_append(s, c">")
			orm_html_append_escaped(s, ff.choice_labels[i])
			string_append(s, c"</option>")
		string_append(s, c"</select>")
	else if (strcmp(w, c"textarea") == 0):
		string_append(s, c"<textarea")
		orm_form_attr(s, c"name", ff.name)
		orm_form_attr(s, c"id", id)
		if (ff.required): string_append(s, c" required")
		string_append(s, c">")
		if (value != 0): orm_html_append_escaped(s, value)
		string_append(s, c"</textarea>")
	else if (strcmp(w, c"checkbox") == 0):
		string_append(s, c"<input type=\"checkbox\"")
		orm_form_attr(s, c"name", ff.name)
		orm_form_attr(s, c"id", id)
		int on = 0
		if (value != 0 && orm_form_checkbox_value(value, &on) && on): string_append(s, c" checked")
		string_append(s, c">")
	else:
		string_append(s, c"<input")
		orm_form_attr(s, c"type", w)
		orm_form_attr(s, c"name", ff.name)
		orm_form_attr(s, c"id", id)
		if (ff.fd.kind == ORM_DECIMAL):
			char* step = orm_form_step(ff.fd.places)
			orm_form_attr(s, c"step", step)
			free(step)
		if (ff.fd.max_length > 0 && strcmp(w, c"text") == 0):
			char* ml = itoa(ff.fd.max_length)
			orm_form_attr(s, c"maxlength", ml)
			free(ml)
		if (value != 0): orm_form_attr(s, c"value", value)
		if (ff.required): string_append(s, c" required")
		string_append(s, c">")
	if (value != 0): free(value)
	free(id)
	char* out = s.data
	free(s)
	return out


# The error messages of `key` (borrowed JSON array), or 0.
json_value* orm_form_messages(orm_form* f, char* key):
	if (f.errors == 0): return 0
	json_value* l = json_object_get(f.errors, key)
	if (l == 0 || l.type != json_type_array()): return 0
	return l


void orm_form_errorlist(string_builder* s, json_value* msgs, char* cls):
	if (msgs == 0 || json_array_length(msgs) == 0): return
	string_append(s, c"<ul class=\"")
	string_append(s, cls)
	string_append(s, c"\">")
	for i in range(json_array_length(msgs)):
		json_value* m = json_array_get(msgs, i)
		string_append(s, c"<li>")
		if (m.type == json_type_string()): orm_html_append_escaped(s, m.string_value)
		string_append(s, c"</li>")
	string_append(s, c"</ul>")


# Errors that belong to no field: non_field_errors, or a {"detail": ...}.
void orm_form_nonfield(orm_form* f, string_builder* s):
	if (f.errors == 0): return
	orm_form_errorlist(s, orm_form_messages(f, c"non_field_errors"), c"errorlist nonfield")
	json_value* detail = json_object_get(f.errors, c"detail")
	if (detail != 0 && detail.type == json_type_string()):
		string_append(s, c"<ul class=\"errorlist nonfield\"><li>")
		orm_html_append_escaped(s, detail.string_value)
		string_append(s, c"</li></ul>")


# Django's form.as_p(): the CSRF input (when token is not 0), form-level
# errors, then per field its errors and a <p> with label and widget.
# Owned HTML.
char* orm_form_render(orm_form* f, char* csrf_token):
	string_builder* s = string_new()
	if (csrf_token != 0):
		string_append(s, c"<input type=\"hidden\" name=\"csrfmiddlewaretoken\"")
		orm_form_attr(s, c"value", csrf_token)
		string_append(s, c">\n")
	orm_form_nonfield(f, s)
	for orm_form_field* ff in f.fields:
		orm_form_errorlist(s, orm_form_messages(f, ff.name), c"errorlist")
		string_append(s, c"<p><label for=\"id_")
		orm_html_append_escaped(s, ff.name)
		string_append(s, c"\">")
		orm_html_append_escaped(s, ff.label)
		string_append(s, c":</label> ")
		char* widget = orm_form_widget_html(f, ff)
		string_append(s, widget)
		free(widget)
		string_append(s, c"</p>\n")
	char* out = s.data
	free(s)
	return out


orm_tpl_value* orm_form_safe_take(orm_tpl_ctx* ctx, char* html):
	orm_tpl_value* v = orm_tpl_str_take(ctx, html)
	if (v.kind == ORM_TV_STR): v.safe = 1
	return v


orm_tpl_value* orm_form_tpl_messages(orm_tpl_ctx* ctx, json_value* msgs):
	orm_tpl_value* l = orm_tpl_list(ctx)
	if (msgs == 0): return l
	for i in range(json_array_length(msgs)):
		json_value* m = json_array_get(msgs, i)
		if (m.type == json_type_string()): orm_tpl_push(l, orm_tpl_str(ctx, m.string_value))
	return l


# The form as a template value: html (as_p, safe, with the CSRF input
# when csrf_token is not 0), fields (name, label, id, widget (safe),
# value, required, errors), non_field_errors, has_errors, is_bound.
orm_tpl_value* orm_form_tpl(orm_tpl_ctx* ctx, orm_form* f, char* csrf_token):
	orm_tpl_value* o = orm_tpl_map(ctx)
	orm_tpl_put(o, c"html", orm_form_safe_take(ctx, orm_form_render(f, csrf_token)))
	orm_tpl_value* fields = orm_tpl_list(ctx)
	for orm_form_field* ff in f.fields:
		orm_tpl_value* m = orm_tpl_map(ctx)
		orm_tpl_put_str(ctx, m, c"name", ff.name)
		orm_tpl_put_str(ctx, m, c"label", ff.label)
		orm_tpl_put(m, c"id", orm_tpl_str_take(ctx, orm_rest_concat(c"id_", ff.name)))
		orm_tpl_put(m, c"widget", orm_form_safe_take(ctx, orm_form_widget_html(f, ff)))
		orm_tpl_put(m, c"value", orm_tpl_str_take(ctx, orm_form_value(f, ff)))
		orm_tpl_put(m, c"required", orm_tpl_bool(ctx, ff.required))
		orm_tpl_put(m, c"errors", orm_form_tpl_messages(ctx, orm_form_messages(f, ff.name)))
		orm_tpl_push(fields, m)
	orm_tpl_put(o, c"fields", fields)
	string_builder* nf = string_new()
	orm_form_nonfield(f, nf)
	orm_tpl_put(o, c"non_field_errors", orm_form_safe_take(ctx, nf.data))
	free(nf)
	orm_tpl_put(o, c"has_errors", orm_tpl_bool(ctx, f.errors != 0))
	orm_tpl_put(o, c"is_bound", orm_tpl_bool(ctx, f.data != 0))
	return o
