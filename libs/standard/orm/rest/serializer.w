# w-orm serializers (unit U3.4, docs/projects/orm/u3_4.md): the DRF
# ModelSerializer equivalent, HTTP-agnostic.
#
# A serializer is built from a model descriptor and then adjusted:
#
#   orm_serializer* s = orm_serializer_new(Book_desc())
#   orm_serializer_exclude(s, c"published_at")
#   orm_serializer_source(s, c"author_name", c"author__name")
#   orm_serializer_nested(s, c"tags", tag_serializer)
#   orm_result* r = orm_serializer_prepare(s, Book_objects(db)).all()
#   char* text = orm_serializer_render_result(s, r)
#
# Output: a row becomes a JSON object (structures/json.w), a result a JSON
# array. Input: orm_serializer_validate parses a JSON object into a new
# row (or onto an existing one), collecting DRF-style errors
# {"field": ["message"]}; orm_validation_save writes it and maps unique,
# FK, NOT NULL and CHECK violations to field errors.
#
# Every relation a serializer reads (source paths, nested serializers,
# pk lists) is declared by the serializer and applied by
# orm_serializer_prepare, so a view cannot forget a select_related.
import libs.standard.orm.orm
import structures.json
import lib.str


const int ORM_SF_FIELD = 1        # a model column (FK as its pk)
const int ORM_SF_SOURCE = 2       # read-only column reached through FKs ("author__name")
const int ORM_SF_NESTED = 3       # nested serializer over an FK (object) or M2M/reverse (array)
const int ORM_SF_ANNOTATION = 4   # value from the row trailer (queryset annotate)
const int ORM_SF_METHOD = 5       # computed by a callback
const int ORM_SF_PK_LIST = 6      # M2M/reverse as an array of target pks

const int ORM_SER_UNKNOWN_REJECT = 0   # unknown input keys are field errors (default)
const int ORM_SER_UNKNOWN_IGNORE = 1   # unknown input keys are ignored (DRF's default)

# (ctx, row) -> owned JSON value (0 = null).
type orm_ser_method_fn = fn(void*, void*) -> json_value*
# (ctx, input value) -> error message (borrowed, copied) or 0 when valid.
type orm_ser_field_validator = fn(void*, json_value*) -> char*
# (ctx, orm_validation*) -> adds errors with orm_validation_add_error.
type orm_ser_object_validator = fn(void*, void*) -> void


struct orm_ser_field:
	char* name                 # output key
	int kind                   # ORM_SF_*
	orm_field_desc* field      # FIELD/NESTED/PK_LIST: the model field; SOURCE: the terminal field
	char* source               # SOURCE: the path
	void* nested               # NESTED: orm_serializer*
	int read_only
	int write_only
	int allow_blank            # TEXT input: accept ""
	int required               # -1 = from the descriptor, else 0/1
	int ann_kind               # ANNOTATION: ORM_* kind of the value, 0 = guess
	orm_ser_method_fn* method
	void* method_ctx
	orm_ser_field_validator* validator
	void* validator_ctx


struct orm_serializer:
	orm_model_desc* model
	list[orm_ser_field*] fields
	int decimal_as_number      # DECIMAL output as JSON numbers instead of strings
	int unknown_policy         # ORM_SER_UNKNOWN_*
	orm_ser_object_validator* validator
	void* validator_ctx
	char* error                # first configuration error, or 0
	list[char*] extra_select_related
	list[char*] extra_prefetch
	list[char*] select_paths   # computed by orm_serializer_paths
	list[char*] prefetch_paths
	int paths_ready
	list[char*] owned          # strings kept alive for querysets


# ---------------------------------------------------------------------------
# Shared helpers (filter.w and pagination.w use these too)

char* orm_rest_concat(char* a, char* b):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	char* out = s.data
	free(s)
	return out


char* orm_rest_concat3(char* a, char* b, char* c):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	string_append(s, c)
	char* out = s.data
	free(s)
	return out


# Appends msg to errors[key] (a JSON array of strings, created on demand).
void orm_rest_error_add(json_value* errors, char* key, char* msg):
	json_value* l = json_object_get(errors, key)
	if (l == 0):
		l = json_array()
		json_object_set(errors, key, l)
	json_array_push(l, json_string(msg))


int orm_rest_errors_empty(json_value* errors):
	return errors == 0 || errors.object_values.length == 0


# {"detail": msg}
json_value* orm_rest_detail(char* msg):
	json_value* o = json_object()
	json_object_set(o, c"detail", json_string(msg))
	return o


# 1 when every byte of text is a decimal digit (optional leading '-').
int orm_rest_parse_int(char* text, int* out):
	return sql_parse_int(text, out)


# A field's value in row as owned text (0 = SQL NULL): ints formatted,
# booleans as 1/0, text kinds copied.
char* orm_rest_field_text(orm_field_desc* fd, void* row):
	if (orm_field_has_column(fd) == 0 || fd.offset < 0): return 0
	if (orm_field_value_is_null(fd, row)): return 0
	int v = orm_slot_get(row, fd.offset)
	if (orm_field_is_text_backed(fd)): return strclone(cast(char*, v))
	if (fd.kind == ORM_BOOL):
		if (v != 0): return strclone(c"1")
		return strclone(c"0")
	return orm_format_int(v)


# Integer text -> JSON int, other numeric text -> JSON float, anything
# else -> JSON string.
json_value* orm_rest_number_json(char* text):
	int v = 0
	if (sql_parse_int(text, &v)): return json_int(v)
	if (sql_decimal_valid(text)):
		json_value* parsed = json_parse(text)
		if (parsed != 0): return parsed
	return json_string(text)


# ---------------------------------------------------------------------------
# Construction

int orm_serializer_fail(orm_serializer* ser, char* a, char* b, char* c):
	if (ser.error != 0): return 0
	string_builder* s = string_new()
	string_append(s, a)
	if (b != 0): string_append(s, b)
	if (c != 0): string_append(s, c)
	ser.error = s.data
	free(s)
	return 0


orm_ser_field* orm_ser_field_new(char* name, int kind, orm_field_desc* fd):
	orm_ser_field* sf = new orm_ser_field()
	sf.name = name
	sf.kind = kind
	sf.field = fd
	sf.required = -1
	return sf


