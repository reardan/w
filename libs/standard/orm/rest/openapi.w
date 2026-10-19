# w-orm OpenAPI generation (unit U4.2, docs/projects/orm/u4_2.md): an
# OpenAPI 3.0.3 document built from serializers, filter sets and
# paginators, the drf-spectacular equivalent. HTTP-agnostic: the viewset
# layer (U4.1) describes its routes with orm_api_route and serves the
# rendered text at /openapi.json.
#
#   orm_api* api = orm_api_new(c"Library", c"1.0.0")
#   orm_api_route* r = orm_api_add(api, c"/books", book_serializer)
#   orm_api_route_filters(r, book_filters)
#   orm_api_route_paginator(r, orm_paginator_cursor(c"-published_at", 20))
#   orm_api_route_auth(r, ORM_API_AUTH_SESSION | ORM_API_AUTH_TOKEN)
#   orm_api_route_history(r, 1)
#   char* text = orm_openapi_render(api)    # pretty JSON, stable key order
#
# Components: one response schema per serializer (named after its model,
# or orm_api_name), "<Name>Request" when the input differs from the
# output (read-only / write-only fields or optional inputs),
# "Patched<Name>Request" for PATCH, "Paginated<Name>List" /
# "CursorPaginated<Name>List" envelopes, "Historical<Name>" rows, and
# the shared Error / ValidationError schemas and responses. Schemas are
# sorted by name and every other object keeps insertion order, so the
# output is deterministic.
import libs.standard.orm.rest.pagination


# Route actions (DRF viewset actions).
const int ORM_API_LIST = 1              # GET    <path>
const int ORM_API_CREATE = 2            # POST   <path>
const int ORM_API_RETRIEVE = 4          # GET    <detail>
const int ORM_API_UPDATE = 8            # PUT    <detail>
const int ORM_API_PARTIAL_UPDATE = 16   # PATCH  <detail>
const int ORM_API_DESTROY = 32          # DELETE <detail>
const int ORM_API_READ_ONLY = 5         # LIST | RETRIEVE
const int ORM_API_ALL = 63

# Authentication schemes a route accepts (0 = no authentication).
const int ORM_API_AUTH_SESSION = 1      # session cookie; unsafe methods also need the CSRF header
const int ORM_API_AUTH_TOKEN = 2        # "Authorization: Token <key>"
const int ORM_API_AUTH_ANON = 4         # anonymous requests are allowed too


# One viewset-shaped route: a collection path and its detail path.
struct orm_api_route:
	char* path                 # collection path ("/books")
	char* detail_path          # 0 = path + "/{<pk name>}"
	char* name                 # operationId prefix; 0 = derived from path ("books")
	char* tag                  # 0 = name
	orm_serializer* serializer
	orm_filter_set* filters    # 0 = no filter parameters
	orm_paginator* paginator   # 0 = the list is a plain array
	int actions                # ORM_API_* bits
	int auth                   # ORM_API_AUTH_* bits
	int history                # 1: GET <detail>/history (model must have history)


struct orm_api_ser_name:
	orm_serializer* ser
	char* name


struct orm_api_override:
	orm_serializer* ser
	char* field
	json_value* schema         # owned


struct orm_api:
	char* title
	char* version
	char* description          # 0 = none
	list[orm_api_route*] routes
	list[orm_api_ser_name*] names
	list[orm_api_override*] overrides
	char* session_cookie       # "sessionid"
	char* csrf_header          # "X-CSRFToken"
	char* token_header         # "Authorization"
	char* token_prefix         # "Token"
	char* error                # first configuration error of the last generation, or 0


orm_api* orm_api_new(char* title, char* version):
	orm_api* api = new orm_api()
	api.title = title
	api.version = version
	api.routes = new list[orm_api_route*]
	api.names = new list[orm_api_ser_name*]
	api.overrides = new list[orm_api_override*]
	api.session_cookie = c"sessionid"
	api.csrf_header = c"X-CSRFToken"
	api.token_header = c"Authorization"
	api.token_prefix = c"Token"
	return api


# Frees the description (not the serializers, filter sets or paginators).
void orm_api_free(orm_api* api):
	if (api == 0): return
	for orm_api_route* r in api.routes: free(cast(void*, r))
	api.routes.free()
	for orm_api_ser_name* n in api.names:
		free(n.name)
		free(cast(void*, n))
	api.names.free()
	for orm_api_override* o in api.overrides:
		json_free(o.schema)
		free(cast(void*, o))
	api.overrides.free()
	if (api.error != 0): free(api.error)
	free(cast(void*, api))


char* orm_api_error(orm_api* api):
	return api.error


# A route with every action, no filters, no pagination, no auth.
orm_api_route* orm_api_add(orm_api* api, char* path, orm_serializer* ser):
	orm_api_route* r = new orm_api_route()
	r.path = path
	r.serializer = ser
	r.actions = ORM_API_ALL
	api.routes.push(r)
	return r


orm_api_route* orm_api_route_actions(orm_api_route* r, int actions):
	r.actions = actions
	return r


orm_api_route* orm_api_route_filters(orm_api_route* r, orm_filter_set* fs):
	r.filters = fs
	return r


orm_api_route* orm_api_route_paginator(orm_api_route* r, orm_paginator* p):
	r.paginator = p
	return r


orm_api_route* orm_api_route_auth(orm_api_route* r, int auth):
	r.auth = auth
	return r


orm_api_route* orm_api_route_history(orm_api_route* r, int on):
	r.history = on
	return r


orm_api_route* orm_api_route_name(orm_api_route* r, char* name):
	r.name = name
	return r


orm_api_route* orm_api_route_tag(orm_api_route* r, char* tag):
	r.tag = tag
	return r


orm_api_route* orm_api_route_detail_path(orm_api_route* r, char* detail_path):
	r.detail_path = detail_path
	return r


# Names ser's component schema (default: its model's name, numbered on
# a clash with another serializer).
void orm_api_name(orm_api* api, orm_serializer* ser, char* name):
	for orm_api_ser_name* n in api.names:
		if (n.ser == ser):
			free(n.name)
			n.name = strclone(name)
			return
	orm_api_ser_name* e = new orm_api_ser_name()
	e.ser = ser
	e.name = strclone(name)
	api.names.push(e)


