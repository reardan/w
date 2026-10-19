# w-orm migration state (issue #754, unit U2.2).
#
# Replays a list of orm_migration (contract C7) into a database schema
# state held in the U1.1 snapshot JSON shape (docs/projects/orm/u1_1.md):
#
#   {"format":"w-orm-schema","version":1,"app":"<app>","models":[<model>,...]}
#
# The state describes tables as the database has them, so it differs from
# a generator snapshot in two ways (docs/projects/orm/u2_2.md):
# - every M2M through table is a model of its own (orm_state_expand adds
#   them to a snapshot so both sides compare the same way);
# - "history" is true only after a CREATE_HISTORY op; CREATE_TABLE alone
#   always leaves it false.
# Fields and models are normalized to the snapshot's full key set in the
# snapshot's key order, so an initial migration replays to exactly the
# expanded snapshot text.
import libs.standard.orm.contract
import libs.standard.orm.migrate.lint
import structures.json
import structures.string
import lib.str


struct orm_state:
	json_value* root        # snapshot-shaped object, owned
	char* error             # first replay error (owned), or 0


int orm_state_json_list_has(json_value* arr, char* s);


# ---------------------------------------------------------------------------
# Small JSON helpers (shared with autodetect.w / writer.w)

json_value* orm_sj_get(json_value* o, char* key):
	if (o == 0 || o.type != json_type_object()): return 0
	return json_object_get(o, key)


# String member, or 0 when absent / not a string.
char* orm_sj_str(json_value* o, char* key):
	json_value* v = orm_sj_get(o, key)
	if (v == 0 || v.type != json_type_string()): return 0
	return v.string_value


int orm_sj_bool(json_value* o, char* key):
	json_value* v = orm_sj_get(o, key)
	if (v == 0): return 0
	if (v.type == json_type_bool() || v.type == json_type_int()): return v.int_value != 0
	return 0


int orm_sj_int(json_value* o, char* key):
	json_value* v = orm_sj_get(o, key)
	if (v == 0): return 0
	if (v.type == json_type_int() || v.type == json_type_bool()): return v.int_value
	return 0


# Array member; 0 when absent or not an array.
json_value* orm_sj_array(json_value* o, char* key):
	json_value* v = orm_sj_get(o, key)
	if (v == 0 || v.type != json_type_array()): return 0
	return v


void orm_sj_set_str(json_value* o, char* key, char* s):
	if (s == 0): json_object_set(o, key, json_null())
	else: json_object_set(o, key, json_string(s))


void orm_sj_set_bool(json_value* o, char* key, int v):
	json_object_set(o, key, json_bool(v))


int orm_sj_streq(char* a, char* b):
	if (a == 0 || b == 0): return a == b
	return strcmp(a, b) == 0


# Removes element i from a JSON array (the element is not freed).
json_value* orm_sj_array_take(json_value* arr, int index):
	json_value* taken = arr.array_values[index]
	list[json_value*] keep = new list[json_value*]
	for i in range(arr.array_values.length):
		if (i != index): keep.push(arr.array_values[i])
	arr.array_values.free()
	arr.array_values = keep
	return taken


# New string a + b + c.
char* orm_concat3(char* a, char* b, char* c):
	string_builder* sb = string_new()
	string_append(sb, a)
	string_append(sb, b)
	string_append(sb, c)
	char* out = sb.data
	free(cast(void*, sb))
	return out


json_value* orm_sj_str_array(list[char*] items):
	json_value* a = json_array()
	for char* s in items: json_array_push(a, json_string(s))
	return a


# ---------------------------------------------------------------------------
# Kind names (the snapshot's "kind_name")

char* orm_state_kind_name(int kind):
	if (kind == ORM_INT): return c"int"
	if (kind == ORM_BIGINT): return c"bigint"
	if (kind == ORM_BOOL): return c"bool"
	if (kind == ORM_TEXT): return c"text"
	if (kind == ORM_DECIMAL): return c"decimal"
	if (kind == ORM_DATETIME): return c"datetime"
	if (kind == ORM_DATE): return c"date"
	if (kind == ORM_UUID): return c"uuid"
	if (kind == ORM_JSON): return c"json"
	if (kind == ORM_FK): return c"fk"
	if (kind == ORM_ENUM): return c"enum"
	if (kind == ORM_M2M): return c"m2m"
	if (kind == ORM_REVERSE_FK): return c"reverse_fk"
	if (kind == ORM_FLOAT): return c"float"
	return c"unknown"


