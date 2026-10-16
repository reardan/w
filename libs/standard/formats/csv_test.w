# wbuild: x64
# wbuild: step="bin/csv_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import lib.file
import libs.standard.formats.csv


# Renders rows as "[f1|f2][f3]" so a whole parse compares as one string.
char* csv_test_render(list[list[char*]] rows):
	string_builder* sb = string_new()
	for list[char*] row in rows:
		string_append(sb, c"[")
		int i = 0
		while (i < row.length):
			if (i > 0): string_append(sb, c"|")
			string_append(sb, row[i])
			i = i + 1
		string_append(sb, c"]")
	char* text = sb.data
	free(sb)
	return text


void expect_parse_dialect(char* text, csv_dialect* d, char* want):
	list[list[char*]] rows = csv_parse_all_dialect(text, d)
	asserts(text, cast(int, rows) != 0)
	char* got = csv_test_render(rows)
	assert_strings_equal(want, got)
	free(got)
	csv_rows_free(rows)


void expect_parse(char* text, char* want):
	expect_parse_dialect(text, 0, want)


# Parses `text` expecting a failure on `line` whose message has `needle`.
void expect_error_dialect(char* text, csv_dialect* d, char* needle, int line):
	csv_reader* r = csv_reader_new_dialect(text, d)
	list[list[char*]] rows = csv_parse_all_reader(r)
	assert_equal(0, cast(int, rows))
	assert_equal(1, csv_reader_failed(r))
	assert_contains(csv_reader_error(r), needle)
	assert_equal(line, csv_reader_error_line(r))
	csv_reader_free(r)


void expect_error(char* text, char* needle, int line):
	expect_error_dialect(text, 0, needle, line)


void test_csv_simple_rows():
	expect_parse(c"a,b,c\r\n1,2,3\r\n", c"[a|b|c][1|2|3]")
	expect_parse(c"a,b\n1,2\n", c"[a|b][1|2]")
	expect_parse(c"a,b\r1,2\r", c"[a|b][1|2]")
	expect_parse(c"a,b\n1,2", c"[a|b][1|2]")
	expect_parse(c"", c"")
	expect_parse(c"x", c"[x]")


void test_csv_empty_fields_and_lines():
	expect_parse(c",\n", c"[|]")
	expect_parse(c"a,,c\n", c"[a||c]")
	expect_parse(c"a,\n", c"[a|]")
	# Empty lines are empty rows (Python yields []).
	expect_parse(c"a\n\nb\n", c"[a][][b]")
	expect_parse(c"\r\n\r\n", c"[][]")
	expect_parse(c"\"\"\n", c"[]")
	list[list[char*]] rows = csv_parse_all(c"\"\"\n\n")
	assert_equal(2, rows.length)
	assert_equal(1, rows[0].length)
	assert_strings_equal(c"", rows[0][0])
	assert_equal(0, rows[1].length)
	csv_rows_free(rows)


void test_csv_quoted_fields():
	expect_parse(c"\"a,b\",c\n", c"[a,b|c]")
	expect_parse(c"\"he said \"\"hi\"\"\",x\n", c"[he said \"hi\"|x]")
	expect_parse(c"\"line1\nline2\",z\n", c"[line1\nline2|z]")
	expect_parse(c"\"crlf\r\ninside\"\r\nnext\r\n", c"[crlf\r\ninside][next]")
	expect_parse(c"\"\"\"\"\n", c"[\"]")
	expect_parse(c"\"\",\"\"\n", c"[|]")
	# A quote inside an unquoted field is literal.
	expect_parse(c"ab\"c,d\n", c"[ab\"c|d]")
	# Non-strict: text after a closing quote is kept (Python behavior).
	expect_parse(c"\"ab\"cd,e\n", c"[abcd|e]")
	expect_parse(c" \"a\",b\n", c"[ \"a\"|b]")


void test_csv_custom_dialect():
	csv_dialect* d = csv_dialect_new()
	d.delimiter = ';'
	d.quotechar = 39
	expect_parse_dialect(c"a;'b;c';'it''s'\n", d, c"[a|b;c|it's]")
	expect_parse_dialect(c"a,b;\"c\"\n", d, c"[a,b|\"c\"]")
	csv_dialect_free(d)

	csv_dialect* tab = csv_dialect_tab()
	expect_parse_dialect(c"a\tb c\t\"d\te\"\n", tab, c"[a|b c|d\te]")
	csv_dialect_free(tab)

	csv_dialect* sp = csv_dialect_new()
	sp.skipinitialspace = 1
	expect_parse_dialect(c"a, b,  \"c,d\"\n", sp, c"[a|b|c,d]")
	csv_dialect_free(sp)