# Replaces the generated schema of one serializer field (method fields
# have no type otherwise). Takes ownership of schema.
void orm_api_field_schema(orm_api* api, orm_serializer* ser, char* field, json_value* schema):
	orm_api_override* o = new orm_api_override()
	o.ser = ser
	o.field = field
	o.schema = schema
	api.overrides.push(o)


# ---------------------------------------------------------------------------
# Generation state

struct orm_oa_gen:
	orm_api* api
	list[char*] schema_names           # component schemas, in creation order
	list[json_value*] schema_values    # parallel; 0 while being built
	list[orm_api_ser_name*] auto_names # names assigned during this run
	list[char*] operation_ids
	list[char*] tags
	list[char*] owned
	int used_session
	int used_token
	int used_errors                    # Error schema referenced
	int used_validation                # ValidationError schema referenced
	int used_401
	int used_403
	int used_404
	int used_400


void orm_oa_fail(orm_oa_gen* g, char* a, char* b, char* c):
	if (g.api.error != 0): return
	string_builder* s = string_new()
	string_append(s, a)
	if (b != 0): string_append(s, b)
	if (c != 0): string_append(s, c)
	g.api.error = s.data
	free(s)


char* orm_oa_own(orm_oa_gen* g, char* s):
	g.owned.push(s)
	return s


int orm_oa_index_of(list[char*] names, char* name):
	for i in range(names.length):
		if (strcmp(names[i], name) == 0): return i
	return -1


json_value* orm_oa_type(char* type):
	json_value* o = json_object()
	json_object_set(o, c"type", json_string(type))
	return o


json_value* orm_oa_type_format(char* type, char* format):
	json_value* o = orm_oa_type(type)
	json_object_set(o, c"format", json_string(format))
	return o


json_value* orm_oa_ref(char* section, char* name):
	json_value* o = json_object()
	char* target = orm_rest_concat3(c"#/components/", section, c"/")
	char* full = orm_rest_concat(target, name)
	json_object_set(o, c"$ref", json_string(full))
	free(target)
	free(full)
	return o


json_value* orm_oa_schema_ref(char* name):
	return orm_oa_ref(c"schemas", name)


json_value* orm_oa_strings(list[char*] items):
	json_value* a = json_array()
	for char* s in items: json_array_push(a, json_string(s))
	return a


json_value* orm_oa_string_array_schema():
	json_value* a = orm_oa_type(c"array")
	json_object_set(a, c"items", orm_oa_type(c"string"))
	return a


# Marks a schema nullable (OpenAPI 3.0: "nullable": true, and an enum
# must list null itself).
void orm_oa_nullable(json_value* schema):
	json_value* e = json_object_get(schema, c"enum")
	if (e != 0): json_array_push(e, json_null())
	json_object_set(schema, c"nullable", json_bool(1))


# ---------------------------------------------------------------------------
# Field schemas

json_value* orm_oa_kind_schema(orm_field_desc* fd, int decimal_as_number);


# "^-?\d{0,6}(?:\.\d{0,2})?$" for NUMERIC(8, 2).
char* orm_oa_decimal_pattern(orm_field_desc* fd):
	string_builder* s = string_new()
	string_append(s, c"^-?\\d{0,")
	string_append_int(s, fd.digits - fd.places)
	string_append_char(s, '}')
	if (fd.places > 0):
		string_append(s, c"(?:\\.\\d{0,")
		string_append_int(s, fd.places)
		string_append(s, c"})?")
	string_append_char(s, '$')
	char* out = s.data
	free(s)
	return out


# The schema of the target's pk (what an FK or pk list carries).
json_value* orm_oa_pk_schema(orm_model_desc* m):
	if (m == 0): return orm_oa_type(c"integer")
	orm_field_desc* pk = orm_model_pk(m)
	if (pk == 0 || pk.kind == ORM_FK): return orm_oa_type(c"integer")
	return orm_oa_kind_schema(pk, 0)


# The JSON shape of one column value (serializer output and input).
json_value* orm_oa_kind_schema(orm_field_desc* fd, int decimal_as_number):
	int k = fd.kind
	if (k == ORM_INT): return orm_oa_type(c"integer")
	if (k == ORM_BIGINT): return orm_oa_type_format(c"integer", c"int64")
	if (k == ORM_FK): return orm_oa_pk_schema(orm_field_target(fd))
	if (k == ORM_BOOL): return orm_oa_type(c"boolean")
	if (k == ORM_FLOAT): return orm_oa_type_format(c"number", c"double")
	if (k == ORM_DECIMAL):
		if (decimal_as_number): return orm_oa_type_format(c"number", c"double")
		json_value* d = orm_oa_type_format(c"string", c"decimal")
		if (fd.digits > 0):
			char* pat = orm_oa_decimal_pattern(fd)
			json_object_set(d, c"pattern", json_string(pat))
			free(pat)
		return d
	if (k == ORM_DATETIME): return orm_oa_type_format(c"string", c"date-time")
	if (k == ORM_DATE): return orm_oa_type_format(c"string", c"date")
	if (k == ORM_UUID): return orm_oa_type_format(c"string", c"uuid")
	if (k == ORM_JSON): return json_object()
	if (k == ORM_ENUM):
		json_value* e = orm_oa_type(c"string")
		json_object_set(e, c"enum", orm_oa_strings(fd.enum_values))
		return e
	json_value* t = orm_oa_type(c"string")
	if (fd.max_length > 0): json_object_set(t, c"maxLength", json_int(fd.max_length))
	return t


# A column schema with nullability.
json_value* orm_oa_column_schema(orm_field_desc* fd, int decimal_as_number):
	json_value* s = orm_oa_kind_schema(fd, decimal_as_number)
	if ((fd.flags & ORM_F_NULL) != 0): orm_oa_nullable(s)
	return s


# 1 when the value at an FK source path can be null (a nullable FK on
# the way, or a nullable terminal column).
int orm_oa_source_nullable(orm_model_desc* m, char* path):
	list[char*] parts = orm_path_split(path)
	int out = 0
	for char* p in parts:
		if (m != 0):
			orm_field_desc* fd = orm_model_field(m, p)
			if (fd != 0):
				if ((fd.flags & ORM_F_NULL) != 0): out = 1
				m = orm_field_target(fd)
			else: m = 0
		free(p)
	parts.free()
	return out