# ---------------------------------------------------------------------------
# Normalization: full key set, snapshot key order

void orm_state_copy_or(json_value* out, json_value* src, char* key, json_value* fallback):
	json_value* v = orm_sj_get(src, key)
	if (v != 0):
		json_free(fallback)
		json_object_set(out, key, json_clone(v))
	else: json_object_set(out, key, fallback)


# Returns a new field object with every snapshot key; missing keys get the
# defaults of a plain NOT NULL column. Unknown keys are dropped.
json_value* orm_state_field_normalize(json_value* src):
	json_value* f = json_object()
	int kind = orm_sj_int(src, c"kind")
	orm_state_copy_or(f, src, c"name", json_null())
	orm_state_copy_or(f, src, c"column", json_null())
	orm_state_copy_or(f, src, c"kind", json_int(kind))
	orm_state_copy_or(f, src, c"kind_name", json_string(orm_state_kind_name(kind)))
	orm_state_copy_or(f, src, c"type", json_string(orm_state_kind_name(kind)))
	json_object_set(f, c"pk", json_bool(orm_sj_bool(src, c"pk")))
	json_object_set(f, c"null", json_bool(orm_sj_bool(src, c"null")))
	json_object_set(f, c"unique", json_bool(orm_sj_bool(src, c"unique")))
	json_object_set(f, c"indexed", json_bool(orm_sj_bool(src, c"indexed")))
	json_object_set(f, c"auto", json_bool(orm_sj_bool(src, c"auto")))
	json_object_set(f, c"auto_now_add", json_bool(orm_sj_bool(src, c"auto_now_add")))
	json_object_set(f, c"auto_now", json_bool(orm_sj_bool(src, c"auto_now")))
	json_object_set(f, c"deprecated", json_bool(orm_sj_bool(src, c"deprecated")))
	json_object_set(f, c"no_history", json_bool(orm_sj_bool(src, c"no_history")))
	json_object_set(f, c"read_only", json_bool(orm_sj_bool(src, c"read_only")))
	json_object_set(f, c"max_length", json_int(orm_sj_int(src, c"max_length")))
	json_object_set(f, c"digits", json_int(orm_sj_int(src, c"digits")))
	json_object_set(f, c"places", json_int(orm_sj_int(src, c"places")))
	orm_state_copy_or(f, src, c"default", json_null())
	orm_state_copy_or(f, src, c"enum", json_null())
	orm_state_copy_or(f, src, c"enum_values", json_array())
	orm_state_copy_or(f, src, c"rel_model", json_null())
	orm_state_copy_or(f, src, c"on_delete", json_null())
	orm_state_copy_or(f, src, c"related_name", json_null())
	orm_state_copy_or(f, src, c"through_table", json_null())
	orm_state_copy_or(f, src, c"through_from", json_null())
	orm_state_copy_or(f, src, c"through_to", json_null())
	orm_state_copy_or(f, src, c"reverse_field", json_null())
	return f


json_value* orm_state_index_normalize(json_value* src):
	json_value* x = json_object()
	orm_state_copy_or(x, src, c"name", json_null())
	orm_state_copy_or(x, src, c"fields", json_array())
	orm_state_copy_or(x, src, c"columns", json_array())
	json_object_set(x, c"unique", json_bool(orm_sj_bool(src, c"unique")))
	orm_state_copy_or(x, src, c"condition", json_null())
	return x