void test_csv_escapechar_and_quote_none():
	csv_dialect* d = csv_dialect_new()
	d.escapechar = 92
	d.doublequote = 0
	expect_parse_dialect(c"a\\,b,\"q\\\"x\",c\\\nd\n", d, c"[a,b|q\"x|c\nd]")
	csv_dialect_free(d)

	csv_dialect* none = csv_dialect_new()
	none.quoting = CSV_QUOTE_NONE
	expect_parse_dialect(c"\"a\",\"b\n", none, c"[\"a\"|\"b]")
	csv_dialect_free(none)


void test_csv_unterminated_quote_reports_line():
	expect_error(c"a,b\nc,\"open\nmore\n", c"unterminated quoted field", 2)
	expect_error(c"\"", c"line 1", 1)
	expect_error(c"x\r\ny\r\n\"z", c"unterminated quoted field (line 3)", 3)
	# Rows before the bad record are still returned one at a time.
	csv_reader* r = csv_reader_new(c"ok,1\n\"bad\n")
	list[char*] row = csv_next_row(r)
	assert_equal(2, row.length)
	assert_equal(1, csv_reader_line_num(r))
	csv_row_free(row)
	assert_equal(0, cast(int, csv_next_row(r)))
	assert_equal(1, csv_reader_failed(r))
	assert_equal(2, csv_reader_error_line(r))
	assert_equal(0, cast(int, csv_next_row(r)))
	csv_reader_free(r)
	assert_equal(0, cast(int, csv_parse_all(c"a\n\"b")))


void test_csv_strict_mode():
	csv_dialect* d = csv_dialect_new()
	d.strict = 1
	expect_error_dialect(c"x\n\"ab\"cd\n", d, c"delimiter expected after closing quote", 2)
	expect_parse_dialect(c"\"ab\",cd\n", d, c"[ab|cd]")
	d.escapechar = 92
	expect_error_dialect(c"ab\\", d, c"unexpected end of data", 1)
	csv_dialect_free(d)


void test_csv_bad_dialect():
	csv_dialect* d = csv_dialect_new()
	d.quotechar = ','
	expect_error_dialect(c"a\n", d, c"delimiter and quotechar must differ", 0)
	d.quotechar = 0
	expect_error_dialect(c"a\n", d, c"quotechar must be set", 0)
	csv_dialect_free(d)


void test_csv_line_num():
	csv_reader* r = csv_reader_new(c"a\n\"b\nc\"\nd")
	list[char*] row = csv_next_row(r)
	assert_equal(1, csv_reader_line_num(r))
	csv_row_free(row)
	row = csv_next_row(r)
	assert_strings_equal(c"b\nc", row[0])
	assert_equal(3, csv_reader_line_num(r))
	csv_row_free(row)
	row = csv_next_row(r)
	assert_equal(4, csv_reader_line_num(r))
	csv_row_free(row)
	assert_equal(0, cast(int, csv_next_row(r)))
	assert_equal(0, csv_reader_failed(r))
	assert_equal(4, csv_reader_line_num(r))
	csv_reader_free(r)


void test_csv_bytes_reader():
	csv_reader* r = csv_reader_new_bytes(c"a,b\nc,d\nIGNORED", 8, 0)
	list[list[char*]] rows = csv_parse_all_reader(r)
	char* got = csv_test_render(rows)
	assert_strings_equal(c"[a|b][c|d]", got)
	free(got)
	csv_rows_free(rows)
	csv_reader_free(r)


void test_csv_quote_field():
	char* q = csv_quote_field(c"plain")
	assert_strings_equal(c"plain", q)
	free(q)
	q = csv_quote_field(c"a,b")
	assert_strings_equal(c"\"a,b\"", q)
	free(q)
	q = csv_quote_field(c"say \"x\"")
	assert_strings_equal(c"\"say \"\"x\"\"\"", q)
	free(q)
	q = csv_quote_field(c"two\nlines")
	assert_strings_equal(c"\"two\nlines\"", q)
	free(q)
	q = csv_quote_field(c"cr\r")
	assert_strings_equal(c"\"cr\r\"", q)
	free(q)
	q = csv_quote_field(c"")
	assert_strings_equal(c"", q)
	free(q)
	q = csv_quote_field(c" lead")
	assert_strings_equal(c" lead", q)
	free(q)