# Read-only by default: auto pks, auto_now(_add) and read-only fields.
int orm_ser_default_read_only(orm_field_desc* fd):
	return (fd.flags & (ORM_F_AUTO | ORM_F_AUTO_NOW | ORM_F_AUTO_NOW_ADD | ORM_F_READ_ONLY)) != 0


# Every column field of m (deprecated ones excluded) in declaration order;
# FKs serialize as the target's pk under the field name ("author": 3).
# M2M and reverse relations are left out: add them with
# orm_serializer_pk_list or orm_serializer_nested.
orm_serializer* orm_serializer_new(orm_model_desc* m):
	orm_serializer* ser = new orm_serializer()
	ser.model = m
	ser.fields = new list[orm_ser_field*]
	ser.extra_select_related = new list[char*]
	ser.extra_prefetch = new list[char*]
	ser.select_paths = new list[char*]
	ser.prefetch_paths = new list[char*]
	ser.owned = new list[char*]
	for orm_field_desc* fd in m.fields:
		if (orm_field_has_column(fd) == 0 || fd.offset < 0): continue
		if ((fd.flags & ORM_F_DEPRECATED) != 0): continue
		orm_ser_field* sf = orm_ser_field_new(fd.name, ORM_SF_FIELD, fd)
		sf.read_only = orm_ser_default_read_only(fd)
		ser.fields.push(sf)
	return ser


# Frees the serializer and its field entries (not nested serializers,
# which the caller owns and may share).
void orm_serializer_free(orm_serializer* ser):
	if (ser == 0): return
	for orm_ser_field* sf in ser.fields: free(cast(void*, sf))
	ser.fields.free()
	for char* s in ser.owned: free(s)
	ser.owned.free()
	ser.extra_select_related.free()
	ser.extra_prefetch.free()
	ser.select_paths.free()
	ser.prefetch_paths.free()
	if (ser.error != 0): free(ser.error)
	free(cast(void*, ser))


char* orm_serializer_error(orm_serializer* ser):
	return ser.error


# The entry with output name `name`, else the entry over model field `name`.
orm_ser_field* orm_serializer_field(orm_serializer* ser, char* name):
	for orm_ser_field* sf in ser.fields:
		if (strcmp(sf.name, name) == 0): return sf
	for orm_ser_field* sf2 in ser.fields:
		if (sf2.field != 0 && sf2.kind != ORM_SF_SOURCE && strcmp(sf2.field.name, name) == 0): return sf2
	return 0


orm_ser_field* orm_serializer_need(orm_serializer* ser, char* name):
	orm_ser_field* sf = orm_serializer_field(ser, name)
	if (sf == 0): orm_serializer_fail(ser, c"serializer: unknown field '", name, c"'")
	return sf


void orm_serializer_changed(orm_serializer* ser):
	ser.paths_ready = 0


# Keeps only `names` (output or model field names), in that order.
orm_serializer* orm_serializer_include(orm_serializer* ser, list[char*] names):
	list[orm_ser_field*] keep = new list[orm_ser_field*]
	for char* n in names:
		orm_ser_field* sf = orm_serializer_need(ser, n)
		if (sf != 0): keep.push(sf)
	for orm_ser_field* old in ser.fields:
		int kept = 0
		for orm_ser_field* k in keep:
			if (k == old): kept = 1
		if (kept == 0): free(cast(void*, old))
	ser.fields.free()
	ser.fields = keep
	orm_serializer_changed(ser)
	return ser


orm_serializer* orm_serializer_exclude(orm_serializer* ser, char* name):
	orm_ser_field* sf = orm_serializer_need(ser, name)
	if (sf == 0): return ser
	for i in range(ser.fields.length):
		if (ser.fields[i] == sf):
			ser.fields.remove(i)
			break
	free(cast(void*, sf))
	orm_serializer_changed(ser)
	return ser


orm_serializer* orm_serializer_read_only(orm_serializer* ser, char* name):
	orm_ser_field* sf = orm_serializer_need(ser, name)
	if (sf != 0): sf.read_only = 1
	return ser


orm_serializer* orm_serializer_write_only(orm_serializer* ser, char* name):
	orm_ser_field* sf = orm_serializer_need(ser, name)
	if (sf != 0):
		if (sf.kind != ORM_SF_FIELD): orm_serializer_fail(ser, c"serializer: only model fields can be write-only ('", name, c"')")
		else:
			sf.write_only = 1
			sf.read_only = 0
	return ser


# Changes the output (and input) key of a field.
orm_serializer* orm_serializer_rename(orm_serializer* ser, char* name, char* out_name):
	orm_ser_field* sf = orm_serializer_need(ser, name)
	if (sf != 0): sf.name = out_name
	return ser


# Overrides whether input must contain the field (create and PUT).
orm_serializer* orm_serializer_required(orm_serializer* ser, char* name, int required):
	orm_ser_field* sf = orm_serializer_need(ser, name)
	if (sf != 0): sf.required = required
	return ser


orm_serializer* orm_serializer_allow_blank(orm_serializer* ser, char* name, int allow):
	orm_ser_field* sf = orm_serializer_need(ser, name)
	if (sf != 0): sf.allow_blank = allow
	return ser


orm_serializer* orm_serializer_decimals_as_numbers(orm_serializer* ser, int on):
	ser.decimal_as_number = on
	return ser


orm_serializer* orm_serializer_unknown_fields(orm_serializer* ser, int policy):
	ser.unknown_policy = policy
	return ser


# Replaces the entry for model field `name` in place, or appends.
void orm_serializer_put(orm_serializer* ser, orm_ser_field* sf):
	for i in range(ser.fields.length):
		orm_ser_field* old = ser.fields[i]
		if (old.kind == ORM_SF_FIELD && old.field == sf.field && sf.field != 0):
			sf.name = old.name
			ser.fields[i] = sf
			free(cast(void*, old))
			orm_serializer_changed(ser)
			return
	ser.fields.push(sf)
	orm_serializer_changed(ser)