json_value* orm_oa_annotation_schema(orm_serializer* ser, int k):
	json_value* s = 0
	if (k == ORM_INT || k == ORM_BIGINT || k == ORM_FK): s = orm_oa_type(c"integer")
	else if (k == ORM_BOOL): s = orm_oa_type(c"boolean")
	else if (k == ORM_FLOAT || (k == ORM_DECIMAL && ser.decimal_as_number)): s = orm_oa_type_format(c"number", c"double")
	else if (k == ORM_DECIMAL): s = orm_oa_type_format(c"string", c"decimal")
	else if (k == 0):
		s = json_object()
		json_value* any = json_array()
		json_array_push(any, orm_oa_type(c"integer"))
		json_array_push(any, orm_oa_type(c"string"))
		json_object_set(s, c"oneOf", any)
	else: s = orm_oa_type(c"string")
	orm_oa_nullable(s)
	return s


json_value* orm_oa_override(orm_api* api, orm_serializer* ser, char* name):
	for orm_api_override* o in api.overrides:
		if (o.ser == ser && strcmp(o.field, name) == 0): return o.schema
	return 0


# ---------------------------------------------------------------------------
# Component schemas

char* orm_oa_ser_name(orm_oa_gen* g, orm_serializer* ser):
	for orm_api_ser_name* n in g.api.names:
		if (n.ser == ser): return n.name
	for orm_api_ser_name* a in g.auto_names:
		if (a.ser == ser): return a.name
	char* base = ser.model.name
	char* name = strclone(base)
	int k = 2
	int clash = 1
	while (clash):
		clash = 0
		for orm_api_ser_name* x in g.api.names:
			if (strcmp(x.name, name) == 0): clash = 1
		for orm_api_ser_name* y in g.auto_names:
			if (strcmp(y.name, name) == 0): clash = 1
		if (clash):
			free(name)
			char* num = itoa(k)
			name = orm_rest_concat(base, num)
			free(num)
			k = k + 1
	orm_api_ser_name* e = new orm_api_ser_name()
	e.ser = ser
	e.name = name
	g.auto_names.push(e)
	return name


# Reserves component `name`; 0 when it already exists.
int orm_oa_reserve(orm_oa_gen* g, char* name):
	if (orm_oa_index_of(g.schema_names, name) >= 0): return 0
	g.schema_names.push(orm_oa_own(g, strclone(name)))
	g.schema_values.push(0)
	return 1


void orm_oa_define(orm_oa_gen* g, char* name, json_value* schema):
	int i = orm_oa_index_of(g.schema_names, name)
	g.schema_values[i] = schema


char* orm_oa_response_ref(orm_oa_gen* g, orm_serializer* ser);


# One serializer entry in the output schema.
json_value* orm_oa_output_field(orm_oa_gen* g, orm_serializer* ser, orm_ser_field* sf):
	json_value* custom = orm_oa_override(g.api, ser, sf.name)
	if (custom != 0): return json_clone(custom)
	int k = sf.kind
	json_value* s = 0
	if (k == ORM_SF_FIELD): s = orm_oa_column_schema(sf.field, ser.decimal_as_number)
	else if (k == ORM_SF_SOURCE):
		s = orm_oa_kind_schema(sf.field, ser.decimal_as_number)
		if (orm_oa_source_nullable(ser.model, sf.source)): orm_oa_nullable(s)
	else if (k == ORM_SF_NESTED && sf.field.kind == ORM_FK):
		char* child = orm_oa_response_ref(g, cast(orm_serializer*, sf.nested))
		s = json_object()
		json_value* all = json_array()
		json_array_push(all, orm_oa_schema_ref(child))
		json_object_set(s, c"allOf", all)
		if ((sf.field.flags & ORM_F_NULL) != 0): json_object_set(s, c"nullable", json_bool(1))
	else if (k == ORM_SF_NESTED):
		char* item = orm_oa_response_ref(g, cast(orm_serializer*, sf.nested))
		s = orm_oa_type(c"array")
		json_object_set(s, c"items", orm_oa_schema_ref(item))
	else if (k == ORM_SF_PK_LIST):
		s = orm_oa_type(c"array")
		json_object_set(s, c"items", orm_oa_pk_schema(orm_field_target(sf.field)))
	else if (k == ORM_SF_ANNOTATION): s = orm_oa_annotation_schema(ser, sf.ann_kind)
	else: s = json_object()
	if (sf.read_only): json_object_set(s, c"readOnly", json_bool(1))
	return s


int orm_oa_input_required(orm_ser_field* sf):
	return orm_ser_field_required(sf)


int orm_oa_writable(orm_ser_field* sf):
	return sf.kind == ORM_SF_FIELD && sf.read_only == 0


# One writable entry in a request schema.
json_value* orm_oa_input_field(orm_oa_gen* g, orm_serializer* ser, orm_ser_field* sf):
	json_value* custom = orm_oa_override(g.api, ser, sf.name)
	if (custom != 0): return json_clone(custom)
	orm_field_desc* fd = sf.field
	json_value* s = orm_oa_column_schema(fd, ser.decimal_as_number)
	if (fd.kind == ORM_TEXT && sf.allow_blank == 0): json_object_set(s, c"minLength", json_int(1))
	if (sf.write_only): json_object_set(s, c"writeOnly", json_bool(1))
	return s


json_value* orm_oa_object(json_value* props, json_value* required):
	json_value* o = orm_oa_type(c"object")
	json_object_set(o, c"properties", props)
	if (json_array_length(required) > 0): json_object_set(o, c"required", required)
	else: json_free(required)
	return o


void orm_oa_check_serializer(orm_oa_gen* g, orm_serializer* ser):
	char* err = orm_serializer_error(ser)
	if (err != 0): orm_oa_fail(g, err, 0, 0)


# The response schema of ser (built on first use); returns its name.
char* orm_oa_response_ref(orm_oa_gen* g, orm_serializer* ser):
	char* name = orm_oa_ser_name(g, ser)
	if (orm_oa_reserve(g, name) == 0): return name
	orm_oa_check_serializer(g, ser)
	json_value* props = json_object()
	json_value* required = json_array()
	for orm_ser_field* sf in ser.fields:
		if (sf.write_only): continue
		json_object_set(props, sf.name, orm_oa_output_field(g, ser, sf))
		json_array_push(required, json_string(sf.name))
	orm_oa_define(g, name, orm_oa_object(props, required))
	return name


