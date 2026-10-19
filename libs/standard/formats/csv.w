/*
CSV reader and writer (RFC 4180, Python `csv` module semantics).

The reader is a port of CPython's Modules/_csv.c state machine: quoted
fields, embedded delimiters and newlines, doubled quotes, an optional
escape character, skipinitialspace, strict mode and `\r\n`, `\n` or `\r`
record terminators. It reads either a byte buffer or a lib/stream.w
stream one row at a time, so a large file is never loaded whole.

	csv_reader* r = csv_reader_new(c"name,age\r\n\"Smith, J\",42\r\n")
	list[char*] row = csv_next_row(r)     # ["name", "age"]
	...
	csv_row_free(row)
	if (csv_reader_failed(r)): print(csv_reader_error(r))
	csv_reader_free(r)

Rows are `list[char*]` of malloc'd strings owned by the caller
(csv_row_free). csv_next_row returns 0 at end of input or on an error;
csv_reader_failed tells the two apart. An empty input line is an empty
row (a list of length 0), as in Python. Unlike Python's non-strict
default, a quoted field still open at end of input is always an error,
reported with the line where its opening quote was
(csv_reader_error_line).

Dialects (csv_dialect_new is Python's "excel"; csv_dialect_tab is
"excel-tab") are copied by readers and writers, so the caller keeps
ownership; `lineterminator` is borrowed and must outlive the writer.
quotechar / escapechar 0 mean "none".

The writer formats rows the way Python's csv.writer does (QUOTE_MINIMAL,
QUOTE_ALL or QUOTE_NONE; a row holding one empty field is written as
`""`) to a stream or to an in-memory buffer. csv_format_row and
csv_quote_field are buffer-free conveniences.

csv_dict_reader is Python's DictReader: the first row (or a given list)
names the fields and each later non-empty row becomes a
`map[char*, char*]` (csv_dict_row_free). Missing fields get a copy of
`restval` (default ""; 0 stores a null value); extra fields are kept in
csv_dict_rest until the next row.

Design notes: libs/standard/plans/06_formats_storage.md
*/
import lib.lib
import lib.io
import lib.stream
import structures.string


const int CSV_QUOTE_MINIMAL = 0
const int CSV_QUOTE_ALL = 1
const int CSV_QUOTE_NONE = 3


struct csv_dialect:
	int delimiter
	int quotechar          # 0 = none
	int escapechar         # 0 = none
	int doublequote
	int skipinitialspace
	int strict
	int quoting            # CSV_QUOTE_*
	char* lineterminator   # writer only; borrowed


# Python's "excel" dialect: comma, double quote, doubled quotes, "\r\n".
csv_dialect* csv_dialect_new():
	csv_dialect* d = new csv_dialect()
	d.delimiter = ','
	d.quotechar = '"'
	d.escapechar = 0
	d.doublequote = 1
	d.skipinitialspace = 0
	d.strict = 0
	d.quoting = CSV_QUOTE_MINIMAL
	d.lineterminator = c"\r\n"
	return d


# Python's "excel-tab" dialect.
csv_dialect* csv_dialect_tab():
	csv_dialect* d = csv_dialect_new()
	d.delimiter = 9
	return d


csv_dialect* csv_dialect_copy(csv_dialect* src):
	csv_dialect* d = new csv_dialect()
	d.delimiter = src.delimiter
	d.quotechar = src.quotechar
	d.escapechar = src.escapechar
	d.doublequote = src.doublequote
	d.skipinitialspace = src.skipinitialspace
	d.strict = src.strict
	d.quoting = src.quoting
	d.lineterminator = src.lineterminator
	return d


void csv_dialect_free(csv_dialect* d):
	free(d)