# Read-only output `name` = the column at `path`, which must follow FKs
# ("author__name", "author__publisher__country"). The FK prefix is
# select_related by orm_serializer_prepare.
orm_serializer* orm_serializer_source(orm_serializer* ser, char* name, char* path):
	list[char*] parts = orm_path_split(path)
	orm_model_desc* m = ser.model
	orm_field_desc* last = 0
	int ok = parts.length > 0
	for i in range(parts.length):
		if (ok == 0): break
		orm_field_desc* fd = orm_model_field(m, parts[i])
		if (fd == 0):
			ok = orm_serializer_fail(ser, c"serializer: unknown field in source '", path, c"'")
		else if (i == parts.length - 1):
			if (orm_field_has_column(fd) == 0): ok = orm_serializer_fail(ser, c"serializer: source '", path, c"' must end at a column")
			last = fd
		else if (fd.kind != ORM_FK || orm_field_target(fd) == 0):
			ok = orm_serializer_fail(ser, c"serializer: source '", path, c"' may only follow foreign keys (use a nested serializer for many relations)")
		else: m = orm_field_target(fd)
	for char* p in parts: free(p)
	parts.free()
	if (ok == 0): return ser
	orm_ser_field* sf = orm_ser_field_new(name, ORM_SF_SOURCE, last)
	sf.source = path
	sf.read_only = 1
	ser.fields.push(sf)
	orm_serializer_changed(ser)
	return ser


# Nests `child` (a serializer over the target model) under relation
# `field`: an object for an FK (replacing its pk entry), an array for
# M2M/reverse relations. Read-only: nested writes are explicit, as in DRF.
orm_serializer* orm_serializer_nested(orm_serializer* ser, char* field, orm_serializer* child):
	orm_field_desc* fd = orm_model_field(ser.model, field)
	if (fd == 0 || (fd.kind != ORM_FK && fd.kind != ORM_M2M && fd.kind != ORM_REVERSE_FK)):
		orm_serializer_fail(ser, c"serializer: '", field, c"' is not a relation")
		return ser
	if (orm_field_target(fd) == 0 || child.model != orm_field_target(fd)):
		orm_serializer_fail(ser, c"serializer: nested serializer for '", field, c"' is for another model")
		return ser
	orm_ser_field* sf = orm_ser_field_new(field, ORM_SF_NESTED, fd)
	sf.nested = child
	sf.read_only = 1
	orm_serializer_put(ser, sf)
	return ser


# M2M/reverse relation `field` as an array of target pks (prefetched).
orm_serializer* orm_serializer_pk_list(orm_serializer* ser, char* field):
	orm_field_desc* fd = orm_model_field(ser.model, field)
	if (fd == 0 || (fd.kind != ORM_M2M && fd.kind != ORM_REVERSE_FK)):
		orm_serializer_fail(ser, c"serializer: '", field, c"' is not a many relation")
		return ser
	orm_ser_field* sf = orm_ser_field_new(field, ORM_SF_PK_LIST, fd)
	sf.read_only = 1
	ser.fields.push(sf)
	orm_serializer_changed(ser)
	return ser


# Read-only output of a queryset annotation (row trailer), typed by
# `kind` (ORM_INT, ORM_BOOL, ORM_DECIMAL, ORM_FLOAT, ORM_TEXT; 0 = an
# integer when it parses as one, else a string).
orm_serializer* orm_serializer_annotation(orm_serializer* ser, char* name, int kind):
	if (starts_with(name, c"prefetch:")):
		orm_serializer_fail(ser, c"serializer: '", name, c"' is a prefetch to_attr list, not an annotation")
		return ser
	orm_ser_field* sf = orm_ser_field_new(name, ORM_SF_ANNOTATION, 0)
	sf.ann_kind = kind
	sf.read_only = 1
	ser.fields.push(sf)
	return ser


# Read-only output computed by fn(ctx, row) (DRF SerializerMethodField).
orm_serializer* orm_serializer_method(orm_serializer* ser, char* name, orm_ser_method_fn* method, void* ctx):
	orm_ser_field* sf = orm_ser_field_new(name, ORM_SF_METHOD, 0)
	sf.method = method
	sf.method_ctx = ctx
	sf.read_only = 1
	ser.fields.push(sf)
	return ser


# Per-field input check, run after the type checks pass.
orm_serializer* orm_serializer_field_validator(orm_serializer* ser, char* name, orm_ser_field_validator* check, void* ctx):
	orm_ser_field* sf = orm_serializer_need(ser, name)
	if (sf != 0):
		sf.validator = check
		sf.validator_ctx = ctx
	return ser


# Object-level check, run when every field is valid (DRF validate()).
orm_serializer* orm_serializer_validator(orm_serializer* ser, orm_ser_object_validator* check, void* ctx):
	ser.validator = check
	ser.validator_ctx = ctx
	return ser


# Extra relations a method field reads.
orm_serializer* orm_serializer_select_related(orm_serializer* ser, char* path):
	ser.extra_select_related.push(path)
	orm_serializer_changed(ser)
	return ser


orm_serializer* orm_serializer_prefetch_related(orm_serializer* ser, char* path):
	ser.extra_prefetch.push(path)
	orm_serializer_changed(ser)
	return ser


# ---------------------------------------------------------------------------
# Declared relations

# Adds prefix__path to paths once; returns the stored path.
char* orm_ser_path_push(orm_serializer* root, list[char*] paths, char* prefix, char* path):
	char* full = 0
	if (prefix == 0 || prefix[0] == 0): full = strclone(path)
	else: full = orm_rest_concat3(prefix, c"__", path)
	for char* p in paths:
		if (strcmp(p, full) == 0):
			free(full)
			return p
	root.owned.push(full)
	paths.push(full)
	return full


# The FK part of a source path ("author__publisher__name" ->
# "author__publisher"), owned by root; 0 for a local column.
char* orm_ser_source_prefix(orm_serializer* root, char* path):
	int at = rindex_of(path, c"__")
	if (at <= 0): return 0
	char* p = substring(path, 0, at)
	root.owned.push(p)
	return p


# Collects select_related / prefetch_related paths for ser under prefix.
# Below a many relation everything becomes a prefetch path.
void orm_ser_collect(orm_serializer* root, orm_serializer* ser, char* prefix, int in_many):
	list[char*] sel = root.select_paths
	if (in_many): sel = root.prefetch_paths
	for orm_ser_field* sf in ser.fields:
		if (sf.write_only): continue
		if (sf.kind == ORM_SF_SOURCE):
			char* fk = orm_ser_source_prefix(root, sf.source)
			if (fk != 0): orm_ser_path_push(root, sel, prefix, fk)
		else if (sf.kind == ORM_SF_NESTED || sf.kind == ORM_SF_PK_LIST):
			int many = sf.field.kind != ORM_FK
			list[char*] dest = sel
			if (many): dest = root.prefetch_paths
			char* sub = orm_ser_path_push(root, dest, prefix, sf.field.name)
			if (sf.kind == ORM_SF_NESTED):
				orm_ser_collect(root, cast(orm_serializer*, sf.nested), sub, in_many || many)
	for char* x in ser.extra_select_related: orm_ser_path_push(root, sel, prefix, x)
	for char* y in ser.extra_prefetch: orm_ser_path_push(root, root.prefetch_paths, prefix, y)