# 1 when the request body has exactly the response's fields, all required.
int orm_oa_request_same(orm_serializer* ser):
	for orm_ser_field* sf in ser.fields:
		if (orm_oa_writable(sf) == 0 || sf.write_only): return 0
		if (orm_oa_input_required(sf) == 0): return 0
	return 1


int orm_oa_request_has_required(orm_serializer* ser):
	for orm_ser_field* sf in ser.fields:
		if (orm_oa_writable(sf) && orm_oa_input_required(sf)): return 1
	return 0


json_value* orm_oa_request_schema(orm_oa_gen* g, orm_serializer* ser, int partial):
	json_value* props = json_object()
	json_value* required = json_array()
	for orm_ser_field* sf in ser.fields:
		if (orm_oa_writable(sf) == 0): continue
		json_object_set(props, sf.name, orm_oa_input_field(g, ser, sf))
		if (partial == 0 && orm_oa_input_required(sf)): json_array_push(required, json_string(sf.name))
	return orm_oa_object(props, required)


# The POST/PUT body schema name: the response schema when identical, else
# "<Name>Request".
char* orm_oa_request_ref(orm_oa_gen* g, orm_serializer* ser):
	char* name = orm_oa_response_ref(g, ser)
	if (orm_oa_request_same(ser)): return name
	char* req = orm_oa_own(g, orm_rest_concat(name, c"Request"))
	if (orm_oa_reserve(g, req)): orm_oa_define(g, req, orm_oa_request_schema(g, ser, 0))
	return req


# The PATCH body schema name: "Patched<Name>Request" (every field
# optional), or the request schema when nothing is required anyway.
char* orm_oa_patch_ref(orm_oa_gen* g, orm_serializer* ser):
	if (orm_oa_request_has_required(ser) == 0): return orm_oa_request_ref(g, ser)
	char* name = orm_oa_response_ref(g, ser)
	char* patched = orm_oa_own(g, orm_rest_concat3(c"Patched", name, c"Request"))
	if (orm_oa_reserve(g, patched)): orm_oa_define(g, patched, orm_oa_request_schema(g, ser, 1))
	return patched


json_value* orm_oa_link_schema():
	json_value* s = orm_oa_type(c"string")
	json_object_set(s, c"nullable", json_bool(1))
	return s


# The list envelope of orm_page_json for p's style.
char* orm_oa_paginated_ref(orm_oa_gen* g, orm_serializer* ser, orm_paginator* p):
	char* item = orm_oa_response_ref(g, ser)
	int cursor = p.style == ORM_PAGE_CURSOR
	char* name = 0
	if (cursor): name = orm_oa_own(g, orm_rest_concat3(c"CursorPaginated", item, c"List"))
	else: name = orm_oa_own(g, orm_rest_concat3(c"Paginated", item, c"List"))
	if (orm_oa_reserve(g, name) == 0): return name
	json_value* props = json_object()
	json_value* required = json_array()
	if (cursor == 0):
		json_object_set(props, c"count", orm_oa_type(c"integer"))
		json_array_push(required, json_string(c"count"))
	json_object_set(props, c"next", orm_oa_link_schema())
	json_object_set(props, c"previous", orm_oa_link_schema())
	json_value* results = orm_oa_type(c"array")
	json_object_set(results, c"items", orm_oa_schema_ref(item))
	json_object_set(props, c"results", results)
	json_array_push(required, json_string(c"next"))
	json_array_push(required, json_string(c"previous"))
	json_array_push(required, json_string(c"results"))
	orm_oa_define(g, name, orm_oa_object(props, required))
	return name


json_value* orm_oa_history_type():
	json_value* t = orm_oa_type(c"string")
	json_value* e = json_array()
	json_array_push(e, json_string(c"+"))
	json_array_push(e, json_string(c"~"))
	json_array_push(e, json_string(c"-"))
	json_object_set(t, c"enum", e)
	json_object_set(t, c"description", json_string(c"+ created, ~ changed, - deleted."))
	return t


json_value* orm_oa_nullable_type(char* type):
	json_value* t = orm_oa_type(type)
	json_object_set(t, c"nullable", json_bool(1))
	return t


# "Historical<Name>": the serializer's model-field outputs (history
# tables keep every tracked column) plus the C8 history columns.
char* orm_oa_history_ref(orm_oa_gen* g, orm_serializer* ser):
	char* base = orm_oa_response_ref(g, ser)
	char* name = orm_oa_own(g, orm_rest_concat(c"Historical", base))
	if (orm_oa_reserve(g, name) == 0): return name
	json_value* props = json_object()
	json_value* required = json_array()
	for orm_ser_field* sf in ser.fields:
		if (sf.write_only || sf.kind != ORM_SF_FIELD): continue
		if ((sf.field.flags & ORM_F_NO_HISTORY) != 0): continue
		json_object_set(props, sf.name, orm_oa_column_schema(sf.field, ser.decimal_as_number))
		json_array_push(required, json_string(sf.name))
	json_object_set(props, c"history_id", orm_oa_type(c"integer"))
	json_object_set(props, c"history_date", orm_oa_type_format(c"string", c"date-time"))
	json_object_set(props, c"history_type", orm_oa_history_type())
	json_object_set(props, c"history_user_id", orm_oa_nullable_type(c"integer"))
	json_object_set(props, c"history_reason", orm_oa_nullable_type(c"string"))
	json_object_set(props, c"history_context_id", orm_oa_nullable_type(c"string"))
	json_array_push(required, json_string(c"history_id"))
	json_array_push(required, json_string(c"history_date"))
	json_array_push(required, json_string(c"history_type"))
	json_array_push(required, json_string(c"history_user_id"))
	json_array_push(required, json_string(c"history_reason"))
	json_array_push(required, json_string(c"history_context_id"))
	orm_oa_define(g, name, orm_oa_object(props, required))
	return name


# ---------------------------------------------------------------------------
# Parameters

json_value* orm_oa_param(char* name, char* where, json_value* schema, char* description):
	json_value* p = json_object()
	json_object_set(p, c"name", json_string(name))
	json_object_set(p, c"in", json_string(where))
	if (strcmp(where, c"path") == 0): json_object_set(p, c"required", json_bool(1))
	if (description != 0): json_object_set(p, c"description", json_string(description))
	json_object_set(p, c"schema", schema)
	return p


