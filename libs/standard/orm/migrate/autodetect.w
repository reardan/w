# w-orm migration autodetector (issue #754, unit U2.2).
#
# orm_autodetect diffs a replayed state (state.w) against a new generator
# snapshot (U1.1) and returns orm_change intents for the planner
# (planner.w); orm_makemigrations runs the planner on them and returns the
# migrations to write (writer.w). docs/projects/orm/u2_2.md lists every
# rule; the short version:
#
# - tables match by SQL table name, columns by SQL column name; renames
#   are never guessed, only taken from hints ("table.old->new" for a
#   column, "old->new" for a table; either side may use model / field
#   names or table / column names);
# - additive changes map to planner kinds (create_table, add_column,
#   alter_null, add_index, add_unique, add_fk, add_check, rename_column,
#   rename_table, drop_column, drop_table);
# - changes the database cannot make in place safely on both dialects
#   (column type, length or precision, pk, FK removal or retarget, removed
#   or changed check, removed unique, removed unnamed index) rebuild the
#   whole table (rebuild_table: shadow table, copy, swap);
# - history flags and named index removals are U2.2's own change kinds
#   (ORM_CHANGE_ADD_HISTORY / DROP_HISTORY / DROP_INDEX), planned here.
import libs.standard.orm.contract
import libs.standard.orm.migrate.planner
import libs.standard.orm.migrate.lint
import libs.standard.orm.migrate.state
import structures.json
import structures.string
import lib.str


# Change kinds beyond planner.w's (the planner rejects these; they are
# planned by orm_makemigrations).
const int ORM_CHANGE_ADD_HISTORY = 101   # table, model_json: CREATE_HISTORY
const int ORM_CHANGE_DROP_HISTORY = 102  # table: empty expand, then DROP_HISTORY
const int ORM_CHANGE_DROP_INDEX = 103    # table, name: DROP_INDEX


struct orm_detect:
	list[orm_change*] changes
	char* error            # set when the diff could not be made (bad JSON, bad hint)
	orm_state* old_state   # expanded old state
	orm_state* new_state   # expanded new snapshot
	list[void*] owned      # strings the detector allocated


struct orm_hint:
	int is_table
	char* old_table        # resolved table names
	char* new_table
	char* old_column       # resolved column names (column hints)
	char* new_column


char* orm_detect_own(orm_detect* d, char* s):
	d.owned.push(cast(void*, s))
	return s


char* orm_detect_cat(orm_detect* d, char* a, char* b, char* c2, char* e):
	string_builder* sb = string_new()
	if (a != 0): string_append(sb, a)
	if (b != 0): string_append(sb, b)
	if (c2 != 0): string_append(sb, c2)
	if (e != 0): string_append(sb, e)
	char* out = sb.data
	free(cast(void*, sb))
	return orm_detect_own(d, out)


int orm_detect_fail(orm_detect* d, char* a, char* b, char* c2):
	if (d.error == 0): d.error = orm_detect_cat(d, a, b, c2, 0)
	return 0


char* orm_detect_json(orm_detect* d, json_value* v):
	return orm_detect_own(d, json_stringify(v))


# ---------------------------------------------------------------------------
# Model / field lookup

json_value* orm_detect_model_by(orm_state* st, char* name_or_table):
	json_value* models = orm_state_models(st)
	for json_value* m in models.array_values:
		if (orm_sj_streq(orm_sj_str(m, c"table"), name_or_table)): return m
	for json_value* m2 in models.array_values:
		if (orm_sj_streq(orm_sj_str(m2, c"name"), name_or_table)): return m2
	return 0


json_value* orm_detect_model_named(orm_state* st, char* name):
	json_value* models = orm_state_models(st)
	for json_value* m in models.array_values:
		if (orm_sj_streq(orm_sj_str(m, c"name"), name)): return m
	return 0


# Column of the field named `name_or_column` (field name first, then column).
char* orm_detect_column_by(json_value* model, char* name_or_column):
	json_value* fields = orm_sj_array(model, c"fields")
	for json_value* f in fields.array_values:
		if (orm_sj_streq(orm_sj_str(f, c"name"), name_or_column) && orm_sj_str(f, c"column") != 0): return orm_sj_str(f, c"column")
	for json_value* f2 in fields.array_values:
		if (orm_sj_streq(orm_sj_str(f2, c"column"), name_or_column)): return orm_sj_str(f2, c"column")
	return 0


# Fields with a database column, in order.
list[json_value*] orm_detect_columns(json_value* model):
	list[json_value*] out = new list[json_value*]
	json_value* fields = orm_sj_array(model, c"fields")
	for json_value* f in fields.array_values:
		if (orm_sj_str(f, c"column") != 0 && orm_sj_int(f, c"kind") != ORM_M2M && orm_sj_int(f, c"kind") != ORM_REVERSE_FK): out.push(f)
	return out


# The table of the model `name` in `st`, or the name itself.
char* orm_detect_rel_table(orm_state* st, char* name):
	json_value* m = orm_detect_model_named(st, name)
	if (m == 0): return name
	return orm_sj_str(m, c"table")


char* orm_detect_pk_column(json_value* model):
	if (model != 0):
		json_value* fields = orm_sj_array(model, c"fields")
		for json_value* f in fields.array_values:
			if (orm_sj_bool(f, c"pk") && orm_sj_str(f, c"column") != 0): return orm_sj_str(f, c"column")
	return c"id"