json_value* orm_state_model_normalize(json_value* src):
	json_value* m = json_object()
	orm_state_copy_or(m, src, c"name", json_null())
	orm_state_copy_or(m, src, c"table", json_null())
	json_object_set(m, c"history", json_bool(orm_sj_bool(src, c"history")))
	json_value* fields = json_array()
	json_value* sf = orm_sj_array(src, c"fields")
	if (sf != 0):
		for json_value* f in sf.array_values: json_array_push(fields, orm_state_field_normalize(f))
	json_object_set(m, c"fields", fields)
	json_value* idx = json_array()
	json_value* si = orm_sj_array(src, c"indexes")
	if (si != 0):
		for json_value* x in si.array_values: json_array_push(idx, orm_state_index_normalize(x))
	json_object_set(m, c"indexes", idx)
	orm_state_copy_or(m, src, c"checks", json_array())
	orm_state_copy_or(m, src, c"unique_together", json_array())
	# Constraints added by ADD_CONSTRAINT that have no snapshot key (FK and
	# UNIQUE ... USING INDEX bodies) only appear when present.
	json_value* extra = orm_sj_array(src, c"constraints")
	if (extra != 0 && extra.array_values.length > 0): json_object_set(m, c"constraints", json_clone(extra))
	return m


# ---------------------------------------------------------------------------
# State object

orm_state* orm_state_new(char* app):
	orm_state* st = new orm_state()
	json_value* r = json_object()
	json_object_set(r, c"format", json_string(c"w-orm-schema"))
	json_object_set(r, c"version", json_int(1))
	orm_sj_set_str(r, c"app", app)
	json_object_set(r, c"models", json_array())
	st.root = r
	return st


void orm_state_free(orm_state* st):
	if (st == 0): return
	json_free(st.root)
	if (st.error != 0): free(st.error)
	free(cast(void*, st))


json_value* orm_state_models(orm_state* st):
	return orm_sj_array(st.root, c"models")


int orm_state_fail(orm_state* st, char* a, char* b, char* c2):
	if (st.error != 0): return 0
	string_builder* sb = string_new()
	string_append(sb, a)
	if (b != 0): string_append(sb, b)
	if (c2 != 0): string_append(sb, c2)
	st.error = sb.data
	free(cast(void*, sb))
	return 0


int orm_state_model_index(orm_state* st, char* table):
	json_value* models = orm_state_models(st)
	if (table == 0): return -1
	for i in range(models.array_values.length):
		if (orm_sj_streq(orm_sj_str(models.array_values[i], c"table"), table)): return i
	return -1


json_value* orm_state_model(orm_state* st, char* table):
	int i = orm_state_model_index(st, table)
	if (i < 0): return 0
	json_value* models = orm_state_models(st)
	return models.array_values[i]


int orm_state_field_index(json_value* model, char* column):
	json_value* fields = orm_sj_array(model, c"fields")
	if (fields == 0 || column == 0): return -1
	for i in range(fields.array_values.length):
		if (orm_sj_streq(orm_sj_str(fields.array_values[i], c"column"), column)): return i
	return -1


json_value* orm_state_field(json_value* model, char* column):
	int i = orm_state_field_index(model, column)
	if (i < 0): return 0
	json_value* fields = orm_sj_array(model, c"fields")
	return fields.array_values[i]


# Parses a snapshot (or a previously saved state) into a state. Empty text
# or 0 is the empty state of `app`. Returns 0 on invalid JSON.
orm_state* orm_state_from_json(char* json, char* app):
	if (json == 0 || json[0] == 0): return orm_state_new(app)
	json_value* v = json_parse(json)
	if (v == 0 || v.type != json_type_object()):
		json_free(v)
		return 0
	char* a = orm_sj_str(v, c"app")
	if (a == 0): a = app
	orm_state* st = orm_state_new(a)
	json_value* models = orm_state_models(st)
	json_value* src = orm_sj_array(v, c"models")
	if (src != 0):
		for json_value* m in src.array_values: json_array_push(models, orm_state_model_normalize(m))
	json_free(v)
	return st


char* orm_state_to_json(orm_state* st):
	return json_stringify(st.root)


orm_state* orm_state_clone(orm_state* st):
	orm_state* c = new orm_state()
	c.root = json_clone(st.root)
	return c


# ---------------------------------------------------------------------------
# M2M through tables

# Name of the column's field: "book_id" -> "book".
char* orm_state_fk_name(char* column):
	int n = strlen(column)
	if (n > 3 && column[n - 3] == '_' && column[n - 2] == 'i' && column[n - 1] == 'd'):
		char* out = cast(char*, malloc(n - 2))
		for i in range(n - 3): out[i] = column[i]
		out[n - 3] = 0
		return out
	return strclone(column)


