# w-orm migration writer (issue #754, unit U2.2).
#
# Emits reviewable W source for migrations: one module per migration,
#
#   <dir>/m0001_initial.w   ->  orm_migration* <app>_m0001_initial()
#
# built only from contract.w constructors (orm_migration_new, orm_op_new,
# orm_migration_add), plus an index module
#
#   <dir>/<app>_migrations.w  ->  list[orm_migration*] <app>_migrations()
#
# returning them in order. Writing is append-only: an existing migration
# module is never rewritten, and the index keeps its existing entries in
# their order and appends new ones. App authors commit these files.
import libs.standard.orm.contract
import libs.standard.orm.migrate.lint
import libs.standard.orm.migrate.state
import structures.json
import structures.string
import lib.str
import lib.file
import lib.path
import lib.stat


# Identifier for a migration name: "m" + the name with every byte outside
# [A-Za-z0-9_] replaced by '_' ("0001_initial" -> "m0001_initial").
char* orm_writer_ident(char* name):
	string_builder* b = string_new()
	string_append_char(b, 'm')
	int i = 0
	while (name[i] != 0):
		int c = name[i]
		int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		if (ok): string_append_char(b, c)
		else: string_append_char(b, '_')
		i = i + 1
	char* out = b.data
	free(cast(void*, b))
	return out


# A W c"..." literal for s.
void orm_writer_wstr(string_builder* b, char* s):
	string_append(b, c"c\"")
	int i = 0
	while (s[i] != 0):
		int c = s[i]
		if (c == '\\' || c == '"'):
			string_append_char(b, '\\')
			string_append_char(b, c)
		else if (c == 10): string_append(b, c"\\n")
		else if (c == 13): string_append(b, c"\\r")
		else if (c == 9): string_append(b, c"\\t")
		else: string_append_char(b, c)
		i = i + 1
	string_append_char(b, '"')


void orm_writer_set_str(string_builder* b, char* target, char* field, char* value):
	if (value == 0): return
	string_append(b, c"\t")
	string_append(b, target)
	string_append(b, c".")
	string_append(b, field)
	string_append(b, c" = ")
	orm_writer_wstr(b, value)
	string_append(b, c"\n")


void orm_writer_set_int(string_builder* b, char* target, char* field, int value):
	string_append(b, c"\t")
	string_append(b, target)
	string_append(b, c".")
	string_append(b, field)
	string_append(b, c" = ")
	string_append_int(b, value)
	string_append(b, c"\n")


char* orm_writer_phase_const(int phase):
	if (phase == ORM_PHASE_EXPAND): return c"ORM_PHASE_EXPAND"
	if (phase == ORM_PHASE_MIGRATE): return c"ORM_PHASE_MIGRATE"
	if (phase == ORM_PHASE_CONTRACT): return c"ORM_PHASE_CONTRACT"
	return c"0"


void orm_writer_append_line(string_builder* b, char* piece):
	string_append(b, c"\tstring_append(j, ")
	orm_writer_wstr(b, piece)
	string_append(b, c")\n")


# A model JSON written one field per line so a review diff shows which
# field changed. Falls back to one literal when the text does not parse.
void orm_writer_model_json(string_builder* b, char* field, char* json):
	json_value* v = json_parse(json)
	json_value* fields = orm_sj_array(v, c"fields")
	if (v == 0 || v.type != json_type_object() || fields == 0):
		json_free(v)
		orm_writer_set_str(b, c"op", field, json)
		return
	string_append(b, c"\tj = string_new()\n")
	string_builder* head = string_new()
	string_append_char(head, '{')
	int first = 1
	for char* key, json_value* member in v.object_values:
		if (strcmp(key, c"fields") == 0):
			if (first == 0): string_append_char(head, ',')
			string_append(head, c"\"fields\":[")
			orm_writer_append_line(b, head.data)
			string_clear(head)
			for i in range(fields.array_values.length):
				char* text = json_stringify(fields.array_values[i])
				if (i > 0): string_append_char(head, ',')
				string_append(head, text)
				free(text)
				orm_writer_append_line(b, head.data)
				string_clear(head)
			string_append_char(head, ']')
			first = 0
			continue
		if (first == 0): string_append_char(head, ',')
		first = 0
		json_value* k = json_string(key)
		char* ktext = json_stringify(k)
		json_free(k)
		string_append(head, ktext)
		free(ktext)
		string_append_char(head, ':')
		char* vtext = json_stringify(member)
		string_append(head, vtext)
		free(vtext)
	string_append_char(head, '}')
	orm_writer_append_line(b, head.data)
	string_free(head)
	string_append(b, c"\top.")
	string_append(b, field)
	string_append(b, c" = j.data\n")
	string_append(b, c"\tfree(cast(void*, j))\n")
	json_free(v)