# Returns 0 when the dialect is usable, else a static error message.
char* csv_dialect_check(csv_dialect* d):
	if ((d.delimiter <= 0) || (d.delimiter > 255) || (d.delimiter == 10) || (d.delimiter == 13)):
		return c"delimiter must be a single byte other than a line break"
	if ((d.quotechar < 0) || (d.quotechar > 255) || (d.quotechar == 10) || (d.quotechar == 13)):
		return c"bad quotechar value"
	if ((d.escapechar < 0) || (d.escapechar > 255) || (d.escapechar == 10) || (d.escapechar == 13)):
		return c"bad escapechar value"
	if ((d.quoting != CSV_QUOTE_MINIMAL) && (d.quoting != CSV_QUOTE_ALL) && (d.quoting != CSV_QUOTE_NONE)):
		return c"bad quoting value"
	if ((d.quoting != CSV_QUOTE_NONE) && (d.quotechar == 0)):
		return c"quotechar must be set if quoting enabled"
	if (d.delimiter == d.quotechar):
		return c"delimiter and quotechar must differ"
	if (d.delimiter == d.escapechar):
		return c"delimiter and escapechar must differ"
	if ((d.quotechar != 0) && (d.quotechar == d.escapechar)):
		return c"quotechar and escapechar must differ"
	if (d.lineterminator == 0):
		return c"lineterminator must be set"
	return 0


/* Free helpers */

void csv_row_free(list[char*] row):
	if (cast(int, row) == 0): return
	for char* field in row: free(field)
	row.free()


void csv_rows_free(list[list[char*]] rows):
	if (cast(int, rows) == 0): return
	for list[char*] row in rows: csv_row_free(row)
	rows.free()


void csv_dict_row_free(map[char*, char*] row):
	if (cast(int, row) == 0): return
	for char* key, char* value in row:
		if (value != 0): free(value)
	row.free()


/* Reader */

const int CSV_START_RECORD = 0
const int CSV_START_FIELD = 1
const int CSV_ESCAPED_CHAR = 2
const int CSV_IN_FIELD = 3
const int CSV_IN_QUOTED_FIELD = 4
const int CSV_ESCAPE_IN_QUOTED_FIELD = 5
const int CSV_QUOTE_IN_QUOTED_FIELD = 6


struct csv_reader:
	csv_dialect* dialect   # owned copy
	char* data             # buffer source (borrowed), or 0
	int length
	int position
	wstream* stream        # stream source (borrowed), or 0
	int newlines           # line terminators consumed so far
	int line_has_bytes     # bytes consumed since the last terminator
	int line_num           # Python's line_num: source lines read so far
	int done
	char* error            # malloc'd message once failed, else 0
	int error_line
	string_builder* field


csv_reader* csv_reader_alloc(csv_dialect* d):
	csv_reader* r = new csv_reader()
	if (d == 0):
		r.dialect = csv_dialect_new()
	else:
		r.dialect = csv_dialect_copy(d)
	r.data = 0
	r.length = 0
	r.position = 0
	r.stream = 0
	r.newlines = 0
	r.line_has_bytes = 0
	r.line_num = 0
	r.done = 0
	r.error = 0
	r.error_line = 0
	r.field = string_new()
	char* problem = csv_dialect_check(r.dialect)
	if (problem != 0):
		r.error = strclone(problem)
		r.done = 1
	return r


# Reads `length` bytes of `data` (borrowed: keep it alive while reading).
csv_reader* csv_reader_new_bytes(char* data, int length, csv_dialect* d):
	csv_reader* r = csv_reader_alloc(d)
	r.data = data
	r.length = length
	return r


# Reads a NUL-terminated text (borrowed) with the default dialect.
csv_reader* csv_reader_new(char* text):
	return csv_reader_new_bytes(text, strlen(text), 0)


csv_reader* csv_reader_new_dialect(char* text, csv_dialect* d):
	return csv_reader_new_bytes(text, strlen(text), d)


# Reads rows from a stream (borrowed; the caller closes it).
csv_reader* csv_reader_from_stream(wstream* s, csv_dialect* d):
	csv_reader* r = csv_reader_alloc(d)
	r.stream = s
	return r


void csv_reader_free(csv_reader* r):
	if (r == 0): return
	csv_dialect_free(r.dialect)
	string_free(r.field)
	if (r.error != 0): free(r.error)
	free(r)


int csv_reader_failed(csv_reader* r):
	return r.error != 0


# The failure message, or 0 when the reader has not failed.
char* csv_reader_error(csv_reader* r):
	return r.error


