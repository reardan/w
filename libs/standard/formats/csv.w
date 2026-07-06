/*
CSV reader/writer for the standard formats MVP.

The parser follows the usual CSV state transitions: unquoted field, quoted
field, and just-closed quote. It supports delimiter, quotechar, escapechar,
doublequote, LF/CRLF rows, empty fields, embedded delimiters, and embedded
newlines in quoted fields.
*/
import lib.lib
import structures.string


struct csv_dialect:
	int delimiter
	int quotechar
	int escapechar
	int doublequote
	char* lineterminator


struct csv_reader:
	char* text
	int index
	int ok
	int done
	csv_dialect dialect


csv_dialect csv_dialect_excel():
	csv_dialect d
	d.delimiter = ','
	d.quotechar = 34
	d.escapechar = 0
	d.doublequote = 1
	d.lineterminator = c"\r\n"
	return d


csv_reader* csv_reader_new_dialect(char* text, csv_dialect* dialect):
	csv_reader* reader = new csv_reader()
	reader.text = text
	reader.index = 0
	reader.ok = 1
	reader.done = 0
	reader.dialect = dialect[0]
	return reader


csv_reader* csv_reader_new(char* text):
	csv_dialect d = csv_dialect_excel()
	return csv_reader_new_dialect(text, &d)


int csv_reader_ok(csv_reader* reader):
	return reader.ok


void csv_fail(csv_reader* reader):
	reader.ok = 0
	reader.done = 1


char* csv_take_string_data(string_builder* s):
	char* data = s.data
	free(s)
	return data


string_builder* csv_finish_field(list[char*] fields, string_builder* field):
	fields.push(csv_take_string_data(field))
	return string_new()


int csv_is_row_end(int c):
	return (c == '\n') | (c == '\r') | (c == 0)


int csv_consume_row_end(csv_reader* reader):
	int c = reader.text[reader.index]
	if (c == '\r'):
		reader.index = reader.index + 1
		if (reader.text[reader.index] == '\n'):
			reader.index = reader.index + 1
		return 1
	if (c == '\n'):
		reader.index = reader.index + 1
		return 1
	if (c == 0):
		reader.done = 1
		return 1
	return 0


list[char*] csv_read_row(csv_reader* reader):
	if ((reader.done) | (reader.ok == 0)):
		return 0
	if (reader.text[reader.index] == 0):
		reader.done = 1
		return 0

	list[char*] fields = new list[char*]
	string_builder* field = string_new()
	int in_quotes = 0
	int after_quote = 0
	int at_start = 1
	while (1):
		int c = reader.text[reader.index]
		if (in_quotes):
			if (c == 0):
				string_free(field)
				csv_fail(reader)
				return 0
			if ((reader.dialect.escapechar != 0) & (c == reader.dialect.escapechar)):
				reader.index = reader.index + 1
				c = reader.text[reader.index]
				if (c == 0):
					string_free(field)
					csv_fail(reader)
					return 0
				string_append_char(field, c)
				reader.index = reader.index + 1
			else if (c == reader.dialect.quotechar):
				if ((reader.dialect.doublequote) & (reader.text[reader.index + 1] == reader.dialect.quotechar)):
					string_append_char(field, reader.dialect.quotechar)
					reader.index = reader.index + 2
				else:
					in_quotes = 0
					after_quote = 1
					reader.index = reader.index + 1
			else:
				string_append_char(field, c)
				reader.index = reader.index + 1
		else if (after_quote):
			if (c == reader.dialect.delimiter):
				field = csv_finish_field(fields, field)
				after_quote = 0
				at_start = 1
				reader.index = reader.index + 1
			else if (csv_is_row_end(c)):
				field = csv_finish_field(fields, field)
				csv_consume_row_end(reader)
				return fields
			else:
				string_free(field)
				csv_fail(reader)
				return 0
		else:
			if ((c == reader.dialect.quotechar) & (at_start)):
				in_quotes = 1
				at_start = 0
				reader.index = reader.index + 1
			else if (c == reader.dialect.quotechar):
				string_free(field)
				csv_fail(reader)
				return 0
			else if (c == reader.dialect.delimiter):
				field = csv_finish_field(fields, field)
				at_start = 1
				reader.index = reader.index + 1
			else if (csv_is_row_end(c)):
				field = csv_finish_field(fields, field)
				csv_consume_row_end(reader)
				return fields
			else:
				string_append_char(field, c)
				at_start = 0
				reader.index = reader.index + 1


int csv_field_needs_quotes(char* field):
	if (field[0] == 0):
		return 0
	int i = 0
	while (field[i] != 0):
		if ((field[i] == ',') | (field[i] == 34) | (field[i] == '\n') | (field[i] == '\r')):
			return 1
		i = i + 1
	return 0


char* csv_write_row(list[char*] fields):
	string_builder* out = string_new()
	int i = 0
	while (i < fields.length):
		if (i > 0):
			string_append_char(out, ',')
		char* field = fields[i]
		if (csv_field_needs_quotes(field)):
			string_append_char(out, 34)
			int j = 0
			while (field[j] != 0):
				if (field[j] == 34):
					string_append_char(out, 34)
					string_append_char(out, 34)
				else:
					string_append_char(out, field[j])
				j = j + 1
			string_append_char(out, 34)
		else:
			string_append(out, field)
		i = i + 1
	return csv_take_string_data(out)