json_value* orm_state_fk_field(char* column, char* rel_model):
	json_value* src = json_object()
	char* name = orm_state_fk_name(column)
	orm_sj_set_str(src, c"name", name)
	free(name)
	orm_sj_set_str(src, c"column", column)
	json_object_set(src, c"kind", json_int(ORM_FK))
	orm_sj_set_str(src, c"type", c"fk")
	orm_sj_set_str(src, c"rel_model", rel_model)
	orm_sj_set_str(src, c"on_delete", c"cascade")
	json_value* f = orm_state_field_normalize(src)
	json_free(src)
	return f


# The model object of an M2M through table:
#   {"name":"<Owner>_<field>","table":<through_table>,"history":false,
#    "fields":[id, <from> fk -> Owner, <to> fk -> Target] (both cascade),
#    "unique_together":[{"fields":[from,to],"columns":[from_id,to_id]}]}
json_value* orm_state_through_model(json_value* owner, json_value* m2m):
	char* table = orm_sj_str(m2m, c"through_table")
	char* from = orm_sj_str(m2m, c"through_from")
	char* to = orm_sj_str(m2m, c"through_to")
	string_builder* nb = string_new()
	string_append(nb, orm_sj_str(owner, c"name"))
	string_append(nb, c"_")
	string_append(nb, orm_sj_str(m2m, c"name"))
	json_value* src = json_object()
	orm_sj_set_str(src, c"name", nb.data)
	string_free(nb)
	orm_sj_set_str(src, c"table", table)
	json_value* m = orm_state_model_normalize(src)
	json_free(src)
	json_value* fields = orm_sj_array(m, c"fields")
	json_value* id = json_object()
	orm_sj_set_str(id, c"name", c"id")
	orm_sj_set_str(id, c"column", c"id")
	json_object_set(id, c"kind", json_int(ORM_INT))
	orm_sj_set_bool(id, c"pk", 1)
	orm_sj_set_bool(id, c"auto", 1)
	json_array_push(fields, orm_state_field_normalize(id))
	json_free(id)
	json_array_push(fields, orm_state_fk_field(from, orm_sj_str(owner, c"name")))
	json_array_push(fields, orm_state_fk_field(to, orm_sj_str(m2m, c"rel_model")))
	json_value* ut = json_object()
	json_value* names = json_array()
	char* fn = orm_state_fk_name(from)
	char* tn = orm_state_fk_name(to)
	json_array_push(names, json_string_take(fn))
	json_array_push(names, json_string_take(tn))
	json_object_set(ut, c"fields", names)
	json_value* cols = json_array()
	json_array_push(cols, json_string(from))
	json_array_push(cols, json_string(to))
	json_object_set(ut, c"columns", cols)
	json_array_push(orm_sj_array(m, c"unique_together"), ut)
	return m


# Appends a through-table model for every M2M field whose through table is
# not a model yet. Idempotent, so it also accepts states.
void orm_state_expand(orm_state* st):
	json_value* models = orm_state_models(st)
	list[json_value*] add = new list[json_value*]
	for json_value* m in models.array_values:
		json_value* fields = orm_sj_array(m, c"fields")
		if (fields == 0): continue
		for json_value* f in fields.array_values:
			if (orm_sj_int(f, c"kind") != ORM_M2M): continue
			char* t = orm_sj_str(f, c"through_table")
			if (t == 0 || orm_state_model_index(st, t) >= 0): continue
			int dup = 0
			for json_value* a in add:
				if (orm_sj_streq(orm_sj_str(a, c"table"), t)): dup = 1
			if (dup == 0): add.push(orm_state_through_model(m, f))
	for json_value* a in add: json_array_push(models, a)
	add.free()


# ---------------------------------------------------------------------------
# Replay

json_value* orm_state_need_model(orm_state* st, orm_op* op, char* table):
	json_value* m = orm_state_model(st, table)
	if (m == 0): orm_state_fail(st, orm_op_kind_name(op.kind), c": unknown table ", table)
	return m