char* orm_detect_on_delete_sql(char* name):
	if (name == 0): return c"NO ACTION"
	if (strcmp(name, c"cascade") == 0): return c"CASCADE"
	if (strcmp(name, c"protect") == 0 || strcmp(name, c"restrict") == 0): return c"RESTRICT"
	if (strcmp(name, c"set_null") == 0): return c"SET NULL"
	if (strcmp(name, c"set_default") == 0): return c"SET DEFAULT"
	return c"NO ACTION"


# ---------------------------------------------------------------------------
# Hints

int orm_detect_split(char* s, char* sep, char** left, char** right):
	int n = strlen(s)
	int m = strlen(sep)
	int i = 0
	while (i + m <= n):
		if (starts_with_at(s, sep, i)):
			left[0] = str_copy_range(s, 0, i)
			right[0] = str_copy_range(s, i + m, n)
			return 1
		i = i + 1
	return 0


int orm_detect_has_char(char* s, int c):
	int i = 0
	while (s[i] != 0):
		if (s[i] == c): return 1
		i = i + 1
	return 0


# Resolves one hint against the expanded states.
orm_hint* orm_detect_hint(orm_detect* d, char* text):
	char* left = 0
	char* right = 0
	if (orm_detect_split(text, c"->", &left, &right) == 0):
		orm_detect_fail(d, c"bad hint '", text, c"' (expect table.old->new or old->new)")
		return 0
	orm_detect_own(d, left)
	orm_detect_own(d, right)
	orm_hint* h = new orm_hint()
	if (orm_detect_has_char(left, '.') == 0):
		h.is_table = 1
		json_value* om = orm_detect_model_by(d.old_state, left)
		json_value* nm = orm_detect_model_by(d.new_state, right)
		if (om == 0 || nm == 0):
			orm_detect_fail(d, c"hint '", text, c"': unknown table")
			free(cast(void*, h))
			return 0
		h.old_table = orm_sj_str(om, c"table")
		h.new_table = orm_sj_str(nm, c"table")
		if (orm_state_model(d.old_state, h.new_table) != 0):
			orm_detect_fail(d, c"hint '", text, c"': the new table already exists")
			free(cast(void*, h))
			return 0
		return h
	char* table = 0
	char* old = 0
	orm_detect_split(left, c".", &table, &old)
	orm_detect_own(d, table)
	orm_detect_own(d, old)
	json_value* nm2 = orm_detect_model_by(d.new_state, table)
	json_value* om2 = orm_detect_model_by(d.old_state, table)
	if (nm2 == 0 || om2 == 0):
		orm_detect_fail(d, c"hint '", text, c"': unknown table")
		free(cast(void*, h))
		return 0
	h.old_table = orm_sj_str(om2, c"table")
	h.new_table = orm_sj_str(nm2, c"table")
	h.old_column = orm_detect_column_by(om2, old)
	h.new_column = orm_detect_column_by(nm2, right)
	if (h.old_column == 0 || h.new_column == 0):
		orm_detect_fail(d, c"hint '", text, c"': unknown column")
		free(cast(void*, h))
		return 0
	if (orm_state_field(om2, h.new_column) != 0):
		orm_detect_fail(d, c"hint '", text, c"': the new column already exists")
		free(cast(void*, h))
		return 0
	return h


# ---------------------------------------------------------------------------
# Per-table comparison

struct orm_detect_key:
	char* key            # columns joined with ","
	char* name           # index name when known, else 0
	list[char*] columns


struct orm_detect_table:
	orm_detect* d
	char* table
	json_value* om
	json_value* nm
	int rebuild
	char* rebuild_reason
	list[orm_change*] adds        # stage-ordered pending changes
	list[orm_change*] drops       # DROP_COLUMN
	list[orm_change*] extras      # DROP_INDEX
	list[char*] removed           # old columns going away (dropped or renamed)
	list[orm_hint*] renames


void orm_detect_rebuild(orm_detect_table* t, char* reason):
	if (t.rebuild == 0):
		t.rebuild = 1
		t.rebuild_reason = reason


int orm_detect_list_has(list[char*] l, char* s):
	for char* x in l:
		if (orm_sj_streq(x, s)): return 1
	return 0


orm_detect_key* orm_detect_key_new(orm_detect* d, list[char*] columns, char* name):
	orm_detect_key* k = new orm_detect_key()
	k.columns = columns
	k.name = name
	string_builder* sb = string_new()
	for i in range(columns.length):
		if (i > 0): string_append(sb, c",")
		string_append(sb, columns[i])
	k.key = orm_detect_own(d, sb.data)
	free(cast(void*, sb))
	return k


list[char*] orm_detect_json_strings(json_value* arr):
	list[char*] out = new list[char*]
	if (arr == 0): return out
	for json_value* v in arr.array_values:
		if (v.type == json_type_string()): out.push(v.string_value)
	return out


list[char*] orm_detect_one(char* s):
	list[char*] out = new list[char*]
	out.push(s)
	return out


orm_detect_key* orm_detect_find_key(list[orm_detect_key*] keys, char* key):
	for orm_detect_key* k in keys:
		if (orm_sj_streq(k.key, key)): return k
	return 0


void orm_detect_add_key(list[orm_detect_key*] keys, orm_detect_key* k):
	if (orm_detect_find_key(keys, k.key) == 0): keys.push(k)


