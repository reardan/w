# w-orm code generator (issue #754, unit U1.1): turns a parsed orm_schema
# into the data module, the API module and the JSON schema snapshot
# described in docs/projects/orm.md ("Generated code shape") and
# docs/projects/orm/u1_1.md.
import lib.lib
import lib.str
import structures.string
import libs.standard.orm.schema.schema


# ---------------------------------------------------------------------------
# Names

char* orm_codegen_kind_const(int kind):
	if (kind == ORM_SCHEMA_INT): return c"ORM_INT"
	if (kind == ORM_SCHEMA_BIGINT): return c"ORM_BIGINT"
	if (kind == ORM_SCHEMA_BOOL): return c"ORM_BOOL"
	if (kind == ORM_SCHEMA_TEXT): return c"ORM_TEXT"
	if (kind == ORM_SCHEMA_DECIMAL): return c"ORM_DECIMAL"
	if (kind == ORM_SCHEMA_DATETIME): return c"ORM_DATETIME"
	if (kind == ORM_SCHEMA_DATE): return c"ORM_DATE"
	if (kind == ORM_SCHEMA_UUID): return c"ORM_UUID"
	if (kind == ORM_SCHEMA_JSON): return c"ORM_JSON"
	if (kind == ORM_SCHEMA_FK): return c"ORM_FK"
	if (kind == ORM_SCHEMA_ENUM): return c"ORM_ENUM"
	if (kind == ORM_SCHEMA_M2M): return c"ORM_M2M"
	if (kind == ORM_SCHEMA_REVERSE_FK): return c"ORM_REVERSE_FK"
	return c"ORM_FLOAT"


# Snapshot kind names: the C2 constant without ORM_, lower-case.
char* orm_codegen_kind_json(int kind):
	return orm_schema_lower(substring(orm_codegen_kind_const(kind), 4, 64))


char* orm_codegen_on_delete_const(int v):
	if (v == ORM_SCHEMA_CASCADE): return c"ORM_CASCADE"
	if (v == ORM_SCHEMA_PROTECT): return c"ORM_PROTECT"
	if (v == ORM_SCHEMA_RESTRICT): return c"ORM_RESTRICT"
	if (v == ORM_SCHEMA_SET_NULL): return c"ORM_SET_NULL"
	if (v == ORM_SCHEMA_SET_DEFAULT): return c"ORM_SET_DEFAULT"
	return c"ORM_DO_NOTHING"


char* orm_codegen_on_delete_json(int v):
	return orm_schema_lower(substring(orm_codegen_on_delete_const(v), 4, 64))


char* orm_codegen_flag_name(int bit):
	if (bit == ORM_SCHEMA_F_PK): return c"PK"
	if (bit == ORM_SCHEMA_F_NULL): return c"NULL"
	if (bit == ORM_SCHEMA_F_UNIQUE): return c"UNIQUE"
	if (bit == ORM_SCHEMA_F_INDEXED): return c"INDEXED"
	if (bit == ORM_SCHEMA_F_AUTO): return c"AUTO"
	if (bit == ORM_SCHEMA_F_AUTO_NOW_ADD): return c"AUTO_NOW_ADD"
	if (bit == ORM_SCHEMA_F_AUTO_NOW): return c"AUTO_NOW"
	if (bit == ORM_SCHEMA_F_DEPRECATED): return c"DEPRECATED"
	if (bit == ORM_SCHEMA_F_NO_HISTORY): return c"NO_HISTORY"
	return c"READ_ONLY"


void orm_codegen_flags(string_builder* b, int flags):
	if (flags == 0):
		string_append(b, c"0")
		return
	int bit = 1
	int first = 1
	while (bit <= ORM_SCHEMA_F_READ_ONLY):
		if ((flags & bit) != 0):
			if (!first): string_append(b, c" | ")
			string_append(b, c"ORM_F_")
			string_append(b, orm_codegen_flag_name(bit))
			first = 0
		bit = bit * 2