void orm_serializer_paths(orm_serializer* ser):
	if (ser.paths_ready): return
	ser.select_paths.clear()
	ser.prefetch_paths.clear()
	orm_ser_collect(ser, ser, c"", 0)
	ser.paths_ready = 1


# The select_related paths the serializer reads (owned by ser).
list[char*] orm_serializer_select_paths(orm_serializer* ser):
	orm_serializer_paths(ser)
	return ser.select_paths


list[char*] orm_serializer_prefetch_paths(orm_serializer* ser):
	orm_serializer_paths(ser)
	return ser.prefetch_paths


# qs with every relation the serializer reads applied (select_related for
# FK chains, prefetch_related for many relations). Paths are owned by ser,
# which must outlive the queryset.
orm_queryset* orm_serializer_prepare(orm_serializer* ser, orm_queryset* qs):
	orm_serializer_paths(ser)
	orm_queryset* out = orm_queryset_clone(qs)
	for char* p in ser.select_paths: out = out.select_related(p)
	for char* pf in ser.prefetch_paths:
		int have = 0
		for orm_prefetch* existing in out.query.prefetch:
			if (strcmp(existing.path, pf) == 0): have = 1
		if (have == 0): out = out.prefetch_related(pf)
	return out


# ---------------------------------------------------------------------------
# Output

json_value* orm_serializer_to_json(orm_serializer* ser, void* row);


json_value* orm_ser_value_json(orm_serializer* ser, orm_field_desc* fd, void* row):
	if (row == 0 || orm_field_value_is_null(fd, row)): return json_null()
	int v = orm_slot_get(row, fd.offset)
	int k = fd.kind
	if (k == ORM_BOOL): return json_bool(v)
	if (orm_field_is_text_backed(fd) == 0): return json_int(v)
	char* s = cast(char*, v)
	if (k == ORM_DECIMAL && ser.decimal_as_number): return orm_rest_number_json(s)
	if (k == ORM_FLOAT): return orm_rest_number_json(s)
	if (k == ORM_JSON):
		json_value* parsed = json_parse(s)
		if (parsed != 0): return parsed
	return json_string(s)


# Row-meta entries named "prefetch:<to_attr>" hold prefetch lists (U2.1),
# not text, and are never read here.
json_value* orm_ser_annotation_json(orm_serializer* ser, orm_ser_field* sf, void* row):
	if (starts_with(sf.name, c"prefetch:")): return json_null()
	char* text = orm_row_annotation(ser.model, row, sf.name)
	if (text == 0): return json_null()
	int k = sf.ann_kind
	int v = 0
	if (k == ORM_BOOL && sql_parse_bool(text, &v)): return json_bool(v)
	if ((k == 0 || k == ORM_INT || k == ORM_BIGINT || k == ORM_FK) && sql_parse_int(text, &v)): return json_int(v)
	if (k == ORM_FLOAT || (k == ORM_DECIMAL && ser.decimal_as_number)): return orm_rest_number_json(text)
	return json_string(text)


# The value at a source path, following loaded FK pointers (null when a
# pointer is unset).
json_value* orm_ser_source_json(orm_serializer* ser, orm_ser_field* sf, void* row):
	list[char*] parts = orm_path_split(sf.source)
	orm_model_desc* m = ser.model
	void* obj = row
	json_value* out = 0
	for i in range(parts.length):
		if (obj == 0 || out != 0): continue
		orm_field_desc* fd = orm_model_field(m, parts[i])
		if (i == parts.length - 1): out = orm_ser_value_json(ser, fd, obj)
		else:
			obj = cast(void*, orm_slot_get(obj, fd.rel_offset))
			m = orm_field_target(fd)
	for char* p in parts: free(p)
	parts.free()
	if (out == 0): return json_null()
	return out


json_value* orm_ser_field_json(orm_serializer* ser, orm_ser_field* sf, void* row):
	int k = sf.kind
	if (k == ORM_SF_FIELD): return orm_ser_value_json(ser, sf.field, row)
	if (k == ORM_SF_SOURCE): return orm_ser_source_json(ser, sf, row)
	if (k == ORM_SF_ANNOTATION): return orm_ser_annotation_json(ser, sf, row)
	if (k == ORM_SF_METHOD):
		json_value* mv = sf.method(sf.method_ctx, row)
		if (mv == 0): return json_null()
		return mv
	orm_field_desc* fd = sf.field
	if (fd.rel_offset < 0): return json_null()
	if (k == ORM_SF_NESTED && fd.kind == ORM_FK):
		void* target = cast(void*, orm_slot_get(row, fd.rel_offset))
		if (target == 0): return json_null()
		return orm_serializer_to_json(cast(orm_serializer*, sf.nested), target)
	json_value* arr = json_array()
	list[void*] items = cast(list[void*], orm_slot_get(row, fd.rel_offset))
	if (items == 0): return arr
	orm_model_desc* t = orm_field_target(fd)
	for void* item in items:
		if (k == ORM_SF_NESTED): json_array_push(arr, orm_serializer_to_json(cast(orm_serializer*, sf.nested), item))
		else: json_array_push(arr, json_int(orm_row_pk(t, item)))
	return arr


# One row as a JSON object (caller frees with json_free). Keys follow the
# serializer's field order; write-only fields are left out.
json_value* orm_serializer_to_json(orm_serializer* ser, void* row):
	json_value* o = json_object()
	for orm_ser_field* sf in ser.fields:
		if (sf.write_only): continue
		json_object_set(o, sf.name, orm_ser_field_json(ser, sf, row))
	return o


json_value* orm_serializer_many(orm_serializer* ser, list[void*] rows):
	json_value* arr = json_array()
	if (rows == 0): return arr
	for void* row in rows: json_array_push(arr, orm_serializer_to_json(ser, row))
	return arr


json_value* orm_serializer_result(orm_serializer* ser, orm_result* r):
	if (r == 0): return json_array()
	return orm_serializer_many(ser, r.rows)


char* orm_rest_render(json_value* v):
	char* text = json_stringify(v)
	json_free(v)
	return text