int orm_state_create_table(orm_state* st, orm_op* op):
	json_value* src = 0
	if (op.model_json != 0): src = json_parse(op.model_json)
	if (src == 0 || src.type != json_type_object()):
		json_free(src)
		return orm_state_fail(st, c"CREATE_TABLE: bad model_json for ", op.table, 0)
	json_value* m = orm_state_model_normalize(src)
	json_free(src)
	if (op.table != 0): orm_sj_set_str(m, c"table", op.table)
	orm_sj_set_bool(m, c"history", 0)
	char* table = orm_sj_str(m, c"table")
	if (orm_state_model_index(st, table) >= 0):
		json_free(m)
		return orm_state_fail(st, c"CREATE_TABLE: table exists: ", table, 0)
	json_array_push(orm_state_models(st), m)
	return 1


# Drops index / unique_together entries that mention `column`.
void orm_state_forget_column(json_value* model, char* column):
	json_value* idx = orm_sj_array(model, c"indexes")
	int i = 0
	while (idx != 0 && i < idx.array_values.length):
		if (orm_state_json_list_has(orm_sj_array(idx.array_values[i], c"columns"), column)):
			json_free(orm_sj_array_take(idx, i))
		else: i = i + 1
	json_value* ut = orm_sj_array(model, c"unique_together")
	i = 0
	while (ut != 0 && i < ut.array_values.length):
		if (orm_state_json_list_has(orm_sj_array(ut.array_values[i], c"columns"), column)):
			json_free(orm_sj_array_take(ut, i))
		else: i = i + 1


int orm_state_json_list_has(json_value* arr, char* s):
	if (arr == 0): return 0
	for json_value* v in arr.array_values:
		if (v.type == json_type_string() && orm_sj_streq(v.string_value, s)): return 1
	return 0


int orm_state_add_column(orm_state* st, orm_op* op):
	json_value* m = orm_state_need_model(st, op, op.table)
	if (m == 0): return 0
	json_value* src = 0
	if (op.field_json != 0): src = json_parse(op.field_json)
	if (src == 0 || src.type != json_type_object()):
		json_free(src)
		return orm_state_fail(st, c"ADD_COLUMN: bad field_json for ", op.table, 0)
	json_value* f = orm_state_field_normalize(src)
	json_free(src)
	if (op.column != 0): orm_sj_set_str(f, c"column", op.column)
	char* column = orm_sj_str(f, c"column")
	if (column == 0):
		json_free(f)
		return orm_state_fail(st, c"ADD_COLUMN without a column on ", op.table, 0)
	if (orm_sj_get(f, c"name").type == json_type_null()): orm_sj_set_str(f, c"name", column)
	if (orm_state_field_index(m, column) >= 0):
		json_free(f)
		return orm_state_fail(st, c"ADD_COLUMN: column exists: ", op.table, 0)
	json_array_push(orm_sj_array(m, c"fields"), f)
	return 1


int orm_state_drop_column(orm_state* st, orm_op* op):
	json_value* m = orm_state_need_model(st, op, op.table)
	if (m == 0): return 0
	int i = orm_state_field_index(m, op.column)
	if (i < 0): return orm_state_fail(st, c"DROP_COLUMN: unknown column ", op.column, 0)
	json_free(orm_sj_array_take(orm_sj_array(m, c"fields"), i))
	orm_state_forget_column(m, op.column)
	return 1


# Applies the "null" and "deprecated" keys of field_json to the column.
int orm_state_alter_null(orm_state* st, orm_op* op):
	json_value* m = orm_state_need_model(st, op, op.table)
	if (m == 0): return 0
	char* column = op.column
	json_value* src = 0
	if (op.field_json != 0): src = json_parse(op.field_json)
	if (src == 0 || src.type != json_type_object()):
		json_free(src)
		return orm_state_fail(st, c"ALTER_NULL: bad field_json for ", op.table, 0)
	if (column == 0): column = orm_sj_str(src, c"column")
	json_value* f = orm_state_field(m, column)
	if (f == 0):
		json_free(src)
		return orm_state_fail(st, c"ALTER_NULL: unknown column ", column, 0)
	if (orm_sj_get(src, c"null") != 0): orm_sj_set_bool(f, c"null", orm_sj_bool(src, c"null"))
	if (orm_sj_get(src, c"deprecated") != 0): orm_sj_set_bool(f, c"deprecated", orm_sj_bool(src, c"deprecated"))
	json_free(src)
	return 1