# 1-based source line the failure points at (0 when not failed).
int csv_reader_error_line(csv_reader* r):
	return r.error_line


# Source lines read so far (Python's reader.line_num).
int csv_reader_line_num(csv_reader* r):
	return r.line_num


int csv_reader_peek(csv_reader* r):
	if (r.stream != 0): return stream_peek_byte(r.stream)
	if (r.position >= r.length): return (-1)
	return r.data[r.position] & 255


int csv_reader_byte(csv_reader* r):
	int c = -1
	if (r.stream != 0):
		c = stream_read_byte(r.stream)
	else if (r.position < r.length):
		c = r.data[r.position] & 255
		r.position = r.position + 1
	if (c == -1): return c
	if ((c == 10) || ((c == 13) && (csv_reader_peek(r) != 10))):
		r.newlines = r.newlines + 1
		r.line_has_bytes = 0
	else:
		r.line_has_bytes = 1
	return c


# Consumes the '\n' of a "\r\n" record terminator.
void csv_reader_eat_crlf(csv_reader* r, int c):
	if ((c == 13) && (csv_reader_peek(r) == 10)): csv_reader_byte(r)


void csv_reader_fail(csv_reader* r, char* message, int line):
	string_builder* sb = string_new()
	string_append(sb, message)
	string_append(sb, c" (line ")
	string_append_int(sb, line)
	string_append(sb, c")")
	r.error = sb.data
	free(sb)
	r.error_line = line
	r.done = 1


void csv_reader_save_field(csv_reader* r, list[char*] row):
	row.push(strclone(r.field.data))
	string_clear(r.field)


void csv_reader_finish_line(csv_reader* r):
	r.line_num = r.newlines
	if (r.line_has_bytes): r.line_num = r.line_num + 1


# The next record as a list of malloc'd fields (csv_row_free), or 0 at
# end of input or on an error (csv_reader_failed).
list[char*] csv_next_row(csv_reader* r):
	if (r.done): return 0
	csv_dialect* d = r.dialect
	list[char*] row = new list[char*]
	string_clear(r.field)
	int state = CSV_START_RECORD
	int quote_line = 0
	while (1):
		int c = csv_reader_byte(r)
		if (c == -1):
			r.done = 1
			if ((r.stream != 0) && (stream_error(r.stream) != IO_OK)):
				csv_reader_fail(r, c"read error", r.newlines + 1)
				csv_row_free(row)
				return 0
			if (state == CSV_START_RECORD):
				csv_reader_finish_line(r)
				csv_row_free(row)
				return 0
			if ((state == CSV_IN_QUOTED_FIELD) || (state == CSV_ESCAPE_IN_QUOTED_FIELD)):
				csv_reader_fail(r, c"unterminated quoted field", quote_line)
				csv_row_free(row)
				return 0
			if ((state == CSV_ESCAPED_CHAR) && d.strict):
				csv_reader_fail(r, c"unexpected end of data", r.newlines + 1)
				csv_row_free(row)
				return 0
			csv_reader_save_field(r, row)
			csv_reader_finish_line(r)
			return row
		if ((c == 10) || (c == 13)):
			int ends = (state == CSV_START_RECORD) || (state == CSV_START_FIELD) || (state == CSV_IN_FIELD)
			if (ends || (state == CSV_QUOTE_IN_QUOTED_FIELD)):
				if (state != CSV_START_RECORD): csv_reader_save_field(r, row)
				csv_reader_eat_crlf(r, c)
				csv_reader_finish_line(r)
				return row
			string_append_char(r.field, c)
			if (state == CSV_ESCAPED_CHAR): state = CSV_IN_FIELD
			else if (state == CSV_ESCAPE_IN_QUOTED_FIELD): state = CSV_IN_QUOTED_FIELD
			continue
		if (state == CSV_START_RECORD): state = CSV_START_FIELD
		if (state == CSV_START_FIELD):
			if ((c == d.quotechar) && (d.quotechar != 0) && (d.quoting != CSV_QUOTE_NONE)):
				state = CSV_IN_QUOTED_FIELD
				quote_line = r.newlines + 1
			else if ((c == d.escapechar) && (d.escapechar != 0)):
				state = CSV_ESCAPED_CHAR
			else if ((c == ' ') && d.skipinitialspace):
				state = CSV_START_FIELD
			else if (c == d.delimiter):
				csv_reader_save_field(r, row)
			else:
				string_append_char(r.field, c)
				state = CSV_IN_FIELD
		else if (state == CSV_ESCAPED_CHAR):
			string_append_char(r.field, c)
			state = CSV_IN_FIELD
		else if (state == CSV_IN_FIELD):
			if ((c == d.escapechar) && (d.escapechar != 0)):
				state = CSV_ESCAPED_CHAR
			else if (c == d.delimiter):
				csv_reader_save_field(r, row)
				state = CSV_START_FIELD
			else:
				string_append_char(r.field, c)
		else if (state == CSV_IN_QUOTED_FIELD):
			if ((c == d.escapechar) && (d.escapechar != 0)):
				state = CSV_ESCAPE_IN_QUOTED_FIELD
			else if ((c == d.quotechar) && (d.quoting != CSV_QUOTE_NONE)):
				if (d.doublequote): state = CSV_QUOTE_IN_QUOTED_FIELD
				else: state = CSV_IN_FIELD
			else:
				string_append_char(r.field, c)
		else if (state == CSV_ESCAPE_IN_QUOTED_FIELD):
			string_append_char(r.field, c)
			state = CSV_IN_QUOTED_FIELD
		else if (state == CSV_QUOTE_IN_QUOTED_FIELD):
			if ((c == d.quotechar) && (d.quoting != CSV_QUOTE_NONE)):
				string_append_char(r.field, c)
				state = CSV_IN_QUOTED_FIELD
			else if (c == d.delimiter):
				csv_reader_save_field(r, row)
				state = CSV_START_FIELD
			else if (d.strict == 0):
				string_append_char(r.field, c)
				state = CSV_IN_FIELD
			else:
				csv_reader_fail(r, c"delimiter expected after closing quote", r.newlines + 1)
				csv_row_free(row)
				return 0
	return row