# Plain (non-unique) indexes: the "indexes" entries plus "indexed" fields.
list[orm_detect_key*] orm_detect_index_keys(orm_detect* d, json_value* m):
	list[orm_detect_key*] keys = new list[orm_detect_key*]
	json_value* idx = orm_sj_array(m, c"indexes")
	for json_value* x in idx.array_values:
		if (orm_sj_bool(x, c"unique")): continue
		orm_detect_add_key(keys, orm_detect_key_new(d, orm_detect_json_strings(orm_sj_array(x, c"columns")), orm_sj_str(x, c"name")))
	for json_value* f in orm_detect_columns(m):
		if (orm_sj_bool(f, c"indexed") == 0 || orm_sj_bool(f, c"unique") || orm_sj_bool(f, c"pk")): continue
		orm_detect_add_key(keys, orm_detect_key_new(d, orm_detect_one(orm_sj_str(f, c"column")), 0))
	return keys


# Unique column sets: unique fields, unique indexes and unique_together.
list[orm_detect_key*] orm_detect_unique_keys(orm_detect* d, json_value* m):
	list[orm_detect_key*] keys = new list[orm_detect_key*]
	for json_value* f in orm_detect_columns(m):
		if (orm_sj_bool(f, c"unique") == 0 || orm_sj_bool(f, c"pk")): continue
		orm_detect_add_key(keys, orm_detect_key_new(d, orm_detect_one(orm_sj_str(f, c"column")), 0))
	json_value* idx = orm_sj_array(m, c"indexes")
	for json_value* x in idx.array_values:
		if (orm_sj_bool(x, c"unique") == 0): continue
		orm_detect_add_key(keys, orm_detect_key_new(d, orm_detect_json_strings(orm_sj_array(x, c"columns")), orm_sj_str(x, c"name")))
	json_value* ut = orm_sj_array(m, c"unique_together")
	for json_value* u in ut.array_values:
		orm_detect_add_key(keys, orm_detect_key_new(d, orm_detect_json_strings(orm_sj_array(u, c"columns")), 0))
	return keys


int orm_detect_key_touches(orm_detect_table* t, orm_detect_key* k):
	for char* c in k.columns:
		if (orm_detect_list_has(t.removed, c)): return 1
	return 0


char* orm_detect_columns_json(orm_detect* d, list[char*] columns):
	json_value* o = json_object()
	json_object_set(o, c"columns", orm_sj_str_array(columns))
	char* out = orm_detect_json(d, o)
	json_free(o)
	return out


char* orm_detect_join(orm_detect* d, list[char*] columns, char* sep):
	string_builder* sb = string_new()
	for i in range(columns.length):
		if (i > 0): string_append(sb, sep)
		string_append(sb, columns[i])
	char* out = sb.data
	free(cast(void*, sb))
	return orm_detect_own(d, out)


# A field json for ADD_COLUMN / RENAME_COLUMN: the snapshot field without
# its unique / indexed flags (those become add_unique / add_index changes).
char* orm_detect_add_field_json(orm_detect* d, json_value* f):
	json_value* c = orm_state_field_normalize(f)
	orm_sj_set_bool(c, c"unique", 0)
	orm_sj_set_bool(c, c"indexed", 0)
	char* out = orm_detect_json(d, c)
	json_free(c)
	return out


char* orm_detect_field_json(orm_detect* d, json_value* f):
	return orm_detect_json(d, f)


# The model json for CREATE_TABLE / RENAME_TABLE / REBUILD_TABLE: the
# snapshot model with history off (CREATE_HISTORY turns it on).
char* orm_detect_model_json(orm_detect* d, json_value* m):
	json_value* c = orm_state_model_normalize(m)
	orm_sj_set_bool(c, c"history", 0)
	char* out = orm_detect_json(d, c)
	json_free(c)
	return out


orm_change* orm_detect_change(int kind, char* table, char* column):
	return orm_change_new(kind, table, column)


# Storage shape that only a rebuild can change: kind (FK counts as int),
# length, precision, pk.
int orm_detect_same_type(json_value* a, json_value* b):
	int ka = orm_sj_int(a, c"kind")
	int kb = orm_sj_int(b, c"kind")
	if (ka == ORM_FK): ka = ORM_INT
	if (kb == ORM_FK): kb = ORM_INT
	if (ka != kb): return 0
	if (orm_sj_int(a, c"max_length") != orm_sj_int(b, c"max_length")): return 0
	if (orm_sj_int(a, c"digits") != orm_sj_int(b, c"digits")): return 0
	if (orm_sj_int(a, c"places") != orm_sj_int(b, c"places")): return 0
	if (orm_sj_bool(a, c"pk") != orm_sj_bool(b, c"pk")): return 0
	return 1


char* orm_detect_fk_sql(orm_detect* d, json_value* f):
	char* target = orm_sj_str(f, c"rel_model")
	char* table = orm_detect_rel_table(d.new_state, target)
	char* pk = orm_detect_pk_column(orm_detect_model_named(d.new_state, target))
	string_builder* sb = string_new()
	string_append(sb, c"FOREIGN KEY (")
	string_append(sb, orm_sj_str(f, c"column"))
	string_append(sb, c") REFERENCES ")
	string_append(sb, table)
	string_append(sb, c" (")
	string_append(sb, pk)
	string_append(sb, c") ON DELETE ")
	string_append(sb, orm_detect_on_delete_sql(orm_sj_str(f, c"on_delete")))
	char* out = sb.data
	free(cast(void*, sb))
	return orm_detect_own(d, out)


void orm_detect_alter_null(orm_detect_table* t, json_value* nf, int nullable):
	orm_change* c = orm_detect_change(ORM_CHANGE_ALTER_NULL, t.table, orm_sj_str(nf, c"column"))
	c.field_json = orm_detect_field_json(t.d, nf)
	c.nullable = nullable
	t.adds.push(c)