int orm_state_add_index(orm_state* st, orm_op* op):
	json_value* m = orm_state_need_model(st, op, op.table)
	if (m == 0): return 0
	json_value* src = 0
	if (op.field_json != 0): src = json_parse(op.field_json)
	json_value* cols = orm_sj_array(src, c"columns")
	json_value* x = json_object()
	orm_sj_set_str(x, c"name", op.name)
	json_value* names = json_array()
	json_value* columns = json_array()
	if (cols != 0):
		for json_value* c in cols.array_values:
			if (c.type != json_type_string()): continue
			json_array_push(columns, json_string(c.string_value))
			json_value* f = orm_state_field(m, c.string_value)
			char* fname = c.string_value
			if (f != 0 && orm_sj_str(f, c"name") != 0): fname = orm_sj_str(f, c"name")
			json_array_push(names, json_string(fname))
	else if (op.column != 0):
		json_array_push(columns, json_string(op.column))
		json_array_push(names, json_string(op.column))
	json_object_set(x, c"fields", names)
	json_object_set(x, c"columns", columns)
	orm_sj_set_bool(x, c"unique", orm_sj_bool(src, c"unique"))
	json_object_set(x, c"condition", json_null())
	json_free(src)
	json_array_push(orm_sj_array(m, c"indexes"), x)
	return 1


# Removes the named entry from the array; returns 1 when found.
int orm_state_drop_named(json_value* arr, char* name):
	if (arr == 0 || name == 0): return 0
	for i in range(arr.array_values.length):
		if (orm_sj_streq(orm_sj_str(arr.array_values[i], c"name"), name)):
			json_free(orm_sj_array_take(arr, i))
			return 1
	return 0


int orm_state_drop_index(orm_state* st, orm_op* op):
	json_value* models = orm_state_models(st)
	for json_value* m in models.array_values:
		if (op.table != 0 && orm_sj_streq(orm_sj_str(m, c"table"), op.table) == 0): continue
		if (orm_state_drop_named(orm_sj_array(m, c"indexes"), op.name)): return 1
	return orm_state_fail(st, c"DROP_INDEX: unknown index ", op.name, 0)


int orm_state_starts_with(char* s, char* prefix):
	int i = 0
	while (prefix[i] != 0):
		if (s[i] != prefix[i]): return 0
		i = i + 1
	return 1


char* orm_state_slice(char* s, int start, int end):
	char* out = cast(char*, malloc(end - start + 1))
	for i in range(end - start): out[i] = s[start + i]
	out[end - start] = 0
	return out


char* orm_state_on_delete_from_sql(char* action):
	if (strcmp(action, c"CASCADE") == 0): return c"cascade"
	if (strcmp(action, c"RESTRICT") == 0): return c"restrict"
	if (strcmp(action, c"SET NULL") == 0): return c"set_null"
	if (strcmp(action, c"SET DEFAULT") == 0): return c"set_default"
	if (strcmp(action, c"NO ACTION") == 0): return c"do_nothing"
	return 0


# "FOREIGN KEY (<col>) REFERENCES <table> (<pk>)[ ON DELETE <action>]",
# the exact form orm_autodetect writes, turns the column into an FK.
int orm_state_apply_fk(orm_state* st, json_value* m, char* sql):
	char* p1 = c"FOREIGN KEY ("
	int n = strlen(sql)
	int i = strlen(p1)
	int start = i
	while (i < n && sql[i] != ')'): i = i + 1
	char* column = orm_state_slice(sql, start, i)
	char* refs = c") REFERENCES "
	int ok = i < n && orm_state_starts_with(&sql[i], refs)
	char* table = 0
	char* action = 0
	if (ok):
		i = i + strlen(refs)
		start = i
		while (i < n && sql[i] != ' '): i = i + 1
		table = orm_state_slice(sql, start, i)
		while (i < n && sql[i] != ')'): i = i + 1
		if (i < n): i = i + 1
		char* od = c" ON DELETE "
		if (i < n && orm_state_starts_with(&sql[i], od)): action = orm_state_slice(sql, i + strlen(od), n)
	json_value* f = orm_state_field(m, column)
	json_value* target = 0
	if (ok): target = orm_state_model(st, table)
	if (f != 0 && target != 0):
		json_object_set(f, c"kind", json_int(ORM_FK))
		orm_sj_set_str(f, c"kind_name", c"fk")
		orm_sj_set_str(f, c"type", c"fk")
		orm_sj_set_str(f, c"rel_model", orm_sj_str(target, c"name"))
		char* od_name = c"do_nothing"
		if (action != 0 && orm_state_on_delete_from_sql(action) != 0): od_name = orm_state_on_delete_from_sql(action)
		orm_sj_set_str(f, c"on_delete", od_name)
	free(column)
	if (table != 0): free(table)
	if (action != 0): free(action)
	if (f == 0 || target == 0): return 0
	return 1