# c"..." literal body: backslash and double quote escaped.
void orm_codegen_wstr(string_builder* b, char* s):
	string_append(b, c"c\"")
	int i = 0
	while (s[i] != 0):
		if (s[i] == '\\' || s[i] == '"'): string_append_char(b, '\\')
		string_append_char(b, s[i])
		i = i + 1
	string_append_char(b, '"')


void orm_codegen_wstr_or_0(string_builder* b, char* s):
	if (s == 0): string_append(b, c"0")
	else:
		orm_codegen_wstr(b, s)


char* orm_codegen_through_table(orm_schema_model* m, orm_schema_field* f):
	return orm_schema_concat3(m.table, c"_", f.name)


char* orm_codegen_through_from(orm_schema_model* m, orm_schema_field* f):
	char* lower = orm_schema_lower(m.name)
	if (orm_schema_streq(f.rel_model, m.name)): return orm_schema_concat3(c"from_", lower, c"_id")
	return orm_schema_concat3(lower, c"_id", c"")


char* orm_codegen_through_to(orm_schema_model* m, orm_schema_field* f):
	char* lower = orm_schema_lower(f.rel_model)
	if (orm_schema_streq(f.rel_model, m.name)): return orm_schema_concat3(c"to_", lower, c"_id")
	return orm_schema_concat3(lower, c"_id", c"")


# 1 when an FK slot can be typed (its target struct is declared earlier).
int orm_codegen_fk_typed(orm_schema* s, orm_schema_model* m, orm_schema_field* f):
	if (orm_schema_streq(f.rel_model, m.name)): return 0
	return orm_schema_ordered_before(s, f.rel_model, m.name)


list[char*] orm_codegen_unique_together_columns(orm_schema_model* m, list[char*] names):
	list[char*] cols = new list[char*]
	for char* n in names:
		orm_schema_field* f = orm_schema_find_field(m, n)
		if (f != 0): cols.push(orm_schema_column(f))
	return cols


# ---------------------------------------------------------------------------
# JSON snapshot

void orm_codegen_json_str(string_builder* b, char* s):
	if (s == 0):
		string_append(b, c"null")
		return
	string_append_char(b, '"')
	int i = 0
	while (s[i] != 0):
		int ch = s[i] & 255
		if (ch == '"' || ch == '\\'):
			string_append_char(b, '\\')
			string_append_char(b, ch)
		else if (ch < 32):
			char* hexdigits = c"0123456789abcdef"
			string_append(b, c"\\u00")
			string_append_char(b, hexdigits[ch / 16])
			string_append_char(b, hexdigits[ch % 16])
		else:
			string_append_char(b, ch)
		i = i + 1
	string_append_char(b, '"')


void orm_codegen_json_key(string_builder* b, char* key):
	string_append_char(b, ',')
	orm_codegen_json_str(b, key)
	string_append_char(b, ':')


void orm_codegen_json_bool(string_builder* b, char* key, int v):
	orm_codegen_json_key(b, key)
	if (v): string_append(b, c"true")
	else:
		string_append(b, c"false")


void orm_codegen_json_int(string_builder* b, char* key, int v):
	orm_codegen_json_key(b, key)
	string_append_int(b, v)


void orm_codegen_json_strkey(string_builder* b, char* key, char* v):
	orm_codegen_json_key(b, key)
	orm_codegen_json_str(b, v)


void orm_codegen_json_list(string_builder* b, list[char*] items):
	string_append_char(b, '[')
	int i = 0
	while (i < items.length):
		if (i > 0): string_append_char(b, ',')
		orm_codegen_json_str(b, items[i])
		i = i + 1
	string_append_char(b, ']')


