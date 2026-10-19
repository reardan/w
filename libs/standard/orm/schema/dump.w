# Canonical text dump of every registered w-orm model descriptor (issue
# #754, unit U1.1). Two programs that register "the same" models (the
# hand-written fixture and bin/orm_gen output) must print identical dumps:
# orm_gen_test compares them. Every orm_model_desc / orm_field_desc /
# orm_index_desc / orm_check_desc attribute is printed except
# orm_model_desc.schema_json (the fixture does not carry a snapshot) and
# raw pointers (rel_target is printed as the target model's name).
import libs.standard.orm.contract
import structures.string


void orm_dump_str(string_builder* b, char* key, char* v):
	string_append_char(b, ' ')
	string_append(b, key)
	string_append_char(b, '=')
	if (v == 0):
		string_append(b, c"null")
		return
	string_append_char(b, '"')
	string_append(b, v)
	string_append_char(b, '"')


void orm_dump_int(string_builder* b, char* key, int v):
	string_append_char(b, ' ')
	string_append(b, key)
	string_append_char(b, '=')
	string_append_int(b, v)


void orm_dump_list(string_builder* b, char* key, list[char*] items):
	string_append_char(b, ' ')
	string_append(b, key)
	string_append(b, c"=[")
	if (items != 0):
		int i = 0
		while (i < items.length):
			if (i > 0): string_append_char(b, ',')
			string_append(b, items[i])
			i = i + 1
	string_append_char(b, ']')


void orm_dump_field(string_builder* b, orm_field_desc* f):
	string_append(b, c"  field")
	orm_dump_str(b, c"name", f.name)
	orm_dump_str(b, c"column", f.column)
	orm_dump_int(b, c"kind", f.kind)
	orm_dump_int(b, c"offset", f.offset)
	orm_dump_int(b, c"size", f.size)
	orm_dump_int(b, c"flags", f.flags)
	orm_dump_int(b, c"null_offset", f.null_offset)
	orm_dump_int(b, c"max_length", f.max_length)
	orm_dump_int(b, c"digits", f.digits)
	orm_dump_int(b, c"places", f.places)
	orm_dump_str(b, c"default_sql", f.default_sql)
	orm_dump_str(b, c"rel_model", f.rel_model)
	char* target = 0
	if (f.rel_target != 0): target = orm_field_target(f).name
	orm_dump_str(b, c"rel_target", target)
	orm_dump_int(b, c"rel_offset", f.rel_offset)
	orm_dump_int(b, c"on_delete", f.on_delete)
	orm_dump_str(b, c"related_name", f.related_name)
	orm_dump_str(b, c"through_table", f.through_table)
	orm_dump_str(b, c"through_from", f.through_from)
	orm_dump_str(b, c"through_to", f.through_to)
	orm_dump_str(b, c"reverse_field", f.reverse_field)
	orm_dump_list(b, c"enum_values", f.enum_values)
	string_append_char(b, 10)


void orm_dump_model(string_builder* b, orm_model_desc* m):
	string_append(b, c"model")
	orm_dump_str(b, c"name", m.name)
	orm_dump_str(b, c"table", m.table)
	orm_dump_int(b, c"struct_size", m.struct_size)
	orm_dump_int(b, c"pk_index", m.pk_index)
	orm_dump_int(b, c"history", m.history)
	orm_dump_int(b, c"fields", m.fields.length)
	string_append_char(b, 10)
	for orm_field_desc* f in m.fields: orm_dump_field(b, f)
	for orm_index_desc* idx in m.indexes:
		string_append(b, c"  index")
		orm_dump_str(b, c"name", idx.name)
		orm_dump_list(b, c"columns", idx.columns)
		orm_dump_int(b, c"unique", idx.unique)
		orm_dump_str(b, c"condition_sql", idx.condition_sql)
		string_append_char(b, 10)
	for orm_check_desc* chk in m.checks:
		string_append(b, c"  check")
		orm_dump_str(b, c"name", chk.name)
		orm_dump_str(b, c"condition_sql", chk.condition_sql)
		string_append_char(b, 10)
	for list[char*] ut in m.unique_together:
		string_append(b, c"  unique_together")
		orm_dump_list(b, c"columns", ut)
		string_append_char(b, 10)


# The dump of every registered model, in registration order.
char* orm_schema_dump_registry():
	string_builder* b = string_new()
	for orm_model_desc* m in orm_registry_models(): orm_dump_model(b, m)
	char* r = b.data
	free(cast(void*, b))
	return r