# Owned JSON text of one row / every row of a result.
char* orm_serializer_render(orm_serializer* ser, void* row):
	return orm_rest_render(orm_serializer_to_json(ser, row))


char* orm_serializer_render_result(orm_serializer* ser, orm_result* r):
	return orm_rest_render(orm_serializer_result(ser, r))


# ---------------------------------------------------------------------------
# Input and validation

struct orm_ser_pending:
	orm_field_desc* field
	char* text                 # owned normalized value, 0 = NULL


struct orm_validation:
	orm_serializer* ser
	orm_db* db
	json_value* data           # the input object (owned when parsed here)
	int owns_data
	void* instance             # existing row being updated, or 0
	void* row                  # the written row: instance, or a new row (orm_row_new)
	int created                # row was allocated here; freed by orm_validation_free unless taken
	int partial                # PATCH: absent fields are left alone
	json_value* errors         # {"field": ["message"], "non_field_errors": [...]} or {"detail": ...}
	int status                 # 0 valid, 400 invalid input, 500 database failure
	list[orm_ser_pending*] pending
	list[char*] owned


orm_validation* orm_validation_new(orm_serializer* ser, orm_db* db, void* instance, int partial):
	orm_validation* v = new orm_validation()
	v.ser = ser
	v.db = db
	v.instance = instance
	v.partial = partial
	v.errors = json_object()
	v.pending = new list[orm_ser_pending*]
	v.owned = new list[char*]
	return v


void orm_validation_add_error(orm_validation* v, char* key, char* msg):
	if (key == 0): key = c"non_field_errors"
	orm_rest_error_add(v.errors, key, msg)
	if (v.status == 0): v.status = 400


int orm_validation_ok(orm_validation* v):
	return v.status == 0 && orm_rest_errors_empty(v.errors)


# Owned JSON text of the errors object ("{}" when valid).
char* orm_validation_errors_text(orm_validation* v):
	return json_stringify(v.errors)


# The row a valid validation wrote to; the caller takes ownership of a
# created row (free with orm_row_free).
void* orm_validation_take_row(orm_validation* v):
	v.created = 0
	return v.row


void orm_validation_free(orm_validation* v):
	if (v == 0): return
	for orm_ser_pending* p in v.pending:
		if (p.text != 0): free(p.text)
		free(cast(void*, p))
	v.pending.free()
	for char* s in v.owned: free(s)
	v.owned.free()
	if (v.owns_data): json_free(v.data)
	json_free(v.errors)
	if (v.created && v.row != 0): orm_row_free(v.ser.model, v.row)
	free(cast(void*, v))


orm_ser_pending* orm_validation_pending(orm_validation* v, orm_field_desc* fd):
	for orm_ser_pending* p in v.pending:
		if (p.field == fd): return p
	return 0


# The value field `name` (output or model name) will have: the validated
# input when present, else the instance's current value. Text (0 = NULL)
# owned by v. For object-level validators.
char* orm_validation_get(orm_validation* v, char* name):
	orm_ser_field* sf = orm_serializer_field(v.ser, name)
	orm_field_desc* fd = 0
	if (sf != 0): fd = sf.field
	if (fd == 0): fd = orm_model_field(v.ser.model, name)
	if (fd == 0): return 0
	orm_ser_pending* p = orm_validation_pending(v, fd)
	if (p != 0): return p.text
	void* src = v.row
	if (src == 0): src = v.instance
	if (src == 0): return 0
	char* t = orm_rest_field_text(fd, src)
	if (t != 0): v.owned.push(t)
	return t


char* orm_ser_msg_n(char* a, int n, char* b):
	string_builder* s = string_new()
	string_append(s, a)
	string_append_int(s, n)
	string_append(s, b)
	char* out = s.data
	free(s)
	return out


char* orm_ser_type_name(json_value* jv):
	int t = jv.type
	if (t == json_type_string()): return c"str"
	if (t == json_type_int()): return c"int"
	if (t == json_type_float()): return c"float"
	if (t == json_type_bool()): return c"bool"
	if (t == json_type_object()): return c"dict"
	if (t == json_type_array()): return c"list"
	return c"null"


# JSON number or numeric string -> owned decimal text, else 0.
char* orm_ser_number_text(json_value* jv):
	if (jv.type == json_type_int()): return itoa(jv.int_value)
	if (jv.type == json_type_float()): return json_stringify(jv)
	if (jv.type == json_type_string()): return strclone(jv.string_value)
	return 0


int orm_ser_is_hex(int ch):
	return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')


int orm_ser_uuid_valid(char* s):
	if (strlen(s) != 36): return 0
	for i in range(36):
		int ch = s[i] & 255
		if (i == 8 || i == 13 || i == 18 || i == 23):
			if (ch != '-'): return 0
		else if (orm_ser_is_hex(ch) == 0): return 0
	return 1


# ISO 8601 "YYYY-MM-DDTHH:MM:SS[Z]" stored as "YYYY-MM-DD HH:MM:SS".
char* orm_ser_datetime_text(char* s):
	char* out = strclone(s)
	int n = strlen(out)
	if (n > 10 && (out[10] == 'T' || out[10] == 't')): out[10] = ' '
	if (n > 0 && (out[n - 1] == 'Z' || out[n - 1] == 'z')): out[n - 1] = 0
	return out