void orm_codegen_field_json(string_builder* b, orm_schema_model* m, orm_schema_field* f):
	int fl = f.flags
	int fk = f.kind == ORM_SCHEMA_FK
	int m2m = f.kind == ORM_SCHEMA_M2M
	string_append(b, c"{\"name\":")
	orm_codegen_json_str(b, f.name)
	orm_codegen_json_strkey(b, c"column", orm_schema_column(f))
	orm_codegen_json_int(b, c"kind", f.kind)
	orm_codegen_json_strkey(b, c"kind_name", orm_codegen_kind_json(f.kind))
	orm_codegen_json_strkey(b, c"type", f.type_name)
	orm_codegen_json_bool(b, c"pk", (fl & ORM_SCHEMA_F_PK) != 0)
	orm_codegen_json_bool(b, c"null", (fl & ORM_SCHEMA_F_NULL) != 0)
	orm_codegen_json_bool(b, c"unique", (fl & ORM_SCHEMA_F_UNIQUE) != 0)
	orm_codegen_json_bool(b, c"indexed", (fl & ORM_SCHEMA_F_INDEXED) != 0)
	orm_codegen_json_bool(b, c"auto", (fl & ORM_SCHEMA_F_AUTO) != 0)
	orm_codegen_json_bool(b, c"auto_now_add", (fl & ORM_SCHEMA_F_AUTO_NOW_ADD) != 0)
	orm_codegen_json_bool(b, c"auto_now", (fl & ORM_SCHEMA_F_AUTO_NOW) != 0)
	orm_codegen_json_bool(b, c"deprecated", (fl & ORM_SCHEMA_F_DEPRECATED) != 0)
	orm_codegen_json_bool(b, c"no_history", (fl & ORM_SCHEMA_F_NO_HISTORY) != 0)
	orm_codegen_json_bool(b, c"read_only", (fl & ORM_SCHEMA_F_READ_ONLY) != 0)
	orm_codegen_json_int(b, c"max_length", f.max_length)
	orm_codegen_json_int(b, c"digits", f.digits)
	orm_codegen_json_int(b, c"places", f.places)
	orm_codegen_json_strkey(b, c"default", f.default_sql)
	char* enum_name = 0
	list[char*] values = new list[char*]
	if (f.enum_type != 0):
		enum_name = f.enum_type.name
		values = f.enum_type.values
	orm_codegen_json_strkey(b, c"enum", enum_name)
	orm_codegen_json_key(b, c"enum_values")
	orm_codegen_json_list(b, values)
	orm_codegen_json_strkey(b, c"rel_model", f.rel_model)
	char* on_delete = 0
	if (fk): on_delete = orm_codegen_on_delete_json(f.on_delete)
	orm_codegen_json_strkey(b, c"on_delete", on_delete)
	orm_codegen_json_strkey(b, c"related_name", f.related_name)
	char* tt = 0
	char* tf = 0
	char* tto = 0
	if (m2m):
		tt = orm_codegen_through_table(m, f)
		tf = orm_codegen_through_from(m, f)
		tto = orm_codegen_through_to(m, f)
	orm_codegen_json_strkey(b, c"through_table", tt)
	orm_codegen_json_strkey(b, c"through_from", tf)
	orm_codegen_json_strkey(b, c"through_to", tto)
	orm_codegen_json_strkey(b, c"reverse_field", f.reverse_field)
	string_append_char(b, '}')