void orm_detect_compare_column(orm_detect_table* t, json_value* of, json_value* nf):
	orm_detect* d = t.d
	if (orm_detect_same_type(of, nf) == 0):
		orm_detect_rebuild(t, c"type")
		return
	int ofk = orm_sj_int(of, c"kind") == ORM_FK
	int nfk = orm_sj_int(nf, c"kind") == ORM_FK
	if (ofk):
		if (nfk == 0):
			orm_detect_rebuild(t, c"fk removed")
			return
		char* ot = orm_detect_rel_table(d.old_state, orm_sj_str(of, c"rel_model"))
		char* nt = orm_detect_rel_table(d.new_state, orm_sj_str(nf, c"rel_model"))
		char* oa = orm_detect_on_delete_sql(orm_sj_str(of, c"on_delete"))
		char* na = orm_detect_on_delete_sql(orm_sj_str(nf, c"on_delete"))
		if (orm_sj_streq(ot, nt) == 0 || strcmp(oa, na) != 0):
			orm_detect_rebuild(t, c"fk changed")
			return
	else if (nfk):
		orm_change* fk = orm_detect_change(ORM_CHANGE_ADD_FK, t.table, orm_sj_str(nf, c"column"))
		fk.sql = orm_detect_fk_sql(d, nf)
		t.adds.push(fk)
	int od = orm_sj_bool(of, c"deprecated")
	int nd = orm_sj_bool(nf, c"deprecated")
	if (nd && od == 0): orm_detect_alter_null(t, nf, 1)
	else if (nd == 0 && od): orm_detect_alter_null(t, nf, orm_sj_bool(nf, c"null"))
	else if (nd == 0 && orm_sj_bool(of, c"null") != orm_sj_bool(nf, c"null")): orm_detect_alter_null(t, nf, orm_sj_bool(nf, c"null"))


orm_hint* orm_detect_rename_to(orm_detect_table* t, char* new_column):
	for orm_hint* h in t.renames:
		if (orm_sj_streq(h.new_column, new_column)): return h
	return 0


orm_hint* orm_detect_rename_from(orm_detect_table* t, char* old_column):
	for orm_hint* h in t.renames:
		if (orm_sj_streq(h.old_column, old_column)): return h
	return 0


void orm_detect_columns_diff(orm_detect_table* t):
	orm_detect* d = t.d
	list[json_value*] ncols = orm_detect_columns(t.nm)
	list[json_value*] ocols = orm_detect_columns(t.om)
	for json_value* nf in ncols:
		char* col = orm_sj_str(nf, c"column")
		json_value* of = orm_state_field(t.om, col)
		if (of != 0 && orm_detect_rename_from(t, col) == 0):
			orm_detect_compare_column(t, of, nf)
			continue
		orm_hint* h = orm_detect_rename_to(t, col)
		if (h != 0):
			json_value* src = orm_state_field(t.om, h.old_column)
			if (orm_sj_bool(src, c"pk") || orm_sj_bool(nf, c"pk")): orm_detect_rebuild(t, c"pk rename")
			orm_change* r = orm_detect_change(ORM_CHANGE_RENAME_COLUMN, t.table, h.old_column)
			r.new_name = col
			r.field_json = orm_detect_add_field_json(d, nf)
			r.nullable = orm_sj_bool(nf, c"null")
			t.adds.push(r)
			t.removed.push(h.old_column)
			continue
		if (of != 0):
			# The old column is renamed away by a hint, yet the new schema
			# still has a column of that name.
			orm_detect_fail(d, c"column renamed away but still in the new schema: ", t.table, orm_detect_cat(d, c".", col, 0, 0))
			continue
		if (orm_sj_bool(nf, c"pk")):
			orm_detect_rebuild(t, c"pk added")
			continue
		orm_change* a = orm_detect_change(ORM_CHANGE_ADD_COLUMN, t.table, col)
		a.field_json = orm_detect_add_field_json(d, nf)
		a.nullable = orm_sj_bool(nf, c"null")
		json_value* def = orm_sj_get(nf, c"default")
		a.has_default = def != 0 && def.type != json_type_null()
		t.adds.push(a)
	for json_value* of2 in ocols:
		char* col2 = orm_sj_str(of2, c"column")
		if (orm_state_field(t.nm, col2) != 0 && orm_detect_rename_from(t, col2) == 0): continue
		if (orm_detect_rename_from(t, col2) != 0): continue
		if (orm_sj_bool(of2, c"pk")):
			orm_detect_rebuild(t, c"pk removed")
			continue
		orm_change* dc = orm_detect_change(ORM_CHANGE_DROP_COLUMN, t.table, col2)
		dc.field_json = orm_detect_field_json(d, of2)
		t.drops.push(dc)
		t.removed.push(col2)
	ncols.free()
	ocols.free()


char* orm_detect_strip_table(orm_detect* d, char* table, char* name):
	int n = strlen(table)
	if (name != 0 && starts_with_at(name, table, 0) && name[n] == '_' && name[n + 1] != 0): return orm_detect_own(d, strclone(&name[n + 1]))
	if (name == 0): return c"check"
	return name