int orm_writer_needs_builder(orm_migration* m):
	for orm_op* op in m.ops:
		if (op.model_json != 0): return 1
	return 0


void orm_writer_op(string_builder* b, orm_op* op):
	string_append(b, c"\n\t# ")
	string_append(b, orm_phase_name(op.phase))
	string_append(b, c" ")
	string_append(b, orm_op_kind_name(op.kind))
	if (op.table != 0):
		string_append(b, c" ")
		string_append(b, op.table)
	if (op.column != 0):
		string_append(b, c".")
		string_append(b, op.column)
	string_append(b, c"\n\top = orm_op_new(ORM_OP_")
	string_append(b, orm_op_kind_name(op.kind))
	string_append(b, c", ")
	string_append(b, orm_writer_phase_const(op.phase))
	string_append(b, c", ")
	if (op.table != 0): orm_writer_wstr(b, op.table)
	else: string_append(b, c"0")
	string_append(b, c")\n")
	orm_writer_set_str(b, c"op", c"column", op.column)
	orm_writer_set_str(b, c"op", c"name", op.name)
	orm_writer_set_str(b, c"op", c"source_table", op.source_table)
	orm_writer_set_str(b, c"op", c"source_column", op.source_column)
	if (op.model_json != 0): orm_writer_model_json(b, c"model_json", op.model_json)
	orm_writer_set_str(b, c"op", c"field_json", op.field_json)
	orm_writer_set_str(b, c"op", c"sql", op.sql)
	orm_writer_set_str(b, c"op", c"reverse_sql", op.reverse_sql)
	if (op.non_atomic): orm_writer_set_int(b, c"op", c"non_atomic", 1)
	if (op.unsafe): orm_writer_set_int(b, c"op", c"unsafe", 1)
	if (op.batch_size != 1000): orm_writer_set_int(b, c"op", c"batch_size", op.batch_size)
	if (op.dialects == ORM_OP_ON_POSTGRES): string_append(b, c"\top.dialects = ORM_OP_ON_POSTGRES\n")
	else if (op.dialects == ORM_OP_ON_SQLITE): string_append(b, c"\top.dialects = ORM_OP_ON_SQLITE\n")
	else if (op.dialects != 0): orm_writer_set_int(b, c"op", c"dialects", op.dialects)
	string_append(b, c"\torm_migration_add(m, op)\n")


# The W source of one migration module.
char* orm_writer_migration_source(char* app, orm_migration* m):
	char* ident = orm_writer_ident(m.name)
	string_builder* b = string_new()
	string_append(b, c"# Generated by w-orm makemigrations (libs/standard/orm/migrate/writer.w).\n")
	string_append(b, c"# Migration ")
	if (app != 0):
		string_append(b, app)
		string_append(b, c".")
	string_append(b, m.name)
	string_append(b, c": review it, then commit it. makemigrations never\n")
	string_append(b, c"# rewrites it; later schema changes become new migrations.\n")
	string_append(b, c"import libs.standard.orm.contract\n")
	int builder = orm_writer_needs_builder(m)
	if (builder): string_append(b, c"import structures.string\n")
	string_append(b, c"\n\norm_migration* ")
	if (app != 0):
		string_append(b, app)
		string_append(b, c"_")
	string_append(b, ident)
	string_append(b, c"():\n\torm_migration* m = orm_migration_new(")
	if (m.app != 0): orm_writer_wstr(b, m.app)
	else: string_append(b, c"0")
	string_append(b, c", ")
	orm_writer_wstr(b, m.name)
	string_append(b, c")\n")
	for char* dep in m.dependencies:
		string_append(b, c"\tm.dependencies.push(")
		orm_writer_wstr(b, dep)
		string_append(b, c")\n")
	orm_writer_set_str(b, c"m", c"requires_applied", m.requires_applied)
	if (m.phase != 0):
		string_append(b, c"\tm.phase = ")
		string_append(b, orm_writer_phase_const(m.phase))
		string_append(b, c"\n")
	if (m.ops.length > 0):
		string_append(b, c"\torm_op* op = 0\n")
		if (builder): string_append(b, c"\tstring_builder* j = 0\n")
	for orm_op* op in m.ops: orm_writer_op(b, op)
	int derived = 1
	for orm_op* op2 in m.ops:
		if (op2.non_atomic): derived = 0
	if (m.atomic != derived):
		string_append(b, c"\n")
		orm_writer_set_int(b, c"m", c"atomic", m.atomic)
	string_append(b, c"\treturn m\n")
	free(ident)
	char* out = b.data
	free(cast(void*, b))
	return out


