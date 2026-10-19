# w-orm row loading (unit U1.3, docs/projects/orm/u1_3.md).
#
# Turns an sql_result into model structs or values rows through the C4
# column map, allocating everything from the orm_result (C6).
#
# Row layout: every row the ORM allocates is `struct_size + one word`. The
# trailing word holds an orm_row_meta* (0 until something needs it) with
# the row's annotation values, its prefetch to_attr lists and the owner of
# strings the ORM writes into the row later (save() timestamps, refresh(),
# RETURNING defaults). Rows
# from a result keep their meta in the result's arena; rows from
# orm_row_new keep it on the heap until orm_row_free.
import libs.standard.orm.contract
import libs.standard.sql.values


# Value conversions: thin wrappers over libs/standard/sql/values.w (U0.1).

# Optional sign then decimal digits. Returns 1, or 0 for null/invalid text.
int orm_parse_int(char* text, int* out):
	return sql_parse_int(text, out)


# SQLite stores booleans as 0/1, PostgreSQL returns t/f.
int orm_parse_bool(char* text, int* out):
	return sql_parse_bool(text, out)


# Owned decimal text of v.
char* orm_format_int(int v):
	return sql_format_int(v)


# Decimal text normalized to `places` fractional digits ("12.5" -> "12.50",
# "10" -> "10.00"), so SQLite's numeric affinity and PostgreSQL's NUMERIC
# read back the same. Text that is not a plain decimal is returned as a
# copy unchanged. Owned by r.
char* orm_decimal_text(orm_result* r, char* text, int places):
	int n = strlen(text)
	int dot = -1
	for i in range(n):
		char ch = text[i]
		if (ch == '.'):
			if (dot >= 0): return orm_result_strdup(r, text)
			dot = i
		else if ((ch < '0' || ch > '9') && !(i == 0 && (ch == '-' || ch == '+'))):
			return orm_result_strdup(r, text)
	if (places <= 0): return orm_result_strdup(r, text)
	int have = 0
	int int_len = n
	if (dot >= 0):
		have = n - dot - 1
		int_len = dot
	if (have > places): return orm_result_strdup(r, text)
	char* out = cast(char*, orm_result_alloc(r, int_len + 1 + places + 1))
	for i in range(int_len): out[i] = text[i]
	out[int_len] = '.'
	for i in range(places):
		if (i < have): out[int_len + 1 + i] = text[int_len + 1 + i]
		else: out[int_len + 1 + i] = '0'
	out[int_len + 1 + places] = 0
	return out


# ---------------------------------------------------------------------------
# Row meta: annotations and strings owned on behalf of a row.

struct orm_row_meta:
	orm_result* result           # owning result, 0 for heap rows
	list[void*] owned            # heap rows: strings freed by orm_row_free
	list[char*] ann_names        # annotation names (shared per result)
	list[char*] ann_values       # annotation values, 0 = SQL NULL
	list[char*] attr_names       # prefetch to_attr names (related.w; shared per stitch)
	list[void*] attr_values      # the to_attr lists (list[void*]), owned by the result


# A values()/values_list() row: names are shared by every row of the result;
# values are owned by the result (0 = SQL NULL).
struct orm_values_row:
	list[char*] names
	list[char*] values


int orm_row_alloc_size(orm_model_desc* m):
	return m.struct_size + sizeof(int)


orm_row_meta* orm_row_meta_get(orm_model_desc* m, void* row):
	if (row == 0): return 0
	return cast(orm_row_meta*, orm_slot_get(row, m.struct_size))


void orm_row_meta_set(orm_model_desc* m, void* row, orm_row_meta* meta):
	orm_slot_set(row, m.struct_size, cast(int, meta))


# Takes ownership of `s` (malloc'd) for the lifetime of `row`: freed with
# the row's result, or by orm_row_free for heap rows. Returns s.
char* orm_row_own(orm_model_desc* m, void* row, char* s):
	if (s == 0): return 0
	orm_row_meta* meta = orm_row_meta_get(m, row)
	if (meta == 0):
		meta = new orm_row_meta()
		meta.owned = new list[void*]
		orm_row_meta_set(m, row, meta)
	if (meta.result != 0): meta.result.owned.push(s)
	else: meta.owned.push(s)
	return s