void orm_detect_constraints_diff(orm_detect_table* t):
	orm_detect* d = t.d
	# Plain indexes.
	list[orm_detect_key*] oi = orm_detect_index_keys(d, t.om)
	list[orm_detect_key*] ni = orm_detect_index_keys(d, t.nm)
	for orm_detect_key* k in ni:
		orm_detect_key* ok = orm_detect_find_key(oi, k.key)
		if (ok != 0 && orm_detect_key_touches(t, ok) == 0): continue
		orm_change* c = orm_detect_change(ORM_CHANGE_ADD_INDEX, t.table, k.columns[0])
		c.name = k.name
		if (c.name == 0): c.name = orm_detect_cat(d, t.table, c"_", orm_detect_join(d, k.columns, c"_"), c"_idx")
		c.field_json = orm_detect_columns_json(d, k.columns)
		t.adds.push(c)
	for orm_detect_key* k2 in oi:
		if (orm_detect_key_touches(t, k2) || orm_detect_find_key(ni, k2.key) != 0): continue
		if (k2.name == 0):
			orm_detect_rebuild(t, c"unnamed index removed")
			continue
		orm_change* di = orm_detect_change(ORM_CHANGE_DROP_INDEX, t.table, k2.columns[0])
		di.name = k2.name
		t.extras.push(di)
	# Unique sets.
	list[orm_detect_key*] ou = orm_detect_unique_keys(d, t.om)
	list[orm_detect_key*] nu = orm_detect_unique_keys(d, t.nm)
	for orm_detect_key* u in nu:
		orm_detect_key* ou1 = orm_detect_find_key(ou, u.key)
		if (ou1 != 0 && orm_detect_key_touches(t, ou1) == 0): continue
		orm_change* cu = orm_detect_change(ORM_CHANGE_ADD_UNIQUE, t.table, u.columns[0])
		cu.name = orm_detect_cat(d, t.table, c"_", orm_detect_join(d, u.columns, c"_"), c"_uniq")
		cu.field_json = orm_detect_columns_json(d, u.columns)
		t.adds.push(cu)
	for orm_detect_key* u2 in ou:
		if (orm_detect_key_touches(t, u2) || orm_detect_find_key(nu, u2.key) != 0): continue
		orm_detect_rebuild(t, c"unique removed")
	# Checks, by name.
	json_value* och = orm_sj_array(t.om, c"checks")
	json_value* nch = orm_sj_array(t.nm, c"checks")
	for json_value* nc in nch.array_values:
		char* name = orm_sj_str(nc, c"name")
		json_value* match = 0
		for json_value* oc in och.array_values:
			if (orm_sj_streq(orm_sj_str(oc, c"name"), name)): match = oc
		if (match != 0):
			if (orm_sj_streq(orm_sj_str(match, c"sql"), orm_sj_str(nc, c"sql")) == 0): orm_detect_rebuild(t, c"check changed")
			continue
		orm_change* ck = orm_detect_change(ORM_CHANGE_ADD_CHECK, t.table, orm_detect_strip_table(d, t.table, name))
		ck.name = name
		ck.sql = orm_detect_cat(d, c"CHECK (", orm_sj_str(nc, c"sql"), c")", 0)
		t.adds.push(ck)
	for json_value* oc2 in och.array_values:
		int found = 0
		for json_value* nc2 in nch.array_values:
			if (orm_sj_streq(orm_sj_str(oc2, c"name"), orm_sj_str(nc2, c"name"))): found = 1
		if (found == 0): orm_detect_rebuild(t, c"check removed")
	# FK / unique bodies added by hand-written ADD_CONSTRAINTs are not part
	# of any snapshot; a state carrying them would rebuild forever, so they
	# are ignored here.
	oi.free()
	ni.free()
	ou.free()
	nu.free()


# ---------------------------------------------------------------------------
# Whole diff

struct orm_detect_lists:
	list[orm_change*] creates
	list[orm_change*] renames
	list[orm_change*] adds
	list[orm_change*] drops
	list[orm_change*] drop_tables
	list[orm_change*] history
	list[orm_change*] extras


void orm_detect_history(orm_detect* d, orm_detect_lists* L, char* table, json_value* nm, int old_history):
	int nh = orm_sj_bool(nm, c"history")
	if (nh && old_history == 0):
		orm_change* c = orm_detect_change(ORM_CHANGE_ADD_HISTORY, table, 0)
		json_value* copy = orm_state_model_normalize(nm)
		c.model_json = orm_detect_json(d, copy)
		json_free(copy)
		L.history.push(c)
	else if (nh == 0 && old_history):
		L.history.push(orm_detect_change(ORM_CHANGE_DROP_HISTORY, table, 0))


char* orm_detect_renamed_from(list[orm_hint*] hints, char* new_table):
	for orm_hint* h in hints:
		if (h.is_table && orm_sj_streq(h.new_table, new_table)): return h.old_table
	return 0


int orm_detect_renamed_away(list[orm_hint*] hints, char* old_table):
	for orm_hint* h in hints:
		if (h.is_table && orm_sj_streq(h.old_table, old_table)): return 1
	return 0


void orm_detect_table_diff(orm_detect* d, orm_detect_lists* L, list[orm_hint*] hints, json_value* om, json_value* nm):
	orm_detect_table* t = new orm_detect_table()
	t.d = d
	t.table = orm_sj_str(nm, c"table")
	t.om = om
	t.nm = nm
	t.adds = new list[orm_change*]
	t.drops = new list[orm_change*]
	t.extras = new list[orm_change*]
	t.removed = new list[char*]
	t.renames = new list[orm_hint*]
	for orm_hint* h in hints:
		if (h.is_table == 0 && orm_sj_streq(h.new_table, t.table)): t.renames.push(h)
	orm_detect_columns_diff(t)
	orm_detect_constraints_diff(t)
	if (t.rebuild):
		if (t.renames.length > 0):
			orm_detect_fail(d, c"table ", t.table, c" needs a rebuild; a column rename hint cannot be combined with it")
		orm_change* r = orm_detect_change(ORM_CHANGE_REBUILD_TABLE, t.table, 0)
		r.model_json = orm_detect_model_json(d, nm)
		L.adds.push(r)
		# The rebuilt table comes from CREATE_TABLE (history off).
		orm_detect_history(d, L, t.table, nm, 0)
	else:
		for orm_change* a in t.adds: L.adds.push(a)
		for orm_change* dc in t.drops: L.drops.push(dc)
		for orm_change* x in t.extras: L.extras.push(x)
		orm_detect_history(d, L, t.table, nm, orm_sj_bool(om, c"history"))
	t.adds.free()
	t.drops.free()
	t.extras.free()
	t.removed.free()
	t.renames.free()
	free(cast(void*, t))