void expect_format(list[char*] fields, csv_dialect* d, char* want):
	char* got = csv_format_row_dialect(fields, d)
	assert_strings_equal(want, got)
	free(got)


void test_csv_format_row():
	list[char*] fields = list[char*]{c"a", c"b,c", c"", c"d\"e"}
	expect_format(fields, 0, c"a,\"b,c\",,\"d\"\"e\"\r\n")
	char* text = csv_format_row(fields)
	assert_strings_equal(c"a,\"b,c\",,\"d\"\"e\"\r\n", text)
	free(text)

	csv_dialect* all = csv_dialect_new()
	all.quoting = CSV_QUOTE_ALL
	all.lineterminator = c"\n"
	expect_format(fields, all, c"\"a\",\"b,c\",\"\",\"d\"\"e\"\n")
	csv_dialect_free(all)
	fields.free()

	# A lone empty field must be quoted, or it would read back as [].
	list[char*] lone = list[char*]{c""}
	expect_format(lone, 0, c"\"\"\r\n")
	list[char*] empty = new list[char*]
	expect_format(empty, 0, c"\r\n")
	empty.free()

	csv_dialect* none = csv_dialect_new()
	none.quoting = CSV_QUOTE_NONE
	assert_equal(0, cast(int, csv_format_row_dialect(lone, none)))
	lone.free()
	list[char*] plain = list[char*]{c"x", c"y"}
	expect_format(plain, none, c"x,y\r\n")
	list[char*] special = list[char*]{c"a,b"}
	assert_equal(0, cast(int, csv_format_row_dialect(special, none)))
	none.escapechar = 92
	expect_format(special, none, c"a\\,b\r\n")
	csv_dialect_free(none)
	special.free()
	plain.free()

	csv_dialect* esc = csv_dialect_new()
	esc.escapechar = 92
	esc.doublequote = 0
	list[char*] quoted = list[char*]{c"q\"x", c"back\\slash"}
	expect_format(quoted, esc, c"q\\\"x,back\\\\slash\r\n")
	esc.escapechar = 0
	assert_equal(0, cast(int, csv_format_row_dialect(quoted, esc)))
	csv_dialect_free(esc)
	quoted.free()


void test_csv_buffer_writer_round_trip():
	csv_writer* w = csv_writer_new_buffer(0)
	list[list[char*]] rows = new list[list[char*]]
	rows.push(list[char*]{c"id", c"text"})
	rows.push(list[char*]{c"1", c"comma, inside"})
	rows.push(list[char*]{c"2", c"quote \" inside"})
	rows.push(list[char*]{c"3", c"multi\r\nline\nfield"})
	rows.push(list[char*]{c""})
	rows.push(new list[char*])
	rows.push(list[char*]{c"", c""})
	assert_equal(1, csv_write_rows(w, rows))
	list[list[char*]] back = csv_parse_all(csv_writer_text(w))
	char* want = csv_test_render(rows)
	char* got = csv_test_render(back)
	assert_strings_equal(want, got)
	free(want)
	free(got)
	assert_equal(rows.length, back.length)
	assert_equal(1, back[4].length)
	assert_equal(0, back[5].length)
	csv_rows_free(back)
	for list[char*] row in rows: row.free()
	rows.free()
	csv_writer_free(w)


void test_csv_writer_error():
	csv_dialect* none = csv_dialect_new()
	none.quoting = CSV_QUOTE_NONE
	csv_writer* w = csv_writer_new_buffer(none)
	csv_dialect_free(none)
	list[char*] bad = list[char*]{c"a,b"}
	assert_equal(0, csv_write_row(w, bad))
	assert_contains(csv_writer_error(w), c"escapechar")
	assert_strings_equal(c"", csv_writer_text(w))
	bad.free()
	csv_writer_free(w)


# The 32- and 64-bit twins run in parallel, so each gets its own file.
char* csv_test_path():
	if (sizeof(int) == 8): return c"/tmp/w_csv_test_stream_31c7_64.csv"
	return c"/tmp/w_csv_test_stream_31c7_32.csv"