# Comma-separated list form (?x__in=a,b): style form, explode false.
json_value* orm_oa_list_param(char* name, json_value* items, int exact_count, char* description):
	json_value* a = orm_oa_type(c"array")
	json_object_set(a, c"items", items)
	if (exact_count > 0):
		json_object_set(a, c"minItems", json_int(exact_count))
		json_object_set(a, c"maxItems", json_int(exact_count))
	json_value* p = orm_oa_param(name, c"query", a, description)
	json_object_set(p, c"style", json_string(c"form"))
	json_object_set(p, c"explode", json_bool(0))
	return p


# The query-string shape of one value of fd (what orm_filter_value accepts).
json_value* orm_oa_filter_value_schema(orm_field_desc* fd):
	int k = fd.kind
	if (k == ORM_DECIMAL || k == ORM_FLOAT): return orm_oa_type(c"number")
	if (k == ORM_TEXT || k == ORM_JSON): return orm_oa_type(c"string")
	return orm_oa_kind_schema(fd, 0)


int orm_oa_text_lookup(char* l):
	if (strcmp(l, c"contains") == 0 || strcmp(l, c"icontains") == 0 || strcmp(l, c"iexact") == 0): return 1
	if (strcmp(l, c"startswith") == 0 || strcmp(l, c"istartswith") == 0): return 1
	if (strcmp(l, c"endswith") == 0 || strcmp(l, c"iendswith") == 0): return 1
	return strcmp(l, c"regex") == 0


json_value* orm_oa_filter_param(orm_filter_rule* r, char* lookup):
	char* name = 0
	if (strcmp(lookup, c"exact") == 0): name = strclone(r.path)
	else: name = orm_rest_concat3(r.path, c"__", lookup)
	char* d0 = orm_rest_concat3(c"Filter on ", r.path, c" (")
	char* desc = orm_rest_concat3(d0, lookup, c").")
	free(d0)
	json_value* p = 0
	if (strcmp(lookup, c"in") == 0): p = orm_oa_list_param(name, orm_oa_filter_value_schema(r.field), 0, desc)
	else if (strcmp(lookup, c"range") == 0): p = orm_oa_list_param(name, orm_oa_filter_value_schema(r.field), 2, desc)
	else if (strcmp(lookup, c"isnull") == 0): p = orm_oa_param(name, c"query", orm_oa_type(c"boolean"), desc)
	else if (orm_oa_text_lookup(lookup)): p = orm_oa_param(name, c"query", orm_oa_type(c"string"), desc)
	else: p = orm_oa_param(name, c"query", orm_oa_filter_value_schema(r.field), desc)
	free(name)
	free(desc)
	return p


void orm_oa_filter_params(orm_oa_gen* g, json_value* params, orm_filter_set* fs):
	char* err = orm_filter_error(fs)
	if (err != 0): orm_oa_fail(g, err, 0, 0)
	for orm_filter_rule* r in fs.rules:
		for char* l in r.lookups: json_array_push(params, orm_oa_filter_param(r, l))
	if (fs.ordering_fields.length > 0):
		json_value* choices = json_array()
		for char* o in fs.ordering_fields:
			json_array_push(choices, json_string(o))
			char* desc = orm_rest_concat(c"-", o)
			json_array_push(choices, json_string(desc))
			free(desc)
		json_value* item = orm_oa_type(c"string")
		json_object_set(item, c"enum", choices)
		json_array_push(params, orm_oa_list_param(fs.ordering_param, item, 0, c"Which fields to order the results by; a leading - reverses."))
	if (fs.search_fields.length > 0):
		char* fields = join(fs.search_fields, c", ")
		char* desc = orm_rest_concat3(c"Search terms; each must match one of: ", fields, c".")
		json_array_push(params, orm_oa_param(fs.search_param, c"query", orm_oa_type(c"string"), desc))
		free(fields)
		free(desc)


json_value* orm_oa_int_min(int minimum, int maximum):
	json_value* s = orm_oa_type(c"integer")
	json_object_set(s, c"minimum", json_int(minimum))
	if (maximum > 0): json_object_set(s, c"maximum", json_int(maximum))
	return s


void orm_oa_page_params(json_value* params, orm_paginator* p):
	int st = p.style
	if (st == ORM_PAGE_NUMBER):
		json_array_push(params, orm_oa_param(p.page_param, c"query", orm_oa_int_min(1, 0), c"A page number within the paginated result set (\"last\" for the last page)."))
	else if (st == ORM_PAGE_LIMIT_OFFSET):
		json_array_push(params, orm_oa_param(p.limit_param, c"query", orm_oa_int_min(1, p.max_page_size), c"Number of results to return per page."))
		json_array_push(params, orm_oa_param(p.offset_param, c"query", orm_oa_int_min(0, 0), c"The initial index from which to return the results."))
	else: json_array_push(params, orm_oa_param(p.cursor_param, c"query", orm_oa_type(c"string"), c"The pagination cursor value."))
	if (st != ORM_PAGE_LIMIT_OFFSET && p.page_size_param != 0):
		json_array_push(params, orm_oa_param(p.page_size_param, c"query", orm_oa_int_min(1, p.max_page_size), c"Number of results to return per page."))


# ---------------------------------------------------------------------------
# Operations

json_value* orm_oa_json_content(json_value* schema):
	json_value* media = json_object()
	json_object_set(media, c"schema", schema)
	json_value* c = json_object()
	json_object_set(c, c"application/json", media)
	return c


json_value* orm_oa_response(char* description, json_value* schema):
	json_value* r = json_object()
	json_object_set(r, c"description", json_string(description))
	if (schema != 0): json_object_set(r, c"content", orm_oa_json_content(schema))
	return r


json_value* orm_oa_body(json_value* schema, int required):
	json_value* b = json_object()
	json_object_set(b, c"content", orm_oa_json_content(schema))
	if (required): json_object_set(b, c"required", json_bool(1))
	return b


# Error responses an operation can return; codes in ascending order.
void orm_oa_error_responses(orm_oa_gen* g, json_value* responses, orm_api_route* r, int bad_request, int not_found):
	if (bad_request):
		json_object_set(responses, c"400", orm_oa_ref(c"responses", c"ValidationError"))
		g.used_400 = 1
	if ((r.auth & (ORM_API_AUTH_SESSION | ORM_API_AUTH_TOKEN)) != 0):
		json_object_set(responses, c"401", orm_oa_ref(c"responses", c"Unauthenticated"))
		json_object_set(responses, c"403", orm_oa_ref(c"responses", c"PermissionDenied"))
		g.used_401 = 1
		g.used_403 = 1
	if (not_found):
		json_object_set(responses, c"404", orm_oa_ref(c"responses", c"NotFound"))
		g.used_404 = 1