# One model's snapshot object (also stored in orm_model_desc.schema_json).
char* orm_codegen_model_json(orm_schema* s, orm_schema_model* m):
	string_builder* b = string_new()
	string_append(b, c"{\"name\":")
	orm_codegen_json_str(b, m.name)
	orm_codegen_json_strkey(b, c"table", m.table)
	orm_codegen_json_bool(b, c"history", m.history)
	orm_codegen_json_key(b, c"fields")
	string_append_char(b, '[')
	int n = 0
	for orm_schema_field* f in m.fields:
		if (n > 0): string_append_char(b, ',')
		orm_codegen_field_json(b, m, f)
		n = n + 1
	for orm_schema_field* r in m.reverse:
		if (n > 0): string_append_char(b, ',')
		orm_codegen_field_json(b, m, r)
		n = n + 1
	string_append_char(b, ']')
	orm_codegen_json_key(b, c"indexes")
	string_append_char(b, '[')
	n = 0
	for orm_schema_index* idx in m.indexes:
		if (n > 0): string_append_char(b, ',')
		string_append(b, c"{\"name\":")
		orm_codegen_json_str(b, idx.name)
		orm_codegen_json_key(b, c"fields")
		orm_codegen_json_list(b, idx.fields)
		orm_codegen_json_key(b, c"columns")
		orm_codegen_json_list(b, orm_codegen_unique_together_columns(m, idx.fields))
		orm_codegen_json_bool(b, c"unique", idx.unique)
		orm_codegen_json_strkey(b, c"condition", 0)
		string_append_char(b, '}')
		n = n + 1
	string_append_char(b, ']')
	orm_codegen_json_key(b, c"checks")
	string_append_char(b, '[')
	n = 0
	for orm_schema_check* chk in m.checks:
		if (n > 0): string_append_char(b, ',')
		string_append(b, c"{\"name\":")
		orm_codegen_json_str(b, chk.name)
		orm_codegen_json_strkey(b, c"sql", chk.sql)
		string_append_char(b, '}')
		n = n + 1
	string_append_char(b, ']')
	orm_codegen_json_key(b, c"unique_together")
	string_append_char(b, '[')
	n = 0
	for list[char*] ut in m.unique_together:
		if (n > 0): string_append_char(b, ',')
		string_append(b, c"{\"fields\":")
		orm_codegen_json_list(b, ut)
		orm_codegen_json_key(b, c"columns")
		orm_codegen_json_list(b, orm_codegen_unique_together_columns(m, ut))
		string_append_char(b, '}')
		n = n + 1
	string_append(b, c"]}")
	char* r = b.data
	free(cast(void*, b))
	return r


# The whole-app snapshot: models in generated (FK dependency) order.
char* orm_codegen_schema_json(orm_schema* s):
	string_builder* b = string_new()
	string_append(b, c"{\"format\":\"w-orm-schema\",\"version\":1")
	orm_codegen_json_strkey(b, c"app", s.app)
	orm_codegen_json_key(b, c"models")
	string_append_char(b, '[')
	int n = 0
	for orm_schema_model* m in s.ordered:
		if (n > 0): string_append_char(b, ',')
		string_append(b, orm_codegen_model_json(s, m))
		n = n + 1
	string_append(b, c"]}")
	char* r = b.data
	free(cast(void*, b))
	return r


# ---------------------------------------------------------------------------
# Data module

void orm_codegen_struct(string_builder* b, orm_schema* s, orm_schema_model* m):
	string_append(b, c"\n\nstruct ")
	string_append(b, m.name)
	string_append(b, c":\n")
	for orm_schema_field* f in m.fields:
		int nullable = (f.flags & ORM_SCHEMA_F_NULL) != 0
		if (f.kind == ORM_SCHEMA_M2M):
			string_append(b, c"\tlist[void*] ")
			string_append(b, f.name)
			string_append_char(b, 10)
			continue
		if (f.kind == ORM_SCHEMA_FK):
			string_append(b, c"\tint ")
			string_append(b, orm_schema_column(f))
			string_append(b, c"\n\t")
			if (orm_codegen_fk_typed(s, m, f)):
				string_append(b, f.rel_model)
				string_append(b, c"* ")
			else:
				string_append(b, c"void* ")
			string_append(b, f.name)
			string_append_char(b, 10)
		else if (orm_schema_int_backed(f.kind)):
			string_append(b, c"\tint ")
			string_append(b, f.name)
			string_append_char(b, 10)
		else:
			string_append(b, c"\tchar* ")
			string_append(b, f.name)
			string_append_char(b, 10)
		if (nullable && orm_schema_int_backed(f.kind)):
			string_append(b, c"\tint ")
			string_append(b, f.name)
			string_append(b, c"__isnull\n")
	for orm_schema_field* r in m.reverse:
		string_append(b, c"\tlist[void*] ")
		string_append(b, r.name)
		string_append_char(b, 10)