void orm_state_push_constraint(json_value* m, char* name, char* sql):
	json_value* arr = orm_sj_array(m, c"constraints")
	if (arr == 0):
		arr = json_array()
		json_object_set(m, c"constraints", arr)
	json_value* c = json_object()
	orm_sj_set_str(c, c"name", name)
	orm_sj_set_str(c, c"sql", sql)
	json_array_push(arr, c)


# CHECK (<sql>) becomes a "checks" entry {name, sql}; FOREIGN KEY bodies
# update the column; anything else (UNIQUE USING INDEX ...) is kept in the
# model's "constraints" list so DROP_CONSTRAINT can find it.
int orm_state_add_constraint(orm_state* st, orm_op* op):
	json_value* m = orm_state_need_model(st, op, op.table)
	if (m == 0): return 0
	char* sql = op.sql
	if (sql == 0): return orm_state_fail(st, c"ADD_CONSTRAINT without sql on ", op.table, 0)
	int n = strlen(sql)
	if (orm_state_starts_with(sql, c"CHECK (") && n > 8 && sql[n - 1] == ')'):
		json_value* c = json_object()
		orm_sj_set_str(c, c"name", op.name)
		json_object_set(c, c"sql", json_string_take(orm_state_slice(sql, 7, n - 1)))
		json_array_push(orm_sj_array(m, c"checks"), c)
		return 1
	if (orm_state_starts_with(sql, c"FOREIGN KEY (")): orm_state_apply_fk(st, m, sql)
	if (orm_state_starts_with(sql, c"UNIQUE USING INDEX ")): return 1
	orm_state_push_constraint(m, op.name, sql)
	return 1


int orm_state_drop_constraint(orm_state* st, orm_op* op):
	json_value* m = orm_state_need_model(st, op, op.table)
	if (m == 0): return 0
	if (orm_state_drop_named(orm_sj_array(m, c"checks"), op.name)): return 1
	json_value* cons = orm_sj_array(m, c"constraints")
	if (cons != 0):
		for i in range(cons.array_values.length):
			json_value* c = cons.array_values[i]
			if (orm_sj_streq(orm_sj_str(c, c"name"), op.name) == 0): continue
			char* sql = orm_sj_str(c, c"sql")
			if (sql != 0 && orm_state_starts_with(sql, c"FOREIGN KEY (")):
				json_value* fields = orm_sj_array(m, c"fields")
				for json_value* f in fields.array_values:
					if (orm_sj_int(f, c"kind") != ORM_FK): continue
					char* col = orm_sj_str(f, c"column")
					string_builder* want = string_new()
					string_append(want, c"FOREIGN KEY (")
					string_append(want, col)
					string_append(want, c")")
					int hit = orm_state_starts_with(sql, want.data)
					string_free(want)
					if (hit):
						json_object_set(f, c"kind", json_int(ORM_INT))
						orm_sj_set_str(f, c"kind_name", c"int")
						orm_sj_set_str(f, c"type", c"int")
						json_object_set(f, c"rel_model", json_null())
						json_object_set(f, c"on_delete", json_null())
			json_free(orm_sj_array_take(cons, i))
			if (cons.array_values.length == 0):
				m.object_values.remove(c"constraints")
				json_free(cons)
			return 1
	# PostgreSQL UNIQUE USING INDEX constraints own their index.
	if (orm_state_drop_named(orm_sj_array(m, c"indexes"), op.name)): return 1
	return 1