# Checks one non-null input value for fd. Returns the owned normalized
# text, or 0 with an owned message in *err.
char* orm_ser_input_text(orm_serializer* ser, orm_ser_field* sf, json_value* jv, char** err):
	orm_field_desc* fd = sf.field
	int k = fd.kind
	int t = jv.type
	err[0] = 0
	if (k == ORM_INT || k == ORM_BIGINT):
		int iv = 0
		if (t == json_type_int()): return itoa(jv.int_value)
		if (t == json_type_string() && sql_parse_int(jv.string_value, &iv)): return itoa(iv)
		err[0] = strclone(c"A valid integer is required.")
		return 0
	if (k == ORM_FK):
		int pk = 0
		if (t == json_type_int()): return itoa(jv.int_value)
		if (t == json_type_string() && sql_parse_int(jv.string_value, &pk)): return itoa(pk)
		err[0] = orm_rest_concat3(c"Incorrect type. Expected pk value, received ", orm_ser_type_name(jv), c".")
		return 0
	if (k == ORM_BOOL):
		int b = 0
		int ok = 0
		if (t == json_type_bool()):
			b = jv.int_value
			ok = 1
		else if (t == json_type_int() && (jv.int_value == 0 || jv.int_value == 1)):
			b = jv.int_value
			ok = 1
		else if (t == json_type_string()): ok = sql_parse_bool(jv.string_value, &b)
		if (ok == 0):
			err[0] = strclone(c"Must be a valid boolean.")
			return 0
		if (b): return strclone(c"1")
		return strclone(c"0")
	if (k == ORM_DECIMAL || k == ORM_FLOAT):
		char* num = orm_ser_number_text(jv)
		if (num == 0 || sql_decimal_valid(num) == 0):
			if (num != 0): free(num)
			err[0] = strclone(c"A valid number is required.")
			return 0
		if (k == ORM_DECIMAL && fd.digits > 0 && sql_decimal_fits(num, fd.digits, fd.places) == 0):
			int whole = 0
			int frac = 0
			sql_decimal_shape(num, strlen(num), &whole, &frac)
			free(num)
			if (whole + frac > fd.digits): err[0] = orm_ser_msg_n(c"Ensure that there are no more than ", fd.digits, c" digits in total.")
			else if (frac > fd.places): err[0] = orm_ser_msg_n(c"Ensure that there are no more than ", fd.places, c" decimal places.")
			else: err[0] = orm_ser_msg_n(c"Ensure that there are no more than ", fd.digits - fd.places, c" digits before the decimal point.")
			return 0
		return num
	if (k == ORM_JSON): return json_stringify(jv)
	if (t != json_type_string()):
		err[0] = strclone(c"Not a valid string.")
		return 0
	char* s = jv.string_value
	if (k == ORM_ENUM):
		for char* choice in fd.enum_values:
			if (strcmp(choice, s) == 0): return strclone(s)
		err[0] = orm_rest_concat3(c"\"", s, c"\" is not a valid choice.")
		return 0
	if (k == ORM_DATETIME):
		datetime dt
		char* norm = orm_ser_datetime_text(s)
		if (sql_parse_datetime(norm, &dt) == 0):
			free(norm)
			err[0] = strclone(c"Datetime has wrong format. Use YYYY-MM-DD HH:MM:SS.")
			return 0
		return norm
	if (k == ORM_DATE):
		date d
		if (strlen(s) != 10 || sql_parse_date(s, &d) == 0):
			err[0] = strclone(c"Date has wrong format. Use YYYY-MM-DD.")
			return 0
		return strclone(s)
	if (k == ORM_UUID):
		if (orm_ser_uuid_valid(s) == 0):
			err[0] = strclone(c"Must be a valid UUID.")
			return 0
		char* u = strclone(s)
		for i in range(36): u[i] = tolower(u[i])
		return u
	if (s[0] == 0 && sf.allow_blank == 0):
		err[0] = strclone(c"This field may not be blank.")
		return 0
	if (fd.max_length > 0 && str_codepoints(s) > fd.max_length):
		err[0] = orm_ser_msg_n(c"Ensure this field has no more than ", fd.max_length, c" characters.")
		return 0
	return strclone(s)


int orm_ser_field_required(orm_ser_field* sf):
	if (sf.required >= 0): return sf.required
	orm_field_desc* fd = sf.field
	if ((fd.flags & ORM_F_NULL) != 0 || fd.default_sql != 0): return 0
	return orm_ser_default_read_only(fd) == 0


# The writable entry for input key `key`; *known is 1 when some entry
# (writable or not) uses that key.
orm_ser_field* orm_ser_input_field(orm_serializer* ser, char* key, int* known):
	known[0] = 0
	for orm_ser_field* sf in ser.fields:
		if (strcmp(sf.name, key) != 0): continue
		known[0] = 1
		if (sf.kind == ORM_SF_FIELD && sf.read_only == 0): return sf
	return 0


# One FK pk must exist on the target model (one query).
void orm_ser_check_fk(orm_validation* v, orm_ser_field* sf, char* text):
	orm_model_desc* t = orm_field_target(sf.field)
	if (t == 0 || v.db == 0): return
	orm_queryset* qs = orm_objects(v.db, t).filter(q_eq(orm_model_pk(t).name, text))
	int found = qs.exists()
	if (found < 0):
		orm_validation_add_error(v, sf.name, orm_db_error(v.db))
		return
	if (found == 0):
		char* msg = orm_rest_concat3(c"Invalid pk \"", text, c"\" - object does not exist.")
		orm_validation_add_error(v, sf.name, msg)
		free(msg)


void orm_ser_validate_value(orm_validation* v, orm_ser_field* sf, json_value* jv):
	orm_field_desc* fd = sf.field
	if (jv.type == json_type_null()):
		if ((fd.flags & ORM_F_NULL) == 0):
			orm_validation_add_error(v, sf.name, c"This field may not be null.")
			return
		orm_ser_pending* np = new orm_ser_pending()
		np.field = fd
		v.pending.push(np)
		return
	char* err = 0
	char* text = orm_ser_input_text(v.ser, sf, jv, &err)
	if (text == 0):
		orm_validation_add_error(v, sf.name, err)
		free(err)
		return
	if (sf.validator != 0):
		char* custom = sf.validator(sf.validator_ctx, jv)
		if (custom != 0):
			orm_validation_add_error(v, sf.name, custom)
			free(text)
			return
	if (fd.kind == ORM_FK):
		int before = v.errors.object_values.length
		orm_ser_check_fk(v, sf, text)
		if (v.errors.object_values.length != before):
			free(text)
			return
	orm_ser_pending* p = new orm_ser_pending()
	p.field = fd
	p.text = text
	v.pending.push(p)


# Stores the pending values into v.row.
void orm_ser_apply(orm_validation* v):
	orm_model_desc* m = v.ser.model
	void* row = v.row
	for orm_ser_pending* p in v.pending:
		orm_field_desc* fd = p.field
		if (orm_field_is_text_backed(fd)):
			orm_slot_set(row, fd.offset, cast(int, orm_row_own(m, row, p.text)))
			p.text = 0
			continue
		int iv = 0
		if (p.text != 0):
			if (fd.kind == ORM_BOOL): sql_parse_bool(p.text, &iv)
			else: sql_parse_int(p.text, &iv)
		if (fd.kind == ORM_FK && fd.rel_offset >= 0 && orm_slot_get(row, fd.offset) != iv): orm_slot_set(row, fd.rel_offset, 0)
		orm_slot_set(row, fd.offset, iv)
		if (fd.null_offset >= 0): orm_slot_set(row, fd.null_offset, p.text == 0)