# "__<app>_offset(&probe, &probe.<member>)"
void orm_codegen_offset(string_builder* b, orm_schema* s, char* member):
	string_append(b, c"__")
	string_append(b, s.app)
	string_append(b, c"_offset(&probe, &probe.")
	string_append(b, member)
	string_append_char(b, ')')


void orm_codegen_attr(list[char*] attrs, char* name, string_builder* value):
	string_builder* line = string_new()
	string_append(line, c"\tf.")
	string_append(line, name)
	string_append(line, c" = ")
	string_append(line, value.data)
	string_append_char(line, 10)
	attrs.push(line.data)
	free(cast(void*, line))
	string_free(value)


string_builder* orm_codegen_value_str(char* s):
	string_builder* v = string_new()
	orm_codegen_wstr(v, s)
	return v


string_builder* orm_codegen_value_int(int n):
	string_builder* v = string_new()
	string_append_int(v, n)
	return v


string_builder* orm_codegen_value_offset(orm_schema* s, char* member):
	string_builder* v = string_new()
	orm_codegen_offset(v, s, member)
	return v


# Emits one orm_model_add_field statement plus its attribute lines.
# Returns 1 once `f` is declared.
int orm_codegen_field_desc(string_builder* b, orm_schema* s, orm_schema_model* m, orm_schema_field* f, int f_declared):
	list[char*] attrs = new list[char*]
	int nullable = (f.flags & ORM_SCHEMA_F_NULL) != 0
	if (f.default_sql != 0): orm_codegen_attr(attrs, c"default_sql", orm_codegen_value_str(f.default_sql))
	if (f.max_length > 0): orm_codegen_attr(attrs, c"max_length", orm_codegen_value_int(f.max_length))
	if (f.digits > 0): orm_codegen_attr(attrs, c"digits", orm_codegen_value_int(f.digits))
	if (f.places > 0): orm_codegen_attr(attrs, c"places", orm_codegen_value_int(f.places))
	if (f.enum_type != 0):
		for char* ev in f.enum_type.values:
			string_builder* push = string_new()
			string_append(push, c"\tf.enum_values.push(")
			orm_codegen_wstr(push, ev)
			string_append(push, c")\n")
			attrs.push(push.data)
			free(cast(void*, push))
	if (nullable && orm_schema_int_backed(f.kind)):
		orm_codegen_attr(attrs, c"null_offset", orm_codegen_value_offset(s, orm_schema_concat3(f.name, c"__isnull", c"")))
	if (f.rel_model != 0):
		orm_codegen_attr(attrs, c"rel_model", orm_codegen_value_str(f.rel_model))
		orm_codegen_attr(attrs, c"rel_offset", orm_codegen_value_offset(s, f.name))
	if (f.kind == ORM_SCHEMA_FK):
		string_builder* od = string_new()
		string_append(od, orm_codegen_on_delete_const(f.on_delete))
		orm_codegen_attr(attrs, c"on_delete", od)
		if (f.related_name != 0): orm_codegen_attr(attrs, c"related_name", orm_codegen_value_str(f.related_name))
	if (f.kind == ORM_SCHEMA_M2M):
		orm_codegen_attr(attrs, c"through_table", orm_codegen_value_str(orm_codegen_through_table(m, f)))
		orm_codegen_attr(attrs, c"through_from", orm_codegen_value_str(orm_codegen_through_from(m, f)))
		orm_codegen_attr(attrs, c"through_to", orm_codegen_value_str(orm_codegen_through_to(m, f)))
	if (f.reverse_field != 0): orm_codegen_attr(attrs, c"reverse_field", orm_codegen_value_str(f.reverse_field))
	string_append_char(b, 9)
	if (attrs.length > 0):
		if (f_declared): string_append(b, c"f = ")
		else:
			string_append(b, c"orm_field_desc* f = ")
	string_append(b, c"orm_model_add_field(m, orm_field_new(")
	orm_codegen_wstr(b, f.name)
	string_append(b, c", ")
	orm_codegen_wstr_or_0(b, orm_schema_column(f))
	string_append(b, c", ")
	string_append(b, orm_codegen_kind_const(f.kind))
	string_append(b, c", ")
	if (orm_schema_has_column(f)): orm_codegen_offset(b, s, orm_schema_column(f))
	else:
		string_append(b, c"-1")
	string_append(b, c", ")
	orm_codegen_flags(b, f.flags)
	string_append(b, c"))\n")
	for char* a in attrs: string_append(b, a)
	return f_declared || attrs.length > 0