# Security requirements: session (+ CSRF header on unsafe methods),
# token, and {} when anonymous access is allowed.
json_value* orm_oa_security(orm_oa_gen* g, orm_api_route* r, int unsafe):
	json_value* s = json_array()
	if ((r.auth & ORM_API_AUTH_SESSION) != 0):
		json_value* req = json_object()
		json_object_set(req, c"cookieAuth", json_array())
		if (unsafe): json_object_set(req, c"csrfToken", json_array())
		json_array_push(s, req)
		g.used_session = 1
	if ((r.auth & ORM_API_AUTH_TOKEN) != 0):
		json_value* tok = json_object()
		json_object_set(tok, c"tokenAuth", json_array())
		json_array_push(s, tok)
		g.used_token = 1
	if ((r.auth & ORM_API_AUTH_ANON) != 0): json_array_push(s, json_object())
	return s


# "/api/books/" -> "api_books".
char* orm_oa_route_name(orm_api_route* r):
	if (r.name != 0): return strclone(r.name)
	string_builder* s = string_new()
	int pending = 0
	int n = strlen(r.path)
	for i in range(n):
		int ch = r.path[i] & 255
		if (isalnum(ch)):
			if (pending && s.length > 0): string_append_char(s, '_')
			pending = 0
			string_append_char(s, ch)
		else if (ch != '{' && ch != '}'): pending = 1
	char* out = s.data
	free(s)
	if (out[0] == 0):
		free(out)
		return strclone(c"root")
	return out


char* orm_oa_operation_id(orm_oa_gen* g, char* prefix, char* action):
	char* base = orm_rest_concat3(prefix, c"_", action)
	char* id = strclone(base)
	int k = 2
	while (orm_oa_index_of(g.operation_ids, id) >= 0):
		free(id)
		char* num = itoa(k)
		id = orm_rest_concat3(base, c"_", num)
		free(num)
		k = k + 1
	free(base)
	g.operation_ids.push(orm_oa_own(g, id))
	return id


json_value* orm_oa_operation(orm_oa_gen* g, orm_api_route* r, char* prefix, char* tag, char* action, char* summary):
	json_value* op = json_object()
	json_object_set(op, c"operationId", json_string(orm_oa_operation_id(g, prefix, action)))
	char* text = orm_rest_concat3(summary, c" ", r.serializer.model.name)
	if (strcmp(action, c"list") == 0):
		char* plural = orm_rest_concat(text, c" objects")
		free(text)
		text = plural
	json_object_set(op, c"summary", json_string(text))
	free(text)
	json_value* tags = json_array()
	json_array_push(tags, json_string(tag))
	json_object_set(op, c"tags", tags)
	return op


# Adds security then the responses object (security sits before
# responses in every operation).
void orm_oa_finish(orm_oa_gen* g, json_value* op, orm_api_route* r, int unsafe, json_value* responses):
	if (r.auth != 0): json_object_set(op, c"security", orm_oa_security(g, r, unsafe))
	json_object_set(op, c"responses", responses)


# The path item for path, created on first use (two routes may share one).
json_value* orm_oa_path_item(json_value* paths, char* path):
	json_value* item = json_object_get(paths, path)
	if (item == 0):
		item = json_object()
		json_object_set(paths, path, item)
	return item


char* orm_oa_join_path(char* base, char* tail):
	int n = strlen(base)
	if (n > 0 && base[n - 1] == '/'): return orm_rest_concat3(base, tail, c"/")
	return orm_rest_concat3(base, c"/", tail)


json_value* orm_oa_pk_param(orm_model_desc* m, orm_field_desc* pk):
	char* lower = strclone(m.name)
	for i in range(strlen(lower)): lower[i] = tolower(lower[i])
	char* desc = orm_rest_concat3(c"Primary key of the ", lower, c".")
	json_value* p = orm_oa_param(pk.name, c"path", orm_oa_pk_schema(m), desc)
	free(lower)
	free(desc)
	return p


void orm_oa_collection(orm_oa_gen* g, json_value* paths, orm_api_route* r, char* prefix, char* tag):
	orm_serializer* ser = r.serializer
	if ((r.actions & (ORM_API_LIST | ORM_API_CREATE)) == 0): return
	json_value* item = orm_oa_path_item(paths, r.path)
	if ((r.actions & ORM_API_LIST) != 0):
		json_value* op = orm_oa_operation(g, r, prefix, tag, c"list", c"List")
		json_value* params = json_array()
		if (r.filters != 0): orm_oa_filter_params(g, params, r.filters)
		if (r.paginator != 0): orm_oa_page_params(params, r.paginator)
		if (json_array_length(params) > 0): json_object_set(op, c"parameters", params)
		else: json_free(params)
		json_value* body = 0
		if (r.paginator != 0): body = orm_oa_schema_ref(orm_oa_paginated_ref(g, ser, r.paginator))
		else:
			body = orm_oa_type(c"array")
			json_object_set(body, c"items", orm_oa_schema_ref(orm_oa_response_ref(g, ser)))
		json_value* responses = json_object()
		json_object_set(responses, c"200", orm_oa_response(c"OK.", body))
		int bad = r.filters != 0
		int missing = r.paginator != 0 && r.paginator.style != ORM_PAGE_LIMIT_OFFSET
		orm_oa_error_responses(g, responses, r, bad, missing)
		orm_oa_finish(g, op, r, 0, responses)
		json_object_set(item, c"get", op)
	if ((r.actions & ORM_API_CREATE) != 0):
		json_value* cop = orm_oa_operation(g, r, prefix, tag, c"create", c"Create a")
		json_object_set(cop, c"requestBody", orm_oa_body(orm_oa_schema_ref(orm_oa_request_ref(g, ser)), 1))
		json_value* cres = json_object()
		json_object_set(cres, c"201", orm_oa_response(c"Created.", orm_oa_schema_ref(orm_oa_response_ref(g, ser))))
		orm_oa_error_responses(g, cres, r, 1, 0)
		orm_oa_finish(g, cop, r, 1, cres)
		json_object_set(item, c"post", cop)