void test_csv_stream_round_trip():
	wstream* out = stream_open_write(csv_test_path())
	asserts(c"open for write", out != 0)
	csv_writer* w = csv_writer_new(out)
	int i = 0
	while (i < 500):
		list[char*] row = new list[char*]
		string_builder* n = string_new()
		string_append_int(n, i)
		row.push(n.data)
		row.push(c"a \"quoted\", multi\nline value")
		row.push(c"")
		assert_equal(1, csv_write_row(w, row))
		row.free()
		string_free(n)
		i = i + 1
	csv_writer_free(w)
	stream_close(out)

	# A tiny buffer makes records and "\r\n" pairs straddle refills.
	int fd = open(csv_test_path(), 0, 0)
	asserts(c"open for read", fd >= 0)
	wstream* in = stream_reader_sized(fd, 3)
	csv_reader* r = csv_reader_from_stream(in, 0)
	int count = 0
	list[char*] row = csv_next_row(r)
	while (cast(int, row) != 0):
		assert_equal(3, row.length)
		assert_equal(count, atoi(row[0]))
		assert_strings_equal(c"a \"quoted\", multi\nline value", row[1])
		assert_strings_equal(c"", row[2])
		csv_row_free(row)
		count = count + 1
		row = csv_next_row(r)
	assert_equal(500, count)
	assert_equal(0, csv_reader_failed(r))
	assert_equal(1000, csv_reader_line_num(r))
	csv_reader_free(r)
	stream_close(in)
	unlink(csv_test_path())


void test_csv_dict_reader():
	csv_reader* r = csv_reader_new(c"name,age,city\nann,30,Paris\n\nbob,41\ncy,22,Rome,extra1,extra2\n")
	csv_dict_reader* d = csv_dict_reader_new(r)
	list[char*] names = csv_dict_fieldnames(d)
	assert_equal(3, names.length)
	assert_strings_equal(c"city", names[2])

	map[char*, char*] row = csv_dict_next_row(d)
	assert_equal(3, row.length)
	assert_strings_equal(c"ann", row[c"name"])
	assert_strings_equal(c"30", row[c"age"])
	assert_strings_equal(c"Paris", row[c"city"])
	assert_equal(0, csv_dict_rest(d).length)
	csv_dict_row_free(row)

	# The empty line is skipped; the short row gets restval for "city".
	row = csv_dict_next_row(d)
	assert_strings_equal(c"bob", row[c"name"])
	assert_strings_equal(c"", row[c"city"])
	csv_dict_row_free(row)

	row = csv_dict_next_row(d)
	assert_strings_equal(c"Rome", row[c"city"])
	list[char*] rest = csv_dict_rest(d)
	assert_equal(2, rest.length)
	assert_strings_equal(c"extra2", rest[1])
	csv_dict_row_free(row)

	assert_equal(0, cast(int, csv_dict_next_row(d)))
	assert_equal(0, csv_reader_failed(d.reader))
	csv_dict_reader_free(d)


void test_csv_dict_reader_fields_and_restval():
	list[char*] names = list[char*]{c"k", c"v", c"k"}
	csv_dict_reader* d = csv_dict_reader_new_fields(csv_reader_new(c"1,2,3\n4\n"), names)
	names.free()
	d.restval = 0
	map[char*, char*] row = csv_dict_next_row(d)
	# A duplicate field name keeps the later column, as in Python.
	assert_equal(2, row.length)
	assert_strings_equal(c"3", row[c"k"])
	assert_strings_equal(c"2", row[c"v"])
	csv_dict_row_free(row)
	row = csv_dict_next_row(d)
	assert_equal(0, cast(int, row[c"v"]))
	assert_equal(0, cast(int, row[c"k"]))
	csv_dict_row_free(row)
	assert_equal(0, cast(int, csv_dict_next_row(d)))
	csv_dict_reader_free(d)


void test_csv_dict_reader_empty_and_malformed():
	csv_dict_reader* d = csv_dict_reader_new(csv_reader_new(c""))
	assert_equal(0, cast(int, csv_dict_fieldnames(d)))
	assert_equal(0, cast(int, csv_dict_next_row(d)))
	csv_dict_reader_free(d)

	d = csv_dict_reader_new(csv_reader_new(c"a,b\n1,\"2\n"))
	assert_equal(0, cast(int, csv_dict_next_row(d)))
	assert_equal(1, csv_reader_failed(d.reader))
	assert_equal(2, csv_reader_error_line(d.reader))
	csv_dict_reader_free(d)