void orm_detect_push_all(list[orm_change*] out, list[orm_change*] items):
	for orm_change* c in items: out.push(c)
	items.free()


# Diffs `old_state_json` (a state from orm_state_to_json, a snapshot, or
# 0 / "" for an empty database) against `new_snapshot_json` (U1.1's
# <app>_schema_json()). `hints` (may be 0) declares renames:
# "table.old->new" (column) or "old->new" (table). The result's `changes`
# are in planning order: create tables, rename tables, per-table additive
# changes and rebuilds, drop columns, drop tables (reverse dependency
# order), history changes, index drops. Free with orm_detect_free.
orm_detect* orm_autodetect(char* old_state_json, char* new_snapshot_json, list[char*] hints):
	orm_detect* d = new orm_detect()
	d.changes = new list[orm_change*]
	d.owned = new list[void*]
	d.old_state = orm_state_from_json(old_state_json, 0)
	d.new_state = orm_state_from_json(new_snapshot_json, 0)
	if (d.old_state == 0 || d.new_state == 0):
		orm_detect_fail(d, c"invalid schema JSON", 0, 0)
		return d
	orm_state_expand(d.old_state)
	orm_state_expand(d.new_state)
	list[orm_hint*] hs = new list[orm_hint*]
	if (hints != 0):
		for char* text in hints:
			orm_hint* h = orm_detect_hint(d, text)
			if (h != 0): hs.push(h)
	orm_detect_lists* L = new orm_detect_lists()
	L.creates = new list[orm_change*]
	L.renames = new list[orm_change*]
	L.adds = new list[orm_change*]
	L.drops = new list[orm_change*]
	L.drop_tables = new list[orm_change*]
	L.history = new list[orm_change*]
	L.extras = new list[orm_change*]
	if (d.error == 0):
		json_value* nmodels = orm_state_models(d.new_state)
		for json_value* nm in nmodels.array_values:
			char* table = orm_sj_str(nm, c"table")
			char* from = orm_detect_renamed_from(hs, table)
			if (from != 0):
				orm_change* r = orm_detect_change(ORM_CHANGE_RENAME_TABLE, from, 0)
				r.new_name = table
				r.model_json = orm_detect_model_json(d, nm)
				L.renames.push(r)
				orm_detect_history(d, L, table, nm, 0)
				continue
			json_value* om = orm_state_model(d.old_state, table)
			if (om == 0 || orm_detect_renamed_away(hs, table)):
				if (om != 0):
					orm_detect_fail(d, c"table ", table, c" is renamed away but still in the new schema")
					break
				orm_change* c = orm_detect_change(ORM_CHANGE_CREATE_TABLE, table, 0)
				c.model_json = orm_detect_model_json(d, nm)
				L.creates.push(c)
				orm_detect_history(d, L, table, nm, 0)
				continue
			orm_detect_table_diff(d, L, hs, om, nm)
		json_value* omodels = orm_state_models(d.old_state)
		int i = omodels.array_values.length - 1
		while (i >= 0):
			json_value* om2 = omodels.array_values[i]
			char* t2 = orm_sj_str(om2, c"table")
			if (orm_state_model(d.new_state, t2) == 0 && orm_detect_renamed_away(hs, t2) == 0):
				L.drop_tables.push(orm_detect_change(ORM_CHANGE_DROP_TABLE, t2, 0))
			i = i - 1
	orm_detect_push_all(d.changes, L.creates)
	orm_detect_push_all(d.changes, L.renames)
	orm_detect_push_all(d.changes, L.adds)
	orm_detect_push_all(d.changes, L.drops)
	orm_detect_push_all(d.changes, L.drop_tables)
	orm_detect_push_all(d.changes, L.history)
	orm_detect_push_all(d.changes, L.extras)
	free(cast(void*, L))
	for orm_hint* h2 in hs: free(cast(void*, h2))
	hs.free()
	return d


void orm_detect_free(orm_detect* d):
	if (d == 0): return
	for orm_change* c in d.changes: free(cast(void*, c))
	d.changes.free()
	for void* s in d.owned: free(s)
	d.owned.free()
	orm_state_free(d.old_state)
	orm_state_free(d.new_state)
	free(cast(void*, d))


char* orm_change_kind_name(int kind):
	if (kind == ORM_CHANGE_ADD_COLUMN): return c"add_column"
	if (kind == ORM_CHANGE_DROP_COLUMN): return c"drop_column"
	if (kind == ORM_CHANGE_RENAME_COLUMN): return c"rename_column"
	if (kind == ORM_CHANGE_ALTER_TYPE): return c"alter_type"
	if (kind == ORM_CHANGE_ALTER_NULL): return c"alter_null"
	if (kind == ORM_CHANGE_ADD_INDEX): return c"add_index"
	if (kind == ORM_CHANGE_ADD_FK): return c"add_fk"
	if (kind == ORM_CHANGE_ADD_CHECK): return c"add_check"
	if (kind == ORM_CHANGE_ADD_UNIQUE): return c"add_unique"
	if (kind == ORM_CHANGE_RENAME_TABLE): return c"rename_table"
	if (kind == ORM_CHANGE_REBUILD_TABLE): return c"rebuild_table"
	if (kind == ORM_CHANGE_CREATE_TABLE): return c"create_table"
	if (kind == ORM_CHANGE_DROP_TABLE): return c"drop_table"
	if (kind == ORM_CHANGE_ADD_HISTORY): return c"add_history"
	if (kind == ORM_CHANGE_DROP_HISTORY): return c"drop_history"
	if (kind == ORM_CHANGE_DROP_INDEX): return c"drop_index"
	return c"unknown"


