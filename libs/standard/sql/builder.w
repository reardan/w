# Compose trusted SQL fragments, quoted identifiers, and bound text values.
# This module does not import the parser or any native database client.
import structures.string


const int sql_bind_question = 0
const int sql_bind_dollar = 1
const int sql_bind_colon = 2


struct sql_builder:
	string_builder* text
	list[char*] parameters
	int style


# ?, $1, or :1 markers for SQLite, PostgreSQL, or Oracle respectively.
sql_builder* sql_builder_new(int style):
	if (style < sql_bind_question || style > sql_bind_colon): return 0
	sql_builder* builder = new sql_builder()
	builder.text = string_new()
	builder.parameters = new list[char*]
	builder.style = style
	return builder


# Only trusted syntax belongs here. No spaces are inserted automatically.
void sql_builder_append(sql_builder* builder, char* fragment):
	string_append(builder.text, fragment)


# Quote ONE identifier with SQL double quotes. For a qualified name, call
# once per component with append(".") between them. A star is syntax.
void sql_builder_identifier(sql_builder* builder, char* name):
	string_append_char(builder.text, '"')
	for i in range(strlen(name)):
		if (name[i] == '"'): string_append_char(builder.text, '"')
		string_append_char(builder.text, name[i])
	string_append_char(builder.text, '"')


# Copy a NUL-terminated text value (null pointer means SQL NULL), then
# append its placeholder. Values are never interpolated into SQL text.
void sql_builder_bind(sql_builder* builder, char* value):
	char* owned = 0
	if (value != 0): owned = strclone(value)
	builder.parameters.push(owned)
	if (builder.style == sql_bind_question):
		string_append_char(builder.text, '?')
	else:
		if (builder.style == sql_bind_dollar): string_append_char(builder.text, '$')
		else: string_append_char(builder.text, ':')
		string_append_int(builder.text, builder.parameters.length)


# Borrowed array for sql_query_params; invalidated by bind/free.
char** sql_builder_values(sql_builder* builder):
	if (builder.parameters.length == 0): return 0
	return &builder.parameters[0]


void sql_builder_free(sql_builder* builder):
	if (builder == 0): return
	for value in builder.parameters:
		if (value != 0): free(value)
	__w_list_free(cast(__w_list*, builder.parameters))
	string_free(builder.text)
	free(builder)