# The annotation `name` of a loaded row, or 0 (absent or SQL NULL).
char* orm_row_annotation(orm_model_desc* m, void* row, char* name):
	orm_row_meta* meta = orm_row_meta_get(m, row)
	if (meta == 0 || meta.ann_names == 0): return 0
	for i in range(meta.ann_names.length):
		if (strcmp(meta.ann_names[i], name) == 0): return meta.ann_values[i]
	return 0


# Integer annotation, `fallback` when absent, NULL or not an integer.
int orm_row_annotation_int(orm_model_desc* m, void* row, char* name, int fallback):
	int v = 0
	if (orm_parse_int(orm_row_annotation(m, row, name), &v)): return v
	return fallback


char* orm_values_get(orm_values_row* row, char* name):
	if (row == 0): return 0
	for i in range(row.names.length):
		if (strcmp(row.names[i], name) == 0): return row.values[i]
	return 0


char* orm_values_at(orm_values_row* row, int index):
	if (row == 0 || index < 0 || index >= row.values.length): return 0
	return row.values[index]


int orm_values_int(orm_values_row* row, char* name, int fallback):
	int v = 0
	if (orm_parse_int(orm_values_get(row, name), &v)): return v
	return fallback


list[orm_values_row*] orm_values_rows(orm_result* r):
	return cast(list[orm_values_row*], r.rows)


# ---------------------------------------------------------------------------
# Field slots

# Zeroed row with empty M2M/reverse lists, owned by r.
void* orm_result_row(orm_result* r, orm_model_desc* m):
	void* row = orm_result_alloc(r, orm_row_alloc_size(m))
	for orm_field_desc* f in m.fields:
		if ((f.kind == ORM_M2M || f.kind == ORM_REVERSE_FK) && f.rel_offset >= 0):
			orm_slot_set(row, f.rel_offset, cast(int, orm_result_list(r)))
	return row


# Stores one database text value (0 = SQL NULL) into the field's slot.
# Text kinds are copied into r. Returns 0 on an unparsable int value.
int orm_load_field(orm_result* r, orm_field_desc* f, void* row, char* text):
	if (orm_field_has_column(f) == 0 || f.offset < 0): return 1
	if (orm_field_is_text_backed(f)):
		char* s = 0
		if (text != 0):
			if (f.kind == ORM_DECIMAL): s = orm_decimal_text(r, text, f.places)
			else: s = orm_result_strdup(r, text)
		orm_slot_set(row, f.offset, cast(int, s))
		return 1
	int v = 0
	int ok = 1
	if (text == 0):
		if (f.null_offset >= 0): orm_slot_set(row, f.null_offset, 1)
	else:
		if (f.kind == ORM_BOOL): ok = orm_parse_bool(text, &v)
		else: ok = orm_parse_int(text, &v)
		if (f.null_offset >= 0): orm_slot_set(row, f.null_offset, 0)
	orm_slot_set(row, f.offset, v)
	return ok


# The object a select_related path names inside `root`, allocating and
# linking missing levels. Returns 0 for a path that does not resolve.
void* orm_load_rel_object(orm_result* r, orm_model_desc* root_model, void* root, char* rel_path, orm_model_desc** model_out):
	orm_model_desc* m = root_model
	void* obj = root
	if (rel_path != 0 && rel_path[0] != 0):
		list[char*] parts = orm_path_split(rel_path)
		for char* part in parts:
			orm_field_desc* f = 0
			if (obj != 0): f = orm_model_field(m, part)
			if (f == 0 || f.kind != ORM_FK || f.rel_offset < 0 || orm_field_target(f) == 0):
				obj = 0
			else:
				orm_model_desc* t = orm_field_target(f)
				void* next = cast(void*, orm_slot_get(obj, f.rel_offset))
				if (next == 0):
					next = orm_result_row(r, t)
					orm_slot_set(obj, f.rel_offset, cast(int, next))
				obj = next
				m = t
			free(part)
		parts.free()
	model_out[0] = m
	return obj