# One line per change: "<kind> <table>[.<column>][ -> <new>][ name=<n>]
# [ null|not-null][ default][ sql=\"...\"]". null / not-null print for
# add_column, alter_null and rename_column.
char* orm_detect_describe(orm_detect* d):
	string_builder* b = string_new()
	for orm_change* c in d.changes:
		string_append(b, orm_change_kind_name(c.kind))
		string_append(b, c" ")
		string_append(b, c.table)
		if (c.column != 0 && c.kind != ORM_CHANGE_ADD_CHECK):
			string_append(b, c".")
			string_append(b, c.column)
		if (c.new_name != 0):
			string_append(b, c" -> ")
			string_append(b, c.new_name)
		if (c.name != 0):
			string_append(b, c" name=")
			string_append(b, c.name)
		int k = c.kind
		if (k == ORM_CHANGE_ADD_COLUMN || k == ORM_CHANGE_ALTER_NULL || k == ORM_CHANGE_RENAME_COLUMN):
			if (c.nullable): string_append(b, c" null")
			else: string_append(b, c" not-null")
		if (c.has_default): string_append(b, c" default")
		if (c.sql != 0):
			string_append(b, c" sql=\"")
			string_append(b, c.sql)
			string_append(b, c"\"")
		if (k == ORM_CHANGE_ADD_INDEX || k == ORM_CHANGE_ADD_UNIQUE):
			char* cols = orm_mjson_get(c.field_json, c"columns")
			if (cols != 0):
				string_append(b, c" columns=")
				string_append(b, cols)
				free(cols)
		string_append(b, c"\n")
	char* out = b.data
	free(cast(void*, b))
	return out


# ---------------------------------------------------------------------------
# makemigrations

struct orm_makemig:
	list[orm_migration*] migrations   # the result, in order
	char* error                       # set when nothing could be planned
	orm_detect* detect
	orm_planner* planner
	list[orm_migration*] planned      # the planner's part (freed by orm_planner_free)
	list[orm_migration*] made         # migrations built here
	list[void*] owned


char* orm_makemig_own(orm_makemig* r, char* s):
	r.owned.push(cast(void*, s))
	return s


char* orm_makemig_name(orm_makemig* r, int number, char* rest):
	char* num = itoa(number)
	char* padded = zfill(num, 4)
	free(num)
	string_builder* sb = string_new()
	string_append(sb, padded)
	free(padded)
	string_append(sb, c"_")
	string_append(sb, rest)
	char* out = sb.data
	free(cast(void*, sb))
	return orm_makemig_own(r, out)


orm_migration* orm_makemig_new(orm_makemig* r, char* app, char* name, char* previous, int phase):
	orm_migration* m = orm_migration_new(app, name)
	m.phase = phase
	if (previous != 0):
		if (app != 0):
			string_builder* sb = string_new()
			string_append(sb, app)
			string_append(sb, c".")
			string_append(sb, previous)
			m.dependencies.push(orm_makemig_own(r, sb.data))
			free(cast(void*, sb))
		else: m.dependencies.push(previous)
	r.made.push(m)
	r.migrations.push(m)
	return m


orm_op* orm_makemig_op(orm_migration* m, int kind, int phase, char* table):
	orm_op* op = orm_op_new(kind, phase, table)
	orm_migration_add(m, op)
	return op


# The leading number of a migration name ("0003_x" -> 3), or 0.
int orm_migration_number(char* name):
	int n = 0
	int i = 0
	if (name == 0): return 0
	while (name[i] >= '0' && name[i] <= '9'):
		n = n * 10 + (name[i] - '0')
		i = i + 1
	return n