# Validates `data` (a JSON object, borrowed) against ser. With an
# instance the values are applied onto it (PUT, or PATCH when partial),
# otherwise onto a new row (v.row, freed with v unless taken). Nothing is
# written to the instance unless every check passes. FK values cost one
# existence query each. Never returns 0.
orm_validation* orm_serializer_validate_json(orm_serializer* ser, orm_db* db, json_value* data, void* instance, int partial):
	orm_validation* v = orm_validation_new(ser, db, instance, partial)
	v.data = data
	if (ser.error != 0):
		json_free(v.errors)
		v.errors = orm_rest_detail(ser.error)
		v.status = 500
		return v
	if (data == 0 || data.type != json_type_object()):
		char* got = c"null"
		if (data != 0): got = orm_ser_type_name(data)
		char* msg = orm_rest_concat3(c"Invalid data. Expected a dictionary, but got ", got, c".")
		orm_validation_add_error(v, 0, msg)
		free(msg)
		return v
	for char* key, json_value* member in data.object_values:
		int known = 0
		orm_ser_field* sf = orm_ser_input_field(ser, key, &known)
		if (sf != 0): orm_ser_validate_value(v, sf, member)
		else if (known == 0 && ser.unknown_policy == ORM_SER_UNKNOWN_REJECT): orm_validation_add_error(v, key, c"Unknown field.")
	if (partial == 0):
		for orm_ser_field* rf in ser.fields:
			if (rf.kind != ORM_SF_FIELD || rf.read_only): continue
			if (json_object_has(data, rf.name) == 0 && orm_ser_field_required(rf)):
				orm_validation_add_error(v, rf.name, c"This field is required.")
	if (orm_validation_ok(v) && ser.validator != 0): ser.validator(ser.validator_ctx, v)
	if (orm_validation_ok(v) == 0): return v
	if (instance != 0): v.row = instance
	else:
		v.row = orm_row_new(ser.model)
		v.created = 1
	orm_ser_apply(v)
	return v


# Same, from JSON text. Unparsable text gives {"detail": "JSON parse error."}.
orm_validation* orm_serializer_validate(orm_serializer* ser, orm_db* db, char* text, void* instance, int partial):
	json_value* data = 0
	if (text != 0): data = json_parse(text)
	if (data == 0):
		orm_validation* bad = orm_validation_new(ser, db, instance, partial)
		json_free(bad.errors)
		bad.errors = orm_rest_detail(c"JSON parse error.")
		bad.status = 400
		return bad
	orm_validation* v = orm_serializer_validate_json(ser, db, data, instance, partial)
	v.owns_data = 1
	return v


# ---------------------------------------------------------------------------
# Saving and integrity errors

# Output name for model field fd (its serializer key when present).
char* orm_ser_key_for(orm_serializer* ser, orm_field_desc* fd):
	for orm_ser_field* sf in ser.fields:
		if (sf.field == fd && sf.kind != ORM_SF_SOURCE): return sf.name
	return fd.name


orm_field_desc* orm_ser_field_by_column(orm_model_desc* m, char* column):
	for orm_field_desc* fd in m.fields:
		if (orm_field_has_column(fd) && strcmp(fd.column, column) == 0): return fd
	return 0


# Column names from "t.a, t.b" (SQLite) or "a, b" (PostgreSQL Key (...)),
# up to the first character in `stop`.
list[char*] orm_ser_columns(char* text, char stop):
	list[char*] cols = new list[char*]
	int i = 0
	while (text[i] != 0 && text[i] != stop && text[i] != '\n'):
		while (text[i] == ' ' || text[i] == ','): i = i + 1
		int start = i
		while (text[i] != 0 && text[i] != ',' && text[i] != stop && text[i] != '\n'): i = i + 1
		int end = i
		while (end > start && text[end - 1] == ' '): end = end - 1
		if (end > start):
			char* name = substring(text, start, end)
			int dot = rindex_of(name, c".")
			if (dot >= 0):
				char* bare = strclone(name + dot + 1)
				free(name)
				name = bare
			if (name[0] == '"'):
				char* unq = substring(name, 1, strlen(name) - 1)
				free(name)
				name = unq
			cols.push(name)
	return cols


void orm_ser_free_list(list[char*] l):
	for char* s in l: free(s)
	l.free()


# The text after `marker` in msg, or 0.
char* orm_ser_after(char* msg, char* marker):
	int at = index_of(msg, marker)
	if (at < 0): return 0
	return msg + at + strlen(marker)


# The quoted name after `marker` ("... constraint \"name\""), owned, or 0.
char* orm_ser_quoted_after(char* msg, char* marker):
	char* rest = orm_ser_after(msg, marker)
	if (rest == 0): return 0
	int i = 0
	while (rest[i] == ' '): i = i + 1
	if (rest[i] != '"'): return 0
	int start = i + 1
	int end = start
	while (rest[end] != 0 && rest[end] != '"'): end = end + 1
	return substring(rest, start, end)


char* orm_ser_lower(char* s):
	char* out = strclone(s)
	int n = strlen(out)
	for i in range(n): out[i] = tolower(out[i])
	return out


void orm_ser_unique_error(orm_serializer* ser, json_value* errors, list[char*] cols):
	orm_model_desc* m = ser.model
	if (cols.length == 1):
		orm_field_desc* fd = orm_ser_field_by_column(m, cols[0])
		if (fd != 0):
			char* model = orm_ser_lower(m.name)
			string_builder* s = string_new()
			string_append(s, model)
			string_append(s, c" with this ")
			string_append(s, fd.name)
			string_append(s, c" already exists.")
			orm_rest_error_add(errors, orm_ser_key_for(ser, fd), s.data)
			string_free(s)
			free(model)
			return
	string_builder* msg = string_new()
	string_append(msg, c"The fields ")
	for i in range(cols.length):
		if (i > 0): string_append(msg, c", ")
		orm_field_desc* cf = orm_ser_field_by_column(m, cols[i])
		if (cf != 0): string_append(msg, orm_ser_key_for(ser, cf))
		else: string_append(msg, cols[i])
	string_append(msg, c" must make a unique set.")
	orm_rest_error_add(errors, c"non_field_errors", msg.data)
	string_free(msg)