int orm_path_is_prefix(char* prefix, char* path):
	int n = strlen(prefix)
	if (starts_with(path, prefix) == 0): return 0
	return path[n] == 0 || (path[n] == '_' && path[n + 1] == '_')


# A related row whose primary key came back NULL (LEFT JOIN with no match)
# is not linked: its parent's FK pointer stays 0.
int orm_rel_path_is_null(list[orm_column_map*] cols, sql_result* sr, int row, char* rel_path):
	for i in range(cols.length):
		orm_column_map* cm = cols[i]
		if (cm.field != 0 && cm.model != 0 && cm.rel_path != 0 && strcmp(cm.rel_path, rel_path) == 0):
			if (orm_model_pk(cm.model) == cm.field && sql_value(sr, row, i) == 0): return 1
	return 0


void orm_unlink_rel(orm_model_desc* root_model, void* root, char* rel_path):
	list[char*] parts = orm_path_split(rel_path)
	orm_model_desc* m = root_model
	void* obj = root
	for i in range(parts.length):
		if (obj == 0): break
		orm_field_desc* f = orm_model_field(m, parts[i])
		if (f == 0 || f.rel_offset < 0): break
		if (i == parts.length - 1): orm_slot_set(obj, f.rel_offset, 0)
		else:
			obj = cast(void*, orm_slot_get(obj, f.rel_offset))
			m = orm_field_target(f)
	for char* p in parts: free(p)
	parts.free()


char* orm_column_name(orm_column_map* cm):
	if (cm.name != 0): return cm.name
	if (cm.field != 0): return cm.field.name
	return c""


# Loads model rows: columns with a field go to the root struct or the
# select_related object their rel_path names; the rest are annotations.
int orm_load_models(orm_db* db, orm_model_desc* m, orm_compiled* c, sql_result* sr, orm_result* out):
	list[orm_column_map*] cols = c.columns
	if (cols.length != sr.columns):
		return orm_db_set_error(db, c"orm: column map does not match the result")
	list[char*] ann_names = 0
	for i in range(cols.length):
		if (cols[i].field == 0):
			if (ann_names == 0): ann_names = cast(list[char*], orm_result_list(out))
			ann_names.push(orm_column_name(cols[i]))
	list[char*] null_paths = new list[char*]
	int ok = 1
	for row in range(sr.rows):
		void* obj = orm_result_row(out, m)
		orm_row_meta* meta = cast(orm_row_meta*, orm_result_alloc(out, sizeof(orm_row_meta)))
		meta.result = out
		orm_row_meta_set(m, obj, meta)
		if (ann_names != 0):
			meta.ann_names = ann_names
			meta.ann_values = cast(list[char*], orm_result_list(out))
		null_paths.clear()
		for i in range(cols.length):
			orm_column_map* cm = cols[i]
			if (cm.field != 0 && cm.rel_path != 0 && cm.rel_path[0] != 0):
				if (orm_rel_path_is_null(cols, sr, row, cm.rel_path)): null_paths.push(cm.rel_path)
		for i in range(cols.length):
			orm_column_map* cm = cols[i]
			char* text = sql_value(sr, row, i)
			if (cm.field == 0):
				meta.ann_values.push(orm_result_strdup(out, text))
				continue
			int skip = 0
			for char* np in null_paths:
				if (cm.rel_path != 0 && orm_path_is_prefix(np, cm.rel_path)): skip = 1
			if (skip): continue
			orm_model_desc* target_model = 0
			void* target = orm_load_rel_object(out, m, obj, cm.rel_path, &target_model)
			if (target == 0): continue
			if (orm_load_field(out, cm.field, target, text) == 0):
				ok = orm_db_set_error(db, c"orm: invalid integer value in result")
		for char* np in null_paths: orm_unlink_rel(m, obj, np)
		out.rows.push(obj)
	null_paths.free()
	return ok