void orm_oa_detail(orm_oa_gen* g, json_value* paths, orm_api_route* r, char* prefix, char* tag):
	orm_serializer* ser = r.serializer
	orm_model_desc* m = ser.model
	orm_field_desc* pk = orm_model_pk(m)
	int detail = ORM_API_RETRIEVE | ORM_API_UPDATE | ORM_API_PARTIAL_UPDATE | ORM_API_DESTROY
	if ((r.actions & detail) == 0 && r.history == 0): return
	if (pk == 0):
		orm_oa_fail(g, c"openapi: model ", m.name, c" has no primary key")
		return
	char* dpath = 0
	if (r.detail_path != 0): dpath = orm_oa_own(g, strclone(r.detail_path))
	else:
		char* brace = orm_rest_concat3(c"{", pk.name, c"}")
		dpath = orm_oa_own(g, orm_oa_join_path(r.path, brace))
		free(brace)
	if ((r.actions & detail) != 0):
		json_value* item = orm_oa_path_item(paths, dpath)
		json_value* pparams = json_array()
		json_array_push(pparams, orm_oa_pk_param(m, pk))
		json_object_set(item, c"parameters", pparams)
		if ((r.actions & ORM_API_RETRIEVE) != 0):
			json_value* op = orm_oa_operation(g, r, prefix, tag, c"retrieve", c"Retrieve a")
			json_value* res = json_object()
			json_object_set(res, c"200", orm_oa_response(c"OK.", orm_oa_schema_ref(orm_oa_response_ref(g, ser))))
			orm_oa_error_responses(g, res, r, 0, 1)
			orm_oa_finish(g, op, r, 0, res)
			json_object_set(item, c"get", op)
		if ((r.actions & ORM_API_UPDATE) != 0):
			json_value* uop = orm_oa_operation(g, r, prefix, tag, c"update", c"Replace a")
			json_object_set(uop, c"requestBody", orm_oa_body(orm_oa_schema_ref(orm_oa_request_ref(g, ser)), 1))
			json_value* ures = json_object()
			json_object_set(ures, c"200", orm_oa_response(c"OK.", orm_oa_schema_ref(orm_oa_response_ref(g, ser))))
			orm_oa_error_responses(g, ures, r, 1, 1)
			orm_oa_finish(g, uop, r, 1, ures)
			json_object_set(item, c"put", uop)
		if ((r.actions & ORM_API_PARTIAL_UPDATE) != 0):
			json_value* pop = orm_oa_operation(g, r, prefix, tag, c"partial_update", c"Partially update a")
			json_object_set(pop, c"requestBody", orm_oa_body(orm_oa_schema_ref(orm_oa_patch_ref(g, ser)), 0))
			json_value* pres = json_object()
			json_object_set(pres, c"200", orm_oa_response(c"OK.", orm_oa_schema_ref(orm_oa_response_ref(g, ser))))
			orm_oa_error_responses(g, pres, r, 1, 1)
			orm_oa_finish(g, pop, r, 1, pres)
			json_object_set(item, c"patch", pop)
		if ((r.actions & ORM_API_DESTROY) != 0):
			json_value* dop = orm_oa_operation(g, r, prefix, tag, c"destroy", c"Delete a")
			json_value* dres = json_object()
			json_object_set(dres, c"204", orm_oa_response(c"Deleted.", 0))
			orm_oa_error_responses(g, dres, r, 0, 1)
			orm_oa_finish(g, dop, r, 1, dres)
			json_object_set(item, c"delete", dop)
	if (r.history):
		if (m.history == 0):
			orm_oa_fail(g, c"openapi: history route for ", m.name, c", which has no history")
			return
		char* hpath = orm_oa_own(g, orm_oa_join_path(dpath, c"history"))
		json_value* hitem = orm_oa_path_item(paths, hpath)
		json_value* hparams = json_array()
		json_array_push(hparams, orm_oa_pk_param(m, pk))
		json_object_set(hitem, c"parameters", hparams)
		json_value* hop = orm_oa_operation(g, r, prefix, tag, c"history", c"History of a")
		json_value* rows = orm_oa_type(c"array")
		json_object_set(rows, c"items", orm_oa_schema_ref(orm_oa_history_ref(g, ser)))
		json_value* hres = json_object()
		json_object_set(hres, c"200", orm_oa_response(c"History rows, newest first.", rows))
		orm_oa_error_responses(g, hres, r, 0, 1)
		orm_oa_finish(g, hop, r, 0, hres)
		json_object_set(hitem, c"get", hop)


# ---------------------------------------------------------------------------
# Document

void orm_oa_shared_schemas(orm_oa_gen* g):
	if (g.used_401 || g.used_403 || g.used_404):
		orm_oa_reserve(g, c"Error")
		json_value* props = json_object()
		json_object_set(props, c"detail", orm_oa_type(c"string"))
		json_value* req = json_array()
		json_array_push(req, json_string(c"detail"))
		orm_oa_define(g, c"Error", orm_oa_object(props, req))
	if (g.used_400):
		orm_oa_reserve(g, c"ValidationError")
		json_value* v = orm_oa_type(c"object")
		json_object_set(v, c"description", json_string(c"Messages keyed by field or query parameter name; non_field_errors holds object-level messages and detail a general one."))
		json_value* vprops = json_object()
		json_object_set(vprops, c"non_field_errors", orm_oa_string_array_schema())
		json_object_set(vprops, c"detail", orm_oa_type(c"string"))
		json_object_set(v, c"properties", vprops)
		json_object_set(v, c"additionalProperties", orm_oa_string_array_schema())
		orm_oa_define(g, c"ValidationError", v)


json_value* orm_oa_responses(orm_oa_gen* g):
	json_value* r = json_object()
	if (g.used_400): json_object_set(r, c"ValidationError", orm_oa_response(c"Invalid input.", orm_oa_schema_ref(c"ValidationError")))
	if (g.used_401): json_object_set(r, c"Unauthenticated", orm_oa_response(c"Authentication credentials were not provided or are not valid.", orm_oa_schema_ref(c"Error")))
	if (g.used_403): json_object_set(r, c"PermissionDenied", orm_oa_response(c"You do not have permission to perform this action.", orm_oa_schema_ref(c"Error")))
	if (g.used_404): json_object_set(r, c"NotFound", orm_oa_response(c"Not found.", orm_oa_schema_ref(c"Error")))
	return r