# The index module: imports every migration module (dotted
# `module_prefix` + "." + ident) and returns them in `idents` order.
char* orm_writer_index_source(char* app, char* module_prefix, list[char*] idents):
	string_builder* b = string_new()
	string_append(b, c"# Generated by w-orm makemigrations (libs/standard/orm/migrate/writer.w).\n")
	string_append(b, c"# The migrations of app ")
	string_append(b, app)
	string_append(b, c", in order. Regenerated append-only: new\n")
	string_append(b, c"# migrations are added at the end; existing entries are kept.\n")
	string_append(b, c"import libs.standard.orm.contract\n")
	for char* id in idents:
		string_append(b, c"import ")
		string_append(b, module_prefix)
		string_append(b, c".")
		string_append(b, id)
		string_append(b, c"\n")
	string_append(b, c"\n\nlist[orm_migration*] ")
	string_append(b, app)
	string_append(b, c"_migrations():\n\tlist[orm_migration*] l = new list[orm_migration*]\n")
	for char* id2 in idents:
		string_append(b, c"\tl.push(")
		string_append(b, app)
		string_append(b, c"_")
		string_append(b, id2)
		string_append(b, c"())\n")
	string_append(b, c"\treturn l\n")
	char* out = b.data
	free(cast(void*, b))
	return out


# The idents listed by an existing index module ("\tl.push(<app>_<id>())"
# lines), in order. Empty when the file is missing.
list[char*] orm_writer_index_entries(char* index_path, char* app):
	list[char*] out = new list[char*]
	char* text = file_read_text(index_path)
	if (text == 0): return out
	string_builder* pre = string_new()
	string_append(pre, c"\tl.push(")
	string_append(pre, app)
	string_append(pre, c"_")
	char* prefix = pre.data
	int plen = strlen(prefix)
	int i = 0
	while (text[i] != 0):
		int line_end = i
		while (text[line_end] != 0 && text[line_end] != 10): line_end = line_end + 1
		if (starts_with_at(text, prefix, i)):
			int s = i + plen
			int e = s
			while (e < line_end && text[e] != '('): e = e + 1
			if (e > s): out.push(str_copy_range(text, s, e))
		i = line_end
		if (text[i] == 10): i = i + 1
	string_free(pre)
	free(text)
	return out


int orm_writer_is_dir(char* path):
	file_stat st
	if (file_stat_path(path, &st) != 0): return 0
	return file_is_dir(&st)


void orm_writer_mkdirs(char* dir):
	if (dir == 0 || dir[0] == 0 || orm_writer_is_dir(dir)): return
	char* parent = path_dirname(dir)
	if (parent != 0 && strcmp(parent, dir) != 0): orm_writer_mkdirs(parent)
	mkdir(dir, 493)


char* orm_writer_path(char* dir, char* name, char* ext):
	string_builder* b = string_new()
	string_append(b, dir)
	string_append(b, c"/")
	string_append(b, name)
	string_append(b, ext)
	char* out = b.data
	free(cast(void*, b))
	return out


# Writes `migrations` under `dir` (created when missing): a module per
# migration that has none yet, then the index `<dir>/<app>_migrations.w`
# listing the existing entries followed by the new ones. `module_prefix`
# is the dotted import path of `dir` ("app.migrations"). Returns the number
# of migration modules written, or -1 with *error set (owned) on a write
# failure.
int orm_write_migrations(char* dir, char* module_prefix, char* app, list[orm_migration*] migrations, char** error):
	orm_writer_mkdirs(dir)
	char* index_name = orm_concat3(app, c"_migrations", c"")
	char* index_path = orm_writer_path(dir, index_name, c".w")
	free(index_name)
	list[char*] idents = orm_writer_index_entries(index_path, app)
	int written = 0
	int failed = 0
	for orm_migration* m in migrations:
		char* id = orm_writer_ident(m.name)
		char* path = orm_writer_path(dir, id, c".w")
		if (path_exists(path) == 0 && failed == 0):
			char* src = orm_writer_migration_source(app, m)
			if (file_write_text(path, src) == 0):
				failed = 1
				if (error != 0): error[0] = orm_concat3(c"cannot write ", path, c"")
			else: written = written + 1
			free(src)
		free(path)
		int listed = 0
		for char* e in idents:
			if (strcmp(e, id) == 0): listed = 1
		if (listed): free(id)
		else: idents.push(id)
	if (failed == 0):
		char* index = orm_writer_index_source(app, module_prefix, idents)
		if (file_write_text(index_path, index) == 0):
			failed = 1
			if (error != 0): error[0] = orm_concat3(c"cannot write ", index_path, c"")
		free(index)
	for char* x in idents: free(x)
	idents.free()
	free(index_path)
	if (failed): return -1
	return written