# The field a plain path ("title", "author__name") names, following FKs
# from m; 0 for anything else.
orm_field_desc* orm_path_field(orm_model_desc* m, char* path):
	if (m == 0 || path == 0): return 0
	list[char*] parts = orm_path_split(path)
	orm_field_desc* out = 0
	for i in range(parts.length):
		if (m == 0): break
		orm_field_desc* fd = orm_model_field(m, parts[i])
		if (fd == 0): break
		if (i == parts.length - 1):
			if (orm_field_has_column(fd)): out = fd
		else if (fd.kind == ORM_FK): m = orm_field_target(fd)
		else: m = 0
	for char* p in parts: free(p)
	parts.free()
	return out


# Loads values()/values_list() rows: one orm_values_row per result row.
# Columns that are plain field paths of q's select list are normalized
# like model fields (booleans as 1/0, decimals to the field's scale); all
# other values are the database's text.
int orm_load_values(orm_db* db, orm_query* q, orm_compiled* c, sql_result* sr, orm_result* out):
	list[char*] names = cast(list[char*], orm_result_list(out))
	list[orm_field_desc*] fields = new list[orm_field_desc*]
	for i in range(sr.columns):
		orm_field_desc* fd = 0
		if (i < c.columns.length):
			names.push(orm_column_name(c.columns[i]))
			fd = c.columns[i].field
		else: names.push(orm_result_strdup(out, sql_column_name(sr, i)))
		if (fd == 0 && q != 0 && i < q.select.length && q.select[i].kind == ORM_E_FIELD):
			fd = orm_path_field(q.model, q.select[i].path)
		fields.push(fd)
	for row in range(sr.rows):
		orm_values_row* vr = cast(orm_values_row*, orm_result_alloc(out, sizeof(orm_values_row)))
		vr.names = names
		vr.values = cast(list[char*], orm_result_list(out))
		for i in range(sr.columns):
			char* text = sql_value(sr, row, i)
			orm_field_desc* fd = fields[i]
			if (text != 0 && fd != 0 && fd.kind == ORM_BOOL):
				int b = 0
				if (orm_parse_bool(text, &b)):
					if (b): text = c"1"
					else: text = c"0"
			if (text != 0 && fd != 0 && fd.kind == ORM_DECIMAL): vr.values.push(orm_decimal_text(out, text, fd.places))
			else: vr.values.push(orm_result_strdup(out, text))
		out.rows.push(vr)
	fields.free()
	return 1


# Loads model rows matching result columns to field columns by name (for
# INSERT/UPDATE ... RETURNING, whose column map may be empty). Columns
# that name no field are ignored.
int orm_load_by_column_name(orm_db* db, orm_model_desc* m, sql_result* sr, orm_result* out):
	int ok = 1
	for row in range(sr.rows):
		void* obj = orm_result_row(out, m)
		orm_row_meta* meta = cast(orm_row_meta*, orm_result_alloc(out, sizeof(orm_row_meta)))
		meta.result = out
		orm_row_meta_set(m, obj, meta)
		for i in range(sr.columns):
			char* col = sql_column_name(sr, i)
			for orm_field_desc* f in m.fields:
				if (orm_field_has_column(f) && strcmp(f.column, col) == 0):
					if (orm_load_field(out, f, obj, sql_value(sr, row, i)) == 0):
						ok = orm_db_set_error(db, c"orm: invalid integer value in result")
		out.rows.push(obj)
	return ok


# Copies one column field from a loaded row into another row, taking
# ownership of copied strings on the destination's behalf.
void orm_copy_field(orm_model_desc* m, orm_field_desc* f, void* dst, void* src):
	if (orm_field_has_column(f) == 0 || f.offset < 0): return
	int v = orm_slot_get(src, f.offset)
	if (orm_field_is_text_backed(f) && v != 0):
		v = cast(int, orm_row_own(m, dst, strclone(cast(char*, v))))
	orm_slot_set(dst, f.offset, v)
	if (f.null_offset >= 0): orm_slot_set(dst, f.null_offset, orm_slot_get(src, f.null_offset))