# SQLite's FK error names no column: probe each FK of the row (one
# existence query each) and report the first missing target.
int orm_ser_probe_fks(orm_db* db, orm_serializer* ser, void* row, json_value* errors):
	for orm_field_desc* fd in ser.model.fields:
		if (fd.kind != ORM_FK || orm_field_value_is_null(fd, row)): continue
		orm_model_desc* t = orm_field_target(fd)
		if (t == 0): continue
		char* id = orm_format_int(orm_slot_get(row, fd.offset))
		int found = orm_objects(db, t).filter(q_eq(orm_model_pk(t).name, id)).exists()
		if (found == 0):
			char* msg = orm_rest_concat3(c"Invalid pk \"", id, c"\" - object does not exist.")
			orm_rest_error_add(errors, orm_ser_key_for(ser, fd), msg)
			free(msg)
			free(id)
			return 1
		free(id)
	return 0


# The single model column an SQL condition mentions, or 0.
orm_field_desc* orm_ser_check_field(orm_model_desc* m, char* condition):
	orm_field_desc* found = 0
	int n = strlen(condition)
	int i = 0
	while (i < n):
		int ch = condition[i] & 255
		if (isalpha(ch) || ch == '_'):
			int start = i
			while (i < n && (isalnum(condition[i]) || condition[i] == '_')): i = i + 1
			char* word = substring(condition, start, i)
			orm_field_desc* fd = orm_ser_field_by_column(m, word)
			free(word)
			if (fd != 0):
				if (found != 0 && found != fd): return 0
				found = fd
		else if (ch == '\''):
			i = i + 1
			while (i < n && condition[i] != '\''): i = i + 1
			i = i + 1
		else: i = i + 1
	return found


# Maps a failed write's database message to a DRF-style error object.
# *status is 400 for constraint violations naming the problem, 500
# otherwise ({"detail": message}).
json_value* orm_serializer_integrity_errors(orm_db* db, orm_serializer* ser, void* row, char* message, int* status):
	json_value* errors = json_object()
	orm_model_desc* m = ser.model
	status[0] = 400
	char* rest = orm_ser_after(message, c"UNIQUE constraint failed: ")
	if (rest == 0): rest = orm_ser_after(message, c"Key (")
	if (rest != 0 && (index_of(message, c"UNIQUE constraint failed") >= 0 || index_of(message, c"duplicate key value") >= 0)):
		list[char*] cols = orm_ser_columns(rest, ')')
		if (cols.length > 0):
			orm_ser_unique_error(ser, errors, cols)
			orm_ser_free_list(cols)
			return errors
		orm_ser_free_list(cols)
	char* nn = orm_ser_after(message, c"NOT NULL constraint failed: ")
	char* nn_col = 0
	if (nn != 0):
		list[char*] ncols = orm_ser_columns(nn, '\n')
		if (ncols.length == 1): nn_col = strclone(ncols[0])
		orm_ser_free_list(ncols)
	else: nn_col = orm_ser_quoted_after(message, c"null value in column")
	if (nn_col != 0):
		orm_field_desc* nfd = orm_ser_field_by_column(m, nn_col)
		free(nn_col)
		if (nfd != 0):
			orm_rest_error_add(errors, orm_ser_key_for(ser, nfd), c"This field may not be null.")
			return errors
	if (index_of(message, c"FOREIGN KEY constraint failed") >= 0):
		if (orm_ser_probe_fks(db, ser, row, errors)): return errors
		orm_rest_error_add(errors, c"non_field_errors", c"A related object does not exist.")
		return errors
	if (index_of(message, c"violates foreign key constraint") >= 0):
		char* key = orm_ser_after(message, c"Key (")
		if (key != 0):
			list[char*] fcols = orm_ser_columns(key, ')')
			char* value = orm_ser_after(key, c")=(")
			orm_field_desc* ffd = 0
			if (fcols.length == 1): ffd = orm_ser_field_by_column(m, fcols[0])
			orm_ser_free_list(fcols)
			if (ffd != 0 && value != 0):
				int end = 0
				while (value[end] != 0 && value[end] != ')'): end = end + 1
				char* id = substring(value, 0, end)
				char* msg = orm_rest_concat3(c"Invalid pk \"", id, c"\" - object does not exist.")
				orm_rest_error_add(errors, orm_ser_key_for(ser, ffd), msg)
				free(msg)
				free(id)
				return errors
		orm_rest_error_add(errors, c"non_field_errors", c"A related object does not exist.")
		return errors
	char* check = 0
	char* ck = orm_ser_after(message, c"CHECK constraint failed: ")
	if (ck != 0):
		int e = 0
		while (ck[e] != 0 && ck[e] != '\n' && ck[e] != ' '): e = e + 1
		check = substring(ck, 0, e)
	else: check = orm_ser_quoted_after(message, c"violates check constraint")
	if (check != 0):
		char* cmsg = orm_rest_concat3(c"Constraint \"", check, c"\" is violated.")
		char* ckey = c"non_field_errors"
		for orm_check_desc* cd in m.checks:
			if (strcmp(cd.name, check) == 0):
				orm_field_desc* cfd = orm_ser_check_field(m, cd.condition_sql)
				if (cfd != 0): ckey = orm_ser_key_for(ser, cfd)
		orm_rest_error_add(errors, ckey, cmsg)
		free(cmsg)
		free(check)
		return errors
	json_free(errors)
	status[0] = 500
	return orm_rest_detail(message)


# orm_save(row); on failure returns an owned error object (constraint
# violations mapped to the field they name, status 400; anything else
# {"detail": ...}, status 500). Returns 0 on success. status may be 0.
json_value* orm_serializer_save(orm_db* db, orm_serializer* ser, void* row, int* status):
	int st = 0
	json_value* out = 0
	if (orm_save(db, ser.model, row) == 0):
		char* message = strclone(orm_db_error(db))
		out = orm_serializer_integrity_errors(db, ser, row, message, &st)
		free(message)
	if (status != 0): status[0] = st
	return out


# Saves a valid validation's row. Returns 1, or 0 with v.errors/v.status
# describing the failure (invalid input is not written).
int orm_validation_save(orm_validation* v):
	if (orm_validation_ok(v) == 0 || v.row == 0): return 0
	int st = 0
	json_value* errors = orm_serializer_save(v.db, v.ser, v.row, &st)
	if (errors == 0): return 1
	json_free(v.errors)
	v.errors = errors
	v.status = st
	return 0