# Area-plan spelling of csv_next_row.
list[char*] csv_read_row(csv_reader* r):
	return csv_next_row(r)


# Every remaining row, or 0 on an error (the rows read so far are
# freed and csv_reader_error says why).
list[list[char*]] csv_parse_all_reader(csv_reader* r):
	list[list[char*]] rows = new list[list[char*]]
	list[char*] row = csv_next_row(r)
	while (cast(int, row) != 0):
		rows.push(row)
		row = csv_next_row(r)
	if (csv_reader_failed(r)):
		csv_rows_free(rows)
		return 0
	return rows


# Parses a whole NUL-terminated text with the default dialect; 0 when
# it is malformed (use csv_parse_all_reader to see the error).
list[list[char*]] csv_parse_all(char* text):
	csv_reader* r = csv_reader_new(text)
	list[list[char*]] rows = csv_parse_all_reader(r)
	csv_reader_free(r)
	return rows


list[list[char*]] csv_parse_all_dialect(char* text, csv_dialect* d):
	csv_reader* r = csv_reader_new_dialect(text, d)
	list[list[char*]] rows = csv_parse_all_reader(r)
	csv_reader_free(r)
	return rows


/* Writer */

int csv_lineterminator_has(csv_dialect* d, int c):
	char* t = d.lineterminator
	int i = 0
	while (t[i] != 0):
		if ((t[i] & 255) == c): return 1
		i = i + 1
	return 0