json_value* orm_oa_api_key(char* where, char* name, char* description):
	json_value* s = orm_oa_type(c"apiKey")
	json_object_set(s, c"in", json_string(where))
	json_object_set(s, c"name", json_string(name))
	json_object_set(s, c"description", json_string(description))
	return s


json_value* orm_oa_security_schemes(orm_oa_gen* g):
	orm_api* api = g.api
	json_value* s = json_object()
	if (g.used_session):
		json_object_set(s, c"cookieAuth", orm_oa_api_key(c"cookie", api.session_cookie, c"Session cookie set by logging in."))
		json_object_set(s, c"csrfToken", orm_oa_api_key(c"header", api.csrf_header, c"CSRF token; required with the session cookie on POST, PUT, PATCH and DELETE."))
	if (g.used_token):
		char* desc = orm_rest_concat3(c"Token-based authentication with required prefix \"", api.token_prefix, c"\".")
		json_object_set(s, c"tokenAuth", orm_oa_api_key(c"header", api.token_header, desc))
		free(desc)
	return s


# The component schemas sorted by name (byte order).
json_value* orm_oa_sorted_schemas(orm_oa_gen* g):
	list[int] order = new list[int]
	for i in range(g.schema_names.length):
		int at = order.length
		while (at > 0 && strcmp(g.schema_names[order[at - 1]], g.schema_names[i]) > 0): at = at - 1
		order.insert(at, i)
	json_value* out = json_object()
	for int k in order:
		json_value* v = g.schema_values[k]
		if (v == 0): v = json_object()
		json_object_set(out, g.schema_names[k], v)
	order.free()
	return out


void orm_oa_gen_free(orm_oa_gen* g):
	for orm_api_ser_name* a in g.auto_names:
		free(a.name)
		free(cast(void*, a))
	g.auto_names.free()
	g.schema_names.free()
	g.schema_values.free()
	g.operation_ids.free()
	for char* t in g.tags: free(t)
	g.tags.free()
	for char* s in g.owned: free(s)
	g.owned.free()
	free(cast(void*, g))


# The OpenAPI 3.0.3 document for api (caller frees with json_free).
# Configuration mistakes (a serializer or filter set with an error, a
# history route on a model without history) are reported by
# orm_api_error; the document is still produced.
json_value* orm_openapi_document(orm_api* api):
	if (api.error != 0):
		free(api.error)
		api.error = 0
	orm_oa_gen* g = new orm_oa_gen()
	g.api = api
	g.schema_names = new list[char*]
	g.schema_values = new list[json_value*]
	g.auto_names = new list[orm_api_ser_name*]
	g.operation_ids = new list[char*]
	g.tags = new list[char*]
	g.owned = new list[char*]
	json_value* paths = json_object()
	for orm_api_route* r in api.routes:
		char* prefix = orm_oa_route_name(r)
		char* tag = prefix
		if (r.tag != 0): tag = r.tag
		if (orm_oa_index_of(g.tags, tag) < 0): g.tags.push(strclone(tag))
		orm_oa_collection(g, paths, r, prefix, tag)
		orm_oa_detail(g, paths, r, prefix, tag)
		free(prefix)
	orm_oa_shared_schemas(g)
	json_value* doc = json_object()
	json_object_set(doc, c"openapi", json_string(c"3.0.3"))
	json_value* info = json_object()
	json_object_set(info, c"title", json_string(api.title))
	json_object_set(info, c"version", json_string(api.version))
	if (api.description != 0): json_object_set(info, c"description", json_string(api.description))
	json_object_set(doc, c"info", info)
	json_value* tags = json_array()
	for char* t in g.tags:
		json_value* to = json_object()
		json_object_set(to, c"name", json_string(t))
		json_array_push(tags, to)
	json_object_set(doc, c"tags", tags)
	json_object_set(doc, c"paths", paths)
	json_value* comp = json_object()
	json_object_set(comp, c"schemas", orm_oa_sorted_schemas(g))
	json_value* responses = orm_oa_responses(g)
	if (responses.object_values.length > 0): json_object_set(comp, c"responses", responses)
	else: json_free(responses)
	json_value* schemes = orm_oa_security_schemes(g)
	if (schemes.object_values.length > 0): json_object_set(comp, c"securitySchemes", schemes)
	else: json_free(schemes)
	json_object_set(doc, c"components", comp)
	orm_oa_gen_free(g)
	return doc


# ---------------------------------------------------------------------------
# Pretty printing (two-space indent, keys in insertion order, a trailing
# newline), so documents diff well and goldens stay readable.

void orm_oa_indent(string_builder* s, int depth):
	for i in range(depth):
		string_append(s, c"  ")


void orm_oa_pretty(string_builder* s, json_value* v, int depth):
	if (v != 0 && v.type == json_type_object()):
		if (v.object_values.length == 0):
			string_append(s, c"{}")
			return
		string_append(s, c"{\n")
		int first = 1
		for char* key, json_value* member in v.object_values:
			if (first == 0): string_append(s, c",\n")
			first = 0
			orm_oa_indent(s, depth + 1)
			json_append_escaped_string(s, key)
			string_append(s, c": ")
			orm_oa_pretty(s, member, depth + 1)
		string_append_char(s, '\n')
		orm_oa_indent(s, depth)
		string_append_char(s, '}')
		return
	if (v != 0 && v.type == json_type_array()):
		if (v.array_values.length == 0):
			string_append(s, c"[]")
			return
		string_append(s, c"[\n")
		for i in range(v.array_values.length):
			if (i > 0): string_append(s, c",\n")
			orm_oa_indent(s, depth + 1)
			orm_oa_pretty(s, v.array_values[i], depth + 1)
		string_append_char(s, '\n')
		orm_oa_indent(s, depth)
		string_append_char(s, ']')
		return
	json_append_value(s, v)


# Owned pretty JSON text of any JSON value.
char* orm_json_pretty(json_value* v):
	string_builder* s = string_new()
	orm_oa_pretty(s, v, 0)
	string_append_char(s, '\n')
	char* out = s.data
	free(s)
	return out


# Owned pretty JSON text of the document (what /openapi.json serves).
char* orm_openapi_render(orm_api* api):
	json_value* doc = orm_openapi_document(api)
	char* text = orm_json_pretty(doc)
	json_free(doc)
	return text