void orm_codegen_desc(string_builder* b, orm_schema* s, orm_schema_model* m):
	char* global = orm_schema_concat3(orm_schema_concat3(c"__", s.app, c"_"), m.name, c"_desc")
	string_append(b, c"\n\norm_model_desc* ")
	string_append(b, m.name)
	string_append(b, c"_desc():\n\tif (")
	string_append(b, global)
	string_append(b, c" != 0): return ")
	string_append(b, global)
	string_append(b, c"\n\t")
	string_append(b, m.name)
	string_append(b, c" probe\n\torm_model_desc* m = orm_model_new(")
	orm_codegen_wstr(b, m.name)
	string_append(b, c", ")
	orm_codegen_wstr(b, m.table)
	string_append(b, c", sizeof(")
	string_append(b, m.name)
	string_append(b, c"))\n")
	if (m.history): string_append(b, c"\tm.history = 1\n")
	int f_declared = 0
	for orm_schema_field* f in m.fields:
		f_declared = orm_codegen_field_desc(b, s, m, f, f_declared)
	for orm_schema_field* r in m.reverse:
		f_declared = orm_codegen_field_desc(b, s, m, r, f_declared)
	int idx_declared = 0
	for orm_schema_index* idx in m.indexes:
		if (idx_declared): string_append(b, c"\tidx = new orm_index_desc()\n")
		else:
			string_append(b, c"\torm_index_desc* idx = new orm_index_desc()\n")
		idx_declared = 1
		string_append(b, c"\tidx.name = ")
		orm_codegen_wstr(b, idx.name)
		string_append(b, c"\n\tidx.columns = new list[char*]\n")
		for char* col in orm_codegen_unique_together_columns(m, idx.fields):
			string_append(b, c"\tidx.columns.push(")
			orm_codegen_wstr(b, col)
			string_append(b, c")\n")
		if (idx.unique): string_append(b, c"\tidx.unique = 1\n")
		string_append(b, c"\tm.indexes.push(idx)\n")
	int chk_declared = 0
	for orm_schema_check* chk in m.checks:
		if (chk_declared): string_append(b, c"\tchk = new orm_check_desc()\n")
		else:
			string_append(b, c"\torm_check_desc* chk = new orm_check_desc()\n")
		chk_declared = 1
		string_append(b, c"\tchk.name = ")
		orm_codegen_wstr(b, chk.name)
		string_append(b, c"\n\tchk.condition_sql = ")
		orm_codegen_wstr(b, chk.sql)
		string_append(b, c"\n\tm.checks.push(chk)\n")
	int ut_declared = 0
	for list[char*] ut in m.unique_together:
		if (ut_declared): string_append(b, c"\tut = new list[char*]\n")
		else:
			string_append(b, c"\tlist[char*] ut = new list[char*]\n")
		ut_declared = 1
		for char* col in orm_codegen_unique_together_columns(m, ut):
			string_append(b, c"\tut.push(")
			orm_codegen_wstr(b, col)
			string_append(b, c")\n")
		string_append(b, c"\tm.unique_together.push(ut)\n")
	string_append(b, c"\tm.schema_json = ")
	orm_codegen_wstr(b, orm_codegen_model_json(s, m))
	string_append(b, c"\n\torm_register(m)\n\t")
	string_append(b, global)
	string_append(b, c" = m\n\treturn m\n")