# Appends one formatted field to out (Python's join_append_data).
# `quote_empty` forces quotes (the lone-empty-field rule). Returns 0 or
# a static error message.
char* csv_append_field(string_builder* out, char* field, csv_dialect* d, int quote_empty):
	string_builder* body = string_new()
	int quoted = (d.quoting == CSV_QUOTE_ALL) || quote_empty
	int i = 0
	while (field[i] != 0):
		int c = field[i] & 255
		int special = (c == d.delimiter) || (c == 10) || (c == 13) || csv_lineterminator_has(d, c)
		if ((d.escapechar != 0) && (c == d.escapechar)): special = 1
		if ((d.quotechar != 0) && (c == d.quotechar)): special = 1
		if (special):
			int want_escape = 0
			if (d.quoting == CSV_QUOTE_NONE):
				want_escape = 1
			else:
				if ((d.quotechar != 0) && (c == d.quotechar)):
					if (d.doublequote): string_append_char(body, c)
					else: want_escape = 1
				else if ((d.escapechar != 0) && (c == d.escapechar)):
					want_escape = 1
				if (want_escape == 0): quoted = 1
			if (want_escape):
				if (d.escapechar == 0):
					string_free(body)
					return c"need to escape, but no escapechar set"
				string_append_char(body, d.escapechar)
		string_append_char(body, c)
		i = i + 1
	if (quoted && (d.quoting == CSV_QUOTE_NONE)):
		string_free(body)
		return c"single empty field record must be quoted"
	if (quoted): string_append_char(out, d.quotechar)
	string_append_bytes(out, body.data, body.length)
	if (quoted): string_append_char(out, d.quotechar)
	string_free(body)
	return 0


# Appends a formatted row plus the line terminator. Returns 0 or a
# static error message (out may then hold a partial row).
char* csv_append_row(string_builder* out, list[char*] fields, csv_dialect* d):
	char* problem = csv_dialect_check(d)
	if (problem != 0): return problem
	int lone_empty = (fields.length == 1) && (fields[0][0] == 0)
	int i = 0
	while (i < fields.length):
		if (i > 0): string_append_char(out, d.delimiter)
		problem = csv_append_field(out, fields[i], d, lone_empty)
		if (problem != 0): return problem
		i = i + 1
	string_append(out, d.lineterminator)
	return 0


# One row formatted with the dialect (0 = default), terminator included,
# as a malloc'd string; 0 when the row cannot be written.
char* csv_format_row_dialect(list[char*] fields, csv_dialect* d):
	csv_dialect* owned = 0
	if (d == 0):
		owned = csv_dialect_new()
		d = owned
	string_builder* sb = string_new()
	char* problem = csv_append_row(sb, fields, d)
	if (owned != 0): csv_dialect_free(owned)
	if (problem != 0):
		string_free(sb)
		return 0
	char* text = sb.data
	free(sb)
	return text


char* csv_format_row(list[char*] fields):
	return csv_format_row_dialect(fields, 0)


# One field quoted only as needed (QUOTE_MINIMAL rules of the dialect,
# 0 = default), as a malloc'd string; 0 when it cannot be written.
char* csv_quote_field_dialect(char* field, csv_dialect* d):
	csv_dialect* owned = 0
	if (d == 0):
		owned = csv_dialect_new()
		d = owned
	string_builder* sb = string_new()
	char* problem = csv_dialect_check(d)
	if (problem == 0): problem = csv_append_field(sb, field, d, 0)
	if (owned != 0): csv_dialect_free(owned)
	if (problem != 0):
		string_free(sb)
		return 0
	char* text = sb.data
	free(sb)
	return text


char* csv_quote_field(char* field):
	return csv_quote_field_dialect(field, 0)


struct csv_writer:
	csv_dialect* dialect     # owned copy
	wstream* out             # borrowed, or 0 for a buffer writer
	string_builder* buffer   # owned, buffer writers only
	string_builder* scratch
	char* error              # static message of the last failure, or 0


csv_writer* csv_writer_alloc(wstream* out, csv_dialect* d):
	csv_writer* w = new csv_writer()
	if (d == 0):
		w.dialect = csv_dialect_new()
	else:
		w.dialect = csv_dialect_copy(d)
	w.out = out
	w.buffer = 0
	if (out == 0): w.buffer = string_new()
	w.scratch = string_new()
	w.error = 0
	return w


# Writes rows to a stream (borrowed; the caller flushes and closes it).
csv_writer* csv_writer_new(wstream* out):
	return csv_writer_alloc(out, 0)


csv_writer* csv_writer_new_dialect(wstream* out, csv_dialect* d):
	return csv_writer_alloc(out, d)


# Collects rows in memory; read them with csv_writer_text.
csv_writer* csv_writer_new_buffer(csv_dialect* d):
	csv_writer* w = csv_writer_alloc(0, d)
	return w