# Diffs and plans. `dialect_id` picks the planner's PostgreSQL or SQLite
# sequences; `next_number` numbers the first new migration and `previous`
# (may be 0) is the latest existing migration, the first dependency.
# When the old state has no tables the result is a single
# "<NNNN>_initial" migration: every CREATE_TABLE (models in snapshot
# order, then M2M through tables) followed by CREATE_HISTORY for history
# models. Otherwise the planner's migrations come first, then U2.2's own
# kinds: "<NNNN>_expand_<table>_history" (CREATE_HISTORY);
# "<NNNN>_expand_<table>_history" (no op) plus
# "<NNNN>_contract_<table>_history" (DROP_HISTORY, requires the expand);
# "<NNNN>_expand_drop_<index>" (DROP_INDEX). An empty diff gives an empty
# list. Free with orm_makemig_free.
orm_makemig* orm_makemigrations(char* app, char* old_state_json, char* new_snapshot_json, int dialect_id, int next_number, char* previous, list[char*] hints):
	orm_makemig* r = new orm_makemig()
	r.migrations = new list[orm_migration*]
	r.made = new list[orm_migration*]
	r.owned = new list[void*]
	if (next_number < 1): next_number = 1
	orm_detect* d = orm_autodetect(old_state_json, new_snapshot_json, hints)
	r.detect = d
	if (d.error != 0):
		r.error = d.error
		return r
	json_value* old_models = orm_state_models(d.old_state)
	int initial = old_models.array_values.length == 0 && d.changes.length > 0
	for orm_change* c0 in d.changes:
		if (c0.kind != ORM_CHANGE_CREATE_TABLE && c0.kind != ORM_CHANGE_ADD_HISTORY): initial = 0
	if (initial):
		orm_migration* m = orm_makemig_new(r, app, orm_makemig_name(r, next_number, c"initial"), previous, ORM_PHASE_EXPAND)
		for orm_change* c in d.changes:
			if (c.kind != ORM_CHANGE_CREATE_TABLE): continue
			orm_op* op = orm_makemig_op(m, ORM_OP_CREATE_TABLE, ORM_PHASE_EXPAND, c.table)
			op.model_json = c.model_json
		for orm_change* h in d.changes:
			if (h.kind != ORM_CHANGE_ADD_HISTORY): continue
			orm_op* hop = orm_makemig_op(m, ORM_OP_CREATE_HISTORY, ORM_PHASE_EXPAND, h.table)
			hop.model_json = h.model_json
		return r
	list[orm_change*] planned = new list[orm_change*]
	for orm_change* c1 in d.changes:
		if (c1.kind < ORM_CHANGE_ADD_HISTORY): planned.push(c1)
	int number = next_number
	char* prev = previous
	if (planned.length > 0):
		r.planner = orm_planner_new(app, dialect_id, next_number, previous)
		r.planned = orm_plan(r.planner, planned)
		if (r.planned == 0):
			r.error = r.planner.error
			planned.free()
			return r
		for orm_migration* pm in r.planned: r.migrations.push(pm)
		number = r.planner.next_number
		if (r.planned.length > 0): prev = r.planned[r.planned.length - 1].name
	planned.free()
	# U2.2's own kinds: stage 0 of every change, then stage 1.
	list[orm_migration*] firsts = new list[orm_migration*]
	for orm_change* x in d.changes:
		if (x.kind < ORM_CHANGE_ADD_HISTORY): continue
		orm_migration* m1 = 0
		if (x.kind == ORM_CHANGE_ADD_HISTORY):
			m1 = orm_makemig_new(r, app, orm_makemig_name(r, number, orm_makemig_own(r, orm_concat3(c"expand_", x.table, c"_history"))), prev, ORM_PHASE_EXPAND)
			orm_op* ch = orm_makemig_op(m1, ORM_OP_CREATE_HISTORY, ORM_PHASE_EXPAND, x.table)
			ch.model_json = x.model_json
		else if (x.kind == ORM_CHANGE_DROP_HISTORY):
			m1 = orm_makemig_new(r, app, orm_makemig_name(r, number, orm_makemig_own(r, orm_concat3(c"expand_", x.table, c"_history"))), prev, ORM_PHASE_EXPAND)
		else:
			m1 = orm_makemig_new(r, app, orm_makemig_name(r, number, orm_makemig_own(r, orm_concat3(c"expand_drop_", x.name, c""))), prev, ORM_PHASE_EXPAND)
			orm_op* di = orm_makemig_op(m1, ORM_OP_DROP_INDEX, ORM_PHASE_EXPAND, x.table)
			di.name = x.name
		firsts.push(m1)
		prev = m1.name
		number = number + 1
	int i = 0
	for orm_change* y in d.changes:
		if (y.kind < ORM_CHANGE_ADD_HISTORY): continue
		orm_migration* first = firsts[i]
		i = i + 1
		if (y.kind != ORM_CHANGE_DROP_HISTORY): continue
		orm_migration* m2 = orm_makemig_new(r, app, orm_makemig_name(r, number, orm_makemig_own(r, orm_concat3(c"contract_", y.table, c"_history"))), prev, ORM_PHASE_CONTRACT)
		m2.requires_applied = first.name
		orm_makemig_op(m2, ORM_OP_DROP_HISTORY, ORM_PHASE_CONTRACT, y.table)
		prev = m2.name
		number = number + 1
	firsts.free()
	return r


# makemigrations against existing migrations: replays them (an error
# replaying is returned as the result's error), numbers after the highest
# existing number and depends on the last one.
orm_makemig* orm_makemigrations_next(char* app, list[orm_migration*] existing, char* new_snapshot_json, int dialect_id, list[char*] hints):
	orm_state* st = orm_state_from_migrations(app, existing)
	if (st.error != 0):
		orm_makemig* bad = new orm_makemig()
		bad.migrations = new list[orm_migration*]
		bad.made = new list[orm_migration*]
		bad.owned = new list[void*]
		bad.error = orm_makemig_own(bad, strclone(st.error))
		orm_state_free(st)
		return bad
	char* json = orm_state_to_json(st)
	orm_state_free(st)
	int next = 1
	char* previous = 0
	if (existing != 0):
		for orm_migration* m in existing:
			int n = orm_migration_number(m.name)
			if (n + 1 > next): next = n + 1
			previous = m.name
	orm_makemig* r = orm_makemigrations(app, json, new_snapshot_json, dialect_id, next, previous, hints)
	r.owned.push(cast(void*, json))
	return r


void orm_makemig_free(orm_makemig* r):
	if (r == 0): return
	if (r.planner != 0): orm_planner_free(r.planner, r.planned)
	for orm_migration* m in r.made:
		for orm_op* op in m.ops: free(cast(void*, op))
		m.ops.free()
		m.dependencies.free()
		free(cast(void*, m))
	r.made.free()
	r.migrations.free()
	orm_detect_free(r.detect)
	for void* s in r.owned: free(s)
	r.owned.free()
	free(cast(void*, r))