void orm_codegen_handle(string_builder* b, char* model, char* infix, char* name, char* value):
	string_append(b, c"char* ")
	string_append(b, model)
	string_append(b, infix)
	string_append(b, name)
	string_append(b, c"(): return ")
	orm_codegen_wstr(b, value)
	string_append_char(b, 10)


void orm_codegen_list_accessor(string_builder* b, orm_schema_model* m, orm_schema_field* f):
	string_append(b, c"list[")
	string_append(b, f.rel_model)
	string_append(b, c"*] ")
	string_append(b, m.name)
	string_append_char(b, '_')
	string_append(b, f.name)
	string_append_char(b, '(')
	string_append(b, m.name)
	string_append(b, c"* row): return cast(list[")
	string_append(b, f.rel_model)
	string_append(b, c"*], row.")
	string_append(b, f.name)
	string_append(b, c")\n")


char* orm_codegen_data(orm_schema* s):
	string_builder* b = string_new()
	string_append(b, c"# Generated by bin/orm_gen from ")
	string_append(b, s.path)
	string_append(b, c"; do not edit.\n# Data module: structs, descriptors, field handles (docs/projects/orm.md).\nimport libs.standard.orm.contract\n")
	for orm_schema_model* m in s.ordered: orm_codegen_struct(b, s, m)
	string_append(b, c"\n\n")
	for orm_schema_model* m2 in s.ordered:
		string_append(b, c"orm_model_desc* __")
		string_append(b, s.app)
		string_append_char(b, '_')
		string_append(b, m2.name)
		string_append(b, c"_desc\n")
	string_append(b, c"\n\nint __")
	string_append(b, s.app)
	string_append(b, c"_offset(void* base, void* field):\n\treturn cast(int, field) - cast(int, base)\n")
	for orm_schema_model* m3 in s.ordered: orm_codegen_desc(b, s, m3)
	string_append(b, c"\n\n# Field handles.\n")
	for orm_schema_model* m4 in s.ordered:
		for orm_schema_field* f in m4.fields: orm_codegen_handle(b, m4.name, c"_f_", f.name, f.name)
		for orm_schema_field* r in m4.reverse: orm_codegen_handle(b, m4.name, c"_f_", r.name, r.name)
	int any_enum = 0
	for orm_schema_model* m5 in s.ordered:
		for orm_schema_enum* e in m5.enums:
			if (!any_enum): string_append(b, c"\n\n# Enum values.\n")
			any_enum = 1
			for char* v in e.values:
				orm_codegen_handle(b, m5.name, c"_", orm_schema_concat3(e.name, c"_", v), v)
	string_append(b, c"\n\n# Typed relation accessors (relation slots hold void*/list[void*]).\n")
	for orm_schema_model* m6 in s.ordered:
		for orm_schema_field* f2 in m6.fields:
			if (f2.kind == ORM_SCHEMA_FK):
				string_append(b, f2.rel_model)
				string_append(b, c"* ")
				string_append(b, m6.name)
				string_append_char(b, '_')
				string_append(b, f2.name)
				string_append_char(b, '(')
				string_append(b, m6.name)
				string_append(b, c"* row): return ")
				if (orm_codegen_fk_typed(s, m6, f2)):
					string_append(b, c"row.")
					string_append(b, f2.name)
				else:
					string_append(b, c"cast(")
					string_append(b, f2.rel_model)
					string_append(b, c"*, row.")
					string_append(b, f2.name)
					string_append_char(b, ')')
				string_append_char(b, 10)
			else if (f2.kind == ORM_SCHEMA_M2M):
				orm_codegen_list_accessor(b, m6, f2)
		for orm_schema_field* r2 in m6.reverse: orm_codegen_list_accessor(b, m6, r2)
	string_append(b, c"\n\n# Schema snapshot (docs/projects/orm/u1_1.md).\nchar* ")
	string_append(b, s.app)
	string_append(b, c"_schema_json():\n\treturn ")
	orm_codegen_wstr(b, orm_codegen_schema_json(s))
	string_append(b, c"\n\n\nvoid ")
	string_append(b, s.app)
	string_append(b, c"_register():\n")
	for orm_schema_model* m7 in s.ordered:
		string_append_char(b, 9)
		string_append(b, m7.name)
		string_append(b, c"_desc()\n")
	string_append(b, c"\tchar* missing = 0\n\tif (orm_registry_resolve(&missing) == 0):\n\t\tprint(c\"")
	string_append(b, s.app)
	string_append(b, c"_register: unresolved relation target \")\n\t\tprintln(missing)\n")
	char* r = b.data
	free(cast(void*, b))
	return r