# The text a buffer writer has collected (borrowed; valid until the
# next write or csv_writer_free).
char* csv_writer_text(csv_writer* w):
	if (w.buffer == 0): return c""
	return w.buffer.data


# The last failure's message, or 0.
char* csv_writer_error(csv_writer* w):
	return w.error


void csv_writer_free(csv_writer* w):
	if (w == 0): return
	csv_dialect_free(w.dialect)
	if (w.buffer != 0): string_free(w.buffer)
	string_free(w.scratch)
	free(w)


# Writes one row. Returns 1 on success; 0 when the row cannot be
# formatted (nothing is written) or the stream has failed.
int csv_write_row(csv_writer* w, list[char*] fields):
	string_clear(w.scratch)
	char* problem = csv_append_row(w.scratch, fields, w.dialect)
	if (problem != 0):
		w.error = problem
		return 0
	if (w.out == 0):
		string_append_bytes(w.buffer, w.scratch.data, w.scratch.length)
		return 1
	stream_write(w.out, w.scratch.data, w.scratch.length)
	if (stream_error(w.out) != IO_OK):
		w.error = c"write error"
		return 0
	return 1


# Writes every row; stops at the first failure. Returns 1 on success.
int csv_write_rows(csv_writer* w, list[list[char*]] rows):
	for list[char*] row in rows:
		if (csv_write_row(w, row) == 0): return 0
	return 1


/* Dict reader */

struct csv_dict_reader:
	csv_reader* reader        # owned
	list[char*] fieldnames    # owned; 0 until the header is read
	char* restval             # borrowed value for missing fields
	list[char*] rest          # owned extra fields of the last row


# Reads the field names from the first row of `r` (taken over: freed
# with the dict reader).
csv_dict_reader* csv_dict_reader_new(csv_reader* r):
	csv_dict_reader* d = new csv_dict_reader()
	d.reader = r
	d.fieldnames = cast(list[char*], 0)
	d.restval = c""
	d.rest = new list[char*]
	return d


# Uses `fieldnames` (copied) instead of a header row.
csv_dict_reader* csv_dict_reader_new_fields(csv_reader* r, list[char*] fieldnames):
	csv_dict_reader* d = csv_dict_reader_new(r)
	d.fieldnames = new list[char*]
	for char* name in fieldnames: d.fieldnames.push(strclone(name))
	return d


void csv_dict_reader_free(csv_dict_reader* d):
	if (d == 0): return
	csv_reader_free(d.reader)
	csv_row_free(d.fieldnames)
	csv_row_free(d.rest)
	free(d)


# The field names (borrowed), reading the header row if needed; 0 when
# the input is empty or malformed.
list[char*] csv_dict_fieldnames(csv_dict_reader* d):
	if (cast(int, d.fieldnames) == 0):
		d.fieldnames = csv_next_row(d.reader)
	return d.fieldnames


# Extra fields of the last row beyond the field names (borrowed).
list[char*] csv_dict_rest(csv_dict_reader* d):
	return d.rest


# The next non-empty row keyed by field name (csv_dict_row_free), or 0
# at end of input or on an error (csv_reader_failed(d.reader)).
map[char*, char*] csv_dict_next_row(csv_dict_reader* d):
	list[char*] names = csv_dict_fieldnames(d)
	if (cast(int, names) == 0): return 0
	list[char*] row = csv_next_row(d.reader)
	while ((cast(int, row) != 0) && (row.length == 0)):
		csv_row_free(row)
		row = csv_next_row(d.reader)
	if (cast(int, row) == 0): return 0
	for char* extra in d.rest: free(extra)
	d.rest.clear()
	map[char*, char*] result = new map[char*, char*]
	int i = 0
	while (i < names.length):
		char* value = 0
		if (i < row.length):
			value = strclone(row[i])
		else if (d.restval != 0):
			value = strclone(d.restval)
		char* name = names[i]
		if (name in result):
			char* old = result[name]
			if (old != 0): free(old)
		result[name] = value
		i = i + 1
	while (i < row.length):
		d.rest.push(strclone(row[i]))
		i = i + 1
	csv_row_free(row)
	return result
