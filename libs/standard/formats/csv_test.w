import lib.testing
import libs.standard.formats.csv


void assert_csv_row(list[char*] row, int length):
	assert1(cast(int, row) != 0)
	assert_equal(length, row.length)


void assert_csv_read_fails(char* text):
	csv_reader* reader = csv_reader_new(text)
	list[char*] row = csv_read_row(reader)
	assert_equal(0, cast(int, row))
	assert_equal(0, csv_reader_ok(reader))


void test_csv_reads_basic_rows():
	csv_reader* reader = csv_reader_new(c"name,age\nAlice,30\n")
	list[char*] header = csv_read_row(reader)
	assert_csv_row(header, 2)
	assert_strings_equal(c"name", header[0])
	assert_strings_equal(c"age", header[1])
	list[char*] row = csv_read_row(reader)
	assert_csv_row(row, 2)
	assert_strings_equal(c"Alice", row[0])
	assert_strings_equal(c"30", row[1])
	list[char*] eof = csv_read_row(reader)
	assert_equal(0, cast(int, eof))
	assert_equal(1, csv_reader_ok(reader))


void test_csv_reads_quoted_fields():
	csv_reader* reader = csv_reader_new(c"\x22a,b\x22,\x22line\nnext\x22,\x22quote \x22\x22here\x22\x22\x22\r\n")
	list[char*] row = csv_read_row(reader)
	assert_csv_row(row, 3)
	assert_strings_equal(c"a,b", row[0])
	assert_strings_equal(c"line\nnext", row[1])
	assert_strings_equal(c"quote \x22here\x22", row[2])
	assert_equal(1, csv_reader_ok(reader))


void test_csv_empty_and_trailing_fields():
	csv_reader* reader = csv_reader_new(c"a,,\n")
	list[char*] row = csv_read_row(reader)
	assert_csv_row(row, 3)
	assert_strings_equal(c"a", row[0])
	assert_strings_equal(c"", row[1])
	assert_strings_equal(c"", row[2])


void test_csv_custom_dialect_escapechar():
	csv_dialect d = csv_dialect_excel()
	d.delimiter = ';'
	d.escapechar = '\\'
	d.doublequote = 0
	csv_reader* reader = csv_reader_new_dialect(c"\x22a;\x5c\x22b\x22;c\n", &d)
	list[char*] row = csv_read_row(reader)
	assert_csv_row(row, 2)
	assert_strings_equal(c"a;\x22b", row[0])
	assert_strings_equal(c"c", row[1])


void test_csv_write_row_quotes_when_needed():
	list[char*] fields = list[char*]{c"plain", c"a,b", c"quote \x22here\x22", c"line\nnext", c""}
	char* text = csv_write_row(fields)
	assert_strings_equal(c"plain,\x22a,b\x22,\x22quote \x22\x22here\x22\x22\x22,\x22line\nnext\x22,", text)
	free(text)


void test_csv_rejects_malformed_input():
	assert_csv_read_fails(c"\x22unterminated")
	assert_csv_read_fails(c"a\x22b,c\n")
	assert_csv_read_fails(c"\x22a\x22x,b\n")
	assert_csv_read_fails(c"\x22bad\x5c")
