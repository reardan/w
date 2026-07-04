/*
Deterministic W source writer used by ParserGenerator.
*/
import lib.lib
import structures.string


struct pg_source_writer:
	string_builder* out
	int indent


pg_source_writer* pg_source_writer_new():
	pg_source_writer* writer = new pg_source_writer()
	writer.out = string_new()
	writer.indent = 0
	return writer


void pg_source_indent(pg_source_writer* writer):
	writer.indent = writer.indent + 1


void pg_source_dedent(pg_source_writer* writer):
	writer.indent = writer.indent - 1
	if (writer.indent < 0):
		writer.indent = 0


void pg_source_tabs(pg_source_writer* writer):
	int i = 0
	while (i < writer.indent):
		string_append_char(writer.out, 9)
		i = i + 1


void pg_source_line(pg_source_writer* writer, char* text):
	pg_source_tabs(writer)
	string_append(writer.out, text)
	string_append_char(writer.out, 10)


void pg_source_blank(pg_source_writer* writer):
	string_append_char(writer.out, 10)


void pg_source_append(pg_source_writer* writer, char* text):
	string_append(writer.out, text)


void pg_source_append_char(pg_source_writer* writer, int c):
	string_append_char(writer.out, c)


void pg_source_append_int(pg_source_writer* writer, int value):
	string_append_int(writer.out, value)


void pg_source_append_w_string(pg_source_writer* writer, char* text):
	string_append_char(writer.out, '"')
	int i = 0
	while (text[i]):
		int c = text[i]
		if (c == '"'):
			string_append(writer.out, c"\\x22")
		else if (c == 92):
			string_append(writer.out, c"\\x5c")
		else if (c == 10):
			string_append(writer.out, c"\\x0a")
		else if (c == 9):
			string_append(writer.out, c"\\x09")
		else:
			string_append_char(writer.out, c)
		i = i + 1
	string_append_char(writer.out, '"')


char* pg_source_take(pg_source_writer* writer):
	char* data = writer.out.data
	free(writer.out)
	free(writer)
	return data


char* pg_read_file_text(char* path):
	int file = open(path, 0, 0)
	if (file < 0):
		return 0
	int size = file_size(file)
	char* data = malloc(size + 1)
	int count = read(file, data, size)
	close(file)
	if (count < 0):
		free(data)
		return 0
	data[count] = 0
	return data


int pg_write_file_text(char* path, char* text):
	int file = open(path, 577, 493)
	if (file < 0):
		return 0
	int count = write(file, text, strlen(text))
	close(file)
	return count == strlen(text)