# ---------------------------------------------------------------------------
# API module

void orm_codegen_api_fn(string_builder* b, char* ret, char* model, char* suffix, char* params, char* body):
	string_append(b, ret)
	string_append_char(b, ' ')
	string_append(b, model)
	string_append(b, suffix)
	string_append_char(b, '(')
	string_append(b, params)
	string_append(b, c"): ")
	string_append(b, body)
	string_append_char(b, 10)


char* orm_codegen_api(orm_schema* s, char* data_module):
	string_builder* b = string_new()
	string_append(b, c"# Generated by bin/orm_gen from ")
	string_append(b, s.path)
	string_append(b, c"; do not edit.\n# API module: typed wrappers over libs.standard.orm.orm (docs/projects/orm.md).\nimport ")
	string_append(b, data_module)
	string_append(b, c"\nimport libs.standard.orm.orm\n")
	int any_history = 0
	for orm_schema_model* hm in s.ordered:
		if (hm.history): any_history = 1
	if (any_history): string_append(b, c"import libs.standard.orm.history.history\n")
	for orm_schema_model* m in s.ordered:
		char* n = m.name
		char* desc = orm_schema_concat3(n, c"_desc()", c"")
		char* ptr = orm_schema_concat3(n, c"*", c"")
		string_append(b, c"\n\n")
		orm_codegen_api_fn(b, c"orm_queryset*", n, c"_objects", c"orm_db* db", orm_schema_concat3(c"return orm_objects(db, ", desc, c")"))
		orm_codegen_api_fn(b, orm_schema_concat3(c"list[", ptr, c"]"), n, c"_rows", c"orm_result* r", orm_schema_concat3(c"return cast(list[", ptr, c"], r.rows)"))
		orm_codegen_api_fn(b, ptr, n, c"_new", c"", orm_schema_concat3(orm_schema_concat3(c"return cast(", ptr, c", orm_row_new("), desc, c"))"))
		char* row_param = orm_schema_concat3(c"orm_db* db, ", ptr, c" row")
		orm_codegen_api_fn(b, c"int", n, c"_save", row_param, orm_schema_concat3(c"return orm_save(db, ", desc, c", row)"))
		orm_codegen_api_fn(b, c"int", n, c"_delete", row_param, orm_schema_concat3(c"return orm_delete_row(db, ", desc, c", row)"))
		orm_codegen_api_fn(b, c"void", n, c"_free", orm_schema_concat3(ptr, c" row", c""), orm_schema_concat3(c"orm_row_free(", desc, c", row)"))
		if (m.history):
			# Trigger history (U3.3, libs/standard/orm/history/history.w).
			orm_codegen_api_fn(b, c"orm_result*", n, c"_history", row_param, orm_schema_concat3(c"return orm_history_of(db, ", desc, c", row)"))
			orm_codegen_api_fn(b, c"orm_result*", n, c"_as_of", c"orm_db* db, char* when", orm_schema_concat3(c"return orm_history_as_of(db, ", desc, c", when)"))
			orm_codegen_api_fn(b, ptr, n, c"_history_row", c"orm_history_entry* e", orm_schema_concat3(c"return cast(", ptr, c", e.row)"))
			orm_codegen_api_fn(b, c"int", n, c"_prune_history", c"orm_db* db, char* older_than", orm_schema_concat3(c"return orm_history_prune(db, ", desc, c", older_than)"))
	char* r = b.data
	free(cast(void*, b))
	return r