int orm_state_swap_tables(orm_state* st, orm_op* op):
	int i = orm_state_model_index(st, op.table)
	int j = orm_state_model_index(st, op.source_table)
	if (i < 0): return orm_state_fail(st, c"SWAP_TABLES: unknown table ", op.table, 0)
	if (j < 0): return orm_state_fail(st, c"SWAP_TABLES: unknown table ", op.source_table, 0)
	json_value* models = orm_state_models(st)
	json_value* a = models.array_values[i]
	json_value* b = models.array_values[j]
	orm_sj_set_str(a, c"table", op.source_table)
	orm_sj_set_str(b, c"table", op.table)
	# Keep the original table's list position for the new shape.
	models.array_values[i] = b
	models.array_values[j] = a
	return 1


int orm_state_rename_table(orm_state* st, orm_op* op):
	json_value* m = orm_state_model(st, op.source_table)
	if (m == 0): return orm_state_fail(st, c"RENAME_TABLE: unknown table ", op.source_table, 0)
	if (orm_state_model_index(st, op.table) >= 0): return orm_state_fail(st, c"RENAME_TABLE: table exists: ", op.table, 0)
	orm_sj_set_str(m, c"table", op.table)
	return 1


# Applies one op. Ops that move data only (COPY_*, SYNC triggers, BACKFILL,
# VALIDATE_CONSTRAINT) and RAW_SQL leave the state unchanged. Returns 0
# with st.error set on an op that does not fit the state.
int orm_state_apply_op(orm_state* st, orm_op* op):
	int k = op.kind
	if (k == ORM_OP_CREATE_TABLE): return orm_state_create_table(st, op)
	if (k == ORM_OP_DROP_TABLE):
		int i = orm_state_model_index(st, op.table)
		if (i < 0): return orm_state_fail(st, c"DROP_TABLE: unknown table ", op.table, 0)
		json_free(orm_sj_array_take(orm_state_models(st), i))
		return 1
	if (k == ORM_OP_ADD_COLUMN): return orm_state_add_column(st, op)
	if (k == ORM_OP_DROP_COLUMN): return orm_state_drop_column(st, op)
	if (k == ORM_OP_ALTER_NULL): return orm_state_alter_null(st, op)
	if (k == ORM_OP_ADD_INDEX): return orm_state_add_index(st, op)
	if (k == ORM_OP_DROP_INDEX): return orm_state_drop_index(st, op)
	if (k == ORM_OP_ADD_CONSTRAINT): return orm_state_add_constraint(st, op)
	if (k == ORM_OP_DROP_CONSTRAINT): return orm_state_drop_constraint(st, op)
	if (k == ORM_OP_SWAP_TABLES): return orm_state_swap_tables(st, op)
	if (k == ORM_OP_RENAME_TABLE): return orm_state_rename_table(st, op)
	if (k == ORM_OP_CREATE_HISTORY || k == ORM_OP_DROP_HISTORY):
		json_value* m = orm_state_need_model(st, op, op.table)
		if (m == 0): return 0
		orm_sj_set_bool(m, c"history", k == ORM_OP_CREATE_HISTORY)
		return 1
	return 1


int orm_state_apply_migration(orm_state* st, orm_migration* m):
	for orm_op* op in m.ops:
		if (orm_state_apply_op(st, op) == 0):
			if (m.name != 0 && st.error != 0):
				char* prev = st.error
				string_builder* sb = string_new()
				string_append(sb, m.name)
				string_append(sb, c": ")
				string_append(sb, prev)
				st.error = sb.data
				free(cast(void*, sb))
				free(prev)
			return 0
	return 1


# Replays `migrations` in order from the empty state. On error the state
# reflects the ops before the failing one and st.error names it.
orm_state* orm_state_from_migrations(char* app, list[orm_migration*] migrations):
	orm_state* st = orm_state_new(app)
	if (migrations == 0): return st
	for orm_migration* m in migrations:
		if (orm_state_apply_migration(st, m) == 0): return st
	return st


# The expanded form of a generator snapshot: normalized, with M2M through
# tables added. Returns owned JSON text, or 0 on invalid JSON.
char* orm_state_expand_snapshot(char* snapshot_json):
	orm_state* st = orm_state_from_json(snapshot_json, 0)
	if (st == 0): return 0
	orm_state_expand(st)
	char* out = orm_state_to_json(st)
	orm_state_free(st)
	return out
